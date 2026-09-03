local presentation = require("agent_manager.presentation")

local M = {}

function M.probe()
  return {
    available = true,
    capabilities = {
      callback_free_fixtures = true,
      offline_preview = true,
      schema_version = presentation.contract_version,
    },
  }
end

function M.new(_)
  return presentation.manifest(), presentation.implementation()
end

return M
