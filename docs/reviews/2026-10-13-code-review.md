# SimpleSpread — code review, 13 October 2026

## Scope and method

- **What was reviewed:** `main` at `47362b3`, the merge of the large-files work (`9a2cd34` "Open huge files fast and in the
  background; save big sheets faster") on top of v1.4.1 (`2e07018`). The working tree is clean: nothing in it is
  uncommitted except this file.
  - The "Origin" column in §2 says where each problem comes from. **1.4.1** means it was already in v1.4.1 or earlier.
    **9a2cd34** means the large-files commit added it.
  - Most problems are older than the large-files commit. That commit matters mainly because it makes 1,048,576-row files
    openable, which turns many older "slow on big sheets" paths into freezes that users can reach.
- **Coverage:** all of `Sources/` (about 17,000 lines of Swift), the tests, the CI and release workflows, the scripts and
  the docs. The review was split into five areas:
  - the formula engine and model
  - the function library and number formats
  - pivot tables
  - file I/O
  - the UI

  The CI, release and repository checks were done separately.
- **Focus (owner's instruction):** fundamental flaws, clear performance mistakes, and structural or architecture
  problems. Nit-picks, style and rare Excel corner cases are left out.
- **How findings were checked:** findings were reproduced with throwaway tests (Swift Testing) in disposable copies of the
  tree, outside the repository.
  - **Confirmed** means a test reproduced the bug.
  - **From reading** means the finding comes from reading the code.
  - All timings come from **debug** builds unless stated. Release builds are faster by a constant factor; the growth rate
    is the same.
- **Re-checked against the committed code:** the review was first written against the working tree before the
  large-files work was committed. It was then re-checked against `47362b3`:
  - **The source matches exactly.** A `git archive` of `47362b3` was compared file by file with the reviewed tree, and no
    source or test file differs. So every location and line number below is current, and so is every "from reading"
    finding.
  - **Every repro test was re-run** against a clean export of `47362b3`. That is 55 tests, plus one new probe covering
    12 findings that were first confirmed by ad-hoc runs. **Every confirmed finding still reproduces**, with the same
    outputs:
    - The same crash messages at the same lines (for example `ValueParser.swift:234: Fatal error`, and "Range requires
      lowerBound <= upperBound" in the sheet scanner).
    - The same wrong values, for example `ROUND(1.005,2)=1`, `_xlfn.IFNA` giving `#NAME?`, `COUNTIFS` giving `#N/A`,
      and the pivot rows summing to 30 under a grand total of 1030.
    - Timings within a few percent of the first run. One pivot `compute()` took 120 s this time (121 s before).
- **Baseline health:**
  - `swift build --build-tests` succeeds and all **636 tests pass** on `47362b3` (about 8 s).
  - A clean build shows 5 compiler warnings. Two of them are Swift 6 Sendable warnings added in `9a2cd34`
    (`ZipArchive.swift:74`, `FileLoading.swift:105`).
  - The published v1.4.1 DMG was downloaded and checked:
    - It is Developer ID signed (team ZK25D4KTDC), notarized, and accepted by Gatekeeper.
    - It is sandboxed with the intended entitlements.
    - It carries `SUPublicEDKey`.
    - Every appcast item has an EdDSA signature.

  The release pipeline itself is sound. No release has been cut from `47362b3` yet.

---

## 1. Summary

SimpleSpread is a well-built app. In particular:

- The module split is clean and almost all of it is testable.
- The tests are serious: Excel-refreshed oracle files for pivots, and fixture comparisons for the new byte scanners.
- Several hard parts are done carefully:
  - the dependency walk without recursion
  - the ZIP reader's bounds checks
  - the pigz-style parallel deflate
  - CSV injection safety
  - pivot preservation when a pivot is not changed
  - the background open with cancel

The serious problems are not scattered bugs. They come from a small number of **structural decisions**, each of which
produces a whole class of defects:

1. **Save is a lossy rewrite, and undo is built on Save.**
   - ⌘S on an opened `.xlsx` writes over the original from the in-memory model. It silently drops charts, images,
     comments, conditional formats, data validation, tables, hyperlinks, defined names, hidden-sheet state, column
     styles and rich text.
   - The same writer is the undo mechanism for every structural edit and every pivot edit. So undo is lossy too, and on
     a big sheet every such edit costs a full XLSX write on the main thread.
2. **One "number → text" function serves four jobs:** screen display, the cell editor, formula re-serialisation, and
   `&`/text coercion. It keeps 10 significant digits. So double-clicking a cell and pressing Enter changes its value.
   Inserting a row rewrites every shifted formula's constants to 10 digits, and the result is saved.
3. **Formula text is the source of truth, and edits are done by re-parsing.** A formula the parser does not understand
   is skipped during insert, delete, sort, copy and fill. Its cell moves, but its references do not. The parser rejects
   things common in real Excel files: empty arguments, array constants, table references, 3-D references, and every
   `_xlfn.` function. Those formulas also show `#ERROR!` or `#NAME?` the moment a file opens, because opening
   recalculates everything.
4. **There is no validation layer between untrusted input and the code.**
   - About 20 sites convert a `Double` to `Int` without a range check, or index into a list with an index from a file.
   - Each of them is a **crash** on plausible input: a 19-digit ID, `ISEVEN(1E20)`, a date cell holding 1E20 (crashes
     while *drawing*), an empty `t="d"` cell, a malformed pivot index, and a one-byte `<sheetData>` (new scanner).
5. **Everything runs on the main thread, and many operations are O(sheet) or O(n²).**
   - The large-file work moved *open* off the main thread. Save, structural undo, Find, recalculation, pivot compute
     and paste are still on it.
   - Range dependencies, AutoFilter value lists, `currentRegion`, paste, and the pivot engine are quadratic.
   - Each of these freezes for seconds to minutes on sheets the README now advertises.
6. **Editing state lives only in the AppKit view, and the Edit menu bypasses the responder chain.**
   - ⌘V/⌘X/⌘Z/⌘A act on the grid even while a text field is being edited.
   - An open cell editor commits to whichever sheet is active when it closes.

If only a few things get fixed, fix them in this order:

1. Stop silent data loss on save (§3.1).
2. Split the number-to-text function (§3.2).
3. Put a crash firewall around numeric conversions and file indices (§3.4).
4. Route the Edit menu through the responder chain and give the editor a fixed target (§3.6).
5. Replace XLSX-snapshot undo with per-command undo (§3.1, §3.5).

---

## 2. Findings at a glance

Severity scale:

- **Critical:** silent data loss or corruption, or a crash on plausible input.
- **High:** wrong results users will hit, or a major performance cliff.
- **Medium:** real, but narrower.

Finding IDs say which area found them: CE = formula engine and model, CF = function library and number formats,
IO = file I/O, PV = pivot tables, UI = the UI.

| # | Severity | Finding | Area | Origin | Checked |
|---|---|---|---|---|---|
| 1 | Critical | ⌘S writes over the original `.xlsx` with a lossy rewrite and no warning | Files/UI | 1.4.1 | from reading |
| 2 | Critical | Number → text keeps 10 significant digits; editing a cell, inserting rows, fill and `&` change values | Core/UI | 1.4.1 | confirmed |
| 3 | Critical | Formulas the parser rejects are not adjusted by insert, delete, sort, copy or fill | Core | 1.4.1 | confirmed |
| 4 | Critical | Crash class: unchecked `Int(Double)` / `Int(String)!` and unchecked file indices (≈20 sites) | all | 1.4.1 + 9a2cd34 | confirmed |
| 5 | Critical | Insert PivotTable on "This sheet" silently erases cells under the 18×3 placeholder | Pivots | 1.4.1 | confirmed |
| 6 | High | Edit menu ⌘X/⌘C/⌘V/⌘A/⌘Z act on the grid while a text field is focused | UI | 1.4.1 | from reading (code checked twice) |
| 7 | High | An open cell editor commits to the wrong sheet or cell after a tab switch or row insert; ⌘W/⌘S ignore it | UI | 1.4.1 | confirmed |
| 8 | High | Defined names → `#NAME?` on open, and dropped on save | Files/Core | 1.4.1 | confirmed |
| 9 | High | `_xlfn.` / `_xlws.` prefixes not handled → IFNA, XLOOKUP, CONCAT… give `#NAME?` in Excel files | Core | 1.4.1 | confirmed |
| 10 | High | Empty function arguments (`IF(a,,b)`, `VLOOKUP(x,r,2,)`) are parse errors | Core | 1.4.1 | confirmed |
| 11 | High (perf) | Structural edits, pivot clicks and their undo serialise the whole workbook to XLSX on the main thread | UI | 1.4.1; exposed by 9a2cd34 | confirmed (timed) |
| 12 | High (perf) | Dependency graph: a large-range reference makes each edit and recalculation O(n²) | Core | 1.4.1 | confirmed (timed) |
| 13 | High (perf) | `usedRange` scans every cell; called for each whole-column reference evaluation and each revision | Core/UI | 1.4.1 + 9a2cd34 | confirmed |
| 14 | High (perf) | Pivot engine is O(cells × records) and recomputes during drawing after every edit | Pivots | 1.4.1 | confirmed (121 s, debug) |
| 15 | High (perf) | Paste is O(N²) (`firstIndex` inside the loop) | UI | 1.4.1 | confirmed |
| 16 | High (perf) | AutoFilter value list and matching O(n²); `currentRegion` O(rows²) | Core | 1.4.1 | confirmed (timed) |
| 17 | High (perf) | Find re-renders every cell per keystroke; selection commands build every address in the rectangle | UI | 1.4.1 | confirmed / from reading |
| 18 | High | Hangs: NETWORKDAYS/WORKDAY/COMBIN/IPMT can loop up to 9e15 times | Functions | 1.4.1 | from reading |
| 19 | High | Copy origin kept in a static per-document map, so cross-window or post-relaunch pastes shift formulas wrongly | UI | 1.4.1 | from reading |
| 20 | High | Fill Down/Right overwrite rows the AutoFilter hides | UI | 1.4.1 | confirmed |
| 21 | High | A reference to a sheet added later is never tracked, so its value stays stale `#REF!` | Core | 1.4.1 | confirmed |
| 22 | High | Number formats: `[h]` an hour short, scaling comma before a literal ignored, conditional sections dropped | Functions | 1.4.1 | confirmed |
| 23 | High | Criteria functions: an error cell in a criteria range poisons SUMIFS/COUNTIFS…; date-text criteria never match | Functions | 1.4.1 | confirmed |
| 24 | High | `ROUND(1.005,2)=1`, and display rounding works on raw binary values (0.145 in `0%` shows 14%) | Functions | 1.4.1 | confirmed |
| 25 | High | A blank lookup key matches blank rows and returns unrelated data | Functions | 1.4.1 | confirmed |
| 26 | High | Pivots: base item wrong after Sort/Refresh; grouped fields sort as text; blanks dropped from rows but not totals; stale filter XML | Pivots | 1.4.1 | confirmed / from reading |
| 27 | Medium | Byte scanner differs from XMLParser on CRLF and non-UTF-8 text; fallback not cancellable | Files | 9a2cd34 | confirmed |
| 28 | Medium | ZIP bomb: declared sizes are trusted for allocation; the scanner reserves capacity from them | Files | 1.4.1 + 9a2cd34 | from reading |
| 29 | Medium | A part or archive over 4 GiB traps on save (`UInt32(...)`) | Files | 1.4.1; exposed by 9a2cd34 | from reading |
| 30 | Medium | Mixed-encoding CSV: one CP1252 byte turns all UTF-8 into mojibake; the large-file importer reads the file twice | Files | 1.4.1 + 9a2cd34 | confirmed |
| 31 | Medium | Undo of a layout step reverts unrelated later resize/freeze changes | UI | 1.4.1 | confirmed |
| 32 | Medium | TSV clipboard is not quoted or unquoted (multi-line cells break the round trip with Excel/Numbers) | UI | 1.4.1 | confirmed |
| 33 | Medium | Drawing walks every hidden row between the first and last visible row (filtered big sheets) | UI | 1.4.1 | from reading |
| 34 | Medium | Sort moves data into and out of rows hidden by hand | UI | 1.4.1 | from reading |
| 35 | Medium | No array evaluation (`SUMPRODUCT((A>1)*B)` → `#VALUE!`), and not documented | Functions | 1.4.1 | confirmed |
| 36 | Medium | Approximate lookups scan the whole range (no binary search) | Functions | 1.4.1 | from reading |
| 37 | Medium | Which cell in a cycle gets `#CYCLE!` depends on hash order, so it changes between launches; sparse SUM order also varies | Core | 1.4.1 | high |
| 38 | Medium | Grid has no accessibility (VoiceOver sees nothing) | UI | 1.4.1 | from reading |
| 39 | Medium | Type-to-edit bypasses the input method (CJK IME); End/F-keys enter a private-use character into the cell | UI | 1.4.1 | confirmed (End key) |
| 40 | Medium | Pivots: range-group edge bucket wrong; outlier refresh creates 10⁸ groups; value sort lost; "saved unchanged" not quite true | Pivots | 1.4.1 | confirmed / from reading |

Totals after merging duplicates across reviewers: **5 Critical, 21 High, 14 Medium.**

---

## 3. Architecture and structural issues

These are the root causes. Most of the findings in §4 are symptoms of one of them.

### 3.1 The XLSX writer is both a lossy file format and the undo mechanism

**Where:**

- `SavePrompt.swift:14-16` (save in place whenever `fileURL` is set)
- `SpreadsheetDocument.swift:1095-1101, 1154` (every opened `.xlsx` gets `fileURL`)
- `XLSXWriter.swift:16-55` (fixed set of parts)
- `SpreadsheetDocument.swift:230-251` (`registerWorkbookUndo` / `restoreWorkbook`)
- `SpreadsheetDocument+Pivots.swift:232`

**What happens:**

- **Save throws away everything the model does not hold.** The writer rebuilds the package from the model. Charts,
  drawings and images, comments, conditional formatting, data validation, tables, hyperlinks, defined names (#8),
  `state="hidden"` sheets (they become visible), hidden columns and column styles without a width, sheet protection,
  print setup, theme colours and rich-text runs are all dropped.
  - Nothing warns the user, and ⌘S writes over the source file.
  - `XLSXReadReport` already exists for pivots (`droppedPivots`), but the UI never shows it and it covers nothing else.
  - **Scenario:** open a budget with a chart and comments, fix one number, press ⌘S. The chart and comments are gone
    from disk.
- **Undo is a whole-workbook XLSX round-trip.** Insert or delete rows and columns, add, delete, rename or move a sheet,
  Import CSV, and every pivot edit first run `XLSXWriter.data(for:)` (every sheet, deflated) and keep the bytes on the
  undo stack. Undo then runs `XLSXReader.read`, `rebuildAll`, and another full write for redo.
  - Measured on a 500k-cell sheet in debug: renaming a sheet takes 1.29 s, and undoing the rename 2.24 s.
    `commitInput` takes 0.0001 s.
  - On the README's full 1,048,576 × 10 sheet, the README's own release numbers imply:
    - about 4.5 s of beachball for one row insert or rename
    - about 11 s for its undo
    - a full compressed copy of the file per undo step
  - Because undo goes through the lossy writer, undoing a row insert also deletes the defined names, comments and so on
    from memory.
  - After a pivot undo, every pivot becomes an unparsed "preserved" pivot again.
  - `try?` at line 245 makes a failed snapshot silently non-undoable. When the writer throws, the failure path of
    `insertPivotTable` calls `undoManager.undo()`, which **undoes the user's previous action**.
- **The large-file work covers only Open.** Save (`SavePrompt.swift:35`) and `importCSVSheet`
  (`SpreadsheetDocument.swift:1167`) still run synchronously on the main thread, with no progress and no cancel.

**Direction:**

1. **Make fidelity visible now.** At read time, list what will not survive. The inputs are:
   - unknown content types in `[Content_Types].xml`
   - unknown worksheet children
   - hidden sheets
   - defined names
   - conditional formatting and data validation

   If the list is not empty, treat the file like a CSV import: the first save is Save As, or one confirmation names
   what will be removed.
2. **Longer term, carry unknown parts through unchanged,** as is already done for pivots. Also carry unknown worksheet
   children through as fragments; `XMLRewriter` already exists for this.
3. **Make undo per command.**
   - Row and column insert/delete invert each other through the same reference-adjust code.
   - Sheet rename and move need only the name and the index.
   - Sheet delete needs that one `Sheet` value. It is copy-on-write, so the copy costs O(1) until it is changed.
   - Pivot edits need `pivotCaches`/`pivotTables` (already value types; `transaction` already keeps
     `savedCaches`/`savedTables`) plus the cells in the old and new areas.
   - Keep the XLSX snapshot only as a fallback for small workbooks, if at all.
4. **Move Save off the main thread** behind the same progress panel as Open. Either snapshot the model first or block
   edits while saving.

### 3.2 One number-to-text function is used for display, editing, formula text and coercion

**Where:**

- `NumberFormat.swift:97-115` (`generalString`: 10 significant digits, scientific with a 5-digit mantissa at ≥1e11 or
  <1e-9)
- `CellValue.swift:85` (`rawDisplayString`)
- `Coercion.swift:51` (`displayText`)
- `FormulaAST.swift:131-132` (`.number` → formula text)
- `SpreadsheetDocument.swift:127-155` (`editString`)

**Consequences (all confirmed):**

- **The cell editor changes values.**
  - `editString` returns the 10-digit text, and `commitEditorIfNeeded` commits even when the text is unchanged.
  - Double-click, then Enter: `3.14159265358979` becomes `3.141592654`, and `1234567890123.45` becomes
    **`1.23457E+12`**, which is 1,234,570,000,000.
  - A date-time shown as `m/d/yyyy` loses its time of day. `0.123456` shown as `0.00%` becomes `0.1235`.
- **Structural edits and fill corrupt formula constants.** `rewriteFormulas` (insert or delete rows/columns, rename or
  delete a sheet: every formula whose references move, in the whole workbook) and `translatedFormula` (fill, copy/paste,
  sort) print constants with this function.
  - `=A1*1.23456789012` becomes `=A2*1.23456789`.
  - `=A1+123456789012.5` becomes `=A2+1.23457E+11`, off by 543,987.5.
  - These changes are saved to the file.
- **Text coercion differs from Excel's 15 digits.**
  - `"x"&1234567.891234` gives `x1234567.891`.
  - Concatenated lookup keys (`A1&"-"&B1`) stop matching.
  - `COUNTIF(A:A,">="&B1)`, where B1 holds a timestamp, returns 0 instead of 2, because the bound is rounded up.

**Direction:** split the function into three, each with its own contract:

- `roundTripString`: shortest exact form, for formula text and the editor.
- `textCoercionString`: Excel's 15 significant digits.
- `generalString`: grid display only.

Better still for formulas: keep the original lexeme in the `.number` node and print that. Also, do not commit an editor
whose text did not change. Add a property test that `commitInput(editString(x)) == x`.

### 3.3 Formula text is the source of truth, and the AST is rebuilt by re-parsing

**Where:**

- `WorkbookOperations.swift:316` and `:327-330` (`try? FormulaParser.parse … else { continue }`)
- `SortRows.swift:97`
- `FormulaParser.swift:178-185`
- `CalculationEngine` `rebuildAll` on open and after every structural edit

**What happens:**

- **Insert or delete row/column:**
  1. Every formula in the workbook is parsed.
  2. The changed ones are printed with the lossy printer (§3.2).
  3. `rebuildAll` parses them all again and **recalculates everything**.
- **A formula that does not parse is skipped.** Its cell moves with the rows, but its references keep the old addresses
  (confirmed: after inserting a row above, `=IF(A2,,1)` and `=SUM(A2,{1,2})` still point at A2). The cell shows
  `#ERROR!`, but the original text is saved, so the file opens in Excel with references one row off and nothing warns
  anyone. The parser rejects forms that are routine in Excel files:
  - empty arguments (#10)
  - array constants `{1,2}`
  - structured references `Table1[Col]`
  - 3-D references `Sheet1:Sheet3!A1`
  - the space intersection operator
- **Open recalculates every formula,** so every formula the engine cannot evaluate replaces Excel's correct cached
  value with an error: `_xlfn.` functions (#9), defined names (#8) and empty arguments (#10).

**Direction:**

- Short term, do the reference rewrite at **token level**, which needs only the lexer: rewrite A1-reference tokens and
  copy every other token's original text through. This removes both the "unparseable is skipped" bug and the "printer
  is lossy" bug.
- Teach the parser the missing forms. Evaluating them can return `#VALUE!` for now; parsing them is what matters for
  adjustment.
- On open, keep the cached value for any formula whose AST has an unresolved name or function, instead of
  recalculating it into an error.
- Longer term, store the AST (or tokens with their original lexemes) per cell. Shift graph keys in place on structural
  edits and recalculate only the cells that moved and their dependents.

### 3.4 No validation layer: untrusted input reaches traps

Swift traps; it does not throw. These are each confirmed **process crashes**, and they lose unsaved work in every open
window:

| Input | Site | Origin |
|---|---|---|
| Typed, pasted or CSV text with a run of 19+ digits in a date-like shape (`2024-01-12345678901234567890`) | `ValueParser.swift:234, 245, 262` (`Int(...)!`) | 1.4.1 |
| `ISEVEN/ISODD(1E20)`, `GCD(1E300)`, `LCM` overflow, `NETWORKDAYS(1,1E20)`, `YEAR(1E20)` | `FunctionsInfo.swift:54,58`, `FunctionsMath.swift:164,171,278`, `FunctionsDateTime.swift:112-123,249,252`, `ExcelDate.swift:100` | 1.4.1 |
| **A date-formatted cell holding 1E20: crashes while drawing**, so the saved file probably crashes on every open | `NumberFormat.swift:655` → `ExcelDate.components` | 1.4.1 |
| `TEXT(x,"0.00000000000000000000")` (≥19 decimals) | `NumberFormat.swift:448` (`Int64(scaled)`) | 1.4.1 |
| `<sheetData> </sheetData>` (one byte of content) | `XLSXSheetDataScanner.swift:47-55` (`0..<(sample-2)`) | **9a2cd34** |
| `<c t="d"/>` or `<v></v>` on a `t="d"` cell (written by SheetJS and others) | `XLSXReader.swift:910-912` (`parts[0]` of an empty split), reached from both readers | 1.4.1 |
| `<col min="5" max="3">` or a huge `min` | `XLSXReader.swift:757` | 1.4.1 |
| Pivot `<field x="5"/>` with 2 fields, `groupInterval="0"`, negative top-10, a calculated field that refers to itself | `PivotEngine.swift:179, 222, 312, 330, 371, 444`; reached from **drawing** via `pivotRole` | 1.4.1 |

The root cause is structural. `Coerce.int` is safe (`abs(n) < 9e15`), but about 15 sites call `Int(...)`/`Int64(...)` on
a `Double` directly. There is no central valid-date-serial check (0…2958465). The pivot parser hands indices to the
engine without checking them.

**Direction:**

- One checked conversion helper, plus a CI grep that bans bare `Int(`/`Int64(` on a `Double` outside it.
- `ExcelDate.components` returns nil outside 0…2958465. Date functions then return `#NUM!`, and the renderer shows `#####`.
- `PivotDefinition.validate(against:)`, called from `unsupportedReason`, so a malformed pivot becomes preserve-only.
- A small fuzz test over `ValueParser.parse` and over worksheet/pivot XML (truncations, attribute swaps) through both
  reader paths. It would have found every row of this table.

### 3.5 Everything runs on the main thread, and several core structures are O(n²) or O(sheet)

The README now advertises 1,048,576-row sheets and 1 million formulas. Open is fast and off the main thread. **Every
interaction after open** still runs on the main thread, and these paths grow badly:

- **Range dependencies** (`CalculationEngine.swift:181, 188-196, 246-248, 269, 293`). A range larger than 256 cells
  goes into a flat per-sheet list that is scanned for every node, and `dirtyPrecedents` rescans the dirty set twice per
  cell.
  - With n formulas like `SUMIF($A$2:$A$50000,…)` filled down, **one keystroke** costs about n².
  - Measured: 2k formulas → 0.43 s per edit, 4k → 1.74 s, 8k → 6.7 s.
- **`Sheet.usedRange`** (`Workbook.swift:72-81`) iterates every key on every call. It is called:
  - per evaluation of every whole-column reference (`FormulaEvaluator.swift:270`), so N formulas over M cells cost N·M
    per recalculation
  - per revision by the new layout cache (`SpreadsheetGridView.swift:46-56`, added in 9a2cd34)
  - by Select All
- **Pivot compute** (`PivotEngine.swift:701, 708-713, 753-764`) filters all records for every output cell. Measured:
  100k records, 500 × 6 layout, **121 s** in debug (188 s with % of row). It reruns on **every** revision, because
  `pivotRole` recomputes during drawing (`SpreadsheetDocument+Pivots.swift:249-262`). Typing next to a modest pivot
  freezes the app.
- **Paste** (`SpreadsheetDocument.swift:779`): `writes.firstIndex(where:)` inside the loop. 2k cells → 0.20 s,
  8k → 3.0 s; copying one value down a full column never finishes.
- **AutoFilter** (`AutoFilter.swift:58, 224`): a case-insensitive `contains(where:)` per row. 20k distinct values →
  11.9 s to open the value list.
- **`currentRegion`** (`SheetLayout.swift:68-96`): grows one row per pass and rescans. 20k rows → 34.7 s, before every
  single-cell Sort or Filter.
- **Find** (`SpreadsheetDocument.swift:982-1021`): formats every cell's display string per keystroke (0.27 s at 500k
  cells).
- **Range commands build every address in the rectangle** (`range.addresses` + `snapshot` in style, clear, fill,
  paste, sort and merge). ⌘A then Bold on 1M × 10 creates 10.5M addresses plus 10.5M snapshots. ⌘C builds a TSV string
  of more than 100 MB, plus JSON.
- **Approximate VLOOKUP/MATCH** scan linearly instead of using binary search (`FunctionsLookup.swift:184-191`).
- **Drawing on a filtered sheet** iterates every hidden row index between the first and last visible row.

**Direction:**

- **Keep sheet metadata up to date incrementally:** used bounds (grow in `setCell`; recompute lazily when a boundary
  cell is deleted) and a sorted list of hidden rows.
- **Index range dependencies** by column (a per-column interval index), and order the dirty set with a topological sort
  over the edges already found.
- **Write range commands over the stored cells** that fall inside the range (the store is sparse), and make
  whole-row/whole-column formats first-class.
- **Give the pivot engine one pass:** each record → (row key, column key) → hash-map accumulators. Store cell roles when
  the layout is applied, not during drawing.
- **Debounce Find and run it off the main thread.**
- **Add a benchmark for editing, not only loading.** `spreadsheet-bench` measures load and save only. A timing guard on
  one edit, one structural edit, a paste of 10k cells and an AutoFilter list would catch every item in this list.

### 3.6 The pending edit lives only in the view, and the menu bypasses the responder chain

**Where:**

- `App.swift:492-541` (`CommandGroup(replacing: .undoRedo)` / `(replacing: .pasteboard)` call the document directly)
- `SpreadsheetGridView.swift:1538-1587` (the editor stores only `editingAddress`)
- `GridContainer.swift:98-115` (`GridActions.commitPendingEdit` is never called)

**What happens:**

- **The Edit menu.** Because it replaces the standard `cut:`/`copy:`/`paste:`/`selectAll:`/`undo:` actions, the menu
  key equivalent wins over any focused text field: the in-cell editor, the formula bar, Find, the name box, or sheet
  rename.
  - While editing B2, ⌘V pastes into the **grid** (multi-line text overwrites B2:B3), and then Return writes the
    editor's old text back.
  - ⌘X clears the selected cells, ⌘Z undoes a document step instead of the typing, and ⌘A selects all cells.
  - Users cannot paste text into a cell editor or the Find field at all.
- **The editor's target.** `commitInput` writes to whichever sheet is active **at commit time**.
  - Type in Sheet1!A1, click the Sheet2 tab, press Return: the text lands in Sheet2!A1 (confirmed). Excel users do
    exactly this when they type `=` and click another tab to build a cross-sheet reference.
  - Insert Row Above while editing A5: the edit lands in the new empty row.
  - ⌘S saves without the pending edit. ⌘W closes with no prompt, because `isModified` is false, and the typed text is lost.
  - Text in the formula bar is discarded when the user clicks the grid.

**Direction:**

- Restore the standard Edit items. Implement `copy(_:)`/`cut(_:)`/`paste(_:)`/`undo`/`redo` as responder actions on
  `SpreadsheetGridView`, or return the document's `undoManager` from the window, so that a focused text field handles
  them first.
- Store `(sheetID, address)` in the editor.
- Commit or cancel the pending edit from one document-level choke point before any command, sheet switch, save or close.
  The unused `GridActions.commitPendingEdit` was built for this.
- Count an open editor as modified for the close prompt.

### 3.7 Duplicated logic that has already drifted

Each item below has its own symptom in §4:

- **Two XLSX readers** (the `XMLParser` delegate and the new byte scanner). They copy the same per-cell rules by hand.
  The tests compare them only on UTF-8, LF-only, Excel-written fixtures, and they already differ on CRLF and on
  non-UTF-8 text (#27). Move the per-cell decisions (`commitCell`, shared formulas, row inference) into one type that
  both front ends feed.
- **Criteria matching is written four times:** the SUMIF loop, the AVERAGEIF loop, the COUNTIF loop and
  `matchingIndices`. Their error handling differs: COUNTIF skips error cells but COUNTIFS fails (#23).
- **Lookup equality is written three times** (`exactMatch`, `lookupEqual`, `sameTypeCompare`). Each copy treats a blank
  key as matching a blank cell (#25).
- **Pivot range grouping is written three times:** labels in `numberItems`, labels in `regroup`, and buckets in
  `bucket`. The edge value already lands in the wrong group (#40).
- **Pivot filters have two sources of truth:** the typed `PivotFilter` drives the engine, while the carried XML fragment
  drives the file (#26).
- **Positions are used as identities:** `baseItem`, `selectedItem`, hidden and collapsed state all point at positions
  in `fields[f].items`, which sort, refresh and group reorder (#26).
- **Undo has three overlapping mechanisms:** per-cell snapshots, whole-`SheetLayoutState` snapshots, and XLSX round-trips.
  Resize and freeze register no undo at all (#31).
- **Filter-hidden semantics are decided per command.** Delete and Copy skip filtered rows; Fill, Paste, Format, Sort
  and Find do not (#20, #34).
- **The Info.plist is built twice,** in `scripts/build-app.sh` and in `.github/workflows/build.yml`, by two copies of the
  same 20 PlistBuddy lines.
  - **Related:** local builds are ad-hoc signed **without** `entitlements.plist`, so the sandbox paths (security-scoped
    bookmarks for Open Recent, Sparkle's installer XPC) never run in development.

---

## 4. Findings in detail

Tags: **[1.4.1]** = already in v1.4.1 or earlier; **[9a2cd34]** = added by the large-files commit. Each finding gives the place,
the problem, a scenario and a fix.

### 4.1 Data loss and silent corruption

**#1 Critical — ⌘S writes over the original `.xlsx` with a lossy rewrite.** [1.4.1] See §3.1.

- **Fix now:** show the user what the file contains that will not be saved, and force Save As or ask for confirmation.
- **Fix later:** carry unknown parts through unchanged.

**#2 Critical — 10-digit number-to-text conversion used for round trips.** [1.4.1] See §3.2. Confirmed through the editor
(from reading), formula rewrite, fill, `&` and COUNTIF.

**#3 Critical — Formulas the parser rejects are not adjusted by structural edits, sort, copy or fill.** [1.4.1]
`WorkbookOperations.swift:316, 327-330`; `SortRows.swift:97`. See §3.3. Confirmed.

**#5 Critical — Insert PivotTable on "This sheet" erases cells.** [1.4.1]
`SpreadsheetDocument+Pivots.swift:69-79`, `PivotRendering.swift:33-47`, `PivotEditing.swift:284-289`.

- **Problem:** the new table is first given its 18 × 3 placeholder area. `pivotLayoutConflicts` then reports only cells
  in the new area that are *not in the current area*. For a new table both areas are the same, so it reports nothing,
  and `applyPivotLayout` clears every cell in the area.
- **Scenario:** data in A1:B4 and "keep" in D4; insert a pivot at D1. D4 is now empty, with no prompt (confirmed).
  - The dialog's default destination (2 columns right of the selection) makes this easy to hit.
  - A destination inside the source range wipes the source itself.
- **Fix:** for a new table, check the whole placeholder area, and show the same "Replace?" confirmation `transaction`
  uses.

**#8 High — Defined names.** [1.4.1]

- **Where:** `XLSXReader.swift:251-255, 279-282` (names are used only by pivots); `XLSXWriter.swift:116-126` (writes only
  `_xlnm._FilterDatabase`).
- **Problem and scenario:**
  - `=SUM(Sales)` becomes `#NAME?` as soon as the file opens, because open recalculates everything.
  - Save drops `<definedNames>`, so the file is now broken in Excel too.
  - Print areas and print titles are lost the same way.
  - Confirmed.
- **Fix:** carry `Workbook.definedNames` through the model and the writer, adjusting them like other references. Then
  resolve names in the evaluator. Until then, keep cached values for formulas that use unresolved names.

**#20 High — Fill Down/Right overwrite filter-hidden rows.** [1.4.1] `SpreadsheetDocument.swift:850-914`.

- **Problem:** Delete and Copy skip rows the filter hides; `fill` does not.
- **Scenario:** select a visible column in a filtered list and press ⌘D. Hidden rows are overwritten (confirmed:
  hidden B3 changed from 5 to 3).
- **Fix:** apply `filteredOutRows(in:)` in `fill`. Better, use one policy helper for all range commands (§3.7).

**#26 High — Pivots.** [1.4.1]

- **(a) "Show Values As" base item breaks after Sort or Refresh.**
  - **Where:** `PivotEngine.swift:766-771` treats `baseItem` as a position. `setSort` (`PivotEditing.swift:182-194`) and
    `remapItems` (`PivotRefresh.swift:247-292`) reorder the items without remapping it.
  - **Scenario:** "% Of East", then Sort ▸ Descending: every number becomes "% of West", while the UI and the file
    still say East. Confirmed.
- **(b) Grouped fields sort as text.**
  - **Where:** sorting grouped fields compares the labels as text.
  - **Scenario:** months come out Apr, Aug, Dec, Feb…; ranges come out "0-9", "10-19", "100-109". Refresh reapplies
    this order. Confirmed.
- **(c) Blank cells in a grouped field disappear from the rows but stay in the grand total.**
  - **Where:** `PivotGrouping.swift:95-97, 135-137`, `PivotEngine.swift:213-216, 444`.
  - **Scenario:** the rows show 10, 10 and 10, and the Grand Total shows 1030. Confirmed.
- **(d) Report filters are written from the carried XML with old field numbers.**
  - **Where:** `PivotXMLWriter.swift:398`. `removeFromAxes` never clears a field's filter, so a removed field's Top-10
    filter keeps cutting the totals with nothing on screen.
  - **Scenario:** after a source column is inserted and the pivot refreshed, Excel applies the filter to a different
    field. From reading.
- **Fix:**
  - One "reorder items" helper that returns an old → new position map, applied to every position reference.
  - Grouped fields sort by group index.
  - Refuse grouping when the field has blanks (as Excel does), or add a "(blank)" item.
  - Write `<filters>` from the model, and drop a field's filters when the field leaves every axis.

**#30 Medium — Mixed-encoding CSV.** [decode rule 1.4.1; restart 9a2cd34]

- **Where:** `CSV.swift:32-42` and `CSVFastImport.swift:36-46`.
- **Problem:** one stray CP1252 byte switches the whole file to CP1252, so every correct `é`/`€` becomes `Ã©`/`â‚¬`
  (confirmed). The fast importer then discards its work, transcodes the whole mapped file into a `String` and a second
  `Data`, and imports again.
  - Peak memory is about 3× the file.
  - The "stop at the row limit" property is lost.
- **Fix:** decode per record or per field, mapping only the invalid bytes through CP1252, and continue scanning in place.

**#31 Medium — Layout undo reverts unrelated later changes.** [1.4.1]

- **Where:** `SpreadsheetDocument+Layout.swift:11-41` restores the whole `SheetLayoutState`, but resize and freeze
  register no undo of their own.
- **Scenario:** hide a row, resize another row, freeze the top row, then ⌘Z. The resize and the freeze are undone too
  (confirmed).

**#32 Medium — TSV clipboard not quoted or unquoted.** [1.4.1] `SpreadsheetDocument.swift:695-707, 799-805`.

- **Problem:** Excel and Numbers put a multi-line cell on the clipboard as `"line1\nline2"`. Here it is split across
  rows, the quote characters are kept, and the neighbouring cells are overwritten (confirmed).
- **Fix:** parse pasted text with the existing CSV parser using a tab delimiter, and quote fields on copy.

**#34 Medium — Sort moves data into and out of rows hidden by hand.** [1.4.1] `SpreadsheetDocument+Layout.swift:243-264`.

- **Problem:** `hiddenRows` and `rowHeights` stay attached to row indices while the cell contents move.
- **Scenario:** hide a confidential row, then sort. A different record is hidden, and the hidden record shows.

### 4.2 Crashes and hangs

**#4 Critical — Crash class from unchecked conversions and indices.** [1.4.1 + 9a2cd34] See the table in §3.4. Every row is
confirmed by a test that died with a Swift runtime trap, except the >4 GiB save (#29), which follows from integer
conversion rules.

**#18 High — Unbounded loops freeze the app.** [1.4.1] From reading; not run, to avoid hanging the test runner.

- **Where:** `FunctionsDateTime.swift:117, 128-133` (NETWORKDAYS and WORKDAY step one day at a time),
  `FunctionsMath.swift:156` (COMBIN), `FunctionsFinancial.swift:178` (IPMT/PPMT loop `period` times).
- **Problem:** `intArg` allows values up to 9e15.
- **Scenario:** a mistyped `45000000000` in a NETWORKDAYS end date, or `=WORKDAY(TODAY(),1E12)`, freezes the window.
  The formula is saved in the file, so the next open freezes too.
- **Fix:** validate date serials, use closed-form week arithmetic, `lgamma` for COMBIN and the closed form for IPMT.

**#28 Medium — ZIP bomb.** [allocation 1.4.1; reservation 9a2cd34] From reading.

- **Where:** `ZipArchive.swift:113-130` allocates `Data(count: uncompressedSize)` from the central directory, up to
  4 GiB per entry, with no total cap. `XLSXSheetDataScanner.swift:47-55` then reserves dictionary capacity extrapolated
  from that size: about 250M slots, well over 10 GB, from a few-MB file.
- **Fix:** cap per-entry and total uncompressed size, reject absurd compression ratios, and cap the reservation.

**#29 Medium — A part or archive over 4 GiB traps on save.** [1.4.1; reachable since 9a2cd34]

- **Where:** `ZipArchive.swift:305-352` (`UInt32(...)`, and `pending.count` silently cut to 16 bits).
- **Scenario:** a 1M-row × ~150-column sheet crashes Save and every structural undo snapshot.
- **Fix:** throw a clear error, or write ZIP64 records (and read them).

### 4.3 Wrong results users will hit

**#9 High — `_xlfn.` / `_xlws.` prefixes.** [1.4.1]

- **Problem:** in files, Excel writes every function added after 2007 with a prefix: `_xlfn.IFNA`, `_xlfn.XLOOKUP`,
  `_xlfn.CONCAT`, `_xlfn.TEXTJOIN`, `_xlfn.IFS`, `_xlfn.MAXIFS`, `_xlfn.STDEV.S` and so on. Nothing in `Sources/`
  mentions `_xlfn`, so after open's recalculation all of these become `#NAME?` (confirmed in the evaluator), and then
  they fall into #3.
- **Fix:** strip the prefixes on parse, and add them back in the writer.

**#10 High — Empty arguments.** [1.4.1] `FormulaParser.swift:178-182`.

- **Problem:** `VLOOKUP(a,b,2,)` (meaning FALSE), `IF(c,,x)` and `SUBSTITUTE(a,"x",)` are common in Excel files and are
  parse errors here (confirmed).
- **Fix:** add a `.missing` argument node, and let each function decide its default.

**#21 High — A reference to a sheet added later stays stale.** [1.4.1] `CalculationEngine.swift:151-152`, and `addSheet`
does not rebuild.

- **Scenario:** write a summary sheet first, then add the data sheet: the summary stays `#REF!` (confirmed).
- **Fix:** keep a map from unresolved sheet name to the formula cells that use it, and re-install those cells on add or
  rename.

**#22 High — Number formats show wrong numbers.** [1.4.1] All confirmed.

- **`[h]:mm`:** it floors the raw float, so 7:12 − 0:12 shows **6:00**. Seconds are rounded after splitting, so
  12:00:59.6 shows `12:00:60`, and `SECOND(NOW())` returns 60 about 0.8% of the time.
  - Where: `NumberFormat.swift:716-723, 770`; `FunctionsDateTime.swift:62`.
- **Scaling commas:** `#,##0,"K"` shows 12345 as `12,345K`, and `0.0,,"M"` shows 2.5M as `2500000.0M`.
  - Where: `NumberFormat.swift:318-394`.
- **Conditional sections:** `[>=1000000]0.0,,"M";[>=1000]0.0,"K";0` renders 500 as `500.0M`. The doc comment says
  conditional sections fall back to General; they do not.
  - Where: `NumberFormat.swift:161-176, 215-252`.
- **Scientific carry:** 9.999 in `0.00E+00` shows `10.00E+00`. 1e20 in `#,##0` shows `9,200,000,000,000,000,000`.
  - Where: `NumberFormat.swift:425-443`.

**#23 High — Criteria functions.** [1.4.1] Confirmed.

- **Error cells:** `matchingIndices` throws on any error cell in a criteria range (`FunctionRegistry.swift:175`), so one
  `#N/A` in a column of VLOOKUP results makes SUMIFS/COUNTIFS/AVERAGEIFS/MAXIFS return `#N/A`, while COUNTIF on the same
  data returns 2.
- **Error and date criteria:** `"#N/A"` is never parsed as an error criterion, and `COUNTIF(dates,">=1/1/2024")`
  returns 0, because `Criterion.parse` tries only numeric text (`Coercion.swift:259-271`).
- **Fix:** one criteria engine; test error cells against the criterion instead of throwing; parse operands with the
  shared `ValueParser`.

**#24 High — Rounding.** [1.4.1] `FunctionsMath.swift:59-108`, `NumberFormat.swift:440-448`.

- **Problem:** `ROUND(1.005,2)` returns 1, because 1.005 × 100 = 100.4999…. Excel rounds to 15 significant digits
  first and gets 1.01.
- **Scenario:** currency amounts ending in 5 in the third decimal show one cent low, and 0.145 in `0%` shows 14%.
  `fuzzyCeil`/`fuzzyFloor` use an absolute 1e-9 tolerance, so `ROUNDUP(1.0000000001,0)` = 1.
- **Fix:** round on the 15-significant-digit decimal form, and use a relative tolerance.

**#25 High — Blank lookup key.** [1.4.1] `FunctionsLookup.swift:210-211, 291-292`.

- **Problem:** `(.empty, .empty)` counts as equal.
- **Scenario:** a VLOOKUP filled down past the end of its input column returns real data from whichever table row has
  a blank key, often hidden inside IFERROR (confirmed). Excel and Sheets return `#N/A`.

**#19 High — Copy origin in a static map.** [1.4.1] From reading.

- **Where:** `Clipboard.swift:9, 22, 33` (`static var copyOrigins: [ObjectIdentifier: CellAddress]`).
- **Problem:** the paste takes the origin from the *destination* document's last copy, not from the payload.
- **Scenario:** cross-window pastes shift relative references by the wrong offset. After a relaunch the offset is 0, so
  `=A1` copied from B2 and pasted at D5 stays `=A1`; Excel gives `=C4`. The keys are never removed.
- **Fix:** put `sourceOrigin` in the `Codable` `ClipboardPayload` and delete the map.

**#35 Medium — No array evaluation.** [1.4.1] `FormulaEvaluator.swift:114-130, 186-229`.

- **Problem:** `SUMPRODUCT((A1:A3>1)*B1:B3)`, the pre-365 way to write a conditional sum, returns `#VALUE!`.
  `FUNCTIONS.md` lists only spilling as a deviation.
- **Related:** `XLOOKUP` with a 2-D return range returns the wrong cell (`FunctionsLookup.swift:42-59`).

**#37 Medium — Results that change between launches.** [1.4.1]

- **Cycles:** which cell in a cycle gets `#CYCLE!` depends on `Set` order (`CalculationEngine.swift:285-305`), which
  Swift randomises per process.
  - Fix: Tarjan SCC (find strongly connected components) and mark every cell in a cycle.
- **Sparse sums:** sparse whole-column sums add in `Dictionary` order (`FormulaEvaluator.swift:86-90`), so their
  floating-point result can differ from run to run.
  - Fix: iterate in sorted address order.

### 4.4 Performance

#11–#17 are described together in §3.1 and §3.5, with locations and measurements. #33 and #36 are in §3.5.

### 4.5 UI correctness and platform

**#6 High — Edit menu.** [1.4.1] See §3.6.

**#7 High — The editor's target and the pending edit.** [1.4.1] See §3.6.

**#38 Medium — No accessibility.** [1.4.1]

- **Problem:** the grid is one custom-drawn `NSView`, with no accessibility role, no cell elements and no focus
  notifications. The main surface of the app is invisible to VoiceOver.
- **Fix:** give the grid a table role, expose the visible cells and the active cell, and post selection-change
  notifications.

**#39 Medium — Keyboard input.** [1.4.1] `SpreadsheetGridView.swift:1436-1449`.

- **Problem:**
  - Type-to-edit seeds the editor with `event.characters` and skips the input method, so with a Japanese or Chinese IME
    the first letter of every cell arrives raw.
  - End, Help and F-keys (U+F700–F8FF, which are not control characters) start an edit with a private-use character.
    The next arrow key writes U+F72B into the cell (confirmed).
- **Fix:** on the first printable key, open an empty editor and re-send the event to it, and ignore `event.specialKey`.

### 4.6 The large-files commit (9a2cd34): issues specific to it

The direction is good. Mapped input, the byte scanner, the parallel deflate, the progress panel with cancel, and the
O(log k) `AxisSizes` layout are all sound designs, and the equivalence tests are the right idea. It is now on `main`
but not yet in a release. Before the next release:

- **Fix the crash at `XLSXSheetDataScanner.swift:47-55`** (#4) and cap the capacity reservation there (#28).
- **Make the scanner follow XML decoding rules** (#27).
  - Normalise CR and CRLF to LF in text.
  - Use the fast path only for UTF-8 parts (an `encoding="ISO-8859-1"` part currently gives `caf\u{FFFD}`).
  - Give the XMLParser fallback progress reporting and cancellation. Today a fallback on a big sheet freezes the bar,
    and Cancel only hides the panel.
- **Resolve the two Sendable warnings** instead of living with them. The code works today, but these are the warnings
  Swift 6 mode exists to make into errors:
  - `DispatchQueue.concurrentPerform` with a closure that writes into an `UnsafeMutableBufferPointer`
    (`ZipArchive.swift:74`)
  - the `report` closure captured in a `@Sendable` closure (`FileLoading.swift:105`)
- **Recheck the README performance table against the rest of the lifecycle.** It promises 1,048,576-row sheets. After
  opening one, the following are the measured or extrapolated costs:

  | Action | Cost on a 1,048,576-row sheet |
  |---|---|
  | Structural edit | about 4.5 s on the main thread |
  | Undo of that edit | about 11 s |
  | Each Find keystroke | well over 1 s |
  | Copying one value down a column | never finishes |
  | Status bar sum of a whole column | not shown: the selection is over the 1,000,000-cell cap |
  | A 4 GiB part | crashes Save |

  Either fix §3.1 and §3.5 first, or scope the README claim to opening.

---

## 5. CI, release and repository

The release pipeline was checked against the live v1.4.1 artifact, and it is in good shape. Structural notes only:

- **`build.yml` pushes the appcast with `git push origin HEAD:main` from whichever ref the workflow was dispatched on.**
  - If it is dispatched from a branch, that branch's commits are pushed to `main` (or the push fails).
  - If `main` moves while the build runs, the push fails *after* the GitHub Release already exists. The
    result is a published DMG that no installed copy will ever be offered.
  - Fix: guard on `github.ref == 'refs/heads/main'`, and fetch and rebase (or retry) before pushing.
- **The release silently falls back to ad-hoc signing** when `APPLE_CERTIFICATE` is missing, and to no appcast when
  `SPARKLE_PRIVATE_KEY` is missing. That fallback path also signs **without** `entitlements.plist`, so it would ship an
  unsandboxed build. For a release workflow, a missing secret should fail the job.
- **CI does not catch performance regressions or new compiler warnings.**
  - The only performance signal is a manual benchmark, and nothing times an edit.
  - Neither workflow builds the release configuration with `-warnings-as-errors`, so new warnings (like the two
    Sendable warnings added in 9a2cd34) go unnoticed.
- **The Info.plist is assembled in two places** (`build-app.sh` and `build.yml`), and local builds skip the
  entitlements (§3.7).
- **Repository hygiene:** `.playwright-mcp/` (about 200 files) and `.claude/` are untracked but not in `.gitignore`.

---

## 6. Test gaps that matter

The test suite is strong where it was aimed: pivot oracles, XLSX fixtures and formula semantics. It has almost nothing
for these four failure kinds:

1. **Extreme and malformed inputs.** No test uses magnitudes ≥1e15, 19-digit numeric strings, empty or odd XML shapes,
   or malformed pivot indices. A small fuzz pass over `ValueParser.parse`, worksheet XML through both readers, and
   pivot XML would have found every crash in §3.4.
2. **Round-trip properties.**
   - `commitInput(editString(v)) == v`
   - `parse(print(ast)) == ast` with exact constants
   - "open → save → open" keeps names, hidden sheets, comments and charts, or at least reports their loss
3. **Scale.** No timing guard exists for any interaction: one edit under 10k range formulas, a 10k-cell paste, an
   AutoFilter list of 20k values, a pivot over 100k records, a structural edit on a 1M-row sheet.
   `spreadsheet-bench` covers load and save only.
4. **Interaction state.**
   - No test drives the grid's key, editor or menu state machine. These tests are cheap to add: the confirmed sheet-switch
     bug (#7) and the End-key bug (#39) were both reproduced by creating `SpreadsheetGridView()` without a window.
   - No test covers fill, paste, format or sort inside an active filter, or the clipboard across two documents.

---

## 7. Notable strengths (keep these)

- A clean module split (Core / Files / UI / a thin app), Swift 6 language mode, and almost everything testable.
- A dependency walk without recursion. Deep formula chains cannot overflow the stack.
- Structural reference adjustment that follows Excel's rules (range growth, endpoint pull-in, `#REF!` only on full
  deletion), at least for formulas that parse.
- CSV import is safe by default (`allowFormulas: false`). Leading zeros and numbers longer than 15 digits are kept as
  text.
- The ZIP reader bounds-checks every header and always verifies CRCs. Part names never touch the file system.
- Pivot preservation is conservative: an unchanged pivot is written back byte for byte, and any unsupported feature
  makes the pivot preserve-only, with a reason, instead of recomputing it badly.
- Pivot behaviour is pinned against oracle files that Excel itself refreshed.
- An injectable clock makes the tests of volatile functions deterministic.
- The wildcard matcher has no exponential backtracking, and the solvers fall back from Newton's method to bisection.
- The release DMG is signed, notarized and sandboxed, and its updates are EdDSA-verified.

---

## Appendix: re-check against `47362b3`

Each repro test below was re-run against a clean export of `47362b3`. "Still reproduces" means the output matched the
first run.

| Finding | Test result on `47362b3` |
|---|---|
| #2 number → text | `=A1*1.23456789012` → `A2*1.23456789` after a row insert (value 12.3456789012 → 12.3456789); `A1&""` → `1234567.891`; a filled-down constant → `1.23457E+12` |
| #3 unparsed formulas | `IF(A2,,1)` and `SUM(A2,{1,2})` still point at A2 after a row insert |
| #4 crashes | All of these still crash: `ValueParser.swift:234/262` force unwrap; `ISEVEN`/`GCD`/`YEAR`/`NETWORKDAYS`/date format with 1E20 (Double → Int); `TEXT` with 20 decimals (Double → Int64); `LCM` overflow; a 1-byte `<sheetData>` and a reversed `<col>` (range bounds); an empty `t="d"` cell on both readers (index out of range); a pivot row field out of range on draw; `groupInterval=0` |
| #5 pivot insert | D4 is empty after inserting at D1 |
| #7 editor target | Sheet1!A1 is empty; Sheet2!A1 = "typed on sheet1" |
| #8 defined names | 5 → `#NAME?` after the engine runs; the re-saved file has no `MyName` |
| #9, #10 | `_xlfn.IFNA(1,2)` → `#NAME?`; `IF(1,,1)` → parse error |
| #11 XLSX undo | 500k cells: rename 1.27 s, undo 2.22 s, `commitInput` 0.0003 s |
| #12 range dependencies | 2k/4k/8k formulas: one edit takes 0.43/1.66/6.57 s |
| #14 pivot compute | 100k records, 500 × 6: 119.7 s; with % of row: 187.2 s (debug) |
| #15 paste | 2,000 cells 0.20 s; 8,000 cells 2.99 s |
| #16 filter list / region | 20k values 11.7 s; `currentRegion` on 20k rows 34.3 s |
| #17 Find | one keystroke on 500k cells 0.27 s |
| #20 fill over filter | hidden B3 overwritten (5 → 3) |
| #21 sheet added later | stays `#REF!` (6 expected) |
| #22 number formats | `[h]:mm` → `6:00`; `12:00:60`; `#,##0,"K"` → `12,345K`; conditional sections → `500.0M`; `10.00E+00`; `9,200,000,000,000,000,000` |
| #23 criteria | COUNTIF 2 vs COUNTIFS `#N/A`; SUMIF `#DIV/0!`; `">=1/1/2024"` → 0; `"#N/A"` → 0 |
| #24 rounding | `ROUND(1.005,2)` = 1; 0.145 in `0%` → `14%` |
| #25 blank key | `VLOOKUP` returns "secret" |
| #26 pivots | "% Of East" becomes "% of West" after Sort; months sort Apr, Aug, Dec…; rows sum to 30 under a grand total of 1030 |
| #27 scanner | CRLF kept (`a\r\nb\rc` vs `a\nb\nc`); Latin-1 → `caf\u{FFFD}` |
| #30 CSV encoding | `cafÃ©`, `ZÃ¼rich` |
| #31 layout undo | row height 60 → 22 and the freeze is removed by one unrelated undo |
| #32 TSV | `"line1` / `line2"` split across rows |
| #35 | `SUMPRODUCT((A1:A3>1)*B1:B3)` → `#VALUE!`; `XLOOKUP` with a 2-D return range → the wrong cell (2) |
| #39 End key | the cell contains U+F72B |
| YEARFRAC (minor; not in §2) | basis 0 → 0.091667 (Excel 0.083333) |

The findings checked by reading (#1, #6, #18, #19, #28, #29, #33, #34, #36, #38 and part of #26 and #40) are in code
that is byte-for-byte the same as what was reviewed.
