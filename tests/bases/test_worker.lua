local worker = require "obsidian.bases.worker"

local eq = MiniTest.expect.equality
local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      worker._set_paths(nil)
    end,
    post_case = function()
      worker._set_paths(nil)
    end,
  },
}

local function evaluate(params, timeout)
  local done, result, err = false, nil, nil
  worker.evaluate(params, function(value, failure)
    result, err, done = value, failure, true
  end)
  eq(
    true,
    vim.wait(timeout or 3000, function()
      return done
    end, 10)
  )
  return result, err
end

local function fixture_paths(timeout)
  local fixture = vim.fs.joinpath(vim.uv.cwd(), "tests", "fixtures", "bases-worker-control.mjs")
  return {
    node = vim.fn.exepath "node",
    worker = fixture,
    dependency = fixture,
    request_timeout = timeout,
  }
end

local rows = {
  {
    note = { status = "active", priority = 2 },
    file = { path = "Projects/One.md", folder = "Projects", name = "One" },
  },
  {
    note = { status = "done", priority = 1 },
    file = { path = "Archive/Two.md", folder = "Archive", name = "Two" },
  },
}

T["evaluates structured filters without JavaScript eval"] = function()
  local result, err = evaluate {
    global_filter = { ["and"] = { 'status == "active"', "priority >= 2" } },
    rows = rows,
  }
  eq(nil, err)
  eq("current", result.state)
  eq(
    { 0 },
    vim.tbl_map(function(match)
      return match.index
    end, result.matches)
  )
end

T["reuses vault context without changing row-local formulas or file properties"] = function()
  local result, err = evaluate {
    global_filter = 'file.properties.status == "active" && formula.score == 4',
    formulas = { score = "priority * 2" },
    rows = rows,
  }
  eq(nil, err)
  eq("current", result.state)
  eq(0, result.matches[1].index)
  eq(4, result.matches[1].formulas.score)
end

T["uses declared property types during evaluation"] = function()
  local result, err = evaluate {
    global_filter = 'due < date("2026-02-01")',
    property_types = { due = "date" },
    rows = {
      {
        note = { due = "2026-01-02" },
        file = { path = "One.md", name = "One" },
      },
    },
  }
  eq(nil, err)
  eq("current", result.state)
  eq(0, result.matches[1].index)
end

T["resolves declared type names case-insensitively with exact-match precedence"] = function()
  local params = {
    property_types = { due = "date", meeting = "date" },
    rows = { { note = { Due = "2026-01-02", MEETING = "2026-01-02T03:04:05" }, file = { path = "Note.md" } } },
    global_filter = "Due.year == 2026 && MEETING.hour == 3",
    formulas = { due = "Due", missing = "due == null" },
  }
  local result, err = evaluate(params)
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)
  eq({ due = "2026-01-02", missing = true }, result.matches[1].formulas)

  params.property_types.Due = "string"
  params.global_filter = 'Due.isType("string") && MEETING.hour == 3'
  result, err = evaluate(params)
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)

  params.property_types.Due = nil
  params.rows[1].note.Due = vim.NIL
  params.global_filter = "Due == null"
  result, err = evaluate(params)
  eq(nil, err)
  eq("current", result.state)
  eq(vim.NIL, result.matches[1].formulas.due)
end

