local M = {}

---@param path string
---@return integer|nil
function M.find(path)
  path = vim.fs.normalize(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and vim.fs.normalize(name) == path then
      return bufnr
    end
  end
end

return M
