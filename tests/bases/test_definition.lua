local definition = require "obsidian.bases.definition"
local resolver = require "obsidian.bases.resolver"
local fs_util = require "obsidian.util.fs"
local Path = require "obsidian.path"

local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["parses and selects named views"] = function()
  local parsed, err = definition.parse({
    [[filters: 'status != "done"']],
    "views:",
    "  - type: table",
    "    name: Active",
    "    order: [file.name, status]",
    "  - type: list",
    "    name: Later",
    "    customSetting: keep-me",
  }, { path = "/vault/Projects.base", view = "Later", revision = 7 })

  eq(nil, err)
  eq("Later", parsed.view_name)
  eq(2, parsed.view_index)
  eq("list", parsed.view.type)
  eq("keep-me", parsed.view.customSetting)
  eq("/vault/Projects.base", parsed.identity)
  eq(7, parsed.revision)
end

T["rejects invalid YAML and missing views"] = function()
  local parsed, err = definition.parse { "views: [" }
  eq(nil, parsed)
  eq(true, vim.startswith(err, "invalid Base definition:"))

  parsed, err = definition.parse { "filters: status" }
  eq(nil, parsed)
  eq("invalid Base definition: views must be a non-empty list", err)
end

T["reports a missing selected view"] = function()
  local parsed, err = definition.parse({ "views:", "  - name: Existing", "    type: table" }, { view = "Missing" })
  eq(nil, parsed)
  eq('invalid Base definition: view "Missing" was not found', err)
end

T["prefers disk changes over an unmodified loaded buffer"] = function()
  local path = tostring(Path.temp { suffix = ".base" })
  vim.fn.writefile({ "views:", "  - name: Loaded", "    type: table" }, path)
  path = assert(vim.uv.fs_realpath(path))
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)

  vim.fn.writefile({ "views:", "  - name: Disk", "    type: table" }, path)
  local disk, disk_err = resolver.load(path)
  assert(disk, disk_err)
  eq("Disk", disk.view_name)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "views:", "  - name: Unsaved", "    type: table" })
  vim.bo[bufnr].modified = true
  local unsaved, unsaved_err = resolver.load(path)
  assert(unsaved, unsaved_err)
  eq("Unsaved", unsaved.view_name)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(path)
end

T["resolves Base files only inside the originating real vault"] = function()
  local original = Obsidian
  local root = vim.fn.tempname()
  local outside = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, ".obsidian"), "p")
  vim.fn.mkdir(outside, "p")
  root = assert(vim.uv.fs_realpath(root))
  outside = assert(vim.uv.fs_realpath(outside))
  Obsidian = {
    dir = root,
    opts = { sync = { config_dir = ".obsidian" }, file = { ignore_filters = {} } },
  }

  local source_path = vim.fs.joinpath(root, "Notes", "Context.md")
  vim.fn.mkdir(vim.fs.dirname(source_path), "p")
  vim.fn.writefile({ "context" }, source_path)
  local inside = vim.fs.joinpath(root, "Inside.base")
  vim.fn.writefile({ "views:", "  - name: Inside" }, inside)
  local inside_link = vim.fs.joinpath(root, "Inside link.base")
  assert(vim.uv.fs_symlink(inside, inside_link))
  local outside_base = vim.fs.joinpath(outside, "Outside.base")
  vim.fn.writefile({ "views:", "  - name: Outside" }, outside_base)
  local outside_link = vim.fs.joinpath(root, "Outside link.base")
  assert(vim.uv.fs_symlink(outside_base, outside_link))

  local spec, err = resolver.resolve(inside_link, { source_path = source_path })
  eq(nil, err)
  eq(inside_link, spec.path)
  vim.fn.delete(inside_link)
  assert(vim.uv.fs_symlink(outside_base, inside_link))
  local escaped, load_err = spec.load()
  eq(nil, escaped)
  eq(true, load_err:find("outside the vault", 1, true) ~= nil)

  spec, err = resolver.resolve(outside_base, { source_path = source_path })
  eq(nil, spec)
  eq(true, err:find("outside the vault", 1, true) ~= nil)

  local relative_escape = fs_util.relpath(vim.fs.dirname(source_path), outside_base)
  spec, err = resolver.resolve(relative_escape, { source_path = source_path })
  eq(nil, spec)
  eq(true, err:find("outside the vault", 1, true) ~= nil)

  spec, err = resolver.resolve(outside_link, { source_path = source_path })
  eq(nil, spec)
  eq(true, err:find("outside the vault", 1, true) ~= nil)

  Obsidian = original
  vim.fn.delete(root, "rf")
  vim.fn.delete(outside, "rf")
end