T["shares declared types across note file foreign and pinned properties"] = function()
  local properties = {
    Due = "2026-11-15",
    MEETING = "2026-11-15T03:04:05",
    empty = vim.NIL,
    literal = "2026-11-15",
    related = "[[Target]]",
  }
  local formulas = {}
  for name, receiver in pairs {
    note = "note",
    file = "file.properties",
    foreign = 'file("Other.md").properties',
    pinned = "this.file.properties",
  } do
    formulas[name .. "_date"] = receiver .. ".Due.year"
    formulas[name .. "_datetime"] = receiver .. ".MEETING.hour"
    formulas[name .. "_empty"] = receiver .. ".empty == null"
    formulas[name .. "_missing"] = receiver .. ".missing == null"
    formulas[name .. "_text"] = receiver .. '.literal.isType("string")'
    formulas[name .. "_link"] = receiver .. ".related.asFile().path"
  end
  local result, err = evaluate {
    property_types = { due = "date", meeting = "date", empty = "date", missing = "date", literal = "string" },
    rows = {
      { note = properties, file = { path = "Current.md", properties = properties } },
      -- A caller without a separate properties field still gets a typed file context.
      { note = properties, file = { path = "Other.md" } },
      { note = {}, file = { path = "Target.md" } },
    },
    this_file = { path = "Context.md", properties = properties },
    global_filter = 'file.path == "Current.md" && Due == this.file.properties.Due',
    formulas = formulas,
  }
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)
  for _, name in ipairs { "note", "file", "foreign", "pinned" } do
    local values = result.matches[1].formulas
    eq(2026, values[name .. "_date"])
    eq(3, values[name .. "_datetime"])
    eq(true, values[name .. "_empty"])
    eq(true, values[name .. "_missing"])
    eq(true, values[name .. "_text"])
    eq("Target.md", values[name .. "_link"])
  end
  eq("2026-11-15", properties.Due)
end

