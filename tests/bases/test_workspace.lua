local h = require "tests.helpers"

local eq = MiniTest.expect.equality
local T, child = h.child_vault {
  post_case = [[
require("obsidian.bases.workspace").close_all()
if _G.bases_original_compare_run then
  require("obsidian.bases.compare").run = _G.bases_original_compare_run
  _G.bases_original_compare_run = nil
end
if _G.bases_primary_workspace then
  pcall(require("obsidian.workspace").set, _G.bases_primary_workspace)
  _G.bases_primary_workspace = nil
end
if _G.bases_extra_vault then
  vim.fn.delete(_G.bases_extra_vault, "rf")
  _G.bases_extra_vault = nil
end
]],
}

T["truncates cells by display width"] = function()
  local truncate = require("obsidian.bases.workspace")._truncate
  eq("plain", truncate("plain", 5))
  eq("你…", truncate("你好", 3))
  eq("…", truncate("你", 1))
  eq(3, vim.fn.strdisplaywidth(truncate("你好世界", 3)))
end

T["coalesces rapid refresh requests"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name]
]],
    ["One.md"] = "body",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "refresh debounce workspace" }
  )

  child.lua [[
local workspace = require "obsidian.bases.workspace"
local state = workspace.get(0)
_G.bases_refresh_calls = 0
local original = state.query.refresh
state.query.refresh = function(self, ...)
  _G.bases_refresh_calls = _G.bases_refresh_calls + 1
  return original(self, ...)
end
workspace._schedule_refresh(state)
workspace._schedule_refresh(state)
workspace._schedule_refresh(state)
]]
  h.child_wait(child, [[return _G.bases_refresh_calls == 1]], { desc = "coalesced Bases refresh" })
  child.lua [[vim.wait(150)]]
  eq(1, child.lua_get "bases_refresh_calls")
end

for _, source in ipairs { "Note.md", "Projects.base", ".obsidian/types.json" } do
  for _, command in ipairs { "bdelete!", "bwipeout!", "bunload!", "edit!" } do
    T["refreshes discarded " .. source .. " overlays after " .. command] = function()
      local files = h.child_mock_vault_contents(child, {
        ["Projects.base"] = [[filters: 'file.path == "Note.md"'
views:
  - type: table
    name: Saved
    order: [file.name, status]
]],
        ["Note.md"] = "---\nstatus: saved\n---",
        [".obsidian/types.json"] = [[{"types":{"status":"text"}}]],
      })
      child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
      child.cmd("edit " .. vim.fn.fnameescape(files[source]))
      local source_buf = child.api.nvim_get_current_buf()
      if source == "Note.md" then
        child.api.nvim_buf_set_lines(source_buf, 1, 2, false, { "status: unsaved" })
      elseif source == "Projects.base" then
        child.api.nvim_buf_set_lines(source_buf, 3, 4, false, { "    name: Unsaved" })
      else
        child.api.nvim_buf_set_lines(source_buf, 0, -1, false, { [[{"types":{"status":"number"}}]] })
      end
      child.cmd("Obsidian bases " .. vim.fn.fnameescape(files["Projects.base"]))
      local workspace_buf = child.api.nvim_get_current_buf()
      local function wait_for(value)
        local predicate = source == "Note.md" and ("result.rows[1].note.status == %q"):format(value)
          or source == "Projects.base" and ("result.view_name == %q"):format(value)
          or ("result.columns[2].declared_type == %q"):format(value)
        h.child_wait(
          child,
          ([[
local state = require("obsidian.bases.workspace").get(%d)
local result = state and state.result
return result and result.status == "ready" and result.freshness == "current"
  and #result.rows == 1 and %s
]]):format(workspace_buf, predicate),
          { timeout = 5000, desc = source .. " overlay value " .. value }
        )
      end
      wait_for(source == "Note.md" and "unsaved" or source == "Projects.base" and "Unsaved" or "number")
      if command == "edit!" then
        child.lua(([[vim.api.nvim_buf_call(%d, function() vim.cmd "edit!" end)]]):format(source_buf))
      else
        child.cmd(command .. " " .. source_buf)
      end
      wait_for(source == "Note.md" and "saved" or source == "Projects.base" and "Saved" or "text")
      eq({ "---", "status: saved", "---" }, vim.fn.readfile(files["Note.md"]))
    end
  end
end

T["keeps an open Bases workspace pinned across vault switches and filters watch events"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[filters: 'file.ext == "md"'
views:
  - type: table
    name: Projects
    order: [file.name, status]
]],
    ["A.md"] = "---\nstatus: 7\ncover: cover.png\n---",
    ["cover.png"] = "primary-image",
    ["ignored/Hidden.md"] = "---\nstatus: 99\n---",
    [".meta-a/types.json"] = [[{"types":{"status":"number"}}]],
  })

  child.lua [[
vim.cmd.runtime "plugin/obsidian.lua"
Obsidian.opts.sync.config_dir = ".meta-a"
Obsidian.opts.file.ignore_filters = { "ignored/**" }
_G.bases_primary_workspace = Obsidian.workspace
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready" and #state.result.rows == 1
]],
    { timeout = 5000, desc = "primary-vault Bases result" }
  )

  child.lua [[
local root = vim.fn.tempname()
vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
root = assert(vim.uv.fs_realpath(root))
_G.bases_extra_vault = root
vim.fn.writefile({ "---", "status: secondary", "---" }, vim.fs.joinpath(root, "B.md"))
vim.fn.writefile({ "secondary-image" }, vim.fs.joinpath(root, "cover.png"))
vim.fn.mkdir(vim.fs.joinpath(root, ".meta-b"), "p")
vim.fn.writefile({ '{"types":{"status":"text"}}' }, vim.fs.joinpath(root, ".meta-b", "types.json"))
local Workspace = require "obsidian.workspace"
local secondary = assert(Workspace.new {
  path = root,
  name = "secondary",
  strict = true,
  overrides = {
    sync = { config_dir = ".meta-b" },
    file = { ignore_filters = {} },
  },
})
table.insert(Obsidian.workspaces, secondary)
_G.bases_workspace_buf = require("obsidian.bases.workspace").get(0).buf
Workspace.set(secondary)
require("obsidian.bases.workspace").refresh(_G.bases_workspace_buf)
]]
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(_G.bases_workspace_buf)
return state and state.result and state.result.status == "ready" and state.refresh_timer == nil
]],
    { timeout = 5000, desc = "pinned refresh after workspace switch" }
  )

  local pinned = child.lua [[
local state = require("obsidian.bases.workspace").get(_G.bases_workspace_buf)
local identity = vim.json.decode(state.result.identity)
local images = require "obsidian.bases.images"
local resolved = assert(images.resolve(state.result.rows[1], { image = "cover" }, state.scope))
local image_data = assert(images.read(resolved.path, state.scope))
return {
  scope = state.scope,
  rows = vim.tbl_map(function(row) return row.file.path end, state.result.rows),
  declared_type = state.result.columns[2].declared_type,
  identity = identity,
  image_path = resolved.path,
  image_data = image_data,
}
]]
  eq(tostring(child.Obsidian.dir), pinned.scope.vault)
  eq(".meta-a", pinned.scope.config_dir)
  eq({ "ignored/**" }, pinned.scope.ignore_filters)
  eq({ "A.md" }, pinned.rows)
  eq("number", pinned.declared_type)
  eq(pinned.scope.vault, pinned.identity.vault)
  eq(".meta-a", pinned.identity.config_dir)
  eq(vim.fs.joinpath(tostring(child.Obsidian.dir), "cover.png"), pinned.image_path)
  eq("primary-image\n", pinned.image_data)

  child.lua [[
local comparison = require "obsidian.bases.compare"
_G.bases_original_compare_run = comparison.run
vim.ui.select = function(_, _, callback) callback "Run comparison" end
comparison.run = function(_, _, callback, opts)
  _G.bases_pinned_cli_vault = opts and opts.vault
  callback { status = "match", summary = "matches", diagnostics = {} }
end
vim.api.nvim_set_current_buf(_G.bases_workspace_buf)
]]
  child.type_keys "C"
  eq(tostring(child.Obsidian.dir), child.lua_get "bases_pinned_cli_vault")

  local watch_state = child.lua [[
local workspace = require "obsidian.bases.workspace"
local watchfiles = require "obsidian.lsp.watchfiles"
local state = assert(workspace.get(_G.bases_workspace_buf))
assert(state.refresh_timer == nil)
watchfiles.handle { {
  path = vim.fs.joinpath(_G.bases_extra_vault, "B.md"),
  type = vim.lsp.protocol.FileChangeType.Changed,
} }
local outside_timer = state.refresh_timer ~= nil
watchfiles.handle { {
  path = vim.fs.joinpath(state.scope.vault, "A.md"),
  type = vim.lsp.protocol.FileChangeType.Changed,
} }
return { outside_timer = outside_timer, inside_timer = state.refresh_timer ~= nil }
]]
  eq(false, watch_state.outside_timer)
  eq(true, watch_state.inside_timer)

  child.lua [[require("obsidian.workspace").set(_G.bases_primary_workspace)]]
