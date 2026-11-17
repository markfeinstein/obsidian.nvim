local BufferDocument = require "obsidian.document"
local Definition = require "obsidian.bases.definition"
local Document = require "obsidian.parse.document"
local embeds = require "obsidian.parse.embeds"
local Range = require "obsidian.range"
local resolver = require "obsidian.bases.resolver"
local vault_scope = require "obsidian.bases.scope"

local M = {}

local function is_base_target(target)
  local path = embeds.target_parts(target)
  return path:lower():match "%.base$" ~= nil
end

local function active_match(document, row, match)
  return not document:intersects(Range.new(row, match.col, row, match.end_col), Document.BODY_EXCLUSIONS)
end

local function linked_spec(target, source_path)
  local scope, scope_err = vault_scope.capture(source_path)
  if not scope then
    return nil, scope_err
  elseif not vault_scope.contains(scope, source_path, { allow_missing = true }) then
    return nil, "Base source context is outside the vault: " .. source_path
  end
  local raw_path, view = embeds.target_parts(target)
  local path, path_err = resolver.resolve_path(raw_path, source_path, scope)
  if not path then
    return nil, path_err
  end
  local spec = {
    path = path,
    view = view,
    context_path = source_path,
    scope = vault_scope.copy(scope),
    load = function()
      return resolver.load(path, view, scope)
    end,
  }
  return spec, nil
end

local function fence_info(line)
  local marker, info = line:match "^%s*(```+)%s*([^%s`]*)%s*$"
  if not marker then
    marker, info = line:match "^%s*(~~~+)%s*([^%s~]*)%s*$"
  end
  if marker and info and info:lower() == "base" then
    return marker
  end
end

local function fenced_region_spec(buf, region, source_path)
  local scope, scope_err = vault_scope.capture(source_path)
  if not scope then
    return nil, scope_err
  elseif not vault_scope.contains(scope, source_path, { allow_missing = true }) then
    return nil, "Base source context is outside the vault: " .. source_path
  end
  local opener_row = region.range.start_row
  local identity = table.concat({ source_path, "inline-base", opener_row }, ":")
  local spec = {
    path = identity,
    view = nil,
    context_path = source_path,
    scope = vault_scope.copy(scope),
    inline = true,
    load = function()
      if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
        return nil, "invalid Base definition: embedding buffer is no longer available"
      end
      local current = BufferDocument.get(buf)
      local current_region
      for _, candidate in ipairs(current.regions) do
        if candidate.kind == "fenced_code" and candidate.range.start_row == opener_row then
          current_region = candidate
          break
        end
      end
      if not current_region or not fence_info(current.lines[opener_row + 1] or "") then
        return nil, "invalid Base definition: fenced base block was moved or removed"
      end
      local current_close = current_region.closer_range and current_region.closer_range.start_row
        or current_region.range.end_row
      local lines = {}
      for source_row = opener_row + 1, current_close - 1 do
        lines[#lines + 1] = current.lines[source_row + 1]
      end
      return Definition.parse(lines, {
        identity = identity,
        revision = vim.api.nvim_buf_get_changedtick(buf),
      })
    end,
  }
  return spec, nil
end

local function fenced_spec(buf, document, row, source_path)
  for _, region in ipairs(document.regions) do
    if region.kind == "fenced_code" and region.range.start_row <= row and row < region.range.end_row then
      local opener = document.lines[region.range.start_row + 1] or ""
      if not fence_info(opener) then
        return nil
      end
      return fenced_region_spec(buf, region, source_path)
    end
  end
end

---@param buf integer|nil
---@return table|nil
---@return string|nil
function M.at_cursor(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local source_path = vim.api.nvim_buf_get_name(buf)
  if source_path == "" then
    return nil, "embedded Bases require a named containing note"
  end
  source_path = vim.fs.normalize(source_path)
  local document = BufferDocument.get(buf)
  local line = document.lines[row + 1] or ""
  for _, match in ipairs(embeds.find(line)) do
    if
      match.col <= col
      and col < match.end_col
      and is_base_target(match.target)
      and active_match(document, row, match)
    then
      return linked_spec(match.target, source_path)
    end
  end
  return fenced_spec(buf, document, row, source_path)
end

---@param target string
---@param buf integer
---@param row integer
---@param document obsidian.parse.Document
---@param source_match obsidian.parse.embeds.Match|nil
---@return { text: string, path: string? }|nil
function M.preview(target, buf, row, document, source_match)
  if not is_base_target(target) then
    return nil
  end
  local match = source_match
  if not match then
    for _, candidate in ipairs(embeds.find(document.lines[row + 1] or "")) do
      if candidate.target == target then
        match = candidate
        break
      end
    end
  end
  if not match or not active_match(document, row, match) then
    return nil
  end
  local source_path = vim.api.nvim_buf_get_name(buf)
  local spec, err = linked_spec(target, vim.fs.normalize(source_path))
  if not spec then
    return { text = "Base unavailable: " .. err }
  end
  local label = vim.fs.basename(spec.path)
  if spec.view then
    label = label .. "#" .. spec.view
  end
  return {
    text = "Base: " .. label .. " · :Obsidian bases",
    path = spec.path,
  }
end

---@class obsidian.bases.EmbeddedDefinition
---@field key string
---@field anchor_row integer 0-indexed source row after which virtual lines render
---@field spec table|nil
---@field error string|nil
---@field kind "linked"|"fenced"

---Discover every eligible Base embed in a Markdown buffer.
---@param buf integer|nil
---@return obsidian.bases.EmbeddedDefinition[]
function M.discover(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return {}
  end
  local source_path = vim.api.nvim_buf_get_name(buf)
  if source_path == "" then
    return {}
  end
  source_path = vim.fs.normalize(source_path)
  local document = BufferDocument.get(buf)
  local found = {}

  for line_num, line in ipairs(document.lines) do
    local row = line_num - 1
    for _, match in ipairs(embeds.find(line)) do
      if is_base_target(match.target) and active_match(document, row, match) then
        local spec, err = linked_spec(match.target, source_path)
        found[#found + 1] = {
          key = table.concat({ "linked", row, match.col, match.end_col, match.target }, ":"),
          anchor_row = row,
          spec = spec,
          error = err,
          kind = "linked",
        }
      end
    end
  end

  for _, region in ipairs(document.regions) do
    if region.kind == "fenced_code" and fence_info(document.lines[region.range.start_row + 1] or "") then
      local spec, err = fenced_region_spec(buf, region, source_path)
      local anchor = region.closer_range and region.closer_range.start_row
        or math.max(region.range.start_row, region.range.end_row - 1)
      found[#found + 1] = {
        key = table.concat({ "fenced", region.range.start_row }, ":"),
        anchor_row = anchor,
        spec = spec,
        error = err,
        kind = "fenced",
      }
    end
  end

  table.sort(found, function(left, right)
    if left.anchor_row == right.anchor_row then
      return left.key < right.key
    end
    return left.anchor_row < right.anchor_row
  end)
  return found
end

M.is_base_target = is_base_target
M.linked_spec = linked_spec

return M
