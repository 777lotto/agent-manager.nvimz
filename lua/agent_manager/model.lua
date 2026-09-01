local Model = {}
Model.__index = Model

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
    selected_agent_id = nil,
    events = {},
    conversations = {},
    activities = {},
    max_events = opts.max_events or 2000,
    last_sequence = 0,
    sequence_gap = nil,
    client_state = "stopped",
    last_error = nil,
    next_local_id = 1,
  }, Model)
end

function Model:set_client_state(state, err)
  self.client_state = state
  if err then
    self.last_error = deep_copy(err)
  end
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
  local next_agents = {}
  local next_order = {}
  for _, agent in ipairs(agents) do
    if type(agent) == "table" and type(agent.id) == "string" then
      next_agents[agent.id] = deep_copy(agent)
      table.insert(next_order, agent.id)
      self.conversations[agent.id] = self.conversations[agent.id] or {}
      self.activities[agent.id] = self.activities[agent.id] or {}
    end
  end
  self.agents = next_agents
  self.order = next_order
  if not self.selected_agent_id or not next_agents[self.selected_agent_id] then
    self.selected_agent_id = next_order[1]
  end
  return true
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
  if is_activity(stored.type or "") then
    local activity = self.activities[event.agent_id]
    table.insert(activity, {
      id = "event:" .. tostring(sequence),
      sequence = sequence,
      type = stored.type,
      detail = activity_detail(stored),
      provider = stored.provider,
    })
  end
  return true
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
  return true
end

function Model:select(agent_id)
  if not self.agents[agent_id] then
    return false
  end
  self.selected_agent_id = agent_id
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
    selected_agent_id = self.selected_agent_id,
    events = self.events,
    conversations = self.conversations,
    activities = self.activities,
    last_sequence = self.last_sequence,
    sequence_gap = self.sequence_gap,
    client_state = self.client_state,
    last_error = self.last_error,
  })
end

return Model
