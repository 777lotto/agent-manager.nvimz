local M = {}

local function executable(command)
  if type(command) ~= "table" or type(command[1]) ~= "string" then
    return false
  end
  return vim.fn.executable(command[1]) == 1
end

function M.check()
  vim.health.start("agent-manager")
  local version = vim.version()
  if version.major > 0 or version.minor >= 11 then
    vim.health.ok("Neovim " .. tostring(version))
  else
    vim.health.error("Neovim 0.11 or newer is required")
  end

  local manager = require("agent_manager")
  local health = manager.health()
  local broker = health.broker or {}
  if executable(broker.command) then
    vim.health.ok("broker executable: " .. broker.command[1])
  else
    vim.health.error("broker executable is not available", {
      "Build agent-manager-broker or configure broker.command with an installed artifact.",
    })
  end
  vim.health.info("broker mode: " .. tostring(health.mode or "unknown"))
  vim.health.info("broker state: " .. tostring(broker.state or "stopped"))
  if broker.initialized then
    vim.health.ok(
      "public protocol "
        .. tostring(broker.initialized.protocol_version)
        .. ", broker "
        .. tostring(broker.initialized.broker_version)
    )
  end
  if health.claude_python then
    if vim.fn.executable(health.claude_python) == 1 then
      vim.health.ok("Claude worker Python: " .. health.claude_python)
    else
      vim.health.warn("configured Claude worker Python is not executable")
    end
  else
    vim.health.warn("Claude worker Python was not discovered", {
      "Run mise run setup or configure providers.claude.python.",
    })
  end
  if broker.last_error then
    vim.health.warn("last client error: " .. tostring(broker.last_error.message))
  end

  local ux = health.ux or {}
  local foundation = ux.foundation or {}
  if foundation.registered then
    vim.health.ok(
      "UX Foundation schema "
        .. tostring(foundation.contract_version)
        .. " registration: agent.manager"
    )
  elseif foundation.available then
    if foundation.contract_version
      and foundation.contract_version ~= foundation.expected_contract_version
    then
      vim.health.warn(
        "UX Foundation contract mismatch: expected "
          .. tostring(foundation.expected_contract_version)
          .. ", found "
          .. tostring(foundation.contract_version)
      )
    else
      vim.health.info("UX Foundation is available; Agent Manager is not currently registered")
    end
  else
    vim.health.info("UX Foundation is absent; native AgentManager* fallbacks are available")
  end
  if foundation.error then
    vim.health.warn("UX Foundation registration: " .. tostring(foundation.error))
  end

  local styling = ux.styling or {}
  if not styling.descriptor_available or not styling.pure then
    vim.health.warn("UX Styling adapter descriptor is unavailable")
  elseif styling.available then
    vim.health.ok("UX Styling adapter is discoverable and side-effect free")
  else
    vim.health.info("UX Styling is not installed; the pure adapter descriptor is ready")
  end

  local chrome = ux.chrome or {}
  if chrome.available then
    vim.health.ok("UX Chrome coexistence support is available")
  else
    vim.health.info("UX Chrome is not installed")
  end
  if chrome.segment_available then
    vim.health.ok("UX Chrome public segment integration is available")
  else
    vim.health.info("no public Chrome segment API; cached Agent Manager status remains available")
  end

  local panels = ux.panels or {}
  if panels.available then
    vim.health.info("UX Panels is present; Agent Manager is using the " .. tostring(panels.backend) .. " backend")
  else
    vim.health.info("UX Panels is unavailable; Agent Manager is using the native view backend")
  end
end

return M
