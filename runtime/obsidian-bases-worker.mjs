import readline from "node:readline";
import {
  compatibilityProfile,
  compileExpression,
  compileFilter,
  compileFormulaSet,
  createFileContext,
  Evaluator,
  fromJs,
  isTruthy,
  normalizeFrontmatterProperties,
  normalizeFrontmatterValue,
  toPlain,
} from "obsidian-bases-expression";

const PROTOCOL_VERSION = 1;
const PACKAGE_VERSION = "0.2.0";

function serializeDiagnostic(diagnostic) {
  return {
    code: diagnostic?.code ?? null,
    message: diagnostic?.message ?? String(diagnostic),
    severity: diagnostic?.severity ?? "error",
    start: diagnostic?.start ?? null,
    end: diagnostic?.end ?? null,
  };
}

function combineFilters(globalFilter, viewFilter) {
  const filters = [globalFilter, viewFilter].filter(
    (filter) => filter !== null && filter !== undefined,
  );
  if (filters.length === 0) return null;
  if (filters.length === 1) return filters[0];
  return { and: filters };
}

// Version 0.2.0 can coerce nested Error values to booleans (including inside
// !, &&, ||, if(), and list predicates). Observe the nodes actually evaluated,
// rather than walking the AST eagerly and breaking short-circuit semantics.
class CheckedEvaluator extends Evaluator {
  failure;

  eval(ast, scope) {
    const value = super.eval(ast, scope);
    if (value?.type === "Error") this.failure ??= value.value.message;
    return value;
  }

  checked(ast) {
    const value = this.eval(ast);
    if (this.failure !== undefined) throw new Error(this.failure);
    return value;
  }
}

// Structured filters need the same check before combining expression leaves.
function compileFilterPredicate(filter) {
  if (filter === null || filter === undefined) return () => true;
  if (filter && typeof filter === "object" && !filter.type) {
    for (const operator of ["and", "or", "not"]) {
      if (filter[operator] === undefined) continue;
      const values = Array.isArray(filter[operator])
        ? filter[operator]
        : [filter[operator]];
      const children = values.map(compileFilterPredicate);
      if (operator === "or") {
        return (context) => children.some((child) => child(context));
      }
      const all = (context) => children.every((child) => child(context));
      return operator === "not" ? (context) => !all(context) : all;
    }
    return () => true;
  }
  const compiled = compileExpression(filter);
  return (context) => isTruthy(new CheckedEvaluator(context).checked(compiled.ast));
}

function evaluateFormulas(formulaSet, context) {
  const evaluator = new CheckedEvaluator(context);
  return Object.fromEntries(formulaSet.evaluationOrder.map((name) => [
    name,
    evaluator.checked(formulaSet.formulas[name]),
  ]));
}

// Preserve source values for editing and display, but compare dates by their
// instant, not the spelling/timezone of the original YAML or formatted formula.
function dateSortKeys(properties, context, formulas) {
  const keys = {};
  for (const property of properties) {
    let value;
    if (property.startsWith("formula.")) {
      value = formulas[property.slice(8)];
    } else if (property.startsWith("file.")) {
      value = context.file[property.slice(5)];
    } else {
      const key = property.startsWith("note.") ? property.slice(5) : property;
      value = context.note[key];
    }
    const runtime = fromJs(value);
    if (runtime.type === "Date") keys[property] = runtime.value.getTime();
  }
  return keys;
}

// Version 0.2.0 coerces a null property with a date hint to Date(0).
// Type hints describe present values; empty properties must stay runtime Nulls.
function rowPropertyTypes(note, propertyTypes, foldedTypes) {
  const declaredType = (property) =>
    Object.hasOwn(propertyTypes, property)
      ? propertyTypes[property]
      : foldedTypes.get(property.toLowerCase());
  return Object.fromEntries(
    Object.keys(note)
      .filter((property) =>
        note[property] !== null &&
        note[property] !== undefined &&
        declaredType(property) !== undefined
      )
      .map((property) => [property, declaredType(property)]),
  );
}

