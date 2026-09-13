# SimpleSpread — Architecture & Execution Plan

A native macOS spreadsheet application written entirely in Swift, built from
scratch with **zero third-party dependencies**. Native file format is XLSX;
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
- Charts, images, comments, conditional formatting, data validation, pivot
  tables, merged-cell *rendering* (model + file round-trip supported).
- Frozen-pane *rendering* (model + file round-trip supported).
- Localization: en-US only (decimal point, M/D dates, comma argument
  separator). The file format layer is locale-invariant per OOXML rules.
- Iterative calculation for circular references.
- Real-time collaboration, autosave/versions.

---

## 2. Architectural decisions (and why)

| Decision | Choice | Rationale |
|---|---|---|
| Project layout | SwiftPM only, no .xcodeproj | Matches questrade-mac-menu; CI is `swift build`/`swift test`; app bundle assembled by script/workflow with PlistBuddy |
| Dependencies | None | "From scratch" requirement; ZIP via Compression framework raw DEFLATE, XML via Foundation XMLParser, UI via SwiftUI+AppKit |
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
    Functions*.swift          8 category files, 156 functions
    CalculationEngine.swift   dependency graph, dirty propagation, cycles
    WorkbookOperations.swift  structural edits with formula rewriting
    ValueParser.swift         shared input-parsing pipeline
  SpreadsheetFiles/
    ZipArchive.swift          minimal ZIP reader/writer + CRC32 + DEFLATE
    XMLSupport.swift          escaping + _xHHHH_ encoding
    XLSXWriter.swift          OPC package writer (interop profile)
    XLSXReader.swift          SAX reader (rels-driven, tolerant)
    CSV.swift                 parser/sniffer/decoder/importer/exporter
  SpreadsheetUI/
    SelectionState.swift      selection model + data-edge navigation + GridLayout
    SpreadsheetDocument.swift document view-model (edit/undo/clipboard/files)
    SpreadsheetGridView.swift AppKit grid (draw, mouse, keyboard, editor)
    GridContainer.swift       NSViewRepresentable + focused values
    Clipboard.swift           NSPasteboard integration
    ContentView.swift         window chrome (format bar, formula bar, tabs)
    App.swift                 App scene, DocumentStore, menu commands
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
  cells, interval entries for larger), dirty-set BFS, DFS topological
  evaluation with visiting-state cycle detection, volatile set (NOW, TODAY,
  RAND, RANDBETWEEN) recalculated on every edit. Structural edits rebuild the
  whole graph (`rebuildAll`) — correct first, incremental later.
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
heights, mergeCells; docProps. Reader resolves parts via relationships
(never hard-coded paths), infers missing `r` attributes, concatenates
rich-text runs, expands shared formulas by reference translation, maps
builtin/custom numFmts, and normalizes 1904-system dates (+1462 on
date-formatted numerics). Cells with formulas we can't evaluate surface
#NAME? after recalc — deliberate honesty over stale cached values.

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
Stored + raw-DEFLATE (Compression framework `COMPRESSION_ZLIB`), correct
CRC-32 in local + central headers, no data descriptors, no ZIP64; reader
scans EOCD backward, trusts the central directory, verifies CRCs, and
rejects CFB (encrypted/legacy .xls) containers with a clear error.

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
- Chrome: format bar (B/I/U, alignment, number-format menu, colors),
  name box + formula bar, sheet tabs (add/rename/delete/switch), status bar
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

External validation: generated XLSX passes `unzip -t` and per-part
`xmllint`; a sample-file generation hook (`SIMPLESPREAD_SAMPLE_DIR`) exists
for manual Excel/Numbers/Sheets checks.

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

**Everything in §1 "in scope" is implemented and tested.** Known gaps and
the intended next steps, in priority order:

1. **Interop bake-off:** open generated files in real Excel/Numbers/Sheets
   and fix nits (the writer follows the researched profile; nothing beats
   the real apps).
2. Frozen-pane and merged-cell rendering in the grid (model+file already
   round-trip).
3. Find & replace (Cmd+F).
4. Paste Special (values only), range-tiling paste.
5. Autofill series inference (1,2→3; dates; weekday names).
6. INDIRECT/OFFSET with dynamic dependency re-extraction per recalc.
7. Background calculation actor for six-figure-cell workbooks.
8. Close-window "unsaved changes" prompt; Open Recent menu; file-association
   opening (bundle Info.plist already declares document types).
9. Localized input parsing (decimal comma, D/M dates).