end

T["closing a workspace cancels its pending evaluator request"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Pending.base"] = [[views:
  - type: table
    name: Pending
]],
  })
  child.lua [[
vim.cmd.runtime "plugin/obsidian.lua"
local source = require "obsidian.bases.source"
local worker = require "obsidian.bases.worker"
source.collect = function(callback) callback({}, {}) end
worker.status = function() return { available = true, name = "test", version = "1" } end
_G.bases_cancel_calls = 0
worker.evaluate = function(_, callback)
  _G.bases_pending_callback = callback
  return function() _G.bases_cancel_calls = _G.bases_cancel_calls + 1 end
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Pending.base"]))
  h.child_wait(child, [[return _G.bases_pending_callback ~= nil]], { desc = "pending Bases evaluator request" })

  local closed = child.lua [[
local workspace = require "obsidian.bases.workspace"
local buf = vim.api.nvim_get_current_buf()
workspace.close(buf)
_G.bases_pending_callback({ state = "current", matches = {}, diagnostics = {} }, nil)
return workspace.get(buf) == nil
]]
  eq(true, closed)
  eq(1, child.lua_get "bases_cancel_calls")
end

T["renders cards grids with native card navigation"] = function()
  eq(1, require("obsidian.bases.workspace")._cards_column_count(24))
  eq(2, require("obsidian.bases.workspace")._cards_column_count(50))
  eq(3, require("obsidian.bases.workspace")._cards_column_count(76))
  eq(4, require("obsidian.bases.workspace")._cards_column_count(102))
  local files = h.child_mock_vault_contents(child, {
    ["Cards.base"] = [[filters: 'file.ext == "md"'
views:
  - type: cards
    name: Gallery
    order: [file.name, status]
    image: cover
]],
    ["A.md"] = "---\nstatus: one\ncover: '[[cover.png]]'\n---",
    ["B.md"] = "---\nstatus: two\n---",
    ["C.md"] = "---\nstatus: three\n---",
    ["D.md"] = "---\nstatus: four\n---",
    ["E.md"] = "---\nstatus: five\n---",
    ["cover.png"] = "png-data",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
_G.bases_next_image = 41
_G.bases_image_updates = 0
vim.ui.img = {
  _supported = function() return true end,
  set = function(data, opts)
    if type(data) == "number" then
      _G.bases_image_updates = _G.bases_image_updates + 1
      return data
    end
    _G.bases_image_data = data
    _G.bases_image_opts = opts
    _G.bases_next_image = _G.bases_next_image + 1
    return _G.bases_next_image
  end,
  get = function() end,
  del = function(id) _G.bases_deleted_image = id end,
}
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Cards.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.cards_mode and #state.gallery_cards == 5
]],
    { timeout = 5000, desc = "cards gallery" }
  )
  eq(false, child.lua_get "vim.wo.wrap")

  local first = child.lua [[
local card = require("obsidian.bases.workspace").get(0).gallery_cards[1]
return { card.line, card.col }
]]
  child.api.nvim_win_set_cursor(0, first)
  child.type_keys "i"
  h.child_wait(child, [[return require("obsidian.bases.workspace").get(0).image_id == 42]], {
    desc = "card image preview",
  })
  eq(22, child.lua_get "bases_image_opts.width")
  eq("png-data\n", child.lua_get "bases_image_data")
  child.type_keys "i"
  eq(42, child.lua_get "bases_deleted_image")

  child.type_keys "I"
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state.thumbnails_enabled and state.gallery_cards[1].image_height == 4
]],
    { timeout = 5000, desc = "enabled card thumbnails" }
  )
  eq(true, child.lua_get [[require("obsidian.bases.workspace").get(0).gallery_cards[1].image_line > 10]])
  child.lua [[
local card = require("obsidian.bases.workspace").get(0).gallery_cards[1]
vim.api.nvim_win_set_cursor(0, { card.image_line, card.col })
vim.api.nvim_exec_autocmds("WinScrolled", {})
]]
  h.child_wait(
    child,
    [[
return vim.tbl_count(require("obsidian.bases.workspace").get(0).thumbnail_ids) == 1
]],
    { timeout = 5000, desc = "visible card thumbnails" }
  )
  eq(
    child.lua [[
local card = require("obsidian.bases.workspace").get(0).gallery_cards[1]
return vim.fn.screenpos(0, card.image_line, card.col + 4).row
]],
    child.lua_get "bases_image_opts.row"
  )
  child.lua [[vim.api.nvim_exec_autocmds("WinScrolled", {})]]
  h.child_wait(child, [[return _G.bases_image_updates > 0]], { desc = "thumbnail reposition" })
  child.type_keys "I"
  eq(false, child.lua_get [[require("obsidian.bases.workspace").get(0).thumbnails_enabled]])

  child.type_keys "l"
  eq(
    "B",
    child.lua [[
local state = require("obsidian.bases.workspace").get(0)
local line, vcol = vim.api.nvim_win_get_cursor(0)[1], vim.fn.virtcol(".")
for _, card in ipairs(state.gallery_cards) do
  if card.start_line <= line and line <= card.end_line and card.vstart <= vcol and vcol <= card.vfinish then return card.row.file.name end
end
]]
  )
  child.type_keys "j"
  eq(
    "E",
    child.lua [[
local state = require("obsidian.bases.workspace").get(0)
local line, vcol = vim.api.nvim_win_get_cursor(0)[1], vim.fn.virtcol(".")
for _, card in ipairs(state.gallery_cards) do
  if card.start_line <= line and line <= card.end_line and card.vstart <= vcol and vcol <= card.vfinish then return card.row.file.name end
end
]]
  )
  child.type_keys "<CR>"
  h.child_wait_for_buf_name(child, files["E.md"])
  eq(true, child.lua_get "vim.wo.wrap")
