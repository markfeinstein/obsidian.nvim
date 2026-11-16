-- Cross-layer regressions: real files, shared index, Node evaluator, and query model.
local definition = require "obsidian.bases.definition"
local files = require "obsidian.index.files"
local property_types = require "obsidian.properties.types"
local query = require "obsidian.bases.query"
local worker = require "obsidian.bases.worker"
local h = require "tests.helpers"

local eq = MiniTest.expect.equality
local root, original_obsidian
local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      original_obsidian = Obsidian
      files.clear()
      property_types.clear()
      worker._set_paths(nil)
      root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/.obsidian", "p")
      root = assert(vim.uv.fs_realpath(root))
      Obsidian = {
        dir = root,
        opts = { sync = { config_dir = ".obsidian" }, file = { ignore_filters = {} } },
      }
    end,
    post_case = function()
      worker.stop()
      files.clear()
      property_types.clear()
      vim.fn.delete(root, "rf")
      Obsidian = original_obsidian
    end,
  },
}

local function write(path, lines)
  vim.fn.writefile(lines, root .. "/" .. path)
end

local function evaluate(lines)
  local parsed, err = definition.parse(lines, { identity = "pipeline-test", revision = 1 })
  assert(parsed, err)
  local result
  local instance = query.new(parsed, { vault = root }, function(value)
    if value.status ~= "refreshing" then
      result = value
    end
  end)
  instance:refresh()
  h.wait(function()
    return result ~= nil
  end, { timeout = 5000, desc = "real Bases query result" })
  instance:dispose()
  eq("ready", result.status)
  eq("complete", result.completeness)
  return result
end

T["sorts declared datetimes and date formulas by instant before limiting"] = function()
  write(".obsidian/types.json", { '{"types":{"due":"datetime"}}' })
  local earlier, later = "2026-01-02T00:30:00+02:00", "2026-01-01T23:00:00Z"
  write("Earlier.md", { "---", 'Due: "' .. earlier .. '"', "---" })
  write("Later.md", { "---", 'Due: "' .. later .. '"', "---" })
  for _, property in ipairs { "Due", "note.Due", "formula.instant" } do
    for _, direction in ipairs { "ASC", "DESC" } do
      local result = evaluate {
        "formulas:",
        "  instant: Due",
        "views:",
        "  - type: table",
        "    order: [file.name, Due]",
        "    limit: 1",
        "    sort:",
        "      - property: " .. property,
        "        direction: " .. direction,
      }
      eq(1, #result.rows)
      eq(direction == "ASC" and "Earlier.md" or "Later.md", result.rows[1].file.path)
      -- Normalization must not replace the raw expected value used by editing.
      eq(direction == "ASC" and earlier or later, result.rows[1].note.Due)
      eq(result.rows[1].note.Due, result.rows[1].cells[2])
    end
  end
end

T["keeps equal instants stable and preserves the null sort position"] = function()
  write(".obsidian/types.json", { '{"types":{"due":"date"}}' })
  write("A.md", { "---", 'due: "2026-01-02T00:30:00+02:00"', "---" })
  write("B.md", { "---", 'due: "2026-01-01T22:30:00Z"', "---" })
  write("Missing.md", { "body" })
  write("Null.md", { "---", "due: null", "---" })
  for _, direction in ipairs { "ASC", "DESC" } do
    local result = evaluate {
      "views:",
      "  - type: table",
      "    sort:",
      "      - property: note.due",
      "        direction: " .. direction,
    }
    local paths = vim.tbl_map(function(row)
      return row.file.path
    end, result.rows)
    eq(
      direction == "ASC" and { "A.md", "B.md", "Missing.md", "Null.md" } or { "Missing.md", "Null.md", "A.md", "B.md" },
      paths
    )
  end
end

T["counts internal links without counting external URLs"] = function()
  write("External.md", {
    "[web](https://example.com)",
    "[upper](HTTPS://example.com)",
    "[mail](mailto:reader@example.com)",
    "[app](obsidian://open?vault=Elsewhere)",
    "[network](//example.com/page)",
    "![remote](https://example.com/image.png)",
  })
  write("Internal.md", {
    "[[Missing]]",
    "[existing](Target.md)",
    "![[Missing.png]]",
  })
  write("Target.md", { "no outgoing links" })
  local result = evaluate {
    "filters: file.links.length > 0",
    "formulas:",
    "  links: file.links.length",
    "  embeds: file.embeds.length",
    "views:",
    "  - type: table",
  }
  eq(1, #result.rows)
  local row = result.rows[1]
  eq("Internal.md", row.file.path)
  eq(3, row.formulas.links)
  eq(1, row.formulas.embeds)
  eq("Missing", row.file.links[1].path)
  eq(nil, row.file.links[1].resolvedPath)
  eq("Target.md", row.file.links[2].resolvedPath)
end

T["keeps creation times across metadata changes for notes attachments and context fallbacks"] = function()
  local function milliseconds(time)
    return time.sec * 1000 + math.floor(time.nsec / 1000000)
  end
  local function create_then_change(path)
    write(path, { "content" })
    -- Ensure a metadata change occurs after creation on filesystems exposing
    -- birth time. The portable fallback is covered separately in test_fs.lua.
    vim.wait(25, function()
      return false
    end)
    assert(vim.uv.fs_chmod(root .. "/" .. path, 384))
    local stat = assert(vim.uv.fs_stat(root .. "/" .. path))
    local born = stat.birthtime
    local created = born and (born.sec ~= 0 or born.nsec ~= 0) and born or stat.ctime
    return milliseconds(created), milliseconds(stat.mtime)
  end
  local created, modified = {}, {}
  for _, path in ipairs { "Note.md", "Attachment.bin" } do
    created[path], modified[path] = create_then_change(path)
  end
  local result = evaluate {
    "formulas:",
    "  created: 'file.ctime.format(\"x\")'",
    "views:",
    "  - type: table",
  }
  eq(2, #result.rows)
  for _, row in ipairs(result.rows) do
    eq(created[row.file.path], row.file.ctime)
    eq(modified[row.file.path], row.file.mtime)
    eq(created[row.file.path], tonumber(row.formulas.created))
  end
  -- These files are created after the cached index snapshot, so context_file
  -- must use its Markdown and generic-file fallback paths, not indexed rows.
  for _, path in ipairs { "Context.md", "Context.base" } do
    local expected = create_then_change(path)
    local context = require("obsidian.bases.source").context_file(root .. "/" .. path, { vault = root })
    eq(expected, context.ctime)
  end
end

return T
