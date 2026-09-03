local Model = {}
Model.__index = Model

local function provider_session_key(provider, session_id)
  return tostring(provider) .. ":" .. tostring(session_id)
end

local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[deep_copy(key, seen)] = deep_copy(item, seen)
  end
  return copy
end

local function text_from(value)
  if type(value) == "string" then
    return value
  end
  if type(value) ~= "table" then
    return nil
  end
  for _, key in ipairs({ "delta", "text", "content", "message" }) do
    local candidate = value[key]
    if type(candidate) == "string" then
      return candidate
    end
  end
  if type(value.content) == "table" then
    local parts = {}
    for _, part in ipairs(value.content) do
      local text = text_from(part)
      if text then
        table.insert(parts, text)
      end
    end
    if #parts > 0 then
      return table.concat(parts, "")
    end
  end
  return nil
end

local function activity_detail(event)
  local payload = event.payload or {}
  local item = payload.item or {}
  return text_from(payload)
    or text_from(item)
    or item.command
    or payload.command
    or payload.tool_name
    or payload.name
    or ""
end

local function is_activity(event_type)
  return event_type:match("^tool%.")
    or event_type:match("^file%.")
    or event_type:match("^diff%.")
    or event_type:match("^usage%.")
    or event_type:match("^approval%.")
    or event_type:match("^question%.")
    or event_type:match("^provider%.")
    or event_type:match("^broker%.")
end

function Model.new(opts)
  opts = opts or {}
  return setmetatable({
    agents = {},
    order = {},
    external_sessions = {},
    external_order = {},
    external_activity = {},
    workspace_repositories = {},
    selected_agent_id = nil,
    events = {},
    conversations = {},
    activities = {},
    pending_actions = {},
    pending_order = {},
    usage = {},
    file_conflicts = {},
    max_events = opts.max_events or 2000,
    last_sequence = 0,
    sequence_gap = nil,
    client_state = "stopped",
    last_error = nil,
    next_local_id = 1,
    on_change = opts.on_change,
  }, Model)
end

function Model:_changed(reason)
  if type(self.on_change) == "function" then
    pcall(self.on_change, reason)
  end
end

function Model:set_client_state(state, err)
  self.client_state = state
  if err then
    self.last_error = deep_copy(err)
  end
  if state == "disconnected" or state == "failed" or state == "stopped" then
    for _, agent in pairs(self.agents) do
      agent.state = "disconnected"
      agent.active_turn_id = nil
      agent.pending_approvals = 0
    end
    self.pending_actions = {}
    self.pending_order = {}
    self.external_sessions = {}
    self.external_order = {}
    self.external_activity = {}
  end
  self:_changed("client_state")
end

function Model:apply_notification(method, params)
  if method == "broker/state" then
    return self:apply_state(params.agents or {})
  end
  if method == "agent/event" then
    return self:apply_event(params)
  end
  return false
end

function Model:apply_state(agents)
  if type(agents) ~= "table" then
    return false
  end
  local observed_activity = {}
  for _, agent in pairs(self.agents) do
    if type(agent.provider) == "string" and type(agent.provider_session_id) == "string" then
      observed_activity[provider_session_key(agent.provider, agent.provider_session_id)] = {
        external_active = agent.external_active,
        activity_known = agent.activity_known,
      }
    end
  end
  local next_agents = {}
  local next_order = {}
  for _, agent in ipairs(agents) do
    if type(agent) == "table" and type(agent.id) == "string" then
      local projected = deep_copy(agent)
      local activity = type(agent.provider_session_id) == "string"
          and observed_activity[provider_session_key(agent.provider, agent.provider_session_id)]
        or nil
      if activity then
        projected.external_active = activity.external_active
        projected.activity_known = activity.activity_known
      end
      next_agents[agent.id] = projected
      table.insert(next_order, agent.id)
      self.conversations[agent.id] = self.conversations[agent.id] or {}
      self.activities[agent.id] = self.activities[agent.id] or {}
    end
  end
  self.agents = next_agents
  self.order = next_order
  self:_dedupe_external_sessions()
  if not self.selected_agent_id or not next_agents[self.selected_agent_id] then
    self.selected_agent_id = next_order[1]
  end
  self:_changed("broker_state")
  return true