// Bases recognizes complete wikilinks in text and list properties without a
// dedicated property type. Keep ordinary text and non-string scalars intact.
function normalizeWikilinkProperties(properties, file, linkResolutions) {
  const resolvedLinks = new Map(
    (file.links ?? [])
      .filter((link) => link.resolvedPath != null)
      .map((link) => [link.path, link.resolvedPath]),
  );
  const normalize = (value) => {
    if (Array.isArray(value)) return value.map(normalize);
    if (typeof value !== "string" || !/^!?\[\[[^\[\]\r\n]+\]\]$/.test(value.trim())) {
      return value;
    }
    const link = normalizeFrontmatterValue(value.trim(), "link", linkResolutions);
    // Reuse source-aware resolution already supplied by the Lua snapshot,
    // including relative targets that the evaluator's global map cannot resolve.
    const resolvedPath = resolvedLinks.get(link.value.path.split("#", 1)[0]);
    if (resolvedPath !== undefined) link.value.resolvedPath = resolvedPath;
    return link;
  };
  return Object.fromEntries(
    Object.entries(properties).map(([key, value]) => [key, normalize(value)]),
  );
}

// File-property access does not consult the evaluator's row-local type hints.
// Store runtime values there (and in note properties) so all access paths share
// date/link semantics without applying a candidate row's types to another file.
// Non-date declarations select editors, not implicit query conversions: retain
// the YAML primitive/list/object type even when it disagrees with types.json.
// This makes mismatches observable and keeps string concatenation distinct from
// numeric arithmetic; explicit expression conversions remain the caller's choice.
function normalizeTypedProperties(properties, file, linkResolutions, propertyTypes) {
  const normalized = normalizeWikilinkProperties(
    normalizeFrontmatterProperties(properties, { linkResolutions, propertyTypes }),
    file,
    linkResolutions,
  );
  return Object.fromEntries(
    Object.entries(normalized).map(([key, value]) => [
      key,
      fromJs(value, propertyTypes[key] === "date" ? "date" : undefined),
    ]),
  );
}

// The package's default map overwrites duplicate aliases, and its fallback
// selects the first suffix match. Index every supported suffix ourselves, with
// explicit nulls for ambiguity and exact paths taking precedence over aliases.
function createLinkResolutions(files) {
  const aliases = Object.create(null);
  const notePaths = Object.create(null);
  const paths = Object.create(null);
  const withoutNoteExtension = (path) => path.replace(/\.(md|markdown|qmd)$/i, "");
  const add = (map, key, path) => {
    if (!key) return;
    for (const variant of new Set([key, key.toLowerCase()])) {
      map[variant] = Object.hasOwn(map, variant) && map[variant] !== path
        ? null
        : path;
    }
  };
  for (const file of files) {
    add(paths, file.path, file.path);
    add(notePaths, withoutNoteExtension(file.path), file.path);
    add(aliases, file.name, file.path);
    add(aliases, file.basename, file.path);
    const parts = file.path.split("/");
    for (let index = 0; index < parts.length; index += 1) {
      const suffix = parts.slice(index).join("/");
      add(aliases, suffix, file.path);
      add(aliases, withoutNoteExtension(suffix), file.path);
    }
  }
  return Object.assign(Object.create(null), aliases, notePaths, paths);
}

