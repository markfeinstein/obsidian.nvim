---
title: "Bases (experimental)"
tags:
  - bases
  - experimental
---

# Bases (experimental)

This fork contains a nightly-first, local-first Bases vertical slice. It opens a native Neovim workspace and does **not** launch or require the Obsidian desktop app. Results render read-only by default; guarded actions can prepare limited note and property-type changes in unsaved buffers. The feature remains experimental while stable-Neovim and official-CLI verification are incomplete.

## Usage

Install Node.js and the pinned evaluator dependency in the plugin checkout. For an existing installation, run:

```sh
npm install --ignore-scripts
```

For a clean checkout, CI job, or reproducible plugin-manager build, use the lockfile:

```sh
npm ci --ignore-scripts
```

Run the command from the directory containing this repository's `package-lock.json`. The dependency is required only for local Bases evaluation; without it, the workspace remains open in `backend_unavailable` state and does not invoke the Obsidian desktop app.

Then use:

```vim
:Obsidian bases Projects.base
:Obsidian bases Projects.base#Active
```

With the cursor on `![[Projects.base]]`, `![[Projects.base#Active]]`, or inside a fenced `base` block, `:Obsidian bases` opens that definition. Linked Base embeds also display a read-only virtual-line action hint. The Markdown source is not changed.

Linked targets prefer an exact file beside the containing note, then an exact vault-root path. Otherwise, shortest-path targets such as `![[Projects.base]]` or `![[Bases/Projects.base#Active]]` resolve only when a unique eligible vault file matches. The bounded fallback excludes internal, ignored, and outside-real-vault files; ambiguous targets require a more specific vault-relative path. Absolute and explicitly relative targets never fall back to a different file elsewhere.

Workspace actions:

- `<CR>` opens the note on a result row or toggles the current group heading.
- `e` edits or adds the top-level note property under a table cell. Scalar, link/date-shaped string, and scalar-list cells use type-aware prompts. Only parsed `md`, `markdown`, and `qmd` note rows inside the originating vault are editable; attachments, `.base` definitions, and other files remain read-only. List-layout rows remain navigation-only.
- `t` changes the note property under the selected table cell in an unsaved, conflict-checked `.obsidian/types.json` buffer.
- `]g` and `[g` move to the next or previous group or Kanban column.
- `za` collapses or expands the current vertical group.
- In Kanban and cards views, `h`/`l` move horizontally and `j`/`k` move vertically between cards.
- In cards views with an image property, `i` probes terminal image support and toggles one explicit local PNG preview.
- `I` explicitly enables or disables viewport-aware thumbnails for visible cards.
- `C` asks for confirmation, then compares the current saved Base view with `obsidian base:query` without replacing local results.
- `r` rescans the originating vault and refreshes the query while preserving collapse state and clearing prior comparison diagnostics. This recovers disk changes even when file-watch events were missed; automatic refreshes remain incremental.
- `q` closes the workspace buffer.
- `?` displays the available actions.

## Architecture and reuse points

The implementation is modular under `lua/obsidian/bases/`:

