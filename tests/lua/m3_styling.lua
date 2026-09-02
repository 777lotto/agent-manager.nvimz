local h = require("tests.lua.m3_helpers")

local root = h.root("AGENT_MANAGER_TEST_ROOT")
local foundation_root = h.root("UX_FOUNDATION_ROOT")
local styling_root = h.root("UX_STYLING_ROOT")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(foundation_root)
vim.opt.runtimepath:prepend(styling_root)

local foundation = require("ux_foundation")
local styling = require("ux_styling")

h.finish(function()
  foundation._reset_for_tests()
  styling._reset_for_tests()

  local descriptor = require("ux_styling_adapter.agent_manager")
  local before_buffers = #vim.api.nvim_list_bufs()
  local original_readfile = vim.fn.readfile
  local original_system = vim.system
  local original_spawn = vim.uv.spawn
  local original_open = io.open
  vim.fn.readfile = function()
    error("adapter attempted filesystem input")
  end
  vim.system = function()
    error("adapter attempted a child process")
  end
  vim.uv.spawn = function()
    error("adapter attempted a provider process")
  end
  io.open = function()
    error("adapter attempted file I/O")
  end
  local manifest, implementation = descriptor.new({ enabled = true })
  vim.fn.readfile = original_readfile
  vim.system = original_system
  vim.uv.spawn = original_spawn
  io.open = original_open

  h.equal(manifest.plugin.id, "agent.manager", "adapter plugin identity")
  h.equal(manifest.schema_version, 1, "adapter schema")
  h.equal(#vim.api.nvim_list_bufs(), before_buffers, "pure adapter created a buffer")
  h.equal(package.loaded["agent_manager"], nil, "adapter loaded the agent runtime")
  h.equal(package.loaded["agent_manager.client"], nil, "adapter loaded the broker client")
  h.equal(package.loaded["agent_manager.model"], nil, "adapter loaded the domain model")
  h.equal(
    implementation.capabilities.presentation_available().available,
    true,
    "side-effect-free availability probe"
  )
  h.equal(manifest, descriptor.new({ enabled = true }), "adapter manifest must be deterministic")

  local foundation_opts = {
    core = false,
    lifecycle = false,
    load_active = false,
    strict = true,
    storage_dir = vim.fn.tempname() .. "-agent-manager-styling",
  }
  foundation.setup(foundation_opts)
  styling.setup({
    discover_adapters = true,
    foundation = foundation_opts,
    raw_browser = false,
  })
  local workspace = h.truthy(styling.open(), "Styling workspace failed to open")
  workspace:render()

  local external
  for _, item in ipairs(styling.adapters().external or {}) do
    if item.name == "agent_manager" then
      external = item
      break
    end
  end
  h.truthy(external and external.registered, "Styling did not discover agent_manager")
  h.equal(package.loaded["agent_manager"], nil, "Styling discovery initialized the runtime")
  local registration = h.truthy(
    h.registration(foundation, "agent.manager"),
    "Styling did not register agent.manager"
  )
  h.equal(#registration.fixture_ids, 10, "registered deterministic fixtures")
  local tree = h.truthy(h.tree_root(workspace.tree, "agent.manager"), "Styling omitted Agent Manager")
  h.equal(tree.depth, 0, "Agent Manager category depth")

  local preview = require("ux_styling.render.preview")
  local fixture = preview.plugin_fixture(tree, {
    inspect = function(property_id)
      return foundation.inspect(property_id)
    end,
    max_lines = 16,
  })
  local rendered = preview.render(fixture, { width = 160 })
  local text = table.concat(rendered.lines, "\n")
  h.truthy(text:find("Application Shell", 1, true), "preview omitted shell component")
  local saw_agent_group = false
  for _, span in ipairs(rendered.spans or {}) do
    if type(span.hl_group) == "string" and span.hl_group:match("^AgentManager") then
      saw_agent_group = true
      break
    end
  end
  h.truthy(saw_agent_group, "preview omitted AgentManager semantic groups")

  styling.close()
  local manager = require("agent_manager")
  h.truthy(manager.setup({
    broker = { command = { "python", root .. "/tests/fixtures/fake_public_broker.py" } },
    providers = { claude = { python = false } },
  }))
  local registration_count = 0
  for _, item in ipairs(foundation.registrations()) do
    if item.manifest.plugin.id == "agent.manager" then
      registration_count = registration_count + 1
    end
  end
  h.equal(registration_count, 1, "runtime duplicated Styling's manifest registration")
  h.truthy(manager.teardown())
  h.truthy(
    h.registration(foundation, "agent.manager"),
    "runtime teardown removed Styling's shared registration"
  )
  styling._reset_for_tests()
  foundation._reset_for_tests()

  foundation.setup(foundation_opts)
  h.truthy(manager.setup({
    broker = { command = { "python", root .. "/tests/fixtures/fake_public_broker.py" } },
    providers = { claude = { python = false } },
  }))
  styling.setup({
    discover_adapters = true,
    foundation = foundation_opts,
    raw_browser = false,
  })
  h.truthy(styling.open(), "Styling failed to discover the runtime-owned manifest")
  styling.close()
  h.truthy(manager.teardown())
  h.truthy(
    h.registration(foundation, "agent.manager"),
    "runtime teardown removed a later Styling registration"
  )
  styling._reset_for_tests()
  foundation._reset_for_tests()
  print("Agent Manager M3 Styling discovery passed")
end)
