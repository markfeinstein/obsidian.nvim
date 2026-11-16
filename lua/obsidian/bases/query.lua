local dependencies = require "obsidian.bases.dependencies"
local model = require "obsidian.bases.model"
local property_types = require "obsidian.properties.types"
local source = require "obsidian.bases.source"
local worker = require "obsidian.bases.worker"

local M = {}

local function value_at(row, property)
  if vim.startswith(property, "formula.") then
    if row.formulas then
      return row.formulas[property:sub(9)]
    end
    return nil
  elseif vim.startswith(property, "file.") then
    return row.file[property:sub(6)]
  elseif vim.startswith(property, "note.") then
    return row.note[property:sub(6)]
  else
    return row.note[property]
  end
end

local function display_value(value)
  if value == nil or value == vim.NIL then
    return ""
  elseif type(value) == "table" then
    if vim.islist(value) then
      return table.concat(
        vim.tbl_map(function(item)
          if type(item) == "table" and type(item.path) == "string" then
            return item.path
          elseif type(item) == "table" then
            return vim.inspect(item, { newline = " ", indent = "" })
          end
          return tostring(item)
        end, value),
        ", "
      )
    end
    return vim.inspect(value, { newline = " ", indent = "" })
  else
    return tostring(value)
  end
end

local function columns(definition, types_snapshot)
  local order = definition.view.order
  if type(order) ~= "table" or not vim.islist(order) or #order == 0 then
    order = { "file.name" }
  end
  local result = {}
  for _, property in ipairs(order) do
    if type(property) == "string" then
      local config = definition.properties[property]
      local family, declared_type = property_types.type_for(property, types_snapshot)
      result[#result + 1] = {
        property = property,
        label = type(config) == "table" and config.displayName or property,
        type = family,
        declared_type = declared_type,
      }
    end
  end
  return result
end

local function compare_values(left, right)
  -- Missing properties and explicit YAML nulls share one sort position.
  -- Otherwise DESC considers each representation greater than the other.
  if left == vim.NIL then
    left = nil
  end
  if right == vim.NIL then
    right = nil
  end
  if left == right then
    return 0
  elseif left == nil or left == vim.NIL then
    return 1
  elseif right == nil or right == vim.NIL then
    return -1
  elseif type(left) == type(right) and (type(left) == "number" or type(left) == "string") then
    return left < right and -1 or 1
  else
    local left_text, right_text = display_value(left), display_value(right)
    if left_text == right_text then
      return 0
    end
    return left_text < right_text and -1 or 1
  end
end