- `definition.lua` parses `.base` YAML with the existing `obsidian.yaml` parser and selects a named view.
- `index/files.lua` owns a lazy, process-local vault index covering arbitrary file extensions. It incrementally consumes the shared watched-file feed and excludes vault internals and configured ignore paths.
- `source.lua` converts shared all-files rows into evaluator contexts, overlays loaded modified Markdown buffers without writing them, and builds incoming-link metadata only for definitions that reference `file.backlinks`.
- `properties/types.lua` reads and validates vault-scoped `.obsidian/types.json`, caches it by revision, observes loaded-buffer changes, and invalidates from the shared watched-file feed.
- `properties/types_edit.lua` locates exact JSON member ranges and applies expected-type and revision-checked type changes without regenerating unknown metadata or writing the file.
- `cache/note.lua` exposes its existing row builder for in-memory source lines and an opt-in complete-property mode, so the all-files index does not introduce a competing frontmatter/tag/link parser or alter the compact persistent-cache schema.
- `worker.lua` owns one persistent, process-wide JSONL Node worker with cancellable requests, ten-second deadlines, and restart-on-timeout recovery. Individual query refreshes are versioned separately from worker lifetime.
- `query.lua` produces the shared typed result model used by the workspace, including scalar groups and manual group order, and rejects late refresh results.
- `edit.lua` applies expected-value and revision-checked patches to exact YAML scalar ranges, edits scalar lists in flow or block form, and inserts missing scalars without regenerating frontmatter.
- `layout.lua` builds table, list, Kanban, and cards text and geometry without owning buffers, queries, or image resources. It preserves source rows for navigation and editing.
- `workspace.lua` manages buffers and windows, applies layouts, and owns collapse state, native card/group motions, note navigation, guarded table-cell editing, explicit image previews, and the bounded viewport-thumbnail lifecycle.
- `images.lua` resolves supported local card image properties without fetching external resources.
- `compat.lua` centralizes Neovim capability checks, guarded `vim.system` startup, and experimental `vim.ui.img` detection, terminal probing, display, repositioning, and cleanup.
- `compare.lua` owns the bounded, explicitly confirmed `obsidian base:query ... format=json` comparison, snapshot comparability checks, and path-set diagnostics.
- `scope.lua` captures each workspace's originating real vault root, config directory, and ignore rules so later workspace switches cannot redirect its query, image, edit, or CLI operations.
- `embed.lua` and `parse/embeds.lua` resolve linked and fenced definitions with source-aware Markdown exclusions and pinned containing-note context.

The result identity includes the vault, Base identity and revision, selected view, pinned context path and revision, and evaluator backend/version.

## Supported syntax

The local backend currently supports:

- Valid Bases YAML with global and view-level filters.
- Expression and structured `and`/`or`/`not` filters supported by `obsidian-bases-expression`.
- Formula evaluation supplied by that evaluator.
- `order` property columns.
- Basic `sort` entries with `property` and `ASC`/`DESC` direction. Declared date/datetime properties and date-valued formulas sort chronologically, including timestamps with different UTC offsets; original note values remain intact for display and editing.
- `limit`.
- Every non-internal, non-ignored vault file as a candidate, including attachments, `.base` definitions, and arbitrary extensions.
- Decoded Markdown frontmatter values in the process-local index, including nested lists and objects. Empty mappings retain `{}` identity and empty sequences retain `[]` identity through evaluator JSON. Nested objects and lists remain read-only.
- Basic `file.*` metadata for every indexed file, plus tags, links, embeds, and dependency-gated `file.backlinks` for Markdown-like notes. Link metadata includes unresolved internal targets but excludes external URLs. `file.tags` includes body and frontmatter tags; the note property `tags` is frontmatter-only.
- `file.ctime` uses filesystem birth time when available, so edits and permission changes do not change a file's creation date. On filesystems that do not expose birth time (missing or zero timestamp), it falls back to metadata-change time.
- Linked embeds and fenced `base` blocks.
- Pinned `this.file` context for embedded Bases.
- Minimal editing and insertion of top-level scalar note properties. Missing values infer booleans, numbers, and null from explicit YAML-like literals; other input is stored as a string.
- Type-aware editing for scalar lists using YAML flow-list input such as `[one, "two words"]`.
- Declared property types from `.obsidian/types.json`, including text, list (`multitext`), number, checkbox, date, datetime, aliases, and tags.
- Guarded declared-type changes from table cells, including creation of missing metadata in an unsaved buffer and exact replacement/insertion inside existing JSON objects.
- Wikilink-shaped scalar properties and list elements are evaluator Link values even when metadata is missing or declares text/list types. Filters, formulas, `file.properties`, and pinned file properties share this behavior; ordinary text and the original Lua source values remain unchanged.
- Link editing for wiki/Markdown-link-shaped text values; a bare target is wrapped as a wikilink.
- ISO date/datetime validation driven by declared types, with conservative value-shape fallback when metadata is missing. Datetimes accept `YYYY-MM-DDTHH:mm` (or a space separator), optional `:ss` and fractional seconds, and optional `Z` or signed `HH:mm`/`HHmm` offsets. Edits preserve the supplied timezone and precision.
- Declared date/datetime types convert present values to evaluator dates; missing and null dates remain null. Other declarations select the editor but do not implicitly convert query values: numbers, booleans, text, lists, and objects retain their underlying YAML types even when metadata disagrees. For example, `amount: "10"` with a number declaration remains a string, so `amount + 2` yields `"102"`; use `number(amount) + 2` for numeric arithmetic or explicitly edit the value to a number. A scalar with a list declaration remains scalar; use `list(value)` when an expression needs a list. This policy applies consistently to note properties, `file.properties`, foreign-file properties, and pinned `this.file.properties`. Wikilink recognition is independent of these non-date declarations.
- Native table, list, read-only `kanban`, and read-only `cards` rendering.
- Scalar `groupBy.property` with `ASC`/`DESC` ordering.
- Manual `groupOrder`, including null and declared empty groups; unlisted groups are hidden as specified by Bases semantics.
- Refresh-persistent collapse state and native group navigation.
- Horizontal Kanban columns sourced from scalar groups, with text cards and `h`/`j`/`k`/`l` navigation.
- Gallery-like cards grids that choose the number of 24-cell cards from the active workspace window width, with native card navigation.
- Optional, explicitly requested local PNG previews for configured card image properties when `vim.ui.img` and the attached terminal report support.
- Explicit viewport thumbnails with four reserved image rows per card, a maximum of twelve visible images, scroll/resize repositioning, offscreen cleanup, and generation-based stale-work rejection.
- Optional comparison against the official Obsidian CLI for saved Base files, reporting matching, local-only, and Obsidian-only paths while retaining the local result.

