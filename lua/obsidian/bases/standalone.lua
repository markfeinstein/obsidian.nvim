local api = require "obsidian.api"
local resolver = require "obsidian.bases.resolver"
local vault_scope = require "obsidian.bases.scope"
local workspace = require "obsidian.bases.workspace"

local M = {}

local group

local function enabled()
  local bases = Obsidian and Obsidian.opts and Obsidian.opts.bases
  return bases and bases.standalone and bases.standalone.auto_open == true
end

local function eligible(path)
  local workspace_config = api.find_workspace(path)
  if not workspace_config then
    return false
  end
  local scope = vault_scope.capture(path)
  if not scope or not vault_scope.contains(scope, path) then
    return false
  end
  return require("obsidian.index.files").path_filter(vault_scope.index_opts(scope))(path)
end

---@param buf integer
function M.maybe_open(buf)
  if not enabled() or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  if vim.b[buf].obsidian_bases_raw == true then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or require("obsidian.filetypes").extension(path) ~= "base" or not eligible(path) then
    return
  end
  if vim.api.nvim_get_current_buf() ~= buf then
    return
  end
  local spec, err = resolver.resolve(nil, { source_path = path })
  if not spec then
    require("obsidian.log").err(err or "Could not resolve Base definition")
    return
  end
  workspace.open(spec, { current = true, raw_buf = buf })
end

---@param path string|nil
---@param workspace_buf integer|nil
---@return integer|nil
function M.open_raw(path, workspace_buf)
  workspace_buf = workspace_buf or vim.api.nvim_get_current_buf()
  local state = workspace.get(workspace_buf)
  path = path or (state and state.spec.path) or vim.api.nvim_buf_get_name(workspace_buf)
  if path == "" or require("obsidian.filetypes").extension(path) ~= "base" then
    require("obsidian.log").err "No standalone .base definition is available"
    return nil
  end
  local buf = state and state.raw_buf or require("obsidian.bases.buffer").find(path)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.fn.bufadd(path)
  end
  vim.fn.bufload(buf)
  vim.b[buf].obsidian_bases_raw = true
  vim.api.nvim_win_set_buf(0, buf)
  if state and vim.api.nvim_buf_is_valid(workspace_buf) then
    vim.api.nvim_buf_delete(workspace_buf, { force = true })
  end
  return buf
end

function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("obsidian.bases.standalone", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = "*.base",
    callback = function(args)
      vim.schedule(function()
        M.maybe_open(args.buf)
      end)
    end,
  })
  vim.schedule(function()
    M.maybe_open(vim.api.nvim_get_current_buf())
  end)
end

function M.stop()
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
end

return M
