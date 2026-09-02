local M = {}

function M.equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(
      (message or "values differ")
        .. ": expected "
        .. vim.inspect(expected)
        .. ", got "
        .. vim.inspect(actual)
    )
  end
end

function M.truthy(value, message)
  if not value then
    error(message or "expected a truthy value")
  end
  return value
end

function M.await(message, predicate)
  if not vim.wait(5000, predicate, 10, false) then
    error("timed out waiting for " .. message)
  end
end

function M.root(name)
  local value = vim.env[name]
  if not value or value == "" or vim.fn.isdirectory(value) ~= 1 then
    error(name .. " must identify a dependency checkout")
  end
  return value
end

function M.registration(foundation, plugin_id)
  for _, registration in ipairs(foundation.registrations() or {}) do
    if registration.manifest and registration.manifest.plugin.id == plugin_id then
      return registration
    end
  end
end

function M.tree_root(tree, plugin_id)
  for _, item in ipairs((tree or {}).roots or {}) do
    if item.id == plugin_id then
      return item
    end
  end
end

function M.raw_highlight(group)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, {
    name = group,
    link = true,
    create = false,
  })
  return ok and value or {}
end

function M.finish(test)
  local ok, err = xpcall(test, debug.traceback)
  if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit 1")
  else
    vim.cmd("qa!")
  end
end

return M
