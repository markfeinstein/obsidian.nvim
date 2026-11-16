local watchfiles = require "obsidian.lsp.watchfiles"
local fs_util = require "obsidian.util.fs"

local M = {}

local entries = {}
local generation = 0
local unregister

local supported_types = {
  "text",
  "multitext",
  "number",
  "checkbox",
  "date",
  "datetime",
  "aliases",
  "tags",
}

local family_by_type = {
  text = "string",
  multitext = "list",
  number = "number",
  checkbox = "boolean",
  date = "date",
  datetime = "datetime",
  aliases = "list",
  tags = "list",
}

local evaluator_by_family = {
  string = "string",
  list = "list",
  number = "number",
  boolean = "boolean",
  date = "date",
  datetime = "date",
}

local function normalize(path)
  return vim.fs.normalize(path)
end

local function find_buffer(path)
  path = normalize(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and normalize(name) == path then
        return bufnr
      end
    end
  end
end

local function default_config_dir()
  local opts = Obsidian and Obsidian.opts or {}
  return opts.sync and opts.sync.config_dir or ".obsidian"
end

local function path_for(vault, config_dir)
  return normalize(vim.fs.joinpath(vault, config_dir, "types.json"))
end

local function revision(path, vault)
  if not fs_util.is_real_subpath(path, vault, { allow_missing = true }) then
    return { kind = "outside_vault" }
  end
  local bufnr = find_buffer(path)
  if bufnr and vim.bo[bufnr].modified then
    return { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(bufnr) }
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return { kind = "missing" }
  end
  return {
    kind = "disk",
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    size = stat.size,
  }
end

local function read_source(path, current_revision)
  if current_revision.kind == "buffer" then
    local bufnr = find_buffer(path)
    if not bufnr then
      return nil
    end
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  elseif current_revision.kind == "disk" then
    local file = io.open(path, "r")
    if not file then
      return nil
    end
    local source = file:read "*a"
    file:close()
    return source
  end
end

local function invalid(path, current_revision, message)
  return {
    status = "invalid",
    path = path,
    revision = current_revision,
    types = {},
    families = {},
    evaluator_types = {},
    unknown = {},
    diagnostic = message,
    generation = generation,
  }
end

local function build(path, current_revision)
  if current_revision.kind == "outside_vault" then
    return invalid(path, current_revision, "property type metadata must remain inside the vault")
  elseif current_revision.kind == "missing" then
    return {
      status = "missing",
      path = path,
      revision = current_revision,
      types = {},
      families = {},
      evaluator_types = {},
      unknown = {},
      diagnostic = nil,
      generation = generation,
    }
  end

  local source = read_source(path, current_revision)
  if not source then
    return invalid(path, current_revision, "property type metadata could not be read")
  end
  local ok, decoded = pcall(vim.json.decode, source)
  if not ok or type(decoded) ~= "table" then
    return invalid(path, current_revision, "property type metadata contains invalid JSON")
  end
  local raw_types = decoded.types
  if type(raw_types) ~= "table" or vim.islist(raw_types) then
    return invalid(path, current_revision, "property type metadata must contain a types object")
  end

  local types = {}
  local families = {}
  local evaluator_types = {}
  local unknown = {}
  for property, type_name in pairs(raw_types) do
    if type(property) ~= "string" or type(type_name) ~= "string" then
      return invalid(path, current_revision, "property type names and values must be strings")
    end
    types[property] = type_name
    local family = family_by_type[type_name]
    if family then
      families[property] = family
      evaluator_types[property] = evaluator_by_family[family]
    else
      unknown[property] = type_name
    end
  end

  return {
    status = "current",
    path = path,
    revision = current_revision,
    types = types,
    families = families,
    evaluator_types = evaluator_types,
    unknown = unknown,
    diagnostic = nil,
    generation = generation,
  }
end

local function ensure_handler()
  if unregister then
    return
  end
  unregister = watchfiles.register_handler(function(events)
    for key, entry in pairs(entries) do
      for _, event in ipairs(events) do
        if event.path == entry.path or event.old_path == entry.path or event.new_path == entry.path then
          entries[key] = nil
          generation = generation + 1
          break
        end
      end
    end
  end)
end

---@param opts { vault: string?, config_dir: string? }|nil
---@return table
function M.get(opts)
  opts = opts or {}
  local configured_vault = normalize(opts.vault or tostring(Obsidian.dir))
  local vault = normalize(vim.uv.fs_realpath(configured_vault) or configured_vault)
  local config_dir = opts.config_dir or default_config_dir()
  local path = path_for(vault, config_dir)
  local key = vault .. "\0" .. config_dir
  local current_revision = revision(path, vault)
  local cached = entries[key]
  if cached and vim.deep_equal(cached.revision, current_revision) then
    return cached
  end

  generation = generation + 1
  local value = build(path, current_revision)
  value.generation = generation
  entries[key] = value
  ensure_handler()
  return value
end

---@param property string
---@param snapshot table|nil
---@return string|nil family
---@return string|nil declared_type
function M.type_for(property, snapshot)
  snapshot = snapshot or M.get()
  if vim.startswith(property, "note.") then
    property = property:sub(6)
  elseif vim.startswith(property, "file.") or vim.startswith(property, "formula.") then
    return nil, nil
  end
  local declared = snapshot.types[property]
  if declared then
    return snapshot.families[property], declared
  end
  local lower = property:lower()
  for name, type_name in pairs(snapshot.types) do
    if name:lower() == lower then
      return snapshot.families[name], type_name
    end
  end
  return nil, nil
end

---@return integer
function M.generation()
  return generation
end

function M.clear()
  entries = {}
  generation = generation + 1
  if unregister then
    unregister()
    unregister = nil
  end
end

M.path = path_for
M.family_by_type = family_by_type
M.supported_types = supported_types

return M
