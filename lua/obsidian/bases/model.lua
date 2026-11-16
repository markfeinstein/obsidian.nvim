local M = {}

---@alias obsidian.bases.ResultStatus "refreshing"|"ready"|"invalid"|"backend_unavailable"|"unsupported"
---@alias obsidian.bases.ResultFreshness "current"|"stale"
---@alias obsidian.bases.ResultCompleteness "complete"|"partial"|"unsupported"

---@class obsidian.bases.Result
---@field identity string
---@field status obsidian.bases.ResultStatus
---@field freshness obsidian.bases.ResultFreshness
---@field completeness obsidian.bases.ResultCompleteness
---@field backend { name: string, version: string }
---@field view_name string
---@field view_type string|nil
---@field view table|nil
---@field columns table[]
---@field rows table[]
---@field groups table[]|nil
---@field grouping table|nil
---@field diagnostics string[]
---@field source_count integer
---@field matched_count integer
---@field comparison_snapshot table|nil

---@param definition obsidian.bases.Definition
---@param context table
---@param backend table
---@return string
function M.identity(definition, context, backend)
  return vim.json.encode {
    vault = context and context.vault or vim.fs.normalize(tostring(Obsidian.dir)),
    config_dir = context and context.config_dir or nil,
    ignore_filters = context and context.ignore_filters or nil,
    definition = definition.identity,
    definition_revision = definition.revision,
    view = definition.view_name,
    context = context and context.path or nil,
    context_revision = context and context.revision or nil,
    property_types_revision = context and context.property_types_revision or nil,
    backend = backend.name,
    backend_version = backend.version,
  }
end

---@param result obsidian.bases.Result
---@param status obsidian.bases.ResultStatus
---@param diagnostic string|nil
---@return obsidian.bases.Result
function M.stale(result, status, diagnostic)
  local stale = vim.deepcopy(result)
  stale.status = status
  stale.freshness = "stale"
  if diagnostic then
    stale.diagnostics[#stale.diagnostics + 1] = diagnostic
  end
  return stale
end

return M
