return function(data)
  local inline = require "obsidian.bases.inline"
  local action = data.args ~= "" and data.args or "toggle"
  if action == "enable" then
    inline.attach(0)
  elseif action == "disable" then
    inline.disable(0)
  elseif action == "refresh" then
    inline.refresh(0, { rescan = true })
  elseif action == "toggle" then
    inline.toggle(0)
  else
    require("obsidian.log").err("Unknown Bases inline action: " .. action)
  end
end