Unknown view types and configuration are preserved. Supported `table`, `list`, and `kanban` types use native renderers; other evaluated views fall back to a read-only table without rewriting the saved type. Grouping is applied after the current local sort and limit. List/object group values, invalid directions, and malformed grouping configuration disable grouping with an explicit diagnostic rather than silently flattening or broadening results. Kanban without a supported scalar `groupBy` falls back to the table renderer with an explicit diagnostic.

Kanban is currently read-only: it does not drag cards, change the grouped property, create notes, render cover images, or rewrite column order. Empty manual groups still render as empty columns. Long boards use ordinary horizontal scrolling rather than a WebView-style canvas.

Cards are also read-only and use fixed 24-cell card sizing; Obsidian's pixel-based `cardSize`, image-fit, and aspect-ratio settings are preserved but not translated into terminal cell geometry. The active workspace window determines how many cards fit per row, with a one-card minimum. Resize events debounce reflow, preserve the selected card by path, update vertical navigation stride, and rebuild thumbnail geometry. If the same workspace buffer is visible in multiple windows, the active window drives the shared buffer layout.

Images are never probed or displayed automatically. Pressing `i` probes and toggles one card preview. Pressing `I` probes once and rerenders cards with four reserved thumbnail rows; only cards intersecting the visible vertical and horizontal viewport are considered, at most twelve local PNGs are loaded, and offscreen image IDs and bytes are removed. Scroll and resize events update screen placements. Every update increments a generation so scheduled work from an older viewport cannot overwrite the current layout.

Both image modes support only local PNG data through the experimental Kitty-protocol API. Stable builds without `vim.ui.img`, external URLs, colors, non-PNG formats, missing or ambiguous files, unsupported terminals, unavailable APIs, and cards outside the visible viewport remain text fallback with explicit messages. Images are removed on refresh, navigation, disable, or close. Experimental presentation is never required for query, navigation, editing, or comparison state.

Existing scalar edits replace only the parser-reported scalar lexeme. Scalar replacements must round-trip through the YAML parser with the intended value and type; numeric overflow, non-finite numbers, and values that lose precision during serialization are refused before mutation. Flow-list edits replace only the list value and retain a trailing property-line comment. Block-list edits replace the item lines while preserving the property key and unrelated frontmatter; comments inside the replaced item range are not retained. Missing properties are inserted immediately before a valid frontmatter closer, and notes without frontmatter receive a minimal frontmatter block at the beginning. An edit is refused when the query's expected value or source revision is stale. File properties, formula values, nested lists/objects, object properties, emptying block-style lists, existing null transitions, multiline scalars/items, invalid, unclosed, non-mapping, or flow-root frontmatter, unsafe property names, and BOM-prefixed frontmatter creation remain read-only. Missing `id`, `aliases`, and `tags` still require dedicated insertion behavior. Edits are never auto-saved and do not claim multi-file atomicity or rollback.

