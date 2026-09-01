local Client = {}
Client.__index = Client

local function error_object(kind, message, code)
  return { kind = kind, message = message, code = code }
end

local function copy_chunks(data)
  local chunks = {}
  for index, chunk in ipairs(data or {}) do
    chunks[index] = chunk
  end
  return chunks
end

local function object_params(params)
  if params == nil or (type(params) == "table" and next(params) == nil) then
    return vim.empty_dict()
  end
  return params
end

function Client.new(opts)
  return setmetatable({
    command = vim.deepcopy(opts.command),
    claude_python = opts.claude_python,
    on_notification = opts.on_notification or function() end,
    on_status = opts.on_status or function() end,
    job_id = nil,
    generation = 0,
    next_id = 1,
    pending = {},
    ready_waiters = {},
    stdout_partial = "",
    state = "stopped",
    initialized = nil,
    last_error = nil,
    stopping = false,
  }, Client)
end

function Client:_argv()
  local command = vim.deepcopy(self.command)
  if type(self.claude_python) == "string" and self.claude_python ~= "" then
    table.insert(command, "--claude-python")
    table.insert(command, self.claude_python)
  end
  return command
end

function Client:_set_state(state, err)
  self.state = state
  if err then
    self.last_error = err
  end
  pcall(self.on_status, state, err)
end

function Client:_finish_ready(err)
  local waiters = self.ready_waiters
  self.ready_waiters = {}
  for _, callback in ipairs(waiters) do
    pcall(callback, err)
  end
end

function Client:start(callback)
  if callback then
    table.insert(self.ready_waiters, callback)
  end
  if self.state == "connected" then
    self:_finish_ready(nil)
    return true
  end
  if self.state == "starting" or self.state == "negotiating" then
    return true
  end

  self.generation = self.generation + 1
  local generation = self.generation
  self.stopping = false
  self.stdout_partial = ""
  self:_set_state("starting")
  local job_id = vim.fn.jobstart(self:_argv(), {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      local chunks = copy_chunks(data)
      vim.schedule(function()
        if self.generation == generation then
          self:_on_stdout(chunks)
        end
      end)
    end,
    on_stderr = function(_, data)
      if data and #data > 1 then
        vim.schedule(function()
          if self.generation == generation then
            self.last_error = error_object(
              "broker_diagnostic",
              "broker wrote a diagnostic to standard error; content was not retained"
            )
          end
        end)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if self.generation == generation then
          self:_on_exit(code)
        end
      end)
    end,
  })
  if job_id <= 0 then
    local err = error_object("spawn", "could not start the Agent Manager broker", job_id)
    self.job_id = nil
    self:_set_state("failed", err)
    self:_finish_ready(err)
    return nil, err
  end
  self.job_id = job_id
  self:_set_state("negotiating")
  local _, err = self:request(
    "initialize",
    {
      protocol_version = 1,
      client = {
        name = "agent-manager.nvim",
        title = "Agent Manager",
        version = "0.1.0",
      },
      last_sequence = vim.NIL,
    },
    function(result, request_err)
      if request_err then
        self:_protocol_fault(request_err)
        return
      end
      if not result or result.protocol_version ~= 1 then
        self:_protocol_fault(error_object("protocol", "broker protocol version mismatch"))
        return
      end
      self.initialized = result
      self:notify("initialized", {})
      self:_set_state("connected")
      self:_finish_ready(nil)
    end
  )
  if err then
    self:_protocol_fault(err)
    return nil, err
  end
  return true
end

function Client:request(method, params, callback)
  if not self.job_id then
    return nil, error_object("disconnected", "broker is not running")
  end
  local id = self.next_id
  self.next_id = self.next_id + 1
  self.pending[id] = callback or function() end
  local ok, encoded = pcall(vim.json.encode, {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = object_params(params),
  })
  if not ok then
    self.pending[id] = nil
    return nil, error_object("encoding", "could not encode broker request")
  end
  local sent, send_result = pcall(vim.fn.chansend, self.job_id, encoded .. "\n")
  if not sent or send_result == 0 then
    self.pending[id] = nil
    return nil, error_object("disconnected", "could not write to the broker")
  end
  return id
end

function Client:notify(method, params)
  if not self.job_id then
    return nil, error_object("disconnected", "broker is not running")
  end
  local ok, encoded = pcall(vim.json.encode, {
    jsonrpc = "2.0",
    method = method,
    params = object_params(params),
  })
  if not ok then
    return nil, error_object("encoding", "could not encode broker notification")
  end
  local sent, send_result = pcall(vim.fn.chansend, self.job_id, encoded .. "\n")
  if not sent or send_result == 0 then
    return nil, error_object("disconnected", "could not write to the broker")
  end
  return true
end

function Client:_on_stdout(data)
  if not data or #data == 0 then
    return
  end
  data[1] = self.stdout_partial .. data[1]
  self.stdout_partial = table.remove(data) or ""
  for _, line in ipairs(data) do
    if line ~= "" then
      local ok, message = pcall(vim.json.decode, line)
      if not ok or type(message) ~= "table" then
        self:_protocol_fault(error_object("protocol", "broker emitted malformed JSON"))
        return
      end
      self:_handle_message(message)
    end
  end
end

function Client:_handle_message(message)
  if message.jsonrpc ~= "2.0" then
    self:_protocol_fault(error_object("protocol", "broker emitted an invalid JSON-RPC frame"))
    return
  end
  if message.method then
    pcall(self.on_notification, message.method, message.params or {})
    return
  end
  local callback = self.pending[message.id]
  if not callback then
    return
  end
  self.pending[message.id] = nil
  if message.error then
    pcall(
      callback,
      nil,
      error_object("rpc", message.error.message or "broker request failed", message.error.code)
    )
  else
    pcall(callback, message.result, nil)
  end
end

function Client:_protocol_fault(err)
  self.last_error = err
  local job_id = self.job_id
  if job_id then
    pcall(vim.fn.jobstop, job_id)
  end
  self:_disconnect("failed", err)
end

function Client:_disconnect(state, err)
  self.job_id = nil
  local pending = self.pending
  self.pending = {}
  for _, callback in pairs(pending) do
    pcall(callback, nil, err or error_object("disconnected", "broker disconnected"))
  end
  self:_set_state(state, err)
  self:_finish_ready(err or error_object("disconnected", "broker disconnected"))
end

function Client:_on_exit(code)
  if not self.job_id and self.state == "failed" then
    return
  end
  if self.stopping then
    self:_disconnect("stopped", nil)
    return
  end
  self:_disconnect(
    "disconnected",
    error_object("broker_exit", "broker exited unexpectedly", code)
  )
end

function Client:stop()
  if not self.job_id then
    self:_set_state("stopped")
    return true
  end
  self.stopping = true
  if self.state == "connected" then
    local job_id = self.job_id
    self:request("broker/shutdown", {}, function()
      pcall(vim.fn.chanclose, job_id, "stdin")
      vim.defer_fn(function()
        if self.job_id == job_id then
          pcall(vim.fn.jobstop, job_id)
        end
      end, 6000)
    end)
  else
    pcall(vim.fn.jobstop, self.job_id)
  end
  return true
end

function Client:status()
  return {
    state = self.state,
    command = self:_argv(),
    initialized = vim.deepcopy(self.initialized),
    last_error = vim.deepcopy(self.last_error),
  }
end

return Client