end

T["reflows cards to window width and preserves the selected card"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Cards.base"] = [[filters: 'file.ext == "md"'
views:
  - type: cards
    name: Gallery
    order: [file.name]
]],
    ["A.md"] = "a",
    ["B.md"] = "b",
    ["C.md"] = "c",
    ["D.md"] = "d",
    ["E.md"] = "e",
    ["F.md"] = "f",
    ["G.md"] = "g",
  })
  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Cards.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.cards_mode and state.gallery_columns == 3 and #state.gallery_cards == 7
]],
    { timeout = 5000, desc = "wide responsive cards" }
  )

  child.lua [[
local card = require("obsidian.bases.workspace").get(0).gallery_cards[3]
vim.api.nvim_win_set_cursor(0, { card.line, card.col })
vim.cmd "vsplit"
vim.api.nvim_win_set_width(0, 50)
vim.api.nvim_exec_autocmds("WinResized", {})
]]
  h.child_wait(child, [[return require("obsidian.bases.workspace").get(0).gallery_columns == 2]], {
    timeout = 5000,
    desc = "narrow responsive cards",
  })
  eq(
    "C",
    child.lua [[
local state = require("obsidian.bases.workspace").get(0)
local line, vcol = vim.api.nvim_win_get_cursor(0)[1], vim.fn.virtcol(".")
for _, card in ipairs(state.gallery_cards) do
  if card.start_line <= line and line <= card.end_line and card.vstart <= vcol and vcol <= card.vfinish then
    return card.row.file.name
  end
end
]]
  )
  child.type_keys "j"
  eq(
    "E",
    child.lua [[
local state = require("obsidian.bases.workspace").get(0)
local line, vcol = vim.api.nvim_win_get_cursor(0)[1], vim.fn.virtcol(".")
for _, card in ipairs(state.gallery_cards) do
  if card.start_line <= line and line <= card.end_line and card.vstart <= vcol and vcol <= card.vfinish then
    return card.row.file.name
  end
end
]]
  )
  child.lua [[vim.cmd "only"]]
end

T["keeps thumbnail mode disabled when terminal images are unsupported"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Cards.base"] = [[filters: 'file.ext == "md"'
views:
  - type: cards
    name: Gallery
    order: [file.name]
    image: cover
]],
    ["A.md"] = "---\ncover: '[[cover.png]]'\n---",
    ["cover.png"] = "png-data",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
_G.bases_image_sets = 0
vim.ui.img = {
  _supported = function() return false, "unsupported terminal" end,
  set = function()
    _G.bases_image_sets = _G.bases_image_sets + 1
    return 1
  end,
  get = function() end,
  del = function() end,
}
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Cards.base"]))
  h.child_wait(child, [[return require("obsidian.bases.workspace").get(0) ~= nil]], {
    timeout = 5000,
    desc = "unsupported thumbnail workspace",
  })
  child.type_keys "I"
  h.child_wait(child, [[return require("obsidian.bases.workspace").get(0).thumbnails_supported == false]], {
    desc = "unsupported thumbnail probe",
  })
  eq(false, child.lua_get [[require("obsidian.bases.workspace").get(0).thumbnails_enabled]])
  eq(0, child.lua_get "bases_image_sets")
end

T["renders cards as text when the nightly image API is absent"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Cards.base"] = [[views:
  - type: cards
    name: Gallery
    order: [file.name]
    image: cover
]],
    ["A.md"] = "---\ncover: '[[cover.png]]'\n---",
    ["cover.png"] = "png-data",
  })
  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
vim.ui.img = false
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Cards.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "stable-compatible cards workspace" }
  )
  eq(
    true,
    child.lua_get [[vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
    return line:find("vim.ui.img is unavailable", 1, true) ~= nil
  end)]]
  )
  child.type_keys "I"
  eq(false, child.lua_get [[require("obsidian.bases.workspace").get(0).thumbnails_enabled]])
end

T["runs CLI comparison only after explicit confirmation and clears it on refresh"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name]
]],
    ["A.md"] = "body",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
local comparison = require "obsidian.bases.compare"
_G.bases_original_compare_run = comparison.run
_G.bases_comparison_calls = 0
vim.ui.select = function(_, _, callback)
  callback "Run comparison"
end
comparison.run = function(_, result, callback, opts)
  _G.bases_comparison_calls = _G.bases_comparison_calls + 1
  _G.bases_comparison_vault = opts and opts.vault
  callback {
    status = "match",
    summary = ("matches Obsidian CLI (%d rows)"):format(#result.rows),
    diagnostics = {},
  }
  return { kill = function() _G.bases_comparison_killed = true end }
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    {
      timeout = 5000,
      desc = "CLI comparison workspace",
    }
  )
  eq(0, child.lua_get "bases_comparison_calls")
  child.type_keys "C"
  h.child_wait(
    child,
    [[
local comparison = require("obsidian.bases.workspace").get(0).comparison
return comparison and comparison.status == "match"
]],
    { desc = "CLI comparison result" }
  )
  eq(1, child.lua_get "bases_comparison_calls")
  eq(tostring(child.Obsidian.dir), child.lua_get "bases_comparison_vault")
  eq(
    true,
    child.lua_get [[vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
    return line:find("matches Obsidian CLI", 1, true) ~= nil
  end)]]
  )
  child.lua(([[
local bufnr = vim.fn.bufadd(%q)
vim.fn.bufload(bufnr)
vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
]]):format(files["Projects.base"]))
  child.type_keys "C"
  eq(1, child.lua_get "bases_comparison_calls")
  child.type_keys "r"
  h.child_wait(child, [[return require("obsidian.bases.workspace").get(0).comparison == nil]], {
    desc = "cleared CLI comparison",
  })
  child.lua [[require("obsidian.bases.compare").run = _G.bases_original_compare_run]]
end

T["refuses CLI comparison for unsaved note overlay snapshots"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name, status]
]],
    ["A.md"] = "---\nstatus: old\n---",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
local comparison = require "obsidian.bases.compare"
_G.bases_original_compare_run = comparison.run
_G.bases_comparison_calls = 0
comparison.run = function()
  _G.bases_comparison_calls = _G.bases_comparison_calls + 1
