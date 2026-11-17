local all_files = require "obsidian.index.files"
local buffer = require "obsidian.bases.buffer"
local compat = require "obsidian.bases.compat"
local compare = require "obsidian.bases.compare"
local edit = require "obsidian.bases.edit"
local images = require "obsidian.bases.images"
local layout = require "obsidian.bases.layout"
local property_types = require "obsidian.properties.types"
local property_types_edit = require "obsidian.properties.types_edit"
local query = require "obsidian.bases.query"
local vault_scope = require "obsidian.bases.scope"
local watchfiles = require "obsidian.lsp.watchfiles"

local M = {}

---@class obsidian.bases.WorkspaceState
---@field buf integer
---@field spec table
---@field scope obsidian.bases.VaultScope
---@field group integer
---@field query obsidian.bases.Query|nil
---@field query_key string|nil
---@field result obsidian.bases.Result|nil
---@field line_paths table<integer, string>
---@field line_rows table<integer, table>
---@field column_spans table[]
---@field line_groups table<integer, string>
---@field group_lines integer[]
---@field collapsed table<string, boolean>
---@field board_mode boolean
---@field board_cards table[]
---@field board_columns table[]
---@field cards_mode boolean
---@field gallery_cards table[]
---@field gallery_columns integer
---@field original_wrap boolean
---@field image_id integer|nil
---@field thumbnails_enabled boolean
---@field thumbnails_supported boolean
---@field thumbnail_ids table<string, integer>
---@field thumbnail_data table<string, string>
---@field thumbnail_generation integer
---@field thumbnail_pending boolean
---@field unregister fun()|nil
---@field refresh_timer uv.uv_timer_t|nil
---@field definition obsidian.bases.Definition|nil
---@field comparison table|nil
---@field comparison_generation integer
---@field comparison_job any|nil
---@field reflow_pending boolean
---@field raw_buf integer|nil

---@type table<integer, obsidian.bases.WorkspaceState>
local states = {}

local function context_revision(path)
  local bufnr = buffer.find(path)
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
    return vim.api.nvim_buf_get_changedtick(bufnr)
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return 0
  end
  return table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":")
end

local function cancel_comparison(state, clear)
  state.comparison_generation = state.comparison_generation + 1
  if state.comparison_job and state.comparison_job.kill then
    pcall(state.comparison_job.kill, state.comparison_job, 15)
  end
  state.comparison_job = nil
  if clear then
    state.comparison = nil
  end
end

local function clear_image(state)
  if state.image_id then
    compat.delete_image(state.image_id)
    state.image_id = nil
  end
end

local function clear_thumbnails(state)
  state.thumbnail_generation = state.thumbnail_generation + 1
  for _, id in pairs(state.thumbnail_ids or {}) do
    compat.delete_image(id)
  end
  state.thumbnail_ids = {}
  state.thumbnail_data = {}
  state.thumbnail_pending = false
end

local function thumbnail_viewport(win)
  return vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    return {
      first_line = vim.fn.line "w0",
      last_line = vim.fn.line "w$",
      first_col = view.leftcol + 1,
      last_col = view.leftcol + vim.api.nvim_win_get_width(win),
    }
  end)
end

local function update_thumbnails(state)
  if not state.thumbnails_enabled or not state.thumbnails_supported or not state.cards_mode or not state.result then
    return
  end
  local wins = vim.fn.win_findbuf(state.buf)
  local win = wins[1]
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  state.thumbnail_generation = state.thumbnail_generation + 1
  local generation = state.thumbnail_generation
  local viewport = thumbnail_viewport(win)
  local desired = {}
  local count = 0

  for _, card in ipairs(state.gallery_cards) do
    if
      count < 12
      and card.image_line
      and card.image_line <= viewport.last_line
      and card.image_line + card.image_height - 1 >= viewport.first_line
      and card.vstart <= viewport.last_col
      and card.vfinish >= viewport.first_col
    then
      local resolved = images.resolve(card.row, state.result.view, state.scope)
      if resolved then
        local key = card.row.path
        -- Title rows and image rows have different UTF-8 byte lengths.
        local image_col = vim.fn.virtcol2col(win, card.image_line, card.vstart + 1)
        local position = vim.fn.screenpos(win, card.image_line, image_col)
        if position and position.row > 0 and position.col > 0 then
          count = count + 1
          desired[key] = true
          local opts = {
            row = position.row,
            col = position.col,
            width = 22,
            height = card.image_height,
            zindex = 40,
          }
          local existing = state.thumbnail_ids[key]
          if existing then
            local ok = compat.update_image(existing, opts)
            if not ok then
              compat.delete_image(existing)
              state.thumbnail_ids[key] = nil
            end
          end
          if not state.thumbnail_ids[key] then
            local data = state.thumbnail_data[key]
            if not data then
              data = images.read(resolved.path, state.scope)
              state.thumbnail_data[key] = data
            end
            if data then
              vim.schedule(function()
                if states[state.buf] ~= state or state.thumbnail_generation ~= generation or not desired[key] then
                  return
                end
                local id = compat.show_image(data, opts)
                if id then
                  state.thumbnail_ids[key] = id
                end
              end)
            end
          end
        end
      end
    end
  end

  for key, id in pairs(state.thumbnail_ids) do
    if not desired[key] then
      compat.delete_image(id)
      state.thumbnail_ids[key] = nil
      state.thumbnail_data[key] = nil
    end
  end
  for key in pairs(state.thumbnail_data) do
    if not desired[key] then
      state.thumbnail_data[key] = nil
    end
  end
