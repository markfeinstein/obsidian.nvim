local cache_note = require "obsidian.cache.note"
local ignore = require "obsidian.ignore"
local fs_util = require "obsidian.util.fs"
local volatile = require "obsidian.cache.volatile"

local M = {}

local markdown_extensions = {
  md = true,
  markdown = true,
  qmd = true,
}

local function normalize(path)
  return vim.fs.normalize(path)
end

local function extension(path)
  return (path:match "%.([^./\\]+)$" or ""):lower()
end

local function relative_path(path, vault)
  if vim.startswith(path, vault .. "/") then
    return path:sub(#vault + 2)
  end
  return path
end

local function in_vault(path, vault)
  return fs_util.is_subpath(path, vault)
end

local function in_real_vault(path, context, opts)
  return fs_util.is_real_subpath(path, context.vault, opts)
end

local function is_internal(path, context)
  local rel = relative_path(path, context.vault)
  local config_dir = normalize(context.config_dir):gsub("^[/\\]+", ""):gsub("[/\\]+$", "")
  local first = rel:match "^([^/\\]+)"
  return first == ".git" or rel == config_dir or vim.startswith(rel, config_dir .. "/")
end

local function is_ignored(path, context)
  if not context.ignore_checker then
    return false
  end
  return context.ignore_checker(relative_path(path, context.vault))
end

local function file_stat(stat)
  local created = fs_util.creation_time(stat)
  return {
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    ctime_sec = created and created.sec or nil,
    ctime_nsec = created and created.nsec or nil,
    size = stat.size,
  }
end

local function read_lines(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local lines = {}
  for line in file:lines() do
    lines[#lines + 1] = line
  end
  file:close()
  return lines
end

local function build_row(path, context)
  path = normalize(path)
  local stat = vim.uv.fs_stat(path)
  if
    not stat
    or stat.type ~= "file"
    or not in_real_vault(path, context)
    or is_internal(path, context)
    or is_ignored(path, context)
  then
    return nil
  end

  local ext = extension(path)
  if markdown_extensions[ext] then
    local lines = read_lines(path)
    if lines then
      local row = cache_note.build_from_lines(path, lines, stat, { preserve_properties = true })
      if row then
        row.extension = ext
        return row
      end
    end
  end
  return {
    kind = "file",
    extension = ext,
    stat = file_stat(stat),
  }
end

local function event_paths(event)
  local paths = {}
  for _, key in ipairs { "path", "old_path", "new_path" } do
    if event[key] then
      paths[#paths + 1] = event[key]
    end
  end
  return paths
end

-- Watchers can report only a directory for subtree imports, moves, or deletes.
-- A vanished directory has no stat; indexed descendants retain that evidence.
local function affects_directory(path, rows, context)
  path = normalize(path)
  if not in_vault(path, context.vault) or is_internal(path, context) or is_ignored(path, context) then
    return false
  end
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return true
  elseif rows[path] then
    return false
  end
  local prefix = path .. "/"
  for indexed_path in pairs(rows) do
    if vim.startswith(indexed_path, prefix) then
      return true
    end
  end
  return false
end

-- Yield often enough to keep the editor responsive while preserving one-file-at-a-time parsing.
local scan_slice_ns = 4 * 1000 * 1000
local build_slice_ns = 8 * 1000 * 1000

local function schedule(state, callback)
  vim.schedule(function()
    if not state.cancelled then
      callback()
    end
  end)
end

local function scan_files(context, state, done)
  local directories = { context.vault }
  local directory_index = 1
  local paths = {}

  local function scan_next_directory()
    if state.cancelled then
      return
    end
    local directory = directories[directory_index]
    if not directory then
      done(paths)
      return
    end
    local is_root = directory_index == 1
    directory_index = directory_index + 1

    local request, request_err
    request, request_err = vim.uv.fs_scandir(directory, function(err, scan)
      state.request = nil
      if state.cancelled then
        return
      end
      if err or not scan then
        if is_root then
          done(nil, err or request_err or ("failed to scan " .. directory))
        else
          schedule(state, scan_next_directory)
        end
        return
      end

      local function consume_scan()
        local started = vim.uv.hrtime()
        while not state.cancelled do
          local name, kind = vim.uv.fs_scandir_next(scan)
          if not name then
            schedule(state, scan_next_directory)
            return
          end
          local path = normalize(vim.fs.joinpath(directory, name))
          if not is_internal(path, context) and not is_ignored(path, context) then
            if kind == "directory" then
              directories[#directories + 1] = path
            else
              paths[#paths + 1] = path
            end
          end
          if vim.uv.hrtime() - started >= scan_slice_ns then
            schedule(state, consume_scan)
            return
          end
        end
      end

      schedule(state, consume_scan)
    end)
    state.request = request
    if not request then
      if is_root then
        done(nil, request_err or ("failed to scan " .. directory))
      else
        schedule(state, scan_next_directory)
      end
    end
  end

  scan_next_directory()
end

local function build_rows(paths, context, state, done)
  local rows = {}
  local path_index = 1

  local function build_slice()
    local started = vim.uv.hrtime()
    while not state.cancelled do
      local path = paths[path_index]
      if not path then
        done { rows = rows }
        return
      end
      path_index = path_index + 1
      local row = M._build_row(path, context)
      if row then
        rows[normalize(path)] = row
      end
      if vim.uv.hrtime() - started >= build_slice_ns then
        schedule(state, build_slice)
        return
      end
    end
  end

  schedule(state, build_slice)
end

local index = volatile.vault_index {
  max_entries = 4,
  version = function(context)
    return context.version
  end,
  matches = function(_, events, context)
    for _, event in ipairs(events) do
      for _, path in ipairs(event_paths(event)) do
        if path and in_vault(normalize(path), context.vault) then
          return true
        end
      end
    end
    return false
  end,
  build = function(context, done)
    local state = { cancelled = false, request = nil }
    scan_files(context, state, function(paths, err)
      if err then
        done(nil, err)
      else
        build_rows(paths, context, state, done)
      end
    end)
    return function()
      state.cancelled = true
      if state.request then
        pcall(vim.uv.cancel, state.request)
        state.request = nil
      end
    end
  end,
  update = function(value, events, context)
    for _, event in ipairs(events) do
      for _, path in ipairs(event_paths(event)) do
        if affects_directory(path, value.rows, context) then
          -- The volatile index invalidates this snapshot and shares the next
          -- asynchronous scan with every waiting workspace.
          return false
        end
      end
    end
    local FileChangeType = vim.lsp.protocol.FileChangeType
    for _, event in ipairs(events) do
      if event.type == "renamed" then
        if event.old_path then
          value.rows[normalize(event.old_path)] = nil
        end
        if event.new_path then
          local new_path = normalize(event.new_path)
          value.rows[new_path] = build_row(new_path, context)
        end
      else
        local path = event.path and normalize(event.path) or nil
        if path then
          if event.type == "deleted" or event.type == FileChangeType.Deleted then
            value.rows[path] = nil
          elseif
            event.type == "created"
            or event.type == "changed"
            or event.type == FileChangeType.Created
            or event.type == FileChangeType.Changed
          then
            value.rows[path] = build_row(path, context)
          end
        end
      end
    end
    return true
  end,
}

local function current_context(opts)
  opts = opts or {}
  local configured_vault = normalize(opts.vault or tostring(Obsidian.dir))
  local vault = normalize(vim.uv.fs_realpath(configured_vault) or configured_vault)
  local config_dir = opts.config_dir
    or (Obsidian.opts and Obsidian.opts.sync and Obsidian.opts.sync.config_dir)
    or ".obsidian"
  local ignore_filters = vim.deepcopy(
    opts.ignore_filters or (Obsidian.opts and Obsidian.opts.file and Obsidian.opts.file.ignore_filters) or {}
  )
  local version = vim.json.encode { config_dir = config_dir, ignore_filters = ignore_filters }
  return {
    vault = vault,
    config_dir = config_dir,
    ignore_checker = ignore._build_ignore_checker(ignore_filters),
    version = version,
    key = vault .. "\0" .. version,
  }
end

---Share the index scope with unsaved-buffer overlays without requiring a disk file.
---@param opts { vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
---@return fun(path: string): boolean
function M.path_filter(opts)
  local context = current_context(opts)
  return function(path)
    path = normalize(path)
    return in_real_vault(path, context, { allow_missing = true })
      and not is_internal(path, context)
      and not is_ignored(path, context)
  end
end

---@param callback fun(rows: table<string, table>?, err: any?)
---@param opts { vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
function M.get(callback, opts)
  local context = current_context(opts)
  index:get(context.key, context, function(value, err)
    callback(value and value.rows or nil, err)
  end)
end

---@param opts { vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
---@return table<string, table>|nil
function M.peek(opts)
  local context = current_context(opts)
  local value = index:peek(context.key)
  return value and value.rows or nil
end

---@param opts { vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
function M.invalidate(opts)
  local context = current_context(opts)
  -- Preserve waiters shared by other workspaces if a rescan is already in
  -- flight. They must receive the replacement snapshot, not an empty failure.
  index:invalidate(context.key)
end

function M.clear()
  index:clear()
end

M._build_row = build_row

return M
