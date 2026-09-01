local View = {}
View.__index = View

local pane_names = { "agents", "conversation", "activity" }

local function valid_buffer(buffer)
  return buffer ~= nil and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

local function valid_tab(tab)
  return tab ~= nil and vim.api.nvim_tabpage_is_valid(tab)
end

local function inline(value)
  value = tostring(value or "")
  return value:gsub("%z", "�"):gsub("[\r\n]", " ")
end

local function text_lines(value)
  value = tostring(value or ""):gsub("%z", "�"):gsub("\r", "")
  return vim.split(value, "\n", { plain = true })
end

local function set_window_options(window, wrap)
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].foldcolumn = "0"
  vim.wo[window].list = false
  vim.wo[window].wrap = wrap
  vim.wo[window].cursorline = true
end

function View.layout_for(columns)
  if columns >= 140 then
    return { mode = "wide", visible = { "agents", "conversation", "activity" } }
  end
  if columns >= 90 then
    return { mode = "medium", visible = { "agents", "conversation" } }
  end
  return { mode = "narrow", visible = { "conversation" } }
end

function View.new(model, actions, opts)
  local self = setmetatable({
    model = model,
    actions = actions or {},
    opts = opts or {},
    buffers = {},
    windows = {},
    tab = nil,
    mode = nil,
    active_pane = "conversation",
    pane_index = 2,
    agent_rows = {},
    namespace = vim.api.nvim_create_namespace("AgentManagerView"),
    render_pending = false,
  }, View)
  self:_define_highlights()
  self:_create_autocmds()
  return self
end

function View:_define_highlights()
  local links = {
    AgentManagerNormal = "Normal",
    AgentManagerTitle = "Title",
    AgentManagerSelection = "CursorLine",
    AgentManagerMuted = "Comment",
    AgentManagerProviderCodex = "Identifier",
    AgentManagerProviderClaude = "Type",
    AgentManagerStatusRunning = "DiagnosticInfo",
    AgentManagerStatusSuccess = "DiagnosticOk",
    AgentManagerStatusFailure = "DiagnosticError",
    AgentManagerStatusInterrupted = "DiagnosticWarn",
    AgentManagerMessageUser = "Special",
    AgentManagerMessageAssistant = "Normal",
    AgentManagerTool = "Function",
    AgentManagerHelpKey = "Special",
    AgentManagerHelpDescription = "Comment",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { default = true, link = target })
  end
end

function View:_create_autocmds()
  self.augroup = vim.api.nvim_create_augroup("AgentManagerView", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.augroup,
    callback = function()
      self:_define_highlights()
      self:schedule_render()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      vim.schedule(function()
        if valid_tab(self.tab) and vim.api.nvim_get_current_tabpage() == self.tab then
          local next_mode = View.layout_for(vim.o.columns).mode
          if next_mode ~= self.mode then
            self:_build_layout()
            self:render()
          end
        end
      end)
    end,
  })
end

function View:_buffer(name)
  if valid_buffer(self.buffers[name]) then
    return self.buffers[name]
  end
  local buffer = vim.api.nvim_create_buf(false, true)
  self.buffers[name] = buffer
  pcall(vim.api.nvim_buf_set_name, buffer, "agent-manager://" .. name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].modeline = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = "agent-manager-" .. name
  self:_map_buffer(buffer)
  return buffer
end

function View:_map_buffer(buffer)
  local map_opts = function(description)
    return { buffer = buffer, silent = true, nowait = true, desc = description }
  end
  vim.keymap.set("n", "<Tab>", function()
    self:cycle(1)
  end, map_opts("Agent Manager: next pane"))
  vim.keymap.set("n", "<S-Tab>", function()
    self:cycle(-1)
  end, map_opts("Agent Manager: previous pane"))
  vim.keymap.set("n", "q", function()
    self:close()
  end, map_opts("Agent Manager: close workspace"))
  vim.keymap.set("n", "<CR>", function()
    self:_activate_row()
  end, map_opts("Agent Manager: select item"))
  vim.keymap.set("n", "n", function()
    if self.actions.start then
      self.actions.start()
    end
  end, map_opts("Agent Manager: start agent"))
  vim.keymap.set("n", "p", function()
    if self.actions.prompt then
      self.actions.prompt()
    end
  end, map_opts("Agent Manager: prompt"))
  vim.keymap.set("n", "s", function()
    if self.actions.steer then
      self.actions.steer()
    end
  end, map_opts("Agent Manager: steer"))
  vim.keymap.set("n", "x", function()
    if self.actions.interrupt then
      self.actions.interrupt()
    end
  end, map_opts("Agent Manager: interrupt"))
  vim.keymap.set("n", "r", function()
    if self.actions.refresh then
      self.actions.refresh()
    end
  end, map_opts("Agent Manager: refresh"))
  vim.keymap.set("n", "?", function()
    self:show_help()
  end, map_opts("Agent Manager: help"))
