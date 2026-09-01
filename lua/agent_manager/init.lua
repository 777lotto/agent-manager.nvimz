local Config = require("agent_manager.config")
local Client = require("agent_manager.client")
local Model = require("agent_manager.model")
local View = require("agent_manager.view")

local M = {}
local runtime = nil

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

function M.setup(opts)
  if runtime then
    M.teardown()
  end
  local config, err = Config.resolve(opts)
  if not config then
    return nil, err
  end
  local model = Model.new({ max_events = config.ui.max_events })
  local client
  local view
  client = Client.new({
    command = config.broker.command,
    claude_python = config.providers.claude.python,
    on_notification = function(method, params)
      if model:apply_notification(method, params) and view then
        view:schedule_render()
      end
    end,
    on_status = function(state, status_err)
      model:set_client_state(state, status_err)
      if view then
        view:schedule_render()
      end
    end,
  })
  local actions = {
    start = function()
      M.start_ui()
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
  }
  return true
end

function M.open()
  local ok, err = ensure_setup()
  if not ok then
    return nil, err
  end
  runtime.view:open()
  local started, start_err = runtime.client:start(function(ready_err)
    if ready_err then
      report(ready_err)
    else
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
  return with_client(function()
    local _, request_err = runtime.client:request(
      "agent/start",
      {
        provider = provider,
        cwd = cwd,
        workspace_strategy = strategy,
        worktree_path = opts.worktree_path,
      },
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

local function normalize_input(input)
  if type(input) == "string" then
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

function M.resume(_, callback)
  local err = structured_error("milestone", "resume is planned for M2")
  finish(callback, nil, err)
  return nil, err
end

function M.fork(_, callback)
  local err = structured_error("milestone", "fork is planned for M2")
  finish(callback, nil, err)
  return nil, err
end

function M.refresh(callback)
  local ok, setup_err = ensure_setup()
  if not ok then
    finish(callback, nil, setup_err)
    return nil, setup_err
  end
  return with_client(function()
    local _, request_err = runtime.client:request("agent/list", {}, function(result, rpc_err)
      if result and result.agents then
        runtime.model:apply_state(result.agents)
        runtime.view:schedule_render()
      end
      if rpc_err then
        report(rpc_err)
      end
      finish(callback, result, rpc_err)
    end)
    if request_err then
      report(request_err)
      finish(callback, nil, request_err)
    end
  end, callback)
end

function M.start_ui()
  if not ensure_setup() then
    return
  end
  if #runtime.model:list() > 0 then
    vim.notify("Agent Manager M1 supports one agent per embedded broker", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "codex", "claude" }, { prompt = "Agent provider" }, function(provider)
    if provider then
      M.start({ provider = provider, cwd = project_root(), workspace_strategy = "shared" })
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
  if initial and initial ~= "" then
    return M.prompt(nil, initial)
  end
  input_ui("Prompt: ", function(text)
    M.prompt(nil, text)
  end)
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

function M.list()
  if not ensure_setup() then
    return {}
  end
  return runtime.model:list()
end

function M.status()
  if not ensure_setup() then
    return {}
  end
  return {
    model = runtime.model:snapshot(),
    client = runtime.client:status(),
    view = runtime.view:status(),
  }
end

function M.running_count()
  return ensure_setup() and runtime.model:running_count() or 0
end

function M.pending_approval_count()
  return ensure_setup() and runtime.model:pending_approval_count() or 0
end

function M.health()
  local status = M.status()
  return {
    neovim = tostring(vim.version()),
    root = runtime and runtime.config.root or nil,
    broker = status.client,
    mode = runtime and runtime.config.broker.mode or nil,
    claude_python = runtime and runtime.config.providers.claude.python or nil,
    agents = status.model and status.model.agents or {},
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
  return true
end

return M