end

local function schedule_thumbnail_update(state)
  if state.thumbnail_pending then
    return
  end
  state.thumbnail_pending = true
  vim.defer_fn(function()
    state.thumbnail_pending = false
    if states[state.buf] == state then
      update_thumbnails(state)
    end
  end, 30)
end

local function workspace_window(state)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == state.buf then
    return current
  end
  for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
    if vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
end

local function workspace_card_columns(state)
  local win = workspace_window(state)
  if not win then
    return state.gallery_columns or 1
  end
  return layout.cards_column_count(vim.api.nvim_win_get_width(win))
end

---@param state obsidian.bases.WorkspaceState
---@param result obsidian.bases.Result
local function render(state, result)
  if not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  clear_image(state)
  clear_thumbnails(state)
  state.result = result
  state.line_paths = {}
  state.line_rows = {}
  state.line_groups = {}
  state.group_lines = {}
  state.column_spans = {}
  state.board_mode = false
  state.board_cards = {}
  state.board_columns = {}
  state.cards_mode = result.view_type == "cards"
  state.gallery_cards = {}
  state.gallery_columns = result.view_type == "cards" and workspace_card_columns(state) or 1
  ---@type string[]
  local lines = {
    ("Bases · %s"):format(result.view_name),
    ("Backend: %s %s · Status: %s/%s/%s"):format(
      result.backend.name,
      result.backend.version,
      result.status,
      result.freshness,
      result.completeness
    ),
    ("Definition: %s"):format(state.spec.path or "inline"),
    ("Context: %s"):format(state.spec.context_path or "none"),
    ("Results: %d matched · %d candidates"):format(result.matched_count, result.source_count),
    state.comparison and ("Obsidian CLI comparison: " .. state.comparison.summary)
      or "Obsidian CLI comparison: not run · C compare explicitly",
    "Actions: <CR> open/toggle · e edit · t property type · C compare · hjkl cards · i image · I thumbnails · [g/]g groups · r refresh · q close",
  }
  if state.comparison and state.comparison.diagnostics then
    local local_only = state.comparison.diagnostics.only_local or {}
    local cli_only = state.comparison.diagnostics.only_cli or {}
    for _, path in ipairs(vim.list_slice(local_only, 1, 5)) do
      lines[#lines + 1] = "  ! local only: " .. path
    end
    for _, path in ipairs(vim.list_slice(cli_only, 1, 5)) do
      lines[#lines + 1] = "  ! Obsidian only: " .. path
    end
  end
  if result.view_type == "cards" and result.view and type(result.view.image) == "string" then
    local image_status = compat.image_status()
    if state.thumbnails_enabled then
      lines[#lines + 1] = "Images: viewport thumbnails enabled · at most 12 visible local PNGs"
    else
      lines[#lines + 1] = image_status.api
          and "Images: text fallback · i previews one card · I enables visible thumbnails"
        or "Images: text fallback · vim.ui.img is unavailable"
    end
  end
  local diagnostic_line
  if #result.diagnostics > 0 then
    diagnostic_line = #lines + 1
    lines[#lines + 1] = "Diagnostics:"
    for _, diagnostic in ipairs(result.diagnostics) do
      lines[#lines + 1] = "  ! " .. diagnostic
    end
  end
  lines[#lines + 1] = ""

  -- All groups share column widths. Compute them lazily once, not once per group.
  local widths
  local function append_rows(rows)
    local start = #lines
    if result.view_type == "cards" then
      local rendered_cards, cards, column_count =
        layout.cards_lines(rows, state.thumbnails_enabled, state.gallery_columns)
      state.gallery_columns = column_count
      vim.list_extend(lines, rendered_cards)
      for _, card in ipairs(cards) do
        card.start_line = card.start_line + start
        card.end_line = card.end_line + start
        card.image_line = card.image_line and card.image_line + start or nil
        card.line = card.line + start
        card.index = #state.gallery_cards + 1
        state.gallery_cards[#state.gallery_cards + 1] = card
      end
    elseif result.view_type == "list" then
      vim.list_extend(lines, layout.list_lines(rows))
      for index, row in ipairs(rows) do
        local line = start + index
        state.line_paths[line] = row.path
        state.line_rows[line] = row
      end
    else
      widths = widths or layout.table_widths(result.rows, result.columns)
      local rendered_table, column_spans = layout.table_lines(rows, result.columns, widths)
      state.column_spans = column_spans
      vim.list_extend(lines, rendered_table)
      for index, row in ipairs(rows) do
        local line = start + 2 + index
        state.line_paths[line] = row.path
        state.line_rows[line] = row
      end
    end
  end

  if result.view_type == "kanban" and result.groups then
    state.board_mode = true
    local start = #lines
    local rendered_board, cards, columns = layout.board_lines(result.groups)
    vim.list_extend(lines, rendered_board)
    for _, card in ipairs(cards) do
      card.line = card.line + start
    end
    for _, column in ipairs(columns) do
      column.line = column.line + start
    end
    state.board_cards = cards
    state.board_columns = columns
  elseif result.groups then
    for _, group in ipairs(result.groups) do
      local line = #lines + 1
      local collapsed = state.collapsed[group.key] == true
      lines[line] = ("%s %s (%d)"):format(collapsed and "▸" or "▾", group.label, #group.rows)
      state.line_groups[line] = group.key
      state.group_lines[#state.group_lines + 1] = line
      if not collapsed and #group.rows > 0 then
        append_rows(group.rows)
      end
    end
  else
    append_rows(result.rows)
  end

  -- Headers, group labels, diagnostics, and list rows can also contain controls.
  lines = vim.tbl_map(layout.single_line, lines)
  vim.bo[state.buf].modifiable = true
  vim.bo[state.buf].readonly = false
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.bo[state.buf].readonly = true
  vim.api.nvim_buf_clear_namespace(state.buf, -1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.buf, -1, "Title", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.buf, -1, "Comment", 1, 0, -1)
  if diagnostic_line then
    vim.api.nvim_buf_add_highlight(state.buf, -1, "DiagnosticWarn", diagnostic_line - 1, 0, -1)
  end
  for _, line in ipairs(state.group_lines) do
    vim.api.nvim_buf_add_highlight(state.buf, -1, "Special", line - 1, 0, -1)
  end
  for _, column in ipairs(state.board_columns) do
    vim.api.nvim_buf_add_highlight(
      state.buf,
      -1,
      "Special",
      math.floor(column.line - 1),
      math.floor(column.col),
      math.floor(column.end_col)
    )
  end
  for _, card in ipairs(state.gallery_cards) do
    vim.api.nvim_buf_add_highlight(
      state.buf,
      -1,
      "Directory",
      math.floor(card.start_line - 1),
      math.floor(card.col),
      math.floor(card.end_col)
    )
  end
  for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
    if state.board_mode or state.cards_mode then
      vim.wo[win].wrap = false
    else
      vim.wo[win].wrap = state.original_wrap
    end
  end
  if state.thumbnails_enabled then
    schedule_thumbnail_update(state)
  end
end

local function gallery_path_in_window(state, win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local virtual_column = vim.api.nvim_win_call(win, function()
    return vim.fn.virtcol "."
  end)
  for _, card in ipairs(state.gallery_cards) do
    if
      card.start_line <= line
      and line <= card.end_line
      and card.vstart <= virtual_column
      and virtual_column <= card.vfinish
    then
      return card.row.path
    end
  end
end

local function schedule_card_reflow(state)
  if state.reflow_pending or not state.cards_mode or not state.result then
    return
  end
  state.reflow_pending = true
  vim.defer_fn(function()
    state.reflow_pending = false
    if states[state.buf] ~= state or not state.cards_mode or not state.result then
      return
    end
    local win = workspace_window(state)
    local columns = workspace_card_columns(state)
    if columns == state.gallery_columns then
      return
    end
    local selected_path = gallery_path_in_window(state, win)
    render(state, state.result)
    if selected_path and win and vim.api.nvim_win_is_valid(win) then
      for _, card in ipairs(state.gallery_cards) do
        if card.row.path == selected_path then
          vim.api.nvim_win_set_cursor(win, { card.line, card.col })
          break
        end
      end
    end
  end, 40)
end

---@param state obsidian.bases.WorkspaceState
local function render_invalid(state, message)
  local backend = require("obsidian.bases.worker").status()
  render(state, {
    identity = "invalid",
    status = "invalid",
    freshness = "current",
    completeness = "unsupported",
    backend = { name = backend.name, version = backend.version },
    view_name = state.spec.view or "Base",
    columns = { { property = "file.name", label = "file.name" } },
    rows = {},
    diagnostics = { message },
    source_count = 0,
    matched_count = 0,
  })
end

---@param state obsidian.bases.WorkspaceState
local function refresh(state, rescan)
  if not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  if rescan then
    -- Manual refresh is also the recovery path for missing watch events. Keep
    -- automatic refreshes incremental, and invalidate only this pinned scope.
    if state.query then
      state.query:dispose()
    end
    all_files.invalidate(vault_scope.index_opts(state.scope))
  end
  cancel_comparison(state, true)
  local definition, err = state.spec.load()
  if not definition then
    if state.query then
      state.query:dispose()
      state.query = nil
      state.query_key = nil
    end
    state.definition = nil
    render_invalid(state, assert(err, "Base definition failed without an error message"))
    return
  end

  state.definition = definition
  local key = table.concat({ definition.identity, definition.revision, definition.view_name }, "\0")
  local context = {
    path = state.spec.context_path,
    revision = state.spec.context_path and context_revision(state.spec.context_path) or 0,
    vault = state.scope.vault,
    config_dir = state.scope.config_dir,
    ignore_filters = vim.deepcopy(state.scope.ignore_filters),
  }
  if state.query and state.query_key == key then
    state.query.context = context
    state.query:refresh()
    return
  end
  if state.query then
    state.query:dispose()
  end
  state.query_key = key
  state.query = query.new(definition, context, function(result)
    render(state, result)
  end)
  state.query:refresh()
end

local function schedule_refresh(state)
  if state.refresh_timer then
    state.refresh_timer:stop()
    state.refresh_timer:close()
  end
  local timer
  timer = vim.defer_fn(function()
    if state.refresh_timer ~= timer then
      return
    end
    state.refresh_timer = nil
    if states[state.buf] == state then
      refresh(state)
    end
  end, 80)
  state.refresh_timer = timer
end

local function board_card_under_cursor(state)
  if not state.board_mode then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local virtual_column = vim.fn.virtcol "."
  for _, card in ipairs(state.board_cards) do
    if card.line == line and card.vstart <= virtual_column and virtual_column <= card.vfinish then
      return card
    end
  end
end

local function gallery_card_under_cursor(state)
  if not state.cards_mode then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local virtual_column = vim.fn.virtcol "."
  for _, card in ipairs(state.gallery_cards) do
    if
      card.start_line <= line
      and line <= card.end_line
      and card.vstart <= virtual_column
      and virtual_column <= card.vfinish
    then
      return card
    end
  end
end

local function active_card_under_cursor(state)
  return board_card_under_cursor(state) or gallery_card_under_cursor(state)
end

local function board_card(state, group_index, card_index)
  for _, card in ipairs(state.board_cards) do
    if card.group_index == group_index and card.card_index == card_index then
      return card
    end
  end
end

local function move_board_card(state, horizontal, vertical)
  if not state.board_mode then
    return nil
  end
  local current = board_card_under_cursor(state)
  if not current then
    local virtual_column = vim.fn.virtcol "."
    local group_index = 1
    for _, column in ipairs(state.board_columns) do
      if column.vstart <= virtual_column and virtual_column <= column.vfinish then
        group_index = column.group_index
        break
      end
    end
    current = board_card(state, group_index, 1)
  end
  if not current then
    return false
  end

  local target
  if horizontal ~= 0 then
    local group_index = current.group_index + horizontal
    while 1 <= group_index and group_index <= #state.board_columns do
      target = board_card(state, group_index, current.card_index) or board_card(state, group_index, 1)
      if target then
        break
      end
      group_index = group_index + horizontal
    end
  elseif vertical ~= 0 then
    target = board_card(state, current.group_index, current.card_index + vertical)
  end
  if not target then
    return false
  end
  vim.api.nvim_win_set_cursor(0, { target.line, target.col })
  return true
end

local function move_gallery_card(state, horizontal, vertical)
  if not state.cards_mode then
    return nil
  end
  local current = gallery_card_under_cursor(state) or state.gallery_cards[1]
  if not current then
    return false
  end
  local offset = horizontal ~= 0 and horizontal or (vertical * state.gallery_columns)
  local target = state.gallery_cards[current.index + offset]
  if not target then
    return false
  end
  vim.api.nvim_win_set_cursor(0, { target.line, target.col })
  return true
end

local function move_active_card(state, horizontal, vertical)
  if state.board_mode then
    return move_board_card(state, horizontal, vertical)
  elseif state.cards_mode then
    return move_gallery_card(state, horizontal, vertical)
  end
end

local function toggle_group(state)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local key = state.line_groups[line]
  if not key or not state.result then
    return false
  end
  state.collapsed[key] = not state.collapsed[key]
  render(state, state.result)
  for rendered_line, rendered_key in pairs(state.line_groups) do
    if rendered_key == key then
      vim.api.nvim_win_set_cursor(0, { rendered_line, 0 })
      break
    end
  end
  return true
end

local function jump_group(state, direction)
  if state.board_mode then
    local virtual_column = vim.fn.virtcol "."
    local current_index = direction > 0 and 0 or (#state.board_columns + 1)
    for index, column in ipairs(state.board_columns) do
      if
        (column.vstart <= virtual_column and virtual_column <= column.vfinish)
        or (direction < 0 and column.vstart > virtual_column)
      then
        current_index = index
        break
      elseif direction > 0 and column.vfinish < virtual_column then
        current_index = index
      end
    end
    local target = state.board_columns[current_index + direction]
    if target then
      vim.api.nvim_win_set_cursor(0, { target.line, target.col })
      return true
    end
    return false
  end

  local current = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if direction > 0 then
    for _, line in ipairs(state.group_lines) do
      if line > current then
        target = line
        break
      end
    end
  else
    for index = #state.group_lines, 1, -1 do
      local line = state.group_lines[index]
      if line < current then
        target = line
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    return true
  end
  return false
end

local function open_row(state)
  local card = active_card_under_cursor(state)
  if card then
    clear_image(state)
    clear_thumbnails(state)
    vim.wo.wrap = state.original_wrap
    vim.cmd.edit(vim.fn.fnameescape(card.row.path))
    return
  end
  if toggle_group(state) then
    return
  end
  local path = state.line_paths[vim.api.nvim_win_get_cursor(0)[1]]
  if path then
    clear_image(state)
    clear_thumbnails(state)
    vim.wo.wrap = state.original_wrap
    vim.cmd.edit(vim.fn.fnameescape(path))
  end
end

local function cell_under_cursor(state)
  local card = active_card_under_cursor(state)
  if card then
    return card.row, nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = state.line_rows[cursor[1]]
  if not row or not state.result then
    return nil, nil
  end
  local virtual_column = vim.fn.virtcol "."
  for index, span in ipairs(state.column_spans or {}) do
    if span.start <= virtual_column and virtual_column <= span.finish then
      return row, state.result.columns[index]
    end
  end
  return row, nil
end

local function edit_cell(state)
  if not state.result or state.result.status ~= "ready" or state.result.freshness ~= "current" then
    vim.notify("Bases edits require a current result", vim.log.levels.WARN)
    return
  end
  local row, column = cell_under_cursor(state)
  if not row or not column then
    vim.notify("Place the cursor on a result cell", vim.log.levels.WARN)
    return
  end
  if not edit.note_identity(row.path, row.cache) then
    vim.notify("Only supported Markdown note rows are editable", vim.log.levels.WARN)
    return
  end
  local property, property_err = edit.property_key(column.property)
  if not property then
    vim.notify(property_err or "The selected property is not editable", vim.log.levels.WARN)
    return
  end
  if not vault_scope.contains(state.scope, row.path, { allow_missing = true }) then
    vim.notify("Bases edit refused: note is outside the originating vault", vim.log.levels.ERROR)
    return
  end
  local property_types_revision = state.query and state.query.context and state.query.context.property_types_revision
    or nil
  if not property_types_revision then
    vim.notify("Property type metadata revision is unavailable", vim.log.levels.WARN)
    return
  end
  local expected = query.value_at(row, column.property)
  local missing = expected == nil
  local kind = edit.value_kind(expected, column.declared_type)
  local show_kind = column.declared_type ~= nil
    or kind == "list"
    or kind == "link"
    or kind == "date"
    or kind == "datetime"
  local kind_label = show_kind and (" (" .. kind .. ")") or ""
  local result_identity = state.result.identity
  local row_path = row.path
  local row_revision = vim.deepcopy(row.revision)
  local column_property = column.property
  local declared_type = column.declared_type
  vim.ui.input({
    prompt = ((missing and "Add" or "Edit") .. " %s%s: "):format(column.label, kind_label),
    default = edit.input_default(expected, declared_type),
  }, function(input)
    if input == nil or states[state.buf] ~= state then
      return
    end
    local current_result = state.result
    if
      not current_result
      or current_result.status ~= "ready"
      or current_result.freshness ~= "current"
      or current_result.identity ~= result_identity
    then
      vim.notify("Bases edit refused: the result changed while the prompt was open", vim.log.levels.ERROR)
      return
    end
    local current_row
    for _, candidate in ipairs(current_result.rows or {}) do
      if candidate.path == row_path then
        current_row = candidate
        break
      end
    end
    local current_column
    for _, candidate in ipairs(current_result.columns or {}) do
      if candidate.property == column_property then
        current_column = candidate
        break
      end
    end
    if
      not current_row
      or not vim.deep_equal(current_row.revision, row_revision)
      or not current_column
      or current_column.declared_type ~= declared_type
    then
      vim.notify("Bases edit refused: the result cell changed while the prompt was open", vim.log.levels.ERROR)
      return
    end
    local latest_types = property_types.get {
      vault = state.scope.vault,
      config_dir = state.scope.config_dir,
    }
    if not vim.deep_equal(latest_types.revision, property_types_revision) then
      vim.notify("Bases edit refused: property type metadata changed while the prompt was open", vim.log.levels.ERROR)
      return
    end
    local result, err = edit.apply {
      path = row_path,
      property = property,
      expected = expected,
      revision = row_revision,
      input = input,
      insert_missing = missing,
      declared_type = declared_type,
      property_types_revision = property_types_revision,
      vault = state.scope.vault,
      config_dir = state.scope.config_dir,
    }
    if not result then
      vim.notify("Bases edit refused: " .. assert(err, "edit failed without an error message"), vim.log.levels.ERROR)
      return
    end
    if result.changed then
      local action = result.inserted and "Added" or "Updated"
      vim.notify(("%s %s in buffer; write the note to save it"):format(action, property), vim.log.levels.INFO)
      refresh(state)
    end
  end)
end

local function edit_property_type(state)
  if not state.result or state.result.status ~= "ready" or state.result.freshness ~= "current" then
    vim.notify("Property type changes require a current result", vim.log.levels.WARN)
    return
  end
  local row, column = cell_under_cursor(state)
  if not row or not column then
    vim.notify("Place the cursor on a result cell", vim.log.levels.WARN)
    return
  end
  local property, property_err = edit.property_key(column.property)
  if not property then
    vim.notify(property_err or "The selected property is not editable", vim.log.levels.WARN)
    return
  end
  local revision = state.query and state.query.context and state.query.context.property_types_revision or nil
  if not revision then
    vim.notify("Property type metadata revision is unavailable", vim.log.levels.WARN)
    return
  end
  vim.ui.select(property_types.supported_types, {
    prompt = ("Set declared type for %s%s: "):format(
      column.label,
      column.declared_type and (" (current: " .. column.declared_type .. ")") or ""
    ),
  }, function(type_name)
    if not type_name or states[state.buf] ~= state then
      return
    end
    local result, err = property_types_edit.apply {
      property = property,
      type_name = type_name,
      expected = column.declared_type,
      revision = revision,
      vault = state.scope.vault,
      config_dir = state.scope.config_dir,
    }
    if not result then
      vim.notify(
        "Property type change refused: " .. assert(err, "type change failed without an error message"),
        vim.log.levels.ERROR
      )
      return
    end
    if not result.changed then
      vim.notify(("Property %s is already declared as %s"):format(property, type_name), vim.log.levels.INFO)
      return
    end
    vim.notify(
      ("Declared %s as %s in buffer %d; write %s to save it"):format(property, type_name, result.buf, result.path),
      vim.log.levels.INFO
    )
    refresh(state)
  end)
end

local function toggle_thumbnails(state)
  if not state.cards_mode or not state.result or not state.result.view or type(state.result.view.image) ~= "string" then
    vim.notify("Viewport thumbnails require a cards view with an image property", vim.log.levels.WARN)
    return
  end
  if state.thumbnails_enabled then
    state.thumbnails_enabled = false
    state.thumbnails_supported = false
    clear_thumbnails(state)
    render(state, state.result)
    vim.notify("Viewport card thumbnails disabled", vim.log.levels.INFO)
    return
  end
  local status = compat.image_status { probe = true, timeout = 250 }
  if not status.supported then
    vim.notify(
      "Viewport thumbnails unavailable: " .. (status.message or "terminal support was not detected"),
      vim.log.levels.WARN
    )
    return
  end
  state.thumbnails_enabled = true
  state.thumbnails_supported = true
  render(state, state.result)
  vim.notify("Viewport card thumbnails enabled", vim.log.levels.INFO)
end

local function preview_image(state)
  if state.image_id then
    clear_image(state)
    vim.notify("Card image preview hidden", vim.log.levels.INFO)
    return
  end
  if not state.cards_mode or not state.result then
    vim.notify("Image previews are available only in cards views", vim.log.levels.WARN)
    return
  end
  local card = gallery_card_under_cursor(state)
  if not card then
    vim.notify("Place the cursor on a card", vim.log.levels.WARN)
    return
  end
  local status = compat.image_status { probe = true, timeout = 250 }
  if not status.supported then
    vim.notify(
      "Card image preview unavailable: " .. (status.message or "terminal support was not detected"),
      vim.log.levels.WARN
    )
    return
  end
  local resolved, resolve_err = images.resolve(card.row, state.result.view, state.scope)
  if not resolved then
    vim.notify(
      "Card image preview unavailable: " .. assert(resolve_err, "image resolution failed without an error message"),
      vim.log.levels.WARN
    )
    return
  end
  local data, read_err = images.read(resolved.path, state.scope)
  if not data then
    vim.notify(
      "Card image preview unavailable: " .. assert(read_err, "image read failed without an error message"),
      vim.log.levels.WARN
    )
    return
  end
  local position = vim.fn.screenpos(0, card.start_line, card.col + 4)
  if not position or position.row == 0 or position.col == 0 then
    vim.notify("Card image preview unavailable outside the visible viewport", vim.log.levels.WARN)
    return
  end
  local id, show_err = compat.show_image(data, {
    row = position.row,
    col = position.col,
    width = 22,
    height = 8,
    zindex = 50,
  })
  if not id then
    vim.notify(
      "Card image preview failed: " .. assert(show_err, "image display failed without an error message"),
      vim.log.levels.ERROR
    )
    return
  end
  state.image_id = id
  vim.notify("Card image preview shown; press i again to hide it", vim.log.levels.INFO)
end

local function compare_with_cli(state)
  if
    not state.definition
    or not state.result
    or state.result.status ~= "ready"
    or state.result.freshness ~= "current"
  then
    vim.notify("CLI comparison requires a current result from a saved .base file", vim.log.levels.WARN)
    return
  end
  local compare_opts = {
    vault = state.scope.vault,
    config_dir = state.scope.config_dir,
    ignore_filters = state.scope.ignore_filters,
    strict_vault = true,
  }
  local comparable, reason = compare.comparability(state.definition, state.result, compare_opts)
  if not comparable then
    state.comparison = {
      status = "non_comparable",
      summary = "not comparable with Obsidian CLI: " .. (reason or "unknown comparison snapshot mismatch"),
      diagnostics = {},
    }
    render(state, state.result)
    vim.notify("Bases CLI comparison " .. state.comparison.summary, vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "Run comparison", "Cancel" }, {
    prompt = "Obsidian CLI may start the desktop app. Compare this view?",
  }, function(choice)
    if choice ~= "Run comparison" or states[state.buf] ~= state then
      return
    end
    cancel_comparison(state, false)
    local generation = state.comparison_generation
    local identity = state.result.identity
    state.comparison = { status = "running", summary = "running…", diagnostics = {} }
    render(state, state.result)
    local completed = false
    local job = compare.run(state.definition, state.result, function(comparison)
      completed = true
      if
        states[state.buf] ~= state
        or state.comparison_generation ~= generation
        or not state.result
        or state.result.identity ~= identity
      then
        return
      end
      state.comparison_job = nil
      state.comparison = comparison
      render(state, state.result)
      local level = comparison.status == "match" and vim.log.levels.INFO or vim.log.levels.WARN
      vim.notify("Bases CLI comparison " .. comparison.summary, level)
    end, compare_opts)
    if not completed then
      state.comparison_job = job
    end
  end)
end

local function install_actions(state)
  local opts = { buffer = state.buf, silent = true }
  local function board_motion(horizontal, vertical, fallback)
    return function()
      if state.board_mode or state.cards_mode then
        move_active_card(state, horizontal, vertical)
      else
        vim.cmd.normal { args = { fallback }, bang = true }
      end
    end
  end
  vim.keymap.set("n", "<CR>", function()
    open_row(state)
  end, vim.tbl_extend("force", opts, { desc = "Bases: open note" }))
  vim.keymap.set("n", "e", function()
    edit_cell(state)
  end, vim.tbl_extend("force", opts, { desc = "Bases: edit property" }))
  vim.keymap.set("n", "t", function()
    edit_property_type(state)
  end, vim.tbl_extend("force", opts, { desc = "Bases: change declared property type" }))
  vim.keymap.set("n", "C", function()
    compare_with_cli(state)
  end, vim.tbl_extend("force", opts, { desc = "Bases: compare with Obsidian CLI" }))
  vim.keymap.set("n", "i", function()
    preview_image(state)
  end, vim.tbl_extend("force", opts, { desc = "Bases: toggle card image preview" }))
  vim.keymap.set("n", "I", function()
    toggle_thumbnails(state)
  end, vim.tbl_extend("force", opts, { desc = "Bases: toggle viewport card thumbnails" }))
  vim.keymap.set("n", "h", board_motion(-1, 0, "h"), vim.tbl_extend("force", opts, { desc = "Bases: left card" }))
  vim.keymap.set("n", "j", board_motion(0, 1, "j"), vim.tbl_extend("force", opts, { desc = "Bases: next card" }))
  vim.keymap.set("n", "k", board_motion(0, -1, "k"), vim.tbl_extend("force", opts, { desc = "Bases: previous card" }))
  vim.keymap.set("n", "l", board_motion(1, 0, "l"), vim.tbl_extend("force", opts, { desc = "Bases: right card" }))
  vim.keymap.set("n", "]g", function()
    jump_group(state, 1)
  end, vim.tbl_extend("force", opts, { desc = "Bases: next group" }))
  vim.keymap.set("n", "[g", function()
    jump_group(state, -1)
  end, vim.tbl_extend("force", opts, { desc = "Bases: previous group" }))
  vim.keymap.set("n", "za", function()
    if not toggle_group(state) then
      vim.notify("Place the cursor on a group heading", vim.log.levels.WARN)
    end
  end, vim.tbl_extend("force", opts, { desc = "Bases: toggle group" }))
  vim.keymap.set("n", "r", function()
    refresh(state, true)
  end, vim.tbl_extend("force", opts, { desc = "Bases: refresh" }))
  vim.keymap.set("n", "q", function()
    clear_image(state)
    vim.wo.wrap = state.original_wrap
    vim.api.nvim_buf_delete(state.buf, {})
  end, vim.tbl_extend("force", opts, { desc = "Bases: close workspace" }))
  vim.keymap.set("n", "?", function()
    vim.notify(
      "Bases actions: <CR> open/toggle, e edit, t property type, C CLI compare, hjkl cards, i image, I thumbnails, [g/]g groups, r refresh, q close",
      vim.log.levels.INFO
    )
  end, vim.tbl_extend("force", opts, { desc = "Bases: show actions" }))
end

---@param spec table
---@param open_opts { current: boolean?, raw_buf: integer? }|nil
---@return integer buf
function M.open(spec, open_opts)
  open_opts = open_opts or {}
  local scope = spec.scope and vault_scope.copy(spec.scope)
    or assert(vault_scope.capture(spec.context_path or spec.path))
  spec = vim.tbl_extend("force", {}, spec, { scope = scope })
  local original_wrap = vim.wo.wrap
  local buf
  if open_opts.current then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.cmd "botright new"
    buf = vim.api.nvim_get_current_buf()
  end
  local name = ("obsidian-bases://%s#%s"):format(spec.path or "inline", spec.view or "")
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "obsidian-bases"
  vim.bo[buf].modifiable = false

  local state = {
    buf = buf,
    spec = spec,
    scope = scope,
    group = vim.api.nvim_create_augroup("obsidian.bases.workspace." .. buf, { clear = true }),
    query = nil,
    query_key = nil,
    result = nil,
    line_paths = {},
    line_rows = {},
    column_spans = {},
    line_groups = {},
    group_lines = {},
    collapsed = {},
    board_mode = false,
    board_cards = {},
    board_columns = {},
    cards_mode = false,
    gallery_cards = {},
    gallery_columns = 3,
    original_wrap = original_wrap,
    image_id = nil,
    thumbnails_enabled = false,
    thumbnails_supported = false,
    thumbnail_ids = {},
    thumbnail_data = {},
    thumbnail_generation = 0,
    thumbnail_pending = false,
    unregister = nil,
    refresh_timer = nil,
    definition = nil,
    comparison = nil,
    comparison_generation = 0,
    comparison_job = nil,
    reflow_pending = false,
    raw_buf = open_opts.raw_buf,
  }
  states[buf] = state
  install_actions(state)

  -- Unload/delete events run before the source overlay disappears. Debounce
  -- their refresh just like text changes so collection observes the final state.
  -- BufReadPost also covers discarding edits with :edit! without unloading.
  local source_events = {
    "BufWritePost",
    "TextChanged",
    "TextChangedI",
    "BufUnload",
    "BufDelete",
    "BufWipeout",
    "BufReadPost",
  }
  vim.api.nvim_create_autocmd(source_events, {
    group = state.group,
    pattern = { "*.md", "*.markdown", "*.qmd", "*.base" },
    callback = function(args)
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path ~= "" and vault_scope.contains_lexically(state.scope, path) then
        schedule_refresh(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd(source_events, {
    group = state.group,
    pattern = "types.json",
    callback = function(args)
      local path = vim.api.nvim_buf_get_name(args.buf)
      local types = property_types.get { vault = state.scope.vault, config_dir = state.scope.config_dir }
      if path ~= "" and vim.fs.normalize(path) == types.path then
        schedule_refresh(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = state.group,
    buffer = buf,
    callback = function()
      schedule_card_reflow(state)
      schedule_thumbnail_update(state)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = state.group,
    buffer = buf,
    callback = function()
      clear_image(state)
      clear_thumbnails(state)
      -- If another window still shows this buffer, recreate its placements.
      schedule_thumbnail_update(state)
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = state.group,
    callback = function()
      schedule_thumbnail_update(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = state.group,
    callback = function()
      schedule_card_reflow(state)
      schedule_thumbnail_update(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = state.group,
    buffer = buf,
    once = true,
    callback = function()
      M.close(buf)
    end,
  })
  state.unregister = watchfiles.register_handler(function(events)
    if vault_scope.events_affect(state.scope, events) then
      schedule_refresh(state)
    end
  end)

  refresh(state)
  return buf
end

---@param buf integer
function M.close(buf)
  local state = states[buf]
  if not state then
    return
  end
  states[buf] = nil
  cancel_comparison(state, true)
  clear_image(state)
  clear_thumbnails(state)
  if state.refresh_timer then
    state.refresh_timer:stop()
    state.refresh_timer:close()
    state.refresh_timer = nil
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win].wrap = state.original_wrap
  end
  if state.query then
    state.query:dispose()
  end
  if state.unregister then
    state.unregister()
  end
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
end

function M.close_all()
  for _, buf in ipairs(vim.tbl_keys(states)) do
    M.close(buf)
  end
end

---@param buf integer
---@return obsidian.bases.WorkspaceState|nil
function M.get(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  return states[buf]
end

M._cards_column_count = layout.cards_column_count
M._schedule_refresh = schedule_refresh
M._truncate = layout.truncate

M.refresh = function(buf)
  if not buf or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local state = states[buf]
  if state then
    refresh(state, true)
  end
end

return M