local function sort_properties(definition)
  local properties = {}
  local sort = definition.view.sort
  if type(sort) == "table" and vim.islist(sort) then
    for _, spec in ipairs(sort) do
      if type(spec) == "table" and type(spec.property) == "string" then
        properties[#properties + 1] = spec.property
      end
    end
  end
  return properties
end

local function sort_value(row, property)
  if row.sort_keys and row.sort_keys[property] ~= nil then
    return row.sort_keys[property]
  end
  return value_at(row, property)
end

local function sort_rows(rows, definition, diagnostics)
  local sort = definition.view.sort
  if sort == nil then
    return
  end
  if type(sort) ~= "table" or not vim.islist(sort) then
    diagnostics[#diagnostics + 1] = "view.sort must be a list; results retain vault path order"
    return
  end
  local specs = {}
  for _, spec in ipairs(sort) do
    if type(spec) == "table" and type(spec.property) == "string" then
      specs[#specs + 1] = {
        property = spec.property,
        descending = tostring(spec.direction or "ASC"):upper() == "DESC",
      }
    else
      diagnostics[#diagnostics + 1] = "unsupported sort entry; results retain the remaining supported sort order"
    end
  end
  table.sort(rows, function(left, right)
    for _, spec in ipairs(specs) do
      local comparison = compare_values(sort_value(left, spec.property), sort_value(right, spec.property))
      if comparison ~= 0 then
        if spec.descending then
          return comparison > 0
        end
        return comparison < 0
      end
    end
    return left.path < right.path
  end)
end

local function group_key(value)
  if value == nil or value == vim.NIL then
    return "null"
  end
  return type(value) .. ":" .. vim.json.encode(value)
end

local function group_rows(rows, definition, diagnostics)
  local spec = definition.view.groupBy
  if spec == nil then
    if definition.view.groupOrder ~= nil then
      diagnostics[#diagnostics + 1] = "groupOrder requires a supported groupBy configuration"
    end
    return nil, nil
  end
  if type(spec) ~= "table" or type(spec.property) ~= "string" then
    diagnostics[#diagnostics + 1] = "groupBy must contain a property name"
    return nil, nil
  end
  local direction = tostring(spec.direction or "ASC"):upper()
  if direction ~= "ASC" and direction ~= "DESC" then
    diagnostics[#diagnostics + 1] = "groupBy.direction must be ASC or DESC"
    return nil, nil
  end

  local buckets = {}
  for _, row in ipairs(rows) do
    local value = value_at(row, spec.property)
    if type(value) == "table" then
      diagnostics[#diagnostics + 1] = ("groupBy property %q produced a list or object; grouping is disabled"):format(
        spec.property
      )
      return nil, nil
    end
    local key = group_key(value)
    local group = buckets[key]
    if not group then
      group = {
        key = key,
        value = value,
        label = (value == nil or value == vim.NIL) and "(empty)" or display_value(value),
        rows = {},
      }
      buckets[key] = group
    end
    group.rows[#group.rows + 1] = row
  end

  local groups = {}
  local manual = definition.view.groupOrder
  if manual ~= nil then
    if type(manual) ~= "table" or not vim.islist(manual) then
      diagnostics[#diagnostics + 1] = "groupOrder must be a list"
      return nil, nil
    end
    for _, value in ipairs(manual) do
      if type(value) == "table" then
        diagnostics[#diagnostics + 1] = "groupOrder supports scalar values only"
        return nil, nil
      end
      local key = group_key(value)
      groups[#groups + 1] = buckets[key]
        or {
          key = key,
          value = value,
          label = (value == nil or value == vim.NIL) and "(empty)" or display_value(value),
          rows = {},
        }
    end
  else
    groups = vim.tbl_values(buckets)
    table.sort(groups, function(left, right)
      local comparison = compare_values(left.value, right.value)
      if comparison == 0 then
        return left.key < right.key
      end
      if direction == "DESC" then
        return comparison > 0
      end
      return comparison < 0
    end)
  end
  return groups, {
    property = spec.property,
    direction = direction,
    manual = manual ~= nil,
  }
end

local function presentation_diagnostics(definition, types_snapshot)
  local diagnostics = {}
  if types_snapshot.status == "invalid" then
    diagnostics[#diagnostics + 1] = "property type metadata is invalid: " .. types_snapshot.diagnostic
  end
  local view_type = definition.view.type
  if
    view_type ~= nil
    and view_type ~= "table"
    and view_type ~= "list"
    and view_type ~= "kanban"
    and view_type ~= "cards"
  then
    diagnostics[#diagnostics + 1] = ("view type %q is preserved and rendered read-only as a table"):format(view_type)
  end
  if
    view_type == "cards"
    and (definition.view.cardSize ~= nil or definition.view.imageFit ~= nil or definition.view.imageAspectRatio ~= nil)
  then
    diagnostics[#diagnostics + 1] =
      "cards sizing and image-layout settings are preserved; the native renderer uses fixed terminal cells"
  end
  local summaries = definition.raw.summaries
  if definition.view.summaries ~= nil or (type(summaries) == "table" and next(summaries) ~= nil) then
    diagnostics[#diagnostics + 1] = "summaries are not rendered in this initial slice"
  end
  local order = definition.view.order
  if type(order) == "table" and vim.islist(order) then
    for _, property in ipairs(order) do
      if type(property) == "string" then
        local key = vim.startswith(property, "note.") and property:sub(6) or property
        local unknown = types_snapshot.unknown[key]
        if unknown then
          diagnostics[#diagnostics + 1] = ("property %q declares unsupported type %q; using value-shape fallback"):format(
            key,
            unknown
          )
        end
      end
    end
  end
  return diagnostics
end

---@class obsidian.bases.Query
---@field definition obsidian.bases.Definition
---@field context table
---@field callback fun(result: obsidian.bases.Result)
---@field serial integer
---@field current obsidian.bases.Result|nil
---@field request { cancel: (fun())|nil }|nil
local Query = {}
Query.__index = Query

---@param self obsidian.bases.Query
local function cancel_request(self)
  local request = self.request
  self.request = nil
  if request and request.cancel then
    request.cancel()
  end
end

local function backend_info()
  local status = worker.status()
  return { name = status.name, version = status.version }, status
end

local function comparison_snapshot(definition, context, types_snapshot, rows)
  local unsaved_note_overlays = false
  for _, row in ipairs(rows or {}) do
    if row.revision and row.revision.kind == "buffer" then
      unsaved_note_overlays = true
      break
    end
  end
  local context_dependent = context and context.path ~= nil
  if context_dependent and definition.path then
    context_dependent = vim.fs.normalize(context.path) ~= vim.fs.normalize(definition.path)
  end
  return {
    definition_path = definition.path,
    definition_revision = definition.revision,
    definition_revision_kind = type(definition.revision) == "string" and "disk" or "buffer",
    embedded = definition.path == nil,
    context_path = context and context.path or nil,
    context_revision = context and context.revision or nil,
    context_dependent = context_dependent,
    property_types_path = types_snapshot.path,
    property_types_revision = vim.deepcopy(types_snapshot.revision),
    unsaved_note_overlays = unsaved_note_overlays,
  }
end

function Query:refresh()
  self.serial = self.serial + 1
  cancel_request(self)
  local serial = self.serial
  local backend, backend_status = backend_info()
  local scope_opts = {
    vault = self.context.vault,
    config_dir = self.context.config_dir,
    ignore_filters = self.context.ignore_filters,
  }
  local types_snapshot = property_types.get(scope_opts)
  self.context.property_types_revision = types_snapshot.revision
  local result_columns = columns(self.definition, types_snapshot)
  if self.current then
    self.callback(model.stale(self.current, "refreshing"))
  else
    self.callback {
      identity = model.identity(self.definition, self.context, backend),
      status = "refreshing",
      freshness = "current",
      completeness = "partial",
      backend = backend,
      view_name = self.definition.view_name,
      columns = result_columns,
      rows = {},
      diagnostics = {},
      source_count = 0,
      matched_count = 0,
    }
  end

  if not backend_status.available then
    local message = assert(backend_status.error).message
    if self.current then
      self.callback(model.stale(self.current, "backend_unavailable", message))
    else
      self.callback {
        identity = model.identity(self.definition, self.context, backend),
        status = "backend_unavailable",
        freshness = "current",
        completeness = "unsupported",
        backend = backend,
        view_name = self.definition.view_name,
        columns = result_columns,
        rows = {},
        diagnostics = { message },
        source_count = 0,
        matched_count = 0,
      }
    end
    return
  end

  source.collect(function(rows, limitations)
    if self.serial ~= serial then
      return
    end
    local this_file
    if self.context and self.context.path then
      local context_path = vim.fs.normalize(self.context.path)
      for _, row in ipairs(rows) do
        if vim.fs.normalize(row.path) == context_path then
          this_file = vim.deepcopy(row.file)
          break
        end
      end
      this_file = this_file or source.context_file(self.context.path, scope_opts)
    end
    local request = {}
    self.request = request
    request.cancel = worker.evaluate({
      global_filter = self.definition.filters,
      view_filter = self.definition.view.filters,
      formulas = self.definition.formulas,
      rows = rows,
      this_file = this_file,
      property_types = types_snapshot.evaluator_types,
      sort_properties = sort_properties(self.definition),
    }, function(evaluated, err)
      if self.serial ~= serial or self.request ~= request then
        return
      end
      self.request = nil
      if err or not evaluated then
        local message = err and err.message or "evaluator returned no result"
        if self.current then
          self.callback(model.stale(self.current, "backend_unavailable", message))
        else
          self.callback {
            identity = model.identity(self.definition, self.context, backend),
            status = "backend_unavailable",
            freshness = "current",
            completeness = "unsupported",
            backend = backend,
            view_name = self.definition.view_name,
            columns = result_columns,
            rows = {},
            diagnostics = { message },
            source_count = #rows,
            matched_count = 0,
          }
        end
        return
      end
      if evaluated.state ~= "current" then
        local diagnostics = {}
        for _, diagnostic in ipairs(evaluated.diagnostics or {}) do
          diagnostics[#diagnostics + 1] = diagnostic.message or tostring(diagnostic)
        end
        if self.current then
          local stale = model.stale(self.current, "unsupported")
          vim.list_extend(stale.diagnostics, diagnostics)
          self.callback(stale)
        else
          self.callback {
            identity = model.identity(self.definition, self.context, backend),
            status = "unsupported",
            freshness = "current",
            completeness = "unsupported",
            backend = backend,
            view_name = self.definition.view_name,
            columns = result_columns,
            rows = {},
            diagnostics = diagnostics,
            source_count = #rows,
            matched_count = 0,
          }
        end
        return
      end

      local matched = {}
      for _, match in ipairs(evaluated.matches or {}) do
        local row = rows[match.index + 1]
        if row then
          row = vim.deepcopy(row)
          row.formulas = match.formulas or {}
          row.sort_keys = match.sort_keys or {}
          matched[#matched + 1] = row
        end
      end
      local diagnostics = presentation_diagnostics(self.definition, types_snapshot)
      sort_rows(matched, self.definition, diagnostics)
      local limit = tonumber(self.definition.view.limit)
      if limit then
        limit = math.floor(limit)
        if limit >= 0 and #matched > limit then
          matched = vim.list_slice(matched, 1, limit)
        end
      end
      local groups, grouping = group_rows(matched, self.definition, diagnostics)
      if self.definition.view.type == "kanban" and groups == nil then
        diagnostics[#diagnostics + 1] = "kanban rendering requires a supported scalar groupBy; using table fallback"
      end
      vim.list_extend(diagnostics, limitations)
      for _, row in ipairs(matched) do
        row.cells = {}
        for _, column in ipairs(result_columns) do
          row.cells[#row.cells + 1] = display_value(value_at(row, column.property))
        end
      end
      local result = {
        identity = model.identity(self.definition, self.context, backend),
        status = "ready",
        freshness = "current",
        completeness = #diagnostics == 0 and "complete" or "partial",
        backend = backend,
        view_name = self.definition.view_name,
        view_type = self.definition.view.type or "table",
        view = vim.deepcopy(self.definition.view),
        columns = result_columns,
        rows = matched,
        groups = groups,
        grouping = grouping,
        diagnostics = diagnostics,
        source_count = #rows,
        matched_count = #(evaluated.matches or {}),
        comparison_snapshot = comparison_snapshot(self.definition, self.context, types_snapshot, rows),
      }
      self.current = result
      self.callback(result)
    end)
  end, vim.tbl_extend("force", dependencies.for_definition(self.definition), scope_opts))
end

function Query:dispose()
  self.serial = self.serial + 1
  cancel_request(self)
end

---@param definition obsidian.bases.Definition
---@param context table|nil
---@param callback fun(result: obsidian.bases.Result)
---@return obsidian.bases.Query
function M.new(definition, context, callback)
  return setmetatable({
    definition = definition,
    context = context or {},
    callback = callback,
    serial = 0,
    current = nil,
    request = nil,
  }, Query)
end

M.value_at = value_at
M.display_value = display_value

return M
