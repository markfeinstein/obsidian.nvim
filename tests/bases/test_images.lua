local files = require "obsidian.index.files"
local images = require "obsidian.bases.images"
local fs_util = require "obsidian.util.fs"

local eq = MiniTest.expect.equality
local root
local outside

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
      Obsidian = {
        dir = root,
        opts = { sync = { config_dir = ".obsidian" }, file = { ignore_filters = {} } },
      }
    end,
    post_case = function()
      files.clear()
      vim.fn.delete(root, "rf")
      vim.fn.delete(outside, "rf")
    end,
  },
}

local function row(value)
  return {
    path = vim.fs.joinpath(root, "Notes", "Card.md"),
    note = { cover = value },
    file = { path = "Notes/Card.md" },
  }
end

T["resolves local PNG image properties"] = function()
  local path = vim.fs.joinpath(root, "assets", "cover.png")
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ "png" }, path, "b")
  local resolved, err = images.resolve(row "[[assets/cover.png]]", { image = "cover" })
  eq(nil, err)
  eq(path, resolved.path)
  eq("png", images.read(path):sub(1, 3))
end

T["keeps in-vault image symlinks and rejects outside image targets"] = function()
  local real = vim.fs.joinpath(root, "assets", "real.png")
  vim.fn.mkdir(vim.fs.dirname(real), "p")
  vim.fn.writefile({ "inside" }, real, "b")
  local inside_link = vim.fs.joinpath(root, "assets", "inside-link.png")
  assert(vim.uv.fs_symlink(real, inside_link))
  local resolved = assert(images.resolve(row "[[assets/inside-link.png]]", { image = "cover" }))
  eq(inside_link, resolved.path)
  eq("inside", images.read(inside_link):sub(1, 6))

  local outside_png = vim.fs.joinpath(outside, "outside.png")
  vim.fn.writefile({ "outside" }, outside_png, "b")
  local outside_link = vim.fs.joinpath(root, "assets", "outside-link.png")
  assert(vim.uv.fs_symlink(outside_png, outside_link))

  local rejected, err = images.resolve(row "[[assets/outside-link.png]]", { image = "cover" })
  eq(nil, rejected)
  eq("the local image target is outside the vault", err)
  eq(nil, images.read(outside_link))

  rejected, err = images.resolve(row("[[" .. outside_png .. "]]"), { image = "cover" })
  eq(nil, rejected)
  eq("the local image target is outside the vault", err)

  local relative_escape = fs_util.relpath(vim.fs.joinpath(root, "Notes"), outside_png)
  rejected, err = images.resolve(row("[[" .. relative_escape .. "]]"), { image = "cover" })
  eq(nil, rejected)
  eq("the local image target is outside the vault", err)
end

T["reports unsupported image values honestly"] = function()
  local resolved, err = images.resolve(row "https://example.com/image.png", { image = "cover" })
  eq(nil, resolved)
  eq("external image URLs are not fetched", err)

  resolved, err = images.resolve(row "[[cover.jpg]]", { image = "cover" })
  eq(nil, resolved)
  eq("native image previews currently support local PNG files only", err)

  resolved, err = images.resolve(row "#ff0000", { image = "cover" })
  eq(nil, resolved)
  eq("color image values use text fallback", err)
end

return T