T["loads a base file with a stat-derived revision"] = function()
  local path = Path.temp { suffix = ".base" }
  vim.fn.writefile({ "views:", "  - name: Table", "    type: table" }, tostring(path))
  local parsed, err = definition.from_file(tostring(path))
  eq(nil, err)
  eq(tostring(path), parsed.path)
  eq("string", type(parsed.revision))
  vim.fn.delete(tostring(path))
end

local root, outside, original
local function base_file(relative, directory)
  local path = vim.fs.joinpath(directory or root, relative)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "views:", "  - name: Active", "    type: table" }, path)
  return path
end

T["shortest targets"] = MiniTest.new_set {
  hooks = {
    pre_case = function()
      original = Obsidian
      root, outside = vim.fn.tempname(), vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, "Notes"), "p")
      vim.fn.mkdir(outside, "p")
      root, outside = assert(vim.uv.fs_realpath(root)), assert(vim.uv.fs_realpath(outside))
      Obsidian = {
        dir = root,
        opts = { sync = { config_dir = ".obsidian" }, file = { ignore_filters = { "private/**" } } },
      }
    end,
    post_case = function()
      Obsidian = original
      vim.fn.delete(root, "rf")
      vim.fn.delete(outside, "rf")
    end,
  },
}

T["shortest targets"]["resolve unique filename and directory suffixes with named views"] = function()
  local path = base_file "Area/Bases/My Projects.base"
  for _, target in ipairs { "My Projects.base", "my projects.base", "Bases/My%20Projects.base" } do
    local spec, err = resolver.resolve(target .. "#Active", { source_path = root .. "/Notes/Home.md" })
    eq(nil, err)
    eq(path, spec.path)
    eq("Active", spec.load().view_name)
  end
end

T["shortest targets"]["reject ambiguity but preserve exact local and root precedence"] = function()
  base_file "Area/Bases/Projects.base"
  base_file "Other/Projects.base"
  local source = root .. "/Notes/Home.md"
  local spec, err = resolver.resolve("Projects.base", { source_path = source })
  eq(nil, spec)
  eq(true, err:find("ambiguous", 1, true) ~= nil)
  local exact = base_file "Projects.base"
  eq(exact, resolver.resolve("Projects.base", { source_path = source }).path)
  local nearby = base_file "Notes/Projects.base"
  eq(nearby, resolver.resolve("Projects.base", { source_path = source }).path)
end

T["shortest targets"]["exclude ignored internal and outside-real-vault fallback matches"] = function()
  local allowed = base_file "Area/Projects.base"
  base_file "private/Projects.base"
  base_file ".obsidian/Projects.base"
  base_file ".git/Projects.base"
  local external = base_file("Projects.base", outside)
  vim.fn.mkdir(root .. "/Escape", "p")
  assert(vim.uv.fs_symlink(external, root .. "/Escape/Projects.base"))
  local spec, err = resolver.resolve("Projects.base", { source_path = root .. "/Notes/Home.md" })
  eq(nil, err)
  eq(allowed, spec.path)
  vim.fn.delete(allowed)
  spec, err = resolver.resolve("Projects.base", { source_path = root .. "/Notes/Home.md" })
  eq(nil, spec)
  eq(true, err:find("not found", 1, true) ~= nil)
end

T["shortest targets"]["do not redirect explicit relative or absolute targets"] = function()
  base_file "Area/Projects.base"
  base_file "Projects.base"
  for _, target in ipairs { "./Projects.base", "../Missing/Projects.base", root .. "/Missing/Projects.base" } do
    local spec = resolver.resolve(target, { source_path = root .. "/Notes/Home.md" })
    eq(nil, spec)
  end
  -- Both direct commands and linked embeds use the same source-relative rule.
  local embed = require "obsidian.bases.embed"
  local spec, err = embed.linked_spec("./Projects.base#Active", root .. "/Notes/Home.md")
  eq(nil, spec)
  eq(true, err:find("not found", 1, true) ~= nil)
  local nearby = base_file "Notes/Projects.base"
  for _, target in ipairs { "./Projects.base", "../Notes/Projects.base" } do
    spec, err = embed.linked_spec(target .. "#Active", root .. "/Notes/Home.md")
    eq(nil, err)
    eq(nearby, spec.path)
    eq("Active", spec.load().view_name)
  end
end

T["shortest targets"]["bound fallback searches without accepting a partial match set"] = function()
  base_file "Area/Projects.base"
  local hrtime = vim.uv.hrtime
  local ticks = -1000000000
  vim.uv.hrtime = function()
    ticks = ticks + 1000000000
    return ticks
  end
  local ok, spec, err = pcall(resolver.resolve, "Projects.base", { source_path = root .. "/Notes/Home.md" })
  vim.uv.hrtime = hrtime
  eq(true, ok)
  eq(nil, spec)
  eq(true, err:find("timed out", 1, true) ~= nil)
end

return T