end

function Model:_dedupe_external_sessions()
  local managed = {}
  for _, agent in pairs(self.agents) do
    if type(agent.provider) == "string" and type(agent.provider_session_id) == "string" then
      managed[provider_session_key(agent.provider, agent.provider_session_id)] = agent
    end
  end
  local next_order = {}
  for _, key in ipairs(self.external_order) do
    local session = self.external_sessions[key]
    if not managed[key] and session then
      table.insert(next_order, key)
    else
      if managed[key] and session then
        managed[key].external_active = session.active == true
        managed[key].activity_known = session.activity_known
      end
      self.external_sessions[key] = nil
    end
  end
  self.external_order = next_order
end

function Model:apply_external_sessions(provider, sessions, activity_available, err)
  if (provider ~= "codex" and provider ~= "claude") or type(sessions) ~= "table" then
    return false
  end
  for key, session in pairs(self.external_sessions) do
    if session.provider == provider then
      self.external_sessions[key] = nil
    end
  end
  local managed = {}
  for _, agent in pairs(self.agents) do
    if agent.provider == provider then
      agent.external_active = false
      agent.activity_known = activity_available == true
    end
    if type(agent.provider) == "string" and type(agent.provider_session_id) == "string" then
      managed[provider_session_key(agent.provider, agent.provider_session_id)] = agent
    end
  end
  for _, session in ipairs(sessions) do
    local session_id = type(session) == "table" and session.provider_session_id or nil
    local cwd = type(session) == "table" and session.cwd or nil
    if
      type(session_id) == "string"
      and session_id ~= ""
      and type(cwd) == "string"
    then
      local key = provider_session_key(provider, session_id)
      if managed[key] then
        managed[key].external_active = session.active == true
        managed[key].activity_known = activity_available == true
      else
        local projected = deep_copy(session)
        projected.key = key
        projected.provider = provider
        projected.provider_session_id = session_id
        projected.cwd = cwd
        projected.title = type(session.title) == "string" and session.title ~= "" and session.title
          or (provider .. " " .. session_id:sub(1, 12))
        projected.active = session.active == true
        projected.activity_known = activity_available == true
        projected.state = projected.active and "running" or "resumable"
        projected.external = true
        projected.managed = false
        self.external_sessions[key] = projected
      end
    end
  end
  self.external_order = vim.tbl_keys(self.external_sessions)
  table.sort(self.external_order, function(left, right)
    local left_session = self.external_sessions[left]
    local right_session = self.external_sessions[right]
    if left_session.cwd ~= right_session.cwd then
      return left_session.cwd < right_session.cwd
    end
    if left_session.provider ~= right_session.provider then
      return left_session.provider < right_session.provider
    end
    return left_session.provider_session_id < right_session.provider_session_id
  end)
  self.external_activity[provider] = {
    available = activity_available == true,
    error = deep_copy(err),
  }
  self:_changed("external_sessions")
  return true
end

function Model:clear_external_sessions()
  self.external_sessions = {}
  self.external_order = {}
  self.external_activity = {}
  self:_changed("external_sessions")
end

function Model:apply_workspace_inventory(repositories)
  if type(repositories) ~= "table" then
    return false
  end
  local projected = {}
  for _, repository in ipairs(repositories) do
    if
      type(repository) == "table"
      and type(repository.slug) == "string"
      and repository.slug ~= ""
      and type(repository.canonical_path) == "string"
      and repository.canonical_path ~= ""
    then
      table.insert(projected, deep_copy(repository))
    end
  end
  table.sort(projected, function(left, right)
    return left.slug < right.slug
  end)
  self.workspace_repositories = projected
  self:_changed("workspace_inventory")
  return true
end

function Model:workspace_list()
  return deep_copy(self.workspace_repositories)
end