end
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["A.md"]))
  child.api.nvim_buf_set_lines(0, 1, 2, false, { "status: unsaved" })
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "overlay comparison workspace" }
  )

  child.type_keys "C"
  eq(0, child.lua_get "bases_comparison_calls")
  eq("non_comparable", child.lua_get [[require("obsidian.bases.workspace").get(0).comparison.status]])
  eq(
    true,
    child.lua_get [[require("obsidian.bases.workspace").get(0).comparison.summary:find("unsaved note overlays", 1, true) ~= nil]]
  )
  child.lua [[require("obsidian.bases.compare").run = _G.bases_original_compare_run]]
end

T["renders kanban columns with native card navigation"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Board.base"] = [[filters: 'file.ext == "md"'
views:
  - type: kanban
    name: Board
    order: [file.name, status]
    groupBy:
      property: status
      direction: ASC
]],
    ["Done.md"] = "---\nstatus: Done\n---",
    ["Planned A.md"] = "---\nstatus: Planned\n---",
    ["Planned B.md"] = "---\nstatus: Planned\n---",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Board.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.board_mode and #state.board_cards == 3 and #state.board_columns == 2
]],
    { timeout = 5000, desc = "kanban board" }
  )
  eq(false, child.lua_get "vim.wo.wrap")

  local done = child.lua [[
local state = require("obsidian.bases.workspace").get(0)
for _, card in ipairs(state.board_cards) do
  if card.row.file.name == "Done" then return { card.line, card.col } end
end
]]
  child.api.nvim_win_set_cursor(0, done)
  child.type_keys "l"
  eq(
    "Planned A",
    child.lua [[
local state = require("obsidian.bases.workspace").get(0)
local line, vcol = vim.api.nvim_win_get_cursor(0)[1], vim.fn.virtcol(".")
for _, card in ipairs(state.board_cards) do
  if card.line == line and card.vstart <= vcol and vcol <= card.vfinish then return card.row.file.name end
end
]]
  )
  child.type_keys "j"
  eq(
    "Planned B",
    child.lua [[
local state = require("obsidian.bases.workspace").get(0)
local line, vcol = vim.api.nvim_win_get_cursor(0)[1], vim.fn.virtcol(".")
for _, card in ipairs(state.board_cards) do
  if card.line == line and card.vstart <= vcol and vcol <= card.vfinish then return card.row.file.name end
end
]]
  )
  child.type_keys "<CR>"
  h.child_wait_for_buf_name(child, files["Planned B.md"])
  eq(true, child.lua_get "vim.wo.wrap")
end

T["renders collapsible grouped list views with group navigation"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[filters: 'file.ext == "md"'
views:
  - type: list
    name: By status
    order: [file.name, status]
    groupBy:
      property: status
      direction: ASC
]],
    ["Planned.md"] = "---\nstatus: Planned\n---",
    ["Done.md"] = "---\nstatus: Done\n---",
    ["Empty.md"] = "# Empty",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
return text:find("▾ Done (1)", 1, true)
  and text:find("▾ Planned (1)", 1, true)
  and text:find("▾ (empty) (1)", 1, true)
  and text:find("• Done · Done", 1, true)
]],
    { timeout = 5000, desc = "grouped list view" }
  )

  local done_line = child.lua [[
for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if line == "▾ Done (1)" then return index end
end
]]
  child.api.nvim_win_set_cursor(0, { done_line, 0 })
  child.type_keys "<CR>"
  h.child_wait(
    child,
    [[
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
return text:find("▸ Done (1)", 1, true) and not text:find("• Done · Done", 1, true)
]],
    { desc = "collapsed group" }
  )

  child.type_keys "]g"
  eq(true, child.lua_get [[vim.api.nvim_get_current_line():find("Planned", 1, true) ~= nil]])
  child.type_keys "r"
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line == "▸ Done (1)"
end)
]],
    { timeout = 5000, desc = "preserved collapsed group" }
  )
end

T["queries arbitrary vault files by file metadata"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Files.base"] = [[filters: 'file.ext == "txt" || file.ext == "custom"'
views:
  - type: table
    name: Files
    order: [file.path, file.ext]
]],
    ["data.txt"] = "data",
    ["assets/cover.custom"] = "image",
    ["Note.md"] = "# Note",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Files.base"]))
  h.child_wait(
    child,
    [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local text, custom = false, false
for _, line in ipairs(lines) do
  text = text or line:find("data.txt", 1, true) ~= nil
  custom = custom or line:find("assets/cover.custom", 1, true) ~= nil
end
return text and custom
]],
    { timeout = 5000, desc = "arbitrary file results" }
  )

  local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(
    false,
    vim.iter(lines):any(function(line)
      return line:find("Note.md", 1, true) ~= nil
    end)
  )
end

T["real command opens a read-only local workspace and navigates notes"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[filters:
  and:
    - 'status == "active"'
properties:
  status:
    displayName: Status
views:
  - type: table
    name: Active
    order: [file.name, status]
    sort:
      - property: file.name
        direction: ASC
]],
    ["One.md"] = "---\nstatus: active\n---\nOne body",
    ["Two.md"] = "---\nstatus: done\n---\nTwo body",
  })

  local original_base = vim.fn.readfile(files["Projects.base"])

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
  ]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
return vim.bo.filetype == "obsidian-bases"
  and vim.iter(lines):any(function(line) return line:find("Status: ready/current/complete", 1, true) ~= nil end)
]],
    { timeout = 5000, desc = "ready Bases workspace" }
  )

  eq(true, child.lua_get "vim.bo.readonly")
  eq(false, child.lua_get "vim.bo.modifiable")
  local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(
    true,
    vim.iter(lines):any(function(line)
      return line:find("One", 1, true) ~= nil and line:find("active", 1, true) ~= nil
    end)
  )
  eq(
    false,
    vim.iter(lines):any(function(line)
      return line:find("Two", 1, true) ~= nil
    end)
  )
  eq(
    true,
    vim.iter(lines):any(function(line)
      return line == "Obsidian CLI comparison: not run · C compare explicitly"
    end)
  )
  eq(original_base, vim.fn.readfile(files["Projects.base"]))

  local row = child.lua [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
  if line:find("One", 1, true) and line:find("active", 1, true) then return index end
end
]]
  child.api.nvim_win_set_cursor(0, { row, 0 })
  child.type_keys "<CR>"
  h.child_wait_for_buf_name(child, files["One.md"])
end