function evaluate(params) {
  const rows = Array.isArray(params.rows) ? params.rows : [];
  const combinedFilter = combineFilters(params.global_filter, params.view_filter);
  const filter = compileFilter(combinedFilter);
  const diagnostics = filter.diagnostics.map(serializeDiagnostic);
  if (!filter.valid) {
    return {
      state: "unsupported",
      matches: [],
      diagnostics,
    };
  }

  const formulas = params.formulas ?? {};
  const formulaSet = compileFormulaSet(formulas);
  diagnostics.push(...formulaSet.diagnostics.map(serializeDiagnostic));
  if (formulaSet.diagnostics.length > 0) {
    return {
      state: "unsupported",
      matches: [],
      diagnostics,
    };
  }

  const matchesFilter = compileFilterPredicate(combinedFilter);
  const sortProperties = Array.isArray(params.sort_properties)
    ? params.sort_properties.filter((property) => typeof property === "string")
    : [];

  // Match the property editor's exact-name-first, case-insensitive lookup.
  // Build the fallback once per request, not once for every vault file.
  const declaredTypes = params.property_types ?? {};
  const foldedTypes = new Map();
  for (const [property, type] of Object.entries(declaredTypes)) {
    const key = property.toLowerCase();
    if (!foldedTypes.has(key)) foldedTypes.set(key, type);
  }
  // File normalization and link resolution are vault-wide work. Rebuilding them
  // for every row makes evaluation quadratic in the number of vault files.
  const files = rows.map((row) => createFileContext({
    ...row.file,
    path: row.file?.path ?? row.path ?? "",
    properties: row.file?.properties ?? row.note ?? {},
  }));
  const linkResolutions = createLinkResolutions(files);
  const normalizeFile = (file) => {
    file.properties = normalizeTypedProperties(
      file.properties,
      file,
      linkResolutions,
      rowPropertyTypes(file.properties, declaredTypes, foldedTypes),
    );
    return file;
  };
  files.forEach(normalizeFile);
  const thisFile = params.this_file
    ? normalizeFile(createFileContext({
        ...params.this_file,
        path: params.this_file.path ?? "",
      }))
    : undefined;
  const matches = [];
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index];
    const properties = row.note ?? {};
    const propertyTypes = rowPropertyTypes(properties, declaredTypes, foldedTypes);
    const file = files[index];
    const note = normalizeTypedProperties(properties, file, linkResolutions, propertyTypes);
    const context = {
      note,
      file,
      files,
      linkResolutions,
      thisFile,
      formulas: formulaSet.formulas,
      propertyTypes,
    };
    try {
      if (matchesFilter(context)) {
        const formulaValues = evaluateFormulas(formulaSet, context);
        matches.push({
          index,
          formulas: Object.fromEntries(Object.entries(formulaValues).map(
            ([name, value]) => [name, toPlain(value)],
          )),
          sort_keys: dateSortKeys(sortProperties, context, formulaValues),
        });
      }
    } catch (error) {
      diagnostics.push(serializeDiagnostic({
        code: "runtime-error",
        message: `${file.path}: ${error instanceof Error ? error.message : String(error)}`,
      }));
    }
  }

  if (diagnostics.length > 0) {
    return {
      state: "unsupported",
      matches: [],
      diagnostics,
    };
  }

  return {
    state: "current",
    matches,
    diagnostics: [],
  };
}

function handle(request) {
  if (request.version !== PROTOCOL_VERSION) {
    throw new Error(
      `unsupported protocol version ${request.version}; expected ${PROTOCOL_VERSION}`,
    );
  }
  if (request.method === "evaluate") {
    return evaluate(request.params ?? {});
  }
  if (request.method === "capabilities") {
    return {
      protocol_version: PROTOCOL_VERSION,
      package_version: PACKAGE_VERSION,
      compatibility: compatibilityProfile,
    };
  }
  throw new Error(`unknown method: ${request.method}`);
}

const input = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

input.on("line", (line) => {
  if (!line.trim()) return;
  let request;
  try {
    request = JSON.parse(line);
    const result = handle(request);
    process.stdout.write(
      `${JSON.stringify({ id: request.id, ok: true, result })}\n`,
    );
  } catch (error) {
    process.stdout.write(
      `${JSON.stringify({
        id: request?.id ?? null,
        ok: false,
        error: {
          message: error instanceof Error ? error.message : String(error),
        },
      })}\n`,
    );
  }
});
