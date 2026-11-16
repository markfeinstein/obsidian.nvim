local M = require "obsidian.util.fs"
local new_set, eq = MiniTest.new_set, MiniTest.expect.equality

local T = new_set()

T["relpath"] = function()
  eq(M.relpath("/a", "/a/b"), "b")
  eq(M.relpath("/a/b/", "/a/d/e"), "../d/e")
  eq(M.relpath("/a/b/c", "/a"), "../..")
  eq(M.relpath("/a/b/c", "/a/d/e"), "../../d/e")
end

T["is_subpath"] = function()
  eq(true, M.is_subpath("/a/b", "/a"))
  eq(true, M.is_subpath("/a", "/a/"))
  eq(false, M.is_subpath("/ab", "/a"))
end

T["atomic_write"] = function()
  local path = vim.fn.tempname()
  M.atomic_write(path, "first")
  eq({ "first" }, vim.fn.readfile(path))
  M.atomic_write(path, "second")
  eq({ "second" }, vim.fn.readfile(path))
  eq(0, vim.fn.filereadable(path .. ".tmp"))
  vim.fn.delete(path)
end

T["creation_time prefers birth time and falls back only when unavailable"] = function()
  local born = { sec = 123, nsec = 456 }
  local changed = { sec = 789, nsec = 123 }
  eq(born, M.creation_time { birthtime = born, ctime = changed })
  eq(changed, M.creation_time { birthtime = { sec = 0, nsec = 0 }, ctime = changed })
  eq(changed, M.creation_time { ctime = changed })
  eq(nil, M.creation_time {})
end

return T
