local Editor = {}

local function error_object(message)
  return { kind = "editor_context", message = message }
end

local function canonical_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  local resolved = vim.uv.fs_realpath(path)
  if resolved then
    return resolved
  end
  local parent = vim.uv.fs_realpath(vim.fs.dirname(path))
  return parent and vim.fs.joinpath(parent, vim.fs.basename(path)) or nil
end

local function within(root, path)
  root = canonical_path(root)
  path = canonical_path(path)
  if not root or not path then
    return false
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function relative_to(root, path)
  root = canonical_path(root)
  path = canonical_path(path)
  if not root or not path or not within(root, path) then
    return nil
  end
  if root == "/" then
    return path:sub(2)
  end
  return path:sub(#root + 2)
end

local function selected_buffer(opts)
  local buffer = opts and opts.bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buffer) then
    return nil, nil, error_object("selected buffer is no longer valid")
  end
  local path = canonical_path(vim.api.nvim_buf_get_name(buffer))
  if not path then
    return nil, nil, error_object("selected buffer has no filesystem path")
  end
  return buffer, path
end

function Editor.context_buffers(agent)
  if type(agent) ~= "table" or type(agent.cwd) ~= "string" then
    return {}
  end
  local candidates = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_is_loaded(buffer) then
      local path = canonical_path(vim.api.nvim_buf_get_name(buffer))
      if path
        and within(agent.cwd, path)
        and vim.bo[buffer].buftype == ""
        and not vim.bo[buffer].filetype:match("^agent%-manager")
      then
        local relative = relative_to(agent.cwd, path)
        table.insert(candidates, {
          bufnr = buffer,
          path = path,
          label = relative and relative ~= "" and relative or vim.fs.basename(path),
          modified = vim.bo[buffer].modified,
        })
      end
    end
  end
  table.sort(candidates, function(left, right)
    return left.label < right.label
  end)
  return candidates
end

local function base_payload(buffer, path)
  return {
    path = path,
    filetype = vim.bo[buffer].filetype,
    unsaved = vim.bo[buffer].modified,
    changedtick = vim.api.nvim_buf_get_changedtick(buffer),
  }
end

local function finish(callback, value, err)
  if callback then
    vim.schedule(function()
      callback(value, err)
    end)
  end
end

function Editor.capture(kind, agent, opts, callback)
  opts = opts or {}
  if type(agent) ~= "table" or type(agent.cwd) ~= "string" then
    finish(callback, nil, error_object("an agent with a cwd must be selected"))
    return
  end
  local buffer, path, err = selected_buffer(opts)
  if err then
    finish(callback, nil, err)
    return
  end
  if not within(agent.cwd, path) then
    finish(callback, nil, error_object("selected buffer is outside the agent cwd"))
    return
  end
  local payload = base_payload(buffer, path)

  if kind == "buffer" then
    payload.text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    finish(callback, { kind = kind, payload = payload }, nil)
    return
  end

  if kind == "range" then
    local line_count = vim.api.nvim_buf_line_count(buffer)
    local start_mark = vim.api.nvim_buf_get_mark(buffer, "<")
    local end_mark = vim.api.nvim_buf_get_mark(buffer, ">")
    local start_line = tonumber(opts.start_line) or start_mark[1]
    local end_line = tonumber(opts.end_line) or end_mark[1]
    if start_line < 1 or end_line < start_line or end_line > line_count then
      finish(callback, nil, error_object("selected range is invalid"))
      return
    end
    payload.start_line = start_line
    payload.end_line = end_line
    payload.text = table.concat(
      vim.api.nvim_buf_get_lines(buffer, start_line - 1, end_line, false),
      "\n"
    )
    finish(callback, { kind = kind, payload = payload }, nil)
    return
  end

  if kind == "diagnostics" then
    payload.diagnostics = {}
    for _, diagnostic in ipairs(vim.diagnostic.get(buffer)) do
      table.insert(payload.diagnostics, {
        line = diagnostic.lnum + 1,
        column = diagnostic.col + 1,
        end_line = diagnostic.end_lnum and diagnostic.end_lnum + 1 or nil,
        end_column = diagnostic.end_col and diagnostic.end_col + 1 or nil,
        severity = diagnostic.severity,
        source = diagnostic.source,
        code = diagnostic.code,
        message = diagnostic.message,
      })
    end
    finish(callback, { kind = kind, payload = payload }, nil)
    return
  end

  if kind == "diff" then
    local relative = relative_to(agent.cwd, path)
    if not relative then
      finish(callback, nil, error_object("selected buffer is outside the agent cwd"))
      return
    end
    vim.system(
      {
        "git",
        "-C",
        agent.cwd,
        "diff",
        "--no-ext-diff",
        "--no-textconv",
        "--",
        relative,
      },
      { text = true, timeout = 5000 },
      function(result)
        if result.code ~= 0 then
          finish(callback, nil, error_object("Git diff is unavailable for the selected buffer"))
          return
        end
        payload.diff = result.stdout or ""
        finish(callback, { kind = kind, payload = payload }, nil)
      end
    )
    return
  end

  finish(callback, nil, error_object("unknown editor context kind"))
