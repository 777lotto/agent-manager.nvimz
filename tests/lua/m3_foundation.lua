local h = require("tests.lua.m3_helpers")

local root = h.root("AGENT_MANAGER_TEST_ROOT")
local foundation_root = h.root("UX_FOUNDATION_ROOT")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(foundation_root)

local foundation = require("ux_foundation")
local manager = require("agent_manager")
local presentation = require("agent_manager.presentation")

h.finish(function()
  foundation._reset_for_tests()
  local baseline = {}
  for _, link in ipairs(presentation.native_links()) do
    baseline[link.group] = h.raw_highlight(link.group)
  end

  foundation.setup({
    core = true,
    lifecycle = true,
    load_active = false,
    strict = true,
    strict_ownership = true,
    storage_dir = vim.fn.tempname() .. "-agent-manager-foundation",
  })
  h.truthy(manager.setup({
    broker = { command = { "python", root .. "/tests/fixtures/fake_public_broker.py" } },
    providers = { claude = { python = false } },
  }))

  local health = manager.health()
  h.equal(health.ux.foundation.contract_version, 1, "Foundation contract")
  h.equal(health.ux.foundation.registered, true, "Foundation registration")
  h.equal(health.ux.native_fallback, false, "Foundation mode must not install native fallback writes")
  h.equal(manager.status().client.state, "stopped", "presentation setup must not start the broker")

  local registration = h.truthy(
    h.registration(foundation, "agent.manager"),
    "Foundation omitted agent.manager"
  )
  h.equal(registration.manifest.plugin, presentation.manifest().plugin, "immutable plugin identity")
  h.equal(#registration.manifest.components, 10, "component catalog")
  for _, component in ipairs(registration.manifest.components) do
    h.equal(
      registration.availability[component.id].available,
      true,
      "component unavailable: " .. component.id
    )
    local fixture = h.truthy(
      foundation.fixture(component.preview.fixture_id),
      "fixture unavailable: " .. component.preview.fixture_id
    )
    h.equal(fixture.component_id, component.id, "fixture component identity")
  end
  for _, report in ipairs(foundation.health_report() or {}) do
    if report.plugin_id == "agent.manager" then
      h.equal(report.unmet, {}, "unmet manifest references")
      h.equal(report.unavailable, {}, "unavailable manifest components")
    end
  end

  local property_id = "agent.manager/status/running/foreground"
  local inspected = h.truthy(foundation.inspect(property_id), "running status property")
  h.equal(inspected.resolved, { kind = "rgb", value = "#8AADF4" }, "semantic token resolution")
  h.equal(h.raw_highlight("AgentManagerStatusRunning").fg, 0x8AADF4, "managed status group")

  local transaction = h.truthy(foundation.begin_transaction())
  h.truthy(transaction:stage(property_id, { kind = "rgb", value = "#123456" }))
  h.truthy(transaction:commit())
  local generation = foundation.state().generation
  for _, link in ipairs(presentation.native_links()) do
    vim.api.nvim_set_hl(0, link.group, {})
  end
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "agent-manager-one", modeline = false })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "agent-manager-two", modeline = false })
  h.await("coalesced Foundation replay", function()
    return foundation.state().generation > generation
  end)
  h.equal(foundation.state().generation, generation + 1, "ColorScheme replay generation")
  h.equal(h.raw_highlight("AgentManagerStatusRunning").fg, 0x123456, "profile replay")

  h.truthy(manager.teardown())
  h.equal(h.registration(foundation, "agent.manager"), nil, "runtime must unregister only its handle")
  for group, value in pairs(baseline) do
    h.equal(h.raw_highlight(group), value, "highlight restoration: " .. group)
  end
  foundation._reset_for_tests()
  print("Agent Manager M3 Foundation integration passed")
end)
