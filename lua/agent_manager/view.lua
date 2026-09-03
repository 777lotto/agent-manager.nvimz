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

local function action_has_choice(action, choice)
  for _, candidate in ipairs(action and action.payload.choices or {}) do
    if candidate == choice then
      return true
    end
  end
  return false
end

local function usage_lines(value, prefix, lines, depth)
  if depth > 4 or #lines >= 16 then
    return
  end
  if type(value) ~= "table" then
    table.insert(lines, string.format(" %s: %s", prefix, inline(value)))
    return
  end
  local keys = vim.tbl_keys(value)
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  for _, key in ipairs(keys) do
    local next_prefix = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
    usage_lines(value[key], next_prefix, lines, depth + 1)
    if #lines >= 16 then
      break
    end
  end
end

local function sorted_keys(values)
  local keys = vim.tbl_keys(values)
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

local function directory_parts(path, home)
  local normalized = tostring(path or ""):gsub("\\", "/")
  normalized = normalized ~= "/" and normalized:gsub("/+$", "") or normalized
  local normalized_home = tostring(home or ""):gsub("\\", "/"):gsub("/+$", "")
  local root = "/"
  local remainder = normalized:gsub("^/+", "")
  if normalized_home ~= "" and (normalized == normalized_home or normalized:sub(1, #normalized_home + 1) == normalized_home .. "/") then
    root = "~"
    remainder = normalized:sub(#normalized_home + 1):gsub("^/+", "")
  else
    local drive, rest = normalized:match("^([A-Za-z]:)/?(.*)$")
    if drive then
      root = drive
      remainder = rest
    elseif normalized:sub(1, 1) ~= "/" then
      root = "(unknown)"
      remainder = normalized
    end
  end
  local parts = {}
  for part in remainder:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  local root_path = root
  if root == "~" then
    root_path = normalized_home
  end
  return root, root_path, parts
end

local function join_path(parent, child)
  if parent == "/" then
    return "/" .. child
  end
  return tostring(parent):gsub("/+$", "") .. "/" .. child
end

local function tree_node(roots, path, home)
  local root_name, root_path, parts = directory_parts(path, home)
  roots[root_name] = roots[root_name]
    or { path = root_path, directories = {}, sessions = {} }
  local node = roots[root_name]
  for _, part in ipairs(parts) do
    node.directories[part] = node.directories[part]
      or {
        path = join_path(node.path, part),
        directories = {},
        sessions = {},
      }
    node = node.directories[part]
  end
  return node
end

local function session_tree(sessions, repositories, directory_hints, home)
  local roots = {}
  for _, session in ipairs(sessions) do
    local node = tree_node(roots, session.cwd, home)
    table.insert(node.sessions, session)
    if session.managed_workspace and session.managed_workspace ~= vim.NIL then
      node.repository = session.managed_workspace.repository
    end
  end
  for _, repository in ipairs(repositories or {}) do
    local node = tree_node(roots, repository.canonical_path, home)
    node.repository = repository.slug
  end
  for path in pairs(directory_hints or {}) do
    local node = tree_node(roots, path, home)
    node.directory_hint = true
  end
  return roots
end

local function ordered_node_items(node)
  local items = {}
  for _, name in ipairs(sorted_keys(node.directories)) do
    table.insert(items, { kind = "directory", name = name, node = node.directories[name] })
  end
  table.sort(node.sessions, function(left, right)
    if left.provider ~= right.provider then
      return tostring(left.provider) < tostring(right.provider)
    end
    if left.title ~= right.title then
      return tostring(left.title) < tostring(right.title)
    end
    return tostring(left.key) < tostring(right.key)
  end)
  for _, session in ipairs(node.sessions) do
    table.insert(items, { kind = "session", session = session })
  end
  return items
end

local function set_window_options(window, wrap, pane)
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].foldcolumn = "0"
  vim.wo[window].list = false
  vim.wo[window].wrap = wrap
  vim.wo[window].cursorline = true
  vim.w[window].agent_manager = {
    plugin_id = "agent.manager",
    pane = pane,
  }
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
    directory_rows = {},
    directory_hints = {},
    namespace = vim.api.nvim_create_namespace("AgentManagerView"),
    render_pending = false,
    last_action_id = nil,
  }, View)
  self:_create_autocmds()
  return self
