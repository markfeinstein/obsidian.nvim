local h = require "tests.helpers"

local eq = MiniTest.expect.equality
local T, child = h.child_vault {
  post_case = [[
local inline = package.loaded["obsidian.bases.inline"]
if inline then inline.stop() end
local query = package.loaded["obsidian.bases.query"]
if query and _G.bases_inline_original_query_new then
  query.new = _G.bases_inline_original_query_new
  _G.bases_inline_original_query_new = nil
end
require("obsidian.bases.worker")._set_paths(nil)
]],
}

local function use_real_worker()
  child.lua(
    [[
require("obsidian.bases.worker")._set_paths {
  dependency = ...,
}
]],
    { vim.fs.joinpath(vim.uv.cwd(), "node_modules", "obsidian-bases-expression", "package.json") }
  )
end

local function rendered_text(buf)
  return child.lua_get(([[
(function()
  local text = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(%d, require("obsidian.bases.inline")._namespace, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do text[#text + 1] = chunk[1] end
    end
  end
  return table.concat(text, "\n")
end)()
]]):format(buf))
end

T["automatically renders linked named and fenced Bases without modifying the note"] = function()
  use_real_worker()
  local source = [=[![[Context.base#Named]]

```base
filters: 'file.folder == this.file.folder && file.ext == "md"'
views:
  - type: table
    name: Inline
    order: [file.path]
```]=]
  local files = h.child_mock_vault_contents(child, {
    ["Context.base"] = [[filters: 'file.folder == this.file.folder && file.ext == "md"'
views:
  - type: table
    name: Default
    order: [file.path]
  - type: list
    name: Named
    order: [file.path]
]],
    ["A/Daily.md"] = source,
    ["B/Daily.md"] = "![[Context.base#Named]]",
    ["A/Other.md"] = "body",
    ["B/Other.md"] = "body",
  })
  child.lua [[
Obsidian.opts.bases.inline.enabled = true
vim.cmd.runtime "plugin/obsidian.lua"
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["A/Daily.md"]))
  local first = child.api.nvim_get_current_buf()
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.inline").get(0)
if not state or vim.tbl_count(state.items) ~= 2 then return false end
for _, item in pairs(state.items) do
  if not item.result or item.result.status ~= "ready" then return false end
end
return true
]],
    { timeout = 5000, desc = "two inline Base results" }
  )
  eq(false, child.bo.modified)
  eq(vim.split(source, "\n", { plain = true }), child.api.nvim_buf_get_lines(first, 0, -1, false))
  eq(vim.split(source, "\n", { plain = true }), vim.fn.readfile(files["A/Daily.md"]))
  local text = rendered_text(first)
  eq(true, text:find("Base · Named · ready/current", 1, true) ~= nil)
  eq(true, text:find("Base · Inline · ready/current", 1, true) ~= nil)
  eq(true, text:find("A/Daily.md", 1, true) ~= nil)
  eq(false, text:find("B/Daily.md", 1, true) ~= nil)

  child.cmd("edit " .. vim.fn.fnameescape(files["B/Daily.md"]))
  local second = child.api.nvim_get_current_buf()
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.inline").get(0)
local item = state and vim.tbl_values(state.items)[1]
return item and item.result and item.result.status == "ready"
]],
    { timeout = 5000, desc = "second daily-note context" }
  )
  local second_text = rendered_text(second)
  eq(true, second_text:find("B/Daily.md", 1, true) ~= nil)
  eq(false, second_text:find("A/Daily.md", 1, true) ~= nil)
end

T["refreshes from unsaved vault data and distinguishes empty and unsupported results"] = function()
  use_real_worker()
  local files = h.child_mock_vault_contents(child, {
    ["Status.base"] = [[filters: 'status == "active"'
views:
  - type: table
    name: Status
    order: [file.name, status]
]],
    ["Empty.base"] = [[filters: 'false'
views:
  - type: table
    name: Empty
]],
    ["Broken.base"] = [[filters: '!nonexistentFunction()'
views:
  - type: table
    name: Broken
]],
    ["Dashboard.md"] = "![[Status.base]]\n![[Empty.base]]\n![[Broken.base]]",
    ["One.md"] = "---\nstatus: active\n---",
    ["Two.md"] = "---\nstatus: done\n---",
  })
  child.lua [[Obsidian.opts.bases.inline.enabled = true; vim.cmd.runtime "plugin/obsidian.lua"]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Dashboard.md"]))
  local dashboard = child.api.nvim_get_current_buf()
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.inline").get(0)
if not state or vim.tbl_count(state.items) ~= 3 then return false end
local statuses = {}
for _, item in pairs(state.items) do
  if not item.result then return false end
  statuses[item.result.view_name] = item.result.status
end
return statuses.Status == "ready" and statuses.Empty == "ready" and statuses.Broken == "unsupported"
]],
    { timeout = 5000, desc = "inline empty and unsupported states" }
  )
  local text = rendered_text(dashboard)
  eq(true, text:find("No results", 1, true) ~= nil)
  eq(true, text:find("nonexistentFunction", 1, true) ~= nil)

  child.cmd("edit " .. vim.fn.fnameescape(files["Status.base"]))
  local definition_buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(definition_buf, 0, 1, false, { [[filters: 'status == "done"']] })
  child.api.nvim_exec_autocmds("TextChanged", { buffer = definition_buf })
  h.child_wait(
    child,
    ([=[
local state = require("obsidian.bases.inline").get(%d)
for _, item in pairs(state.items) do
  if item.result and item.result.view_name == "Status" and item.result.status == "ready" then
    return #item.result.rows == 1 and item.result.rows[1].file.name == "Two"
  end
end
return false
]=]):format(dashboard),
    { timeout = 5000, desc = "unsaved definition refresh" }
  )
  child.api.nvim_buf_set_lines(definition_buf, 0, 1, false, { [[filters: 'status == "active"']] })
  child.api.nvim_exec_autocmds("TextChanged", { buffer = definition_buf })

  child.cmd("edit " .. vim.fn.fnameescape(files["Two.md"]))
  local data_buf = child.api.nvim_get_current_buf()
  child.api.nvim_buf_set_lines(data_buf, 1, 2, false, { "status: active" })
  child.api.nvim_exec_autocmds("TextChanged", { buffer = data_buf })
  h.child_wait(
    child,
    ([=[
local state = require("obsidian.bases.inline").get(%d)
for _, item in pairs(state.items) do
  if item.result and item.result.view_name == "Status" then
    return item.result.status == "ready" and #item.result.rows == 2
  end
end
return false
]=]):format(dashboard),
    { timeout = 5000, desc = "unsaved data refresh" }
  )
  eq({ "---", "status: done", "---" }, vim.fn.readfile(files["Two.md"]))
