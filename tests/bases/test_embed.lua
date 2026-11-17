local base_embed = require "obsidian.bases.embed"
local embed = require "obsidian.embed"

local eq = MiniTest.expect.equality
local namespace = vim.api.nvim_create_namespace "obsidian-nvim-embeds"
local root

local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      embed.detach_all()
      root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      root = assert(vim.uv.fs_realpath(root), "failed to resolve test vault")
      vim.fn.writefile({
        "views:",
        "  - type: table",
        "    name: Active",
        "    order: [file.name]",
      }, vim.fs.joinpath(root, "Projects.base"))
      Obsidian = Obsidian or {}
      Obsidian.dir = root
    end,
    post_case = function()
      embed.detach_all()
      vim.fn.delete(root, "rf")
    end,
  },
}

local function note_buffer(name, lines)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(root, name))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function virt_text(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
  local text = {}
  for _, mark in ipairs(marks) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do
        text[#text + 1] = chunk[1]
      end
    end
  end
  return table.concat(text)
end

T["resolves linked embeds with a pinned containing-note context"] = function()
  local first = note_buffer("Folder/First.md", { "![[Projects.base#Active]]" })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  local first_spec = base_embed.at_cursor(first)
  eq(vim.fs.joinpath(root, "Folder", "First.md"), first_spec.context_path)
  eq("Active", first_spec.view)
  local definition = first_spec.load()
  eq("Active", definition.view_name)

  local second = note_buffer("Second.md", { "![[Projects.base#Active]]" })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  local second_spec = base_embed.at_cursor(second)
  eq(vim.fs.joinpath(root, "Second.md"), second_spec.context_path)
  eq(false, first_spec.context_path == second_spec.context_path)
end

T["discovers a unique shortest-path Base without an action hint"] = function()
  vim.fn.mkdir(root .. "/Bases", "p")
  eq(0, vim.fn.rename(root .. "/Projects.base", root .. "/Bases/Projects.base"))
  local source = { "![[Projects.base#Active]]" }
  local buf = note_buffer("Folder/Home.md", source)
  embed.attach(buf)
  eq("", virt_text(buf))
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  local spec, err = base_embed.at_cursor(buf)
  eq(nil, err)
  eq(root .. "/Bases/Projects.base", spec.path)
  eq(source, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

T["parses fenced base blocks and ignores examples in other fences"] = function()
  local buf = note_buffer("Inline.md", {
    "```base",
    "views:",
    "  - type: table",
    "    name: Inline",
    "    order: [file.name]",
    "```",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  local spec = base_embed.at_cursor(buf)
  eq(true, spec.inline)
  eq(vim.fs.joinpath(root, "Inline.md"), spec.context_path)
  local definition = spec.load()
  eq("Inline", definition.view_name)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "```markdown", "![[Projects.base]]", "```" })
  vim.api.nvim_win_set_cursor(0, { 2, 5 })
  eq(nil, base_embed.at_cursor(buf))

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "%% ![[Projects.base]] %%" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  eq(nil, base_embed.at_cursor(buf))
end

T["does not render linked-Base action hints or change Markdown"] = function()
  local source = { "![[Projects.base#Active]]", "", "```markdown", "![[Projects.base]]", "```" }
  local buf = note_buffer("Preview.md", source)
  embed.attach(buf)

  eq("", virt_text(buf))
  eq(source, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

return T
