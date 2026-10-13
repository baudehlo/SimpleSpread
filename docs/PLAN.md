# SimpleSpread — Architecture & Execution Plan

A native macOS spreadsheet application written entirely in Swift, built from
scratch — the spreadsheet stack has **no third-party dependencies** (Sparkle,
added later, is the only external library, and only for software updates).
Native file format is XLSX;
CSV is import/export. The formula engine targets Google Sheets' core feature
level, not full Excel.

This document is the working plan the project was built against. Section 12
records where the implementation landed relative to the plan.

---

## 1. Goals & product scope

**Product thesis:** a fast, small, honest spreadsheet for everyday work —
open real XLSX files, edit values/formulas/formatting, save them back in a
form Excel/Numbers/Google Sheets accept, and interchange CSV cleanly.

### In scope (v1)
- Workbooks with multiple sheets; sparse grids up to Excel's bounds
  (1,048,576 × 16,384 addressable; UI virtualizes what's visible).
- Values: numbers (IEEE double), text, booleans, errors, dates/times as
  serial numbers with formats (the Excel model).
- Formula engine at Google Sheets basic level: ~150 functions, full operator
  set, criteria matching, cross-sheet references, whole-row/column ranges,
  incremental recalculation with cycle detection.
- Formatting: bold/italic/underline/strikethrough, font size/name, text and
  fill color, horizontal/vertical alignment, wrap, number formats (built-in
  table + custom format codes).
- Editing UX: Excel's Ready/Enter/Edit state machine, full keyboard
  navigation, drag selection, header row/column selection, resize + autofit,
  fill handle (copy semantics), clipboard (internal lossless + TSV interop),
  per-operation undo/redo.
- Files: XLSX read/write (interop-hardened), CSV import (sniffed dialect,
  injection-safe) and export (RFC 4180, BOM+CRLF, ISO dates).
- CI on GitHub Actions; releasable .app + DMG pipeline.

### Explicitly out of scope (v1) — the honest cut list
- Array formulas / spill, ARRAYFORMULA, SPLIT/FILTER/UNIQUE-style
  range-returning functions.
- INDIRECT/OFFSET (they break static dependency analysis; roadmap item with
  dynamic dependency tracking).
- Charts, images, comments, conditional formatting, data validation.
- Pivot tables: OLAP/Data Model sources, calculated items, label/value
  filters, slicers and timelines, and Excel 2010+ show-values-as modes
  (rank, % of parent). Pivots that use them are kept intact for Excel but
  can't be recomputed or edited (§7); everything else is supported.
- Localization: en-US only (decimal point, M/D dates, comma argument
  separator). The file format layer is locale-invariant per OOXML rules.
- Iterative calculation for circular references.
- Real-time collaboration, autosave/versions.

---

## 2. Architectural decisions (and why)

| Decision | Choice | Rationale |
|---|---|---|
| Project layout | SwiftPM only, no .xcodeproj | Matches questrade-mac-menu; CI is `swift build`/`swift test`; app bundle assembled by script/workflow with PlistBuddy |
| Dependencies | Sparkle only | Spreadsheet stack is from-scratch (ZIP via the Compression framework and the system zlib, XML via Foundation XMLParser plus byte scanners for cell data, UI via SwiftUI+AppKit); Sparkle added later for in-place software updates (docs/UPDATES.md) |
| Module split | 4 targets: Core / Files / UI / app shell | Everything except the ~40-line executable is a testable library |
| Concurrency | Swift 6 language mode; engine synchronous on the document's actor | Spreadsheet recalc is CPU-bound and fast at this scale; a background-calc actor is a roadmap item, not a v1 risk |
| Grid rendering | Custom AppKit NSView in NSScrollView, virtualized draw | SwiftUI-only grids can't hit spreadsheet interaction/performance targets; this is the industry-standard shape |
| Date system | Serial numbers, epoch 1899-12-30 = 0, **no** Lotus leap-year bug | Google Sheets' choice: exact Excel agreement for all dates ≥ Mar 1 1900; clean math |
| Circular refs | Detect, mark #CYCLE! (exports as #REF!) | Sheets shows #REF! + message; a distinct code is clearer in-app |
| Formula storage | Text (no '='), parsed AST cached in engine | Matches XLSX storage; AST enables reference transforms |
| Undo | Cell-level snapshots for edits; whole-workbook XLSX snapshot for structural ops | The XLSX round-trip is the most-tested serialization in the codebase — reusing it for undo gets fidelity for free |
| CSV import safety | `=`/`+`/`@` fields import as text, never formulas | OWASP CSV-injection guidance; files are data |
| CSV export | Machine-canonical by default (full-precision numbers, ISO dates), display-mode as option | Round-trips beat Excel's lossy "as displayed" default |

## 3. Module map

```
Sources/
  SpreadsheetCore/          # no UI, no I/O — pure model + engine
    CellValue.swift           values + error taxonomy (+ ERROR.TYPE codes)
    CellAddress.swift         A1 addressing, ranges, iteration
    ExcelDate.swift           serial <-> civil date (Hinnant algorithms)
    NumberFormat.swift        format model, builtin id table, format renderer
    CellStyle.swift           style value type + deduplicating StyleTable
    Workbook.swift            Workbook/Sheet/Cell, sheet management
    FormulaLexer.swift        tokenizer
    FormulaParser.swift       recursive-descent parser (precedence per Excel)
    FormulaAST.swift          Expr tree, serializer, reference transforms
    FormulaEvaluator.swift    EvalValue, resolved ranges, operator semantics
    Coercion.swift            the coercion table + criteria evaluator
    FunctionRegistry.swift    registry, GridArg, shared arg helpers
    Functions*.swift          9 category files, 157 functions
    CalculationEngine.swift   dependency graph, dirty propagation, cycles
    RangeDependencyIndex.swift large-range dependents: per-column interval trees
    WorkbookOperations.swift  structural edits with formula rewriting
    PivotTables.swift         pivot tables/caches: typed facts + preserved XML
    PivotModel.swift          parsed cache (fields, shared items, groups, records) + definition
    PivotEngine.swift         computes a pivot's layout (axis items, totals, show-as, geometry)
    PivotCalculatedField.swift calculated fields through the formula engine
    PivotRendering.swift      writes a computed layout into the sheet (conflicts, placement)
    PivotRefresh.swift        rebuilds a cache from its source; remaps the definition
    PivotEditing.swift        field placement, summaries, filters, sort, layout; new pivots
    PivotGrouping.swift       date-part and number-range grouping
    FunctionsPivot.swift      GETPIVOTDATA
    ValueParser.swift         shared input-parsing pipeline
  SpreadsheetFiles/
    ZipArchive.swift          minimal ZIP reader/writer + CRC32 + parallel DEFLATE
    XMLSupport.swift          escaping + _xHHHH_ encoding
    XLSXWriter.swift          OPC package writer (interop profile)
    XLSXReader.swift          SAX reader (rels-driven, tolerant)
    XLSXPivotTables.swift     pivot part read (keep/drop decisions) + write (patch or generate)
    PivotXMLParser.swift      cache/table XML → PivotCacheData/PivotDefinition
    PivotXMLWriter.swift      PivotCacheData/PivotDefinition → XML (carrying over the unmodelled)
    XMLRewriter.swift         streaming XML rewrite/scan/fragment extraction
    CSV.swift                 parser/sniffer/decoder/importer/exporter
    CSVFastImport.swift       byte-level CSV import (row limit, progress)
    XLSXSheetDataScanner.swift  byte-level <sheetData> reader
    XLSXSheetDataWriter.swift   byte-level <sheetData> writer
  SpreadsheetUI/
    SelectionState.swift      selection model + data-edge navigation + GridLayout
    SpreadsheetDocument.swift document view-model (edit/undo/clipboard/files)
    SpreadsheetGridView.swift AppKit grid (draw, mouse, keyboard, editor)
    GridContainer.swift       NSViewRepresentable + focused values
    Clipboard.swift           NSPasteboard integration
    ContentView.swift         window chrome (format bar, formula bar, tabs)
    App.swift                 App scene, DocumentStore, menu commands
    SpreadsheetDocument+Pivots.swift  insert/edit/group/refresh with one undo step each
    PivotFieldsPanel.swift    the PivotTable Fields panel + Insert PivotTable sheet
    PivotGridStyle.swift      Excel-style pivot drawing (bands, bold totals, field buttons)
  SimpleSpread/
    main.swift                calls SimpleSpreadApp.run()
```

**Dependency rule:** Core knows nothing of Files or UI. Files depends only on
Core. UI depends on both. Tests mirror the split (312 tests).

## 4. Data model

- `CellValue`: `empty | number(Double) | string | bool | error(CellError)`.
  Dates ARE numbers; display is a property of the cell's number format.
- `Cell`: value + optional formula text + style index. Default cells are
  dropped from storage (`Sheet.cells: [CellAddress: Cell]` stays sparse).
- `CellStyle` is a value type deduplicated through `StyleTable` (index 0 =
  default) — mirrors XLSX `cellXfs`, and cell `s=` attributes are written
  straight from style indices.
- `Sheet` has a stable integer `id` that survives rename/reorder; formulas
  reference sheets by *name*, and rename rewrites formula text (Sheets
  behavior).

## 5. Formula engine

**Pipeline:** text → lexer → parser (AST) → evaluator, with the AST cached
per cell in the engine and reused for dependency extraction and transforms.

- **Precedence** (tightest first): `:` range, unary ± (binds tighter than
  `^`, so `-2^2 = 4`), `%` postfix, `^` (left-assoc: `2^3^2 = 64`), `* /`,
  `+ -`, `&`, comparisons.
- **Coercion regimes** (the core subtlety, from research):
  - Operators + direct literal args coerce aggressively (bool→1/0, numeric
    text→number, blank→0; failure → #VALUE!).
  - Range-consuming aggregates SKIP text/bool/blank cells without coercing.
  - Comparisons never cross-coerce: type rank number < text < boolean; text
    case-insensitive; blank becomes the other side's zero value.
- **Criteria evaluator** (SUMIF/COUNTIF family): operator-prefix parsing
  (`>=`, `<>`, …), whole-cell wildcard matching (`*`, `?`, `~` escape),
  same-type-only inequalities, `""`↔blank and `"<>"`↔non-blank rules.
- **Laziness:** IF/IFS/SWITCH/CHOOSE evaluate only taken branches;
  IFERROR/IFNA/IS*/TYPE/ERROR.TYPE capture argument errors instead of
  propagating.
- **Errors are values** internally; helpers throw typed `CellError` which the
  evaluator converts back to error values at the cell boundary.
- **Recalculation:** precedent→dependent edges (cell-level for ranges ≤ 256
  cells; a larger range is one shared graph node, found from a cell through
  a per-sheet, per-column interval-tree index in O(log n + k)). One iterative
  Tarjan SCC pass from the edited cells finds what to recalculate and orders
  it; every formula in a cycle gets #CYCLE! (deterministic, whatever the walk
  order). Volatile set (NOW, TODAY, RAND, RANDBETWEEN, and GETPIVOTDATA — it
  reads pivot cells its arguments don't name) recalculated on every edit.
  Formulas naming a sheet that doesn't exist yet are re-installed when it
  appears. Sheets keep their used range up to date incrementally. Structural
  edits rebuild the whole graph (`rebuildAll`) — correct first, incremental
  later. `spreadsheet-bench --edits` times edits on synthetic workbooks.
- **Iterative solvers** (IRR/XIRR/RATE): Newton–Raphson with numeric
  derivative, bracketing-scan + bisection fallback, #NUM! on non-convergence.

## 6. Number formatting

Custom renderer for Excel format codes: sections (`pos;neg;zero;text`),
digit placeholders `0 # ?`, grouping and trailing-comma scaling, `%`,
`E+00`, quoted/escaped literals, `_` width and `*` fill (degraded to
space/ignored), `@`, date/time tokens with the m-month-vs-minute adjacency
rule, elapsed `[h] [m] [s]`, color/condition brackets parsed and dropped.
Fractions (`?/?`) fall back to General. "General" implements the
integer/decimal/scientific selection rules. The builtin numFmtId table
(0–49) is baked in both directions (read ids → codes; write codes → ids).

## 7. File formats

### XLSX (native)
Writer emits the researched interop profile: `[Content_Types].xml` first;
schema-ordered elements; minimal-but-complete styles part (fills[0]=none,
fills[1]=gray125, cellXfs aligned to StyleTable, Normal cell style); shared
strings with `xml:space` and `_xHHHH_`; formulas without `=` plus cached
`<v>` and correct result types (`str`/`b`/`e`); dimension, sheetViews with
frozen panes, cols with the character-width formula (px = 7·w + 5), row
heights and `hidden` rows (hidden-only rows still get a `<row>`),
`<autoFilter>` (after sheetData, before mergeCells) plus the hidden
sheet-scoped `_xlnm._FilterDatabase` defined name Excel expects, mergeCells;
a deduplicated `<borders>` table (index 0 empty; `borderId` + `applyBorder`);
docProps. Filter criteria we can't evaluate (top10, dynamic, color, icon,
`dateGroupItem` filters) are kept as the filterColumn child's XML and written
back verbatim (attribute order normalized, unused namespace declarations
dropped). Border colors other than `rgb` (theme, indexed) read as automatic;
diagonals are not modelled. Reader resolves parts via relationships
(never hard-coded paths), infers missing `r` attributes, concatenates
rich-text runs, expands shared formulas by reference translation, maps
builtin/custom numFmts, and normalizes 1904-system dates (+1462 on
date-formatted numerics). Cells with formulas we can't evaluate surface
#NAME? after recalc — deliberate honesty over stale cached values.

**Pivot tables** are preserved *and* modelled. The reader keeps each pivot
table, cache definition and records part verbatim, and also parses them into
a typed cache (fields, shared items, groups, records) and definition (fields,
axes, items, data fields, layout). An unchanged pivot is written back from
its verbatim parts; one that was edited, refreshed or created is generated
from the model, carrying over the attributes and extensions we don't model.
For the verbatim path the model holds the facts edits can invalidate — the table's location and report-filter area,
the cache's source ranges (tracked by sheet id), cache ids. On save the
writer lays the parts out afresh (Overrides, workbook/sheet/table/cache
rels, `<pivotCaches>` after `<sheets>`) and patches just those facts plus
the records `r:id` (found by namespace URI, not prefix) through a streaming
rewriter. Stylesheet references inside the parts stay valid without
rewriting: custom numFmt ids the parts use keep their ids (our own custom
formats are numbered above them), and the source `<dxfs>` and
`<tableStyles>` are re-emitted in original order. A pivot's
`<conditionalFormats>` are removed, since they must pair with sheet
conditional formatting we don't keep. Table- and defined-name sources are
resolved to sheet ranges (tables and names aren't preserved). Dropped,
leaving the rendered cells as plain values: connection/OLAP/Data Model and
scenario caches, unresolvable named sources, Strict-namespace parts, and
1904-date workbooks. Editing: typing, paste, fill or cut into a pivot's
area, or row/column inserts/deletes that would split one, are refused as in
Excel; deleting every row/column or clearing a whole pivot removes it;
moves above/left shift it; source edits follow formula reference semantics
(a source whose rows all go is kept "detached" and `refreshOnLoad` is
cleared). Research and real-file fixtures: docs/RESEARCH.md §Pivot tables,
Tests/SpreadsheetFilesTests/Fixtures/Pivots. GETPIVOTDATA reads the cell a
pivot renders: it decodes the definition's row/column items into item tuples,
picks the line the field/item pairs name (all of an axis's fields = an item
line, a leading part = its subtotal, none = the grand total) and returns the
cell at their crossing, so it works for any pivot with a parsed definition.

*Computing* a pivot (`PivotEngine`) is a port of the research prototype,
checked cell by cell against Excel: axis items and their `rowItems`/
`colItems` encoding, compact/outline/tabular geometry, subtotals top or
bottom, custom subtotal functions, grand totals, hidden items and report
filters, top-N filters, grouping (date parts, number ranges, discrete
groups), calculated fields (through the formula engine), show values as
(% of total/row/column, index, difference, % of, % difference, running
total — with Excel's blank/zero rules for missing base items), items with no
data, blank lines, Values on rows, and localized captions. A pivot using
something outside that (OLAP, calculated items, label/value filters, newer
show-as modes, hidden items in totals) is kept verbatim and refuses edits
with the reason. *Refresh* rebuilds the cache from the source range (Excel's
first-appearance shared items, case-insensitive matching), keeps groups and
calculated fields, and remaps the definition by field name and item value
(manual order kept, new items appended in Excel's collation). *Editing*
goes through `SpreadsheetDocument.editPivot`/`regroupPivot`: each change is
one transaction that recomputes every affected pivot, rolls back on error
or overlap with another pivot, asks before overwriting cells, and registers
one undo step. Grouping edits the shared cache, so all pivots on it change.

### CSV (import/export)
Import: BOM/UTF-16/UTF-8-validation/CP1252 decode chain; delimiter sniffing
by column-count-consistency scoring; quote-aware state machine (CRLF/LF/CR,
`""`, embedded newlines, ragged rows, unterminated-quote fail-soft);
type inference through the shared ValueParser with leading-zero and
>15-digit protection; `=`-prefixed fields stay text; semicolon dialect
implies decimal-comma numbers. Export: computed values only; minimal
quoting; CRLF; UTF-8 BOM (Excel double-click compatibility); numbers
machine-canonical; dates ISO 8601; display-mode option.

### ZIP (under XLSX)
Stored + raw-DEFLATE, correct CRC-32 in local + central headers, no data
descriptors, no ZIP64; reader scans EOCD backward, trusts the central
directory, verifies CRCs, and rejects CFB (encrypted/legacy .xls)
containers with a clear error. Inflate uses the Compression framework;
deflate and CRC-32 use the system zlib. Deflate runs pigz-style on all
cores: 1 MB chunks, each primed with the previous 32 KB and ended with a
sync flush, joined into one ordinary stream (level 6 size, ~8× faster).

### Large files
- Opening runs off the main thread (`SpreadsheetDocument.load`, then
  `make` on the main actor) behind a progress panel with Cancel
  (`FileLoading.swift`); the panel only appears after 0.25 s.
- CSV (`CSVFastImport.swift`): bytes are scanned in place (the file is
  memory-mapped and UTF-8 is validated as the scan goes, falling back to
  CP1252 if needed); common fields (plain numbers, ISO dates, text that
  can't be a value, TRUE/FALSE) skip ValueParser with identical results;
  the import stops at 1,048,576 rows and reports truncation. The old
  String-based importer remains as the test reference.
- XLSX (`XLSXSheetDataScanner.swift`): `<sheetData>` is read by a byte
  scanner that mirrors the XMLParser delegate rule for rule; the rest of
  the sheet still goes through XMLParser, and anything unexpected falls
  back to XMLParser for the whole sheet. The writer builds `<sheetData>`
  as bytes (`XLSXSheetDataWriter.swift`). Tests compare both directions
  with the XMLParser/String versions on every fixture.
- Grid: `GridLayout` offsets are O(log k) over the rows/columns with
  non-default sizes (prefix sums + binary search), cached per revision;
  status-bar statistics look up the selection rather than scan the sheet.
- Still proportional to sheet size: the first calculation (~4 s per
  million formulas), saving (~4.5 s for a full sheet, on the main thread),
  and Find, which scans every cell per keystroke.

## 8. Application layer

- `SpreadsheetDocument` (MainActor ObservableObject) is the single write
  path: typed input (shared ValueParser: `=formula`, numbers, `5%`, `$`,
  dates, times, TRUE/FALSE, `'`-escape, Plain-Text format suppression),
  style application, structural edits, sheet ops, clipboard, fill, file I/O.
  Every operation is one undo group (`groupsByEvent = false` + explicit
  groups so behavior is identical under tests and menus).
- Grid: virtualized cell drawing with pinned headers; Excel's
  Ready/Enter/Edit machine — typing replaces (arrows commit+move),
  double-click/F2 edits in place (arrows move caret), Enter/Tab/Shift
  variants, Esc cancels; Cmd+arrow data-edge jumps; header click/drag
  selection; boundary drag resize + double-click autofit; fill handle with
  formula translation; NSTextField overlay editor.
- Frozen panes: the grid draws up to four panes (corner, frozen rows,
  frozen columns, scrolling body), each clipped and shifted by the scroll
  offset like the pinned headers; hit testing and scroll-into-view are
  pane-aware. Merged ranges draw as one cell (no inner grid lines or
  borders, no text overflow into or out of them); selections grow to whole
  merges and arrow keys step over them. Hidden rows are zero-height in
  GridLayout and skipped by navigation.
- Borders: `CellStyle.borders` (four edges, OOXML line styles, optional
  colour). Each cell draws its own edges after the grid lines.
- Sort and AutoFilter live in Core (`SortRows.swift`, `AutoFilter.swift`):
  Excel's sort order (numbers, text, booleans, errors; blanks last), whole-row
  moves with formulas translated like a copy, a header guess, value/condition
  criteria with wildcards, and filter evaluation that hides rows. Merges,
  hidden rows, frozen panes, the filter and row heights undo together as
  `SheetLayoutState`. Unsupported criteria (top 10, dynamic, colour) are kept
  as XML and written back, but hide nothing when re-applied.
- Chrome: toolbar (undo/redo, format painter, clear formatting; $ / % /
  decimal places / number-format menu; font, size, B/I/U/S, colors, borders;
  horizontal and vertical alignment, wrap, merge; Sort & Filter menu; AutoSum
  split button). Larger font sizes grow short rows (never shrink) in the same
  undo step. Name box + formula bar, sheet tabs (add/rename/delete/switch), status bar
  (Sum/Avg/Count), standard menus with shortcuts.
- Windows: `WindowGroup(for: Int)` + DocumentStore registry; File→New/Open
  spawn windows; documents own their UndoManager.
- Headless hooks: `SIMPLESPREAD_SCREENSHOT` renders the real window to PNG
  and exits (CI smoke test); `SIMPLESPREAD_DEMO` seeds sample content.

## 9. Testing strategy

312 tests across three suites, engineered around the risk profile:

- **Core (215):** addressing round-trips; date serial round-trips incl.
  leap years and month-overflow normalization; number-format golden cases
  (grouping, sections, date tokens, m/mm disambiguation, elapsed, carry);
  parser precedence + serialization round-trips; reference transforms
  (copy, insert/delete expand/contract/#REF!, rename); coercion table;
  criteria matcher incl. wildcards/escapes; per-category function tests with
  a fixed clock (TODAY/NOW/RAND deterministic); engine dependency/dirty/
  cycle/volatile/cross-sheet tests; ValueParser (leading zeros, long digits,
  dates, times, injection); structural operations.
- **Files (62):** ZIP round-trips + CRC corruption + CFB rejection + known
  CRC vectors; XLSX write→read round-trips (values, strings incl. control
  chars/emoji/whitespace, formulas+cached values, styles, dates, layout,
  multi-sheet, empty); hand-built "foreign" XLSX fixtures (r-less cells,
  shared formulas, rich text, inline strings, 1904 dates, builtin numFmt
  ids, missing optional parts); CSV parser/sniffer/encoding/import/export
  incl. round-trip.
- **UI (35):** document operations end-to-end (typing→recalc, undo/redo
  incl. dependents and sheet restoration, formats-survive-delete), clipboard
  payloads (reference adjustment, style carriage, replication, overwrite
  semantics), fill, selection navigation (incl. Cmd+arrow data edges), grid
  layout hit-testing.

- **Pivot tables:** 23 real-world files from Excel, LibreOffice and
  ONLYOFFICE (Apache-2.0/MIT/MPL-2.0 test data, see the fixtures README)
  checked for keep/drop decisions, referential integrity of every written
  pivot part against the original (rels, content types, cacheId, numFmtId
  and dxfId meaning, records byte-identical, parts unchanged beyond the
  patched attributes), byte-identical second saves, and the same checks
  after renames and row/column edits; hand-built packages for irregular
  inputs; structural-edit geometry; document-level refusal/removal/undo.
  The engine recomputes all 38 computable fixture pivots exactly as Excel
  laid them out, and refresh reproduces Excel's layout for every refreshable
  fixture. **Excel oracle:** three workbooks of pivots created in SimpleSpread
  (38 pivots: layouts, show-as modes, subtotals, filters, errors and blanks,
  grouping) were refreshed by Excel for the web; Excel's result is checked
  in (Fixtures/ExcelOracle) and `PivotOracleComparisonTests` compares every
  cell, indent, field button, axis line and item order with ours.

External validation: generated XLSX passes `unzip -t` and per-part
`xmllint`; a sample-file generation hook (`SIMPLESPREAD_SAMPLE_DIR`) exists
for manual Excel/Numbers/Sheets checks. `SIMPLESPREAD_PIVOT_OUT=dir` (and
`SIMPLESPREAD_PIVOT_EDIT_OUT=dir`) with `swift test --filter PivotSurvey`
writes every pivot fixture's round trip (and edited round trip) for checks
against the ECMA-376 schemas and other readers; all pass schema validation.

## 10. CI & release

- `ci.yml`: push/PR → macos-15 → `swift build`, `swift test`, plus a
  warn-only headless render smoke test that uploads the window PNG.
- `build.yml`: manual dispatch with version → tests → release build →
  generated icon → .app assembly (PlistBuddy, document types for xlsx/csv)
  → signing → DMG → optional notarization → GitHub Release with composed
  notes. Secrets (same as questrade-mac-menu): `APPLE_CERTIFICATE`,
  `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
  `APPLE_PASSWORD`, `APPLE_TEAM_ID`. Without them, builds are ad-hoc signed.
- `scripts/build-app.sh` does the same locally (ad-hoc).

## 11. Execution order (as run)

1. Research (3 parallel tracks: function semantics, XLSX internals, UX+CSV).
2. Core model → formula engine → functions → calc engine (+ 215 tests).
3. ZIP → XLSX writer/reader → CSV (+ 62 tests, external XML validation).
4. Document view-model → grid → chrome → menus (+ 35 tests, screenshot
   verification of the running app).
5. Icon, build script, entitlements, CI workflows, docs.

## 12. Status & roadmap

**Everything in §1 "in scope" is implemented and tested.**

Shipped since v1 core: view zoom (⌘+/⌘−/⌘0, status-bar control, pinch sync);
Find (⌘F with match navigation, ⌘G/⇧⌘G); Finder/`open` file-association
opening; File → Open Recent (security-scoped bookmarks so a sandboxed app can
truly reopen files, not just list names); CSV/TSV/TXT open routing with forced Save-As to XLSX; in-place
software updates via Sparkle driven by GitHub Releases (Check for Updates…
menu item + automatic background checks; appcast published by the release
workflow — see docs/UPDATES.md; needs the network-client entitlement, now in
entitlements.plist). Sparkle is the project's one third-party dependency; the
spreadsheet stack itself remains dependency-free. Pivot tables: create,
edit, group, refresh and save, and recompute pivots from Excel (§7).

Known gaps and the intended next steps, in priority order:

1. **Interop bake-off:** open generated files in real Excel/Numbers/Sheets
   and fix nits (the writer follows the researched profile; nothing beats
   the real apps).
2. Filtered ranges, the rest of Excel's visible-cells-only behaviour: Copy
   and Delete skip filtered rows (done); still to do are Fill Down and
   formatting a filtered selection, hidden columns, and SUBTOTAL ignoring
   filtered rows.
3. Find & Replace (Find is done; add Replace / Replace All).
4. Paste Special (values only), range-tiling paste.
5. Autofill series inference (1,2→3; dates; weekday names).
6. INDIRECT/OFFSET with dynamic dependency re-extraction per recalc.
7. Background calculation actor for six-figure-cell workbooks.
8. Close-window "unsaved changes" prompt.
9. Localized input parsing (decimal comma, D/M dates).
10. Pivot follow-ups: label/value filters, calculated items, Excel 2010+
    show-as modes, slicers; preserve tables (ListObjects), defined names
    and sheet conditional formatting so table/name sources and pivot
    conditional formats survive as-is; pivot formats (pivot-area styling).