CRLF note lines are normalized before shared parsing, so frontmatter, links, embeds, and backlinks retain their ordinary semantics. Guarded `.obsidian/types.json` edits remove line-terminal carriage returns before placing text in a `dos` buffer, allowing an explicit write to preserve CRLF without producing doubled carriage returns. General cross-platform CRLF note-edit coverage remains narrower than the index and type-metadata regression coverage.

The all-files query index can return attachments, `.base` files, and arbitrary extensions, but property editing rejects every row that is not a successfully parsed supported Markdown-like note. The direct edit API repeats the extension, parsed-note identity, source-revision, expected-value, property-type-revision, and originating-vault checks as defense in depth.

When property metadata is missing, editing falls back to conservative value-shape detection. When metadata is present, declared text remains text even if its value resembles a date, and missing values receive the declared editor and default. Unknown plugin-provided type names and unrelated top-level JSON members are preserved. Pressing `t` offers only recognized type names, replaces only the selected JSON string or inserts one member, and refuses invalid JSON, stale revisions, expected-type mismatches, unsafe property names, read-only buffers, and unsupported target types. Metadata edits remain modified in memory and must be written explicitly; the plugin never auto-saves `.obsidian/types.json`.

## Runtime dependencies

Local filter/formula evaluation uses the MIT-licensed `obsidian-bases-expression` package pinned exactly to `0.2.0` in `package-lock.json`. It requires:

- A Neovim build with `vim.system()`.
- Node.js available as `node`.
- `npm install --ignore-scripts` in an existing plugin directory, or `npm ci --ignore-scripts` for a clean lockfile-based install.

The package is headless and does not import private Obsidian APIs. Requests are JSON encoded and sent to a persistent worker; formulas are not executed through JavaScript `eval`, Lua `load`, or shell interpolation.

CLI comparison is optional and separate from local evaluation. It requires the official `obsidian` CLI with `base:query` support. Pressing `C` warns that the official CLI may start the desktop app and requires confirmation before invoking an exact argument vector with a five-second deadline. Comparisons are refused as non-comparable when the saved Base revision changed, the result depends on an embedded context, or unsaved Base, note, or property-type overlays would make the CLI observe a different snapshot. Missing executables, nonzero exits, timeouts, malformed JSON, opaque result shapes, and stale callbacks are diagnostic-only; they never replace or invalidate the local result.

## Degradation and correctness

The workspace explicitly displays backend, freshness, status, completeness, and diagnostics.

- A missing Node runtime or package leaves the workspace open in `backend_unavailable` state.
- Invalid YAML leaves it open in `invalid` state.
- Unsupported or failed evaluation is `unsupported`, not an empty result. The pinned evaluator is guarded at each evaluated expression node so boolean operators, conditionals, and list predicates cannot hide runtime errors; short-circuited branches are not evaluated.
- A valid zero-row query remains a current result and is distinct from unsupported evaluation.
- When a refresh fails after a verified result, the previous result remains visible as stale.
- Late asynchronous results cannot replace a newer refresh. Obsolete evaluator requests are cancelled, every request has a finite deadline, and a timed-out worker is terminated before the next request starts a replacement.
- Obsidian desktop and CLI are never invoked automatically; only the confirmed `C` action can call the official CLI.
- Property edits and insertions fail closed on changedticks, disk stat changes, expected-value or type-revision mismatches, invalid frontmatter, unsupported or nested values, unsafe keys, read-only buffers, non-note targets, and paths outside the originating real vault.
- Missing property metadata is a supported fallback state. Invalid metadata is surfaced as a partial-result diagnostic and is not partially interpreted.

