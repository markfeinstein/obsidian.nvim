local property_types = require "obsidian.properties.types"
local watchfiles = require "obsidian.lsp.watchfiles"

local eq = MiniTest.expect.equality
local root
local outside
local buffers

local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      property_types.clear()
      root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
      root = assert(vim.uv.fs_realpath(root))
      outside = vim.fn.tempname()
      vim.fn.mkdir(outside, "p")
      outside = assert(vim.uv.fs_realpath(outside))
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
      vim.fn.delete(outside, "rf")
    end,
  },
}

local function path()
  return vim.fs.joinpath(root, ".obsidian", "types.json")
end

local function write_types(types)
  vim.fn.writefile({ vim.json.encode { types = types } }, path())
end

T["represents missing metadata explicitly"] = function()
  local snapshot = property_types.get()
  eq("missing", snapshot.status)
  eq({}, snapshot.types)
  eq(path(), snapshot.path)
end

T["normalizes known types and preserves unknown declarations"] = function()
  write_types {
    title = "text",
    owners = "multitext",
    priority = "number",
    active = "checkbox",
    due = "date",
    meeting = "datetime",
    score = "plugin:rating",
  }
  local snapshot = property_types.get()
  eq("current", snapshot.status)
  eq("string", snapshot.families.title)
  eq("list", snapshot.families.owners)
  eq("number", snapshot.families.priority)
  eq("boolean", snapshot.families.active)
  eq("date", snapshot.families.due)
  eq("datetime", snapshot.families.meeting)
  eq("plugin:rating", snapshot.unknown.score)
  eq("date", snapshot.evaluator_types.meeting)
  eq({ "list", "multitext" }, { property_types.type_for("note.owners", snapshot) })
end

T["reports invalid metadata without partial interpretation"] = function()
  vim.fn.writefile({ "{" }, path())
  local snapshot = property_types.get()
  eq("invalid", snapshot.status)
  eq({}, snapshot.types)
  eq("property type metadata contains invalid JSON", snapshot.diagnostic)
end

T["prefers disk changes over an unmodified loaded buffer"] = function()
  write_types { due = "date" }
  local bufnr = vim.fn.bufadd(path())
  vim.fn.bufload(bufnr)
  buffers[#buffers + 1] = bufnr

  write_types { due = "text" }
  watchfiles.handle { { path = path(), type = vim.lsp.protocol.FileChangeType.Changed } }
  local snapshot = property_types.get()
  eq("disk", snapshot.revision.kind)
  eq("string", snapshot.families.due)
end

T["uses modified buffer revisions and watched-file invalidation"] = function()
  write_types { due = "date" }
  local first = property_types.get()
  local bufnr = vim.fn.bufadd(path())
  vim.fn.bufload(bufnr)
  buffers[#buffers + 1] = bufnr
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { vim.json.encode { types = { due = "text" } } })

  local modified = property_types.get()
  eq("buffer", modified.revision.kind)
  eq("string", modified.families.due)
  eq(true, modified.generation > first.generation)

  watchfiles.handle { { path = path(), type = vim.lsp.protocol.FileChangeType.Changed } }
  local invalidated = property_types.get()
  eq(true, invalidated.generation > modified.generation)
end

T["rejects property metadata symlinked outside the real vault"] = function()
  local external = vim.fs.joinpath(outside, "types.json")
  vim.fn.writefile({ vim.json.encode { types = { secret = "text" } } }, external)
  assert(vim.uv.fs_symlink(external, path()))

  local snapshot = property_types.get()
  eq("invalid", snapshot.status)
  eq({}, snapshot.types)
  eq("property type metadata must remain inside the vault", snapshot.diagnostic)
end

T["supports configured metadata directories"] = function()
  vim.fn.mkdir(vim.fs.joinpath(root, ".config"), "p")
  local custom = vim.fs.joinpath(root, ".config", "types.json")
  vim.fn.writefile({ vim.json.encode { types = { active = "checkbox" } } }, custom)
  local snapshot = property_types.get { config_dir = ".config" }
  eq(custom, snapshot.path)
  eq("boolean", snapshot.families.active)
end

return T
