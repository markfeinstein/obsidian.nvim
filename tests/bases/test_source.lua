local files = require "obsidian.index.files"
local source = require "obsidian.bases.source"
local worker = require "obsidian.bases.worker"
local h = require "tests.helpers"

local eq = MiniTest.expect.equality
local root
local outside
local buffers

local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      files.clear()
      root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
      root = assert(vim.uv.fs_realpath(root))
      outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")
      outside = assert(vim.uv.fs_realpath(outside))
      buffers = {}
      Obsidian = {
        dir = root,
        opts = {
          sync = { config_dir = ".obsidian" },
          file = { ignore_filters = {} },
        },
      }
    end,
    post_case = function()
      worker.stop()
      files.clear()
      for _, bufnr in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      vim.fn.delete(root, "rf")
      vim.fn.delete(outside, "rf")
    end,
  },
}

local function write(rel, lines)
  local path = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return path
end

local function write_bytes(rel, contents)
  local path = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  assert(file:write(contents))
  file:close()
  return path
end

local function collect(opts)
  local collected, limitations, completed
  source.collect(function(rows, partial)
    collected, limitations, completed = rows, partial, true
  end, opts)
  assert(
    vim.wait(5000, function()
      return completed
    end),
    "timed out waiting for Bases source collection"
  )
  assert(collected, "Bases source collection returned no rows")
  return collected, limitations
end

local function by_path(rows)
  local result = {}
  for _, row in ipairs(rows) do
    result[row.path] = row
  end
  return result
end

T["collects arbitrary files with lossless note properties"] = function()
  local note = write("Project.md", {
    "---",
    "nested:",
    "  child: value",
    "items:",
    "  - [one, two]",
    "empty: []",
    "empty_object: {}",
    "---",
  })
  local text = write("data.txt", { "data" })
  local image = write("cover.custom", { "image" })

  local rows, limitations = collect()
  rows = by_path(rows)
  eq({ child = "value" }, rows[note].note.nested)
  eq({ { "one", "two" } }, rows[note].note.items)
  eq({}, rows[note].note.empty)
  eq(true, vim.islist(rows[note].note.empty))
  eq("[]", vim.json.encode(rows[note].note.empty))
  eq({}, rows[note].note.empty_object)
  eq(false, vim.islist(rows[note].note.empty_object))
  eq("{}", vim.json.encode(rows[note].note.empty_object))
  eq("txt", rows[text].file.ext)
  eq({}, rows[text].note)
  eq("custom", rows[image].file.ext)
  eq({}, limitations)
  eq(nil, rows[note].file.backlinks)
end

