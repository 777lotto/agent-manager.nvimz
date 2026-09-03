local Config = require("agent_manager.config")
local Client = require("agent_manager.client")
local Editor = require("agent_manager.editor")
local Model = require("agent_manager.model")
local UX = require("agent_manager.ux")
local View = require("agent_manager.view")

local M = {}
local runtime = nil
local state_event_pending = false
local state_event_data = nil
local cached_summary = {
  running_count = 0,
  pending_approval_count = 0,
  agent_ids = {},
}

local function summary_for(model)
  local ids = {}
  for _, agent in ipairs(model and model:list() or {}) do
    ids[#ids + 1] = agent.id
  end
  return {
    running_count = model and model:running_count() or 0,
    pending_approval_count = model and model:pending_approval_count() or 0,
    agent_ids = ids,
  }
end

local function publish_state(model, reason)
  cached_summary = summary_for(model)
  state_event_data = vim.tbl_extend("force", vim.deepcopy(cached_summary), {
    reason = reason or "state_changed",
  })
  if state_event_pending then
    return
  end
  state_event_pending = true
  vim.schedule(function()
    state_event_pending = false
    local data = state_event_data
    state_event_data = nil
    if data then
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AgentManagerStateChanged",
        modeline = false,
        data = data,
      })
    end
  end)
end

local function structured_error(kind, message)
  return { kind = kind, message = message }
end

local function report(err)
  if not err then
    return
  end
  if runtime then
    runtime.model:set_client_state(runtime.client.state, err)
    runtime.view:schedule_render()
  end
  vim.notify("Agent Manager: " .. (err.message or "operation failed"), vim.log.levels.ERROR)
end

local function finish(callback, result, err)
  if callback then
    pcall(callback, result, err)
  end
end

local function project_root()
  return vim.fs.root(0, { ".git" }) or vim.uv.cwd()
end

local function ensure_setup()
  if runtime then
    return true
  end
  return M.setup({})
end

