local buffer = require "obsidian.bases.buffer"
local definition = require "obsidian.bases.definition"
local filetypes = require "obsidian.filetypes"
local Path = require "obsidian.path"
local vault_scope = require "obsidian.bases.scope"

local M = {}

local function split_target(target)
  local path, view = target:match "^(.-)#(.*)$"
  return path or target, view ~= "" and view or nil
end

local function is_base(path)
  return filetypes.extension(path) == "base"
end

local function resolve_shortest(target, scope)
  -- Absolute and explicitly relative paths must not silently fall back to a
  -- different file elsewhere. Shortest paths may contain a directory suffix.
  if Path.new(target):is_absolute() then
    return nil
  end
  for component in target:gmatch "[^/\\]+" do
    if component == "." or component == ".." then
      return nil
    end
  end

  local included = require("obsidian.index.files").path_filter(vault_scope.index_opts(scope))
  local suffix = "/" .. vim.fs.normalize(target):gsub("\\", "/"):lower()
  local deadline = vim.uv.hrtime() + 1000 * 1000000
  local found, found_real
  -- Discover filenames only, without building/parsing the all-files index just
  -- to resolve an embed. Bound cold searches and fail closed on ambiguity.
  for relative, kind in
    vim.fs.dir(scope.vault, {
      depth = 2147483647,
      skip = function(directory)
        return included(vim.fs.joinpath(scope.vault, directory))
      end,
    })
  do
    if vim.uv.hrtime() >= deadline then
      return nil, "Base lookup timed out; use a vault-relative path: " .. target
    end
    if (kind == "file" or kind == "link") and vim.endswith("/" .. relative:lower(), suffix) then
      local path = vim.fs.joinpath(scope.vault, relative)
      local stat = vim.uv.fs_stat(path)
      if stat and stat.type == "file" and included(path) then
        local real = vim.uv.fs_realpath(path)
        if found and real ~= found_real then
          return nil, "Base target is ambiguous; use a vault-relative path: " .. target
        end
        found, found_real = path, real
      end
    end
  end
  return found
end

local function resolve_path(target, source_path, scope)
  target = vim.trim(target)
  if target == "" then
    return nil, "Base target is empty"
  end
  target = vim.uri_decode(target)
  if not is_base(target) then
    target = target .. ".base"
  end
  scope = scope or assert(vault_scope.capture(source_path))

  local candidates = {}
  if Path.new(target):is_absolute() then
    candidates[1] = target
  else
    if source_path and source_path ~= "" then
      candidates[#candidates + 1] = vim.fs.joinpath(vim.fs.dirname(source_path), target)
    end
    -- Explicit relative targets have exactly one meaning: relative to the
    -- containing note. Do not redirect a missing ./file to a vault-root file.
    if not target:match "^%.%.?[/\\]" then
      candidates[#candidates + 1] = vim.fs.joinpath(scope.vault, target)
    end
  end

  local outside = false
  local included = require("obsidian.index.files").path_filter(vault_scope.index_opts(scope))
  for _, candidate in ipairs(candidates) do
    candidate = vim.fs.normalize(candidate)
    local stat = vim.uv.fs_stat(candidate)
    if stat then
      if stat.type == "file" and vault_scope.contains(scope, candidate) and included(candidate) then
        return candidate, nil
      elseif not vault_scope.contains(scope, candidate) then
        outside = true
      end
    elseif not vault_scope.contains(scope, candidate, { allow_missing = true }) then
      outside = true
    end
  end
  if outside then
    return nil, "Base target is outside the vault: " .. target
  end
  local shortest, shortest_err = resolve_shortest(target, scope)
  if shortest or shortest_err then
    return shortest, shortest_err
  end
  return nil, "Base not found: " .. target
end

---@param path string
---@param view string|nil
---@param scope obsidian.bases.VaultScope|nil
---@return obsidian.bases.Definition|nil
---@return string|nil
function M.load(path, view, scope)
  path = vim.fs.normalize(path)
  if scope and not vault_scope.contains(scope, path) then
    return nil, "Base target is outside the vault: " .. path
  end
  local bufnr = buffer.find(path)
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
    return definition.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
      path = path,
      identity = path,
      revision = vim.api.nvim_buf_get_changedtick(bufnr),
      view = view,
    })
  end
  return definition.from_file(path, { view = view })
end

---@param target string|nil
---@param opts { source_path: string? }|?
---@return { path: string, view: string|nil, context_path: string, scope: obsidian.bases.VaultScope, load: fun(): obsidian.bases.Definition?, string? }|nil
---@return string|nil
function M.resolve(target, opts)
  opts = opts or {}
  local source_path = opts.source_path or vim.api.nvim_buf_get_name(0)
  local scope, scope_err = vault_scope.capture(source_path)
  if not scope then
    return nil, scope_err
  end
  if
    source_path ~= ""
    and not source_path:match "^%a[%w+.-]*://"
    and not vault_scope.contains(scope, source_path, { allow_missing = true })
  then
    return nil, "Base source context is outside the vault: " .. source_path
  end
  local path, view
  if target and vim.trim(target) ~= "" then
    local raw_path
    raw_path, view = split_target(target)
    local resolve_err
    path, resolve_err = resolve_path(raw_path, source_path, scope)
    if not path then
      return nil, resolve_err
    end
  elseif is_base(source_path) then
    local resolve_err
    path, resolve_err = resolve_path(source_path, nil, scope)
    if not path then
      return nil, resolve_err
    end
  else
    return nil, "no .base file or Base target was provided"
  end

  local context_path = path
  local spec = {
    path = path,
    view = view,
    context_path = context_path,
    scope = vault_scope.copy(scope),
    load = function()
      return M.load(path, view, scope)
    end,
  }
  return spec, nil
end

M.split_target = split_target
M.resolve_path = resolve_path

return M
