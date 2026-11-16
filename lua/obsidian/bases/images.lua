local query = require "obsidian.bases.query"
local all_files = require "obsidian.index.files"
local Path = require "obsidian.path"
local vault_scope = require "obsidian.bases.scope"

local M = {}

local function normalize(path)
  return vim.fs.normalize(path)
end

local function scoped_options(opts, source_path)
  if opts and opts.vault then
    return assert(vault_scope.new(opts.vault, {
      sync = { config_dir = opts.config_dir },
      file = { ignore_filters = opts.ignore_filters },
    }))
  end
  return assert(vault_scope.capture(source_path))
end

local function target(value)
  value = vim.trim(value)
  if value:match "^#%x%x%x%x%x%x$" or value:match "^#%x%x%x$" then
    return nil, "color"
  elseif value:match "^https?://" then
    return nil, "external"
  end
  local wiki = value:match "^!?%[%[([^%]]+)%]%]$"
  if wiki then
    value = vim.trim(wiki:match "^([^|#]+)" or wiki)
  else
    local markdown = value:match "^%[[^%]]*%]%(([^%)]+)%)$"
    if markdown then
      value = markdown
    end
  end
  return vim.uri_decode(value), nil
end

---@param row table
---@param view table|nil
---@param opts obsidian.bases.VaultScope|nil
---@return { kind: "png", path: string, property: string }|nil
---@return string|nil
function M.resolve(row, view, opts)
  local property = view and view.image or nil
  if type(property) ~= "string" or property == "" then
    return nil, "no image property is configured"
  end
  local value = query.value_at(row, property)
  if type(value) == "table" and vim.islist(value) then
    value = value[1]
  end
  if type(value) ~= "string" or value == "" then
    return nil, "the image property has no supported value"
  end
  local raw, kind = target(value)
  if not raw then
    return nil, kind == "external" and "external image URLs are not fetched" or "color image values use text fallback"
  end
  if not raw:lower():match "%.png$" then
    return nil, "native image previews currently support local PNG files only"
  end

  local scope = scoped_options(opts, row.path)
  local vault = scope.vault
  local candidates = {}
  if Path.new(raw):is_absolute() then
    candidates[#candidates + 1] = normalize(raw)
  else
    candidates[#candidates + 1] = normalize(vim.fs.joinpath(vim.fs.dirname(row.path), raw))
    candidates[#candidates + 1] = normalize(vim.fs.joinpath(vault, raw))
  end
  local outside = false
  for _, path in ipairs(candidates) do
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == "file" then
      if vault_scope.contains(scope, path) then
        return { kind = "png", path = path, property = property }, nil
      end
      outside = true
    end
  end
  if outside then
    return nil, "the local image target is outside the vault"
  end

  local basename = vim.fs.basename(raw):lower()
  local match
  for path in pairs(all_files.peek(vault_scope.index_opts(scope)) or {}) do
    if vim.fs.basename(path):lower() == basename then
      if match then
        return nil, "the image basename resolves to more than one vault file"
      end
      match = path
    end
  end
  if match then
    return { kind = "png", path = match, property = property }, nil
  end
  return nil, "the local image file was not found"
end

---@param path string
---@param opts obsidian.bases.VaultScope|nil
---@return string|nil
---@return string|nil
function M.read(path, opts)
  local scope = scoped_options(opts, path)
  if not vault_scope.contains(scope, path) then
    return nil, "the local image target is outside the vault"
  end
  local file = io.open(path, "rb")
  if not file then
    return nil, "the local image could not be read"
  end
  local data = file:read "*a"
  file:close()
  return data, nil
end

return M
