-- Immutable local associations complement provider history, whose cwd can remain
-- the original canonical checkout even after a session moves to a worktree.
local M = {}

local function key(session)
  return vim.fn.sha256(session.provider .. "\n" .. session.provider_session_id)
end

local function path(session)
  return vim.fn.stdpath("state") .. "/agent-manager/session-workspaces/" .. key(session) .. ".json"
end

local function valid(value, dots)
  return type(value) == "string"
    and #value > 0
    and #value <= 128
    and value:match(dots and "^[a-z0-9][a-z0-9.-]*$" or "^[a-z0-9][a-z0-9-]*$")
    and not value:match("[.-][.-]")
    and not value:match("[.-]$")
end

function M.load(session)
  if (session.provider ~= "codex" and session.provider ~= "claude")
    or type(session.provider_session_id) ~= "string" or session.provider_session_id == ""
  then
    return nil, "A provider session identity is required for workspace recovery"
  end
  local filename = path(session)
  local stat, _, code = vim.uv.fs_lstat(filename)
  if not stat then
    if code == "ENOENT" then
      return nil
    end
    return nil, "Cannot read the saved session workspace; restore its mapping before resuming"
  end
  if stat.type ~= "file" or stat.size > 4096 then
    return nil, "Invalid saved session workspace; restore its mapping before resuming"
  end
  local ok, mapping = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(filename), "\n"))
  end)
  if not ok or type(mapping) ~= "table" or not valid(mapping.repository, true)
    or not valid(mapping.task_id, false)
  then
    return nil, "Invalid saved session workspace; restore its mapping before resuming"
  end
  return { repository = mapping.repository, task_id = mapping.task_id }
end

function M.save(session, workspace)
  if type(workspace) ~= "table" or not valid(workspace.repository, true)
    or not valid(workspace.task_id, false)
  then
    return nil, "Cannot save invalid session workspace metadata"
  end
  local existing, err = M.load(session)
  if err then
    return nil, err
  end
  if existing then
    if existing.repository == workspace.repository and existing.task_id == workspace.task_id then
      return true
    end
    return nil, "Conflicting session workspaces; restore the original mapping before resuming"
  end
  local filename = path(session)
  local temporary = filename .. "." .. vim.uv.os_getpid() .. "." .. tostring(vim.uv.hrtime())
  local ok = pcall(function()
    vim.fn.mkdir(vim.fs.dirname(filename), "p", 448)
    assert(vim.fn.writefile({ vim.json.encode({
      repository = workspace.repository,
      task_id = workspace.task_id,
    }) }, temporary, "s") == 0)
    assert(vim.uv.fs_chmod(temporary, 384))
  end)
  if not ok then
    vim.uv.fs_unlink(temporary)
    return nil, "Cannot save the session workspace association"
  end
  -- Publish atomically without replacing an association written by another editor.
  local linked = vim.uv.fs_link(temporary, filename)
  vim.uv.fs_unlink(temporary)
  if not linked then
    existing, err = M.load(session)
    if existing and existing.repository == workspace.repository
      and existing.task_id == workspace.task_id
    then
      return true
    end
    return nil, err or "Cannot save a conflicting session workspace association"
  end
  return true
end

function M.task_id(session)
  return "session-" .. key(session):sub(1, 32)
end

return M
