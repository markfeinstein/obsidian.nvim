local M = {}

---@class obsidian.parse.embeds.Match
---@field col integer 0-indexed
---@field end_col integer 0-indexed, exclusive
---@field target string

local function clean_wiki_target(body)
  return vim.trim(body:match "^([^|]+)" or body)
end

local function clean_markdown_target(body)
  body = vim.trim(body)
  body = body:match "^<(.+)>$" or body
  body = body:match "^(%S+)%s+['\"].-['\"]$" or body
  return vim.uri_decode(body:gsub("\\ ", " "))
end

---@param line string
---@return obsidian.parse.embeds.Match[]
function M.find(line)
  local matches = {}
  for col, body, end_pos in line:gmatch "()!%[%[([^%]]+)%]%]()" do
    matches[#matches + 1] = {
      col = col - 1,
      end_col = end_pos - 1,
      target = clean_wiki_target(body),
    }
  end
  for col, body, end_pos in line:gmatch "()!%[[^%]]*%]%(([^%)]+)%)()" do
    matches[#matches + 1] = {
      col = col - 1,
      end_col = end_pos - 1,
      target = clean_markdown_target(body),
    }
  end
  table.sort(matches, function(left, right)
    return left.col < right.col
  end)
  return matches
end

---@param target string
---@return string path
---@return string|nil fragment
function M.target_parts(target)
  local path, fragment = target:match "^(.-)#(.*)$"
  path = (path or target):gsub("%?.*$", "")
  if fragment then
    fragment = fragment:gsub("%?.*$", "")
  end
  return path, fragment ~= "" and fragment or nil
end

return M
