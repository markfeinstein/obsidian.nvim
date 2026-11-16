local property_types = require "obsidian.properties.types"

local M = {}

local function skip_ws(source, pos)
  while pos <= #source and source:sub(pos, pos):match "%s" do
    pos = pos + 1
  end
  return pos
end

local function parse_string(source, pos)
  if source:sub(pos, pos) ~= '"' then
    return nil, "expected JSON string"
  end
  local start = pos
  pos = pos + 1
  local escaped = false
  while pos <= #source do
    local char = source:sub(pos, pos)
    if escaped then
      escaped = false
    elseif char == "\\" then
      escaped = true
    elseif char == '"' then
      local finish = pos + 1
      local ok, value = pcall(vim.json.decode, source:sub(start, pos))
      if not ok or type(value) ~= "string" then
        return nil, "invalid JSON string"
      end
      return { value = value, start = start, finish = finish }, nil
    end
    pos = pos + 1
  end
  return nil, "unterminated JSON string"
end

---@type fun(source: string, pos: integer): integer|nil, string|nil
local skip_value

local function parse_object(source, pos)
  if source:sub(pos, pos) ~= "{" then
    return nil, "expected JSON object"
  end
  local object = { open = pos, members = {} }
  local keys = {}
  pos = skip_ws(source, pos + 1)
  if source:sub(pos, pos) == "}" then
    object.close = pos
    return object, pos + 1
  end
  while pos <= #source do
    local key, key_err = parse_string(source, pos)
    if not key then
      return nil, key_err
    end
    if keys[key.value] then
      return nil, "duplicate JSON object key: " .. key.value
    end
    keys[key.value] = true
    pos = skip_ws(source, key.finish)
    if source:sub(pos, pos) ~= ":" then
      return nil, "expected ':' after JSON object key"
    end
    local value_start = skip_ws(source, pos + 1)
    local value_finish, value_err = skip_value(source, value_start)
    if not value_finish then
      return nil, value_err
    end
    object.members[#object.members + 1] = {
      key = key.value,
      key_start = key.start,
      key_finish = key.finish,
      value_start = value_start,
      value_finish = value_finish,
    }
    pos = skip_ws(source, value_finish)
    local char = source:sub(pos, pos)
    if char == "}" then
      object.close = pos
      return object, pos + 1
    elseif char ~= "," then
      return nil, "expected ',' or '}' in JSON object"
    end
    pos = skip_ws(source, pos + 1)
  end
  return nil, "unterminated JSON object"
end

local function skip_array(source, pos)
  pos = skip_ws(source, pos + 1)
  if source:sub(pos, pos) == "]" then
    return pos + 1
  end
  while pos <= #source do
    local finish, err = skip_value(source, pos)
    if not finish then
      return nil, err
    end
    pos = skip_ws(source, finish)
    local char = source:sub(pos, pos)
    if char == "]" then
      return pos + 1
    elseif char ~= "," then
      return nil, "expected ',' or ']' in JSON array"
    end
    pos = skip_ws(source, pos + 1)
  end
  return nil, "unterminated JSON array"
end

skip_value = function(source, pos)
  local char = source:sub(pos, pos)
  if char == '"' then
    local value, err = parse_string(source, pos)
    return value and value.finish or nil, err
  elseif char == "{" then
    local _, finish = parse_object(source, pos)
    return type(finish) == "number" and finish or nil, type(finish) == "string" and finish or nil
  elseif char == "[" then
    return skip_array(source, pos)
  end
  local finish = pos
  while finish <= #source and not source:sub(finish, finish):match "[%s,%]}]" do
    finish = finish + 1
  end
  if finish == pos then
    return nil, "expected JSON value"
  end
  return finish
end

local function member(object, key)
  for _, value in ipairs(object.members) do
    if value.key == key then
      return value
    end
  end
end

local function line_indent(source, pos)
  local line_start = source:sub(1, pos - 1):match ".*\n()" or 1
  return source:sub(line_start, pos - 1):match "^%s*" or ""
end

