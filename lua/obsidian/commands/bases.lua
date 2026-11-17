return function(data)
  local bases = require "obsidian.bases"
  if data.args == "--raw" then
    require("obsidian.bases.standalone").open_raw()
    return
  end
  local target = data.args ~= "" and data.args or nil
  if not target then
    local spec, err = require("obsidian.bases.embed").at_cursor(0)
    if spec then
      bases.open_spec(spec)
      return
    elseif err then
      require("obsidian.log").err(err)
      return
    end
  end
  local _, err = bases.open(target, {
    source_path = vim.api.nvim_buf_get_name(0),
  })
  if err then
    require("obsidian.log").err(err)
  end
end
