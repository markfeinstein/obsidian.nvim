local files = require "obsidian.index.files"
local watchfiles = require "obsidian.lsp.watchfiles"

local eq = MiniTest.expect.equality
local root
local outside
local original_build_row = files._build_row

local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      files.clear()
      root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
      vim.fn.mkdir(vim.fs.joinpath(root, ".git"), "p")
      root = assert(vim.uv.fs_realpath(root))
      outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")
      outside = assert(vim.uv.fs_realpath(outside))
      Obsidian = {
        dir = root,
        opts = {
          sync = { config_dir = ".obsidian" },
          file = { ignore_filters = { "ignored/**" } },
        },
      }
    end,
    post_case = function()
      files._build_row = original_build_row
      files.clear()
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

local function get()
  local result, failure, completed
  files.get(function(rows, err)
    result, failure, completed = rows, err, true
  end)
  assert(
    vim.wait(5000, function()
      return completed
    end),
    "timed out waiting for all-files index"
  )
  assert(result, failure)
  return result
end

T["builds a cold index asynchronously and yields while parsing"] = function()
  for i = 1, 20 do
    write(("Note-%02d.md"):format(i), { "---", "index: " .. i, "---" })
  end

  local builds = 0
  local builds_at_yield
  files._build_row = function(...)
    builds = builds + 1
    if builds == 1 then
      vim.schedule(function()
        builds_at_yield = builds
      end)
    end
    local deadline = vim.uv.hrtime() + (2 * 1000 * 1000)
    local spin = 0
    while vim.uv.hrtime() < deadline do
      spin = spin + 1
    end
    assert(spin > 0, "test delay did not run")
    return original_build_row(...)
  end

  local result, failure, completed
  files.get(function(rows, err)
    result, failure, completed = rows, err, true
  end)
  eq(nil, completed)
  assert(
    vim.wait(5000, function()
      return completed
    end),
    "timed out waiting for asynchronous all-files index"
  )
  assert(result, failure)
  eq(20, vim.tbl_count(result))
  assert(builds_at_yield and builds_at_yield < builds, "all rows were parsed in one event-loop turn")
end

T["cancels an asynchronous cold build when cleared"] = function()
  write("Note.md", { "# Note" })
  local calls = 0
  local failure
  files.get(function(_, err)
    calls = calls + 1
    failure = err
  end)

  files.clear()
  eq(1, calls)
  eq("vault index cleared", failure)
  vim.wait(20, function()
    return false
  end)
  eq(1, calls)
  eq(nil, files.peek())
end