end

function View:open()
  if valid_tab(self.tab) then
    vim.api.nvim_set_current_tabpage(self.tab)
    self:render()
    return true
  end
  for _, name in ipairs(pane_names) do
    self:_buffer(name)
  end
  vim.cmd("tabnew")
  self.tab = vim.api.nvim_get_current_tabpage()
  self:_build_layout()
  self:render()
  return true
end

function View:_build_layout()
  if not valid_tab(self.tab) or vim.api.nvim_get_current_tabpage() ~= self.tab then
    return
  end
  local tab_windows = vim.api.nvim_tabpage_list_wins(self.tab)
  local main = tab_windows[1]
  if not valid_window(main) then
    return
  end
  vim.api.nvim_set_current_win(main)
  for index = 2, #tab_windows do
    if valid_window(tab_windows[index]) then
      pcall(vim.api.nvim_win_close, tab_windows[index], true)
    end
  end
  self.windows = { conversation = main }
  vim.api.nvim_win_set_buf(main, self:_buffer("conversation"))
  set_window_options(main, true)
  local layout = View.layout_for(vim.o.columns)
  self.mode = layout.mode

  if layout.mode == "wide" or layout.mode == "medium" then
    vim.api.nvim_set_current_win(main)
    vim.cmd("topleft vertical split")
    local agents = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(agents, self:_buffer("agents"))
    vim.api.nvim_win_set_width(agents, self.opts.agent_width or 28)
    vim.wo[agents].winfixwidth = true
    set_window_options(agents, false)
    self.windows.agents = agents
  end
  if layout.mode == "wide" then
    vim.api.nvim_set_current_win(main)
    vim.cmd("botright vertical split")
    local activity = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(activity, self:_buffer("activity"))
    vim.api.nvim_win_set_width(activity, self.opts.activity_width or 38)
    vim.wo[activity].winfixwidth = true
    set_window_options(activity, true)
    self.windows.activity = activity
  end
  vim.api.nvim_set_current_win(main)
  self.active_pane = "conversation"
  self.pane_index = 2
end