T["real command filters wikilink properties while preserving editable source values"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Links.base"] = [[filters: 'related == link("B")'
views:
  - type: table
    name: Linked
    order: [file.name, related]
]],
    ["A.md"] = '---\nrelated: "[[B]]"\n---',
    ["B.md"] = "body",
  })
  child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Links.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "wikilink property filter" }
  )
  eq(1, child.lua_get [[#require("obsidian.bases.workspace").get(0).result.rows]])
  eq({ "A", "[[B]]" }, child.lua_get [[require("obsidian.bases.workspace").get(0).result.rows[1].cells]])
end

T["real command reports boolean-wrapped runtime errors as unsupported"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Broken.base"] = [[filters: '!nonexistentFunction()'
views:
  - type: table
    name: Broken
]],
    ["One.md"] = "body",
  })
  child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Broken.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "unsupported"
]],
    { timeout = 5000, desc = "boolean expression error" }
  )
  eq(0, child.lua_get [[#require("obsidian.bases.workspace").get(0).result.rows]])
  eq("unsupported", child.lua_get [[require("obsidian.bases.workspace").get(0).result.completeness]])
end

T["real command finishes descending sorts with mixed missing and null values"] = function()
  local contents = {
    ["Nullable.base"] = [[filters: 'file.ext == "md"'
views:
  - type: table
    name: Nullable
    sort:
      - property: priority
        direction: DESC
]],
  }
  for index = 1, 7 do
    contents[index .. ".md"] = index % 2 == 0 and "---\npriority: null\n---" or "body"
  end
  local files = h.child_mock_vault_contents(child, contents)
  child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Nullable.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "mixed-null descending sort" }
  )
  eq(
    { "1.md", "2.md", "3.md", "4.md", "5.md", "6.md", "7.md" },
    child.lua_get [[
vim.tbl_map(function(row) return row.file.path end, require("obsidian.bases.workspace").get(0).result.rows)
]]
  )
end

T["manual refresh reconciles disk changes without watched-file events"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[filters: '(file.ext == "md" && status == "active") || file.ext == "png"'
views:
  - type: table
    name: Active
    order: [file.name, status]
]],
    ["One.md"] = "---\nstatus: active\n---\nbody",
    ["Old.png"] = "old image",
  })
  child.lua [[
vim.cmd.runtime "plugin/obsidian.lua"
Obsidian.opts.file.ignore_filters = { "ignored/**" }
-- Model an unavailable watcher, without mocking source collection or queries.
require("obsidian.lsp.watchfiles").handle = function() return {} end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready" and #state.result.rows == 2
]],
    { timeout = 5000, desc = "initial manual-refresh result" }
  )

  child.lua(([[
vim.fn.writefile({ "---", "status: done", "---", "new body" }, %q)
vim.fn.delete(%q)
local root = tostring(Obsidian.dir)
vim.fn.writefile({ "new image" }, vim.fs.joinpath(root, "New.png"))
vim.fn.mkdir(vim.fs.joinpath(root, "ignored"), "p")
vim.fn.writefile({ "ignored image" }, vim.fs.joinpath(root, "ignored", "Hidden.png"))
_G.bases_rescan_builds = 0
local index = require "obsidian.index.files"
local build = index._build_row
index._build_row = function(...)
  _G.bases_rescan_builds = _G.bases_rescan_builds + 1
  return build(...)
end
local workspace = require "obsidian.bases.workspace"
workspace._schedule_refresh(workspace.get(0))
]]):format(files["One.md"], files["Old.png"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state.refresh_timer == nil and state.result.status == "ready"
]],
    { timeout = 5000, desc = "incremental automatic refresh" }
  )
  eq(0, child.lua_get "bases_rescan_builds")
  eq(2, child.lua_get '#require("obsidian.bases.workspace").get(0).result.rows')

  child.type_keys "r"
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state.result.status == "ready" and state.result.freshness == "current"
  and #state.result.rows == 1 and state.result.rows[1].file.path == "New.png"
]],
    { timeout = 5000, desc = "manual rescan after missed watch events" }
  )
  eq(true, child.lua_get "bases_rescan_builds > 0")
end

T["refresh reads modified note buffers and leaves disk unchanged"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[filters: 'status == "active"'
views:
  - type: table
    name: Active
    order: [file.name, status]
]],
    ["One.md"] = "---\nstatus: done\n---\nOne body",
  })
  local original_note = vim.fn.readfile(files["One.md"])

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["One.md"]))
  child.api.nvim_buf_set_lines(0, 0, 3, false, { "---", "status: active", "---" })
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) and line:find("active", 1, true)
end)
]],
    { timeout = 5000, desc = "modified-buffer Bases result" }
  )

  child.lua(([[
local wanted = vim.fs.normalize(%q)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == wanted then
    vim.api.nvim_buf_set_lines(buf, 0, 3, false, { "---", "status: done", "---" })
    break
  end
end
require("obsidian.bases.workspace").refresh()
]]):format(files["One.md"]))
  h.child_wait(
    child,
    [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
return vim.iter(lines):any(function(line) return line:find("Status: ready/current/complete", 1, true) end)
  and not vim.iter(lines):any(function(line) return line:find("One", 1, true) and line:find("active", 1, true) end)
]],
    { timeout = 5000, desc = "refreshed Bases result" }
  )

  eq(original_note, vim.fn.readfile(files["One.md"]))
end

T["edits an existing scalar cell in a note buffer without saving"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name, status]
]],
    ["One.md"] = "---\nstatus: old\n---\nOne body",
  })
  local original_note = vim.fn.readfile(files["One.md"])

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
vim.ui.input = function(_, callback) callback("active") end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) and line:find("old", 1, true)
end)
]],
    { timeout = 5000, desc = "editable Bases row" }
  )

  local cell = child.lua [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
  local col = line:find("old", 1, true)
  if line:find("One", 1, true) and col then return { index, col - 1 } end
end
]]
  child.api.nvim_win_set_cursor(0, cell)
  child.type_keys "e"
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) and line:find("active", 1, true)
end)
]],
    { timeout = 5000, desc = "edited Bases row" }
  )

  local buffer_state = child.lua(([[
local wanted = vim.fs.normalize(%q)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == wanted then
    return { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), modified = vim.bo[buf].modified }
  end
end
]]):format(files["One.md"]))
  eq({ "---", "status: active", "---", "One body" }, buffer_state.lines)
  eq(true, buffer_state.modified)
  eq(original_note, vim.fn.readfile(files["One.md"]))
end