end

T["renders missing evaluator backends as diagnostics instead of empty results"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Backend.base"] = "views:\n  - type: table\n    name: Backend",
    ["Note.md"] = "![[Backend.base]]",
  })
  child.lua [[
require("obsidian.bases.worker")._set_paths { dependency = "/definitely/missing/package.json" }
Obsidian.opts.bases.inline.enabled = true
vim.cmd.runtime "plugin/obsidian.lua"
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Note.md"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.inline").get(0)
local item = state and vim.tbl_values(state.items)[1]
return item and item.result and item.result.status == "backend_unavailable"
]],
    { desc = "inline missing backend diagnostic" }
  )
  local text = rendered_text(child.api.nvim_get_current_buf())
  eq(true, text:find "obsidian%-bases%-expression@0%.2%.0 is not installed" ~= nil)
  eq(false, text:find("No results", 1, true) ~= nil)
end

T["rejects obsolete callbacks and cleans up removed embeds"] = function()
  local files = h.child_mock_vault_contents(child, {
    ["Pending.base"] = "views:\n  - type: table\n    name: Pending",
    ["Note.md"] = "![[Pending.base]]",
  })
  child.lua [[
local query = require "obsidian.bases.query"
_G.bases_inline_original_query_new = query.new
_G.bases_inline_disposed = 0
_G.bases_inline_callbacks = {}
query.new = function(_, _, callback)
  local instance = { current = nil, callback = callback }
  function instance:refresh()
    self.callback({
      status = "refreshing", freshness = "current", completeness = "partial",
      backend = { name = "test", version = "1" }, view_name = "Pending", view_type = "table",
      columns = { { label = "file.name" } }, rows = {}, diagnostics = {}, source_count = 0, matched_count = 0,
    })
    _G.bases_inline_callbacks[#_G.bases_inline_callbacks + 1] = self.callback
  end
  function instance:dispose() _G.bases_inline_disposed = _G.bases_inline_disposed + 1 end
  return instance
end
Obsidian.opts.bases.inline.enabled = true
vim.cmd.runtime "plugin/obsidian.lua"
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Note.md"]))
  local note = child.api.nvim_get_current_buf()
  h.child_wait(child, [[return #_G.bases_inline_callbacks == 1]], { desc = "pending inline callback" })
  child.api.nvim_buf_set_lines(note, 0, -1, false, { "embed removed" })
  child.lua [[require("obsidian.bases.inline")._refresh_now(require("obsidian.bases.inline").get(0), false)]]
  child.lua [[
_G.bases_inline_callbacks[1]({
  status = "ready", freshness = "current", completeness = "complete",
  backend = { name = "test", version = "1" }, view_name = "Late", view_type = "table",
  columns = { { label = "file.name" } }, rows = {}, diagnostics = {}, source_count = 0, matched_count = 0,
})
]]
  eq(1, child.lua_get "bases_inline_disposed")
  eq(0, child.lua_get [[vim.tbl_count(require("obsidian.bases.inline").get(0).items)]])
  eq("", rendered_text(note))
  child.api.nvim_buf_delete(note, { force = true })
  eq(vim.NIL, child.lua_get(([[require("obsidian.bases.inline").get(%d)]]):format(note)))
end

T["surfaces ignored and outside-vault resolution failures at the embed"] = function()
  local outside = vim.fn.tempname() .. ".base"
  vim.fn.writefile({ "views:", "  - type: table" }, outside)
  local files = h.child_mock_vault_contents(child, {
    ["Ignored/Hidden.base"] = "views:\n  - type: table",
    ["Note.md"] = "![[Ignored/Hidden.base]]\n![[" .. outside .. "]]",
  })
  child.lua [[
Obsidian.opts.file.ignore_filters = { "Ignored/**" }
Obsidian.opts.bases.inline.enabled = true
vim.cmd.runtime "plugin/obsidian.lua"
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Note.md"]))
  local note = child.api.nvim_get_current_buf()
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.inline").get(0)
return state and vim.tbl_count(state.items) == 2
]],
    { desc = "inline resolution diagnostics" }
  )
  local text = rendered_text(note)
  eq(true, text:find("Base not found", 1, true) ~= nil)
  eq(true, text:find("outside the vault", 1, true) ~= nil)
  vim.fn.delete(outside)
end

return T
