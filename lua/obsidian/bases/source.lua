local buffer = require "obsidian.bases.buffer"
local cache_note = require "obsidian.cache.note"
local filetypes = require "obsidian.filetypes"
local all_files = require "obsidian.index.files"
local vault_scope = require "obsidian.bases.scope"
local uri = require "obsidian.uri"
local fs_util = require "obsidian.util.fs"

local M = {}

local markdown_extensions = {
  md = true,
  markdown = true,
  qmd = true,
}

local function normalize(path)
  return vim.fs.normalize(path)
end

local function relative_path(path, vault)
  if vim.startswith(path, vault .. "/") then
    return path:sub(#vault + 2)
  end
  return path
end

local function milliseconds(sec, nsec)
  if sec == nil then
    return nil
  end
  return (sec * 1000) + math.floor((nsec or 0) / 1000000)
end

---@param path string
---@param row table
---@param vault string
---@return table
local function query_row(path, row, vault)
  local rel = relative_path(path, vault)
  local ext = row.extension or filetypes.extension(path)
  local folder = vim.fs.dirname(rel)
  if folder == "." then
    folder = ""
  end
  local properties = vim.deepcopy(row.properties or {})
  local note = vim.deepcopy(properties)
  if row.aliases and note.aliases == nil then
    note.aliases = vim.deepcopy(row.aliases)
  end
  local revision = row._bases_revision
    or {
      kind = "disk",
      mtime_sec = row.stat and row.stat.mtime_sec or nil,
      mtime_nsec = row.stat and row.stat.mtime_nsec or nil,
      size = row.stat and row.stat.size or nil,
    }
  return {
    path = path,
    revision = vim.deepcopy(revision),
    note = note,
    cache = row,
    file = {
      path = rel,
      name = vim.fn.fnamemodify(path, ":t:r"),
      -- The evaluator otherwise derives basename by stripping another suffix
      -- from our already extensionless display name.
      basename = vim.fn.fnamemodify(path, ":t:r"),
      ext = ext,
      folder = folder,
      size = row.stat and row.stat.size or nil,
      ctime = row.stat and milliseconds(row.stat.ctime_sec, row.stat.ctime_nsec) or nil,
      mtime = row.stat and milliseconds(row.stat.mtime_sec, row.stat.mtime_nsec) or nil,
      tags = vim.deepcopy(row.tags or {}),
      links = {},
      embeds = {},
      properties = properties,
    },
  }
end

local function buffer_row(bufnr, path)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ---@type table|nil
  local stat = vim.uv.fs_stat(path)
  if not stat then
    stat = {
      type = "file",
      size = #table.concat(lines, "\n"),
      mtime = { sec = 0, nsec = vim.api.nvim_buf_get_changedtick(bufnr) },
      ctime = { sec = 0, nsec = 0 },
    }
  end
  return cache_note.build_from_lines(path, lines, stat, { preserve_properties = true })
end

local function generic_row(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local created = fs_util.creation_time(stat)
  return {
    kind = "file",
    extension = filetypes.extension(path),
    stat = {
      mtime_sec = stat.mtime.sec,
      mtime_nsec = stat.mtime.nsec,
      ctime_sec = created and created.sec or nil,
      ctime_nsec = created and created.nsec or nil,
      size = stat.size,
    },
  }
end

local function modified_markdown_buffers(scope)
  local included = all_files.path_filter(vault_scope.index_opts(scope))
  local result = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        path = normalize(path)
        if included(path) and markdown_extensions[filetypes.extension(path)] then
          result[#result + 1] = { bufnr = bufnr, path = path }
        end
      end
    end
  end
  return result
end

local function overlay_modified_buffers(rows, scope)
  for _, item in ipairs(modified_markdown_buffers(scope)) do
    local row = buffer_row(item.bufnr, item.path)
    if row then
      row._bases_revision = {
        kind = "buffer",
        changedtick = vim.api.nvim_buf_get_changedtick(item.bufnr),
      }
      rows[item.path] = row
    end
  end
end

local function lookup_add(lookup, key, path)
  key = key:lower()
  local values = lookup[key]
  if not values then
    lookup[key] = { path }
  elseif not vim.tbl_contains(values, path) then
    values[#values + 1] = path
  end
end

local function without_markdown_extension(path)
  local extension = filetypes.extension(path)
  if markdown_extensions[extension] then
    return path:sub(1, -(#extension + 2))
  end
  return path
end

local function link_lookup(rows)
  local lookup = { paths = {}, note_paths = {}, aliases = {} }
  for _, row in ipairs(rows) do
    local rel = row.file.path:gsub("\\", "/")
    lookup_add(lookup.paths, rel, row.path)
    lookup_add(lookup.note_paths, without_markdown_extension(rel), row.path)
    local suffix = rel
    while suffix do
      lookup_add(lookup.aliases, suffix, row.path)
      lookup_add(lookup.aliases, without_markdown_extension(suffix), row.path)
      suffix = suffix:match "^[^/]+/(.+)$"
    end
  end
  return lookup
end

local function is_internal_target(target)
  return not uri.is_uri(target) and not vim.startswith(target, "//")
end

local function target_candidates(target, source_rel, kind)
  if target == "" or not is_internal_target(target) then
    return {}
  end
  local ok, decoded = pcall(vim.uri_decode, target)
  target = (ok and decoded or target):gsub("\\", "/"):gsub("[#%^].*$", "")
  local candidates = {}
  local function add(value, exact)
    value = vim.fs.normalize(value):gsub("\\", "/"):gsub("^%./", ""):gsub("^/", "")
    candidates[#candidates + 1] = { path = value, exact = exact }
  end
  if vim.startswith(target, "./") or vim.startswith(target, "../") then
    add(vim.fs.joinpath(vim.fs.dirname(source_rel), target), true)
  else
    -- Markdown paths need not start with './' to be source-relative. Try
    -- the containing folder before the existing vault/shortest-path lookup.
    if kind == "markdown" and not vim.startswith(target, "/") then
      add(vim.fs.joinpath(vim.fs.dirname(source_rel), target), true)
    end
    add(target, vim.startswith(target, "/"))
  end
  return candidates
end

local function resolve_target(target, source_rel, lookup, kind)
  for _, candidate in ipairs(target_candidates(target, source_rel, kind)) do
    local key = candidate.path:lower()
    -- Never let a basename elsewhere make an exact path ambiguous. Explicit
    -- relative/root paths must also not fall back to a different vault file.
    local matches = lookup.paths[key] or lookup.note_paths[key] or (not candidate.exact and lookup.aliases[key] or nil)
    if matches then
      return #matches == 1 and matches[1] or nil
    end
  end
end

local function enrich_outgoing(row, lookup, vault)
  for _, outgoing in ipairs(row.cache.links_out or {}) do
    -- An unresolved internal link still belongs in file.links; an external URL
    -- does not. Resolution failure alone cannot distinguish those two cases.
    if is_internal_target(outgoing.target or "") then
      local target_path = resolve_target(outgoing.target or "", row.file.path, lookup, outgoing.kind)
      local link = {
        path = outgoing.target,
        resolvedPath = target_path and relative_path(target_path, vault) or nil,
      }
      row.file.links[#row.file.links + 1] = link
      if outgoing.embed then
        row.file.embeds[#row.file.embeds + 1] = link
      end
    end
  end
end

local function enrich_backlinks(rows, lookup)
  local backlinks_by_path = {}
  for _, row in ipairs(rows) do
    local backlinks = {}
    backlinks_by_path[row.path] = backlinks
    row.file.backlinks = backlinks
  end
  local seen = {}
  for _, source_row in ipairs(rows) do
    for _, outgoing in ipairs(source_row.cache.links_out or {}) do
      local target_path = resolve_target(outgoing.target or "", source_row.file.path, lookup, outgoing.kind)
      if target_path then
        local key = target_path .. "\0" .. source_row.path
        if not seen[key] then
          seen[key] = true
          local backlinks = backlinks_by_path[target_path]
          if backlinks then
            backlinks[#backlinks + 1] = {
              path = source_row.file.path,
              resolvedPath = source_row.file.path,
            }
          end
        end
      end
    end
  end
  for _, backlinks in pairs(backlinks_by_path) do
    table.sort(backlinks, function(left, right)
      return left.path < right.path
    end)
  end
end

local function finish(index_rows, callback, opts, scope)
  local vault = scope.vault
  local rows = {}
  for path, row in pairs(index_rows or {}) do
    rows[path] = row
  end
  overlay_modified_buffers(rows, scope)
  local result = {}
  for path, row in pairs(rows) do
    result[#result + 1] = query_row(path, row, vault)
  end
  table.sort(result, function(left, right)
    return left.path < right.path
  end)
  local lookup = link_lookup(result)
  for _, row in ipairs(result) do
    enrich_outgoing(row, lookup, vault)
  end
  if opts.backlinks then
    enrich_backlinks(result, lookup)
  end
  callback(result, {})
end

local function scoped_options(opts)
  opts = opts or {}
  if opts.vault then
    return assert(vault_scope.new(opts.vault, {
      sync = { config_dir = opts.config_dir },
      file = { ignore_filters = opts.ignore_filters },
    }))
  end
  return assert(vault_scope.capture())
end

---@param callback fun(rows: table[], limitations: string[])
---@param opts { backlinks: boolean?, vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
function M.collect(callback, opts)
  opts = opts or {}
  local scope = scoped_options(opts)
  all_files.get(function(rows, err)
    if not rows then
      callback({}, { "local all-files index failed: " .. tostring(err) })
      return
    end
    finish(rows, callback, opts, scope)
  end, vault_scope.index_opts(scope))
end

---@param opts { vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
---@return boolean
function M.has_unsaved_overlays(opts)
  return #modified_markdown_buffers(scoped_options(opts)) > 0
end

---@param path string
---@param opts { vault: string?, config_dir: string?, ignore_filters: string[]? }|nil
---@return table|nil
function M.context_file(path, opts)
  local scope = scoped_options(opts)
  path = normalize(path)
  if not vault_scope.contains(scope, path, { allow_missing = true }) then
    return nil
  end
  local ext = filetypes.extension(path)
  local bufnr = buffer.find(path)
  local row
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified and markdown_extensions[ext] then
    row = buffer_row(bufnr, path)
  else
    local indexed = all_files.peek(vault_scope.index_opts(scope))
    row = indexed and indexed[path] or nil
    if not row and markdown_extensions[ext] then
      row = cache_note.build(path, scope.vault, { preserve_properties = true })
    end
    row = row or generic_row(path)
  end
  if not row then
    return nil
  end
  local context = query_row(path, row, scope.vault)
  local candidates = { context }
  for candidate_path in pairs(all_files.peek(vault_scope.index_opts(scope)) or {}) do
    if candidate_path ~= path then
      candidates[#candidates + 1] = {
        path = candidate_path,
        file = { path = relative_path(candidate_path, scope.vault) },
      }
    end
  end
  enrich_outgoing(context, link_lookup(candidates), scope.vault)
  return context.file
end

return M
