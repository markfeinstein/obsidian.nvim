local api = require("obsidian").api

local function file_location(path)
  return {
    uri = vim.uri_from_fname(path),
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 0 },
    },
  }
end

---@param params lsp.DefinitionParams
---@param handler fun(_:any, locations: lsp.Location[])
return function(params, handler)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local inline_path = require("obsidian.bases.inline").definition_path(bufnr, params.position)
  if inline_path then
    return handler(nil, { file_location(inline_path) })
  end

  local bases = require("obsidian.bases.workspace").row_at_position(bufnr, params.position)
  if bases then
    return handler(nil, { file_location(bases.path) })
  end

  local link, _, range = api.cursor_link(bufnr, params.position)
  if not link then
    return handler(nil, {})
  end
  require("obsidian.lsp.handlers._definition").follow_link(link, handler, {
    range = range,
    bufnr = bufnr,
    cursor_row = params.position.line + 1,
  })
end
