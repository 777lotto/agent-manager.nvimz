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
end

return M