local function with_client(action, callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  local started, start_err = runtime.client:start(function(err)
    if err then
      report(err)
      finish(callback, nil, err)
      return
    end
    action()
  end)
  if not started then
    return nil, start_err
  end
  return true
end

local function selected_id(agent_id)
  if agent_id then
    return agent_id
  end
  return runtime and runtime.model.selected_agent_id or nil
end

local function selected_agent()
  return runtime and runtime.model:selected_agent() or nil
end

local function has_live_agent()
  if not runtime then
    return false
  end
  for _, agent in ipairs(runtime.model:list()) do
    if agent.state ~= "disconnected" then
      return true
    end
  end
  return false
end

local function choice_available(action, choice)
  for _, candidate in ipairs(action.payload.choices or {}) do
    if candidate == choice then
      return true
    end
  end
  return false
end

function M.setup(opts)
  if runtime then
    local torn_down, teardown_err = M.teardown()
    if not torn_down then
      return nil, teardown_err
    end
  end
  local config, err = Config.resolve(opts)
  if not config then
    return nil, err
  end
  local model
  local client
  local view
  local ux = UX.new()
  model = Model.new({
    max_events = config.ui.max_events,
    on_change = function(reason)
      publish_state(model, reason)
    end,
  })
  client = Client.new({
    mode = config.broker.mode,
    command = config.broker.command,
    socket = config.broker.socket,
    reconnect = config.broker.reconnect,
    codex_executable = config.providers.codex.executable,
    claude_python = config.providers.claude.python,
    workspace_lifecycle = config.worktrees.lifecycle,
    allow_shared_workspaces = config.worktrees.allow_shared,
    on_notification = function(method, params)
      local changed = model:apply_notification(method, params)
      if changed and method == "agent/event" and params.type == "file.changed" then
        changed = Editor.observe_file_event(params, model) or changed
      end
      if changed and view then
        view:schedule_render()
      end
    end,
    on_status = function(state, status_err)
      model:set_client_state(state, status_err)
      if view then
        view:schedule_render()
      end
    end,
    on_resync = function(replay)
      model:begin_resync(replay.latest)
      vim.schedule(function()
        if not runtime or runtime.client ~= client then
          return
        end
        M.refresh(function(result, refresh_err)
          if refresh_err then
            return
          end
          for _, agent in ipairs((result and result.agents) or {}) do
            if agent.state ~= "disconnected" and agent.provider_session_id then
              M.history(agent.id)
            end
          end
        end)
      end)
    end,
  })
  local actions = {
    start = function(context)
      M.start_ui(context)
    end,
    prompt = function()
      M.prompt_ui()
    end,
    steer = function()
      M.steer_ui()
    end,
    interrupt = function()
      M.confirm_interrupt()
    end,
    attach = function()
      M.attach_ui()
    end,
    fork = function()
      M.fork()
    end,
    archive = function()
      M.confirm_archive()
    end,
    allow = function(action)
      M.respond_approval(action.agent_id, action.id, "allow")
    end,
    deny = function(action)
      if action.kind == "question" then
        M.respond_question(action.agent_id, action.id, "deny", {})
      else
        M.respond_approval(action.agent_id, action.id, "deny")
      end
    end,
    answer = function(action)
      M.answer_ui(action)
    end,
    context = function()
      M.context_ui()
    end,
    diff = function()
      M.diff_ui()
    end,
    refresh = function()
      M.refresh()
    end,
  }
  view = View.new(model, actions, config.ui)
  runtime = {
    config = config,
    model = model,
    client = client,
    view = view,
    ux = ux,
  }
  publish_state(model, "setup")
  return true
end

function M.open()
  local ok, err = ensure_setup()
  if not ok then
    return nil, err
  end
  runtime.view:add_directory_hint(project_root())
  runtime.view:open()
  local started, start_err = runtime.client:start(function(ready_err)
    if ready_err then
      report(ready_err)
    elseif not runtime.client.resync_required then
      M.refresh()
    end
  end)
  if not started then
    report(start_err)
    return nil, start_err
  end
  return true
end

function M.close()
  if not runtime then
    return true
  end
  return runtime.view:close()
end

local function valid_managed_identifier(value, allow_dot)
  if type(value) ~= "string" or value == "" or #value > 128 then
    return false
  end
  local previous_separator = true
  for index = 1, #value do
    local character = value:sub(index, index)
    if character:match("[a-z0-9]") then
      previous_separator = false
    elseif (character == "-" or (allow_dot and character == ".")) and not previous_separator then
      previous_separator = true
    else
      return false
    end
  end
  return not previous_separator
end

local function request_agent_start(params, callback)
  return with_client(function()
    local _, request_err = runtime.client:request("agent/start", params, function(result, rpc_err)
      if rpc_err then
        report(rpc_err)
        finish(callback, nil, rpc_err)
        return
      end
      if result and result.agent then
        runtime.model:select(result.agent.id)
        runtime.view:schedule_render()
      end
      finish(callback, result, nil)
    end)
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.start(opts, callback)
  opts = opts or {}
  if type(opts) ~= "table" then
    local err = structured_error("input", "start options must be a table")
    finish(callback, nil, err)
    return nil, err
  end
  local provider = opts.provider or "codex"
  if provider ~= "codex" and provider ~= "claude" then
    local err = structured_error("input", "provider must be 'codex' or 'claude'")
    finish(callback, nil, err)
    return nil, err
  end
  if opts.managed_workspace ~= nil then
    local workspace = opts.managed_workspace
    if type(workspace) ~= "table" then
      local err = structured_error("input", "managed_workspace must be a table")
      finish(callback, nil, err)
      return nil, err
    end
    if
      not valid_managed_identifier(workspace.repository, true)
      or not valid_managed_identifier(workspace.task_id, false)
    then
      local err = structured_error(
        "input",
        "managed repository and task IDs must use normalized lowercase names"
      )
      finish(callback, nil, err)
      return nil, err
    end
    if workspace.resume ~= nil and type(workspace.resume) ~= "boolean" then
      local err = structured_error("input", "managed_workspace.resume must be a boolean")
      finish(callback, nil, err)
      return nil, err
    end
    return request_agent_start({
      provider = provider,
      managed_workspace = {
        repository = workspace.repository,
        task_id = workspace.task_id,
        resume = workspace.resume == true,
      },
    }, callback)
  end
  local cwd = opts.cwd or project_root()
  if type(cwd) ~= "string" then
    local err = structured_error("input", "cwd must be a directory path")
    finish(callback, nil, err)
    return nil, err
  end
  cwd = vim.uv.fs_realpath(vim.fs.normalize(cwd))
  if not cwd then
    local err = structured_error("input", "cwd does not identify an existing directory")
    finish(callback, nil, err)
    return nil, err
  end
  local strategy = opts.workspace_strategy or "shared"
  if strategy ~= "shared" and strategy ~= "worktree" then
    local err = structured_error("input", "workspace_strategy must be 'shared' or 'worktree'")
    finish(callback, nil, err)
    return nil, err
  end
  local worktree_path = nil
  if strategy == "worktree" then
    if type(opts.worktree_path) ~= "string" then
      local err = structured_error("input", "worktree strategy requires worktree_path")
      finish(callback, nil, err)
      return nil, err
    end
    worktree_path = vim.uv.fs_realpath(vim.fs.normalize(opts.worktree_path))
    if worktree_path ~= cwd then
      local err = structured_error("input", "worktree_path must identify the agent cwd")
      finish(callback, nil, err)
      return nil, err
    end
  end
  return request_agent_start({
    provider = provider,
    cwd = cwd,
    workspace_strategy = strategy,
    worktree_path = worktree_path,
  }, callback)
end

local function normalize_input(input)
  if type(input) == "string" then
    if input == "" then
      return nil, structured_error("input", "input text must not be empty")
    end
    return { text = input, attachments = {} }
  end
  if type(input) ~= "table" then
    return nil, structured_error("input", "input must be text or a table")
  end
  if type(input.text) ~= "string" or input.text == "" then
    return nil, structured_error("input", "input.text must not be empty")
  end
  return {
    text = input.text,
    attachments = vim.deepcopy(input.attachments or {}),
  }
end

local function send_input(method, kind, agent_id, input, callback)
  local normalized, input_err = normalize_input(input)
  if not normalized then
    finish(callback, nil, input_err)
    return nil, input_err
  end
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      method,
      { agent_id = agent_id, input = normalized },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        runtime.model:record_user_input(agent_id, normalized.text, kind)
        runtime.view:schedule_render()
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.prompt(agent_id, input, callback)
  return send_input("agent/prompt", "prompt", agent_id, input, callback)
end

function M.steer(agent_id, input, callback)
  return send_input("agent/steer", "steer", agent_id, input, callback)
end

function M.interrupt(agent_id, callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/interrupt",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.attach(agent_id, callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no broker-owned agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/attach",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        if result and result.agent then
          runtime.model:select(result.agent.id)
          runtime.view:schedule_render()
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.workspaces(callback)
  return with_client(function()
    local _, request_err = runtime.client:request("workspace/list", {}, function(result, rpc_err)
      if rpc_err then
        report(rpc_err)
        finish(callback, nil, rpc_err)
        return
      end
      if result and result.repositories then
        runtime.model:apply_workspace_inventory(result.repositories)
        runtime.view:schedule_render()
      end
      finish(callback, result, nil)
    end)
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.handoff_workspace(repository, task_id, callback)
  if
    not valid_managed_identifier(repository, true)
    or not valid_managed_identifier(task_id, false)
  then
    local err = structured_error("input", "invalid managed repository or task ID")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "workspace/handoff",
      { repository = repository, task_id = task_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.sessions(opts, callback)
  opts = opts or {}
  if type(opts) ~= "table" or (opts.provider ~= "codex" and opts.provider ~= "claude") then
    local err = structured_error("input", "session discovery requires a Codex or Claude provider")
    finish(callback, nil, err)
    return nil, err
  end
  if opts.active_only ~= nil and type(opts.active_only) ~= "boolean" then
    local err = structured_error("input", "active_only must be a boolean")
    finish(callback, nil, err)
    return nil, err
  end
  local cwd = nil
  if opts.cwd ~= nil then
    if type(opts.cwd) ~= "string" then
      local err = structured_error("input", "cwd must be a directory path")
      finish(callback, nil, err)
      return nil, err
    end
    cwd = vim.uv.fs_realpath(vim.fs.normalize(opts.cwd))
    if not cwd then
      local err = structured_error("input", "cwd does not identify an existing directory")
      finish(callback, nil, err)
      return nil, err
    end
  end
  return with_client(function()
    local params = {
      provider = opts.provider,
      cursor = opts.cursor or vim.NIL,
      limit = opts.limit or 50,
      active_only = opts.active_only == true,
    }
    if cwd then
      params.cwd = cwd
    end
    local _, request_err = runtime.client:request(
      "provider/session/list",
      params,
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.resume(opts, callback)
  opts = opts or {}
  if type(opts) ~= "table" then
    local err = structured_error("input", "resume options must be a table")
    finish(callback, nil, err)
    return nil, err
  end
  local provider = opts.provider
  local session_id = opts.provider_session_id or opts.session_id
  if (provider ~= "codex" and provider ~= "claude") or type(session_id) ~= "string" or session_id == "" then
    local err = structured_error("input", "resume requires a provider and provider_session_id")
    finish(callback, nil, err)
    return nil, err
  end
  local cwd = opts.cwd or project_root()
  if type(cwd) ~= "string" then
    local err = structured_error("input", "cwd must be a directory path")
    finish(callback, nil, err)
    return nil, err
  end
  cwd = vim.uv.fs_realpath(vim.fs.normalize(cwd))
  if not cwd then
    local err = structured_error("input", "cwd does not identify an existing directory")
    finish(callback, nil, err)
    return nil, err
  end
  local strategy = opts.workspace_strategy or "shared"
  if strategy ~= "shared" and strategy ~= "worktree" then
    local err = structured_error("input", "workspace_strategy must be 'shared' or 'worktree'")
    finish(callback, nil, err)
    return nil, err
  end
  local worktree_path = nil
  if strategy == "worktree" then
    if type(opts.worktree_path) ~= "string" then
      local err = structured_error("input", "worktree strategy requires worktree_path")
      finish(callback, nil, err)
      return nil, err
    end
    worktree_path = vim.uv.fs_realpath(vim.fs.normalize(opts.worktree_path))
    if worktree_path ~= cwd then
      local err = structured_error("input", "worktree_path must identify the agent cwd")
      finish(callback, nil, err)
      return nil, err
    end
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/resume",
      {
        provider = provider,
        provider_session_id = session_id,
        cwd = cwd,
        workspace_strategy = strategy,
        worktree_path = worktree_path,
      },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        if result and result.agent then
          runtime.model:select(result.agent.id)
          M.history(result.agent.id)
          runtime.view:schedule_render()
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.fork(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/fork",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
          finish(callback, nil, rpc_err)
          return
        end
        if result and result.agent then
          runtime.model:select(result.agent.id)
          M.history(result.agent.id)
          runtime.view:schedule_render()
        end
        finish(callback, result, nil)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.archive(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/archive",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.history(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/history",
      { agent_id = agent_id, cursor = vim.NIL, limit = 200 },
      function(result, rpc_err)
        if result and result.messages then
          runtime.model:apply_history(agent_id, result.messages)
          runtime.view:schedule_render()
        end
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.respond_approval(agent_id, approval_id, decision, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  if
    type(opts) ~= "table"
    or type(approval_id) ~= "string"
    or not ({ allow = true, deny = true, defer = true })[decision]
    or (opts.updated_input ~= nil and type(opts.updated_input) ~= "table")
    or (opts.message ~= nil and type(opts.message) ~= "string")
  then
    local err = structured_error("input", "invalid approval response")
    finish(callback, nil, err)
    return nil, err
  end
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/approval/respond",
      {
        agent_id = agent_id,
        approval_id = approval_id,
        decision = decision,
        updated_input = opts.updated_input,
        message = opts.message or vim.NIL,
      },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.respond_question(agent_id, question_id, decision, answers, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}
  if
    type(opts) ~= "table"
    or type(question_id) ~= "string"
    or (decision ~= "answer" and decision ~= "deny")
    or type(answers) ~= "table"
    or (opts.message ~= nil and type(opts.message) ~= "string")
  then
    local err = structured_error("input", "invalid question response")
    finish(callback, nil, err)
    return nil, err
  end
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/question/respond",
      {
        agent_id = agent_id,
        question_id = question_id,
        decision = decision,
        answers = next(answers) and answers or vim.empty_dict(),
        message = opts.message or vim.NIL,
      },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.add_context(agent_id, context, callback)
  if type(context) ~= "table" then
    local err = structured_error("input", "context must be a table")
    finish(callback, nil, err)
    return nil, err
  end
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/context/add",
      { agent_id = agent_id, context = vim.deepcopy(context) },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.diff(agent_id, callback)
  if not ensure_setup() then
    local err = structured_error("configuration", "Agent Manager setup failed")
    finish(callback, nil, err)
    return nil, err
  end
  agent_id = selected_id(agent_id)
  if not agent_id then
    local err = structured_error("input", "no agent is selected")
    finish(callback, nil, err)
    return nil, err
  end
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/diff",
      { agent_id = agent_id },
      function(result, rpc_err)
        if rpc_err then
          report(rpc_err)
        end
        finish(callback, result, rpc_err)
      end
    )
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

local function refresh_external_sessions(callback)
  if not runtime.config.ui.external_sessions then
    runtime.model:clear_external_sessions()
    callback({ sessions = {}, activity = {} })
    return
  end
  local remaining = 2
  local activity = {}
  local function settle(provider, result, err)
    local sessions = result and result.sessions or {}
    local available = result and result.activity_available == true or false
    runtime.model:apply_external_sessions(provider, sessions, available, err)
    activity[provider] = {
      available = available,
      error = err,
    }
    remaining = remaining - 1
    if remaining == 0 then
      callback({
        sessions = runtime.model:external_session_list(),
        activity = activity,
      })
    end
  end
  for _, provider in ipairs({ "codex", "claude" }) do
    local current_provider = provider
    local _, request_err = runtime.client:request(
      "provider/session/list",
      {
        provider = current_provider,
        cursor = vim.NIL,
        limit = runtime.config.ui.external_session_limit,
        active_only = true,
      },
      function(result, rpc_err)
        settle(current_provider, result, rpc_err)
      end
    )
    if request_err then
      settle(current_provider, nil, request_err)
    end
  end
end

function M.refresh(callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  runtime.ux:refresh()
  return with_client(function()
    local _, request_err = runtime.client:request("agent/list", {}, function(result, rpc_err)
      if result and result.agents then
        runtime.model:apply_state(result.agents)
        runtime.view:schedule_render()
      end
      if rpc_err then
        report(rpc_err)
        finish(callback, nil, rpc_err)
        return
      end
      refresh_external_sessions(function(external)
        result = result or {}
        result.external_sessions = external.sessions
        result.external_activity = external.activity
        runtime.view:schedule_render()
        finish(callback, result, nil)
      end)
    end)
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

local function repository_label(repository)
  local state = repository.canonical_clean and "clean" or "dirty"
  return string.format(
    "%s · base %s · %s",
    repository.slug,
    repository.base_branch,
    state
  )
end

local function task_label(task)
  local lease = #(task.lease_identity or {}) > 0 and table.concat(task.lease_identity, ",")
    or "unleased"
  return string.format("%s/%s · %s", task.repository, task.task_id, lease)
end

local function load_workspace_inventory(callback)
  M.workspaces(function(result, err)
    if err then
      return
    end
    local repositories = result and result.repositories or {}
    if #repositories == 0 then
      vim.notify("Agent Manager: no registered repositories are available", vim.log.levels.WARN)
      return
    end
    callback(repositories)
  end)
end

local function schedule_ui(callback)
  local owner = runtime
  vim.schedule(function()
    if runtime == owner then
      callback()
    end
  end)
end

local function normalized_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local normalized = vim.fs.normalize(path):gsub("/+$", "")
  return normalized == "" and "/" or normalized
end

local function path_within(path, root)
  path = normalized_path(path)
  root = normalized_path(root)
  if not path or not root then
    return false
  end
  return root == "/" or path == root or path:sub(1, #root + 1) == root .. "/"
end

local function contextual_repository(repositories, context)
  context = type(context) == "table" and context or {}
  if type(context.repository) == "string" then
    for _, repository in ipairs(repositories) do
      if repository.slug == context.repository then
        return repository
      end
    end
  end
  local selected = nil
  local selected_length = -1
  for _, repository in ipairs(repositories) do
    local roots = { repository.canonical_path }
    if repository.worktree_root ~= nil and repository.worktree_root ~= vim.NIL then
      table.insert(roots, repository.worktree_root)
    end
    for _, root in ipairs(roots) do
      if type(root) == "string" and path_within(context.cwd, root) and #root > selected_length then
        selected = repository
        selected_length = #root
      end
    end
  end
  return selected
end

local function started_notice(provider, result)
  local agent = result and result.agent
  if not agent then
    return
  end
  vim.notify(
    string.format("Agent Manager: %s is ready in %s — press p to prompt", provider, agent.cwd)
  )
end

local function start_new_managed_task(provider, context)
  local function choose_task_id(repository)
    schedule_ui(function()
      vim.ui.input({
        prompt = string.format("New %s task in %s · stable task ID: ", provider, repository.slug),
      }, function(task_id)
        if not task_id or task_id == "" then
          return
        end
        if not valid_managed_identifier(task_id, false) then
          vim.notify("Agent Manager: task ID must use lowercase kebab-case", vim.log.levels.ERROR)
          return
        end
        schedule_ui(function()
          vim.notify(
            string.format(
              "Agent Manager: starting %s in isolated task %s/%s…",
              provider,
              repository.slug,
              task_id
            )
          )
          local ok, start_err = M.start({
            provider = provider,
            managed_workspace = {
              repository = repository.slug,
              task_id = task_id,
              resume = false,
            },
          }, function(result, err)
            if not err then
              started_notice(provider, result)
            end
          end)
          if not ok and start_err then
            report(start_err)
          end
        end)
      end)
    end)
  end

  local cached = runtime.model:workspace_list()
  local known = contextual_repository(cached, context)
  if not known and valid_managed_identifier(context and context.repository, true) then
    known = { slug = context.repository }
  end
  if known then
    choose_task_id(known)
    return
  end

  vim.notify("Agent Manager: loading registered repositories for " .. provider .. "…")
  load_workspace_inventory(function(repositories)
    local repository = contextual_repository(repositories, context)
    if repository then
      choose_task_id(repository)
      return
    end
    vim.ui.select(repositories, {
      prompt = "New " .. provider .. " task · choose repository",
      format_item = repository_label,
    }, function(selected)
      if selected then
        choose_task_id(selected)
      end
    end)
  end)
end

local function resume_managed_task(provider)
  vim.notify("Agent Manager: loading managed tasks for " .. provider .. "…")
  load_workspace_inventory(function(repositories)
    local tasks = {}
    for _, repository in ipairs(repositories) do
      for _, task in ipairs(repository.tasks or {}) do
        local item = vim.deepcopy(task)
        item.repository = repository.slug
        table.insert(tasks, item)
      end
    end
    if #tasks == 0 then
      vim.notify("Agent Manager: no managed tasks are available to resume", vim.log.levels.WARN)
      return
    end
    vim.ui.select(tasks, {
      prompt = "Resume " .. provider .. " · choose managed task",
      format_item = task_label,
    }, function(task)
      if task then
        schedule_ui(function()
          vim.notify(
            string.format(
              "Agent Manager: resuming %s in isolated task %s/%s…",
              provider,
              task.repository,
              task.task_id
            )
          )
          local ok, start_err = M.start({
            provider = provider,
            managed_workspace = {
              repository = task.repository,
              task_id = task.task_id,
              resume = true,
            },
          }, function(result, err)
            if not err then
              started_notice(provider, result)
            end
          end)
          if not ok and start_err then
            report(start_err)
          end
        end)
      end
    end)
  end)
end

function M.start_ui(context)
  if not ensure_setup() then
    return
  end
  context = type(context) == "table" and vim.deepcopy(context) or {}
  if runtime.config.broker.mode == "embedded" and has_live_agent() then
    vim.notify("Agent Manager embedded mode supports one live agent", vim.log.levels.WARN)
    return
  end
  local function choose_workspace(provider)
    local actions = { "New isolated task", "Resume isolated task" }
    if runtime.config.worktrees.allow_shared then
      table.insert(actions, "Shared checkout (admin-enabled)")
    end
    vim.ui.select(actions, { prompt = "Start " .. provider .. " · choose workspace" }, function(action)
      if action == "New isolated task" then
        schedule_ui(function()
          start_new_managed_task(provider, context)
        end)
      elseif action == "Resume isolated task" then
        schedule_ui(function()
          resume_managed_task(provider)
        end)
      elseif action == "Shared checkout (admin-enabled)" then
        local cwd = context.cwd or project_root()
        vim.notify(string.format("Agent Manager: starting %s in shared checkout %s…", provider, cwd))
        local ok, start_err = M.start({ provider = provider, cwd = cwd, workspace_strategy = "shared" }, function(
          result,
          err
        )
          if not err then
            started_notice(provider, result)
          end
        end)
        if not ok and start_err then
          report(start_err)
        end
      end
    end)
  end

  if context.provider == "codex" or context.provider == "claude" then
    choose_workspace(context.provider)
    return
  end
  vim.ui.select({ "codex", "claude" }, { prompt = "Start agent · choose provider" }, function(provider)
    if provider then
      schedule_ui(function()
        choose_workspace(provider)
      end)
    end
  end)
end

local function session_label(session)
  local updated = session.updated_at and session.updated_at ~= vim.NIL
      and (" · " .. tostring(session.updated_at))
    or ""
  return string.format(
    "%s · %s%s",
    session.title or session.provider_session_id,
    session.cwd ~= "" and session.cwd or "unknown cwd",
    updated
  )
end

local function choose_provider_session(provider)
  M.sessions({ provider = provider, cwd = project_root() }, function(result, err)
    if err then
      return
    end
    if not result or result.activity_available ~= true then
      vim.notify(
        "Agent Manager: cannot verify whether " .. provider .. " sessions are still active",
        vim.log.levels.WARN
      )
      return
    end
    local sessions = {}
    for _, session in ipairs(result and result.sessions or {}) do
      if session.active ~= true then
        table.insert(sessions, session)
      end
    end
    if #sessions == 0 then
      vim.notify("Agent Manager: no resumable " .. provider .. " sessions found for this project")
      return
    end
    vim.ui.select(sessions, {
      prompt = "Resume " .. provider .. " session",
      format_item = session_label,
    }, function(session)
      if session then
        M.resume({
          provider = provider,
          provider_session_id = session.provider_session_id,
          cwd = session.cwd ~= "" and session.cwd or project_root(),
          workspace_strategy = "shared",
        })
      end
    end)
  end)
end

function M.attach_ui()
  if not ensure_setup() then
    return
  end
  local choices = {}
  for _, agent in ipairs(runtime.model:list()) do
    if agent.state ~= "disconnected" then
      table.insert(choices, { kind = "agent", agent = agent })
    end
  end
  if not has_live_agent() then
    table.insert(choices, { kind = "provider", provider = "codex" })
    table.insert(choices, { kind = "provider", provider = "claude" })
  end
  vim.ui.select(choices, {
    prompt = "Attach or resume session",
    format_item = function(choice)
      if choice.kind == "agent" then
        local agent = choice.agent
        return string.format("%s · %s · %s", agent.provider, agent.title, agent.state)
      end
      return "Resume a " .. choice.provider .. " provider session"
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.kind == "agent" then
      M.attach(choice.agent.id)
    else
      choose_provider_session(choice.provider)
    end
  end)
end

local function input_ui(prompt, callback)
  vim.ui.input({ prompt = prompt }, function(text)
    if text and text ~= "" then
      callback(text)
    end
  end)
end

function M.prompt_ui(initial)
  if not ensure_setup() then
    return
  end
  if not selected_agent() then
    local err = structured_error(
      "input",
      "no agent is selected — press 1, place the cursor on a [repo] or [cwd] directory, then press n"
    )
    report(err)
    return nil, err
  end
  if initial and initial ~= "" then
    local ok, err = M.prompt(nil, initial)
    if not ok and err then
      report(err)
    end
    return ok, err
  end
  input_ui("Prompt: ", function(text)
    local ok, err = M.prompt(nil, text)
    if not ok and err then
      report(err)
    end
  end)
  return true
end

function M.steer_ui(initial)
  if initial and initial ~= "" then
    return M.steer(nil, initial)
  end
  input_ui("Steer: ", function(text)
    M.steer(nil, text)
  end)
end

function M.confirm_interrupt()
  if not runtime or not runtime.model.selected_agent_id then
    report(structured_error("input", "no agent is selected"))
    return
  end
  vim.ui.select({ "Cancel", "Interrupt" }, { prompt = "Interrupt active turn?" }, function(choice)
    if choice == "Interrupt" then
      M.interrupt()
    end
  end)
end

function M.confirm_archive()
  local agent = selected_agent()
  if not agent then
    report(structured_error("input", "no agent is selected"))
    return
  end
  vim.ui.select({ "Cancel", "Archive" }, {
    prompt = "Archive " .. tostring(agent.title or agent.id) .. " from Agent Manager?",
  }, function(choice)
    if choice == "Archive" then
      M.archive(agent.id)
    end
  end)
end

local function answer_question(action, questions, index, answers)
  local question = questions[index]
  if not question then
    M.respond_question(action.agent_id, action.id, "answer", answers)
    return
  end
  local prompt = (question.header and (question.header .. ": ") or "")
    .. (question.question or "Answer")
  local options = question.options or {}
  if #options > 0 and not question.multi_select and not question.secret then
    vim.ui.select(options, {
      prompt = prompt,
      format_item = function(option)
        local description = option.description and option.description ~= ""
            and (" — " .. option.description)
          or ""
        return tostring(option.label) .. description
      end,
    }, function(option)
      if option then
        answers[question.id] = tostring(option.label)
        answer_question(action, questions, index + 1, answers)
      end
    end)
    return
  end

  local function accept(value)
    if value == nil then
      return
    end
    if question.multi_select then
      local selected = {}
      for item in value:gmatch("[^,]+") do
        item = vim.trim(item)
        if item ~= "" then
          table.insert(selected, item)
        end
      end
      answers[question.id] = selected
    else
      answers[question.id] = value
    end
    answer_question(action, questions, index + 1, answers)
  end

  local suffix = question.multi_select and " (comma-separated)" or ""
  local input_prompt = prompt .. suffix .. ": "
  if question.secret then
    local ok, value = pcall(vim.fn.inputsecret, input_prompt)
    if ok then
      accept(value)
    end
  else
    vim.ui.input({ prompt = input_prompt }, accept)
  end
end

function M.answer_ui(action)
  if not ensure_setup() then
    return
  end
  action = action or runtime.model:focused_action()
  if not action or action.kind ~= "question" or not choice_available(action, "answer") then
    vim.notify("Agent Manager: focus a pending question before answering", vim.log.levels.WARN)
    return
  end
  local questions = action.payload.questions or {}
  if #questions == 0 then
    report(structured_error("protocol", "the provider question has no answerable prompts"))
    return
  end
  answer_question(action, questions, 1, {})
end

local function capture_context(kind, agent, buffer)
  Editor.capture(kind, agent, { bufnr = buffer }, function(context, err)
    if err then
      report(err)
      return
    end
    M.add_context(agent.id, context, function(result, rpc_err)
      if not rpc_err then
        vim.notify(
          string.format("Agent Manager: queued %s context (%d total)", kind, result.count or 1)
        )
      end
    end)
  end)
end

function M.context_ui()
  if not ensure_setup() then
    return
  end
  local agent = selected_agent()
  if not agent then
    report(structured_error("input", "no agent is selected"))
    return
  end
  local current = vim.api.nvim_get_current_buf()
  local candidates = Editor.context_buffers(agent)
  local preferred = nil
  for _, candidate in ipairs(candidates) do
    if candidate.bufnr == current then
      preferred = candidate
      break
    end
  end

  local function select_kind(candidate)
    vim.ui.select({ "buffer", "range", "diagnostics", "diff" }, {
      prompt = "Context from " .. candidate.label,
    }, function(kind)
      if kind then
        capture_context(kind, agent, candidate.bufnr)
      end
    end)
  end

  if preferred then
    select_kind(preferred)
  elseif #candidates == 0 then
    report(structured_error("editor_context", "no loaded file buffer belongs to the agent cwd"))
  else
    vim.ui.select(candidates, {
      prompt = "Context source buffer",
      format_item = function(candidate)
        return candidate.label .. (candidate.modified and " [unsaved]" or "")
      end,
    }, function(candidate)
      if candidate then
        select_kind(candidate)
      end
    end)
  end
end

local function resolve_conflict(conflict, resolution)
  runtime.model:resolve_file_conflict(conflict.agent_id, conflict.path, resolution)
  runtime.view:schedule_render()
end

local function conflict_ui(conflict)
  vim.ui.select({ "Inspect buffer", "Show disk/buffer diff", "Reload from disk", "Keep buffer" }, {
    prompt = "Resolve external change: " .. conflict.path,
  }, function(choice)
    if choice == "Inspect buffer" then
      local _, err = Editor.inspect(conflict)
      report(err)
    elseif choice == "Show disk/buffer diff" then
      local diff, err = Editor.conflict_diff(conflict)
      if err then
        report(err)
      else
        runtime.view:show_diff(diff, "DISK ↔ DIRTY BUFFER · " .. conflict.path)
      end
    elseif choice == "Reload from disk" then
      vim.ui.select({ "Cancel", "Reload and discard buffer edits" }, {
        prompt = "Discard unsaved edits in " .. conflict.path .. "?",
      }, function(confirm)
        if confirm == "Reload and discard buffer edits" then
          local ok, err = Editor.reload(conflict)
          if ok then
            resolve_conflict(conflict, "reloaded")
          else
            report(err)
          end
        end
      end)
    elseif choice == "Keep buffer" then
      resolve_conflict(conflict, "kept_buffer")
      vim.notify("Agent Manager: kept the dirty buffer without reloading")
    end
  end)
end

function M.diff_ui()
  if not ensure_setup() then
    return
  end
  local agent = selected_agent()
  if not agent then
    report(structured_error("input", "no agent is selected"))
    return
  end
  local conflicts = runtime.model:file_conflict_list(agent.id)
  if #conflicts > 0 then
    if #conflicts == 1 then
      conflict_ui(conflicts[1])
    else
      vim.ui.select(conflicts, {
        prompt = "Dirty buffers changed on disk",
        format_item = function(conflict)
          return conflict.path
        end,
      }, function(conflict)
        if conflict then
          conflict_ui(conflict)
        end
      end)
    end
    return
  end
  M.diff(agent.id, function(result, err)
    if not err then
      local title = "WORKSPACE DIFF · " .. (result.cwd or agent.cwd)
      if result.truncated then
        title = title .. " · TRUNCATED"
      end
      runtime.view:show_diff(result.diff or "", title)
    end
  end)
end

function M.list()
  if not ensure_setup() then
    return {}
  end
  return runtime.model:list()
end

function M.status()
  if not runtime then
    return {
      model = {
        agents = {},
        client_state = "stopped",
      },
      client = { state = "stopped" },
      view = {
        open = false,
        buffers = {},
        windows = {},
        backend = "native",
      },
      summary = vim.deepcopy(cached_summary),
    }
  end
  return {
    model = runtime.model:snapshot(),
    client = runtime.client:status(),
    view = runtime.view:status(),
    summary = vim.deepcopy(cached_summary),
  }
end

function M.running_count()
  return cached_summary.running_count
end

function M.pending_approval_count()
  return cached_summary.pending_approval_count
end

function M.health()
  local status = M.status()
  local config = runtime and runtime.config or select(1, Config.resolve({}))
  local broker = status.client or {}
  if config and broker.command == nil then
    broker.command = vim.deepcopy(config.broker.command)
  end
  return {
    neovim = tostring(vim.version()),
    root = config and config.root or nil,
    broker = broker,
    mode = config and config.broker.mode or nil,
    codex_executable = config and config.providers.codex.executable or nil,
    claude_python = config and config.providers.claude.python or nil,
    worktrees = config and vim.deepcopy(config.worktrees) or nil,
    agents = status.model and status.model.agents or {},
    ux = runtime and runtime.ux:status() or UX.detect(),
  }
end

function M.teardown()
  if not runtime then
    return true
  end
  local old = runtime
  runtime = nil
  old.view:teardown()
  old.client:stop()
  local ux_ok, ux_err = old.ux:teardown()
  publish_state(nil, "teardown")
  if not ux_ok then
    return nil, structured_error("ux_teardown", "UX presentation teardown failed: " .. tostring(
      type(ux_err) == "table" and (ux_err.message or vim.inspect(ux_err)) or ux_err
    ))
  end
  return true
end

return M
