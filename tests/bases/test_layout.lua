local layout = require "obsidian.bases.layout"

local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["table geometry uses display cells without changing source values"] = function()
  local rows = { { cells = { "界界", "two\nlines" }, file = { path = "Note.md" } } }
  local columns = { { label = "Name" }, { label = "Value" } }
  local original = vim.deepcopy(rows)
  local widths = layout.table_widths(rows, columns)
  local lines, spans = layout.table_lines(rows, columns, widths)
  eq({ 4, 9 }, widths)
  eq({ { start = 1, finish = 4 }, { start = 8, finish = 16 } }, spans)
  eq("界界 │ two lines", lines[3])
  eq(original, rows)
end

T["board and gallery geometry retain row identity without mutating results"] = function()
  local rows = {
    { path = "/vault/A.md", cells = { "界", "first" }, file = { path = "A.md" } },
    { path = "/vault/B.md", cells = { "B", "second" }, file = { path = "B.md" } },
  }
  local original = vim.deepcopy(rows)
  local groups = { { key = "one", label = "One", rows = rows } }
  local board, board_cards, columns = layout.board_lines(groups)
  eq(4, #board)
  eq(2, #board_cards)
  eq(true, board_cards[1].row == rows[1])
  eq(3, board_cards[1].line)
  eq("one", columns[1].key)
  for _, thumbnails in ipairs { false, true } do
    local gallery, cards, count = layout.cards_lines(rows, thumbnails, 2)
    eq(thumbnails and 7 or 3, #gallery)
    eq(2, count)
    eq(true, cards[2].row == rows[2])
    eq(27, cards[2].vstart)
    eq(thumbnails and 2 or nil, cards[2].image_line)
    eq(50, vim.fn.strdisplaywidth(gallery[1]))
  end
  eq(original, rows)
end

return T
