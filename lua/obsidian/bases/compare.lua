local buffer = require "obsidian.bases.buffer"
local compat = require "obsidian.bases.compat"
local fs_util = require "obsidian.util.fs"
local property_types = require "obsidian.properties.types"
local source = require "obsidian.bases.source"

local M = {}

local function relative_path(path, vault)
  path, vault = vim.fs.normalize(path), vim.fs.normalize(vault)
  if vim.startswith(path, vault .. "/") then
    return path:sub(#vault + 2)
  end
  return path
end

local function normalize_result_path(value)
  if type(value) == "string" then
    return value:gsub("\\", "/"):gsub("^%./", "")
  elseif type(value) ~= "table" then
    return nil
  end
  if type(value.path) == "string" then
    return normalize_result_path(value.path)
  elseif type(value.file) == "string" then
    return normalize_result_path(value.file)
  elseif type(value.file) == "table" and type(value.file.path) == "string" then
    return normalize_result_path(value.file.path)
  end
end

---@param stdout string
---@return string[]|nil paths
---@return string|nil error
function M.parse(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok or type(decoded) ~= "table" or not vim.islist(decoded) then
    return nil, "Obsidian CLI returned invalid JSON"
  end
  local paths = {}
  local seen = {}
  for _, value in ipairs(decoded) do
    local path = normalize_result_path(value)
    if not path then
      return nil, "Obsidian CLI JSON did not expose result paths"
    end
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths, nil
end

---@param definition obsidian.bases.Definition
---@param opts { cmd: string?, vault: string?, strict_vault: boolean? }|nil
---@return string[]|nil
---@return string|nil
function M.command(definition, opts)
  opts = opts or {}
  if not definition.path then
    return nil, "CLI comparison requires a saved .base file"
  end
  local cmd = opts.cmd or vim.fn.exepath "obsidian"
  if not cmd or cmd == "" then
    return nil, "Obsidian CLI executable was not found"
  end
  local vault = opts.vault or tostring(Obsidian.dir)
  if opts.strict_vault and not fs_util.is_real_subpath(definition.path, vault) then
    return nil, "CLI comparison Base must remain inside the originating vault"
  end
  return {
    cmd,
    "base:query",
    "path=" .. relative_path(definition.path, vault),
    "view=" .. definition.view_name,
    "format=json",
  },
    nil
end

local function disk_revision(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":")
end

local function non_comparable(reason)
  return {
    status = "non_comparable",
    summary = "not comparable with Obsidian CLI: " .. reason,
    diagnostics = {},
  }
end

---@param definition obsidian.bases.Definition
---@param result obsidian.bases.Result
---@param opts { vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
---@return boolean
---@return string|nil
function M.comparability(definition, result, opts)
  opts = opts or {}
  local snapshot = result and result.comparison_snapshot or nil
  if not definition or not definition.path or (snapshot and snapshot.embedded) then
    return false, "embedded Bases do not have a saved .base definition"
  elseif not snapshot then
    return false, "local comparison snapshot metadata is unavailable"
  elseif snapshot.definition_revision_kind ~= "disk" then
    return false, "the local result includes unsaved .base changes"
  elseif snapshot.context_dependent then
    return false, "the local result depends on its embedding note context"
  elseif snapshot.unsaved_note_overlays or source.has_unsaved_overlays(opts) then
    return false, "the local result includes unsaved note overlays"
  end

  local snapshot_types_revision = snapshot.property_types_revision
  local current_types = property_types.get {
    vault = opts.vault,
    config_dir = opts.config_dir,
  }
  if
    (snapshot_types_revision and snapshot_types_revision.kind == "buffer")
    or (current_types.revision and current_types.revision.kind == "buffer")
  then
    return false, "the local result includes unsaved property type metadata"
  elseif not snapshot_types_revision or not vim.deep_equal(current_types.revision, snapshot_types_revision) then
    return false, "property type metadata changed after the local result was evaluated"
  end

  -- Keep this last so M.run checks the disk revision immediately before invoking the CLI.
  local definition_buf = buffer.find(definition.path)
  if definition_buf and vim.api.nvim_buf_is_loaded(definition_buf) and vim.bo[definition_buf].modified then
    return false, "the local result includes unsaved .base changes"
  end
  local current_definition_revision = disk_revision(definition.path)
  if not current_definition_revision then
    return false, "the saved .base file is no longer available"
  elseif
    current_definition_revision ~= snapshot.definition_revision or current_definition_revision ~= definition.revision
  then
    return false, "the saved .base file changed after the local result was evaluated"
  end
  return true, nil
end

local function path_diff(local_paths, cli_paths)
  local local_set, cli_set = {}, {}
  for _, path in ipairs(local_paths) do
    local_set[path] = true
  end
  for _, path in ipairs(cli_paths) do
    cli_set[path] = true
  end
  local only_local, only_cli = {}, {}
  for path in pairs(local_set) do
    if not cli_set[path] then
      only_local[#only_local + 1] = path
    end
  end
  for path in pairs(cli_set) do
    if not local_set[path] then
      only_cli[#only_cli + 1] = path
    end
  end
  table.sort(only_local)
  table.sort(only_cli)
  return only_local, only_cli
end

---@param definition obsidian.bases.Definition
---@param result obsidian.bases.Result
---@param callback fun(result: table)
---@param opts { cmd: string?, vault: string?, strict_vault: boolean?, timeout: integer?, system?: fun(args: string[], opts: table, callback: fun(out: table)): any }|nil
---@return any|nil
function M.run(definition, result, callback, opts)
  opts = opts or {}
  local command, command_err = M.command(definition, opts)
  if not command then
    callback { status = "unavailable", summary = command_err, diagnostics = {} }
    return nil
  end
  local local_paths = {}
  for _, row in ipairs(result.rows or {}) do
    local_paths[#local_paths + 1] = row.file.path
  end
  table.sort(local_paths)
  local system_opts = {
    text = true,
    timeout = opts.timeout or 5000,
    cwd = opts.vault or tostring(Obsidian.dir),
  }
  local function on_exit(out)
    vim.schedule(function()
      if out.code ~= 0 then
        local message = vim.trim(out.stderr or "")
        callback {
          status = "error",
          summary = "Obsidian CLI comparison failed" .. (message ~= "" and ": " .. message or ""),
          diagnostics = {},
        }
        return
      end
      local cli_paths, parse_err = M.parse(out.stdout or "")
      if not cli_paths then
        callback { status = "error", summary = parse_err, diagnostics = {} }
        return
      end
      local only_local, only_cli = path_diff(local_paths, cli_paths)
      local matches = #only_local == 0 and #only_cli == 0
      callback {
        status = matches and "match" or "different",
        summary = matches and ("matches Obsidian CLI (%d rows)"):format(#local_paths)
          or ("differs from Obsidian CLI · local-only %d · Obsidian-only %d"):format(#only_local, #only_cli),
        diagnostics = {
          only_local = only_local,
          only_cli = only_cli,
        },
      }
    end)
  end
  local comparable, reason = M.comparability(definition, result, opts)
  if not comparable then
    callback(non_comparable(reason or "unknown comparison snapshot mismatch"))
    return nil
  end
  if opts.system then
    return opts.system(command, system_opts, on_exit)
  end
  local process, system_err = compat.system(command, system_opts, on_exit)
  if not process then
    callback { status = "unavailable", summary = system_err, diagnostics = {} }
  end
  return process
end

M.path_diff = path_diff

return M