T["refuses property edits for text, Base, and attachment rows"] = function()
  local contents = {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.path, status]
]],
    ["Data.txt"] = "---\nstatus: old\n---\ntext",
    ["Definition.base"] = "---\nstatus: old\n---\nbase",
    ["Attachment.png"] = "not-a-note",
  }
  local files = h.child_mock_vault_contents(child, contents)

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
_G.bases_edit_input_calls = 0
vim.ui.input = function(_, callback)
  _G.bases_edit_input_calls = _G.bases_edit_input_calls + 1
  callback("active")
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
return vim.iter({ "Data.txt", "Definition.base", "Attachment.png" }):all(function(target)
  return vim.iter(lines):any(function(line) return line:find(target, 1, true) ~= nil end)
end)
]],
    { timeout = 5000, desc = "non-note Bases rows" }
  )

  child.lua [[
_G.bases_edit_notices = {}
vim.notify = function(message, level)
  _G.bases_edit_notices[#_G.bases_edit_notices + 1] = { message = message, level = level }
end
]]
  for _, target in ipairs { "Data.txt", "Definition.base", "Attachment.png" } do
    local cell = child.lua(([[
local target = %q
for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if line:find(target, 1, true) then return { index, math.max(0, #line - 1) } end
end
]]):format(target))
    child.api.nvim_win_set_cursor(0, cell)
    child.type_keys "e"
  end

  eq(0, child.lua_get "bases_edit_input_calls")
  eq(3, child.lua_get "#bases_edit_notices")
  eq(
    true,
    child.lua_get [[vim.iter(bases_edit_notices):all(function(notice)
      return notice.message == "Only supported Markdown note rows are editable"
        and notice.level == vim.log.levels.WARN
    end)]]
  )
  for name, original in pairs(contents) do
    if name ~= "Projects.base" then
      eq(vim.split(original, "\n", { plain = true }), vim.fn.readfile(files[name]))
    end
  end
end

T["edits supported Markdown-like rows without saving"] = function()
  local original_note = { "---", "status: old", "---", "body" }
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.path, status]
]],
    ["One.md"] = table.concat(original_note, "\n"),
    ["Two.markdown"] = table.concat(original_note, "\n"),
    ["Three.qmd"] = table.concat(original_note, "\n"),
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
vim.ui.input = function(_, callback) callback("active") end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
return vim.iter({ "One.md", "Two.markdown", "Three.qmd" }):all(function(target)
  return vim.iter(lines):any(function(line)
    return line:find(target, 1, true) and line:find("old", 1, true)
  end)
end)
]],
    { timeout = 5000, desc = "supported Markdown-like Bases rows" }
  )

  for _, target in ipairs { "One.md", "Two.markdown", "Three.qmd" } do
    local cell = child.lua(([[
local target = %q
for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  local col = line:find("old", 1, true)
  if line:find(target, 1, true) and col then return { index, col - 1 } end
end
]]):format(target))
    child.api.nvim_win_set_cursor(0, cell)
    child.type_keys "e"
    h.child_wait(
      child,
      ([=[
local target = %q
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find(target, 1, true) and line:find("active", 1, true)
end)
]=]):format(target),
      { timeout = 5000, desc = "edited " .. target .. " Bases row" }
    )
  end

  for _, target in ipairs { "One.md", "Two.markdown", "Three.qmd" } do
    local buffer_state = child.lua(([=[
local wanted = vim.fs.normalize(%q)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == wanted then
    return { line = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], modified = vim.bo[buf].modified }
  end
end
]=]):format(files[target]))
    eq({ line = "status: active", modified = true }, buffer_state)
    eq(original_note, vim.fn.readfile(files[target]))
  end
end

T["inserts a missing scalar property from an empty cell"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name, owner]
]],
    ["One.md"] = "---\nstatus: active\n---\nOne body",
  })
  local original_note = vim.fn.readfile(files["One.md"])

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
vim.ui.input = function(_, callback) callback("Ada") end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) ~= nil
end)
]],
    { timeout = 5000, desc = "row with missing property" }
  )

  local cell = child.lua [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
  if line:find("One", 1, true) then return { index, math.max(0, #line - 1) } end
end
]]
  child.api.nvim_win_set_cursor(0, cell)
  child.type_keys "e"
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) and line:find("Ada", 1, true)
end)
]],
    { timeout = 5000, desc = "inserted Bases property" }
  )

  local buffer_state = child.lua(([[
local wanted = vim.fs.normalize(%q)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == wanted then
    return { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), modified = vim.bo[buf].modified }
  end
end
]]):format(files["One.md"]))
  eq({ "---", "status: active", "owner: Ada", "---", "One body" }, buffer_state.lines)
  eq(true, buffer_state.modified)
  eq(original_note, vim.fn.readfile(files["One.md"]))
end

T["refuses adding a property to sequence-root frontmatter through the real command"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[filters: 'file.ext == "md"'
views:
  - type: table
    name: Projects
    order: [file.name, owner]
]],
    ["Sequence.md"] = "---\n- first\n- second\n---\nbody",
  })
  local original = vim.fn.readfile(files["Sequence.md"])
  child.lua [[
vim.cmd.runtime "plugin/obsidian.lua"
vim.ui.input = function(_, callback) callback("Ada") end
_G.bases_edit_warning = nil
vim.notify = function(message) _G.bases_edit_warning = message end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "sequence-root Bases row" }
  )
  child.lua [[
local state = require("obsidian.bases.workspace").get(0)
for line, row in pairs(state.line_rows) do
  if row.file.path == "Sequence.md" then
    local col = vim.fn.virtcol2col(0, line, state.column_spans[2].start)
    vim.api.nvim_win_set_cursor(0, { line, col - 1 })
    break
  end
end
]]
  child.type_keys "e"
  h.child_wait(child, [[return _G.bases_edit_warning ~= nil]], { desc = "refused sequence-root insertion" })
  eq("Bases edit refused: frontmatter must be a block mapping", child.lua_get "bases_edit_warning")
  local state = child.lua(([[
local buf = vim.fn.bufnr(%q)
return { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), modified = vim.bo[buf].modified }
]]):format(files["Sequence.md"]))
  eq(original, state.lines)
  eq(false, state.modified)
  eq(original, vim.fn.readfile(files["Sequence.md"]))
end

T["uses declared types for missing property editors"] = function()
  local files = h.child_mock_vault_contents(child, {
    [".obsidian/types.json"] = vim.json.encode { types = { owners = "multitext" } },
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name, owners]
]],
    ["One.md"] = "---\nstatus: active\n---\nOne body",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
vim.ui.input = function(opts, callback)
  _G.bases_edit_prompt = opts.prompt
  _G.bases_edit_default = opts.default
  callback("[Ada, Bob]")
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) ~= nil
end)
]],
    { timeout = 5000, desc = "declared list property row" }
  )

  local cell = child.lua [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
  if line:find("One", 1, true) then return { index, math.max(0, #line - 1) } end
end
]]
  child.api.nvim_win_set_cursor(0, cell)
  child.type_keys "e"
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) and line:find("Ada, Bob", 1, true)
end)
]],
    { timeout = 5000, desc = "declared list property edit" }
  )

  eq("Add owners (list): ", child.lua_get "bases_edit_prompt")
  eq("[]", child.lua_get "bases_edit_default")
  local note_line = child.lua(([[
local wanted = vim.fs.normalize(%q)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == wanted then
    return vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1]
  end
end
]]):format(files["One.md"]))
  eq("owners: [Ada, Bob]", note_line)
end

T["refuses prompt edits after property type metadata changes and refreshes"] = function()
  local original_types = vim.json.encode { types = { owners = "multitext" } }
  local files = h.child_mock_vault_contents(child, {
    [".obsidian/types.json"] = original_types,
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name, owners]
]],
    ["One.md"] = "---\nstatus: active\n---\nOne body",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