T["keeps inline tags separate from frontmatter properties in queries and overlays"] = function()
  local inline = write("Inline.md", { "body #inline" })
  local tagged = write("Tagged.md", { "---", "tags: [frontmatter]", "---", "body #body" })
  write("Untagged.md", { "body" })
  local rows = by_path(collect())
  eq(nil, rows[inline].note.tags)
  eq(nil, rows[inline].file.properties.tags)
  eq({ "inline" }, rows[inline].file.tags)
  eq({ "frontmatter" }, rows[tagged].note.tags)
  eq({ "frontmatter" }, rows[tagged].file.properties.tags)
  eq({ "frontmatter", "body" }, rows[tagged].file.tags)
  eq(nil, source.context_file(inline).properties.tags)

  local buf = vim.fn.bufadd(inline)
  vim.fn.bufload(buf)
  buffers[#buffers + 1] = buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "body #unsaved" })
  rows = by_path(collect())
  eq(nil, rows[inline].note.tags)
  eq({ "unsaved" }, rows[inline].file.tags)
  eq(nil, source.context_file(inline).properties.tags)

  local definition = assert(require("obsidian.bases.definition").parse {
    "filters: tags != null",
    "views:",
    "  - type: table",
    "    name: Frontmatter tags",
    "    order: [file.name, tags]",
  })
  local result
  local query = require("obsidian.bases.query").new(definition, { vault = root }, function(value)
    if value.status ~= "refreshing" then
      result = value
    end
  end)
  query:refresh()
  h.wait(function()
    return result ~= nil
  end, { desc = "frontmatter-only tag query" })
  query:dispose()
  eq("ready", result.status)
  eq("complete", result.completeness)
  eq(1, #result.rows)
  eq("Tagged.md", result.rows[1].file.path)
  eq({ "Tagged", "frontmatter" }, result.rows[1].cells)
  eq({ "body #inline" }, vim.fn.readfile(inline))
end

T["preserves dotted file names in evaluator rows and pinned contexts"] = function()
  local note = write("My.Project.md", { "body" })
  local image = write("My.Project.png", { "image" })
  local context = write("My.Context.md", { "context" })
  local rows = collect()
  local indexed = by_path(rows)
  eq("My.Project", indexed[note].file.name)
  eq("My.Project", indexed[note].file.basename)
  eq("My.Project", indexed[image].file.basename)
  local result, err
  worker.evaluate({
    rows = rows,
    this_file = source.context_file(context),
    global_filter = 'file.name == "My.Project" && this.file.name == "My.Context"',
    formulas = { name = "file.name" },
  }, function(value, failure)
    result, err = value, failure
  end)
  h.wait(function()
    return result ~= nil or err ~= nil
  end, { desc = "dotted file name evaluation" })
  eq(nil, err)
  eq("current", result.state)
  eq(2, #result.matches)
  for _, match in ipairs(result.matches) do
    eq("My.Project", match.formulas.name)
  end
end

T["evaluates source-relative outgoing links and embeds in rows and pinned contexts"] = function()
  write("Targets/Dest.md", { "destination" })
  write("Targets/Cover.png", { "image" })
  local context = write("Sources/Source.md", {
    "[dest](../Targets/Dest.md#Section)",
    "![cover](../Targets/Cover.png)",
  })
  local rows = collect()
  local result, err
  worker.evaluate({
    rows = rows,
    this_file = source.context_file(context),
    global_filter = 'file.path == "Sources/Source.md" && file.hasLink("Targets/Dest.md") && this.file.hasLink("Targets/Dest.md")',
    formulas = { target = "file.links[0].asFile().path", image = "file.embeds[0].asFile().path" },
  }, function(value, failure)
    result, err = value, failure
  end)
  h.wait(function()
    return result ~= nil or err ~= nil
  end, { desc = "source-relative outgoing link evaluation" })
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)
  eq({ target = "Targets/Dest.md", image = "Targets/Cover.png" }, result.matches[1].formulas)
end

T["queries declared dates consistently across real file contexts"] = function()
  write(".obsidian/types.json", { '{"types":{"due":"date"}}' })
  write("Dated.md", { "---", "due: 2026-11-15", "---" })
  local context = write("Context.md", { "---", "due: 2026-11-15", "---" })
  local definition = assert(require("obsidian.bases.definition").parse {
    [[filters: 'file.path == "Dated.md" && due == this.file.properties.due']],
    "formulas:",
    "  current: file.properties.due.year",
    [[  foreign: 'file("Context.md").properties.due.year']],
    "views:",
    "  - type: table",
    "    name: Dates",
    "    order: [file.name, formula.current, formula.foreign]",
  })
  local result
  local query = require("obsidian.bases.query").new(definition, { vault = root, path = context }, function(value)
    if value.status ~= "refreshing" then
      result = value
    end
  end)
  query:refresh()
  h.wait(function()
    return result ~= nil
  end, { desc = "typed file context query" })
  query:dispose()
  eq("ready", result.status)
  eq("complete", result.completeness)
  eq(1, #result.rows)
  eq({ current = 2026, foreign = 2026 }, result.rows[1].formulas)
  eq("2026-11-15", result.rows[1].note.due)
end

T["evaluates wikilink properties using the source snapshot without rewriting values"] = function()
  write("Targets/Dest.md", { "destination" })
  local path = write("Sources/Source.md", {
    "---",
    'related: "[[../Targets/Dest#Section|Target]]"',
    'related_list: ["[[../Targets/Dest]]", plain]',
    "---",
  })
  local rows = collect()
  local result, err
  worker.evaluate({
    rows = rows,
    this_file = source.context_file(path),
    property_types = { related = "string", related_list = "list" },
    global_filter = 'file.path == "Sources/Source.md" && related_list.contains(link("Targets/Dest.md"))',
    formulas = {
      target = "related.asFile().path",
      context_target = "this.file.properties.related.asFile().path",
      file_target = 'file("Sources/Source.md").properties.related.asFile().path',
    },
  }, function(value, failure)
    result, err = value, failure
  end)
  h.wait(function()
    return result ~= nil or err ~= nil
  end, { desc = "wikilink property evaluation" })
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)
  eq(
    { target = "Targets/Dest.md", context_target = "Targets/Dest.md", file_target = "Targets/Dest.md" },
    result.matches[1].formulas
  )
  eq("[[../Targets/Dest#Section|Target]]", by_path(rows)[path].note.related)
  eq({ "[[../Targets/Dest]]", "plain" }, by_path(rows)[path].note.related_list)
end

T["keeps ambiguous links unresolved through the real evaluator"] = function()
  write("A/Folder/Target.md", { "first target" })
  write("Z/Folder/Target.md", { "second target" })
  local path = write("Source.md", {
    "---",
    'related: "[[Target]]"',
    'partial: "[[Folder/Target]]"',
    'exact: "[[A/Folder/Target]]"',
    "---",
    "[[Target]]",
  })
  local rows = collect { backlinks = true }
  local indexed = by_path(rows)
  eq(nil, indexed[path].file.links[1].resolvedPath)
  eq({ { path = "Source.md", resolvedPath = "Source.md" } }, indexed[root .. "/A/Folder/Target.md"].file.backlinks)
  local result, err
  worker.evaluate({
    rows = rows,
    this_file = source.context_file(path),
    global_filter = 'file.path == "Source.md"',
    formulas = {
      outgoing = "file.links[0].asFile() == null",
      property = "related.asFile() == null",
      partial = "partial.asFile() == null",
      computed = 'link("Folder/" + "Target").asFile() == null',
      file_property = 'file("Source.md").properties.related.asFile() == null',
      context = "this.file.properties.related.asFile() == null",
      has_wrong_target = 'file.hasLink("Z/Folder/Target.md")',
      exact = "exact.asFile().path",
    },
  }, function(value, failure)
    result, err = value, failure
  end)
  h.wait(function()
    return result ~= nil or err ~= nil
  end, { desc = "ambiguous link evaluation" })
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)
  eq({
    outgoing = true,
    property = true,
    partial = true,
    computed = true,
    file_property = true,
    context = true,
    has_wrong_target = false,
    exact = "A/Folder/Target.md",
  }, result.matches[1].formulas)
  eq({}, indexed[root .. "/Z/Folder/Target.md"].file.backlinks)
end

T["computes backlink files only when requested"] = function()
  local target = write("Projects/Target.md", { "target" })
  write("Other/Target.md", { "other" })
  write("Source.md", { "[[Projects/Target]]", "[[Projects/Target#Section]]", "[[Target]]" })
  write("Notes/Relative.md", { "[target](../Projects/Target.md#Section)" })

  local ordinary = by_path(collect())
  eq(nil, ordinary[target].file.backlinks)

  local rows, limitations = collect { backlinks = true }
  rows = by_path(rows)
  eq({
    { path = "Notes/Relative.md", resolvedPath = "Notes/Relative.md" },
    { path = "Source.md", resolvedPath = "Source.md" },
  }, rows[target].file.backlinks)
  eq({}, limitations)
end

for _, expression in ipairs {
  "file.backlinks.length > 0",
  'file["backlinks"].length > 0',
  "file . backlinks.length > 0",
  'file["back" + "links"].length > 0',
  "file[formula.key].length > 0",
} do
  T["queries incoming links through " .. expression] = function()
    write("Target.md", { "target" })
    write("Source.md", { "[[Target]]" })
    local definition = assert(require("obsidian.bases.definition").parse {
      "filters: '" .. expression .. "'",
      "formulas:",
      '  key: \'"back" + "links"\'',
      "views:",
      "  - type: table",
      "    name: Incoming",
      "    order: [file.path]",
    })
    local result
    local query = require("obsidian.bases.query").new(definition, { vault = root }, function(value)
      if value.status ~= "refreshing" then
        result = value
      end
    end)
    query:refresh()
    h.wait(function()
      return result ~= nil
    end, { desc = "incoming-link query" })
    query:dispose()
    eq("ready", result.status)
    eq("complete", result.completeness)
    eq(1, #result.rows)
    eq("Target.md", result.rows[1].file.path)
  end
end

T["prefers source-relative Markdown paths without changing wiki lookup"] = function()
  local nested = write("Notes/children/Target.md", { "nested" })
  local vault_target = write("children/Target.md", { "vault" })
  local sibling = write("Notes/Sibling.md", { "sibling" })
  write("Other/Sibling.md", { "ambiguous shortest path" })
  local source_path = write("Notes/Source.md", {
    "[child](children/Target.md#Heading)",
    "[child again](./children/Target.md)",
    "[sibling](Sibling.md)",
  })
  local wiki_path = write("Notes/Wiki.md", { "[[children/Target]]", "[[Sibling]]" })
  local rows = by_path(collect { backlinks = true })
  local source_link = { { path = "Notes/Source.md", resolvedPath = "Notes/Source.md" } }
  eq("Notes/children/Target.md", rows[source_path].file.links[1].resolvedPath)
  eq("Notes/children/Target.md", rows[source_path].file.links[2].resolvedPath)
  eq("Notes/Sibling.md", rows[source_path].file.links[3].resolvedPath)
  eq("children/Target.md", rows[wiki_path].file.links[1].resolvedPath)
  eq(source_link, rows[nested].file.backlinks)
  eq(source_link, rows[sibling].file.backlinks)
  eq({ { path = "Notes/Wiki.md", resolvedPath = "Notes/Wiki.md" } }, rows[vault_target].file.backlinks)
end

T["resolves exact root links despite duplicate basenames"] = function()
  local target = write("Target.md", { "root target" })
  local duplicate = write("Nested/Target.md", { "nested target" })
  local path = write("Source.md", {
    "[explicit](./Target.md)",
    "[ordinary](Target.md)",
    "[root](/Target.md)",
  })
  write("Notes/Source.md", { "[parent](../Target.md)" })
  local rows = collect { backlinks = true }
  local indexed = by_path(rows)
  for _, link in ipairs(indexed[path].file.links) do
    eq("Target.md", link.resolvedPath)
  end
  eq({
    { path = "Notes/Source.md", resolvedPath = "Notes/Source.md" },
    { path = "Source.md", resolvedPath = "Source.md" },
  }, indexed[target].file.backlinks)
  eq({}, indexed[duplicate].file.backlinks)
  local result, err
  worker.evaluate({
    rows = rows,
    this_file = source.context_file(path),
    global_filter = 'file.path == "Source.md" && file.hasLink("Target.md")',
    formulas = {
      target = "file.links[0].asFile().path",
      context = "this.file.links[0].asFile().path",
    },
  }, function(value, failure)
    result, err = value, failure
  end)
  h.wait(function()
    return result ~= nil or err ~= nil
  end, { desc = "exact root link evaluation" })
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)
  eq({ target = "Target.md", context = "Target.md" }, result.matches[1].formulas)
end

T["does not resolve missing explicit paths through shortest-path aliases"] = function()
  local target = write("Nested/Target.md", { "nested target" })
  local path = write("Source.md", {
    "[missing](./Target.md)",
    "[missing root](/Target.md)",
    "[[Nested/Target]]",
  })
  write("Notes/Source.md", { "[missing parent](../Target.md)" })
  local rows = by_path(collect { backlinks = true })
  eq(nil, rows[path].file.links[1].resolvedPath)
  eq(nil, rows[path].file.links[2].resolvedPath)
  eq("Nested/Target.md", rows[path].file.links[3].resolvedPath)
  eq({ { path = "Source.md", resolvedPath = "Source.md" } }, rows[target].file.backlinks)
end

T["resolves unique directory suffix links and retains suffix ambiguity"] = function()
  local unique = write("Projects/Docs/Guide.markdown", { "guide" })
  write("A/Docs/Target.md", { "first target" })
  write("Z/Docs/Target.md", { "second target" })
  local path = write("Source.md", { "[[Docs/Guide]]", "[[Docs/Target]]" })
  local rows = by_path(collect { backlinks = true })
  eq("Projects/Docs/Guide.markdown", rows[path].file.links[1].resolvedPath)
  eq(nil, rows[path].file.links[2].resolvedPath)
  eq({ { path = "Source.md", resolvedPath = "Source.md" } }, rows[unique].file.backlinks)
end

T["resolves supported backlink extensions without hiding mixed-extension ambiguity"] = function()
  local markdown = write("Docs/Guide.markdown", { "guide" })
  local qmd = write("Reports/Quarter.qmd", { "quarter" })
  local mixed_md = write("Mixed/Target.md", { "md" })
  local mixed_markdown = write("Mixed/Target.markdown", { "markdown" })
  local mixed_qmd = write("Mixed/Target.qmd", { "qmd" })
  write("Sources/Unique.md", { "[[Docs/Guide]]", "[[Reports/Quarter]]" })
  write("Sources/Ambiguous.md", { "[[Mixed/Target]]" })
  write("Sources/ExplicitMd.md", { "[[Mixed/Target.md]]" })
  write("Sources/ExplicitMarkdown.md", { "[[Mixed/Target.markdown]]" })
  write("Sources/ExplicitQmd.md", { "[[Mixed/Target.qmd]]" })

  local rows = by_path(collect { backlinks = true })
  eq({ { path = "Sources/Unique.md", resolvedPath = "Sources/Unique.md" } }, rows[markdown].file.backlinks)
  eq({ { path = "Sources/Unique.md", resolvedPath = "Sources/Unique.md" } }, rows[qmd].file.backlinks)
  eq({ { path = "Sources/ExplicitMd.md", resolvedPath = "Sources/ExplicitMd.md" } }, rows[mixed_md].file.backlinks)
  eq({
    { path = "Sources/ExplicitMarkdown.md", resolvedPath = "Sources/ExplicitMarkdown.md" },
  }, rows[mixed_markdown].file.backlinks)
  eq({ { path = "Sources/ExplicitQmd.md", resolvedPath = "Sources/ExplicitQmd.md" } }, rows[mixed_qmd].file.backlinks)
end

T["indexes CRLF note properties and links"] = function()
  local target = write("Target.md", { "target" })
  write("Image.png", { "image" })
  local note = write_bytes("Source.md", "---\r\nstatus: active\r\n---\r\n[[Target]]\r\n![[Image.png]]\r\n")

  local rows, limitations = collect { backlinks = true }
  rows = by_path(rows)
  eq("active", rows[note].note.status)
  eq({
    { path = "Target", resolvedPath = "Target.md" },
    { path = "Image.png", resolvedPath = "Image.png" },
  }, rows[note].file.links)
  eq({ { path = "Image.png", resolvedPath = "Image.png" } }, rows[note].file.embeds)
  eq({ { path = "Source.md", resolvedPath = "Source.md" } }, rows[target].file.backlinks)
  eq({}, limitations)
end

T["overlays modified buffers without writing Markdown source"] = function()
  local path = write("Project.md", { "---", "status: old", "---", "body" })
  local buf = vim.api.nvim_create_buf(false, false)
  buffers[#buffers + 1] = buf
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "---",
    "status: active",
    "nested:",
    "  child: unsaved",
    "---",
    "body",
  })
  vim.bo[buf].modified = true

  local collected = by_path(collect())
  eq("active", collected[path].note.status)
  eq({ child = "unsaved" }, collected[path].note.nested)
  eq("old", files.peek()[path].properties.status)
  eq("buffer", collected[path].revision.kind)
  eq(vim.api.nvim_buf_get_changedtick(buf), collected[path].revision.changedtick)
  eq({ "---", "status: old", "---", "body" }, vim.fn.readfile(path))
