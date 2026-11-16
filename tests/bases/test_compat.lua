local compat = require "obsidian.bases.compat"

local eq = MiniTest.expect.equality
local original_img = vim.ui.img
local original_system = vim.system
local original_async = vim.async
local T = MiniTest.new_set {
  hooks = {
    post_case = function()
      vim.ui.img = original_img
      vim.system = original_system
      vim.async = original_async
    end,
  },
}

T["reports missing and unprobed image capabilities"] = function()
  vim.ui.img = {}
  eq({ api = false, supported = false, message = "vim.ui.img is unavailable" }, compat.image_status())

  vim.ui.img = { set = function() end, get = function() end, del = function() end }
  eq({ api = true, supported = nil, message = "terminal image support has not been probed" }, compat.image_status())
  eq({ api = true, supported = true, message = "custom image backend" }, compat.image_status { probe = true })
end

T["reports stable-compatible capability fallbacks"] = function()
  vim.ui.img = false
  vim.async = false
  local capabilities = compat.capabilities()
  eq(false, capabilities.ui_img)
  eq(false, capabilities.async)
  eq(true, capabilities.system)

  vim.system = nil
  local process, missing = compat.system({ "missing" }, {}, function() end)
  eq(nil, process)
  eq("this Neovim build does not provide vim.system()", missing)

  vim.system = function()
    error "system setup failed"
  end
  local failed, failure = compat.system({ "bad" }, {}, function() end)
  eq(nil, failed)
  eq(true, failure:find("system setup failed", 1, true) ~= nil)
end

T["probes and wraps the experimental image backend"] = function()
  local deleted
  vim.ui.img = {
    _supported = function(opts)
      eq(25, opts.timeout)
      return false, "unsupported terminal"
    end,
    set = function(data, opts)
      if type(data) == "number" then
        eq(7, data)
        eq(9, opts.col)
        return data
      end
      eq("png", data)
      eq(3, opts.row)
      return 7
    end,
    get = function() end,
    del = function(id)
      deleted = id
    end,
  }
  eq(
    { api = true, supported = false, message = "unsupported terminal" },
    compat.image_status { probe = true, timeout = 25 }
  )
  eq(7, compat.show_image("png", { row = 3 }))
  eq(true, compat.update_image(7, { col = 9 }))
  compat.delete_image(7)
  eq(7, deleted)
end

return T
