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
- Editing images, comments, conditional formatting and data validation.
  Files that have them keep them through a save (§7), but SimpleSpread
  doesn't show or change them. (Charts are shown and edited: "Charts" in §7.)
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
| Undo | Cell-level snapshots for edits; inverse edits plus a small log for row/column insert and delete; an in-memory copy-on-write workbook snapshot (`WorkbookSnapshot`) for sheet and pivot ops | Exact (nothing the file writer can't model is lost, pivots stay editable) and cheap to take; it was an XLSX round-trip, which cost seconds per step on big sheets and was lossy |
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
  SpreadsheetUI/               (see docs/IPAD.md: one module, three folders)
    Shared/                    builds for Mac and iPad
      SelectionState.swift      selection model + data-edge navigation + GridLayout
      SpreadsheetDocument.swift document view-model (edit/undo/clipboard/files)
      SpreadsheetDocument+Pivots.swift  insert/edit/group/refresh with one undo step each
      GridGeometry.swift        grid coordinates: panes, hit testing, scroll targets
      GridRenderer.swift        draws the grid (Core Graphics, both platforms)
      GridController.swift      grid behaviour: edit modes, selection, fill, resize, keys, menus
      Clipboard.swift           pasteboard integration (NSPasteboard / UIPasteboard)
      ContentView.swift         window chrome (format bar, formula bar, tabs)
      App.swift                 DocumentStore, shared menu commands
      PivotFieldsPanel.swift    the PivotTable Fields panel + Insert PivotTable sheet
      PivotGridStyle.swift      Excel-style pivot banding rules
      Platform.swift            the few AppKit/UIKit naming differences
    Mac/                       AppKit shell (#if os(macOS))
      SpreadsheetGridView.swift NSView grid: events → GridController, NSTextField editor
      GridContainer.swift       NSViewRepresentable
      MacApp.swift              App scene, app delegate, File menu, Sparkle menu
      SavePrompt.swift          save panels and "save changes?" prompts
    iOS/                       UIKit shell (#if os(iOS))
      GridView.swift            UIScrollView grid: touch/pointer/keys → GridController
      SpreadsheetFile.swift     UIDocument: coordinated, autosaving file access
      IOSApp.swift              App scene, document browser, editor screen, File menu
  SimpleSpread/
    main.swift                calls SimpleSpreadApp.run()
```

**Dependency rule:** Core knows nothing of Files or UI. Files depends only on
Core. UI depends on both; its Shared code never names AppKit or UIKit
directly (Platform.swift and the pasteboard calls in Clipboard.swift aside). Tests mirror the split.

## 4. Data model

- `CellValue`: `empty | number(Double) | string | bool | error(CellError)`.
  Dates ARE numbers; display is a property of the cell's number format.
- `Cell`: value + optional formula text + style index. Default cells are
  dropped from storage (`Sheet.cells: [CellAddress: Cell]` stays sparse).
- `CellStyle` is a value type deduplicated through `StyleTable` (index 0 =
  default) — mirrors XLSX `cellXfs`, and cell `s=` attributes are written
  straight from style indices.
- Rows and columns have formats of their own (`Sheet.rowStyles`,
  `columnStyles`; XLSX `row@s` with `customFormat`, `col@style`), and
  columns can be hidden (`hiddenColumns`). A cell with no style of its own
  (index 0, stored or not) shows its row's format, else its column's, as in
  Excel (`Sheet.styleIndex(at:)`); everything that shows, copies or saves
  a style uses that. In the file a cell without `s` is plain, so the writer
  writes what each cell shows, and the reader stores a cell styled as it
  would inherit as 0; a plain cell under a formatted row or column gets
  `StyleTable.plainIndex()` (the default under another index;
  `Workbook.storableStyleIndex` applies both rules). Formatting a selection
  of whole columns or rows sets their format, restyles only the cells with
  a style of their own (and the crossings of formatted rows and columns,
  which take both), and undoes from the old row and column formats plus
  those cells: Bold over 1,048,576 × 10 numbers takes 0.3 s (debug), not 7.
  Formats that depend on a cell's place in the selection (borders) still go
  cell by cell. Inserted rows and columns don't copy their neighbour's
  format yet, and outline levels (grouping) aren't kept.
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
  appears. Sheets keep their used range up to date incrementally.
- **Row and column inserts and deletes** don't rebuild the graph.
  `StructuralChange` describes the edit, and everything that holds a
  position moves by it: cells, formula text, layout tables, pivot tables,
  and (later) anything else in the file that's anchored to cells.
  `WorkbookOperations.apply` returns a `StructuralEditResult` (rewritten
  formulas, removed cells, the parts outside the cells as they were);
  `CalculationEngine.apply` moves the graph entries of the formulas that
  moved or whose references changed, adjusting their parse trees in place
  (formulas using names are re-parsed). A per-formula record of the last
  row and column it reads lets it skip the rest without looking at their
  trees. Only formulas whose result can change recalculate: a reference
  that spans or cuts into the edit, a deleted reference, ROW/COLUMN when
  they or their references moved, and names the edit rewrote. A formula
  that moved with everything it reads keeps its value. Sheet operations
  still use `rebuildAll`. `StructuralEditEngineTests` holds the in-place
  path to a full rebuild over random workbooks, edits and undos.
  `spreadsheet-bench --edits` times edits on synthetic workbooks; `--undo`
  times a row insert with its undo and redo (release, 1,048,575 formulas:
  1.9 s near the top, where every formula moves, 0.6 s near the bottom;
  a full rebuild took 5.4 s).
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
date-formatted numerics). Defined names (`<definedNames>`, including
`_xlnm.*` print areas/titles) are read into `Workbook.definedNames`, resolved
by the evaluator, adjusted by structural edits like any reference, and
written back. Function prefixes Excel writes for post-2007 functions
(`_xlfn.`, `_xlws.`) are stripped on read and added back on write. On open, a
formula that can only give #NAME? here (a function we don't have, an
undefined name) or that doesn't parse keeps the cached value from the file;
once its inputs change it recalculates (to the error).

Reference adjustment (insert/delete rows and columns, sheet rename/delete,
copy, fill, sort) works on formula *tokens*, not on a parse:
`FormulaTextRewriter` rewrites A1 references and copies every other token
verbatim, so formulas the parser rejects (array constants, table references,
3-D references, intersections) move too and constants keep every digit.
Number→text has three contracts: `generalString` (grid only, ~10 digits),
`roundTripString` (formula text, the cell editor: exact), and
`textCoercionString` (`&`, text functions: Excel's 15 digits).
Hidden sheets (`state`) are kept (`Sheet.isHidden`; veryHidden comes back as
hidden).

**Carried content.** What the model doesn't hold is carried through a save
(`CarriedParts`, behind Core's `CarriedContent` protocol on
`Workbook.carriedContent`):
- every part a worksheet links to and what those link to in turn (drawings
  with their charts and images, comments and their VML boxes, threaded
  comments, tables, OLE objects and controls, printer settings), written at
  their original paths with their relationships rebuilt under their
  original ids;
- the worksheet elements the writer doesn't produce (sheetPr, protection,
  conditional formatting, data validation, hyperlinks, print setup and page
  breaks, sparklines and other extLst content), kept as XML fragments and
  spliced back in schema order, with the original root's namespace
  declarations and `mc:Ignorable`;
- at workbook level, the theme, links to other workbooks, the people behind
  threaded comments, custom XML and custom document properties, and the
  `<workbook>` children that are settings (protection, custom views, …).

A part is carried only if everything it links to is, and an element
pointing at a part that isn't carried goes too, so a saved file never has
a dangling link. Not carried, and still reported: chart sheets (they open as
empty sheets; their chart is carried on them), macros, slicers and
timelines, data connections, query tables and the Data Model, linked data
types, change history, signatures, add-ins, Strict-namespace sheets, plus
what the model rewrites itself (outlines, rich text).

Edits keep carried content lined up with the cells. Every row and column
insert or delete (the same `StructuralChange` that moves cells), sheet
rename and sheet delete goes to `CarriedContent.applying`, which:
- moves drawing anchors, honouring "move but don't size" and "don't move";
- moves comment, sqref, hyperlink and table references, removing those whose
  cells were deleted, with their VML boxes and empty containers;
- moves page breaks, and adds or removes table columns for column edits
  inside a table;
- rewrites formulas in charts, rules, validations, sparklines, VML controls
  and hyperlink locations with the same reference rewrite as cell formulas.

**Charts.** Charts live in the carried parts like everything else there
(a sheet's drawing holds an anchor per chart, pointing at its chart part),
so saving, undo (a value swap), snapshots and structural edits need nothing
of their own. `SheetChart` (what's drawn) and `ChartSettings` (what the
panel edits) are always derived from the parts, never kept beside them.
They live in SpreadsheetFiles, so GridController, GridRenderer and the
document's chart commands import it: the price of the parts being the model.
- *References* (`ChartReference`): the one place a chart's `c:f` is
  followed, for drawing, for the caches written to the file and for the
  panel's data range. It follows sheet references, unions and this
  workbook's defined names (`Book1.xlsx!Sales`, `[0]!Sales`); not other
  workbooks or names that compute a range, which keep their cached values.
  It reads only as far as the sheet's data goes (a whole-column reference
  costs what the data does), and leaves out hidden rows and columns when
  the chart plots visible cells only (as Excel's caches do too).
- *Reading* (`SheetChartSource`): column and bar, line, area, pie and
  doughnut, scatter, clustered / stacked / 100% stacked, column + line
  combinations, secondary value axes (drawn as a right-hand scale), titles
  (with Excel's automatic "Chart Title"), axis titles, legends, data labels
  (per series), theme and explicit series colours; 3-D types draw flat;
  every chart in a group of shapes, placed in its group's frame. Numbers in
  the XML are clamped (counts, indexes, anchors, sizes), so an odd file
  can't crash or stall. Series keep at most 4,096 points (the lowest and
  highest of each run, so peaks survive; a pie's smallest slices become
  "Other"). Parsing is kept per part, keyed by its bytes (moving a chart
  reparses only the drawing). What a chart read from the cells is kept
  with what it read: the blocks of cells, and their sheets' change stamps,
  hidden rows and columns and row/column formats, and the defined names. A
  change reads it again only if one of those changed, or a cell changed
  inside one of its blocks (`Sheet.changedCells(since:)`: a short log of
  changed cells; a formula's recalculated value is logged like an edit);
  row and column resizes don't count at all.
- *Drawing* (`SheetChartLayer`): Swift Charts into an image per chart,
  never inside the grid's draw: a chart shows its last image (or a plain
  box) while a new one is made, one per run-loop turn. Swift Charts sees
  at most what the plot's width can show (2 points per pixel for lines,
  1 per 3 pixels for bars), with categories plotted by position. Images
  are keyed by a fingerprint of what the chart shows, capped at 8
  megapixels each (scaled up beyond) and 256 MB in all. Other kinds
  (radar, stock, bubble, surface, and the chartex types such as waterfall
  and treemap) are placed and drawn as a labelled box.
- *Making and changing* (`XLSXChartEditor`, `ChartXML`): Insert ▸ Chart
  makes series from the selection (or the block around the active cell,
  trimmed to the data) the way Excel does: a text header row names the
  series, a text first column gives the categories, series run down columns
  unless the block is wider than tall, a scatter takes x from the first
  column. New charts get Excel's default style, written as Excel writes it,
  with values cached beside the references. Settings changes touch only
  what they change, in schema order, under the part's own prefixes
  (Excel's `c:` or a default namespace). A new type or data range rebuilds
  the plot series by series: each `<c:ser>` is kept and moved into a group
  of its new kind, losing only children that kind can't have (a pie has no
  trendline), and only references that changed are rewritten; groups and
  axes, a secondary axis included, are kept where both kinds have them. At
  save, caches that are there are brought up to date with the cells when
  their values differ (a save without edits keeps the parts' bytes).
  Checked in Excel for the web: new charts of every kind, and Excel's own
  charts after each kind of change, open without repairs and look as
  intended (`ChartOracleFiles` writes the files).
- *Interaction* (GridController, both platforms): a click or tap selects
  the topmost chart (outline and handles; round, larger ones on iPad); drag
  moves it and a handle resizes it (by how far the pointer moved, so a drag
  across a frozen pane's edge doesn't jump), arrows nudge it (⇧: 10 px; a
  run is one undo step), Delete removes it, Escape or a click on a cell
  deselects. Tab and ⇧Tab go chart to chart, and Insert ▸ Select Next Chart
  (⌥⌘J) reaches one from the cells; VoiceOver finds each chart on screen (an
  element on the Mac, an action on iPad). A chart in a group of shapes can
  be selected, edited and deleted (the rest of the group stays) but moves
  only with its group. Copy puts the chart on the pasteboard as a picture.
  The Chart panel shows beside the grid while a chart is selected; changes
  apply at once, one undo step each (a run of colour changes is one).
- Not covered: editing the secondary axis itself, trendlines and error bars
  (kept, not drawn or edited), axis scale and number formats, copying a
  chart as a chart, chart sheets.

The content is a value: workbook snapshots, the structural undo record
(`StructuralEditResult.Before`) and the background save copy it for free.
At save, table column names are synced to their header cells (Excel repairs
a mismatch); a header cell that's empty or repeats a name gets the name
written into it in the file. Sorting doesn't move comments with their rows.
The reader lists what isn't carried (`UnsupportedContent`: parts not
carried, by content type; elements of sheets that aren't carried; rich-text
runs; dropped pivots), and the first ⌘S over such a file asks: Save a
Copy… / Save Anyway / Cancel (`DocumentSaving.plan`); Save As only notes it
in the panel. Checked in Excel for the web: files with charts, comments,
tables, conditional formatting, validation, hyperlinks and sparklines open
without repair after inserts, deletes and renames.
Both worksheet readers feed one `SheetCellBuilder` (row/column inference,
shared formulas, value types, bounds on every number from the file), and a
fuzz test checks they never trap and agree.

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
Import: BOM/UTF-16, then UTF-8 with only invalid bytes read as CP1252
(per field, so one stray CP1252 byte doesn't re-decode the whole file); delimiter sniffing
by column-count-consistency scoring; quote-aware state machine (CRLF/LF/CR,
`""`, embedded newlines, ragged rows, unterminated-quote fail-soft);
type inference through the shared ValueParser with leading-zero and
>15-digit protection; `=`-prefixed fields stay text; semicolon dialect
implies decimal-comma numbers. Export: computed values only; minimal
quoting; CRLF; UTF-8 BOM (Excel double-click compatibility); numbers
machine-canonical; dates ISO 8601; display-mode option.

### ZIP (under XLSX)
Stored + raw-DEFLATE, correct CRC-32 in local + central headers, no data
descriptors, no ZIP64 (the writer throws `ZipError.tooLarge` past 4 GB or
65,534 entries rather than truncating); reader scans EOCD backward, trusts
the central directory within limits (4 GB per entry, 8 GB in all, no
deflated entry over 8 MB claiming more than 1000:1), verifies CRCs, and rejects CFB (encrypted/legacy .xls)
containers with a clear error. Inflate uses the Compression framework;
deflate and CRC-32 use the system zlib. Deflate runs pigz-style on all
cores: 1 MB chunks, each primed with the previous 32 KB and ended with a
sync flush, joined into one ordinary stream (level 6 size, ~8× faster).

### Large files
- Opening runs off the main thread (`SpreadsheetDocument.load`, then
  `make` on the main actor) behind a progress panel with Cancel
  (`FileLoading.swift`); the panel only appears after 0.25 s.
- CSV (`CSVFastImport.swift`): bytes are scanned in place (the file is
  memory-mapped, and each field is checked for UTF-8 as it is imported,
  with invalid bytes read as CP1252); common fields (plain numbers, ISO dates, text that
  can't be a value, TRUE/FALSE) skip ValueParser with identical results;
  the import stops at 1,048,576 rows and reports truncation. The old
  String-based importer remains as the test reference.
- XLSX (`XLSXSheetDataScanner.swift`): `<sheetData>` is read by a byte
  scanner (UTF-8 parts only) that shares its cell rules with the XMLParser
  delegate and follows XML's line-end and attribute normalisation; the
  rest of the sheet still goes through XMLParser, and anything unexpected
  falls back to XMLParser for the whole sheet, which also reports progress
  and stops on Cancel. The writer builds `<sheetData>`
  as bytes (`XLSXSheetDataWriter.swift`). Tests compare both directions
  with the XMLParser/String versions on every fixture.
- Grid: `GridLayout` offsets are O(log k) over the rows/columns with
  non-default sizes (prefix sums + binary search), cached per revision;
  status-bar statistics look up the selection rather than scan the sheet.
- Save runs in the background (`BackgroundSave.swift`): the main thread
  takes a `Workbook.copy()` snapshot (microseconds) and the writer
  (~4.5 s for a full sheet) runs on a queue behind the shared progress
  panel (`ProgressPanel.swift`, after 0.25 s, with Cancel), while the
  user keeps editing; the document is clean only if its `changeCount`
  didn't move during the save. One save per document at a time; close
  and quit wait for saves. CSV import/export run the same way. The first
  edit during a save copies that sheet's cell table once (~0.2 s for a
  full sheet). `spreadsheet-bench --save-full-sheet` measures all this.
- Still proportional to sheet size: the first calculation (~4 s per
  million formulas) and Find, which scans every cell per keystroke.

## 8. Application layer

- `SpreadsheetDocument` (MainActor ObservableObject) is the single write
  path: typed input (shared ValueParser: `=formula`, numbers, `5%`, `$`,
  dates, times, TRUE/FALSE, `'`-escape, Plain-Text format suppression),
  style application, structural edits, sheet ops, clipboard, fill, file I/O.
  Every operation is one undo group (`groupsByEvent = false` + explicit
  groups so behavior is identical under tests and menus).
- Undo of inserting and deleting rows and columns
  (`SpreadsheetDocument+StructuralUndo.swift`): no copy of the sheet. The
  step records the cells a delete removed, the original text of every
  formula the edit rewrote (an edit and its opposite rewrite the same
  formulas, so the rest needn't be kept), and the small layout tables,
  defined names and pivot definitions (`StructuralEditResult.undo`). Undo
  runs the opposite edit and puts those back; redo runs the edit again;
  neither rebuilds the engine (see §5). A step on a full 1,048,576 × 10
  sheet holds a few KB (a whole-sheet snapshot would hold ~1 GB, the old
  XLSX snapshot 24 MB).
- Undo of other workbook-level commands (add, delete, rename and move
  sheet, Import CSV, every pivot edit, Delete over a pivot): `takeSnapshot()`
  before the command, `registerSnapshotUndo` after it. The snapshot is
  `Workbook.copy()` — every table shared copy-on-write — plus the active
  sheet and selection. Once the command has run, cell tables it didn't
  change are let go (each `Sheet` counts changes to its cells), so a
  snapshot keeps only what the command replaced: a deleted sheet, tables
  of sheets whose formulas a rename rewrote, old pivot definitions. Undo
  puts the snapshot back in place (the engine and views keep the same
  `Workbook`; sheet ids are kept, so cell undo records still apply),
  registers the state it replaced as the redo, and runs `rebuildAll`
  unless the command left every formula alone (move sheet; add sheet when
  no formula was waiting for its name). Frozen panes stay as they are. A
  failed command puts its snapshot back directly, never by undoing. With
  1M formulas undo is mostly `rebuildAll`, ~3 s (release).
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
  criteria with wildcards, and filter evaluation that hides rows. A layout
  command's undo step records only what it changed (`SheetLayoutChange`:
  merges added/removed, rows hidden/shown, heights, the filter), so undoing
  it leaves later changes alone. Row and column resizes are one undo step
  per drag; frozen panes are a view setting and, as in Excel, not undoable.
  Unsupported criteria (top 10, dynamic, colour) are kept
  as XML and written back, but hide nothing when re-applied.
- Chrome: toolbar (undo/redo, format painter, clear formatting; $ / % /
  decimal places / number-format menu; font, size, B/I/U/S, colors, borders;
  horizontal and vertical alignment, wrap, merge; Sort & Filter menu; AutoSum
  split button). Larger font sizes grow short rows (never shrink) in the same
  undo step. Name box + formula bar, sheet tabs (add/rename/delete/switch), status bar
  (Sum/Avg/Count), standard menus with shortcuts.
- Formatting a selection of up to 100,000 cells formats every cell in it.
  A bigger one (whole columns, ⌘A on a big sheet) formats the cells inside
  the used range — the stored ones and the blanks among them — and never
  creates formatted blanks past the data (there are no whole-column
  formats). Formatting undo restores styles only. Clear Formatting, Merge
  and Sort walk the stored cells, not every address in the rectangle.
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
