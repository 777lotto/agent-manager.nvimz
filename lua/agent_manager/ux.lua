local Presentation = require("agent_manager.presentation")

local UX = {}
UX.__index = UX

local function copy(value)
  return vim.deepcopy(value)
end

local function describe(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err or "unknown error")
end

local function raw_highlight(group)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, {
    name = group,
    link = true,
    create = false,
  })
  return ok and copy(value) or {}
end

local function module_paths(pattern)
  return vim.api.nvim_get_runtime_file(pattern, true)
end

local function module_present(pattern)
  return #module_paths(pattern) > 0
end

local function foundation_has_registration(foundation)
  if type(foundation) ~= "table" or type(foundation.health_report) ~= "function" then
    return false
  end
  local ok, reports = pcall(foundation.health_report)
  if not ok then
    return false
  end
  for _, report in ipairs(reports or {}) do
    if report.plugin_id == Presentation.plugin_id then
      return true
    end
  end
  return false
end

local function styling_has_registration()
  local styling = package.loaded["ux_styling"]
  if type(styling) ~= "table" or type(styling.adapters) ~= "function" then
    return false
  end
  local ok, adapters = pcall(styling.adapters)
  if not ok or type(adapters) ~= "table" then
    return false
  end
  for _, entry in ipairs(adapters.external or {}) do
    if entry.plugin_id == Presentation.plugin_id and entry.registered == true then
      return true
    end
  end
  return false
end

function UX.detect()
  local foundation = package.loaded["ux_foundation"]
  local chrome = package.loaded["ux_chrome"]
  local panels_available = module_present("lua/ux_panels/init.lua")
  local foundation_registered = foundation_has_registration(foundation)
  return {
    foundation = {
      available = type(foundation) == "table" or module_present("lua/ux_foundation/init.lua"),
      contract_version = type(foundation) == "table" and foundation.contract_version or nil,
      expected_contract_version = Presentation.contract_version,
      registered = foundation_registered,
      plugin_id = Presentation.plugin_id,
    },
    styling = {
      adapter = "ux_styling_adapter.agent_manager",
      available = module_present("lua/ux_styling/init.lua"),
      descriptor_available = module_present("lua/ux_styling_adapter/agent_manager.lua"),
      loaded = package.loaded["ux_styling"] ~= nil,
      pure = true,
    },
    chrome = {
      available = type(chrome) == "table" or module_present("lua/ux_chrome/init.lua"),
      loaded = type(chrome) == "table",
      segment_available = type(chrome) == "table" and type(chrome.register_segment) == "function",
      cached_status_available = true,
    },
    panels = {
      available = panels_available,
      backend = "native",
      reason = panels_available and "adapter not adopted" or "ux.panels is not available",
    },
    native_fallback = false,
  }
end

function UX.new()
  local self = setmetatable({
    augroup = nil,
    foundation = nil,
    foundation_handle = nil,
    foundation_handle_owned = false,
    foundation_error = nil,
    foundation_contract = nil,
    native_baselines = {},
    native_active = false,
  }, UX)
  self:_register_foundation()
  if not self.foundation_handle then
    self:_apply_native(true)
  end
  self:_create_autocmds()
  return self
end

function UX:_register_foundation()
  local loaded, foundation = pcall(require, "ux_foundation")
  if not loaded then
    self.foundation_error = module_present("lua/ux_foundation/init.lua")
        and ("UX Foundation failed to load: " .. describe(foundation))
      or nil
    return false
  end
  self.foundation_contract = foundation.contract_version
  if foundation.contract_version ~= Presentation.contract_version then
    self.foundation_error = ("UX Foundation contract %s is incompatible with schema %s"):format(
      tostring(foundation.contract_version),
      tostring(Presentation.contract_version)
    )
    return false
  end
  local already_registered = foundation_has_registration(foundation)
  local handle, err = foundation.register(Presentation.manifest(), Presentation.implementation())
  if not handle then
    self.foundation_error = describe(err)
    return false
  end
  self.foundation = foundation
  self.foundation_handle = handle
  self.foundation_handle_owned = not already_registered
  self.foundation_error = nil
  return true
end

function UX:_apply_native(refresh_baseline)
  for _, link in ipairs(Presentation.native_links()) do
    local current = raw_highlight(link.group)
    local is_our_fallback = current.link == link.target
    if self.native_baselines[link.group] == nil or (refresh_baseline and not is_our_fallback) then
      self.native_baselines[link.group] = current
    end
    vim.api.nvim_set_hl(0, link.group, {
      default = true,
      link = link.target,
    })
  end
  self.native_active = true
end

function UX:_create_autocmds()
  self.augroup = vim.api.nvim_create_augroup("AgentManagerPresentation", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.augroup,
    callback = function()
      if not self.foundation_handle then
        self:_apply_native(true)
      end
    end,
    desc = "Replay Agent Manager native presentation fallbacks",
  })
end

function UX:refresh()
  if self.foundation_handle then
    local ok, err = self.foundation.refresh(self.foundation_handle)
    if not ok then
      self.foundation_error = describe(err)
      return false, err
    end
    self.foundation_error = nil
    return true
  end
  if self:_register_foundation() then
    return true
  end
  self:_apply_native(false)
  return false, self.foundation_error
end

function UX:status()
  local status = UX.detect()
  status.foundation.contract_version = self.foundation_contract
  status.foundation.registered = self.foundation_handle ~= nil
  status.foundation.error = self.foundation_error
  status.native_fallback = self.native_active
  return status
end

function UX:teardown()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  local ok = true
  local err = nil
  if self.foundation and self.foundation_handle then
    local registration_is_shared = not self.foundation_handle_owned or styling_has_registration()
    if not registration_is_shared then
      ok, err = self.foundation.unregister(self.foundation_handle)
    end
    if ok then
      self.foundation_handle = nil
      self.foundation_handle_owned = false
    else
      self.foundation_error = describe(err)
    end
  end
  if ok and self.native_active and not foundation_has_registration(self.foundation) then
    for _, link in ipairs(Presentation.native_links()) do
      vim.api.nvim_set_hl(0, link.group, copy(self.native_baselines[link.group] or {}))
    end
    self.native_baselines = {}
    self.native_active = false
  end
  return ok, err
end

return UX
