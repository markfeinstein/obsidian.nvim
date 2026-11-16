local types = require "obsidian.properties.types"
local types_edit = require "obsidian.properties.types_edit"

local eq = MiniTest.expect.equality
local root
local buffers

local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      types.clear()
      root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
      root = assert(vim.uv.fs_realpath(root))
      buffers = {}
      Obsidian = { dir = root, opts = { sync = { config_dir = ".obsidian" } } }
    end,
    post_case = function()
      types.clear()
      for _, bufnr in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      vim.fn.delete(root, "rf")
    end,
  },
}

local function path()
  return vim.fs.joinpath(root, ".obsidian", "types.json")
end

local function write_bytes(contents)
  local file = assert(io.open(path(), "wb"))
  assert(file:write(contents))
  file:close()
end

local function read_bytes()
  local file = assert(io.open(path(), "rb"))
  local contents = assert(file:read "*a")
  file:close()
  return contents
end

local function track(result)
  if result and result.buf then
    buffers[#buffers + 1] = result.buf
  end
  return result
end

T["patches only the selected JSON type value and preserves unknown data"] = function()
  local source = table.concat({
    "{",
    '  "version": 1,',
    '  "types": {',
    '    "status": "text",',
    '    "plugin-owned": "custom"',
    "  },",
    '  "other": { "keep": true }',
    "}",
    "",
  }, "\n")
  local patched, inserted = types_edit.patch_source(source, "status", "number")
  eq(false, inserted)
  eq(source:gsub('"status": "text"', '"status": "number"'), patched)

  local added, was_inserted = types_edit.patch_source(source, "due", "date")
  eq(true, was_inserted)
  eq(true, added:find('    "due": "date"', 1, true) ~= nil)
  eq(true, added:find('"plugin-owned": "custom"', 1, true) ~= nil)
  eq(true, added:find('"other": { "keep": true }', 1, true) ~= nil)

  local duplicate, duplicate_err =
    types_edit.patch_source('{"types":{"status":"text","status":"number"}}', "status", "date")
  eq(nil, duplicate)
  eq("duplicate JSON object key: status", duplicate_err)
end

T["edits a guarded metadata buffer without writing the file"] = function()
  local original = '{\n  "types": { "status": "text" },\n  "other": 1\n}\n'
  vim.fn.writefile(vim.split(original:sub(1, -2), "\n", { plain = true }), path())
  local snapshot = types.get()
  local mismatch, mismatch_err = types_edit.apply {
    property = "status",
    type_name = "number",
    expected = "date",
    revision = snapshot.revision,
  }
  eq(nil, mismatch)
  eq("declared property type no longer matches the expected value", mismatch_err)

  local result, err = types_edit.apply {
    property = "status",
    type_name = "number",
    expected = "text",
    revision = snapshot.revision,
  }
  assert(result, err)
  track(result)

  eq(true, result.changed)
  eq(false, result.inserted)
  eq(true, vim.bo[result.buf].modified)
  eq("number", types.get().types.status)
  eq(vim.split(original:sub(1, -2), "\n", { plain = true }), vim.fn.readfile(path()))

  local refused, conflict = types_edit.apply {
    property = "status",
    type_name = "date",
    expected = "text",
    revision = snapshot.revision,
  }
  eq(nil, refused)
  eq("property type metadata changed since the view was evaluated", conflict)

  local latest = types.get()
  vim.bo[result.buf].readonly = true
  local readonly, readonly_err = types_edit.apply {
    property = "status",
    type_name = "date",
    expected = "number",
    revision = latest.revision,
  }
  eq(nil, readonly)
  eq("property type metadata buffer is read-only", readonly_err)
  vim.bo[result.buf].readonly = false
end

T["patches fresh disk content when a loaded buffer is unmodified"] = function()
  vim.fn.writefile({ '{"types":{"status":"text"},"other":1}' }, path())
  local bufnr = vim.fn.bufadd(path())
  vim.fn.bufload(bufnr)
  buffers[#buffers + 1] = bufnr
  vim.fn.writefile({ '{"types":{"status":"text"},"other":2}' }, path())

  local snapshot = types.get()
  eq("disk", snapshot.revision.kind)
  local result, err = types_edit.apply {
    property = "status",
    type_name = "number",
    expected = "text",
    revision = snapshot.revision,
  }
  assert(result, err)

  eq(true, vim.bo[bufnr].modified)
  eq(true, table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find('"other":2', 1, true) ~= nil)
  eq({ '{"types":{"status":"text"},"other":2}' }, vim.fn.readfile(path()))
end

T["writes CRLF metadata without doubled carriage returns"] = function()
  local original = '{\r\n  "types": { "status": "text" },\r\n  "other": 1\r\n}\r\n'
  write_bytes(original)
  local snapshot = types.get()
  local result, err = types_edit.apply {
    property = "status",
    type_name = "number",
    expected = "text",
    revision = snapshot.revision,
  }
  assert(result, err)
  track(result)

  eq("dos", vim.bo[result.buf].fileformat)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(result.buf, 0, -1, false)) do
    eq(nil, line:find("\r", 1, true))
  end
  vim.api.nvim_buf_call(result.buf, function()
    vim.cmd.write()
  end)

  local expected = original:gsub('"status": "text"', '"status": "number"')
  local written = read_bytes()
  eq(expected, written)
  eq(nil, written:find("\r\r\n", 1, true))
end

T["creates missing metadata only in an unsaved buffer"] = function()
  local snapshot = types.get()
  eq("missing", snapshot.status)
  local result, err = types_edit.apply {
    property = "due",
    type_name = "date",
    expected = nil,
    revision = snapshot.revision,
  }
  assert(result, err)
  track(result)

  eq(true, result.inserted)
  eq(true, vim.bo[result.buf].modified)
  eq(0, vim.fn.filereadable(path()))
  eq("date", types.get().types.due)
end

return T