end

function View:add_directory_hint(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  self.directory_hints[vim.fs.normalize(path)] = true
  self:schedule_render()
  return true
end

function View:_create_autocmds()
  self.augroup = vim.api.nvim_create_augroup("AgentManagerView", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = self.augroup,
    callback = function()
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
  vim.b[buffer].agent_manager = {
    plugin_id = "agent.manager",
    pane = name,
  }
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
  for index, pane in ipairs(pane_names) do
    local target = pane
    vim.keymap.set("n", tostring(index), function()
      self:focus(target)
    end, map_opts("Agent Manager: focus " .. target .. " pane"))
  end
  vim.keymap.set("n", "q", function()
    self:close()
  end, map_opts("Agent Manager: close workspace"))
  vim.keymap.set("n", "<CR>", function()
    self:_activate_row()
  end, map_opts("Agent Manager: select item"))
  vim.keymap.set("n", "a", function()
    local action = self:_focused_decision()
    if action and action.kind == "approval" and action_has_choice(action, "allow") and self.actions.allow then
      self.actions.allow(action)
    end
  end, map_opts("Agent Manager: allow focused approval"))
  vim.keymap.set("n", "d", function()
    local action = self:_focused_decision()
    if action and action_has_choice(action, "deny") and self.actions.deny then
      self.actions.deny(action)
    end
  end, map_opts("Agent Manager: deny focused request"))
  vim.keymap.set("n", "n", function()
    if self.actions.start then
      self.actions.start(self:_start_context())
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
  vim.keymap.set("n", "h", function()
    if self.actions.attach then
      self.actions.attach()
    end
  end, map_opts("Agent Manager: attach or resume"))
  vim.keymap.set("n", "f", function()
    if self.actions.fork then
      self.actions.fork()
    end
  end, map_opts("Agent Manager: fork selected session"))
  vim.keymap.set("n", "A", function()
    if self.actions.archive then
      self.actions.archive()
    end
  end, map_opts("Agent Manager: archive selected agent"))
  vim.keymap.set("n", "c", function()
    if self.actions.context then
      self.actions.context()
    end
  end, map_opts("Agent Manager: add editor context"))
  vim.keymap.set("n", "D", function()
    if self.actions.diff then
      self.actions.diff()
    end
  end, map_opts("Agent Manager: show diff or file conflict"))
  vim.keymap.set("n", "r", function()
    if self.actions.refresh then
      self.actions.refresh()
    end
  end, map_opts("Agent Manager: refresh"))
  vim.keymap.set("n", "?", function()
    self:show_help()
  end, map_opts("Agent Manager: help"))
  vim.keymap.set("n", "g?", function()
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
  set_window_options(main, true, "conversation")
  local layout = View.layout_for(vim.o.columns)
  self.mode = layout.mode

  if layout.mode == "wide" or layout.mode == "medium" then
    vim.api.nvim_set_current_win(main)
    vim.cmd("topleft vertical split")
    local agents = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(agents, self:_buffer("agents"))
    vim.api.nvim_win_set_width(agents, self.opts.agent_width or 28)
    vim.wo[agents].winfixwidth = true
    set_window_options(agents, false, "agents")
    self.windows.agents = agents
  end
  if layout.mode == "wide" then
    vim.api.nvim_set_current_win(main)
    vim.cmd("botright vertical split")
    local activity = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(activity, self:_buffer("activity"))
    vim.api.nvim_win_set_width(activity, self.opts.activity_width or 38)
    vim.wo[activity].winfixwidth = true
    set_window_options(activity, true, "activity")
    self.windows.activity = activity
  end
  vim.api.nvim_set_current_win(main)
  self.active_pane = "conversation"
  self.pane_index = 2
end

function View:cycle(direction)
  if not valid_tab(self.tab) then
    return false
  end
  local index = ((self.pane_index - 1 + direction) % #pane_names) + 1
  return self:focus(pane_names[index])
end

function View:focus(pane)
  local index = type(pane) == "number" and pane or nil
  if not index then
    for candidate, name in ipairs(pane_names) do
      if name == pane then
        index = candidate
        break
      end
    end
  end
  if not index or not valid_tab(self.tab) then
    return false
  end
  pane = pane_names[index]
  self.pane_index = index
  self.active_pane = pane
  local window = self.windows[pane]
  if valid_window(window) then
    vim.api.nvim_win_set_buf(window, self:_buffer(pane))
    set_window_options(window, pane ~= "agents", pane)
    vim.api.nvim_set_current_win(window)
    return true
  end
  local content = self.windows.conversation
  if not valid_window(content) then
    content = vim.api.nvim_tabpage_list_wins(self.tab)[1]
  end
  if valid_window(content) then
    vim.api.nvim_win_set_buf(content, self:_buffer(pane))
    self.windows.conversation = content
    vim.api.nvim_set_current_win(content)
    set_window_options(content, pane ~= "agents", pane)
    return true
  end
  return false
end

function View:_start_context()
  if vim.api.nvim_get_current_buf() ~= self.buffers.agents then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local directory = self.directory_rows[row]
  if directory then
    return vim.deepcopy(directory)
  end
  local agent_id = self.agent_rows[row]
  local agent = agent_id and self.model.agents[agent_id] or nil
  if agent then
    return {
      cwd = agent.cwd,
      repository = agent.managed_workspace and agent.managed_workspace ~= vim.NIL
          and agent.managed_workspace.repository
        or nil,
    }
  end
  return nil
end

function View:_activate_row()
  local buffer = vim.api.nvim_get_current_buf()
  if buffer == self.buffers.decision then
    local action = self:_focused_decision()
    if action and action.kind == "question" and self.actions.answer then
      self.actions.answer(action)
    end
    return
  end
  if buffer ~= self.buffers.agents then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local agent_id = self.agent_rows[row]
  if agent_id and self.model:select(agent_id) then
    self:render()
  end
end

function View:_focused_decision()
  if vim.api.nvim_get_current_buf() ~= self.buffers.decision then
    return nil
  end
  return self.model:focused_action()
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
  local action = self.model:focused_action()
  self:_render_decision(action)
  self:_sync_decision(action)
end

function View:_set_lines(name, lines, highlights)
  local buffer = self:_buffer(name)
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].modified = false
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
  local sessions = self.model:session_list()
  local lines = {
    " 1 AGENTS · BY DIRECTORY",
    string.format(" broker: %s · sessions: %d", inline(self.model.client_state), #sessions),
    "",
  }
  local highlights = {
    { line = 1, group = "AgentManagerTitle" },
    { line = 2, group = "AgentManagerMuted" },
  }
  self.agent_rows = {}
  self.directory_rows = {}
  local repositories = self.model:workspace_list()
  if #sessions == 0 and #repositories == 0 and not next(self.directory_hints) then
    table.insert(lines, " No directory context is available.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end

  local function render_node(node, prefix)
    local items = ordered_node_items(node)
    for index, item in ipairs(items) do
      local last = index == #items
      local connector = last and "└─ " or "├─ "
      if item.kind == "directory" then
        local suffix = item.node.repository and "  [repo]"
          or item.node.directory_hint and "  [cwd]"
          or ""
        table.insert(lines, prefix .. connector .. inline(item.name) .. suffix)
        self.directory_rows[#lines] = {
          cwd = item.node.path,
          repository = item.node.repository,
        }
        table.insert(highlights, {
          line = #lines,
          group = item.node.repository and "AgentManagerTitle" or "AgentManagerMuted",
        })
        render_node(item.node, prefix .. (last and "   " or "│  "))
      else
        local session = item.session
        local selected = session.managed and session.id == self.model.selected_agent_id and ">" or " "
        local provider = session.provider == "claude" and "◆ CLAUDE" or "● CODEX"
        local pending = session.managed and #self.model:pending(session.id) or 0
        local marker = pending > 0 and (" !" .. tostring(pending)) or ""
        local lead = string.format("%s%s%s ", prefix, connector, selected)
        table.insert(lines, string.format(
          "%s%s · %s · %s%s",
          lead,
          provider,
          inline(session.state),
          inline(session.title),
          marker
        ))
        table.insert(
          highlights,
          {
            line = #lines,
            group = session.provider == "claude" and "AgentManagerProviderClaude"
              or "AgentManagerProviderCodex",
            start = #lead,
            finish = #lead + #provider,
          }
        )
        if session.managed then
          self.agent_rows[#lines] = session.id
        end
      end
    end
  end

  local tree = session_tree(sessions, repositories, self.directory_hints, vim.env.HOME)
  for _, root_name in ipairs(sorted_keys(tree)) do
    local root = tree[root_name]
    local suffix = root.repository and "  [repo]" or root.directory_hint and "  [cwd]" or ""
    table.insert(lines, " " .. inline(root_name) .. suffix)
    self.directory_rows[#lines] = { cwd = root.path, repository = root.repository }
    table.insert(highlights, {
      line = #lines,
      group = "AgentManagerTitle",
    })
    render_node(root, " ")
  end

  if #repositories > 0 or next(self.directory_hints) then
    table.insert(lines, "")
    table.insert(lines, " Start: place cursor on a [repo] or [cwd] directory and press n.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end

  if #self.model:external_session_list() > 0 then
    table.insert(lines, "")
    table.insert(lines, " CLI sessions are read-only here. Press r to refresh.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end
  for _, provider in ipairs({ "codex", "claude" }) do
    local activity = self.model.external_activity[provider]
    if activity and (activity.error or not activity.available) then
      table.insert(lines, " ! " .. provider .. " CLI session discovery unavailable")
      table.insert(highlights, { line = #lines, group = "AgentManagerStatusFailure" })
    end
  end
  local selected = self.model:selected_agent()
  if selected then
    table.insert(lines, "")
    table.insert(lines, " WORKSPACE")
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    table.insert(lines, " " .. inline(selected.cwd))
    table.insert(lines, " " .. inline(selected.workspace_strategy))
    if selected.managed_workspace and selected.managed_workspace ~= vim.NIL then
      table.insert(
        lines,
        " "
          .. inline(selected.managed_workspace.repository)
          .. "/"
          .. inline(selected.managed_workspace.task_id)
      )
      table.insert(
        lines,
        " "
          .. inline(selected.managed_workspace.branch)
          .. " ← "
          .. inline(selected.managed_workspace.base_branch)
      )
    end
    if selected.runtime and selected.runtime ~= vim.NIL then
      table.insert(
        lines,
        " runtime "
          .. inline(selected.runtime.provider_version)
          .. " · "
          .. inline(selected.runtime.compatibility_profile)
      )
    end
    local conflicts = self.model:file_conflict_list(selected.id)
    if #conflicts > 0 then
      table.insert(lines, " ! " .. tostring(#conflicts) .. " dirty buffer conflict(s)")
      table.insert(highlights, { line = #lines, group = "AgentManagerStatusFailure" })
    end
    table.insert(lines, "")
    table.insert(lines, " CAPABILITIES")
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    for _, capability in ipairs(selected.capabilities or {}) do
      local mark = capability.available and "+" or "-"
      table.insert(lines, string.format(" %s %s", mark, inline(capability.name)))
      table.insert(highlights, {
        line = #lines,
        group = capability.available and "AgentManagerStatusSuccess" or "AgentManagerMuted",
      })
      if capability.reason and capability.reason ~= "" then
        table.insert(lines, "   " .. inline(capability.reason))
        table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
      end
    end
  end
  self:_set_lines("agents", lines, highlights)
end

function View:_render_conversation()
  local agent = self.model:selected_agent()
  local title = agent and (inline(agent.provider) .. " · " .. inline(agent.state)) or "no agent selected"
  local lines = { " 2 CONVERSATION", " " .. title, "" }
  local highlights = {
    { line = 1, group = "AgentManagerTitle" },
    { line = 2, group = "AgentManagerMuted" },
  }
  local messages = self.model:conversation()
  if #messages == 0 then
    if agent then
      table.insert(lines, " Press p to compose a prompt.")
    else
      table.insert(lines, " Start a session in pane 1, then press p here to prompt it.")
    end
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  end
  for _, message in ipairs(messages) do
    local label = message.role == "user" and " YOU" or " ASSISTANT"
    if message.role == "system" then
      label = " SYSTEM"
    end
    if message.kind == "steer" then
      label = " YOU · STEER"
    end
    table.insert(lines, label)
    table.insert(highlights, {
      line = #lines,
      group = message.role == "user" and "AgentManagerMessageUser"
        or message.role == "system" and "AgentManagerMessageSystem"
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
  local lines = { " 3 ACTIVITY", "" }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  local activity = self.model:activity()
  local usage = self.model:usage_for()
  if next(usage) then
    table.insert(lines, " USAGE")
    table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
    local projected = {}
    usage_lines(usage, "", projected, 0)
    vim.list_extend(lines, projected)
    table.insert(lines, "")
  end
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

function View:_render_decision(action)
  if not action then
    self:_set_lines("decision", { " DECISION", "", " No pending human request." }, {
      { line = 1, group = "AgentManagerTitle" },
      { line = 3, group = "AgentManagerMuted" },
    })
    return
  end
  local agent = self.model.agents[action.agent_id] or {}
  local payload = action.payload or {}
  local title = action.kind == "approval" and " APPROVAL REQUIRED" or " QUESTION REQUIRED"
  local lines = {
    title,
    "",
    " Provider:  " .. inline(action.provider or agent.provider),
    " Workspace: " .. inline(agent.cwd),
    " Strategy:  " .. inline(agent.workspace_strategy),
    " Session:   " .. inline(agent.provider_session_id),
    "",
  }
  local highlights = {
    {
      line = 1,
      group = action.kind == "approval" and "AgentManagerApprovalPending"
        or "AgentManagerQuestionPending",
    },
    { line = 3, group = "AgentManagerMuted" },
    { line = 4, group = "AgentManagerMuted" },
    { line = 5, group = "AgentManagerMuted" },
    { line = 6, group = "AgentManagerMuted" },
  }
  if agent.managed_workspace and agent.managed_workspace ~= vim.NIL then
    table.insert(
      lines,
      7,
      " Task:      "
        .. inline(agent.managed_workspace.repository)
        .. "/"
        .. inline(agent.managed_workspace.task_id)
    )
    table.insert(highlights, { line = 7, group = "AgentManagerMuted" })
  end
  if action.kind == "approval" then
    table.insert(lines, " Action:  " .. inline(payload.tool_name))
    table.insert(lines, " Summary: " .. inline(payload.summary))
    if payload.command then
      table.insert(lines, "")
      table.insert(lines, " Command")
      table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
      for _, line in ipairs(text_lines(payload.command)) do
        table.insert(lines, "   " .. line)
      end
    end
    if payload.cwd then
      table.insert(lines, " Working directory: " .. inline(payload.cwd))
    end
    for _, detail in ipairs({
      { label = "Risk", value = payload.risk },
      { label = "Permission suggestions", value = payload.permission_suggestions },
    }) do
      if detail.value ~= nil and detail.value ~= vim.NIL then
        local ok, encoded = pcall(vim.json.encode, detail.value)
        if ok then
          table.insert(lines, " " .. detail.label .. ": " .. inline(encoded))
        end
      end
    end
    if #(payload.paths or {}) > 0 then
      table.insert(lines, "")
      table.insert(lines, " Affected paths")
      table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
      for _, path in ipairs(payload.paths) do
        table.insert(lines, "   " .. inline(path))
      end
    end
  else
    for index, question in ipairs(payload.questions or {}) do
      table.insert(lines, string.format(" %d. %s", index, inline(question.header or "Question")))
      table.insert(highlights, { line = #lines, group = "AgentManagerTitle" })
      for _, line in ipairs(text_lines(question.question)) do
        table.insert(lines, "    " .. line)
      end
      for _, option in ipairs(question.options or {}) do
        local description = option.description and option.description ~= ""
            and (" — " .. inline(option.description))
          or ""
        table.insert(lines, "      • " .. inline(option.label) .. description)
        table.insert(highlights, { line = #lines, group = "AgentManagerQuestionChoice" })
      end
      if question.multi_select then
        table.insert(lines, "    Multiple answers may be selected.")
        table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
      end
      table.insert(lines, "")
    end
  end
  table.insert(lines, "")
  if action.kind == "approval" then
    table.insert(lines, " a allow    d deny")
  else
    table.insert(lines, " <CR> answer    d deny")
  end
  table.insert(highlights, { line = #lines, group = "AgentManagerHelpKey" })
  self:_set_lines("decision", lines, highlights)
end

function View:_sync_decision(action)
  local content = self.windows.conversation
  if not valid_window(content) then
    return
  end
  local current = vim.api.nvim_win_get_buf(content)
  if action and action.id ~= self.last_action_id then
    vim.api.nvim_win_set_buf(content, self:_buffer("decision"))
    set_window_options(content, true, "decision")
    self.active_pane = "decision"
    if vim.api.nvim_get_current_tabpage() == self.tab then
      vim.api.nvim_set_current_win(content)
    end
  elseif not action and current == self.buffers.decision then
    vim.api.nvim_win_set_buf(content, self:_buffer("conversation"))
    set_window_options(content, true, "conversation")
    self.active_pane = "conversation"
  end
  self.last_action_id = action and action.id or nil
end

function View:show_diff(diff, title)
  if not valid_tab(self.tab) then
    self:open()
  end
  local lines = { " " .. inline(title or "DIFF"), "" }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  if diff == "" then
    table.insert(lines, " No changes.")
    table.insert(highlights, { line = #lines, group = "AgentManagerMuted" })
  else
    for _, line in ipairs(text_lines(diff)) do
      table.insert(lines, line)
      local group = nil
      if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        group = "AgentManagerDiffAdd"
      elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        group = "AgentManagerDiffDelete"
      elseif line:sub(1, 2) == "@@" then
        group = "AgentManagerDiffChange"
      end
      if group then
        table.insert(highlights, { line = #lines, group = group })
      end
    end
  end
  self:_set_lines("diff", lines, highlights)
  local content = self.windows.conversation
  if valid_window(content) then
    vim.api.nvim_win_set_buf(content, self:_buffer("diff"))
    set_window_options(content, false, "diff")
    self.active_pane = "diff"
    if vim.api.nvim_get_current_tabpage() == self.tab then
      vim.api.nvim_set_current_win(content)
    end
  end
end

function View:show_help()
  local lines = {
    " HELP",
    "",
    " n       start agent from focused directory",
    " h       attach or resume session",
    " p       prompt selected agent",
    " s       steer active turn",
    " x       interrupt active turn",
    " a / d   allow or deny focused request",
    " f       fork selected session",
    " A       archive selected inactive agent",
    " c       add explicit editor context",
    " D       show workspace diff or dirty-buffer conflict",
    " r       refresh agents and CLI sessions",
    " 1 / 2 / 3 focus agents / conversation / activity",
    " <Tab>   cycle panes",
    " <CR>    select agent or answer focused question",
    " q       close workspace",
  }
  local highlights = { { line = 1, group = "AgentManagerTitle" } }
  for line = 3, #lines do
    table.insert(highlights, { line = line, group = "AgentManagerHelpDescription" })
  end
  self:_set_lines("activity", lines, highlights)
  self:focus("activity")
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
    windows = vim.deepcopy(self.windows),
    backend = "native",
  }
end

return View
