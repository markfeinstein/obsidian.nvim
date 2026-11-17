-- Text and geometry only: no buffers, windows, queries, or image lifecycles.
local M = {}

-- Keep rendering single-line without changing the typed values used for edits.
local function single_line(value)
  return (tostring(value):gsub("[%c]", " "))
end

local function truncate(value, width)
  value = single_line(value)
  if width <= 0 then
    return ""
  elseif vim.fn.strdisplaywidth(value) <= width then
    return value
  end

  local ellipsis = "…"
  local budget = math.max(0, width - vim.fn.strdisplaywidth(ellipsis))
  local prefix = ""
  for index = 0, vim.fn.strchars(value) - 1 do
    local candidate = prefix .. vim.fn.strcharpart(value, index, 1)
    if vim.fn.strdisplaywidth(candidate) > budget then
      break
    end
    prefix = candidate
  end
  return prefix .. ellipsis
end

local function table_widths(rows, columns)
  local widths = {}
  for index, column in ipairs(columns) do
    widths[index] = math.min(40, math.max(3, vim.fn.strdisplaywidth(single_line(column.label))))
  end
  for _, row in ipairs(rows) do
    for index, cell in ipairs(row.cells or {}) do
      widths[index] = math.min(40, math.max(widths[index] or 3, vim.fn.strdisplaywidth(single_line(cell))))
    end
  end

  return widths
end