function Model:apply_event(event)
  if type(event) ~= "table" or type(event.agent_id) ~= "string" then
    return false
  end
  local sequence = tonumber(event.sequence)
  if not sequence or sequence <= self.last_sequence then
    return false
  end
  if self.last_sequence > 0 and sequence ~= self.last_sequence + 1 then
    self.sequence_gap = { expected = self.last_sequence + 1, received = sequence }
  end
  self.last_sequence = sequence
  local stored = deep_copy(event)
  table.insert(self.events, stored)
  while #self.events > self.max_events do
    table.remove(self.events, 1)
  end
  self.conversations[event.agent_id] = self.conversations[event.agent_id] or {}
  self.activities[event.agent_id] = self.activities[event.agent_id] or {}
  self:_project_conversation(stored)
  self:_project_human_request(stored)
  if stored.type == "usage.updated" then
    self.usage[event.agent_id] = deep_copy(stored.payload or {})
  end
  if is_activity(stored.type or "") then
    local activity = self.activities[event.agent_id]
    table.insert(activity, {
      id = "event:" .. tostring(sequence),
      sequence = sequence,
      type = stored.type,
      detail = activity_detail(stored),
      provider = stored.provider,
      payload = deep_copy(stored.payload or {}),
    })
  end
  self:_changed(stored.type or "agent_event")
  return true
end

function Model:_project_human_request(event)
  local event_type = event.type or ""
  if event_type == "approval.requested" or event_type == "question.requested" then
    local payload = event.payload or {}
    local id = type(payload.id) == "string" and payload.id or ("event:" .. tostring(event.sequence))
    if not self.pending_actions[id] then
      table.insert(self.pending_order, id)
    end
    self.pending_actions[id] = {
      id = id,
      agent_id = event.agent_id,
      provider = event.provider,
      kind = event_type == "approval.requested" and "approval" or "question",
      payload = deep_copy(payload),
      sequence = event.sequence,
    }
  elseif event_type == "approval.resolved" or event_type == "question.resolved" then
    local id = event.payload and event.payload.id
    if type(id) == "string" then
      self.pending_actions[id] = nil
      for index, pending_id in ipairs(self.pending_order) do
        if pending_id == id then
          table.remove(self.pending_order, index)
          break
        end
      end
    end
  end
end

