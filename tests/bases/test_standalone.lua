local h = require "tests.helpers"

local eq = MiniTest.expect.equality
local T, child = h.child_vault {
  post_case = [[require("obsidian.bases.workspace").close_all()]],
}

T["opens standalone Base files as a current-window workspace and provides a raw escape"] = function()
  local definition = [[views:
  - type: table
    name: Standalone
    order: [file.name]
]]
  local files = h.child_mock_vault_contents(child, {
    ["Standalone.base"] = definition,
    ["One.md"] = "body",
  })
  child.lua [[
Obsidian.opts.bases.standalone.auto_open = true
vim.cmd.runtime "plugin/obsidian.lua"
]]
  child.cmd("edit " .. vim.fn.fnameescape(files["Standalone.base"]))
  h.child_wait(
    child,
    [[
local state = require("obsidian.bases.workspace").get(0)
return state and state.spec.path:match("Standalone%.base$") ~= nil
]],
    { timeout = 5000, desc = "automatic standalone Base workspace" }
  )
  eq("obsidian-bases", child.bo.filetype)
  eq(1, #child.api.nvim_list_wins())
  local workspace_buf = child.api.nvim_get_current_buf()
  eq(true, child.lua_get [[require("obsidian.bases.workspace").get(0).raw_buf ~= nil]])

  child.cmd "Obsidian bases --raw"
  eq(vim.fs.normalize(files["Standalone.base"]), vim.fs.normalize(child.api.nvim_buf_get_name(0)))
  eq(true, child.b.obsidian_bases_raw)
  local expected = vim.split(definition, "\n", { plain = true, trimempty = true })
  local expected_buffer = vim.deepcopy(expected)
  expected_buffer[#expected_buffer + 1] = ""
  eq(expected_buffer, child.api.nvim_buf_get_lines(0, 0, -1, false))
  eq(expected_buffer, vim.fn.readfile(files["Standalone.base"]))
  eq(false, child.api.nvim_buf_is_valid(workspace_buf))

  child.cmd("edit! " .. vim.fn.fnameescape(files["Standalone.base"]))
  vim.wait(100, function()
    return false
  end)
  eq(vim.fs.normalize(files["Standalone.base"]), vim.fs.normalize(child.api.nvim_buf_get_name(0)))
  eq(vim.NIL, child.lua_get [[require("obsidian.bases.workspace").get(0)]])
end

T["does not auto-open outside-vault Base files"] = function()
  local outside = vim.fn.tempname() .. ".base"
  vim.fn.writefile({ "views:", "  - type: table" }, outside)
  child.lua [[Obsidian.opts.bases.standalone.auto_open = true; vim.cmd.runtime "plugin/obsidian.lua"]]
  child.cmd("edit " .. vim.fn.fnameescape(outside))
  vim.wait(100, function()
    return false
  end)
  eq(vim.uv.fs_realpath(outside), vim.uv.fs_realpath(child.api.nvim_buf_get_name(0)))
  eq(vim.NIL, child.lua_get [[require("obsidian.bases.workspace").get(0)]])
  vim.fn.delete(outside)
end

return T