local function fit_table_widths(widths, available_width)
  local fitted = vim.deepcopy(widths)
  local separators = math.max(0, (#fitted - 1) * 3)
  local target = math.max(#fitted * 3, math.floor(available_width) - separators)
  local total = 0
  for _, width in ipairs(fitted) do
    total = total + width
  end
  while total > target do
    local widest_index, widest_width
    for index, width in ipairs(fitted) do
      if width > 3 and (not widest_width or width > widest_width) then
        widest_index, widest_width = index, width
      end
    end
    if not widest_index then
      break
    end
    fitted[widest_index] = fitted[widest_index] - 1
    total = total - 1
  end
  return fitted
end

local function table_lines(rows, columns, widths)
  local function line(values)
    local cells = {}
    for index, value in ipairs(values) do
      local width = widths[index] or 3
      value = truncate(value, width)
      cells[index] = value .. string.rep(" ", math.floor(width - vim.fn.strdisplaywidth(value)))
    end
    return table.concat(cells, " │ ")
  end

  local lines = {}
  local labels = vim.tbl_map(function(column)
    return column.label
  end, columns)
  lines[#lines + 1] = line(labels)
  local separators = {}
  for index, width in ipairs(widths) do
    separators[index] = string.rep("─", width)
  end
  lines[#lines + 1] = table.concat(separators, "─┼─")
  for _, row in ipairs(rows) do
    lines[#lines + 1] = line(row.cells or {})
  end
  local spans = {}
  local start = 1
  for index, width in ipairs(widths) do
    spans[index] = { start = start, finish = start + width - 1 }
    start = start + width + 3
  end
  return lines, spans
end

local function list_lines(rows)
  local lines = {}
  for _, row in ipairs(rows) do
    local values = {}
    for _, cell in ipairs(row.cells or {}) do
      if cell ~= "" then
        values[#values + 1] = cell
      end
    end
    lines[#lines + 1] = "• " .. (#values > 0 and table.concat(values, " · ") or row.file.path)
  end
  return lines
end

local function board_lines(groups)
  local widths = {}
  local card_text = {}
  local maximum_cards = 0
  for group_index, group in ipairs(groups) do
    local header = ("%s (%d)"):format(group.label, #group.rows)
    widths[group_index] = math.min(30, math.max(12, vim.fn.strdisplaywidth(single_line(header))))
    card_text[group_index] = {}
    maximum_cards = math.max(maximum_cards, #group.rows)
    for card_index, row in ipairs(group.rows) do
      local values = {}
      for _, cell in ipairs(row.cells or {}) do
        if cell ~= "" then
          values[#values + 1] = cell
        end
      end
      local text = #values > 0 and table.concat(values, " · ") or row.file.path
      card_text[group_index][card_index] = text
      widths[group_index] = math.min(30, math.max(widths[group_index], vim.fn.strdisplaywidth(single_line(text))))
    end
  end

  local function padded(value, width)
    value = truncate(value, width)
    return value .. string.rep(" ", width - vim.fn.strdisplaywidth(value))
  end

  local lines = {}
  local columns = {}
  local header_parts = {}
  local separator_parts = {}
  local byte_col, virtual_col = 0, 1
  for index, group in ipairs(groups) do
    local header = padded(("%s (%d)"):format(group.label, #group.rows), widths[index])
    header_parts[index] = header
    separator_parts[index] = string.rep("─", widths[index])
    columns[index] = {
      key = group.key,
      group_index = index,
      line = 1,
      col = byte_col,
      end_col = byte_col + #header,
      vstart = virtual_col,
      vfinish = virtual_col + widths[index] - 1,
    }
    byte_col = byte_col + #header + 2
    virtual_col = virtual_col + widths[index] + 2
  end
  lines[1] = table.concat(header_parts, "  ")
  lines[2] = table.concat(separator_parts, "  ")

  local cards = {}
  for card_index = 1, maximum_cards do
    local parts = {}
    byte_col, virtual_col = 0, 1
    for group_index, group in ipairs(groups) do
      local text = card_text[group_index][card_index] or ""
      local rendered = padded(text, widths[group_index])
      parts[group_index] = rendered
      local row = group.rows[card_index]
      if row then
        cards[#cards + 1] = {
          row = row,
          group_index = group_index,
          card_index = card_index,
          line = card_index + 2,
          col = byte_col,
          vstart = virtual_col,
          vfinish = virtual_col + widths[group_index] - 1,
        }
      end
      byte_col = byte_col + #rendered + 2
      virtual_col = virtual_col + widths[group_index] + 2
    end
    lines[card_index + 2] = table.concat(parts, "  ")
  end
  return lines, cards, columns
end

local CARD_WIDTH = 24
local CARD_GAP = 2

local function cards_column_count(available_width)
  return math.max(1, math.floor((math.max(1, available_width) + CARD_GAP) / (CARD_WIDTH + CARD_GAP)))
end

local function cards_lines(rows, thumbnails, column_count)
  local width = CARD_WIDTH
  column_count = math.max(1, column_count or 1)
  local image_height = thumbnails and 4 or 0
  local lines = {}
  local cards = {}
  for start_index = 1, #rows, column_count do
    local batch = {}
    for offset = 0, column_count - 1 do
      local row = rows[start_index + offset]
      if row then
        local title = row.cells and row.cells[1] ~= "" and row.cells[1] or row.file.name
        local details = {}
        for index = 2, #(row.cells or {}) do
          if row.cells[index] ~= "" then
            details[#details + 1] = row.cells[index]
          end
        end
        batch[#batch + 1] = {
          row = row,
          title = title,
          details = table.concat(details, " · "),
          grid_col = offset + 1,
        }
      end
    end

    local rendered = {}
    local byte_col, virtual_col = 0, 1
    local local_start_line = #lines + 1
    for line_index = 1, image_height + 3 do
      rendered[line_index] = {}
    end
    for index = 1, column_count do
      local card = batch[index]
      if card then
        local title = truncate(card.title, width - 2)
        local details = truncate(card.details, width - 2)
        rendered[1][index] = "┌" .. title .. string.rep("─", width - 2 - vim.fn.strdisplaywidth(title)) .. "┐"
        for image_row = 1, image_height do
          local fallback = image_row == 1 and "[text image fallback]" or ""
          rendered[image_row + 1][index] = "│"
            .. fallback
            .. string.rep(" ", width - 2 - vim.fn.strdisplaywidth(fallback))
            .. "│"
        end
        rendered[image_height + 2][index] = "│"
          .. details
          .. string.rep(" ", width - 2 - vim.fn.strdisplaywidth(details))
          .. "│"
        rendered[image_height + 3][index] = "└" .. string.rep("─", width - 2) .. "┘"
        cards[#cards + 1] = {
          row = card.row,
          grid_col = card.grid_col,
          start_line = local_start_line,
          end_line = local_start_line + image_height + 2,
          image_line = image_height > 0 and local_start_line + 1 or nil,
          image_height = image_height,
          line = local_start_line,
          col = byte_col,
          end_col = byte_col + #rendered[1][index],
          vstart = virtual_col,
          vfinish = virtual_col + width - 1,
        }
      else
        for line_index = 1, image_height + 3 do
          rendered[line_index][index] = string.rep(" ", width)
        end
      end
      byte_col = byte_col + #rendered[1][index] + 2
      virtual_col = virtual_col + width + 2
    end
    for line_index = 1, image_height + 3 do
      lines[#lines + 1] = table.concat(rendered[line_index], "  ")
    end
  end
  return lines, cards, column_count
end

M.single_line = single_line
M.truncate = truncate
M.table_widths = table_widths
M.fit_table_widths = fit_table_widths
M.table_lines = table_lines
M.list_lines = list_lines
M.board_lines = board_lines
M.cards_column_count = cards_column_count
M.cards_lines = cards_lines

return M
