local api = require("obsidian").api

---@param params lsp.DefinitionParams
---@param handler fun(_:any, locations: lsp.Location[])
return function(params, handler)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local bases = require("obsidian.bases.workspace").row_at_position(bufnr, params.position)
  if bases then
    return handler(nil, {
      {
        uri = vim.uri_from_fname(bases.path),
        range = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 0 },
        },
      },
    })
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
