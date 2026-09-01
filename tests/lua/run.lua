local root = assert(vim.env.AGENT_MANAGER_TEST_ROOT, "AGENT_MANAGER_TEST_ROOT is required")
vim.opt.runtimepath:prepend(root)
vim.cmd("helptags " .. vim.fn.fnameescape(root .. "/doc"))

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
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

local function pure_model_test()
  local Model = require("agent_manager.model")
  local model = Model.new({ max_events = 4 })
  model:apply_state({
    {
      id = "agent-1",
      provider = "codex",
      title = "fixture",
      state = "idle",
      pending_approvals = 0,
    },
  })
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
  assert_equal(model:conversation()[2].text, "answer", "assistant delta projection")
  assert_equal(model:activity()[1].type, "tool.started", "activity projection")
  local snapshot = model:snapshot()
  snapshot.agents[1].state = "corrupted"
  assert_equal(model:list()[1].state, "idle", "snapshots must be defensive")
end

local function layout_test()
  local View = require("agent_manager.view")
  assert_equal(View.layout_for(160).mode, "wide", "wide layout")
  assert_equal(View.layout_for(100).mode, "medium", "medium layout")
  assert_equal(View.layout_for(80).mode, "narrow", "narrow layout")
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

local function integration_test()
  vim.cmd.runtime("plugin/agent_manager.lua")
  assert_equal(vim.fn.exists(":AgentManager"), 2, "AgentManager command")

  local manager = require("agent_manager")
  local ok, setup_err = manager.setup({
    broker = {
      command = { "python", root .. "/tests/fixtures/fake_public_broker.py" },
    },
    providers = { claude = { python = false } },
  })
  assert(ok, vim.inspect(setup_err))
  assert(manager.open())
  await("broker handshake", function()
    return manager.status().client.state == "connected"
  end)

  assert(manager.start({ provider = "codex", cwd = "/tmp", workspace_strategy = "shared" }))
  await("agent startup", function()
    local agents = manager.list()
    return agents[1] and agents[1].state == "idle"
  end)
  local agent_id = manager.list()[1].id

  assert(manager.prompt(agent_id, "first question"))
  await("first completed response", function()
    local status = manager.status().model
    return status.agents[1]
      and status.agents[1].state == "completed"
      and status.conversations[agent_id]
      and status.conversations[agent_id][2]
      and status.conversations[agent_id][2].text == "hello world"
  end)
  local status = manager.status()
  assert_equal(status.model.activities[agent_id][1].type, "tool.started", "streamed tool activity")
  for name, buffer in pairs(status.view.buffers) do
    assert(vim.api.nvim_buf_is_valid(buffer), name .. " buffer must be valid")
    assert_equal(vim.bo[buffer].swapfile, false, name .. " buffer swapfile")
    assert_equal(vim.bo[buffer].modeline, false, name .. " buffer modeline")
  end
  assert(buffer_contains(status.view.buffers.conversation, "hello world"), "conversation was not rendered")
  assert(buffer_contains(status.view.buffers.activity, "tool.started"), "activity was not rendered")
  local focused_buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
  await("pane cycling", function()
    return vim.api.nvim_get_current_buf() ~= focused_buffer
  end)

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
  assert_equal(manager.running_count(), 0, "running agent count")
  assert_equal(manager.pending_approval_count(), 0, "pending approvals")
  assert(manager.status().model.last_sequence >= 7, "event sequence did not advance")

  manager.close()
  assert_equal(manager.status().view.open, false, "workspace close")
  assert_equal(#vim.api.nvim_list_tabpages(), 1, "workspace tab cleanup")
  manager.teardown()
  vim.wait(500, function()
    return false
  end, 25, false)
end

local function run()
  pure_model_test()
  layout_test()
  real_broker_handshake_test()
  integration_test()
  print("Agent Manager Lua tests passed")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