end

T["does not collect note contents through an outside-vault symlink"] = function()
  local outside_note = vim.fs.joinpath(outside, "Secret.md")
  vim.fn.writefile({ "---", "secret: leaked", "---" }, outside_note)
  local linked = vim.fs.joinpath(root, "Linked.md")
  assert(vim.uv.fs_symlink(outside_note, linked))

  local rows = by_path(collect())
  eq(nil, rows[linked])
end

T["modified buffers respect vault internals and ignore filters"] = function()
  Obsidian.opts.file.ignore_filters = { "private/**" }
  local excluded = { ".obsidian/Internal.md", ".git/Internal.md", "private/Hidden.md" }
  for _, rel in ipairs(excluded) do
    local path = write(rel, { "disk" })
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    buffers[#buffers + 1] = buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
  end
  local new_path = vim.fs.joinpath(root, "New.md")
  local buf = vim.fn.bufadd(new_path)
  vim.fn.bufload(buf)
  buffers[#buffers + 1] = buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "---", "status: new", "---" })

  local rows = by_path(collect())
  for _, rel in ipairs(excluded) do
    eq(nil, rows[vim.fs.joinpath(root, rel)])
  end
  eq("new", rows[new_path].note.status)
  eq("buffer", rows[new_path].revision.kind)
end

return T
