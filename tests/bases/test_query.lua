local definition = require "obsidian.bases.definition"
local query = require "obsidian.bases.query"
local property_types = require "obsidian.properties.types"
local source = require "obsidian.bases.source"
local worker = require "obsidian.bases.worker"

local eq = MiniTest.expect.equality

local original_types_get = property_types.get
local original_collect = source.collect
local original_context_file = source.context_file
local original_status = worker.status
local original_evaluate = worker.evaluate

local function restore()
  property_types.get = original_types_get
  source.collect = original_collect
  source.context_file = original_context_file
  worker.status = original_status
  worker.evaluate = original_evaluate
end

local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      Obsidian = Obsidian or {}
      Obsidian.dir = "/vault"
      property_types.get = function()
        return {
          status = "missing",
          revision = { kind = "missing" },
          types = {},
          families = {},
          evaluator_types = {},
          unknown = {},
        }
      end
      worker.status = function()
        return { available = true, name = "test", version = "1" }
      end
      source.context_file = function(path)
        return { path = path, folder = vim.fs.dirname(path) }
      end
    end,
    post_case = restore,
  },
}

local rows = {
  { path = "/vault/B.md", note = { priority = 2 }, file = { path = "B.md", name = "B" } },
  { path = "/vault/A.md", note = { priority = 1 }, file = { path = "A.md", name = "A" } },
}

local function parsed(lines)
  local value, err = definition.parse(lines, { path = "/vault/Test.base", revision = 1 })
  assert(value, err)
  return value
end

