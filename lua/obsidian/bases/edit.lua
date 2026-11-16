local buffer = require "obsidian.bases.buffer"
local filetypes = require "obsidian.filetypes"
local fs_util = require "obsidian.util.fs"
local Note = require "obsidian.note"
local Path = require "obsidian.path"
local property_types = require "obsidian.properties.types"
local yaml = require "obsidian.yaml"
local yaml_util = require "obsidian.yaml.util"

local M = {}

local reserved_properties = {
  id = true,
  aliases = true,
  tags = true,
}
local BOM = "\239\187\191"
local markdown_extensions = {
  md = true,
  markdown = true,
  qmd = true,
}

---@param path string
---@return boolean
function M.supports_note_path(path)
  return markdown_extensions[filetypes.extension(path)] == true
end

---Return the normalized path only when `parsed` identifies a successfully parsed,
---supported Markdown-like note at that path.
---@param path string
---@param parsed obsidian.Note|table
---@return string|nil
function M.note_identity(path, parsed)
  if type(path) ~= "string" or not M.supports_note_path(path) then
    return nil
  end
  path = tostring(Path.new(path):resolve())
  if Note.is_note_obj(parsed) then
    if not parsed.path or tostring(parsed.path) ~= path then
      return nil
    end
  elseif type(parsed) ~= "table" or parsed.kind ~= "note" then
    return nil
  end
  return path
end

---@class obsidian.bases.EditRequest
---@field path string
---@field property string
---@field expected any
---@field revision table
---@field input string
---@field insert_missing boolean|nil
---@field declared_type string|nil
---@field property_types_revision table|nil
---@field vault string|nil
---@field config_dir string|nil

---@class obsidian.bases.EditResult
---@field bufnr integer
---@field property string
---@field old_value any
---@field new_value any
---@field changedtick integer
---@field changed boolean
---@field inserted boolean|nil

---@param property string
---@return string|nil
---@return string|nil
function M.property_key(property)
  if vim.startswith(property, "file.") then
    return nil, "file properties are read-only"
  elseif vim.startswith(property, "formula.") then
    return nil, "formula properties are read-only"
  elseif vim.startswith(property, "note.") then
    property = property:sub(6)
  end
  if property == "" or property:find("[", 1, true) or property:find(".", 1, true) then
    return nil, "only top-level note properties are editable"
  end
  return property, nil
end

local function stat_matches(stat, revision)
  return stat ~= nil
    and stat.type == "file"
    and stat.mtime.sec == revision.mtime_sec
    and stat.mtime.nsec == revision.mtime_nsec
    and stat.size == revision.size
end

local function load_target(path, revision)
  local bufnr = buffer.find(path)
  if revision.kind == "buffer" then
    if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then
      return nil, "the source buffer is no longer loaded"
    end
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= revision.changedtick then
      return nil, "the note changed after this result was evaluated"
    end
    return bufnr, nil
  elseif revision.kind ~= "disk" then
    return nil, "the result has no supported source revision"
  end

  if not stat_matches(vim.uv.fs_stat(path), revision) then
    return nil, "the note changed on disk after this result was evaluated"
  end
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
    return nil, "the note has unsaved changes newer than this result"
  end
  if not bufnr then
    bufnr = vim.fn.bufadd(path)
  end
  vim.fn.bufload(bufnr)
  -- bufload() does not reload an already loaded, unmodified buffer. A result
  -- may describe newer disk content while the property itself is unchanged.
  local ok, disk_lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "the note could not be read while preparing the edit"
  end
  if disk_lines[1] then
    disk_lines[1] = disk_lines[1]:gsub("^" .. BOM, "")
  else
    disk_lines = { "" }
  end
  if not vim.deep_equal(disk_lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) then
    return nil, "the note buffer differs from disk; reload it before editing"
  end
  if not stat_matches(vim.uv.fs_stat(path), revision) then
    return nil, "the note changed on disk while preparing the edit"
  end
  return bufnr, nil