_G.bases_original_notify = vim.notify
_G.bases_notifications = {}
vim.notify = function(message)
  _G.bases_notifications[#_G.bases_notifications + 1] = message
end
vim.ui.input = function(_, callback)
  _G.bases_edit_callback = callback
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
  and state.result.columns[2].declared_type == "multitext"
]],
    { timeout = 5000, desc = "typed prompt workspace" }
  )
  child.lua [[_G.bases_workspace_buf = vim.api.nvim_get_current_buf()]]

  local cell = child.lua [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
  if line:find("One", 1, true) then return { index, math.max(0, #line - 1) } end
end
]]
  child.api.nvim_win_set_cursor(0, cell)
  child.type_keys "e"
  h.child_wait(child, [[return type(_G.bases_edit_callback) == "function"]], { desc = "open Bases edit prompt" })

  child.lua(([=[
local bufnr = vim.fn.bufadd(%q)
vim.fn.bufload(bufnr)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { vim.json.encode { types = { owners = "text" } } })
_G.bases_edit_callback("[Ada]")
]=]):format(files[".obsidian/types.json"]))

  eq(
    true,
    child.lua_get [[vim.iter(_G.bases_notifications):any(function(message)
    return message:find("property type metadata changed while the prompt was open", 1, true) ~= nil
  end)]]
  )
  eq(
    false,
    child.lua(([=[
local wanted = vim.fs.normalize(%q)
for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) == wanted then
    return vim.iter(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)):any(function(line)
      return line:find("owners:", 1, true) ~= nil
    end)
  end
end
return false
]=]):format(files["One.md"]))
  )
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(_G.bases_workspace_buf)
return state and state.result and state.result.status == "ready"
  and state.result.columns[2].declared_type == "text"
]],
    { timeout = 5000, desc = "types metadata refresh" }
  )
  eq({ original_types }, vim.fn.readfile(files[".obsidian/types.json"]))
  child.lua [[vim.notify = _G.bases_original_notify]]
end

T["changes declared property types in an unsaved guarded metadata buffer"] = function()
  local original_types = {
    "{",
    '  "types": {',
    '    "priority": "text",',
    '    "plugin-owned": "custom"',
    "  },",
    '  "other": true',
    "}",
  }
  local files = h.child_mock_vault_contents(child, {
    [".obsidian/types.json"] = table.concat(original_types, "\n"),
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name, priority]
]],
    ["One.md"] = "---\npriority: 1\n---\nOne body",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
vim.ui.select = function(items, opts, callback)
  _G.bases_type_prompt = opts.prompt
  callback "number"
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "property type workspace" }
  )

  local cell = child.lua [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
  local col = line:find("1", 1, true)
  if line:find("One", 1, true) and col then return { index, col - 1 } end
end
]]
  child.api.nvim_win_set_cursor(0, cell)
  child.type_keys "t"
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.columns[2].declared_type == "number"
]],
    { timeout = 5000, desc = "updated property type" }
  )

  eq(true, child.lua_get [[bases_type_prompt:find("current: text", 1, true) ~= nil]])
  local buffer_state = child.lua(([=[
local wanted = vim.fs.normalize(%q)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == wanted then
    return { lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), modified = vim.bo[buf].modified }
  end
end
]=]):format(files[".obsidian/types.json"]))
  eq(true, buffer_state.modified)
  eq(
    true,
    vim.iter(buffer_state.lines):any(function(line)
      return line:find('"priority": "number"', 1, true) ~= nil
    end)
  )
  eq(
    true,
    vim.iter(buffer_state.lines):any(function(line)
      return line:find('"plugin-owned": "custom"', 1, true) ~= nil
    end)
  )
  eq(original_types, vim.fn.readfile(files[".obsidian/types.json"]))
end

T["uses the typed list editor from a list cell"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Projects.base"] = [[views:
  - type: table
    name: Projects
    order: [file.name, owners]
]],
    ["One.md"] = "---\nowners: [one, two]\n---\nOne body",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
vim.ui.input = function(opts, callback)
  _G.bases_edit_prompt = opts.prompt
  _G.bases_edit_default = opts.default
  callback("[three, four]")
end
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Projects.base"]))
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) and line:find("one, two", 1, true)
end)
]],
    { timeout = 5000, desc = "list Bases row" }
  )

  local cell = child.lua [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for index, line in ipairs(lines) do
  local col = line:find("one, two", 1, true)
  if col then return { index, col - 1 } end
end
]]
  child.api.nvim_win_set_cursor(0, cell)
  child.type_keys "e"
  h.child_wait(
    child,
    [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("One", 1, true) and line:find("three, four", 1, true)
end)
]],
    { timeout = 5000, desc = "edited list Bases row" }
  )

  eq("Edit owners (list): ", child.lua_get "bases_edit_prompt")
  eq("[one, two]", child.lua_get "bases_edit_default")
  local note_line = child.lua(([[
local wanted = vim.fs.normalize(%q)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == wanted then
    return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
  end
end
]]):format(files["One.md"]))
  eq("owners: [three, four]", note_line)
end

T["command opens a shortest-path Base embed from another folder"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Bases/Projects.base"] = [[filters: 'file.ext == "md"'
views:
  - type: table
    name: Active
]],
    ["Notes/Home.md"] = "![[Projects.base#Active]]",
  })
  child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Notes/Home.md"]))
  child.api.nvim_win_set_cursor(0, { 1, 5 })
  child.cmd "Obsidian bases"
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "shortest-path embedded Base" }
  )
  eq(files["Bases/Projects.base"], child.lua_get [[require("obsidian.bases.workspace").get(0).spec.path]])
  eq(files["Notes/Home.md"], child.lua_get [[require("obsidian.bases.workspace").get(0).spec.context_path]])
  eq("Active", child.lua_get [[require("obsidian.bases.workspace").get(0).result.view_name]])
end

T["command preserves ambiguous embedded-Base diagnostics"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["A/Projects.base"] = "views:\n  - type: table",
    ["B/Projects.base"] = "views:\n  - type: table",
    ["Notes/Home.md"] = "![[Projects.base]]",
  })
  child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Notes/Home.md"]))
  child.api.nvim_win_set_cursor(0, { 1, 5 })
  child.lua [[
_G.bases_command_ok, _G.bases_command_error = pcall(vim.cmd, "Obsidian bases")
]]
  eq(false, child.lua_get "bases_command_ok")
  eq(true, child.lua_get [[bases_command_error:find("Base target is ambiguous", 1, true) ~= nil]])
  eq(false, child.lua_get [[require("obsidian.bases.workspace").get(0) ~= nil]])
end

