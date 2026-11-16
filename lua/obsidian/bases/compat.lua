local M = {}

---@class obsidian.bases.Capabilities
---@field async boolean
---@field ui_img boolean
---@field decoration_provider boolean
---@field system boolean

---@return obsidian.bases.Capabilities
function M.capabilities()
  return {
    async = type(vim.async) == "function",
    ui_img = vim.ui ~= nil and type(vim.ui.img) == "table",
    decoration_provider = vim.api.nvim_set_decoration_provider ~= nil,
    system = vim.system ~= nil,
  }
end

---@param opts { probe: boolean?, timeout: integer? }|nil
---@return { api: boolean, supported: boolean|nil, message: string|nil }
function M.image_status(opts)
  opts = opts or {}
  local image = vim.ui and vim.ui.img or nil
  local api = type(image) == "table"
    and type(image.set) == "function"
    and type(image.get) == "function"
    and type(image.del) == "function"
  if not api then
    return { api = false, supported = false, message = "vim.ui.img is unavailable" }
  end
  if not opts.probe then
    return { api = true, supported = nil, message = "terminal image support has not been probed" }
  end
  local supported_fn = rawget(image, "_supported")
  if type(supported_fn) ~= "function" then
    return { api = true, supported = true, message = "custom image backend" }
  end
  local ok, supported, message = pcall(supported_fn, { timeout = opts.timeout or 250 })
  if not ok then
    return { api = true, supported = false, message = tostring(supported) }
  end
  return { api = true, supported = supported == true, message = message }
end

---@param data string
---@param opts table
---@return integer|nil
---@return string|nil
function M.show_image(data, opts)
  local status = M.image_status()
  if not status.api then
    return nil, status.message
  end
  local ok, id = pcall(vim.ui.img.set, data, opts)
  if not ok then
    return nil, tostring(id)
  end
  return id, nil
end

---@param id integer
---@param opts table
---@return boolean
---@return string|nil
function M.update_image(id, opts)
  local status = M.image_status()
  if not status.api then
    return false, status.message
  end
  local ok, err = pcall(vim.ui.img.set, id, opts)
  return ok, ok and nil or tostring(err)
end

---@param id integer
function M.delete_image(id)
  local status = M.image_status()
  if status.api then
    pcall(vim.ui.img.del, id)
  end
end

---@param command string[]
---@param opts table
---@param on_exit fun(result: vim.SystemCompleted)
---@return vim.SystemObj|nil
---@return string|nil
function M.system(command, opts, on_exit)
  if not vim.system then
    return nil, "this Neovim build does not provide vim.system()"
  end
  local ok, process = pcall(vim.system, command, opts, on_exit)
  if not ok then
    return nil, tostring(process)
  end
  return process, nil
end

return M
