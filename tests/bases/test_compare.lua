local compare = require "obsidian.bases.compare"
local compat = require "obsidian.bases.compat"
local property_types = require "obsidian.properties.types"

local eq = MiniTest.expect.equality
local root
local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      property_types.clear()
      root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
      root = assert(vim.uv.fs_realpath(root))
      Obsidian = Obsidian or {}
      Obsidian.dir = root
      Obsidian.opts = Obsidian.opts or {}
      Obsidian.opts.sync = { config_dir = ".obsidian" }
    end,
    post_case = function()
      property_types.clear()
      vim.fn.delete(root, "rf")
    end,
  },
}

local definition = {
  path = "/vault/Projects.base",
  view_name = "Active Projects",
}

local function revision(path)
  local stat = assert(vim.uv.fs_stat(path))
  return table.concat({ stat.mtime.sec, stat.mtime.nsec, stat.size }, ":")
end

local function saved_definition()
  local path = vim.fs.joinpath(root, "Projects.base")
  vim.fn.writefile({ "views:", "  - type: table", "    name: Active Projects" }, path)
  return {
    path = path,
    identity = path,
    revision = revision(path),
    view_name = "Active Projects",
  }
end

local function comparison_result(rows, overrides)
  local value = {
    rows = rows or {},
    comparison_snapshot = {
      definition_revision_kind = "disk",
      property_types_revision = vim.deepcopy(property_types.get().revision),
      unsaved_note_overlays = false,
      context_dependent = false,
      embedded = false,
    },
  }
  for key, item in pairs(overrides or {}) do
    value.comparison_snapshot[key] = item
  end
  return value
end

T["builds the documented explicit base query command"] = function()
  eq({
    "/usr/bin/obsidian",
    "base:query",
    "path=Projects.base",
    "view=Active Projects",
    "format=json",
  }, compare.command(definition, { cmd = "/usr/bin/obsidian", vault = "/vault" }))
  local command, err = compare.command({ view_name = "Inline" }, { cmd = "/usr/bin/obsidian", vault = "/vault" })
  eq(nil, command)
  eq("CLI comparison requires a saved .base file", err)
end

T["refuses strict CLI comparisons after a Base escapes the real vault"] = function()
  local vault_root = vim.fn.tempname()
  local outside = vim.fn.tempname() .. ".base"
  vim.fn.mkdir(vault_root, "p")
  vim.fn.writefile({ "views: []" }, outside)
  vault_root = assert(vim.uv.fs_realpath(vault_root), "failed to resolve test vault")
  outside = assert(vim.uv.fs_realpath(outside), "failed to resolve outside Base")
  local linked = vim.fs.joinpath(vault_root, "Linked.base")
  assert(vim.uv.fs_symlink(outside, linked), "failed to create test symlink")

  local command, err = compare.command({ path = linked, view_name = "View" }, {
    cmd = "/usr/bin/obsidian",
    vault = vault_root,
    strict_vault = true,
  })
  eq(nil, command)
  eq("CLI comparison Base must remain inside the originating vault", err)

  vim.fn.delete(vault_root, "rf")
  vim.fn.delete(outside)
end

T["parses supported CLI path shapes and rejects opaque JSON"] = function()
  local parsed, parsed_err = compare.parse(vim.json.encode {
    { file = { path = "C.md" } },
    { path = "A.md" },
    "B.md",
    { path = "A.md" },
  })
  eq({ "A.md", "B.md", "C.md" }, parsed)
  eq(nil, parsed_err)
  local paths, err = compare.parse(vim.json.encode { { name = "A" } })
  eq(nil, paths)
  eq("Obsidian CLI JSON did not expose result paths", err)
end

T["reports unavailable process support without throwing"] = function()
  local original = compat.system
  compat.system = function()
    return nil, "vim.system unavailable"
  end
  local current_definition = saved_definition()
  local snapshot = comparison_result()
  snapshot.comparison_snapshot.definition_revision = current_definition.revision
  local result
  compare.run(current_definition, snapshot, function(value)
    result = value
  end, { cmd = "/usr/bin/obsidian", vault = root })
  compat.system = original
  eq("unavailable", result.status)
  eq("vim.system unavailable", result.summary)
end

T["reports path matches and differences without replacing local results"] = function()
  local callbacks = {}
  local outputs = {
    { code = 0, stdout = vim.json.encode { { path = "A.md" }, { path = "B.md" } }, stderr = "" },
    { code = 0, stdout = vim.json.encode { { path = "B.md" }, { path = "C.md" } }, stderr = "" },
  }
  local function system(args, opts, callback)
    eq("base:query", args[2])
    eq(123, opts.timeout)
    eq(root, opts.cwd)
    callback(table.remove(outputs, 1))
    return { kill = function() end }
  end
  local current_definition = saved_definition()
  local result = comparison_result { { file = { path = "A.md" } }, { file = { path = "B.md" } } }
  result.comparison_snapshot.definition_revision = current_definition.revision
  compare.run(current_definition, result, function(value)
    callbacks[#callbacks + 1] = value
  end, { cmd = "/usr/bin/obsidian", vault = root, timeout = 123, system = system })
  compare.run(current_definition, result, function(value)
    callbacks[#callbacks + 1] = value
  end, { cmd = "/usr/bin/obsidian", vault = root, timeout = 123, system = system })
  vim.wait(1000, function()
    return #callbacks == 2
  end)

  eq("match", callbacks[1].status)
  eq("matches Obsidian CLI (2 rows)", callbacks[1].summary)
  eq("different", callbacks[2].status)
  eq({ "A.md" }, callbacks[2].diagnostics.only_local)
  eq({ "C.md" }, callbacks[2].diagnostics.only_cli)
  eq(2, #result.rows)
end

T["refuses stale Base revisions before invoking the CLI"] = function()
  local current_definition = saved_definition()
  local result = comparison_result()
  result.comparison_snapshot.definition_revision = current_definition.revision
  vim.fn.writefile(
    { "views:", "  - type: table", "    name: Changed", "    order: [file.name]" },
    current_definition.path
  )
  local invoked = false
  local comparison
  compare.run(current_definition, result, function(value)
    comparison = value
  end, {
    cmd = "/usr/bin/obsidian",
    vault = root,
    system = function()
      invoked = true
    end,
  })
  eq(false, invoked)
  eq("non_comparable", comparison.status)
  eq(
    "not comparable with Obsidian CLI: the saved .base file changed after the local result was evaluated",
    comparison.summary
  )
end

T["classifies overlay and context-dependent snapshots as non-comparable"] = function()
  local current_definition = saved_definition()
  local cases = {
    {
      overrides = { unsaved_note_overlays = true },
      message = "the local result includes unsaved note overlays",
    },
    {
      overrides = { property_types_revision = { kind = "buffer", changedtick = 7 } },
      message = "the local result includes unsaved property type metadata",
    },
    {
      overrides = { context_dependent = true },
      message = "the local result depends on its embedding note context",
    },
  }
  for _, case in ipairs(cases) do
    local result = comparison_result(nil, case.overrides)
    result.comparison_snapshot.definition_revision = current_definition.revision
    local comparable, reason = compare.comparability(current_definition, result)
    eq(false, comparable)
    eq(case.message, reason)
  end
end

return T
