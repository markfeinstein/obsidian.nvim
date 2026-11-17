local all_files = require "obsidian.index.files"
local base_embed = require "obsidian.bases.embed"
local layout = require "obsidian.bases.layout"
local query = require "obsidian.bases.query"
local vault_scope = require "obsidian.bases.scope"
local watchfiles = require "obsidian.lsp.watchfiles"

local M = {}

local namespace = vim.api.nvim_create_namespace "obsidian-bases-inline"
local states = {}
local global_group
local unregister_watchfiles

local function state_buffers()
  return vim.tbl_keys(states)
end

---@class obsidian.bases.InlineItem
---@field key string
---@field anchor_row integer
---@field spec table|nil
---@field error string|nil
---@field query obsidian.bases.Query|nil
---@field query_key string|nil
---@field result obsidian.bases.Result|nil
---@field token integer

---@class obsidian.bases.InlineState
---@field buf integer
---@field enabled boolean
---@field items table<string, obsidian.bases.InlineItem>
---@field timer uv.uv_timer_t|nil
---@field generation integer

local function opts()
  local configured = Obsidian and Obsidian.opts and Obsidian.opts.bases
  return (configured and configured.inline) or {}
end

local function context_revision(path)
  local buf = require("obsidian.bases.buffer").find(path)
  if buf and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    return vim.api.nvim_buf_get_changedtick(buf)
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return 0
  end
  return table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":")
end

local function inline_width(buf)
  local width
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      width = math.max(width or 0, vim.api.nvim_win_get_width(win))
    end
  end
  width = width or vim.o.columns
  local maximum = math.max(20, math.floor(tonumber(opts().max_width) or 100))
  return math.max(20, math.min(maximum, width - 4))
end