end

local path_keys = {
  path = true,
  file_path = true,
  filePath = true,
  absolute_path = true,
}

local function collect_paths(value, paths, depth)
  if type(value) ~= "table" or depth > 8 then
    return
  end
  for key, item in pairs(value) do
    if path_keys[key] and type(item) == "string" then
      paths[item] = true
    elseif type(item) == "table" then
      collect_paths(item, paths, depth + 1)
    end
  end
end

function Editor.observe_file_event(event, model)
  if type(event) ~= "table" or event.type ~= "file.changed" then
    return false
  end
  local agent = model.agents[event.agent_id]
  if not agent then
    return false
  end
  local raw_paths = {}
  collect_paths(event.payload or {}, raw_paths, 0)
  local changed = false
  for raw_path in pairs(raw_paths) do
    local path = raw_path
    if path:sub(1, 1) ~= "/" then
      path = vim.fs.joinpath(agent.cwd, path)
    end
    path = canonical_path(path)
    if path and within(agent.cwd, path) then
      local buffer = vim.fn.bufnr(path)
      if buffer > 0 and vim.api.nvim_buf_is_loaded(buffer) then
        local scratch = vim.bo[buffer].buftype ~= ""
          or vim.bo[buffer].filetype:match("^agent%-manager") ~= nil
        if not scratch and vim.bo[buffer].modified then
          changed = model:record_file_conflict(event.agent_id, path, {
            bufnr = buffer,
            sequence = event.sequence,
            event = vim.deepcopy(event),
          }) or changed
          vim.notify(
            "Agent Manager: disk changed while the buffer is modified: " .. path,
            vim.log.levels.WARN
          )
        elseif not scratch then
          pcall(vim.api.nvim_buf_call, buffer, function()
            vim.cmd("silent checktime")
          end)
        end
      end
    end
  end
  return changed
end

function Editor.conflict_diff(conflict)
  if type(conflict) ~= "table" or not vim.api.nvim_buf_is_valid(conflict.bufnr or -1) then
    return nil, error_object("conflicted buffer is no longer available")
  end
  local buffer_text = table.concat(vim.api.nvim_buf_get_lines(conflict.bufnr, 0, -1, false), "\n")
  local ok, disk_lines = pcall(vim.fn.readfile, conflict.path, "b")
  if not ok then
    return nil, error_object("changed file could not be read from disk")
  end
  local disk_text = table.concat(disk_lines, "\n")
  local ok_diff, diff = pcall(vim.diff, disk_text, buffer_text, {
    result_type = "unified",
    ctxlen = 3,
  })
  if not ok_diff then
    return nil, error_object("buffer/disk diff could not be generated")
  end
  return diff
end

function Editor.inspect(conflict)
  if type(conflict) ~= "table" or not vim.api.nvim_buf_is_valid(conflict.bufnr or -1) then
    return nil, error_object("conflicted buffer is no longer available")
  end
  vim.cmd("tabnew")
  vim.api.nvim_set_current_buf(conflict.bufnr)
  return true
end

function Editor.reload(conflict)
  if type(conflict) ~= "table" or not vim.api.nvim_buf_is_valid(conflict.bufnr or -1) then
    return nil, error_object("conflicted buffer is no longer available")
  end
  local ok, err = pcall(vim.api.nvim_buf_call, conflict.bufnr, function()
    vim.cmd("edit!")
  end)
  if not ok then
    return nil, error_object("buffer reload failed: " .. tostring(err))
  end
  return true
end

return Editor
