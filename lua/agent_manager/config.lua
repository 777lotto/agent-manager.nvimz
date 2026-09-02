local M = {}

local function source_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function executable(path)
  return type(path) == "string" and vim.fn.executable(path) == 1
end

local function default_broker_command(root)
  local release = root .. "/target/release/agent-manager-broker"
  local debug = root .. "/target/debug/agent-manager-broker"
  if executable(release) then
    return { release, "serve" }
  end
  if executable(debug) then
    return { debug, "serve" }
  end
  return { "agent-manager-broker", "serve" }
end

local function default_claude_python(root)
  local python = root .. "/python/.venv/bin/python"
  return executable(python) and python or nil
end

local function default_socket()
  local runtime = vim.env.XDG_RUNTIME_DIR
  if type(runtime) ~= "string" or runtime == "" or runtime:sub(1, 1) ~= "/" then
    return nil
  end
  return vim.fs.normalize(runtime .. "/agent-manager/broker.sock")
end

local function defaults()
  local root = source_root()
  return {
    broker = {
      mode = "embedded",
      command = default_broker_command(root),
      socket = default_socket(),
      reconnect = {
        initial_delay = 100,
        max_delay = 5000,
        max_attempts = 8,
        jitter = 0.2,
      },
    },
    providers = {
      codex = {},
      claude = {
        python = default_claude_python(root),
      },
    },
    ui = {
      max_events = 2000,
      agent_width = 28,
      activity_width = 38,
    },
    root = root,
  }
end

local function reconnect_error(reconnect)
  if type(reconnect) ~= "table" then
    return "broker.reconnect must be a table"
  end
  for _, key in ipairs({ "initial_delay", "max_delay", "max_attempts" }) do
    local value = reconnect[key]
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
      return "broker.reconnect." .. key .. " must be a positive integer"
    end
  end
  if reconnect.max_delay < reconnect.initial_delay then
    return "broker.reconnect.max_delay must be at least initial_delay"
  end
  if type(reconnect.jitter) ~= "number" or reconnect.jitter < 0 or reconnect.jitter > 1 then
    return "broker.reconnect.jitter must be between 0 and 1"
  end
end

local function command_error(command)
  if type(command) ~= "table" or #command == 0 then
    return "broker.command must be a non-empty argv list"
  end
  for _, argument in ipairs(command) do
    if type(argument) ~= "string" or argument == "" then
      return "every broker.command argument must be a non-empty string"
    end
  end
end

function M.resolve(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return nil, { kind = "configuration", message = "setup options must be a table" }
  end
  opts = opts or {}
  local config = vim.tbl_deep_extend("force", defaults(), opts)
  if opts.broker and opts.broker.command then
    config.broker.command = vim.deepcopy(opts.broker.command)
  end
  if config.broker.mode ~= "embedded" and config.broker.mode ~= "durable" then
    return nil, {
      kind = "configuration",
      message = "broker.mode must be 'embedded' or 'durable'",
    }
  end
  local message = command_error(config.broker.command)
  if message then
    return nil, { kind = "configuration", message = message }
  end
  if config.broker.mode == "durable" then
    if config.broker.command[1]:sub(1, 1) ~= "/" or not executable(config.broker.command[1]) then
      return nil, {
        kind = "configuration",
        message = "durable broker.command must begin with an absolute executable path",
      }
    end
    if
      type(config.broker.socket) ~= "string"
      or config.broker.socket == ""
      or config.broker.socket:sub(1, 1) ~= "/"
    then
      return nil, {
        kind = "configuration",
        message = "durable broker.socket must be an absolute path",
      }
    end
    config.broker.socket = vim.fs.normalize(config.broker.socket)
    local reconnect_message = reconnect_error(config.broker.reconnect)
    if reconnect_message then
      return nil, { kind = "configuration", message = reconnect_message }
    end
  end
  local python = config.providers.claude.python
  if python ~= nil and python ~= false and (type(python) ~= "string" or python == "") then
    return nil, {
      kind = "configuration",
      message = "providers.claude.python must be a path, false, or nil",
    }
  end
  if type(python) == "string" and python:sub(1, 1) ~= "/" then
    return nil, {
      kind = "configuration",
      message = "providers.claude.python must be an absolute path",
    }
  end
  if type(config.ui.max_events) ~= "number" or config.ui.max_events < 1 then
    return nil, { kind = "configuration", message = "ui.max_events must be positive" }
  end
  return config
end

return M
