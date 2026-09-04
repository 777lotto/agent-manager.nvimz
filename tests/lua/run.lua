local root = assert(vim.env.AGENT_MANAGER_TEST_ROOT, "AGENT_MANAGER_TEST_ROOT is required")
vim.opt.runtimepath:prepend(root)
vim.cmd("helptags " .. vim.fn.fnameescape(root .. "/doc"))

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "values differ")
        .. ": expected "
        .. vim.inspect(expected)
        .. ", got "
        .. vim.inspect(actual)
    )
  end
end

local function await(message, predicate)
  local ok = vim.wait(5000, predicate, 10, false)
  if not ok then
    error("timed out waiting for " .. message)
  end
end

local function buffer_contains(buffer, needle)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  return table.concat(lines, "\n"):find(needle, 1, true) ~= nil
end

local function buffer_has_line(buffer, expected)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line == expected then
      return true
    end
  end
  return false
end

local function buffer_line_number(buffer, needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

local function pure_client_resync_test()
  local Client = require("agent_manager.client")
  local observed_resync = nil
  local client = Client.new({
    mode = "durable",
    command = { "/fixture/agent-manager-broker", "serve-durable" },
    socket = "/fixture/broker.sock",
    on_resync = function(replay)
      observed_resync = replay
    end,
  })
  client.last_sequence = 3
  client.request = function(_, method, params, callback)
    assert_equal(method, "initialize", "resync handshake method")
    assert_equal(params.last_sequence, 3, "resync request cursor")
    callback({
      protocol_version = 1,
      mode = "durable",
      replay = { resync_required = true, oldest = 40, latest = 41 },
    }, nil)
    return 1
  end
  client.notify = function(_, method)
    assert_equal(method, "initialized", "resync initialized notification")
    return true
  end
  client:_begin_initialize()
  assert_equal(client.last_sequence, 41, "resync advances the reconnect cursor")
  assert_equal(observed_resync.latest, 41, "resync callback receives the baseline")
  assert_equal(client.state, "connected", "resync handshake reaches connected state")
end

local function pure_model_test()
  local Model = require("agent_manager.model")
  local model = Model.new({ max_events = 8 })
  model:apply_state({
    {
      id = "agent-1",
      provider = "codex",
      provider_session_id = "thread-1",
      cwd = "/tmp",
      workspace_strategy = "shared",
      title = "fixture",
      state = "idle",
      pending_approvals = 0,
      capabilities = { { name = "approvals", available = true } },
    },
  })
  assert(model:apply_external_sessions("codex", {
    {
      provider_session_id = "thread-1",
      cwd = "/tmp",
      title = "managed duplicate",
      active = true,
    },
    {
      provider_session_id = "external-codex",
      cwd = "/workspace/repos/alpha/api",
      title = "external fixture",
      active = true,
    },
    {
      provider_session_id = "saved-codex",
      cwd = "/workspace/repos/alpha/api",
      title = "saved fixture",
      active = false,
    },
  }, true))
  assert_equal(#model:external_session_list(), 2, "managed provider sessions are de-duplicated")
  assert_equal(model:list()[1].external_active, true, "duplicate active writer is retained on broker row")
  assert_equal(model:external_session_list()[1].state, "running", "active external session state")
  assert_equal(model:external_session_list()[2].state, "resumable", "saved external session state")
  assert_equal(#model:session_list(), 3, "combined session projection")
  assert(model:apply_workspace_inventory({
    {
      slug = "agent-manager",
      canonical_path = "/workspace/agent-manager",
      base_branch = "bluff",
    },
  }))
  local repositories = model:workspace_list()
  assert_equal(repositories[1].slug, "agent-manager", "workspace inventory projection")
  repositories[1].slug = "corrupted"
  assert_equal(model:workspace_list()[1].slug, "agent-manager", "workspace inventory is defensive")
  assert(model:record_user_input("agent-1", "question", "prompt"))
  assert(model:apply_event({
    sequence = 1,
    agent_id = "agent-1",
    provider = "codex",
    type = "message.delta",
    payload = { delta = "answer" },
  }))
  assert(model:apply_event({
    sequence = 2,
    agent_id = "agent-1",
    provider = "codex",
    type = "tool.started",
    payload = { item = { command = "fixture" } },
  }))
  assert(model:apply_event({
    sequence = 3,
    agent_id = "agent-1",
    provider = "codex",
    type = "approval.requested",
    payload = {
      id = "approval-1",
      choices = { "allow", "deny" },
      tool_name = "Command",
    },
  }))
  assert_equal(model:focused_action().id, "approval-1", "pending approval projection")
  assert(model:apply_event({
    sequence = 4,
    agent_id = "agent-1",
    provider = "codex",
    type = "approval.resolved",
    payload = { id = "approval-1", decision = "allow" },
  }))
  assert_equal(model:focused_action(), nil, "approval resolution")
  assert(model:apply_event({
    sequence = 5,
    agent_id = "agent-1",
    provider = "codex",
    type = "usage.updated",
    payload = { input_tokens = 4, output_tokens = 2 },
  }))
  assert_equal(model:usage_for().input_tokens, 4, "usage projection")
  assert(model:apply_history("agent-1", {
    { id = "u", role = "user", text = "historic" },
    { id = "a", role = "assistant", text = "reply" },
  }))
  assert_equal(model:conversation()[2].text, "reply", "history projection")
  assert(model:record_file_conflict("agent-1", "/tmp/fixture", { bufnr = 1 }))
  assert_equal(#model:file_conflict_list(), 1, "file conflict projection")
  assert(model:resolve_file_conflict("agent-1", "/tmp/fixture", "kept_buffer"))
  assert_equal(#model:file_conflict_list(), 0, "file conflict resolution")
  assert_equal(model:activity()[1].type, "tool.started", "activity projection")
  local snapshot = model:snapshot()
  snapshot.agents[1].state = "corrupted"
  assert_equal(model:list()[1].state, "idle", "snapshots must be defensive")
  assert(model:begin_resync(41))
  assert_equal(model:snapshot().last_sequence, 41, "history resync cursor")
  assert_equal(model:conversation(), {}, "history resync clears stale projection")
  assert(model:apply_event({
    sequence = 42,
    agent_id = "agent-1",
    provider = "codex",
    type = "message.completed",
    payload = { text = "resynced" },
  }))
  assert_equal(model:snapshot().sequence_gap, nil, "history resync closes sequence gap")
  model:set_client_state("disconnected", { message = "fixture disconnect" })
  assert_equal(model:list()[1].state, "disconnected", "disconnect projection")
  assert_equal(model:external_session_list(), {}, "disconnect clears stale external sessions")
  assert_equal(model:pending(), {}, "disconnect clears unactionable requests")
end

local function layout_test()
  local View = require("agent_manager.view")
  assert_equal(View.layout_for(160).mode, "wide", "wide layout")
  assert_equal(View.layout_for(100).mode, "medium", "medium layout")
  assert_equal(View.layout_for(80).mode, "narrow", "narrow layout")
end

local function workspace_view_navigation_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local home = vim.fn.tempname() .. "-agent-manager-home"
  local repository = home .. "/projects/agent-manager"
  assert_equal(vim.fn.mkdir(repository, "p"), 1, "test home repository creation")
  assert_equal(vim.fn.mkdir(home .. "/notes", "p"), 1, "unrelated home directory creation")
  vim.fn.writefile({ "home fixture" }, home .. "/README.txt")
  vim.fn.writefile({ "project fixture" }, repository .. "/project.txt")

  local model = Model.new({ max_events = 8 })
  model:apply_workspace_inventory({
    {
      slug = "agent-manager",
      canonical_path = repository,
      worktree_root = home .. "/worktrees/agent-manager",
    },
  })
  model:apply_state({
    {
      id = "agent-codex",
      provider = "codex",
      provider_session_id = "codex-view",
      cwd = repository,
      workspace_strategy = "shared",
      title = "codex fixture",
      state = "idle",
      capabilities = {},
      updated_at = "2026-09-01T00:02:00Z",
    },
    {
      id = "agent-claude",
      provider = "claude",
      provider_session_id = "claude-view",
      cwd = repository,
      workspace_strategy = "shared",
      title = "claude fixture",
      state = "idle",
      capabilities = {},
      updated_at = 1788221040000,
    },
  })
  local start_context = nil
  local resumed_session = nil
  local deleted_session = nil
  local diff_target = nil
  local view = View.new(model, {
    start = function(context)
      start_context = context
    end,
    resume = function(session)
      resumed_session = session
    end,
    delete_session = function(session)
      deleted_session = session
    end,
    diff = function(target)
      diff_target = target
    end,
  }, { home = home })
  model:apply_external_sessions("codex", {
    {
      provider_session_id = "codex-saved-view",
      cwd = repository,
      title = "saved codex fixture",
      active = false,
      updated_at = "2026-09-01T00:03:00Z",
    },
    {
      provider_session_id = "codex-home-view",
      cwd = "",
      title = "home codex fixture",
      active = false,
      updated_at = "2026-09-01T00:01:00Z",
    },
  }, true)
  assert(view:open())
  view:render()
  local status = view:status()
  assert(buffer_has_line(status.buffers.agents, " ▾ " .. home .. "/"), "full home root label")
  assert(buffer_contains(status.buffers.agents, "notes/"), "unrelated home directory")
  assert(buffer_contains(status.buffers.agents, "README.txt"), "unrelated home file")
  assert(not buffer_contains(status.buffers.agents, "(unknown)"), "blank session cwd uses home")
  assert(buffer_contains(status.buffers.agents, "● CODEX"), "Codex badge")
  assert(buffer_contains(status.buffers.agents, "○ RESUME"), "saved session badge")
  assert(not buffer_contains(status.buffers.agents, "◆ CLAUDE"), "nested sessions start collapsed")
  assert(not buffer_contains(status.buffers.agents, "project.txt"), "directory files start collapsed")
  local projects_row = assert(buffer_line_number(status.buffers.agents, "projects/"))
  local notes_row = assert(buffer_line_number(status.buffers.agents, "notes/"))
  assert(projects_row < notes_row, "directories containing sessions sort first")
  for index, pane in ipairs({ "agents", "conversation", "activity" }) do
    vim.api.nvim_feedkeys(tostring(index), "x", false)
    assert_equal(view:status().active_pane, pane, "numbered pane navigation")
  end

  assert(view:focus("agents"))
  vim.api.nvim_win_set_cursor(0, { projects_row, 0 })
  vim.api.nvim_feedkeys("l", "x", false)
  assert(vim.wait(1000, function()
    return buffer_contains(status.buffers.agents, "agent-manager/  [repo]")
  end), "projects directory expansion")
  local repository_row = assert(
    buffer_line_number(status.buffers.agents, "agent-manager/  [repo]"),
    "registered repository row"
  )
  vim.api.nvim_win_set_cursor(0, { repository_row, 0 })
  vim.api.nvim_feedkeys("l", "x", false)
  assert(vim.wait(1000, function()
    return buffer_contains(status.buffers.agents, "◆ CLAUDE")
  end), "repository session expansion")
  assert(buffer_contains(status.buffers.agents, "Sessions (3)"), "dedicated session group")
  assert(buffer_contains(status.buffers.agents, "project.txt"), "expanded directory file")
  local session_group_row = assert(buffer_line_number(status.buffers.agents, "Sessions (3)"))
  vim.api.nvim_win_set_cursor(0, { session_group_row, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  assert(vim.wait(1000, function()
    return not buffer_contains(status.buffers.agents, "saved codex fixture")
  end), "session group collapse")
  vim.api.nvim_win_set_cursor(0, { session_group_row, 0 })
  vim.api.nvim_feedkeys("l", "x", false)
  assert(vim.wait(1000, function()
    return buffer_contains(status.buffers.agents, "saved codex fixture")
  end), "session group expansion")
  local claude_row = assert(buffer_line_number(status.buffers.agents, "· claude fixture"))
  local saved_row = assert(buffer_line_number(status.buffers.agents, "saved codex fixture"))
  local codex_row = assert(buffer_line_number(status.buffers.agents, "· codex fixture"))
  assert(claude_row < saved_row and saved_row < codex_row, "sessions sort by latest activity")
  vim.api.nvim_win_set_cursor(0, { repository_row, 0 })
  vim.api.nvim_feedkeys("sn", "x", false)
  assert_equal(start_context.repository, "agent-manager", "directory start repository")
  assert_equal(start_context.cwd, repository, "directory start cwd")
  vim.api.nvim_win_set_cursor(0, { repository_row, 0 })
  vim.api.nvim_feedkeys("df", "x", false)
  assert_equal(diff_target.cwd, repository, "directory diff target")
  vim.api.nvim_win_set_cursor(0, { saved_row, 0 })
  vim.api.nvim_feedkeys("ds", "x", false)
  assert_equal(
    deleted_session.provider_session_id,
    "codex-saved-view",
    "saved row delete action"
  )
  vim.api.nvim_win_set_cursor(0, { saved_row, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  assert_equal(resumed_session.provider_session_id, "codex-saved-view", "saved row resume action")
  view:teardown()
  vim.fn.delete(home, "rf")
end

local function which_key_prefix_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local home = vim.fn.tempname() .. "-agent-manager-which-key"
  assert_equal(vim.fn.mkdir(home, "p"), 1, "which-key test home creation")
  local specs = {}
  local previous_which_key = package.loaded["which-key"]
  package.loaded["which-key"] = {
    add = function(spec)
      vim.list_extend(specs, vim.deepcopy(spec))
    end,
    show = function(opts)
      error("Agent Manager must not call which-key.show() from a keymap: " .. vim.inspect(opts))
    end,
  }
  local view = View.new(Model.new({ max_events = 8 }), {}, { home = home })
  assert(view:open())
  assert(view:focus("agents"))

  local groups = {}
  local buffer = view:status().buffers.agents
  for _, spec in ipairs(specs) do
    if spec.buffer == buffer then
      groups[spec[1]] = spec.group
    end
  end
  assert_equal(groups, {
    a = "agent settings",
    d = "diff / delete",
    g = "go",
    s = "session",
    t = "turn",
  }, "buffer-local which-key groups")
  local prefix_maps = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
    prefix_maps[mapping.lhs] = true
  end
  for _, prefix in ipairs({ "a", "d", "g", "s", "t" }) do
    assert(not prefix_maps[prefix], prefix .. " must be owned by which-key opts.triggers")
  end

  view:teardown()
  package.loaded["which-key"] = previous_which_key
  vim.fn.delete(home, "rf")
end

local function native_presentation_test()
  local manager = require("agent_manager")
  local presentation = require("agent_manager.presentation")
  local baselines = {}
  for _, link in ipairs(presentation.native_links()) do
    baselines[link.group] = vim.api.nvim_get_hl(0, {
      name = link.group,
      link = true,
      create = false,
    })
  end
  local buffer_count = #vim.api.nvim_list_bufs()
  local initial = manager.status()
  assert_equal(initial.view.open, false, "status cache must be readable before setup")
  assert_equal(initial.summary.agent_ids, {}, "initial cached agent IDs")
  assert_equal(#vim.api.nvim_list_bufs(), buffer_count, "status cache must not initialize a view")

  assert(manager.setup({
    broker = {
      command = { "python", root .. "/tests/fixtures/fake_public_broker.py" },
    },
    providers = { claude = { python = false } },
  }))
  local ux = manager.health().ux
  assert_equal(ux.foundation.registered, false, "native mode Foundation registration")
  assert_equal(ux.native_fallback, true, "native fallback mode")
  for _, link in ipairs(presentation.native_links()) do
    assert_equal(
      vim.api.nvim_get_hl(0, { name = link.group, link = true, create = false }).link,
      link.target,
      "native highlight link: " .. link.group
    )
  end
  vim.api.nvim_exec_autocmds("ColorScheme", {
    pattern = "agent-manager-native-replay",
    modeline = false,
  })
  assert(manager.teardown())
  for group, baseline in pairs(baselines) do
    assert_equal(
      vim.api.nvim_get_hl(0, { name = group, link = true, create = false }),
      baseline,
      "native highlight restoration: " .. group
    )
  end
end

local function public_input_validation_test()
  local manager = require("agent_manager")
  local result, err = manager.prompt(nil, "")
  assert_equal(result, nil, "empty string prompt result")
  assert_equal(err.kind, "input", "empty string prompt error")

  result, err = manager.sessions({ provider = "codex", cwd = 42 })
  assert_equal(result, nil, "invalid discovery cwd result")
  assert_equal(err.kind, "input", "invalid discovery cwd error")

  result, err = manager.sessions({ provider = "codex", active_only = "yes" })
  assert_equal(result, nil, "invalid active-only discovery result")
  assert_equal(err.kind, "input", "invalid active-only discovery error")

  result, err = manager.workspace_diff(42)
  assert_equal(result, nil, "invalid workspace diff result")
  assert_equal(err.kind, "input", "invalid workspace diff error")

  result, err = manager.delete_session({ provider = "codex", cwd = "/tmp" })
  assert_equal(result, nil, "invalid session delete result")
  assert_equal(err.kind, "input", "invalid session delete error")

  result, err = manager.resume({
    provider = "claude",
    provider_session_id = "session",
    cwd = 42,
  })
  assert_equal(result, nil, "invalid resume cwd result")
  assert_equal(err.kind, "input", "invalid resume cwd error")

  result, err = manager.resume({
    provider = "claude",
    provider_session_id = "session",
    managed_workspace = { repository = "agent-manager", task_id = "Bad Name" },
  })
  assert_equal(result, nil, "invalid managed resume result")
  assert_equal(err.kind, "input", "invalid managed resume error")
end

local function real_broker_handshake_test()
  local Client = require("agent_manager.client")
  local broker_path = root .. "/target/debug/agent-manager-broker"
  assert(vim.fn.executable(broker_path) == 1, "debug broker must be built before Lua tests")
  local listed = nil
  local request_error = nil
  local client = Client.new({
    command = { broker_path, "serve" },
    claude_python = false,
  })
  assert(client:start())
  await("real broker handshake", function()
    return client.state == "connected"
  end)
  assert(client:request("agent/list", {}, function(result, err)
    listed = result
    request_error = err
  end))
  await("real broker list response", function()
    return listed ~= nil or request_error ~= nil
  end)
  assert_equal(request_error, nil, "real broker list error")
  assert_equal(listed.agents, {}, "real broker starts empty")
  client:stop()
  await("real broker shutdown", function()
    return client.state == "stopped" or client.state == "disconnected"
  end)
  assert_equal(client.state, "stopped", "real broker shutdown state: " .. vim.inspect(client:status()))
end

local function durable_reconnect_test()
  local manager = require("agent_manager")
  local broker_path = root .. "/target/debug/agent-manager-broker"
  local directory = vim.fn.tempname() .. "-agent-manager-m4"
  assert_equal(vim.fn.mkdir(directory, "p"), 1, "durable test directory creation")
  assert(vim.uv.fs_chmod(directory, 448), "durable test directory permissions")
  local socket = directory .. "/broker.sock"
  local registry = directory .. "/registry.json"

  local function start_broker()
    local job = vim.fn.jobstart({
      broker_path,
      "serve-durable",
      "--socket",
      socket,
      "--registry",
      registry,
    }, {
      stdout_buffered = false,
      stderr_buffered = false,
    })
    assert(job > 0, "durable broker process must start")
    await("durable socket", function()
      local stat = vim.uv.fs_stat(socket)
      return stat and stat.type == "socket" and (stat.mode or 0) % 64 == 0
    end)
    return job
  end

  local broker_job = start_broker()
  local ok, setup_err = manager.setup({
    broker = {
      mode = "durable",
      command = { broker_path, "serve-durable" },
      socket = socket,
      reconnect = {
        initial_delay = 20,
        max_delay = 100,
        max_attempts = 20,
        jitter = 0,
      },
    },
    providers = { claude = { python = false } },
    ui = { external_sessions = false },
  })
  assert(ok, vim.inspect(setup_err))
  assert(manager.open())
  await("durable client handshake", function()
    return manager.status().client.state == "connected"
  end)
  assert_equal(manager.health().mode, "durable", "durable health mode")

  vim.fn.jobstop(broker_job)
  vim.fn.jobwait({ broker_job }, 5000)
  await("durable disconnect", function()
    local state = manager.status().client.state
    return state == "disconnected" or state == "reconnecting" or state == "connecting"
  end)
  await("durable socket cleanup", function()
    return vim.uv.fs_stat(socket) == nil
  end)

  broker_job = start_broker()
  await("durable automatic reconnect", function()
    return manager.status().client.state == "connected"
  end)
  assert(manager.status().client.reconnect_attempt == 0, "reconnect counter must reset")
  assert(manager.teardown())
  assert_equal(vim.fn.jobwait({ broker_job }, 0)[1], -1, "teardown must not stop durable broker")
  vim.fn.jobstop(broker_job)
  vim.fn.jobwait({ broker_job }, 5000)
  vim.fn.delete(directory, "rf")
end

local function configure_fake(manager)
  local ok, setup_err = manager.setup({
    broker = {
      command = { "python", root .. "/tests/fixtures/fake_public_broker.py" },
    },
    providers = { claude = { python = false } },
  })
  assert(ok, vim.inspect(setup_err))
end

local function integration_test()
  vim.cmd.runtime("plugin/agent_manager.lua")
  for _, command in ipairs({
    "AgentManager",
    "AgentManagerAttach",
    "AgentManagerContext",
    "AgentManagerDelete",
    "AgentManagerDiff",
    "AgentManagerFork",
  }) do
    assert_equal(vim.fn.exists(":" .. command), 2, command .. " command")
  end

  local test_file = vim.fn.tempname() .. "-agent-manager-m2.txt"
  vim.fn.writefile({ "disk original" }, test_file)
  vim.env.AGENT_MANAGER_TEST_FILE = test_file
  vim.cmd("edit " .. vim.fn.fnameescape(test_file))
  local source_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(source_buffer, 0, -1, false, { "dirty local edit" })
  vim.bo[source_buffer].modified = true

  local manager = require("agent_manager")
  configure_fake(manager)
  assert(manager.open())
  await("broker handshake", function()
    return manager.status().client.state == "connected"
  end)
  await("external CLI session discovery", function()
    return #(manager.status().model.external_sessions or {}) == 4
  end)
  local external_status = manager.status()
  local agents_buffer = external_status.view.buffers.agents
  assert_equal(manager.list(), {}, "external CLI sessions are not broker-owned agents")
  assert(not buffer_contains(agents_buffer, "workspace/"), "outside directories start collapsed")
  assert(manager.status().view.active_pane == "conversation")
  vim.api.nvim_feedkeys("1", "x", false)
  local function expand_tree(parent, child)
    local row = assert(buffer_line_number(agents_buffer, parent), "missing tree row " .. parent)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys("l", "x", false)
    local expanded = vim.wait(1000, function()
      return buffer_contains(agents_buffer, child)
    end, 10, false)
    if not expanded then
      error(
        "missing tree child "
          .. child
          .. "\n"
          .. table.concat(vim.api.nvim_buf_get_lines(agents_buffer, 0, -1, false), "\n")
      )
    end
  end
  expand_tree("▸ /  [missing]", "workspace/")
  expand_tree("workspace/", "repos/")
  expand_tree("agent-manager/  [missing]", "○ RESUME")
  expand_tree("repos/", "alpha/")
  expand_tree("alpha/", "api/")
  expand_tree("api/", "Codex terminal session")
  expand_tree("web/", "Claude terminal session")
  assert(buffer_contains(agents_buffer, "● ACTIVE"), "active external label")
  assert(buffer_contains(agents_buffer, "○ RESUME"), "resumable external label")
  assert(
    buffer_contains(agents_buffer, "sn new · so open · am model · ae effort"),
    "session action note"
  )

  local sessions = nil
  assert(manager.sessions({ provider = "codex", cwd = "/tmp" }, function(result, err)
    assert_equal(err, nil, "session discovery error")
    sessions = result
  end))
  await("provider session discovery", function()
    return sessions ~= nil
  end)
  assert_equal(sessions.sessions[1].provider_session_id, "codex-resumable-lua", "session id")

  local deleted = nil
  assert(manager.delete_session(sessions.sessions[1], function(result, err)
    assert_equal(err, nil, "session deletion error")
    deleted = result
  end))
  await("provider session deletion", function()
    return deleted ~= nil
  end)
  assert_equal(deleted.worktree_preserved, true, "session deletion preserves files")
  assert_equal(#manager.status().model.external_sessions, 3, "deleted session leaves the tree")

  local external_diff = nil
  assert(manager.workspace_diff("/tmp", function(result, err)
    assert_equal(err, nil, "external workspace diff error")
    external_diff = result
  end))
  await("external workspace diff", function()
    return external_diff ~= nil
  end)
  assert(external_diff.diff:find("+new", 1, true), "external workspace diff result")

  assert(manager.start({ provider = "codex", cwd = "/tmp", workspace_strategy = "shared" }))
  await("agent startup", function()
    local agents = manager.list()
    return agents[1] and agents[1].state == "idle"
  end)
  local agent_id = manager.list()[1].id
  local initial_status = manager.status()
  assert(buffer_contains(initial_status.view.buffers.agents, "CAPABILITIES"), "capability heading")
  assert(buffer_contains(initial_status.view.buffers.agents, "approvals"), "approval capability")
  assert(buffer_contains(initial_status.view.buffers.agents, "shared"), "workspace strategy")

  local Editor = require("agent_manager.editor")
  local context = nil
  Editor.capture("buffer", manager.list()[1], { bufnr = source_buffer }, function(result, err)
    assert_equal(err, nil, "editor context error")
    context = result
  end)
  await("editor context capture", function()
    return context ~= nil
  end)
  assert_equal(context.payload.unsaved, true, "dirty context marker")
  assert_equal(context.payload.text, "dirty local edit", "dirty context snapshot")
  local context_result = nil
  assert(manager.add_context(agent_id, context, function(result, err)
    assert_equal(err, nil, "context queue error")
    context_result = result
  end))
  await("context queue", function()
    return context_result ~= nil
  end)
  assert_equal(context_result.count, 1, "queued context count")

  assert(manager.prompt(agent_id, "interactive question"))
  await("approval request", function()
    local action = manager.status().model.pending_actions["approval-lua-1"]
    return action ~= nil and manager.list()[1].state == "waiting_approval"
  end)
  local approval_status = manager.status()
  assert_equal(approval_status.view.active_pane, "decision", "approval focus")
  assert_equal(
    vim.api.nvim_get_current_buf(),
    approval_status.view.buffers.decision,
    "streaming redraw must preserve decision focus"
  )
  assert_equal(manager.pending_approval_count(), 1, "pending approval count")
  assert(buffer_contains(approval_status.view.buffers.decision, "Provider:  codex"), "approval provider")
  assert(buffer_contains(approval_status.view.buffers.decision, "Workspace: /tmp"), "approval cwd")
  assert(buffer_contains(approval_status.view.buffers.decision, "fixture --write-file"), "approval action")
  assert(buffer_contains(approval_status.view.buffers.decision, test_file), "approval affected path")

  local defer_error = nil
  assert(manager.respond_approval(agent_id, "approval-lua-1", "defer", function(_, err)
    defer_error = err
  end))
  await("unsupported defer response", function()
    return defer_error ~= nil
  end)
  assert(manager.status().model.pending_actions["approval-lua-1"], "failed response must remain pending")

  vim.api.nvim_set_current_buf(approval_status.view.buffers.decision)
  vim.api.nvim_feedkeys("y", "x", false)
  await("clarifying question", function()
    local action = manager.status().model.pending_actions["question-lua-1"]
    return action ~= nil and manager.list()[1].state == "waiting_input"
  end)
  local question_status = manager.status()
  assert_equal(question_status.view.active_pane, "decision", "question focus")
  assert(buffer_contains(question_status.view.buffers.decision, "Which safe mode"), "question text")
  assert(buffer_contains(question_status.view.buffers.decision, "careful"), "question choice")

  local original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  vim.api.nvim_set_current_buf(question_status.view.buffers.decision)
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  vim.ui.select = original_select

  await("interactive completion", function()
    local status = manager.status().model
    return status.agents[1]
      and status.agents[1].state == "completed"
      and status.usage[agent_id]
      and status.file_conflicts[agent_id]
      and status.file_conflicts[agent_id][test_file]
  end)
  local completed = manager.status()
  assert_equal(completed.model.agents[1].title, "interactive question", "shared prompt title")
  assert_equal(completed.model.usage[agent_id].input_tokens, 12, "usage input tokens")
  assert_equal(vim.api.nvim_buf_get_lines(source_buffer, 0, -1, false), {
    "dirty local edit",
  }, "dirty buffer must not be overwritten")
  assert_equal(vim.bo[source_buffer].modified, true, "dirty buffer modified flag")
  assert_equal(#completed.model.pending_order, 0, "human requests resolved")
  assert_equal(manager.pending_approval_count(), 0, "resolved approval count")
  assert(buffer_contains(completed.view.buffers.conversation, "interactive answer"), "conversation response")
  assert(buffer_contains(completed.view.buffers.activity, "input_tokens: 12"), "usage presentation")
  assert(buffer_contains(completed.view.buffers.agents, "dirty buffer conflict"), "conflict presentation")

  local conflict = manager.status().model.file_conflicts[agent_id][test_file]
  local conflict_diff, conflict_error = Editor.conflict_diff(conflict)
  assert_equal(conflict_error, nil, "conflict diff error")
  assert(conflict_diff:find("dirty local edit", 1, true), "conflict diff must include buffer text")

  original_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[#items])
  end
  manager.diff_ui()
  vim.ui.select = original_select
  await("keep-buffer resolution", function()
    return manager.status().model.file_conflicts[agent_id][test_file].resolved == true
  end)
  assert_equal(
    manager.status().model.file_conflicts[agent_id][test_file].resolution,
    "kept_buffer",
    "conflict resolution"
  )

  manager.diff_ui()
  await("workspace diff", function()
    local status = manager.status()
    return status.view.active_pane == "diff" and buffer_contains(status.view.buffers.diff, "+new")
  end)

  local history = nil
  assert(manager.history(agent_id, function(result, err)
    assert_equal(err, nil, "history error")
    history = result
  end))
  await("provider history", function()
    return history ~= nil and manager.status().model.conversations[agent_id][2]
  end)
  assert_equal(manager.status().model.conversations[agent_id][2].text, "historic answer", "history message")

  assert(manager.prompt(agent_id, "second question"))
  await("second active turn", function()
    return manager.list()[1].state == "running"
  end)
  assert(manager.steer(agent_id, "more detail"))
  await("steering delta", function()
    local conversation = manager.status().model.conversations[agent_id]
    for _, message in ipairs(conversation or {}) do
      if message.text and message.text:find("steered", 1, true) then
        return true
      end
    end
    return false
  end)
  assert(manager.interrupt(agent_id))
  await("interrupted state", function()
    return manager.list()[1].state == "interrupted"
  end)

  local forked = nil
  assert(manager.fork(agent_id, function(result, err)
    assert_equal(err, nil, "fork error")
    forked = result
  end))
  await("forked session", function()
    return forked ~= nil and #manager.list() == 2 and manager.list()[2].state == "idle"
  end)
  assert_equal(manager.list()[1].state, "disconnected", "fork source retirement")
  assert(manager.list()[2].provider_session_id:match("%-fork$"), "forked provider session id")

  local status = manager.status()
  for name, buffer in pairs(status.view.buffers) do
    assert(vim.api.nvim_buf_is_valid(buffer), name .. " buffer must be valid")
    assert_equal(vim.bo[buffer].swapfile, false, name .. " buffer swapfile")
    assert_equal(vim.bo[buffer].modeline, false, name .. " buffer modeline")
  end
  local focused_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  await("pane cycling", function()
    return vim.api.nvim_get_current_buf() ~= focused_buffer
  end)
  assert_equal(manager.running_count(), 0, "running agent count")

  manager.close()
  assert_equal(manager.status().view.open, false, "workspace close")
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)
  pcall(vim.api.nvim_buf_delete, source_buffer, { force = true })
  vim.fn.delete(test_file)
end

local function managed_workspace_ui_test()
  local manager = require("agent_manager")
  configure_fake(manager)
  assert(manager.open())
  await("managed broker handshake", function()
    return manager.status().client.state == "connected"
  end)

  local inventory = nil
  assert(manager.workspaces(function(result, err)
    assert_equal(err, nil, "workspace inventory error")
    inventory = result
  end))
  await("workspace inventory", function()
    return inventory ~= nil
  end)
  assert_equal(inventory.repositories[1].base_branch, "bluff", "managed base branch")
  assert_equal(inventory.repositories[1].tasks[1].task_id, "existing-task", "managed task")

  local prompt_input_opened = false
  local original_input = vim.ui.input
  vim.ui.input = function()
    prompt_input_opened = true
  end
  local prompt_ok, prompt_err = manager.prompt_ui()
  vim.ui.input = original_input
  assert_equal(prompt_ok, nil, "prompt without an agent")
  assert_equal(prompt_err.kind, "input", "prompt without an agent error")
  assert_equal(prompt_input_opened, false, "prompt should fail before opening input")

  local original_select = vim.ui.select
  local select_count = 0
  local ui_active = false
  vim.ui.select = function(items, _, callback)
    assert_equal(ui_active, false, "start picker nesting")
    ui_active = true
    select_count = select_count + 1
    callback(items[1])
    ui_active = false
  end
  local input_prompts = {}
  vim.ui.input = function(opts, callback)
    assert_equal(ui_active, false, "start input nesting")
    ui_active = true
    table.insert(input_prompts, opts.prompt)
    if opts.prompt:find("model", 1, true) then
      callback("gpt-fixture")
    else
      assert_equal(opts.prompt, "Prompt: ", "first prompt opens after model selection")
      callback("build the managed feature")
    end
    ui_active = false
  end
  assert(manager.status().model.workspace_repositories[1], "workspace inventory model")
  assert(manager.status().view.active_pane == "conversation")
  manager.start_ui({
    cwd = inventory.repositories[1].canonical_path,
    repository = "agent-manager",
  })
  await("managed agent startup", function()
    local agent = manager.list()[1]
    return agent and agent.state == "completed"
  end)
  vim.ui.select = original_select
  vim.ui.input = original_input

  local agent = manager.list()[1]
  assert_equal(select_count, 1, "new session only asks for a provider")
  assert_equal(#input_prompts, 2, "model selection flows directly to the initial prompt")
  assert(input_prompts[1]:find("New Codex session", 1, true), "model prompt wording")
  assert(not input_prompts[1]:find("name", 1, true), "new sessions do not request a title")
  assert_equal(agent.workspace_strategy, "worktree", "managed strategy")
  assert_equal(agent.managed_workspace.repository, "agent-manager", "managed repository")
  assert(agent.managed_workspace.task_id:match("^session%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d%d%d%d%d%d$"), "generated managed task ID")
  assert_equal(agent.managed_workspace.base_branch, "bluff", "managed task base")
  assert_equal(agent.provider_options.model, "gpt-fixture", "selected model reaches the broker")
  assert_equal(agent.runtime.provider_version, "0.153.0", "actual runtime version")
  local status = manager.status()
  assert(
    buffer_contains(
      status.view.buffers.agents,
      "agent-manager/" .. agent.managed_workspace.task_id
    ),
    "managed task presentation"
  )
  assert(
    buffer_contains(status.view.buffers.agents, "codex-app-server-stable-v1"),
    "runtime profile presentation"
  )
  assert(
    buffer_contains(
      status.view.buffers.conversation,
      agent.managed_workspace.task_id .. " · Codex — gpt-fixture / default"
    ),
    "conversation heading shows title, provider, model, and effort"
  )

  vim.ui.input = function(opts, callback)
    assert(opts.prompt:find("Codex model", 1, true), "am model prompt")
    callback("gpt-switched")
  end
  manager.model_ui()
  vim.ui.select = function(items, _, callback)
    for _, item in ipairs(items) do
      if item == "high" then
        callback(item)
        return
      end
    end
  end
  manager.effort_ui()
  assert(manager.prompt(agent.id, "apply the changed settings"))
  await("changed model and effort", function()
    local current = manager.list()[1]
    return current
      and current.provider_options.model == "gpt-switched"
      and current.provider_options.effort == "high"
  end)
  assert(manager.interrupt(agent.id))
  vim.ui.select = original_select
  vim.ui.input = original_input
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)
end

local function managed_start_uses_focused_layout_without_inventory_test()
  local manager = require("agent_manager")
  configure_fake(manager)
  assert(manager.open())
  await("focused-layout broker handshake", function()
    return manager.status().client.state == "connected"
  end)
  await("focused-layout provider sessions", function()
    return #(manager.status().model.external_sessions or {}) == 4
  end)
  assert_equal(
    manager.status().model.workspace_repositories,
    {},
    "opening the session tree must not run the full workspace audit"
  )

  local original_select = vim.ui.select
  local original_input = vim.ui.input
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  local remembered_model = nil
  vim.ui.input = function(opts, callback)
    if opts.prompt:find("model", 1, true) then
      remembered_model = opts.default
      callback(opts.default)
    else
      callback("inspect the focused layout")
    end
  end

  manager.start_ui({ cwd = root })
  await("focused-layout managed startup", function()
    local agent = manager.list()[1]
    return agent and agent.state == "completed"
  end)

  vim.ui.select = original_select
  vim.ui.input = original_input
  local agent = manager.list()[1]
  assert_equal(remembered_model, "gpt-switched", "new session defaults to the last model")
  assert_equal(agent.managed_workspace.repository, "agent-manager", "focused repository")
  assert(agent.managed_workspace.task_id:match("^session%-"), "focused task uses a generated ID")
  assert_equal(agent.provider_options.effort, "high", "new session defaults to the last effort")
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)
end

local function managed_decision_render_test()
  local Model = require("agent_manager.model")
  local View = require("agent_manager.view")
  local model = Model.new({ max_events = 8 })
  model:apply_state({
    {
      id = "agent-managed",
      provider = "codex",
      provider_session_id = "thread-managed",
      cwd = "/workspace/worktrees/agent-manager/decision-task",
      workspace_strategy = "worktree",
      worktree_path = "/workspace/worktrees/agent-manager/decision-task",
      managed_workspace = {
        repository = "agent-manager",
        task_id = "decision-task",
        branch = "agent/decision-task",
        base_branch = "bluff",
      },
      runtime = {
        compatibility_profile = "codex-app-server-stable-v1",
        provider_version = "0.153.0",
      },
      title = "fixture",
      state = "waiting_approval",
      pending_approvals = 1,
      capabilities = { { name = "approvals", available = true } },
    },
  })
  assert(model:apply_event({
    sequence = 1,
    agent_id = "agent-managed",
    provider = "codex",
    type = "approval.requested",
    payload = {
      id = "approval-managed-1",
      kind = "approval",
      choices = { "allow", "deny" },
      tool_name = "Command",
      summary = "write a managed file",
    },
  }))
  assert_equal(model:focused_action().id, "approval-managed-1", "managed approval projection")

  local denied_action = nil
  local view = View.new(model, {
    deny = function(action)
      denied_action = action.id
    end,
  }, {})
  assert(view:open())
  view:render()
  local decision = view:status().buffers.decision
  assert(
    buffer_contains(decision, "Task:      agent-manager/decision-task"),
    "managed task line in the decision pane"
  )
  assert(buffer_contains(decision, "Strategy:  worktree"), "managed decision strategy")
  vim.api.nvim_set_current_buf(decision)
  vim.api.nvim_feedkeys("n", "x", false)
  assert_equal(denied_action, "approval-managed-1", "n denies the focused request")
  view:teardown()
end

local function resume_test()
  local manager = require("agent_manager")
  configure_fake(manager)
  assert(manager.open())
  await("resume broker handshake", function()
    return manager.status().client.state == "connected"
  end)
  await("all provider sessions", function()
    return #(manager.status().model.external_sessions or {}) == 4
  end)
  local session = nil
  for _, candidate in ipairs(manager.status().model.external_sessions) do
    if candidate.provider_session_id == "claude-resumable-lua" then
      session = candidate
      break
    end
  end
  assert(session, "resumable Claude session must be listed")
  local original_input = vim.ui.input
  local resume_prompt = nil
  vim.ui.input = function(opts, callback)
    resume_prompt = opts.prompt
    callback("continued-session")
  end
  manager.resume_session_ui(session)
  await("specific resume", function()
    local agent = manager.list()[1]
    local conversations = manager.status().model.conversations
    return agent and conversations[agent.id] and conversations[agent.id][2]
  end)
  vim.ui.input = original_input
  local resumed = manager.list()[1]
  assert(resume_prompt:find("Continue Claude Code session", 1, true), "continue-session prompt wording")
  assert_equal(resumed.provider_session_id, "claude-resumable-lua", "specific resume id")
  assert_equal(resumed.workspace_strategy, "worktree", "resumed session workspace strategy")
  assert_equal(resumed.managed_workspace.task_id, "continued-session", "resumed session workspace")
  assert_equal(
    manager.status().model.conversations[resumed.id][2].text,
    "historic answer",
    "resumed history"
  )
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)
end

local function run()
  pure_client_resync_test()
  pure_model_test()
  layout_test()
  workspace_view_navigation_test()
  which_key_prefix_test()
  native_presentation_test()
  public_input_validation_test()
  real_broker_handshake_test()
  durable_reconnect_test()
  managed_workspace_ui_test()
  managed_start_uses_focused_layout_without_inventory_test()
  managed_decision_render_test()
  integration_test()
  resume_test()
  print("Agent Manager Lua M4 tests passed")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