The local candidate set covers every non-internal, non-ignored file whose real path remains inside the originating vault. Backlinks are computed from the same process-local snapshot when filters, formulas, or view configuration reference backlinks. Dependency detection also conservatively enables them for bracket expressions, whose computed keys may resolve to `backlinks`; ordinary definitions without those references do not pay the incoming-link indexing cost. Backlink source files are deduplicated by path, relative links are resolved from their source directory, supported `md`/`markdown`/`qmd` extensions share extensionless lookup, and ambiguous shortest-path links remain unresolved. Watched changes and `r` refresh the pinned workspace snapshot. The persistent cache remains compact and lossy for compatibility; complete property values and dependency-gated backlinks live only in the process-local index used by Bases.

## Verification

Focused mini.test coverage in a prepared development checkout includes:

- Definition parsing, named view selection, and invalid YAML.
- Local filter evaluation, sorting, empty results, unsupported expressions, and missing runtime detection.
- Distinct `this.file` contexts for one Base.
- Arbitrary file extensions, attachment/file metadata filtering, ignored/internal and outside-real-vault path exclusion, incremental create/change/delete/rename events, complete property values, empty mapping/list identity, dependency-gated and deduplicated backlinks across supported note extensions, CRLF parsing, modified-buffer overlays, and Markdown source preservation.
- Minimal scalar source-range patches and insertions, flow/block scalar-list updates, note-only and originating-vault enforcement, declared-type revision checks, metadata invalidation, evaluator type propagation, frontmatter creation, stale-prompt rejection, expected-value checks, and no automatic disk writes.
- Exact JSON declared-type replacement/insertion, unknown-member preservation, missing-file buffers, expected-type conflicts, stale metadata revisions, workspace type selection, and unchanged on-disk metadata.
- Late-result rejection.
- Scalar grouping, list rendering, Kanban navigation, width-aware cards grids, selected-card preservation across reflow, dynamic navigation stride, image resolution, capability probing, explicit PNG previews, viewport bounds, twelve-image limits, resize/reposition updates, stale-generation rejection, cleanup, and text fallback states.
- Official CLI command construction, JSON path extraction, match/difference summaries, explicit confirmation, saved-revision and overlay comparability checks, stale comparison cleanup, and unavailable/error states.
- Simulated stable-Neovim capability paths with `vim.ui.img` and `vim.async` absent, guarded `vim.system` setup failures, and cards text fallback.
- Real `:Obsidian bases` command execution, read-only rendering, note navigation, refresh, and operation without Obsidian desktop.
- Linked and fenced embedded Bases, source exclusions, discoverable inline actions, and pinned context.

Actual `NVIM v0.13.0-nightly` terminal UI runs confirmed the workspace layout, arbitrary file rows, dependency-gated backlinks rendered as source paths, grouped lists, Kanban navigation, cards navigation, and immediate result refresh. In the attached Rex terminal, a cards workspace reflowed from three to two columns when its active window narrowed; the selected-card behavior is covered by the same real workspace path in focused tests. The `t` action changed `priority` from text to number in a modified metadata buffer while the on-disk `.obsidian/types.json` remained byte-for-byte unchanged. Earlier runs confirmed explicit single-image and viewport-thumbnail display and cleanup.

Mocked backends cover CLI command construction, comparability, and result handling, but no end-to-end comparison against an installed official `obsidian` CLI is claimed. No separate stable Neovim binary was available, so stable coverage is feature-path simulation rather than execution in a stable binary. Focused regressions cover CRLF index/type-metadata handling, distinct `{}` versus `[]` transport, note-only edits, vault switching, realpath boundaries, request cancellation, and worker timeout recovery.

The Tests workflow uses Node.js 22 and runs `npm ci --ignore-scripts` before `make test`, so clean CI installs the pinned evaluator. The repository's full suite can still expose an environment-dependent failure group in `tests/lib/test_moment_parse.lua` under local DST/timezone conversion; the CI-like UTC run is the portable baseline.

## Next milestones

The remaining release checks are real stable-Neovim execution, an explicitly authorized end-to-end official-CLI comparison, and broader Linux/macOS/Windows terminal coverage. Broader Bases syntax and visual fidelity remain subsequent enhancements after those checks.
