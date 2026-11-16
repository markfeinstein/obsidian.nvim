local yaml = require "obsidian.yaml"

local M = {}

---@class obsidian.bases.Definition
---@field identity string
---@field revision string|integer
---@field path string|nil
---@field raw table
---@field properties table
---@field formulas table
---@field filters any
---@field views table[]
---@field view table
---@field view_index integer
---@field view_name string

---@param message string
---@return nil
---@return string
local function invalid(message)
  return nil, "invalid Base definition: " .. message
end

---@param lines string[]
---@param opts { path: string?, identity: string?, revision: string|integer?, view: string? }|?
---@return obsidian.bases.Definition|nil
---@return string|nil
function M.parse(lines, opts)
  opts = opts or {}
  local ok, value = pcall(yaml.loads, lines)
  if not ok then
    return invalid(tostring(value))
  end
  if type(value) ~= "table" or vim.islist(value) then
    return invalid "top-level YAML value must be a mapping"
  end

  local views = value.views
  if type(views) ~= "table" or not vim.islist(views) or #views == 0 then
    return invalid "views must be a non-empty list"
  end

  local selected, selected_index
  if opts.view and opts.view ~= "" then
    for index, view in ipairs(views) do
      if type(view) == "table" and view.name == opts.view then
        selected, selected_index = view, index
        break
      end
    end
    if not selected then
      return invalid(("view %q was not found"):format(opts.view))
    end
  else
    selected, selected_index = views[1], 1
  end
  if type(selected) ~= "table" or vim.islist(selected) then
    return invalid(("view %d must be a mapping"):format(selected_index))
  end

  local view_name = selected.name
  if type(view_name) ~= "string" or view_name == "" then
    view_name = ("View %d"):format(selected_index)
  end

  selected_index = selected_index or 1
  ---@type obsidian.bases.Definition
  local parsed = {
    identity = opts.identity or opts.path or "inline-base",
    revision = opts.revision or 0,
    path = opts.path,
    raw = value,
    properties = type(value.properties) == "table" and value.properties or {},
    formulas = type(value.formulas) == "table" and value.formulas or {},
    filters = value.filters,
    views = views,
    view = selected,
    view_index = selected_index,
    view_name = view_name,
  }
  return parsed, nil
end

---@param path string
---@param opts { view: string? }|?
---@return obsidian.bases.Definition|nil
---@return string|nil
function M.from_file(path, opts)
  opts = opts or {}
  path = vim.fs.normalize(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return invalid("file not found: " .. path)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return invalid("could not read file: " .. path)
  end
  return M.parse(lines, {
    path = path,
    identity = path,
    revision = table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":"),
    view = opts.view,
  })
end

return M