function View:cycle(direction)
  if not valid_tab(self.tab) then
    return
  end
  self.pane_index = ((self.pane_index - 1 + direction) % #pane_names) + 1
  local pane = pane_names[self.pane_index]
  self.active_pane = pane
  local window = self.windows[pane]
  if valid_window(window) then
    vim.api.nvim_win_set_buf(window, self:_buffer(pane))
    vim.api.nvim_set_current_win(window)
    return
  end
  local content = self.windows.conversation
  if not valid_window(content) then
    content = vim.api.nvim_tabpage_list_wins(self.tab)[1]
  end
  if valid_window(content) then
    vim.api.nvim_win_set_buf(content, self:_buffer(pane))
    self.windows.conversation = content
    vim.api.nvim_set_current_win(content)
    set_window_options(content, pane ~= "agents")
  end
end

function View:_activate_row()
  local buffer = vim.api.nvim_get_current_buf()
  if buffer ~= self.buffers.agents then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local agent_id = self.agent_rows[row]
  if agent_id and self.model:select(agent_id) then
    self:render()
  end
end

function View:schedule_render()
  if self.render_pending then
    return
  end
  self.render_pending = true
  vim.schedule(function()
    self.render_pending = false
    self:render()
  end)
end

function View:render()
  if not valid_tab(self.tab) then
    return
  end
  self:_render_agents()
  self:_render_conversation()
  self:_render_activity()
end

function View:_set_lines(name, lines, highlights)
  local buffer = self:_buffer(name)
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(buffer, self.namespace, 0, -1)
  for _, highlight in ipairs(highlights or {}) do
    pcall(
      vim.api.nvim_buf_add_highlight,
      buffer,
      self.namespace,
      highlight.group,
      highlight.line - 1,
      highlight.start or 0,
      highlight.finish or -1
    )
  end
end

function View:_render_agents()
  local lines = { " AGENTS", " broker: " .. inline(self.model.client_state), "" }
  local highlights = {
    { line = 1, group = "AgentManagerTitle" },
    { line = 2, group = "AgentManagerMuted" },
  }
  self.agent_rows = {}
  local agents = self.model:list()
  if #agents == 0 then
    table.insert(lines, " No agents. Press n to start one.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end
  for _, agent in ipairs(agents) do
    local selected = agent.id == self.model.selected_agent_id and ">" or " "
    local provider = string.upper(inline(agent.provider))
    local line = string.format("%s %-6s %-11s %s", selected, provider, inline(agent.state), inline(agent.title))
    table.insert(lines, line)
    self.agent_rows[#lines] = agent.id
    table.insert(highlights, {
      line = #lines,
      group = agent.provider == "claude" and "AgentManagerProviderClaude"
        or "AgentManagerProviderCodex",
    })
  end
  self:_set_lines("agents", lines, highlights)
end

function View:_render_conversation()
  local agent = self.model:selected_agent()
  local title = agent and (inline(agent.provider) .. " · " .. inline(agent.state)) or "no agent selected"
  local lines = { " CONVERSATION", " " .. title, "" }
  local highlights = {
    { line = 1, group = "AgentManagerTitle" },
    { line = 2, group = "AgentManagerMuted" },
  }
  local messages = self.model:conversation()
  if #messages == 0 then
    table.insert(lines, " Press p to compose a prompt.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end
  for _, message in ipairs(messages) do
    local label = message.role == "user" and " YOU" or " ASSISTANT"
    if message.kind == "steer" then
      label = " YOU · STEER"
    end
    table.insert(lines, label)
    table.insert(highlights, {
      line = #lines,
      group = message.role == "user" and "AgentManagerMessageUser"
        or "AgentManagerMessageAssistant",
    })
    for _, line in ipairs(text_lines(message.text)) do
      table.insert(lines, " " .. line)
    end
    if message.streaming then
      table.insert(lines, " …")
      table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
    end
    table.insert(lines, "")
  end
  self:_set_lines("conversation", lines, highlights)
end

function View:_render_activity()
  local lines = { " ACTIVITY", "" }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  local activity = self.model:activity()
  if #activity == 0 then
    table.insert(lines, " Tool and provider activity appears here.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end
  for _, entry in ipairs(activity) do
    table.insert(lines, string.format(" %04d  %s", entry.sequence or 0, inline(entry.type)))
    table.insert(highlights, { line = #lines, group = "AgentManagerTool" })
    if entry.detail and entry.detail ~= "" then
      for _, line in ipairs(text_lines(entry.detail)) do
        table.insert(lines, "       " .. line)
      end
    end
  end
  self:_set_lines("activity", lines, highlights)
end

function View:show_help()
  local lines = {
    " HELP",
    "",
    " n       start agent",
    " p       prompt selected agent",
    " s       steer active turn",
    " x       interrupt active turn",
    " r       refresh agent state",
    " <Tab>   cycle panes",
    " <CR>    select agent",
    " q       close workspace",
  }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  for line = 3, #lines do
    table.insert(highlights, { line = line, group = "AgentManagerHelpDescription" })
  end
  self:_set_lines("activity", lines, highlights)
  local activity_index = 3
  self.pane_index = activity_index - 1
  self:cycle(1)
end

function View:close()
  if not valid_tab(self.tab) then
    self.tab = nil
    return true
  end
  local number = vim.api.nvim_tabpage_get_number(self.tab)
  pcall(vim.cmd, "tabclose " .. number)
  self.tab = nil
  self.windows = {}
  return true
end

function View:teardown()
  self:close()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for _, buffer in pairs(self.buffers) do
    if valid_buffer(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  self.buffers = {}
end

function View:status()
  return {
    open = valid_tab(self.tab),
    mode = self.mode,
    active_pane = self.active_pane,
    buffers = vim.deepcopy(self.buffers),
  }
end

return View