local function insert_member(source, object, key, value)
  local encoded = vim.json.encode(key) .. ": " .. vim.json.encode(value)
  local multiline = source:sub(object.open, object.close):find("\n", 1, true) ~= nil
  local last = object.members[#object.members]
  if not last then
    if multiline then
      local close_indent = line_indent(source, object.close)
      local indent = close_indent .. "  "
      local replacement = "\n" .. indent .. encoded .. "\n" .. close_indent
      return source:sub(1, object.open) .. replacement .. source:sub(object.close)
    end
    return source:sub(1, object.open) .. encoded .. source:sub(object.close)
  end
  if multiline then
    local indent = line_indent(source, last.key_start)
    local insertion = ",\n" .. indent .. encoded
    return source:sub(1, last.value_finish - 1) .. insertion .. source:sub(last.value_finish)
  end
  return source:sub(1, last.value_finish - 1) .. ", " .. encoded .. source:sub(last.value_finish)
end

local function patch_source(source, property, type_name)
  local root_start = skip_ws(source, 1)
  local root, root_finish = parse_object(source, root_start)
  if not root then
    return nil, root_finish
  end
  if skip_ws(source, root_finish) <= #source then
    return nil, "property type metadata has trailing non-whitespace content"
  end
  local types_member = member(root, "types")
  if not types_member then
    return insert_member(source, root, "types", { [property] = type_name }), true
  end
  local types, types_finish = parse_object(source, types_member.value_start)
  if not types or types_finish ~= types_member.value_finish then
    return nil, "property type metadata types value is not a JSON object"
  end
  local property_member = member(types, property)
  if property_member then
    local current, current_err = parse_string(source, property_member.value_start)
    if not current or current.finish ~= property_member.value_finish then
      return nil, current_err or "property type value is not a JSON string"
    end
    return source:sub(1, current.start - 1) .. vim.json.encode(type_name) .. source:sub(current.finish), false
  end
  return insert_member(source, types, property, type_name), true
end

local function source_lines(source)
  local endofline = source:sub(-1) == "\n"
  if endofline then
    source = source:sub(1, -2)
  end
  local lines = vim.split(source, "\n", { plain = true, trimempty = false })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("\r$", "")
  end
  return lines, endofline
end

local function find_property(snapshot, property)
  if snapshot.types[property] ~= nil then
    return property, snapshot.types[property], nil
  end
  local lower = property:lower()
  local found
  for name, value in pairs(snapshot.types) do
    if name:lower() == lower then
      if found then
        return nil, nil, "property type metadata contains ambiguous case variants for " .. property
      end
      found = { name, value }
    end
  end
  return found and found[1] or property, found and found[2] or nil, nil
end

---@param opts { property: string, type_name: string, expected: string?, revision: table, vault: string?, config_dir: string? }
---@return table|nil
---@return string|nil
function M.apply(opts)
  if type(opts.property) ~= "string" or opts.property == "" or opts.property:find "[%c\r\n]" then
    return nil, "invalid property name"
  end
  if not vim.tbl_contains(property_types.supported_types, opts.type_name) then
    return nil, "unsupported property type: " .. tostring(opts.type_name)
  end
  local snapshot = property_types.get { vault = opts.vault, config_dir = opts.config_dir }
  if snapshot.status == "invalid" then
    return nil, snapshot.diagnostic
  end
  if not vim.deep_equal(snapshot.revision, opts.revision) then
    return nil, "property type metadata changed since the view was evaluated"
  end
  local property, current, property_err = find_property(snapshot, opts.property)
  if not property then
    return nil, property_err
  end
  if current ~= opts.expected then
    return nil, "declared property type no longer matches the expected value"
  end
  if current == opts.type_name then
    return {
      changed = false,
      inserted = false,
      property = property,
      type_name = opts.type_name,
      path = snapshot.path,
      revision = snapshot.revision,
    },
      nil
  end

  local source
  if snapshot.revision.kind == "missing" then
    source = vim.json.encode { types = { [property] = opts.type_name } } .. "\n"
  else
    local bufnr = vim.fn.bufnr(snapshot.path)
    if snapshot.revision.kind == "buffer" and bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      if vim.bo[bufnr].endofline then
        source = source .. "\n"
      end
    else
      local file = io.open(snapshot.path, "r")
      if not file then
        return nil, "property type metadata could not be read"
      end
      source = file:read "*a"
      file:close()
    end
    local patched, inserted_or_err = patch_source(source, property, opts.type_name)
    if not patched then
      return nil, inserted_or_err
    end
    source = patched
  end

  local latest = property_types.get { vault = opts.vault, config_dir = opts.config_dir }
  if not vim.deep_equal(latest.revision, snapshot.revision) then
    return nil, "property type metadata changed while preparing the edit"
  end
  local bufnr = vim.fn.bufadd(snapshot.path)
  vim.fn.bufload(bufnr)
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return nil, "property type metadata buffer is read-only"
  end
  local lines, endofline = source_lines(source)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].endofline = endofline
  vim.bo[bufnr].modified = true
  local updated = property_types.get { vault = opts.vault, config_dir = opts.config_dir }
  return {
    changed = current ~= opts.type_name,
    inserted = current == nil,
    property = property,
    type_name = opts.type_name,
    buf = bufnr,
    path = snapshot.path,
    revision = updated.revision,
  },
    nil
end

M.patch_source = patch_source

return M
