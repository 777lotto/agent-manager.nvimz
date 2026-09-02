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

local function defaults()
  local root = source_root()
  return {
    broker = {
      mode = "embedded",
      command = default_broker_command(root),
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
  if config.broker.mode ~= "embedded" then
    return nil, {
      kind = "configuration",
      message = "M2 supports broker.mode = 'embedded' only",
    }
  end
  local message = command_error(config.broker.command)
  if message then
    return nil, { kind = "configuration", message = message }
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
