local M = {}

---Prefer filesystem creation time. Libuv uses a zero timestamp when birth time
---is unavailable; only then fall back to inode change time for compatibility.
---@param stat uv.fs_stat.result
---@return { sec: integer, nsec: integer }|nil
function M.creation_time(stat)
  local birthtime = stat.birthtime
  if birthtime and (birthtime.sec ~= 0 or birthtime.nsec ~= 0) then
    return birthtime
  end
  return stat.ctime
end

local function split_path(path)
  local parts = {}
  for part in path:gmatch "[^/]+" do
    table.insert(parts, part)
  end
  return parts
end

local function join_path(parts)
  return table.concat(parts, "/")
end

---@param base string
---@param target string
---@return string|?
function M.relpath(base, target)
  base = vim.fs.normalize(vim.fs.abspath(base))
  target = vim.fs.normalize(vim.fs.abspath(target))

  if base == target then
    return "."
  end

  local base_parts = split_path(base)
  local target_parts = split_path(target)

  -- Find common prefix
  local i = 1
  while i <= #base_parts and i <= #target_parts and base_parts[i] == target_parts[i] do
    i = i + 1
  end

  -- Steps up from base to common ancestor
  local ups = {}
  for _ = i, #base_parts do
    table.insert(ups, "..")
  end

  -- Steps down to target from common ancestor
  local downs = {}
  for j = i, #target_parts do
    table.insert(downs, target_parts[j])
  end

  local rel_parts = {}
  vim.list_extend(rel_parts, ups)
  vim.list_extend(rel_parts, downs)

  return #rel_parts > 0 and join_path(rel_parts) or "."
end

---@param path string
---@param root string
---@return boolean
function M.is_subpath(path, root)
  path = vim.fs.normalize(path):gsub("/+$", "")
  root = vim.fs.normalize(root):gsub("/+$", "")
  return path == root or vim.startswith(path, root .. "/")
end

local function absolute(path)
  return vim.fs.normalize(vim.fs.abspath(path))
end

---Check a path against the filesystem-resolved boundary of a root.
---When `allow_missing` is set, a missing leaf is accepted only when its nearest
---existing ancestor resolves inside the root. Dangling symlinks remain rejected.
---@param path string
---@param root string
---@param opts { allow_missing: boolean? }|nil
---@return boolean inside
---@return string|nil resolved_path
---@return string|nil resolved_root
function M.is_real_subpath(path, root, opts)
  opts = opts or {}
  path, root = absolute(path), absolute(root)
  local resolved_root = vim.uv.fs_realpath(root)
  if not resolved_root then
    return false, nil, nil
  end
  resolved_root = vim.fs.normalize(resolved_root)

  local resolved_path = vim.uv.fs_realpath(path)
  if resolved_path then
    resolved_path = vim.fs.normalize(resolved_path)
    return M.is_subpath(resolved_path, resolved_root), resolved_path, resolved_root
  elseif not opts.allow_missing or vim.uv.fs_lstat(path) then
    return false, nil, resolved_root
  end

  local ancestor = vim.fs.dirname(path)
  while ancestor and ancestor ~= "" do
    local resolved_ancestor = vim.uv.fs_realpath(ancestor)
    if resolved_ancestor then
      resolved_ancestor = vim.fs.normalize(resolved_ancestor)
      return M.is_subpath(resolved_ancestor, resolved_root), nil, resolved_root
    elseif vim.uv.fs_lstat(ancestor) then
      return false, nil, resolved_root
    end
    local parent = vim.fs.dirname(ancestor)
    if parent == ancestor then
      break
    end
    ancestor = parent
  end
  return false, nil, resolved_root
end

---@param path string
---@param contents string
function M.atomic_write(path, contents)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then
    error("cannot open " .. tmp .. ": " .. tostring(err))
  end
  f:write(contents)
  f:close()
  local ok, rename_err = vim.uv.fs_rename(tmp, path)
  if not ok then
    error("rename failed: " .. tostring(rename_err))
  end
end

return M