function Model:_project_conversation(event)
  local conversation = self.conversations[event.agent_id]
  local event_type = event.type or ""
  if event_type == "message.delta" then
    local text = text_from(event.payload) or ""
    local current = conversation[#conversation]
    if not current or current.role ~= "assistant" or not current.streaming then
      current = {
        id = "assistant:" .. tostring(event.sequence),
        role = "assistant",
        text = "",
        streaming = true,
        provider = event.provider,
      }
      table.insert(conversation, current)
    end
    current.text = current.text .. text
  elseif event_type == "message.completed" then
    local text = text_from(event.payload)
    local current = conversation[#conversation]
    if current and current.role == "assistant" and current.streaming then
      if text and #text >= #current.text then
        current.text = text
      end
      current.streaming = false
    elseif text then
      table.insert(conversation, {
        id = "assistant:" .. tostring(event.sequence),
        role = "assistant",
        text = text,
        streaming = false,
        provider = event.provider,
      })
    end
  elseif event_type == "turn.completed" or event_type == "turn.failed" then
    local current = conversation[#conversation]
    if current and current.role == "assistant" then
      current.streaming = false
    end
  end
end

function Model:record_user_input(agent_id, text, kind)
  if not self.agents[agent_id] then
    return false
  end
  self.conversations[agent_id] = self.conversations[agent_id] or {}
  local local_id = self.next_local_id
  self.next_local_id = self.next_local_id + 1
  table.insert(self.conversations[agent_id], {
    id = "local:" .. tostring(local_id),
    role = "user",
    text = text,
    kind = kind or "prompt",
    streaming = false,
  })
  self:_changed(kind or "prompt")
  return true
end

function Model:apply_history(agent_id, messages)
  if not self.agents[agent_id] or type(messages) ~= "table" then
    return false
  end
  local conversation = {}
  for index, message in ipairs(messages) do
    if
      type(message) == "table"
      and (message.role == "user" or message.role == "assistant" or message.role == "system")
      and type(message.text) == "string"
    then
      table.insert(conversation, {
        id = message.id or ("history:" .. tostring(index)),
        role = message.role,
        text = message.text,
        streaming = false,
        history = true,
      })
    end
  end
  self.conversations[agent_id] = conversation
  self:_changed("history")
  return true
end

function Model:begin_resync(latest_sequence)
  self.events = {}
  self.conversations = {}
  self.activities = {}
  self.pending_actions = {}
  self.pending_order = {}
  self.usage = {}
  self.last_sequence = tonumber(latest_sequence) or 0
  self.sequence_gap = nil
  for _, agent_id in ipairs(self.order) do
    self.conversations[agent_id] = {}
    self.activities[agent_id] = {}
  end
  self:_changed("history_resync")
  return true
end

function Model:pending(agent_id)
  local actions = {}
  for _, id in ipairs(self.pending_order) do
    local action = self.pending_actions[id]
    if action and (not agent_id or action.agent_id == agent_id) then
      table.insert(actions, deep_copy(action))
    end
  end
  return actions
end

function Model:focused_action()
  local selected = self:pending(self.selected_agent_id)
  return selected[1] or self:pending()[1]
end

function Model:usage_for(agent_id)
  return deep_copy(self.usage[agent_id or self.selected_agent_id] or {})
end

function Model:record_file_conflict(agent_id, path, details)
  if not self.agents[agent_id] or type(path) ~= "string" then
    return false
  end
  self.file_conflicts[agent_id] = self.file_conflicts[agent_id] or {}
  self.file_conflicts[agent_id][path] = vim.tbl_deep_extend("force", {
    agent_id = agent_id,
    path = path,
  }, deep_copy(details or {}))
  self:_changed("file_conflict")
  return true
end

function Model:resolve_file_conflict(agent_id, path, resolution)
  local conflicts = self.file_conflicts[agent_id]
  if not conflicts or not conflicts[path] then
    return false
  end
  conflicts[path].resolution = resolution
  conflicts[path].resolved = true
  self:_changed("file_conflict_resolved")
  return true
end

function Model:file_conflict_list(agent_id)
  local conflicts = {}
  for _, conflict in pairs(self.file_conflicts[agent_id or self.selected_agent_id] or {}) do
    if not conflict.resolved then
      table.insert(conflicts, deep_copy(conflict))
    end
  end
  table.sort(conflicts, function(left, right)
    return left.path < right.path
  end)
  return conflicts
end

function Model:select(agent_id)
  if not self.agents[agent_id] then
    return false
  end
  self.selected_agent_id = agent_id
  self:_changed("selection")
  return true
end

function Model:selected_agent()
  return deep_copy(self.agents[self.selected_agent_id])
end

function Model:conversation(agent_id)
  return deep_copy(self.conversations[agent_id or self.selected_agent_id] or {})
end

function Model:activity(agent_id)
  return deep_copy(self.activities[agent_id or self.selected_agent_id] or {})
end

function Model:list()
  local agents = {}
  for _, id in ipairs(self.order) do
    table.insert(agents, deep_copy(self.agents[id]))
  end
  return agents
end

function Model:external_session_list()
  local sessions = {}
  for _, key in ipairs(self.external_order) do
    local session = self.external_sessions[key]
    if session then
      table.insert(sessions, deep_copy(session))
    end
  end
  return sessions
end

function Model:session_list()
  local sessions = {}
  for _, agent in ipairs(self:list()) do
    agent.external = false
    agent.managed = true
    agent.key = "agent:" .. agent.id
    table.insert(sessions, agent)
  end
  vim.list_extend(sessions, self:external_session_list())
  return sessions
end

function Model:running_count()
  local count = 0
  for _, agent in pairs(self.agents) do
    if agent.state == "running" or agent.state == "starting" then
      count = count + 1
    end
  end
  return count
end

function Model:pending_approval_count()
  local count = 0
  for _, agent in pairs(self.agents) do
    count = count + (tonumber(agent.pending_approvals) or 0)
  end
  return count
end

function Model:snapshot()
  return deep_copy({
    agents = self:list(),
    external_sessions = self:external_session_list(),
    external_activity = self.external_activity,
    workspace_repositories = self:workspace_list(),
    selected_agent_id = self.selected_agent_id,
    events = self.events,
    conversations = self.conversations,
    activities = self.activities,
    pending_actions = self.pending_actions,
    pending_order = self.pending_order,
    usage = self.usage,
    file_conflicts = self.file_conflicts,
    last_sequence = self.last_sequence,
    sequence_gap = self.sequence_gap,
    client_state = self.client_state,
    last_error = self.last_error,
  })
end

return Model