T["sorts supported properties and builds display columns"] = function()
  source.collect = function(callback)
    callback(vim.deepcopy(rows), { "markdown-only source" })
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0 }, { index = 1 } }, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(
    parsed {
      "properties:",
      "  priority:",
      "    displayName: Priority",
      "views:",
      "  - name: Sorted",
      "    type: table",
      "    order: [file.name, priority]",
      "    sort:",
      "      - property: priority",
      "        direction: ASC",
    },
    nil,
    function(result)
      results[#results + 1] = result
    end
  )
  instance:refresh()

  local result = results[#results]
  eq("ready", result.status)
  eq("partial", result.completeness)
  eq({ "A", "1" }, result.rows[1].cells)
  eq("Priority", result.columns[2].label)
end

T["passes declared property types to columns and the evaluator"] = function()
  property_types.get = function()
    return {
      status = "current",
      revision = { kind = "disk", size = 1 },
      types = { due = "date" },
      families = { due = "date" },
      evaluator_types = { due = "date" },
      unknown = {},
    }
  end
  source.collect = function(callback)
    callback({ { path = "/vault/A.md", note = { due = "2026-01-02" }, file = { path = "A.md" } } }, {})
  end
  local request
  worker.evaluate = function(params, callback)
    request = params
    callback({ state = "current", matches = { { index = 0 } }, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(
    parsed {
      "views:",
      "  - name: Dates",
      "    type: table",
      "    order: [due]",
    },
    nil,
    function(result)
      results[#results + 1] = result
    end
  )
  instance:refresh()

  local result = results[#results]
  eq("date", result.columns[1].type)
  eq("date", result.columns[1].declared_type)
  eq({ due = "date" }, request.property_types)
end

T["pins source types context and result identity to the query scope"] = function()
  local received = {}
  property_types.get = function(opts)
    received.types = vim.deepcopy(opts)
    return {
      status = "current",
      revision = { kind = "disk", size = 1 },
      types = {},
      families = {},
      evaluator_types = {},
      unknown = {},
    }
  end
  source.collect = function(callback, opts)
    received.source = vim.deepcopy(opts)
    callback({ { path = "/vault-a/A.md", note = {}, file = { path = "A.md" } } }, {})
  end
  source.context_file = function(path, opts)
    received.context = { path = path, opts = vim.deepcopy(opts) }
    return { path = "Context.md" }
  end
  worker.evaluate = function(params, callback)
    received.this_file = params.this_file
    callback({ state = "current", matches = { { index = 0 } }, diagnostics = {} }, nil)
  end

  local result
  query
    .new(
      parsed {
        "views:",
        "  - name: Scoped",
        "    type: table",
      },
      {
        path = "/vault-a/Context.md",
        vault = "/vault-a",
        config_dir = ".meta-a",
        ignore_filters = { "private/**" },
      },
      function(value)
        result = value
      end
    )
    :refresh()

  eq({ vault = "/vault-a", config_dir = ".meta-a", ignore_filters = { "private/**" } }, received.types)
  eq("/vault-a", received.source.vault)
  eq(".meta-a", received.source.config_dir)
  eq({ "private/**" }, received.source.ignore_filters)
  eq("/vault-a/Context.md", received.context.path)
  eq(".meta-a", received.context.opts.config_dir)
  eq({ path = "Context.md" }, received.this_file)
  local identity = vim.json.decode(result.identity)
  eq("/vault-a", identity.vault)
  eq(".meta-a", identity.config_dir)
  eq({ "private/**" }, identity.ignore_filters)
end

T["preserves empty collection identity in evaluator JSON"] = function()
  source.collect = function(callback)
    callback({
      {
        path = "/vault/A.md",
        note = { empty_object = vim.empty_dict(), empty_list = {} },
        file = { path = "A.md", name = "A" },
      },
    }, {})
  end
  local encoded
  worker.evaluate = function(params, callback)
    encoded = vim.json.decode(vim.json.encode(params))
    callback({ state = "current", matches = { { index = 0 } }, diagnostics = {} }, nil)
  end

  local result
  query
    .new(
      parsed {
        "formulas: {}",
        "views:",
        "  - name: Collections",
        "    type: table",
        "    order: [file.name]",
      },
      nil,
      function(value)
        result = value
      end
    )
    :refresh()

  eq(false, vim.islist(encoded.formulas))
  eq("{}", vim.json.encode(encoded.formulas))
  eq(false, vim.islist(encoded.rows[1].note.empty_object))
  eq("{}", vim.json.encode(encoded.rows[1].note.empty_object))
  eq(true, vim.islist(encoded.rows[1].note.empty_list))
  eq("[]", vim.json.encode(encoded.rows[1].note.empty_list))
  eq("ready", result.status)
end

T["requests backlinks only for dependent definitions"] = function()
  local collected_opts = {}
  source.collect = function(callback, opts)
    collected_opts[#collected_opts + 1] = opts
    callback({
      {
        path = "/vault/A.md",
        note = {},
        file = { path = "A.md", backlinks = opts.backlinks and { { path = "B.md" } } or nil },
      },
    }, {})
  end
  local requests = {}
  worker.evaluate = function(request, callback)
    requests[#requests + 1] = request
    callback({ state = "current", matches = {}, diagnostics = {} }, nil)
  end

  query
    .new(
      parsed {
        "views:",
        "  - name: Ordinary",
        "    type: table",
        "    order: [file.name]",
      },
      nil,
      function() end
    )
    :refresh()
  query
    .new(
      parsed {
        "filters: 'file.backlinks.length > 0'",
        "views:",
        "  - name: Incoming",
        "    type: table",
        "    order: [file.name, file.backlinks]",
      },
      { path = "/vault/A.md" },
      function() end
    )
    :refresh()

  eq(false, collected_opts[1].backlinks)
  eq(true, collected_opts[2].backlinks)
  eq({ { path = "B.md" } }, requests[2].this_file.backlinks)
  eq("B.md", query.display_value { { path = "B.md" } })
end

T["groups scalar values with direction and empty values"] = function()
  local grouped_rows = {
    { path = "/vault/A.md", note = { status = "Planned" }, file = { path = "A.md", name = "A" } },
    { path = "/vault/B.md", note = { status = "Done" }, file = { path = "B.md", name = "B" } },
    { path = "/vault/C.md", note = {}, file = { path = "C.md", name = "C" } },
  }
  source.collect = function(callback)
    callback(grouped_rows, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0 }, { index = 1 }, { index = 2 } }, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(
    parsed {
      "views:",
      "  - name: Grouped",
      "    type: list",
      "    order: [file.name, status]",
      "    groupBy:",
      "      property: status",
      "      direction: ASC",
    },
    nil,
    function(result)
      results[#results + 1] = result
    end
  )
  instance:refresh()

  local result = results[#results]
  eq(
    { "Done", "Planned", "(empty)" },
    vim.tbl_map(function(group)
      return group.label
    end, result.groups)
  )
  eq("B", result.groups[1].rows[1].file.name)
  eq("list", result.view_type)
end

T["honors manual group order including empty declared groups"] = function()
  source.collect = function(callback)
    callback({ { path = "/vault/A.md", note = { status = "Done" }, file = { path = "A.md", name = "A" } } }, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0 } }, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(
    parsed {
      "views:",
      "  - name: Manual",
      "    type: table",
      "    order: [file.name, status]",
      "    groupBy:",
      "      property: status",
      "      direction: DESC",
      "    groupOrder: [Blocked, Done]",
    },
    nil,
    function(result)
      results[#results + 1] = result
    end
  )
  instance:refresh()

  local groups = results[#results].groups
  eq({ "Blocked", "Done" }, { groups[1].label, groups[2].label })
  eq(0, #groups[1].rows)
  eq(1, #groups[2].rows)
end

T["disables unsupported list grouping explicitly"] = function()
  source.collect = function(callback)
    callback({ { path = "/vault/A.md", note = { tags = { "one" } }, file = { path = "A.md" } } }, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0 } }, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(
    parsed {
      "views:",
      "  - name: Unsupported",
      "    type: list",
      "    order: [file.name, tags]",
      "    groupBy:",
      "      property: tags",
    },
    nil,
    function(result)
      results[#results + 1] = result
    end
  )
  instance:refresh()

  local result = results[#results]
  eq(nil, result.groups)
  eq(
    true,
    vim.iter(result.diagnostics):any(function(message)
      return message:find("produced a list or object", 1, true) ~= nil
    end)
  )
end

T["preserves cards view configuration for the native renderer"] = function()
  source.collect = function(callback)
    callback({ { path = "/vault/A.md", note = {}, file = { path = "A.md", name = "A" } } }, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0 } }, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(
    parsed {
      "views:",
      "  - name: Gallery",
      "    type: cards",
      "    order: [file.name]",
      "    image: cover",
      "    cardSize: 240",
    },
    nil,
    function(result)
      results[#results + 1] = result
    end
  )
  instance:refresh()

  local result = results[#results]
  eq("cards", result.view_type)
  eq("cover", result.view.image)
  eq(240, result.view.cardSize)
end

T["falls back honestly when kanban grouping is unavailable"] = function()
  source.collect = function(callback)
    callback({ { path = "/vault/A.md", note = {}, file = { path = "A.md", name = "A" } } }, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0 } }, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(
    parsed {
      "views:",
      "  - name: Board",
      "    type: kanban",
      "    order: [file.name]",
    },
    nil,
    function(result)
      results[#results + 1] = result
    end
  )
  instance:refresh()

  local result = results[#results]
  eq(nil, result.groups)
  eq("kanban", result.view_type)
  eq(
    true,
    vim.iter(result.diagnostics):any(function(message)
      return message:find("kanban rendering requires", 1, true) ~= nil
    end)
  )
end

T["rejects late refresh results"] = function()
  local callbacks = {}
  source.collect = function(callback)
    callbacks[#callbacks + 1] = callback
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = {}, diagnostics = {} }, nil)
  end
  local results = {}
  local instance = query.new(parsed { "views:", "  - name: Table", "    type: table" }, nil, function(result)
    results[#results + 1] = result
  end)

  instance:refresh()
  instance:refresh()
  callbacks[1](rows, {})
  eq("refreshing", results[#results].status)
  callbacks[2](rows, {})
  eq("ready", results[#results].status)
end

T["cancels obsolete evaluator requests and disposal"] = function()
  source.collect = function(callback)
    callback(rows, {})
  end
  local requests = {}
  worker.evaluate = function(_, callback)
    local request = { callback = callback, cancelled = false }
    requests[#requests + 1] = request
    return function()
      request.cancelled = true
    end
  end
  local results = {}
  local instance = query.new(parsed { "views:", "  - name: Table", "    type: table" }, nil, function(result)
    results[#results + 1] = result
  end)

  instance:refresh()
  instance:refresh()
  eq(true, requests[1].cancelled)
  requests[1].callback({ state = "current", matches = {}, diagnostics = {} }, nil)
  eq("refreshing", results[#results].status)
  requests[2].callback({ state = "current", matches = {}, diagnostics = {} }, nil)
  eq("ready", results[#results].status)

  instance:refresh()
  instance:dispose()
  eq(true, requests[3].cancelled)
end

T["reports evaluator timeouts as backend errors"] = function()
  source.collect = function(callback)
    callback(rows, {})
  end
  worker.evaluate = function(_, callback)
    callback(nil, { kind = "timeout", message = "Bases evaluator timed out after 25ms" })
  end
  local results = {}
  query
    .new(parsed { "views:", "  - name: Table", "    type: table" }, nil, function(result)
      results[#results + 1] = result
    end)
    :refresh()

  local result = results[#results]
  eq("backend_unavailable", result.status)
  eq("unsupported", result.completeness)
  eq({ "Bases evaluator timed out after 25ms" }, result.diagnostics)
end

T["does not present unsupported evaluation as an empty result"] = function()
  source.collect = function(callback)
    callback(rows, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "unsupported", matches = {}, diagnostics = { { message = "unknown function" } } }, nil)
  end
  local results = {}
  local instance = query.new(parsed { "views:", "  - name: Table", "    type: table" }, nil, function(result)
    results[#results + 1] = result
  end)
  instance:refresh()

  local result = results[#results]
  eq("unsupported", result.status)
  eq("unsupported", result.completeness)
  eq({ "unknown function" }, result.diagnostics)
end

T["descending sorts and groups use a strict ordering"] = function()
  local values = { 2, 1, 3, 2 }
  source.collect = function(callback)
    local collected = {}
    for index, value in ipairs(values) do
      collected[index] = { path = "/vault/" .. index .. ".md", note = { rank = value }, file = {} }
    end
    callback(collected, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0 }, { index = 1 }, { index = 2 }, { index = 3 } } }, nil)
  end
  local result
  query
    .new(
      parsed {
        "views:",
        "  - name: Descending",
        "    sort:",
        "      - property: rank",
        "        direction: DESC",
        "    groupBy:",
        "      property: rank",
        "      direction: DESC",
      },
      nil,
      function(value)
        result = value
      end
    )
    :refresh()
  eq(
    { 3, 2, 2, 1 },
    vim.tbl_map(function(row)
      return row.note.rank
    end, result.rows)
  )
  eq(
    { 3, 2, 1 },
    vim.tbl_map(function(group)
      return group.value
    end, result.groups)
  )
  eq(
    { "/vault/1.md", "/vault/4.md" },
    vim.tbl_map(function(row)
      return row.path
    end, result.groups[2].rows)
  )
end

T["sorts mixed missing and explicit nulls with stable tie breakers"] = function()
  source.collect = function(callback)
    local collected = {}
    for index = 1, 9 do
      local note = { secondary = 10 - index }
      if index % 2 == 0 then
        note.rank = vim.NIL
      end
      if index > 7 then
        note.rank = index
      end
      collected[index] = { path = "/vault/" .. index .. ".md", note = note, file = {} }
    end
    callback(collected, {})
  end
  worker.evaluate = function(params, callback)
    local matches = {}
    for index in ipairs(params.rows) do
      matches[#matches + 1] = { index = index - 1 }
    end
    callback({ state = "current", matches = matches }, nil)
  end
  for _, direction in ipairs { "ASC", "DESC" } do
    for _, secondary in ipairs { false, true } do
      local def = parsed {
        "views:",
        "  - name: Nullable",
        "    sort:",
        "      - property: rank",
        "        direction: " .. direction,
      }
      if secondary then
        def.view.sort[#def.view.sort + 1] = { property = "secondary", direction = "ASC" }
      end
      local result
      query
        .new(def, nil, function(value)
          result = value
        end)
        :refresh()
      eq("ready", result.status)
      local empty = secondary and { 7, 6, 5, 4, 3, 2, 1 } or { 1, 2, 3, 4, 5, 6, 7 }
      local expected = direction == "ASC" and vim.list_extend({ 8, 9 }, empty) or vim.list_extend(empty, { 9, 8 })
      eq(
        vim.tbl_map(function(index)
          return "/vault/" .. index .. ".md"
        end, expected),
        vim.tbl_map(function(row)
          return row.path
        end, result.rows)
      )
    end
  end
end

T["preserves false formula values for display and grouping"] = function()
  eq(false, query.value_at({ formulas = { done = false } }, "formula.done"))
  source.collect = function(callback)
    callback({ { path = "/vault/A.md", note = {}, file = {} } }, {})
  end
  worker.evaluate = function(_, callback)
    callback({ state = "current", matches = { { index = 0, formulas = { done = false } } } }, nil)
  end
  local result
  query
    .new(
      parsed {
        "views:",
        "  - name: Formulas",
        "    order: [formula.done]",
        "    groupBy:",
        "      property: formula.done",
      },
      nil,
      function(value)
        result = value
      end
    )
    :refresh()
  eq({ "false" }, result.rows[1].cells)
  eq(false, result.groups[1].value)
  eq("false", result.groups[1].label)
end

return T