end

local function find_element(note, property)
  for _, element in ipairs(note.frontmatter_elements or {}) do
    if #element.path == 1 and element.path[1] == property then
      return element
    end
  end
end

local function is_link(value)
  return value:match "^!?%[%[.-%]%]$" ~= nil or value:match "^%[[^%]]+%]%([^%)]+%)$" ~= nil
end

local function date_parts(value)
  local year, month, day = value:match "^(%d%d%d%d)%-(%d%d)%-(%d%d)$"
  local hour, minute, second
  local has_time = false
  if not year then
    ---@type string|nil
    local suffix
    year, month, day, hour, minute, suffix = value:match "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)(.*)$"
    if not year or not suffix then
      return nil
    end
    has_time = true
    second = "0"
    if vim.startswith(suffix, ":") then
      second, suffix = suffix:match "^:(%d%d)(.*)$"
      if not second or not suffix then
        return nil
      end
      if vim.startswith(suffix, ".") then
        suffix = suffix:match "^%.%d+(.*)$"
        if not suffix then
          return nil
        end
      end
    end
    if suffix ~= "" and suffix ~= "Z" then
      local offset_hour, offset_minute = suffix:match "^[+-](%d%d):?(%d%d)$"
      if not offset_hour or tonumber(offset_hour) > 23 or tonumber(offset_minute) > 59 then
        return nil
      end
    end
  end
  if not year then
    return nil
  end
  year = assert(tonumber(year), "invalid date year")
  month = assert(tonumber(month), "invalid date month")
  day = assert(tonumber(day), "invalid date day")
  hour = has_time and assert(tonumber(hour), "invalid date hour") or 0
  minute = has_time and assert(tonumber(minute), "invalid date minute") or 0
  second = has_time and second ~= "" and assert(tonumber(second), "invalid date second") or 0
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0) then
    days[2] = 29
  end
  if month < 1 or month > 12 or day < 1 or day > days[month] then
    return nil
  end
  if hour > 23 or minute > 59 or second > 59 then
    return nil
  end
  return { year = year, month = month, day = day, hour = hour, minute = minute, second = second, has_time = has_time }
end

---@param value any
---@param declared_type string|nil
---@return "null"|"list"|"object"|"link"|"date"|"datetime"|"string"|"number"|"boolean"|"unknown"
function M.value_kind(value, declared_type)
  local declared_family = declared_type and property_types.family_by_type[declared_type] or nil
  if declared_family then
    if declared_family == "string" and type(value) == "string" and is_link(value) then
      return "link"
    end
    return declared_family
  elseif value == nil or value == vim.NIL then
    return "null"
  elseif type(value) == "table" then
    return vim.islist(value) and "list" or "object"
  elseif type(value) == "string" then
    if is_link(value) then
      return "link"
    elseif date_parts(value) then
      return "date"
    end
    return "string"
  elseif type(value) == "number" then
    return "number"
  elseif type(value) == "boolean" then
    return "boolean"
  end
  return "unknown"
end