local function append_line(lines, text, hl)
  lines[#lines + 1] = { text = layout.truncate(layout.single_line(text), lines.width), hl = hl or "Comment" }
end

local function append_table(lines, rows, columns)
  if #rows == 0 then
    return
  end
  local widths = layout.fit_table_widths(layout.table_widths(rows, columns), lines.width)
  local rendered = layout.table_lines(rows, columns, widths)
  for index, line in ipairs(rendered) do
    append_line(lines, line, index == 1 and "Title" or "Comment")
  end
end

local function append_rows(lines, result, max_rows)
  if #result.rows == 0 then
    append_line(lines, "No results", "Comment")
    return
  end

  local remaining = max_rows
  local view_type = result.view_type or "table"
  local use_list = view_type == "list"
  if view_type ~= "table" and view_type ~= "list" then
    append_line(lines, ("View type %q uses inline table fallback"):format(view_type), "DiagnosticWarn")
  end

  local function append_batch(rows)
    if remaining <= 0 then
      return
    end
    local batch = vim.list_slice(rows, 1, math.min(#rows, remaining))
    remaining = remaining - #batch
    if use_list then
      for _, line in ipairs(layout.list_lines(batch)) do
        append_line(lines, line, "Comment")
      end
    else
      append_table(lines, batch, result.columns)
    end
  end

  if result.groups then
    for _, group in ipairs(result.groups) do
      if remaining <= 0 then
        break
      end
      append_line(lines, ("%s (%d)"):format(group.label, #group.rows), "Special")
      append_batch(group.rows)
    end
  else
    append_batch(result.rows)
  end

  if remaining == 0 and #result.rows > max_rows then
    append_line(lines, ("… %d more rows; use :Obsidian bases for the full workspace"):format(#result.rows - max_rows))
  end
end

local function item_lines(item, width)
  local lines = { width = width }
  local result = item.result
  if item.error then
    append_line(lines, "Base · invalid", "DiagnosticError")
    append_line(lines, item.error, "DiagnosticError")
    return lines
  elseif not result then
    append_line(lines, "Base · loading…", "Comment")
    return lines
  end

  append_line(
    lines,
    ("Base · %s · %s/%s"):format(result.view_name or "View", result.status, result.freshness),
    result.status == "ready" and "Title" or "DiagnosticWarn"
  )
  local diagnostic_limit = math.max(1, math.floor(tonumber(opts().max_diagnostics) or 4))
  for index, diagnostic in ipairs(result.diagnostics or {}) do
    if index > diagnostic_limit then
      append_line(lines, ("… %d more diagnostics"):format(#result.diagnostics - diagnostic_limit), "DiagnosticWarn")
      break
    end
    append_line(lines, "! " .. diagnostic, "DiagnosticWarn")
  end

  if result.status == "refreshing" and result.freshness == "current" then
    append_line(lines, "Loading results…", "Comment")
  elseif result.status == "invalid" or result.status == "backend_unavailable" or result.status == "unsupported" then
    if result.freshness == "stale" and #result.rows > 0 then
      append_line(lines, "Showing stale results", "DiagnosticWarn")
      append_rows(lines, result, math.max(1, math.floor(tonumber(opts().max_rows) or 20)))
    elseif #(result.diagnostics or {}) == 0 then
      append_line(lines, "Results unavailable", "DiagnosticWarn")
    end
  else
    append_rows(lines, result, math.max(1, math.floor(tonumber(opts().max_rows) or 20)))
  end
  return lines
end

local function draw(state)
  if states[state.buf] ~= state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
  if not state.enabled or not vim.api.nvim_buf_is_loaded(state.buf) then
    return
  end

  local grouped = {}
  for _, item in pairs(state.items) do
    local anchor = item.anchor_row
    grouped[anchor] = grouped[anchor] or {}
    grouped[anchor][#grouped[anchor] + 1] = item
  end
  local line_count = vim.api.nvim_buf_line_count(state.buf)
  for anchor, items in pairs(grouped) do
    table.sort(items, function(left, right)
      return left.key < right.key
    end)
    local virtual = {}
    for _, item in ipairs(items) do
      for _, line in ipairs(item_lines(item, inline_width(state.buf))) do
        virtual[#virtual + 1] = { { "▏ " .. line.text, line.hl } }
      end
    end
    if #virtual > 0 and line_count > 0 then
      vim.api.nvim_buf_set_extmark(state.buf, namespace, math.min(anchor, line_count - 1), 0, {
        virt_lines = virtual,
        virt_lines_above = false,
        hl_mode = "combine",
      })
    end
  end
end

local function dispose_item(item)
  item.token = item.token + 1
  if item.query then
    item.query:dispose()
    item.query = nil
  end
end

local function refresh_item(state, item)
  item.token = item.token + 1
  local token = item.token
  if item.spec then
    item.error = nil
  else
    item.error = item.error or "Base definition is unavailable"
  end
  if item.error then
    if item.query then
      item.query:dispose()
      item.query = nil
      item.query_key = nil
    end
    item.result = nil
    return
  end

  local definition, err = item.spec.load()
  if not definition then
    item.error = err or "invalid Base definition"
    if item.query then
      item.query:dispose()
      item.query = nil
      item.query_key = nil
    end
    item.result = nil
    return
  end

  local key = table.concat({ definition.identity, definition.revision, definition.view_name }, "\0")
  local context = {
    path = item.spec.context_path,
    revision = item.spec.context_path and context_revision(item.spec.context_path) or 0,
    vault = item.spec.scope.vault,
    config_dir = item.spec.scope.config_dir,
    ignore_filters = vim.deepcopy(item.spec.scope.ignore_filters),
  }
  local function accept(result)
    if states[state.buf] ~= state or state.items[item.key] ~= item or item.token ~= token then
      return
    end
    item.result = result
    draw(state)
  end

  if item.query and item.query_key == key then
    item.query.context = context
    item.query.callback = accept
  else
    if item.query then
      item.query:dispose()
    end
    item.query_key = key
    item.query = query.new(definition, context, accept)
  end
  item.result = item.query.current
  item.query:refresh()
end

local function refresh_now(state, rescan)
  if states[state.buf] ~= state or not state.enabled or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.generation = state.generation + 1
  local previous = state.items
  local next_items = {}
  local invalidated = {}

  for _, discovered in ipairs(base_embed.discover(state.buf)) do
    local item = previous[discovered.key]
      or {
        key = discovered.key,
        query = nil,
        query_key = nil,
        result = nil,
        token = 0,
      }
    item.anchor_row = discovered.anchor_row
    item.spec = discovered.spec
    item.error = discovered.error
    next_items[item.key] = item
    if rescan and item.spec and not invalidated[item.spec.scope.vault] then
      invalidated[item.spec.scope.vault] = true
      all_files.invalidate(vault_scope.index_opts(item.spec.scope))
    end
  end

  state.items = next_items
  for key, item in pairs(previous) do
    if not next_items[key] then
      dispose_item(item)
    end
  end
  draw(state)
  for _, item in pairs(next_items) do
    refresh_item(state, item)
  end
  draw(state)
end

local function schedule_refresh(state)
  if states[state.buf] ~= state or not state.enabled then
    return
  end
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  local timer
  timer = vim.defer_fn(function()
    if state.timer ~= timer then
      return
    end
    state.timer = nil
    refresh_now(state, false)
  end, math.max(20, math.floor(tonumber(opts().debounce_ms) or 120)))
  state.timer = timer
end

local function event_affects_state(state, path)
  if path == "" then
    return false
  end
  for _, item in pairs(state.items) do
    if item.spec and vault_scope.contains_lexically(item.spec.scope, path) then
      return true
    end
  end
  local source = vim.api.nvim_buf_get_name(state.buf)
  if source ~= "" then
    local scope = vault_scope.capture(source)
    return scope and vault_scope.contains_lexically(scope, path) or false
  end
  return false
end

local function ensure_global_lifecycle()
  if not global_group then
    global_group = vim.api.nvim_create_augroup("obsidian.bases.inline", { clear = true })
    vim.api.nvim_create_autocmd({
      "BufWritePost",
      "TextChanged",
      "TextChangedI",
      "BufUnload",
      "BufDelete",
      "BufWipeout",
      "BufReadPost",
    }, {
      group = global_group,
      pattern = { "*.md", "*.markdown", "*.qmd", "*.base", "types.json" },
      callback = function(args)
        local path = vim.api.nvim_buf_get_name(args.buf)
        for _, buf in ipairs(state_buffers()) do
          local state = states[buf]
          if state then
            if
              args.buf == state.buf
              and (args.event == "BufUnload" or args.event == "BufDelete" or args.event == "BufWipeout")
            then
              M.detach(state.buf)
            elseif args.buf == state.buf or event_affects_state(state, path) then
              schedule_refresh(state)
            end
          end
        end
      end,
    })
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      group = global_group,
      callback = function()
        for _, state in pairs(states) do
          draw(state)
        end
      end,
    })
  end
  if unregister_watchfiles then
    return
  end
  unregister_watchfiles = watchfiles.register_handler(function(events)
    for _, state in pairs(states) do
      for _, item in pairs(state.items) do
        if item.spec and vault_scope.events_affect(item.spec.scope, events) then
          schedule_refresh(state)
          break
        end
      end
    end
  end)
end

---@param buf integer|nil
function M.attach(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  ensure_global_lifecycle()
  local state = states[buf]
  if not state then
    state = { buf = buf, enabled = true, items = {}, timer = nil, generation = 0 }
    states[buf] = state
  else
    state.enabled = true
  end
  vim.b[buf].obsidian_bases_inline_disabled = false
  refresh_now(state, false)
end

---@param buf integer|nil
function M.detach(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local state = states[buf]
  if not state then
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    end
    return
  end
  states[buf] = nil
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  for _, item in pairs(state.items) do
    dispose_item(item)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  end
  if vim.tbl_isempty(states) and unregister_watchfiles then
    unregister_watchfiles()
    unregister_watchfiles = nil
  end
end

---@param buf integer|nil
function M.disable(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  vim.b[buf].obsidian_bases_inline_disabled = true
  M.detach(buf)
end

---@param buf integer|nil
function M.toggle(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if states[buf] then
    M.disable(buf)
    return false
  end
  M.attach(buf)
  return true
end

---@param buf integer|nil
---@param options { rescan: boolean? }|nil
function M.refresh(buf, options)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local state = states[buf]
  if state then
    refresh_now(state, options and options.rescan == true)
  end
end

---@param buf integer|nil
---@return obsidian.bases.InlineState|nil
function M.get(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  return states[buf]
end

function M.enabled_by_default()
  return opts().enabled == true
end

function M.stop()
  for _, buf in ipairs(state_buffers()) do
    M.detach(buf)
  end
  if unregister_watchfiles then
    unregister_watchfiles()
    unregister_watchfiles = nil
  end
  if global_group then
    pcall(vim.api.nvim_del_augroup_by_id, global_group)
    global_group = nil
  end
end

M._namespace = namespace
M._draw = draw
M._refresh_now = refresh_now

return M