T["command opens the Base under cursor with its original context"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["By folder.base"] = [[filters: 'file.folder == this.file.folder'
views:
  - type: table
    name: Nearby
    order: [file.path]
]],
    ["Folder/Context.md"] = "![[By folder.base#Nearby]]",
    ["Folder/Match.md"] = "---\nstatus: active\n---",
    ["Other/Other.md"] = "---\nstatus: active\n---",
  })

  child.lua [[
if vim.fn.exists(":Obsidian") == 0 then
  vim.cmd.runtime "plugin/obsidian.lua"
end
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Folder/Context.md"]))
  child.api.nvim_win_set_cursor(0, { 1, 5 })
  child.cmd "Obsidian bases"
  h.child_wait(
    child,
    [[
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
return vim.iter(lines):any(function(line) return line:find("Folder/Match.md", 1, true) end)
]],
    { timeout = 5000, desc = "context-pinned embedded Base" }
  )

  local lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(
    true,
    vim.iter(lines):any(function(line)
      return line:find("Context: " .. files["Folder/Context.md"], 1, true) ~= nil
    end)
  )
  eq(
    false,
    vim.iter(lines):any(function(line)
      return line:find("Other/Other.md", 1, true) ~= nil
    end)
  )
end

T["command pins a fenced Base to its containing buffer across refreshes"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Folder/Context.md"] = [[```base
filters: 'file.folder == this.file.folder && file.ext == "md"'
views:
  - type: table
    name: Inline
    order: [file.path]
```]],
    ["Folder/Match.md"] = "body",
    ["Other.md"] = "body",
  })
  child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Folder/Context.md"]))
  local source_buf = child.api.nvim_get_current_buf()
  child.api.nvim_win_set_cursor(0, { 3, 1 })
  child.cmd "Obsidian bases"
  local workspace_buf = child.api.nvim_get_current_buf()
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready"
]],
    { timeout = 5000, desc = "fenced Base command" }
  )
  eq("Inline", child.lua_get [[require("obsidian.bases.workspace").get(0).result.view_name]])
  eq(
    { "Folder/Context.md", "Folder/Match.md" },
    child.lua_get [[
vim.tbl_map(function(row) return row.file.path end, require("obsidian.bases.workspace").get(0).result.rows)
]]
  )

  child.cmd("edit " .. vim.fn.fnameescape(files["Other.md"]))
  child.api.nvim_buf_set_lines(source_buf, 4, 5, false, { "    name: Refreshed" })
  child.lua(([[require("obsidian.bases.workspace").refresh(%d)]]):format(workspace_buf))
  h.child_wait(
    child,
    ([[
local result = require("obsidian.bases.workspace").get(%d).result
return result.status == "ready" and result.view_name == "Refreshed"
]]):format(workspace_buf),
    { timeout = 5000, desc = "refresh from the pinned fenced source" }
  )
end

for _, layout in ipairs { "table", "list", "kanban", "cards" } do
  T["renders multiline properties in " .. layout .. " views"] = function()
    local files = h.child_mock_vault_contents(child, {
      ["Multiline.base"] = ([[filters: 'file.ext == "md"'
views:
  - type: %s
    name: Multiline
    order: [file.name, description]
    groupBy:
      property: description
]]):format(layout),
      ["One.md"] = "---\ndescription: |\n  first\n  second\tthird\n---",
    })
    child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
    child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Multiline.base"]))
    h.child_wait(
      child,
      [[
return vim.iter(vim.api.nvim_buf_get_lines(0, 0, -1, false)):any(function(line)
  return line:find("first second third", 1, true) ~= nil
end)
]],
      { timeout = 5000, desc = "single-line rendering of multiline property" }
    )
    eq(false, child.lua_get "vim.bo.modifiable")
    eq(
      "first\nsecond\tthird",
      child.lua_get [[require("obsidian.bases.workspace").get(0).result.rows[1].note.description]]
    )
  end
end

T["measures grouped table columns once per render"] = function()
  local contents = {
    ["Grouped.base"] = [[filters: 'file.ext == "md"'
views:
  - type: table
    name: Grouped
    order: [file.name]
    groupBy:
      property: rank
]],
  }
  for index = 1, 80 do
    contents["measure-" .. index .. ".md"] = "---\nrank: " .. index .. "\n---"
  end
  local files = h.child_mock_vault_contents(child, contents)
  child.lua [[vim.cmd.runtime "plugin/obsidian.lua"]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Grouped.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.result and state.result.status == "ready" and #state.group_lines == 80
]],
    { timeout = 5000, desc = "many-group table" }
  )
  local count = child.lua [[
local state = require("obsidian.bases.workspace").get(0)
local original = vim.fn.strdisplaywidth
local calls = 0
vim.fn.strdisplaywidth = function(value, ...)
  if value:find("measure-", 1, true) then calls = calls + 1 end
  return original(value, ...)
end
local ok, err = pcall(state.query.callback, state.result)
vim.fn.strdisplaywidth = original
assert(ok, err)
return calls
]]
  eq(true, count <= 4 * 80)
end

T["positions thumbnails by display columns and removes them on hide and close"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Images.base"] = [[filters: 'file.ext == "md"'
views:
  - type: cards
    name: Images
    order: [title]
    image: cover
]],
    ["A.md"] = "---\ntitle: 你好\ncover: cover.png\n---",
    ["B.md"] = "---\ntitle: second\ncover: cover.png\n---",
    ["cover.png"] = "png-data",
  })
  child.lua [[
vim.cmd.runtime "plugin/obsidian.lua"
_G.bases_live_images = {}
local next_id = 0
vim.ui.img = {
  _supported = function() return true end,
  get = function() end,
  set = function(data, opts)
    local id = data
    if type(data) ~= "number" then next_id = next_id + 1; id = next_id end
    bases_live_images[id] = opts
    return id
  end,
  del = function(id) bases_live_images[id] = nil end,
}
]]
  child.lua(([[vim.cmd("Obsidian bases " .. vim.fn.fnameescape(%q))]]):format(files["Images.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and #state.gallery_cards == 2
]],
    { timeout = 5000, desc = "thumbnail gallery" }
  )
  child.lua [[_G.bases_image_state = require("obsidian.bases.workspace").get(0)]]
  child.type_keys "I"
  child.lua [[
local card = bases_image_state.gallery_cards[1]
vim.api.nvim_win_set_cursor(0, { card.image_line, 0 })
vim.cmd "normal! zt"
vim.api.nvim_exec_autocmds("WinScrolled", {})
]]
  h.child_wait(child, [[return vim.tbl_count(bases_live_images) == 2]], { desc = "two visible thumbnails" })
  eq(
    true,
    child.lua [=[
local card = bases_image_state.gallery_cards[2]
local col = vim.fn.virtcol2col(0, card.image_line, card.vstart + 1)
local position = vim.fn.screenpos(0, card.image_line, col)
local opts = bases_live_images[bases_image_state.thumbnail_ids[card.row.path]]
return opts.row == position.row and opts.col == position.col
]=]
  )
  child.cmd "enew"
  h.child_wait(child, [[return next(bases_live_images) == nil]], { desc = "hidden workspace image cleanup" })
  eq(0, child.lua_get "vim.tbl_count(bases_image_state.thumbnail_data)")
  child.lua [[
vim.api.nvim_set_current_buf(bases_image_state.buf)
local card = bases_image_state.gallery_cards[1]
vim.api.nvim_win_set_cursor(0, { card.image_line, 0 })
vim.cmd "normal! zt"
]]
  h.child_wait(child, [[return vim.tbl_count(bases_live_images) == 2]], { desc = "restored thumbnails" })
  child.lua [[require("obsidian.bases.workspace").close(bases_image_state.buf)]]
  eq(0, child.lua_get "vim.tbl_count(bases_live_images)")
  eq(0, child.lua_get "vim.tbl_count(bases_image_state.thumbnail_data)")
end

return T
