local api = require "obsidian.api"
local fs_util = require "obsidian.util.fs"

local M = {}

---@class obsidian.bases.VaultScope
---@field vault string Normalized, real vault root.
---@field config_dir string
---@field ignore_filters string[]

local function current_options(workspace)
  if workspace then
    return api._workspace_opts(workspace)
  end
  return Obsidian.opts or {}
end

---@param vault string|obsidian.Path
---@param opts obsidian.config.Internal|table|nil
---@return obsidian.bases.VaultScope|nil
---@return string|nil
function M.new(vault, opts)
  local real_vault = vim.uv.fs_realpath(vim.fs.normalize(tostring(vault)))
  if not real_vault then
    return nil, "vault root could not be resolved: " .. tostring(vault)
  end
  opts = opts or {}
  local scope = {
    vault = vim.fs.normalize(real_vault),
    config_dir = (opts.sync and opts.sync.config_dir) or ".obsidian",
    ignore_filters = vim.deepcopy((opts.file and opts.file.ignore_filters) or {}),
  }
  return scope, nil
end

---@param source_path string|nil
---@return obsidian.bases.VaultScope|nil
---@return string|nil
function M.capture(source_path)
  local current_dir = Obsidian.dir and tostring(Obsidian.dir) or nil
  if
    current_dir
    and (
      not source_path
      or source_path == ""
      or fs_util.is_real_subpath(source_path, current_dir, { allow_missing = true })
    )
  then
    return M.new(current_dir, Obsidian.opts or {})
  end

  local workspace
  local current = Obsidian.workspace
  if source_path and source_path ~= "" then
    if current and fs_util.is_real_subpath(source_path, tostring(current.root), { allow_missing = true }) then
      workspace = current
    else
      workspace = api.find_workspace(source_path)
    end
  end
  workspace = workspace or current
  local vault = workspace and workspace.root or Obsidian.dir
  if not vault then
    return nil, "no originating vault is available"
  end
  return M.new(vault, current_options(workspace))
end

---@param scope obsidian.bases.VaultScope
---@return obsidian.bases.VaultScope
function M.copy(scope)
  return {
    vault = scope.vault,
    config_dir = scope.config_dir,
    ignore_filters = vim.deepcopy(scope.ignore_filters or {}),
  }
end

---@param scope obsidian.bases.VaultScope
---@return table
function M.index_opts(scope)
  return {
    vault = scope.vault,
    config_dir = scope.config_dir,
    ignore_filters = vim.deepcopy(scope.ignore_filters or {}),
  }
end

---@param scope obsidian.bases.VaultScope
---@param path string
---@param opts { allow_missing: boolean? }|nil
---@return boolean
function M.contains(scope, path, opts)
  local inside = fs_util.is_real_subpath(path, scope.vault, opts)
  return inside
end

---@param scope obsidian.bases.VaultScope
---@param path string
---@return boolean
function M.contains_lexically(scope, path)
  return fs_util.is_subpath(vim.fs.normalize(vim.fs.abspath(path)), scope.vault)
end

---@param scope obsidian.bases.VaultScope
---@param events table[]
---@return boolean
function M.events_affect(scope, events)
  for _, event in ipairs(events) do
    for _, key in ipairs { "path", "old_path", "new_path" } do
      if event[key] and M.contains_lexically(scope, event[key]) then
        return true
      end
    end
  end
  return false
end

return M