local function is_finite(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function encode_scalar(value)
  if value == nil or value == vim.NIL then
    return "null"
  elseif type(value) == "table" or (type(value) == "number" and not is_finite(value)) then
    return nil
  end
  local encoded = yaml.dumps(value)
  if encoded:find("\n", 1, true) then
    return nil
  end
  local ok, decoded = pcall(yaml.loads, { "value: " .. encoded })
  if not ok or type(decoded) ~= "table" or not vim.deep_equal(decoded.value, value) then
    return nil
  end
  return encoded
end

local function scalar_input(value)
  local replacement = encode_scalar(value)
  if not replacement then
    return nil, nil, "the scalar cannot be represented safely by the current YAML parser"
  end
  return value, replacement, nil
end

local function flow_list(values)
  local encoded = {}
  for _, value in ipairs(values) do
    local scalar = encode_scalar(value)
    if not scalar then
      return nil
    end
    -- Plain scalars have stricter rules inside a flow collection than on a
    -- property line. Single quotes preserve punctuation and backslashes.
    if type(value) == "string" and value:find "[,%[%]{}]" then
      scalar = "'" .. value:gsub("'", "''") .. "'"
    end
    encoded[#encoded + 1] = scalar
  end
  local replacement = "[" .. table.concat(encoded, ", ") .. "]"
  local ok, decoded = pcall(yaml.loads, { "value: " .. replacement })
  if not ok or type(decoded) ~= "table" or not vim.deep_equal(decoded.value, values) then
    return nil
  end
  return replacement
end

---@param value any
---@param declared_type string|nil
---@return string
function M.input_default(value, declared_type)
  if M.value_kind(value, declared_type) == "list" then
    return type(value) == "table" and (flow_list(value) or "[]") or "[]"
  elseif value == nil or value == vim.NIL then
    return ""
  end
  return tostring(value)
end

---@type fun(input: string): any[]|nil, string|nil
local parse_list_input

local function coerce_input(input, current, declared_type)
  local kind = M.value_kind(current, declared_type)
  if kind == "list" then
    local values, err = parse_list_input(input)
    if not values then
      return nil, nil, err
    end
    local replacement = flow_list(values)
    if not replacement then
      return nil, nil, "the list cannot be represented safely by the current YAML parser"
    end
    return values, replacement, nil
  elseif kind == "null" then
    if vim.trim(input):lower() == "null" then
      return vim.NIL, "null"
    end
    return nil, nil, "null properties need a declared type before changing value"
  elseif kind == "number" then
    local value = tonumber(vim.trim(input))
    if value == nil then
      return nil, nil, "expected a number"
    elseif not is_finite(value) then
      return nil, nil, "expected a finite number"
    end
    return scalar_input(value)
  elseif kind == "boolean" then
    local normalized = vim.trim(input):lower()
    if normalized ~= "true" and normalized ~= "false" then
      return nil, nil, "expected true or false"
    end
    local value = normalized == "true"
    return scalar_input(value)
  elseif kind == "object" or kind == "unknown" then
    return nil, nil, "objects and unsupported property types are read-only"
  end

  if input:find("\n", 1, true) or input:find("\r", 1, true) then
    return nil, nil, "multiline scalar editing is not supported"
  end
  local value = input
  if kind == "link" then
    value = vim.trim(input)
    if value == "" then
      return nil, nil, "link targets cannot be empty"
    elseif not is_link(value) then
      if value:find("%[%[", 1) or value:find("%]%]", 1) then
        return nil, nil, "expected a complete wikilink, Markdown link, or bare link target"
      end
      value = "[[" .. value .. "]]"
    end
  elseif kind == "date" or kind == "datetime" then
    value = vim.trim(input)
    local parts = date_parts(value)
    if
      not parts
      or (kind == "datetime" and not parts.has_time)
      or (kind == "date" and declared_type and parts.has_time)
    then
      local message = kind == "datetime" and "expected an ISO datetime"
        or declared_type and "expected an ISO date"
        or "expected an ISO date or datetime"
      return nil, nil, message
    end
  end
  return scalar_input(value)
end

parse_list_input = function(input)
  if input:find("\n", 1, true) or input:find("\r", 1, true) then
    return nil, "list input must be a single YAML flow list"
  end
  local trimmed = vim.trim(input)
  if not vim.startswith(trimmed, "[") or not vim.endswith(trimmed, "]") then
    return nil, "list input must use YAML flow syntax, for example [one, two]"
  end
  local ok, decoded = pcall(yaml.loads, { "value: " .. trimmed })
  local values = ok and type(decoded) == "table" and decoded.value or nil
  if type(values) ~= "table" or not vim.islist(values) then
    return nil, "expected a YAML list"
  end
  for _, value in ipairs(values) do
    if type(value) == "table" then
      return nil, "nested lists and objects are read-only"
    end
  end
  return values, nil
end

local function property_line(document, property)
  local frontmatter = document.frontmatter
  if not frontmatter or not frontmatter.body_range then
    return nil
  end
  for row = frontmatter.body_range.start_row, frontmatter.body_range.end_row - 1 do
    local line = document.lines[row + 1] or ""
    if not line:match "^%s" then
      local key = line:match "^([%w_][%w_ /()%-]*):"
      if key == property then
        return row, line
      end
    end
  end
end

local function list_elements(note, property)
  local elements = {}
  for _, element in ipairs(note.frontmatter_elements or {}) do
    if #element.path >= 2 and element.path[1] == property then
      if #element.path ~= 2 or type(element.path[2]) ~= "number" or type(element.value) == "table" then
        return nil, "nested lists and objects are read-only"
      end
      if element.range.start_row ~= element.range.end_row then
        return nil, "multiline list items are read-only"
      end
      elements[#elements + 1] = element
    end
  end
  table.sort(elements, function(left, right)
    return left.path[2] < right.path[2]
  end)
  return elements, nil
end

local function edit_list(bufnr, note, property, current, expected, input, before_parse)
  if not vim.deep_equal(current, expected) then
    return nil, "the property value changed after this result was evaluated"
  end
  local values, parse_err = parse_list_input(input)
  if not values then
    return nil, parse_err
  end
  if vim.deep_equal(values, current) then
    return {
      bufnr = bufnr,
      property = property,
      old_value = current,
      new_value = values,
      changedtick = before_parse,
      changed = false,
    },
      nil
  end
  local document = note:parsed_document()
  local row, source_line = property_line(document, property)
  if not row then
    return nil, "the list property has no safe top-level source range"
  end
  local stripped = yaml_util.strip_comments(source_line)
  local colon = stripped:find(":", 1, true)
  local after = colon and stripped:sub(colon + 1) or ""
  local leading = after:match "^(%s*)" or ""
  local source_value = vim.trim(after)
  local replacement = flow_list(values)
  if not replacement then
    return nil, "the list cannot be represented safely by the current YAML parser"
  end
  if vim.api.nvim_buf_get_changedtick(bufnr) ~= before_parse then
    return nil, "the note changed while preparing the edit"
  end

  if vim.startswith(source_value, "[") and vim.endswith(source_value, "]") then
    local start_col = assert(colon, "property line is missing a colon") + #leading
    vim.api.nvim_buf_set_text(bufnr, row, start_col, row, #stripped, { replacement })
  else
    if #values == 0 then
      return nil, "emptying a block-style list is not supported"
    end
    local elements, elements_err = list_elements(note, property)
    if not elements or #elements == 0 then
      return nil, elements_err or "the block list has no safe item ranges"
    end
    local start_row = elements[1].range.start_row
    ---@cast start_row integer
    local end_row = elements[#elements].range.end_row + 1
    local item_line = document.lines[start_row + 1] or ""
    local indent = item_line:match "^(%s*)%-" or "  "
    local replacement_lines = {}
    for _, value in ipairs(values) do
      replacement_lines[#replacement_lines + 1] = indent .. "- " .. assert(encode_scalar(value))
    end
    vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, replacement_lines)
  end

  return {
    bufnr = bufnr,
    property = property,
    old_value = current,
    new_value = values,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    changed = true,
  },
    nil
end

local function infer_missing_input(input, declared_type)
  if declared_type then
    if not property_types.family_by_type[declared_type] then
      return nil, nil, "unsupported declared property types are read-only"
    end
    return coerce_input(input, nil, declared_type)
  end
  if input:find("\n", 1, true) or input:find("\r", 1, true) then
    return nil, nil, "multiline scalar editing is not supported"
  end
  local normalized = vim.trim(input)
  local lower = normalized:lower()
  if lower == "true" or lower == "false" then
    local value = lower == "true"
    return scalar_input(value)
  elseif lower == "null" or normalized == "~" then
    return vim.NIL, "null", nil
  elseif
    normalized:match "^[+-]?%d+$"
    or normalized:match "^[+-]?%d+%.%d+$"
    or normalized:match "^[+-]?%d+[eE][+-]?%d+$"
    or normalized:match "^[+-]?%d+%.%d+[eE][+-]?%d+$"
  then
    local value = tonumber(normalized)
    if value ~= nil then
      if not is_finite(value) then
        return nil, nil, "expected a finite number"
      end
      return scalar_input(value)
    end
  end
  return scalar_input(input)
end

local function validate_insert_line(property, value, replacement)
  if property:find("\n", 1, true) or property:find("\r", 1, true) or property:find(":", 1, true) then
    return nil, "the property name cannot be represented safely by the current YAML parser"
  end
  local line = property .. ": " .. replacement
  local ok, decoded, _, elements = pcall(yaml.loads, { line })
  local paths_ok = true
  for _, element in ipairs(elements or {}) do
    if element.path[1] ~= property then
      paths_ok = false
      break
    end
  end
  if
    not ok
    or type(decoded) ~= "table"
    or vim.tbl_count(decoded) ~= 1
    or not vim.deep_equal(decoded[property], value)
    or not paths_ok
  then
    return nil, "the property name cannot be represented safely by the current YAML parser"
  end
  return line, nil
end

---@param document obsidian.parse.Document
---@return boolean, string|nil
local function validate_frontmatter(document)
  local frontmatter = document.frontmatter
  if not frontmatter then
    return true, nil
  end
  if frontmatter.termination ~= "delimiter" or not frontmatter.body_range then
    return false, "frontmatter is not safely replaceable"
  end
  local lines = {}
  for row = frontmatter.body_range.start_row, frontmatter.body_range.end_row - 1 do
    lines[#lines + 1] = document.lines[row + 1]
  end
  local ok, value = pcall(yaml.loads, lines)
  if not ok then
    return false, "frontmatter contains invalid YAML"
  end
  -- Empty/comment-only frontmatter is safe to populate. Other roots must be
  -- mappings, including rejecting mixed sequence/mapping tables the parser
  -- currently accepts. Appending a property to a flow root is not safe either.
  if value ~= nil then
    if type(value) ~= "table" or vim.islist(value) then
      return false, "frontmatter must be a block mapping"
    end
    for key in pairs(value) do
      if type(key) ~= "string" then
        return false, "frontmatter must be a block mapping"
      end
    end
    for _, line in ipairs(lines) do
      local content = vim.trim(yaml_util.strip_comments(line))
      if content ~= "" then
        if vim.startswith(content, "{") then
          return false, "flow-style frontmatter mappings are read-only"
        end
        break
      end
    end
  end
  return true, nil
end

local function insert_missing(bufnr, note, property, input, before_parse, declared_type)
  if reserved_properties[property] then
    return nil, "id, aliases, and tags require dedicated editors"
  end
  if input == nil then
    return nil, "a value is required"
  end
  local value, replacement, infer_err = infer_missing_input(input, declared_type)
  if infer_err then
    return nil, infer_err
  end
  local line, line_err = validate_insert_line(property, value, assert(replacement, "missing insertion replacement"))
  if not line then
    return nil, line_err
  end

  local document = note:parsed_document()
  if vim.api.nvim_buf_get_changedtick(bufnr) ~= before_parse then
    return nil, "the note changed while preparing the edit"
  end

  if document.frontmatter then
    local closer = assert(document.frontmatter.closer_range, "replaceable frontmatter requires a closer")
    vim.api.nvim_buf_set_lines(bufnr, closer.start_row, closer.start_row, false, { line })
  else
    local first = document.lines[1] or ""
    if vim.startswith(first, BOM) then
      return nil, "frontmatter insertion into a BOM-prefixed note is not supported"
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "---", line, "---", "" })
  end

  return {
    bufnr = bufnr,
    property = property,
    old_value = nil,
    new_value = value,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    changed = true,
    inserted = true,
  },
    nil
end

---@param request obsidian.bases.EditRequest
---@return obsidian.bases.EditResult|nil
---@return string|nil
function M.apply(request)
  local property, property_err = M.property_key(request.property)
  if not property then
    return nil, property_err
  end
  if type(request.revision) ~= "table" then
    return nil, "the result has no source revision"
  end
  if request.property_types_revision then
    local latest_types = property_types.get { vault = request.vault, config_dir = request.config_dir }
    if not vim.deep_equal(latest_types.revision, request.property_types_revision) then
      return nil, "property type metadata changed after this result was evaluated"
    end
  end

  local path = vim.fs.normalize(request.path)
  if not M.supports_note_path(path) then
    return nil, "the edit target is not a supported Markdown note"
  elseif request.vault and not fs_util.is_real_subpath(path, request.vault, { allow_missing = true }) then
    return nil, "the edit target is outside the originating vault"
  end
  local bufnr, load_err = load_target(path, request.revision)
  if not bufnr then
    return nil, load_err
  end
  if not vim.bo[bufnr].modifiable or vim.bo[bufnr].readonly then
    return nil, "the note buffer is read-only"
  end

  local before_parse = vim.api.nvim_buf_get_changedtick(bufnr)
  local ok, note = pcall(Note.from_buffer, bufnr, { max_lines = 2147483647 })
  if not ok or not note then
    return nil, "the note could not be parsed"
  end
  if not M.note_identity(path, note) then
    return nil, "the edit target is not a supported Markdown note"
  end
  local valid, frontmatter_err = validate_frontmatter(note:parsed_document())
  if not valid then
    return nil, frontmatter_err
  end
  local element = find_element(note, property)
  if not element then
    if request.insert_missing and reserved_properties[property] then
      return nil, "id, aliases, and tags require dedicated editors"
    end
    local current = note.metadata and note.metadata[property] or nil
    if current == nil and reserved_properties[property] then
      current = note[property]
    end
    if type(current) == "table" then
      if vim.islist(current) then
        return edit_list(bufnr, note, property, current, request.expected, request.input, before_parse)
      end
      return nil, "objects are read-only"
    elseif current ~= nil then
      return nil, "the property has no safe scalar source range"
    elseif request.expected ~= nil then
      return nil, "the property value changed after this result was evaluated"
    elseif request.insert_missing then
      return insert_missing(bufnr, note, property, request.input, before_parse, request.declared_type)
    end
    return nil, "only existing top-level scalar properties are editable"
  end
  if element.range.start_row ~= element.range.end_row then
    return nil, "multiline scalar editing is not supported"
  end
  if type(element.value) == "table" then
    return nil, "lists and objects are read-only"
  end
  if not vim.deep_equal(element.value, request.expected) then
    return nil, "the property value changed after this result was evaluated"
  end

  local new_value, replacement, coerce_err = coerce_input(request.input, element.value, request.declared_type)
  if coerce_err then
    return nil, coerce_err
  elseif not replacement then
    return nil, "missing scalar replacement"
  end
  if vim.deep_equal(new_value, element.value) then
    return {
      bufnr = bufnr,
      property = property,
      old_value = element.value,
      new_value = new_value,
      changedtick = before_parse,
      changed = false,
    },
      nil
  end
  if vim.api.nvim_buf_get_changedtick(bufnr) ~= before_parse then
    return nil, "the note changed while preparing the edit"
  end

  vim.api.nvim_buf_set_text(
    bufnr,
    element.range.start_row,
    element.range.start_col,
    element.range.end_row,
    element.range.end_col,
    { replacement }
  )
  return {
    bufnr = bufnr,
    property = property,
    old_value = element.value,
    new_value = new_value,
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    changed = true,
  },
    nil
end

return M