T["preserves YAML value types when non-date declarations disagree"] = function()
  local properties = {
    amount = "10",
    checked = "false",
    labels = "one",
    label = 12,
    flag = false,
    amounts = { 1, 2 },
  }
  local original = vim.deepcopy(properties)
  local formulas, expected = {}, {}
  for name, receiver in pairs {
    note = "note",
    file = "file.properties",
    foreign = 'file("Other.md").properties',
    pinned = "this.file.properties",
  } do
    for property, value in pairs(properties) do
      local key = name .. "_" .. property
      formulas[key] = receiver .. "." .. property
      expected[key] = value
    end
    formulas[name .. "_sum"] = receiver .. ".amount + 2"
    expected[name .. "_sum"] = "102"
    formulas[name .. "_converted_sum"] = "number(" .. receiver .. ".amount) + 2"
    expected[name .. "_converted_sum"] = 12
    formulas[name .. "_converted_list"] = "list(" .. receiver .. ".labels)"
    expected[name .. "_converted_list"] = { "one" }
    formulas[name .. "_number"] = receiver .. '.amount.isType("number")'
    expected[name .. "_number"] = false
    formulas[name .. "_boolean"] = receiver .. '.checked.isType("boolean")'
    expected[name .. "_boolean"] = false
    formulas[name .. "_list"] = receiver .. '.labels.isType("list")'
    expected[name .. "_list"] = false
    formulas[name .. "_text"] = receiver .. '.label.isType("string")'
    expected[name .. "_text"] = false
  end
  local result, err = evaluate {
    property_types = {
      amount = "number",
      checked = "boolean",
      labels = "list",
      label = "string",
      flag = "string",
      amounts = "number",
    },
    rows = {
      { note = properties, file = { path = "Current.md", properties = properties } },
      { note = properties, file = { path = "Other.md" } },
    },
    this_file = { path = "Context.md", properties = properties },
    global_filter = 'file.path == "Current.md"',
    formulas = formulas,
  }
  eq(nil, err)
  eq("current", result.state)
  eq(1, #result.matches)
  eq(expected, result.matches[1].formulas)
  eq(original, properties)
end

T["uses each file's own null and case-specific type hints"] = function()
  local result, err = evaluate {
    property_types = { due = "date", Due = "string" },
    rows = {
      { note = { due = vim.NIL }, file = { path = "Empty.md" } },
      { note = { due = "2026-11-15", Due = "2026-11-15" }, file = { path = "Dated.md" } },
    },
    this_file = { path = "Context.md", properties = { due = vim.NIL } },
    global_filter = 'file.path == "Empty.md"',
    formulas = {
      empty = "file.properties.due == null && this.file.properties.due == null",
      foreign = 'file("Dated.md").properties.due.year',
      exact = 'file("Dated.md").properties.Due.isType("string")',
    },
  }
  eq(nil, err)
  eq("current", result.state)
  eq({ empty = true, foreign = 2026, exact = true }, result.matches[1].formulas)
end

T["preserves explicit null and missing declared dates in filters and formulas"] = function()
  local params = {
    property_types = { due = "date", meeting = "date" },
    rows = {
      { note = { due = vim.NIL, meeting = vim.NIL }, file = { path = "Empty.md" } },
      { note = {}, file = { path = "Missing.md" } },
      { note = { due = "2026-01-02", meeting = "2026-01-02T03:04:05" }, file = { path = "Dated.md" } },
    },
    formulas = { due = "due", meeting = "note.meeting", empty = "due == null", present = "!!due" },
  }
  local result, err = evaluate(params)
  eq(nil, err)
  eq("current", result.state)
  eq(3, #result.matches)
  for index = 1, 2 do
    eq({ due = vim.NIL, meeting = vim.NIL, empty = true, present = false }, result.matches[index].formulas)
  end
  eq("2026-01-02", result.matches[3].formulas.due)
  eq("2026-01-02T03:04:05", result.matches[3].formulas.meeting)
  eq(false, result.matches[3].formulas.empty)
  eq(true, result.matches[3].formulas.present)

  params.global_filter = "due == null && meeting == null"
  result, err = evaluate(params)
  eq(nil, err)
  eq("current", result.state)
  eq(
    { 0, 1 },
    vim.tbl_map(function(match)
      return match.index
    end, result.matches)
  )
end

T["recognizes wikilink scalars and list items without changing ordinary values"] = function()
  for _, types in ipairs { {}, { related = "string", mixed = "list" } } do
    local result, err = evaluate {
      property_types = types,
      rows = {
        {
          note = {
            related = "[[B]]",
            mixed = { "[[B|Alias]]", "plain", 3, false, vim.NIL },
            prose = "see [[B]] here",
            bare = "B",
            malformed = "[[B]",
          },
          file = { path = "A.md" },
        },
        { note = {}, file = { path = "B.md", properties = { related = "[[A]]" } } },
      },
      this_file = { path = "Context.md", properties = { related = "[[B]]" } },
      global_filter = 'related == link("B") && mixed.contains(link("B"))',
      formulas = {
        target = "related.asFile().path",
        file_target = "file.properties.related.asFile().path",
        context_target = "this.file.properties.related.asFile().path",
        other_target = 'file("B.md").properties.related.asFile().path',
        link_items = 'mixed.map(value.isType("link"))',
        plain = 'prose.isType("string") && bare.isType("string") && malformed.isType("string")',
        serialized = "mixed",
      },
    }
    eq(nil, err)
    eq("current", result.state)
    eq(1, #result.matches)
    eq(0, result.matches[1].index)
    eq({
      target = "B.md",
      file_target = "B.md",
      context_target = "B.md",
      other_target = "A.md",
      link_items = { true, false, false, false, false },
      plain = true,
      serialized = { "B", "plain", 3, false, vim.NIL },
    }, result.matches[1].formulas)
  end
end

T["resolves exact paths ahead of aliases independently of file order"] = function()
  local candidates = {
    { file = { path = "Target.md" } },
    { file = { path = "Nested/Target.md" } },
    { file = { path = "A/Guide.markdown" } },
    { file = { path = "Z/Guide.qmd" } },
    { file = { path = "Files/Report.qmd" } },
  }
  for _, ordered in ipairs { candidates, vim.fn.reverse(vim.deepcopy(candidates)) } do
    local result, err = evaluate {
      rows = ordered,
      global_filter = 'file.path == "Target.md"',
      formulas = {
        root = 'link("Target.md").asFile().path',
        root_without_extension = 'link("Target").asFile().path',
        nested = 'link("Nested/Target").asFile().path',
        ambiguous = 'link("Guide").asFile() == null',
        explicit_extension = 'link("Guide.qmd").asFile().path',
        unique = 'link("Files/Report").asFile().path',
      },
    }
    eq(nil, err)
    eq("current", result.state)
    eq(1, #result.matches)
    eq({
      root = "Target.md",
      root_without_extension = "Target.md",
      nested = "Nested/Target.md",
      ambiguous = true,
      explicit_extension = "Z/Guide.qmd",
      unique = "Files/Report.qmd",
    }, result.matches[1].formulas)
  end
end

T["pins distinct this.file contexts"] = function()
  local projects = evaluate {
    global_filter = "file.folder == this.file.folder",
    this_file = { path = "Projects/Context.md", folder = "Projects" },
    rows = rows,
  }
  local archive = evaluate {
    global_filter = "file.folder == this.file.folder",
    this_file = { path = "Archive/Context.md", folder = "Archive" },
    rows = rows,
  }
  eq(0, projects.matches[1].index)
  eq(1, archive.matches[1].index)
end

T["keeps unsupported evaluation distinct from empty results"] = function()
  local empty = evaluate { global_filter = 'status == "missing"', rows = rows }
  eq("current", empty.state)
  eq(0, #empty.matches)

  local unsupported = evaluate { global_filter = "status ==", rows = rows }
  eq("unsupported", unsupported.state)
  eq(0, #unsupported.matches)
  eq(true, #unsupported.diagnostics > 0)
end

T["rejects runtime errors in expressions structured filters and formulas"] = function()
  for _, params in ipairs {
    { global_filter = "nonexistentFunction()" },
    { global_filter = { ["not"] = { "nonexistentFunction()" } } },
    { global_filter = { ["and"] = { "true", { ["or"] = { "nonexistentFunction()", "true" } } } } },
    { global_filter = "true", view_filter = "nonexistentFunction()" },
    { formulas = { broken = "nonexistentFunction()" } },
    { formulas = { broken = "nonexistentFunction()" }, global_filter = { ["not"] = "formula.broken" } },
  } do
    params.rows = rows
    local result, err = evaluate(params)
    eq(nil, err)
    eq("unsupported", result.state)
    eq({}, result.matches)
    eq("runtime-error", result.diagnostics[1].code)
    eq(true, result.diagnostics[1].message:find("nonexistentFunction", 1, true) ~= nil)
  end
  local recovered, err = evaluate { rows = rows }
  eq(nil, err)
  eq("current", recovered.state)
  eq(2, #recovered.matches)
end

T["rejects evaluated errors before expression operators can coerce them"] = function()
  for _, expression in ipairs {
    "!nonexistentFunction()",
    "true && nonexistentFunction()",
    "nonexistentFunction() || true",
    "nonexistentFunction() && false",
    "if(nonexistentFunction(), true, false)",
    "list(1).filter(!nonexistentFunction())",
  } do
    for _, location in ipairs { "global_filter", "view_filter", "formula" } do
      local params = { rows = rows }
      if location == "formula" then
        params.formulas = { broken = expression, dependent = "!formula.broken" }
      else
        params[location] = expression
      end
      local result, err = evaluate(params)
      eq(nil, err)
      eq("unsupported", result.state)
      eq({}, result.matches)
      eq("runtime-error", result.diagnostics[1].code)
      eq(true, result.diagnostics[1].message:find("nonexistentFunction", 1, true) ~= nil)
    end
  end
end

T["does not evaluate short-circuited expression branches"] = function()
  for _, case in ipairs {
    { "false && nonexistentFunction()", false },
    { "true || nonexistentFunction()", true },
    { "if(true, true, nonexistentFunction())", true },
    { "if(false, nonexistentFunction(), false)", false },
    { "[].filter(nonexistentFunction()).isEmpty()", true },
  } do
    local result, err = evaluate { rows = rows, global_filter = case[1] }
    eq(nil, err)
    eq("current", result.state)
    eq({}, result.diagnostics)
    eq(case[2] and 2 or 0, #result.matches)
    result, err = evaluate { rows = rows, formulas = { safe = case[1] } }
    eq(nil, err)
    eq("current", result.state)
    eq({}, result.diagnostics)
    eq(case[2], result.matches[1].formulas.safe)
  end
  -- A row with an evaluated error must not make later requests fail.
  local result, err = evaluate { rows = rows, global_filter = "true" }
  eq(nil, err)
  eq("current", result.state)
  eq(2, #result.matches)
end

T["preserves structured-filter short circuiting around unused errors"] = function()
  for _, filter in ipairs {
    { ["and"] = { "false", "nonexistentFunction()" } },
    { ["not"] = { "false", "nonexistentFunction()" } },
    { ["or"] = { "true", "nonexistentFunction()" } },
  } do
    local result, err = evaluate { global_filter = filter, rows = rows }
    eq(nil, err)
    eq("current", result.state)
    eq({}, result.diagnostics)
    eq(filter["and"] and 0 or 2, #result.matches)
  end
end

T["reports a missing evaluator runtime"] = function()
  worker._set_paths {
    node = "/missing/node",
    worker = "/missing/worker.mjs",
    dependency = "/missing/package.json",
  }
  local status = worker.status()
  eq(false, status.available)
  eq("missing_runtime", status.error.kind)
end

T["cancels delayed callbacks and ignores late responses"] = function()
  worker._set_paths(fixture_paths(500))
  local keeper, keeper_err, calls
  worker.evaluate({ fixture = "delay", delay = 120 }, function(result, err)
    keeper, keeper_err = result, err
  end)
  local cancel = worker.evaluate({ fixture = "delay", delay = 50 }, function()
    calls = (calls or 0) + 1
  end)
  cancel()

  eq(
    true,
    vim.wait(1000, function()
      return keeper ~= nil or keeper_err ~= nil
    end, 10)
  )
  eq(nil, keeper_err)
  eq("delay", keeper.fixture)
  eq(nil, calls)

  local result, err = evaluate { fixture = "recovered" }
  eq(nil, err)
  eq("recovered", result.fixture)
end

T["cancelling the only blocked request restarts the worker"] = function()
  worker._set_paths(fixture_paths(1000))
  local calls = 0
  local cancel = worker.evaluate({ fixture = "hang" }, function()
    calls = calls + 1
  end)
  cancel()

  local result, err = evaluate({ fixture = "recovered" }, 2000)
  eq(nil, err)
  eq("recovered", result.fixture)
  eq(0, calls)
end

T["times out a blocked worker, fails queued work, and recovers"] = function()
  worker._set_paths(fixture_paths(500))
  local completed = {}
  worker.evaluate({ fixture = "hang" }, function(_, err)
    completed.hang = err
  end)
  worker.evaluate({ fixture = "queued" }, function(_, err)
    completed.queued = err
  end)

  eq(
    true,
    vim.wait(2000, function()
      return completed.hang ~= nil and completed.queued ~= nil
    end, 10)
  )
  eq("timeout", completed.hang.kind)
  eq(true, completed.hang.message:find("500ms", 1, true) ~= nil)
  eq("worker_failure", completed.queued.kind)
  eq(true, completed.queued.message:find("restarted", 1, true) ~= nil)

  local result, err = evaluate({ fixture = "recovered" }, 2000)
  eq(nil, err)
  eq("recovered", result.fixture)
end

T["cleans up after worker crashes and starts a replacement"] = function()
  worker._set_paths(fixture_paths(1000))
  local _, crash = evaluate({ fixture = "crash" }, 2000)
  eq("worker_failure", crash.kind)
  eq(true, crash.message:find("code 7", 1, true) ~= nil)
  eq(true, crash.message:find("controlled fixture crash", 1, true) ~= nil)

  local result, err = evaluate({ fixture = "recovered" }, 2000)
  eq(nil, err)
  eq("recovered", result.fixture)
end

T["stopping fails active requests without reviving cancelled callbacks"] = function()
  worker._set_paths(fixture_paths(1000))
  local stopped, cancelled_calls
  worker.evaluate({ fixture = "delay", delay = 500 }, function(_, err)
    stopped = err
  end)
  local cancel = worker.evaluate({ fixture = "delay", delay = 500 }, function()
    cancelled_calls = (cancelled_calls or 0) + 1
  end)
  cancel()
  worker.stop()

  eq(
    true,
    vim.wait(1000, function()
      return stopped ~= nil
    end, 10)
  )
  eq("worker_failure", stopped.kind)
  eq("Bases evaluator stopped", stopped.message)
  vim.wait(50, function()
    return cancelled_calls ~= nil
  end, 10)
  eq(nil, cancelled_calls)
end

return T
