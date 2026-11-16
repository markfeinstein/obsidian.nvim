local resolver = require "obsidian.bases.resolver"
local vault_scope = require "obsidian.bases.scope"
local workspace = require "obsidian.bases.workspace"

local M = {}

---@param spec table
---@return integer
function M.open_spec(spec)
  return workspace.open(spec)
end

---@param target string|nil
---@param opts { source_path: string? }|?
---@return integer|nil
---@return string|nil
function M.open(target, opts)
  local spec, err = resolver.resolve(target, opts)
  if not spec then
    return nil, err
  end
  return workspace.open(spec), nil
end

---@param query string|nil
---@return string[]
function M.complete(query)
  query = query or ""
  local scope = assert(vault_scope.capture(vim.api.nvim_buf_get_name(0)))
  local root = scope.vault
  local paths = vim.fs.find(function(name)
    return vim.endswith(name, ".base")
  end, { path = root, type = "file", limit = 200 })
  local values = {}
  for _, path in ipairs(paths) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" and vault_scope.contains(scope, path) then
      local relative = path
      if vim.startswith(path, root .. "/") then
        relative = path:sub(#root + 2)
      end
      if query == "" or relative:lower():find(query:lower(), 1, true) then
        values[#values + 1] = relative
      end
    end
  end
  table.sort(values)
  return values
end

return M
