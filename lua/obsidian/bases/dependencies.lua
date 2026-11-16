local M = {}

local function contains(value, dependency)
  if type(value) == "string" then
    return value:find(dependency, 1, true) ~= nil
  elseif type(value) ~= "table" then
    return false
  end
  for key, child in pairs(value) do
    if contains(key, dependency) or contains(child, dependency) then
      return true
    end
  end
  return false
end

---@param definition obsidian.bases.Definition
---@return { backlinks: boolean }
function M.for_definition(definition)
  local expressions = {
    filters = definition.filters,
    formulas = definition.formulas,
    view = definition.view,
  }
  -- Do not duplicate the evaluator's parser in Lua. Whitespace, bracket
  -- notation, and computed keys can all refer to backlinks. When a definition
  -- uses brackets, conservatively collect incoming links rather than treating
  -- an unrecognized dependency as an empty, complete result.
  return {
    backlinks = contains(expressions, "backlinks") or contains(expressions, "["),
  }
end

M.contains = contains

return M