T["restarts a pending scan without failing shared waiters"] = function()
  local note = write("Note.md", { "---", "status: old", "---" })
  local calls = 0
  local results = {}
  local function collect(rows, err)
    eq(nil, err)
    calls = calls + 1
    results[#results + 1] = rows
  end
  files.get(collect)
  files.get(collect)
  write("Note.md", { "---", "status: new", "---" })
  files.invalidate()
  require("tests.helpers").wait(function()
    return calls == 2
  end, { desc = "shared waiters after index invalidation" })
  eq(2, #results)
  for _, rows in ipairs(results) do
    eq("new", rows[note].properties.status)
  end
end

T["indexes arbitrary files and preserves complete Markdown properties"] = function()
  local note = write("Note.md", {
    "---",
    "nested:",
    "  child: value",
    "items:",
    "  - [one, two]",
    "empty: []",
    "empty_object: {}",
    "---",
    "# Note",
  })
  local text = write("data.txt", { "data" })
  local image = write("image.bin", { "binary" })
  local base = write("Projects.base", { "views: []" })
  write(".obsidian/types.json", { '{"types":{}}' })
  write(".git/config", { "internal" })
  write("ignored/secret.dat", { "ignored" })

  local rows = get()
  eq(4, vim.tbl_count(rows))
  eq("note", rows[note].kind)
  eq({ child = "value" }, rows[note].properties.nested)
  eq({ { "one", "two" } }, rows[note].properties.items)
  eq({}, rows[note].properties.empty)
  eq(true, vim.islist(rows[note].properties.empty))
  eq("[]", vim.json.encode(rows[note].properties.empty))
  eq({}, rows[note].properties.empty_object)
  eq(false, vim.islist(rows[note].properties.empty_object))
  eq("{}", vim.json.encode(rows[note].properties.empty_object))
  eq("file", rows[text].kind)
  eq("txt", rows[text].extension)
  eq("file", rows[image].kind)
  eq("base", rows[base].extension)
end

T["keeps in-vault file symlinks and rejects symlinks outside the real vault"] = function()
  local inside = write("Inside.md", { "---", "scope: inside", "---" })
  local inside_link = vim.fs.joinpath(root, "Inside link.md")
  assert(vim.uv.fs_symlink(inside, inside_link))

  local outside_note = vim.fs.joinpath(outside, "Outside.md")
  vim.fn.writefile({ "---", "scope: outside", "---" }, outside_note)
  local outside_link = vim.fs.joinpath(root, "Outside link.md")
  assert(vim.uv.fs_symlink(outside_note, outside_link))

  local rows = get()
  eq("inside", rows[inside].properties.scope)
  eq("inside", rows[inside_link].properties.scope)
  eq(nil, rows[outside_link])
end

T["excludes configured nested metadata directories"] = function()
  Obsidian.opts.sync.config_dir = ".config/obsidian"
  local note = write("Note.md", { "# Note" })
  write(".config/obsidian/types.json", { '{"types":{}}' })
  write(".config/obsidian/plugins/example.js", { "internal" })

  local rows = get()
  eq(1, vim.tbl_count(rows))
  eq("note", rows[note].kind)
end

T["updates ready rows from shared watched-file events"] = function()
  local note = write("Note.md", { "---", "status: old", "---" })
  local rows = get()
  eq("old", rows[note].properties.status)

  local attachment = write("archive.custom", { "one" })
  watchfiles.handle { { path = attachment, type = vim.lsp.protocol.FileChangeType.Created } }
  eq("custom", files.peek()[attachment].extension)

  vim.fn.writefile({ "---", "status: new", "---" }, note)
  watchfiles.handle { { path = note, type = vim.lsp.protocol.FileChangeType.Changed } }
  eq("new", files.peek()[note].properties.status)

  vim.fn.delete(attachment)
  watchfiles.handle { { path = attachment, type = vim.lsp.protocol.FileChangeType.Deleted } }
  eq(nil, files.peek()[attachment])
end

T["handles renames and ignored destinations"] = function()
  local old_path = write("old.unknown", { "one" })
  get()
  local new_path = vim.fs.joinpath(root, "new.unknown")
  vim.uv.fs_rename(old_path, new_path)
  watchfiles.handle { { old_path = old_path, new_path = new_path, type = "renamed" } }
  eq(nil, files.peek()[old_path])
  eq("unknown", files.peek()[new_path].extension)

  local ignored = vim.fs.joinpath(root, "ignored", "new.unknown")
  vim.fn.mkdir(vim.fs.dirname(ignored), "p")
  vim.uv.fs_rename(new_path, ignored)
  watchfiles.handle { { old_path = new_path, new_path = ignored, type = "renamed" } }
  eq(nil, files.peek()[new_path])
  eq(nil, files.peek()[ignored])
end

for _, paired_events in ipairs { false, true } do
  T["reconciles directory moves with " .. (paired_events and "delete/create" or "rename") .. " events"] = function()
    local old_note = write("Before/Nested/Note.md", { "---", "status: current", "---" })
    local old_attachment = write("Before/image.png", { "image" })
    local unaffected = write("Before-other.md", { "body" })
    get()
    local before, after = vim.fs.joinpath(root, "Before"), vim.fs.joinpath(root, "After")
    assert(vim.uv.fs_rename(before, after))
    if paired_events then
      watchfiles.handle {
        { path = before, type = vim.lsp.protocol.FileChangeType.Deleted },
        { path = after, type = vim.lsp.protocol.FileChangeType.Created },
      }
    else
      watchfiles.handle { { old_path = before, new_path = after, type = "renamed" } }
    end
    eq(nil, files.peek())
    local rows = get()
    eq(nil, rows[old_note])
    eq(nil, rows[old_attachment])
    eq("current", rows[vim.fs.joinpath(after, "Nested", "Note.md")].properties.status)
    eq("png", rows[vim.fs.joinpath(after, "image.png")].extension)
    eq("note", rows[unaffected].kind)
  end
end

T["reconciles imported and deleted directory subtrees"] = function()
  local external_note = vim.fs.joinpath(outside, "Imported.md")
  vim.fn.writefile({ "body" }, external_note)
  get()
  local imported = vim.fs.joinpath(root, "Imported")
  assert(vim.uv.fs_rename(outside, imported))
  watchfiles.handle { { path = imported, type = "created" } }
  local rows = get()
  local note = vim.fs.joinpath(imported, "Imported.md")
  eq("note", rows[note].kind)

  assert(vim.uv.fs_unlink(note))
  assert(vim.uv.fs_rmdir(imported))
  watchfiles.handle { { path = imported, type = "deleted" } }
  eq({}, get())
end

T["does not invalidate for excluded directory events"] = function()
  write("Note.md", { "body" })
  get()
  for _, directory in ipairs { ".obsidian", "ignored/subdirectory" } do
    local path = vim.fs.joinpath(root, directory)
    vim.fn.mkdir(path, "p")
    watchfiles.handle { { path = path, type = "created" } }
    eq(true, files.peek() ~= nil)
  end
end

return T
