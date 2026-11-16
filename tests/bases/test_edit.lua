local edit = require "obsidian.bases.edit"
local property_types = require "obsidian.properties.types"

local eq = MiniTest.expect.equality
local root
local buffers

local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      property_types.clear()
      root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
      root = assert(vim.uv.fs_realpath(root))
      buffers = {}
      Obsidian = Obsidian or {}
      Obsidian.dir = root
      Obsidian.opts = Obsidian.opts or {}
      Obsidian.opts.sync = { config_dir = ".obsidian" }
    end,
    post_case = function()
      property_types.clear()
      for _, bufnr in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      vim.fn.delete(root, "rf")
    end,
  },
}

local function write_note(name, lines)
  local path = vim.fs.joinpath(root, name)
  vim.fn.writefile(lines, path)
  return path
end

local function disk_revision(path)
  local stat = assert(vim.uv.fs_stat(path))
  return {
    kind = "disk",
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    size = stat.size,
  }
end

T["patches only the expected scalar lexeme and does not save"] = function()
  local original = { "---", "status: 'old' # keep", "other: 1", "---", "body" }
  local path = write_note("Project.md", original)
  local result, err = edit.apply {
    path = path,
    property = "status",
    expected = "old",
    revision = disk_revision(path),
    input = "new value",
  }

  eq(nil, err)
  eq(true, result.changed)
  buffers[#buffers + 1] = result.bufnr
  eq(
    { "---", 'status: "new value" # keep', "other: 1", "---", "body" },
    vim.api.nvim_buf_get_lines(result.bufnr, 0, -1, false)
  )
  eq(true, vim.bo[result.bufnr].modified)
  eq(original, vim.fn.readfile(path))
end

for _, case in ipairs {
  { name = "existing", expected = 1 },
  { name = "declared existing", expected = 1, declared_type = "number" },
  { name = "declared missing", insert_missing = true, declared_type = "number" },
  { name = "inferred missing", insert_missing = true },
} do
  T["rejects non-finite " .. case.name .. " numeric edits"] = function()
    local original = { "---", case.insert_missing and "other: keep" or "amount: 1", "---" }
    local path = write_note("NonFinite.md", original)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    buffers[#buffers + 1] = bufnr
    local inputs = { "1e999", "-1e999" }
    if not case.insert_missing or case.declared_type then
      vim.list_extend(inputs, { "inf", "-inf", "nan" })
    end
    for _, input in ipairs(inputs) do
      local result, err = edit.apply {
        path = path,
        property = "amount",
        expected = case.expected,
        revision = disk_revision(path),
        input = input,
        insert_missing = case.insert_missing,
        declared_type = case.declared_type,
      }
      eq(nil, result)
      eq("expected a finite number", err)
      eq(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      eq(false, vim.bo[bufnr].modified)
      eq(original, vim.fn.readfile(path))
    end
  end
end

T["refuses scalar serialization that loses numeric precision"] = function()
  local original = { "---", "amount: 1", "---" }
  local path = write_note("Precision.md", original)
  local result, err = edit.apply {
    path = path,
    property = "amount",
    expected = 1,
    revision = disk_revision(path),
    input = "1.2345678901234567",
  }
  eq(nil, result)
  eq("the scalar cannot be represented safely by the current YAML parser", err)
  local bufnr = vim.fn.bufnr(path)
  buffers[#buffers + 1] = bufnr
  eq(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  eq(false, vim.bo[bufnr].modified)

  result, err = edit.apply {
    path = path,
    property = "amount",
    expected = 1,
    revision = disk_revision(path),
    input = "1.25e2",
  }
  eq(nil, err)
  eq(125, result.new_value)
  eq(125, require("obsidian.note").from_buffer(bufnr).metadata.amount)
  eq(original, vim.fn.readfile(path))
end

T["rejects overflowing list elements without changing the buffer"] = function()
  local original = { "---", "amounts: [1]", "---" }
  local path = write_note("ListOverflow.md", original)
  local result, err = edit.apply {
    path = path,
    property = "amounts",
    expected = { 1 },
    revision = disk_revision(path),
    input = "[1e999]",
  }
  eq(nil, result)
  eq("the list cannot be represented safely by the current YAML parser", err)
  local bufnr = vim.fn.bufnr(path)
  buffers[#buffers + 1] = bufnr
  eq(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  eq(false, vim.bo[bufnr].modified)
end

T["restricts edits to supported parsed Markdown note targets"] = function()
  local original = { "---", "status: old", "---", "body" }
  for _, name in ipairs { "Data.txt", "Definition.base" } do
    local path = write_note(name, original)
    local result, err = edit.apply {
      path = path,
      property = "status",
      expected = "old",
      revision = disk_revision(path),
      input = "active",
    }
    eq(nil, result)
    eq("the edit target is not a supported Markdown note", err)
    eq(original, vim.fn.readfile(path))
  end

  local path = vim.fs.joinpath(root, "Attachment.png")
  local original_bytes = "\137PNG\r\n\26\n\0\255binary"
  local file = assert(io.open(path, "wb"))
  file:write(original_bytes)
  file:close()
  local result, err = edit.apply {
    path = path,
    property = "status",
    expected = nil,
    revision = disk_revision(path),
    input = "active",
    insert_missing = true,
  }
  eq(nil, result)
  eq("the edit target is not a supported Markdown note", err)
  file = assert(io.open(path, "rb"))
  eq(original_bytes, file:read "*a")
  file:close()
end

T["rejects supported note paths outside the originating vault"] = function()
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  local path = vim.fs.joinpath(outside, "Outside.md")
  local original = { "---", "status: old", "---", "body" }
  vim.fn.writefile(original, path)
  local result, err = edit.apply {
    path = path,
    property = "status",
    expected = "old",
    revision = disk_revision(path),
    input = "active",
    vault = root,
  }
  eq(nil, result)
  eq("the edit target is outside the originating vault", err)
  eq(original, vim.fn.readfile(path))
  vim.fn.delete(outside, "rf")
end

T["edits every supported Markdown-like note extension"] = function()
  for _, extension in ipairs { "md", "markdown", "qmd" } do
    local original = { "---", "status: old", "---", "body" }
    local path = write_note("Project." .. extension, original)
    local result, err = edit.apply {
      path = path,
      property = "status",
      expected = "old",
      revision = disk_revision(path),
      input = "active",
    }
    eq(nil, err)
    eq(true, result.changed)
    buffers[#buffers + 1] = result.bufnr
    eq("status: active", vim.api.nvim_buf_get_lines(result.bufnr, 1, 2, false)[1])
    eq(original, vim.fn.readfile(path))
  end
end

T["preserves scalar types"] = function()
  local path = write_note("Typed.md", { "---", "priority: 1", "active: false", "---" })
  local priority = edit.apply {
    path = path,
    property = "note.priority",
    expected = 1,
    revision = disk_revision(path),
    input = "2.5",
  }
  buffers[#buffers + 1] = priority.bufnr
  eq("priority: 2.5", vim.api.nvim_buf_get_lines(priority.bufnr, 1, 2, false)[1])

  local result, err = edit.apply {
    path = path,
    property = "active",
    expected = false,
    revision = { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(priority.bufnr) },
    input = "true",
  }
  eq(nil, err)
  eq(true, result.new_value)
  eq("active: true", vim.api.nvim_buf_get_lines(result.bufnr, 2, 3, false)[1])
end

T["rejects stale revisions and mismatched expected values"] = function()
  local path = write_note("Stale.md", { "---", "status: old", "---", "body" })
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  buffers[#buffers + 1] = bufnr
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "changed" })

  local result, err = edit.apply {
    path = path,
    property = "status",
    expected = "old",
    revision = { kind = "buffer", changedtick = changedtick },
    input = "new",
  }
  eq(nil, result)
  eq("the note changed after this result was evaluated", err)

  result, err = edit.apply {
    path = path,
    property = "status",
    expected = "different",
    revision = { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(bufnr) },
    input = "new",
  }
  eq(nil, result)
  eq("the property value changed after this result was evaluated", err)
end

T["inserts a missing scalar before the frontmatter closer"] = function()
  local original = { "---", "# keep", "status: old", "---", "body" }
  local path = write_note("Insert.md", original)
  local result, err = edit.apply {
    path = path,
    property = "owner",
    expected = nil,
    revision = disk_revision(path),
    input = "Ada Lovelace",
    insert_missing = true,
  }

  eq(nil, err)
  eq(true, result.inserted)
  eq("Ada Lovelace", result.new_value)
  buffers[#buffers + 1] = result.bufnr
  eq(
    { "---", "# keep", "status: old", 'owner: "Ada Lovelace"', "---", "body" },
    vim.api.nvim_buf_get_lines(result.bufnr, 0, -1, false)
  )
  eq(original, vim.fn.readfile(path))
end

T["creates minimal frontmatter and infers scalar types"] = function()
  local original = { "# Note", "body" }
  local path = write_note("NoFrontmatter.md", original)
  local priority, err = edit.apply {
    path = path,
    property = "priority",
    expected = nil,
    revision = disk_revision(path),
    input = "2",
    insert_missing = true,
  }
  eq(nil, err)
  eq(2, priority.new_value)
  buffers[#buffers + 1] = priority.bufnr

  local active = edit.apply {
    path = path,
    property = "active",
    expected = nil,
    revision = { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(priority.bufnr) },
    input = "true",
    insert_missing = true,
  }
  eq(true, active.new_value)
  eq(
    { "---", "priority: 2", "active: true", "---", "", "# Note", "body" },
    vim.api.nvim_buf_get_lines(active.bufnr, 0, -1, false)
  )
  eq(original, vim.fn.readfile(path))
end

T["uses declared types instead of value-shape inference"] = function()
  local path = write_note("Declared.md", { "---", "label: 2026-01-02", 'active: "false"', "---" })
  local label, err = edit.apply {
    path = path,
    property = "label",
    expected = "2026-01-02",
    revision = disk_revision(path),
    input = "not a date",
    declared_type = "text",
  }
  eq(nil, err)
  buffers[#buffers + 1] = label.bufnr
  eq('label: "not a date"', vim.api.nvim_buf_get_lines(label.bufnr, 1, 2, false)[1])

  local active = edit.apply {
    path = path,
    property = "active",
    expected = "false",
    revision = { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(label.bufnr) },
    input = "true",
    declared_type = "checkbox",
  }
  eq(true, active.new_value)
  eq("active: true", vim.api.nvim_buf_get_lines(active.bufnr, 2, 3, false)[1])
end

T["refuses declared-type edits when metadata revisions change"] = function()
  local path = write_note("DeclaredRevision.md", { "---", "owners: [one]", "---" })
  local types_path = vim.fs.joinpath(root, ".obsidian", "types.json")
  vim.fn.writefile({ vim.json.encode { types = { owners = "multitext" } } }, types_path)
  local snapshot = property_types.get()
  local types_buf = vim.fn.bufadd(types_path)
  vim.fn.bufload(types_buf)
  buffers[#buffers + 1] = types_buf
  vim.api.nvim_buf_set_lines(types_buf, 0, -1, false, { vim.json.encode { types = { owners = "text" } } })

  local result, err = edit.apply {
    path = path,
    property = "owners",
    expected = { "one" },
    revision = disk_revision(path),
    input = "[two]",
    declared_type = "multitext",
    property_types_revision = snapshot.revision,
  }
  eq(nil, result)
  eq("property type metadata changed after this result was evaluated", err)
  eq({ "---", "owners: [one]", "---" }, vim.fn.readfile(path))
end

T["distinguishes declared dates from datetimes"] = function()
  local path = write_note("DateTypes.md", { "---", "due: 2026-01-02", "meeting: 2026-01-02T10:30:00", "---" })
  local result, err = edit.apply {
    path = path,
    property = "due",
    expected = "2026-01-02",
    revision = disk_revision(path),
    input = "2026-01-03T10:00:00",
    declared_type = "date",
  }
  eq(nil, result)
  eq("expected an ISO date", err)

  result, err = edit.apply {
    path = path,
    property = "meeting",
    expected = "2026-01-02T10:30:00",
    revision = disk_revision(path),
    input = "2026-01-03T11:45:00",
    declared_type = "datetime",
  }
  eq(nil, err)
  buffers[#buffers + 1] = result.bufnr
  eq("meeting: 2026-01-03T11:45:00", vim.api.nvim_buf_get_lines(result.bufnr, 2, 3, false)[1])
end

for _, declared in ipairs { "datetime", "inferred" } do
  T["edits ISO datetimes with zones and fractions using " .. declared .. " types"] = function()
    local current = "2026-11-15T03:04:05Z"
    for index, value in ipairs {
      "2026-11-16T03:04:05Z",
      "2026-11-16T03:04:05+05:30",
      "2026-11-16T03:04:05-07:00",
      "2026-11-16T03:04:05+0530",
      "2026-11-16T03:04:05-0700",
      "2026-11-16T03:04:05.123Z",
      "2026-11-16T03:04:05.123456-07:00",
      "2026-11-16T03:04Z",
      "2026-11-16 03:04:05",
      "2024-02-29T03:04",
    } do
      local path = write_note("Datetime" .. index .. ".md", { "---", "meeting: " .. current, "---" })
      local result, err = edit.apply {
        path = path,
        property = "meeting",
        expected = current,
        revision = disk_revision(path),
        input = value,
        declared_type = declared == "datetime" and declared or nil,
      }
      eq(nil, err)
      eq(value, result.new_value)
      buffers[#buffers + 1] = result.bufnr
      local note = require("obsidian.note").from_buffer(result.bufnr)
      eq(value, note.metadata.meeting)
      eq({ "---", "meeting: " .. current, "---" }, vim.fn.readfile(path))
    end
  end
end

T["rejects malformed ISO datetime components without changing the buffer"] = function()
  local original = { "---", "meeting: 2026-11-15T03:04:05Z", "---" }
  local path = write_note("InvalidDatetime.md", original)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  buffers[#buffers + 1] = bufnr
  for _, value in ipairs {
    "2026-11-16T03:041",
    "2026-11-16T03:04:5",
    "2026-11-16T03:04:",
    "2026-11-16T03:04:05.",
    "2026-11-16T03:04:05.Z",
    "2026-11-16T03:04.5Z",
    "2026-11-16T03:04:05+24:00",
    "2026-11-16T03:04:05+01:60",
    "2026-11-16T03:04:05+1:00",
    "2026-11-16T03:04:05Zjunk",
    "2026-11-16T24:04:05Z",
    "2026-11-16T03:60:05Z",
    "2026-11-16T03:04:60Z",
    "2026-02-29T03:04:05Z",
  } do
    local result, err = edit.apply {
      path = path,
      property = "meeting",
      expected = "2026-11-15T03:04:05Z",
      revision = disk_revision(path),
      input = value,
      declared_type = "datetime",
    }
    eq(nil, result)
    eq("expected an ISO datetime", err)
    eq(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    eq(false, vim.bo[bufnr].modified)
  end
end

T["inserts missing values using declared types"] = function()
  local path = write_note("DeclaredMissing.md", { "---", "status: active", "---" })
  local owners, err = edit.apply {
    path = path,
    property = "owners",
    expected = nil,
    revision = disk_revision(path),
    input = "[one, two]",
    insert_missing = true,
    declared_type = "multitext",
  }
  eq(nil, err)
  buffers[#buffers + 1] = owners.bufnr
  eq({ "one", "two" }, owners.new_value)
  eq("owners: [one, two]", vim.api.nvim_buf_get_lines(owners.bufnr, 2, 3, false)[1])

  local title = edit.apply {
    path = path,
    property = "title",
    expected = nil,
    revision = { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(owners.bufnr) },
    input = "true",
    insert_missing = true,
    declared_type = "text",
  }
  eq("true", title.new_value)
  eq('title: "true"', vim.api.nvim_buf_get_lines(title.bufnr, 3, 4, false)[1])
end

T["edits link and date scalars with type-aware validation"] = function()
  local path = write_note("TypedStrings.md", { "---", "project: '[[Old]]'", "due: 2026-01-02", "---" })
  local project, err = edit.apply {
    path = path,
    property = "project",
    expected = "[[Old]]",
    revision = disk_revision(path),
    input = "New",
  }
  eq(nil, err)
  buffers[#buffers + 1] = project.bufnr
  eq('project: "[[New]]"', vim.api.nvim_buf_get_lines(project.bufnr, 1, 2, false)[1])

  local result
  result, err = edit.apply {
    path = path,
    property = "due",
    expected = "2026-01-02",
    revision = { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(project.bufnr) },
    input = "2026-02-30",
  }
  eq(nil, result)
  eq("expected an ISO date or datetime", err)

  result, err = edit.apply {
    path = path,
    property = "due",
    expected = "2026-01-02",
    revision = { kind = "buffer", changedtick = vim.api.nvim_buf_get_changedtick(project.bufnr) },
    input = "2028-02-29",
  }
  eq(nil, err)
  eq("due: 2028-02-29", vim.api.nvim_buf_get_lines(result.bufnr, 2, 3, false)[1])
end

T["edits flow lists while preserving trailing comments"] = function()
  local path = write_note("FlowList.md", { "---", 'owners: [one, "two words"] # keep', "---" })
  local result, err = edit.apply {
    path = path,
    property = "owners",
    expected = { "one", "two words" },
    revision = disk_revision(path),
    input = '[three, "four words"]',
  }
  eq(nil, err)
  buffers[#buffers + 1] = result.bufnr
  eq('owners: [three, "four words"] # keep', vim.api.nvim_buf_get_lines(result.bufnr, 1, 2, false)[1])
end

T["round-trips flow punctuation in list edits and input defaults"] = function()
  local yaml = require "obsidian.yaml"
  local input = [=[ ["a,b", "a]b", "a[b", "a{b}", "a'b,c", 'a\b,c'] ]=]
  local values = yaml.loads({ "items: " .. input }).items
  eq(values, yaml.loads({ "items: " .. edit.input_default(values) }).items)
  for _, case in ipairs {
    { name = "Flow", source = "items: [old] # keep", expected = { "old" } },
    { name = "Scalar", source = "items: old # keep", expected = "old", declared_type = "multitext" },
    { name = "Missing", source = "other: keep", insert_missing = true, declared_type = "multitext" },
  } do
    local original = { "---", case.source, "---", "body" }
    local path = write_note(case.name .. ".md", original)
    local result, err = edit.apply {
      path = path,
      property = "items",
      expected = case.expected,
      revision = disk_revision(path),
      input = input,
      insert_missing = case.insert_missing,
      declared_type = case.declared_type,
    }
    eq(nil, err)
    buffers[#buffers + 1] = result.bufnr
    local note = require("obsidian.note").from_buffer(result.bufnr)
    eq(values, note.metadata.items)
    eq(values, result.new_value)
    eq(original, vim.fn.readfile(path))
  end
end

T["edits block lists without rewriting unrelated frontmatter"] = function()
  local original = { "---", "owners:", "  - one # item comment", "  - two", "other: keep", "---", "body" }
  local path = write_note("BlockList.md", original)
  local result, err = edit.apply {
    path = path,
    property = "owners",
    expected = { "one", "two" },
    revision = disk_revision(path),
    input = "[three, four, five]",
  }
  eq(nil, err)
  buffers[#buffers + 1] = result.bufnr
  eq(
    { "---", "owners:", "  - three", "  - four", "  - five", "other: keep", "---", "body" },
    vim.api.nvim_buf_get_lines(result.bufnr, 0, -1, false)
  )
  eq(original, vim.fn.readfile(path))
end

for _, case in ipairs {
  { name = "Unclosed", lines = { "---", "status: old" }, error = "frontmatter is not safely replaceable" },
  {
    name = "Invalid",
    lines = { "---", "status: old", "foo: 1", "  bad: 2", "---" },
    error = "frontmatter contains invalid YAML",
  },
} do
  for _, modified in ipairs { false, true } do
    T["refuses scalar edits in " .. case.name .. " frontmatter from " .. (modified and "buffers" or "disk")] = function()
      local path = write_note(case.name .. ".md", case.lines)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      buffers[#buffers + 1] = bufnr
      vim.bo[bufnr].modified = modified
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      local result, err = edit.apply {
        path = path,
        property = "status",
        expected = "old",
        revision = modified and { kind = "buffer", changedtick = tick } or disk_revision(path),
        input = "new",
      }
      eq(nil, result)
      eq(case.error, err)
      eq(case.lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      eq(case.lines, vim.fn.readfile(path))
      eq(modified, vim.bo[bufnr].modified)
      eq(tick, vim.api.nvim_buf_get_changedtick(bufnr))
    end
  end
end

for _, case in ipairs {
  { name = "Sequence", body = { "- first", "- second" } },
  { name = "FlowSequence", body = { "[first, second]" } },
  { name = "EmptySequence", body = { "[]" } },
  { name = "Scalar", body = { "text" } },
  { name = "Null", body = { "null" } },
  { name = "Mixed", body = { "- first", "status: old" } },
  { name = "EmptyMapping", body = { "{}" }, flow = true },
  { name = "FlowMapping", body = { "{status: old, other: keep}" }, flow = true },
} do
  for _, modified in ipairs { false, true } do
    T["refuses non-block mapping " .. case.name .. " from " .. (modified and "buffer" or "disk")] = function()
      local original = vim.list_extend({ "---" }, case.body)
      vim.list_extend(original, { "---", "body" })
      local path = write_note(case.name .. ".md", original)
      local bufnr = vim.fn.bufadd(path)
      vim.fn.bufload(bufnr)
      buffers[#buffers + 1] = bufnr
      vim.bo[bufnr].modified = modified
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      local result, err = edit.apply {
        path = path,
        property = "owner",
        revision = modified and { kind = "buffer", changedtick = tick } or disk_revision(path),
        input = "Ada",
        insert_missing = true,
      }
      eq(nil, result)
      eq(case.flow and "flow-style frontmatter mappings are read-only" or "frontmatter must be a block mapping", err)
      eq(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      eq(original, vim.fn.readfile(path))
      eq(modified, vim.bo[bufnr].modified)
      eq(tick, vim.api.nvim_buf_get_changedtick(bufnr))
    end
  end
end

T["populates empty and comment-only frontmatter safely"] = function()
  for index, body in ipairs { {}, { "# keep" } } do
    local original = vim.list_extend({ "---" }, body)
    vim.list_extend(original, { "---", "body" })
    local path = write_note("Empty" .. index .. ".md", original)
    local result, err = edit.apply {
      path = path,
      property = "owner",
      revision = disk_revision(path),
      input = "Ada",
      insert_missing = true,
    }
    eq(nil, err)
    buffers[#buffers + 1] = result.bufnr
    local expected = vim.list_extend({ "---" }, body)
    vim.list_extend(expected, { "owner: Ada", "---", "body" })
    eq(expected, vim.api.nvim_buf_get_lines(result.bufnr, 0, -1, false))
    eq(original, vim.fn.readfile(path))
  end
end

T["refuses unsafe missing-property insertions"] = function()
  local invalid = write_note("Invalid.md", { "---", "foo: 1", "  bad: 2", "---", "body" })
  local result, err = edit.apply {
    path = invalid,
    property = "owner",
    expected = nil,
    revision = disk_revision(invalid),
    input = "Ada",
    insert_missing = true,
  }
  eq(nil, result)
  eq("frontmatter contains invalid YAML", err)

  local plain = write_note("Plain.md", { "body" })
  result, err = edit.apply {
    path = plain,
    property = "unsafe:key",
    expected = nil,
    revision = disk_revision(plain),
    input = "value",
    insert_missing = true,
  }
  eq(nil, result)
  eq("the property name cannot be represented safely by the current YAML parser", err)

  result, err = edit.apply {
    path = plain,
    property = "tags",
    expected = nil,
    revision = disk_revision(plain),
    input = "one",
    insert_missing = true,
  }
  eq(nil, result)
  eq("id, aliases, and tags require dedicated editors", err)
end

T["keeps formula, file, and missing properties read-only"] = function()
  eq(nil, edit.property_key "formula.score")
  eq(nil, edit.property_key "file.name")

  local path = write_note("ReadOnly.md", { "---", "tags: [one, two]", "---" })
  local revision = disk_revision(path)
  local result, err = edit.apply {
    path = path,
    property = "tags",
    expected = { "one", "two" },
    revision = revision,
    input = "three",
  }
  eq(nil, result)
  eq("list input must use YAML flow syntax, for example [one, two]", err)

  result, err = edit.apply {
    path = path,
    property = "missing",
    expected = nil,
    revision = revision,
    input = "value",
  }
  eq(nil, result)
  eq("only existing top-level scalar properties are editable", err)
end

T["refuses disk revisions when a clean buffer still contains older content"] = function()
  local original = { "---", "status: old", "---", "old body" }
  local path = write_note("ExternallyChanged.md", original)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  buffers[#buffers + 1] = bufnr
  local updated = { "---", "status: old", "---", "new body from another editor" }
  vim.fn.writefile(updated, path)
  eq(false, vim.bo[bufnr].modified)

  local result, err = edit.apply {
    path = path,
    property = "status",
    expected = "old",
    revision = disk_revision(path),
    input = "active",
  }
  eq(nil, result)
  eq("the note buffer differs from disk; reload it before editing", err)
  eq(original, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  eq(false, vim.bo[bufnr].modified)
  eq(updated, vim.fn.readfile(path))
end

return T
