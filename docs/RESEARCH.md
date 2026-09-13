# SimpleSpread — Feature-Set Research

Consolidated findings from the three research tracks run before
implementation (September 2026). These findings drove the decisions recorded
in PLAN.md; anything cited in code comments traces back here.

---

## Track 1 — Formula semantics (Google Sheets baseline)

### What "core" means
Google Sheets documents ~500 functions. The Enron spreadsheet corpus study
(Hermans & Murphy-Hill, ICSE 2015) shows the overwhelming majority of
real-world formulas use only operators plus a small set — SUM, IF, NOW,
AVERAGE, VLOOKUP, ROUND, TODAY, MONTH/YEAR, ISERROR, INDEX/MATCH. ~25
functions cover >90% of usage; ~120 covers essentially everything a
non-specialist writes. **Conclusion: invest in operator/coercion correctness
and the high-traffic functions before breadth.** SimpleSpread ships 156.

### Coercion table (the part clones get wrong)
- Arithmetic operators and *direct literal* arguments coerce: TRUE→1,
  "3"→3, blank→0; unparseable text → #VALUE!.
- Range-consuming aggregates (SUM, AVERAGE, COUNT, MAX…) **skip**
  text/booleans/blanks in references without coercing. `SUM(A1:A2)` with
  A1="3" (text) ignores it; `SUM("3")` counts it.
- Comparisons never cross-coerce. Mixed types order by rank:
  **number < text < boolean** (so `99 < "1"` is TRUE, `TRUE > 10^9` is
  TRUE, `"3" = 3` is FALSE). Text compares case-insensitively (EXACT is the
  case-sensitive escape hatch). Blank coerces to the other operand's zero
  value (0 / "" / FALSE).
- Concatenation renders numbers in shortest-round-trip form and dates as
  their serial ("x"&DATE(2020,1,1) → "x43831") — users must TEXT().
- Boolean contexts: 0/nonzero; only "TRUE"/"FALSE" text coerces; other text
  → #VALUE!; AND/OR skip text/blanks inside ranges.

### Operators
Precedence (Excel-verified, Sheets matches minus reference union/intersection
which Sheets lacks): `:` › unary − (binds tighter than `^`: `-2^2 = 4`) ›
`%` postfix › `^` (LEFT-associative: `2^3^2 = 64`) › `* /` › `+ -` › `&` ›
comparisons. Sheets has no space-intersection or union operator → #NULL!
essentially never occurs natively (code reserved anyway).

### Criteria (SUMIF/COUNTIF/AVERAGEIF + *IFS family)
One shared evaluator: strip operator prefix (>=, <=, <>, =, >, <) longest
first; parse remainder as number/bool else text. Equality is whole-cell,
case-insensitive, wildcard-active (`?` one char, `*` any run, `~` escapes).
Inequalities compare within the criterion's type only (a numeric bound
silently excludes text cells). `""` matches blanks, `"<>"` matches
non-blanks, `"<>x"` matches blanks too. *IFS ranges must match dimensions →
#VALUE!. Empty results: SUMIF 0, COUNTIF 0, AVERAGEIF #DIV/0!,
MAXIFS/MINIFS 0.

### Error taxonomy
#DIV/0!, #VALUE!, #REF!, #NAME?, #N/A, #NUM!, #NULL! (reserved), plus
Sheets-specific #ERROR! (formula parse error — Sheets *commits* unparseable
formulas; Excel refuses; we follow Sheets). ERROR.TYPE codes 1–8. Circular
references: Sheets shows #REF! with a message on every cell in the cycle
(no distinct code); SimpleSpread shows #CYCLE! in-app and writes #REF! to
files. IFERROR with one argument returns *blank*, not "".

### Semantics worth their own tests
- VLOOKUP `is_sorted` DEFAULTS TO TRUE (largest ≤ key, silently wrong on
  unsorted data) — the #1 user footgun; exact match needs FALSE. Wildcards
  active in exact mode.
- MATCH types 1/0/−1; XLOOKUP match modes 0/1/−1/2 and search modes ±1/±2.
- IF evaluates only the taken branch (`IF(TRUE,1,1/0)` → 1).
- ROUND is half-away-from-zero (not banker's); INT floors (−1.5→−2), TRUNC
  truncates (−1.5→−1); MOD takes the divisor's sign; CEILING(−2.5,2)→−2 but
  FLOOR(−2.5,2)→−4; mixed-sign CEILING/MROUND → #NUM!.
- DATE normalizes overflow (DATE(2020,13,1)→Jan 2021; DATE(2020,2,30)→Mar 1)
  and adds 1900 to years < 1900. DATEDIF units Y/M/YM count whole months
  only when the day-of-month is reached. TRIM also collapses internal runs.
- FIND is case-sensitive/no wildcards; SEARCH is insensitive/wildcards.
- Financial sign convention: money out negative; IRR/RATE/XIRR need
  iterative solvers (Newton from guess + bracketing fallback, #NUM! on
  non-convergence); NPV discounts the first cashflow one full period.
- Volatile set: NOW, TODAY, RAND, RANDBETWEEN.

## Track 2 — XLSX (SpreadsheetML) internals

Target **Transitional** conformance (what Excel writes); Strict breaks real
consumers. Apple Numbers is the strictest reader — files that skip styles.xml
or sheetViews render blank there, hence the "write everything" profile.

### Package
Required: `[Content_Types].xml`, `_rels/.rels` (officeDocument rel),
workbook part + rels, ≥1 worksheet. Recommended always: styles,
sharedStrings, docProps. Readers must resolve parts via relationships (other
producers use arbitrary part names) and tolerate missing `r` attributes on
rows/cells (Google Sheets omits them) by inference: row = prev+1, cell =
next column. Element ORDER inside worksheet/workbook/styleSheet follows the
schema sequence or Excel shows the repair dialog; within `<c>`: `<f>` then
`<v>`. Never write empty container elements (`<cols/>`, `<mergeCells
count="0"/>` → repair).

### Cells
`t` attribute: `n` number (default), `s` shared-string index, `str` formula
string result, `b` 0/1, `e` error literal, `inlineStr` (`<is><t>`), `d`
ISO date (read-only support; never write). Styles: `s` = cellXfs index.

### Styles part hard rules
fills[0] MUST be `none`, fills[1] MUST be `gray125` (Excel hard-codes);
solid fill color goes in **fgColor**; cellXfs[0] must exist; write
cellStyleXfs + cellStyles(Normal) trio for Numbers; custom numFmtId ≥ 164;
builtin id table 0–49 must be baked into readers (files reference ids with
no numFmt element); date-detection heuristic: ids {14–22, 27–36, 45–47} or
y/m/d/h/s tokens outside literals in custom codes. Avoid theme color
references unless shipping theme1.xml.

### Dates & formulas
1900 system: serial 1 = Jan 1 1900 with the phantom Feb 29 1900 (serial 60).
Practical epoch shortcut (valid ≥ Mar 1 1900): days since 1899-12-30. We
adopt Google's interpretation (no phantom day) — divergence only for
Jan–Feb 1900 display. `date1904="1"` workbooks: serial1900 = serial1904 +
1462 (normalize on read). Formulas stored WITHOUT `=`, en-US canonical
(`,` separators, `.` decimal, A1 style, quoted sheet names with `''`
escaping). Shared formulas: master carries text+`ref`+`si`; followers are
empty `<f t="shared" si=…/>` and must be expanded by translating relative
references by the cell offset. Cached `<v>`: write accurate values with
matching `t` (Excel does NOT auto-recalc absent `fullCalcOnLoad`); delete
calcChain.xml when rewriting files.

### ZIP profile
PKZIP, deflate (raw, headerless — Compression framework's COMPRESSION_ZLIB)
or stored; correct CRC-32 both headers; no data descriptors (write real
sizes); `[Content_Types].xml` first entry by convention; readers must scan
EOCD backward and trust the central directory; ZIP64 unnecessary; encrypted
"xlsx" files are CFB containers (D0 CF 11 E0 magic) — detect and reject
clearly. Entry names: forward slashes, no leading slash. `_xHHHH_`
escape/unescape for control characters in strings; strip CR, keep LF.

## Track 3 — Editing UX & CSV

### The one architectural must
Implement Excel's **Ready / Enter / Edit** cell-state machine explicitly and
route all keys through it: typing replaces (Enter mode — arrows COMMIT and
move), double-click/F2 preserves (Edit mode — arrows move the caret). Every
spreadsheet UX bug class lives there. Second must: ONE shared value-parsing
pipeline for typed entry, paste, and CSV import with per-call flags.

### v1 MUST list (implemented)
Click/drag/shift selection with distinct active cell; header row/column
selection incl. drag and shift; select-all corner; arrows/Tab/Enter (+shift
reverse) navigation; Cmd+arrow data-edge jump (in-data → run end; at edge →
next block; none → boundary); type-to-replace; Esc cancel; commit-on-click;
Delete clears contents not formats; formula bar + name box; input parsing
(`=`, numbers, `5%`→percent format, `$`→currency, dates/times, TRUE/FALSE,
leading `'` forces text, unparseable→text, auto alignment by type, existing
format wins); TSV clipboard both directions with type inference; internal
rich clipboard with relative-reference adjustment on copy-paste (cut pastes
verbatim); single-cell→range replication; insert/delete rows/columns with
reference adjustment (absolute refs shift too; ranges expand/contract;
deleted refs → #REF!); drag resize + double-click autofit; per-gesture undo
incl. structural and sheet ops; B/I/U + alignment + colors + number-format
picker (Plain Text suppresses inference — the ZIP-code fix); fill handle
with copy semantics; sheet tabs add/rename/delete; standard Mac menu/keys.

Deferred (NICE): merge/freeze rendering, hide rows, Paste Special, series
autofill, find/replace, Cmd+click discontiguous selection, marching ants.

### CSV rules (implemented)
- Parse: quote-aware state machine; CRLF/LF/lone-CR; `""` escapes; embedded
  newlines; ragged rows padded; stray quotes literal; unterminated quote
  fail-soft; trailing newline ≠ empty record. (Swift gotcha discovered in
  testing: `"\r\n"` is ONE grapheme-cluster Character.)
- Sniff delimiter (, ; tab |) by column-count-consistency scoring on a
  parsed prefix — frequency counting fails on quoted commas. Semicolon
  dialect → decimal-comma numbers likely.
- Decode: UTF-8 BOM strip → UTF-16 BOMs → strict UTF-8 validation →
  CP1252 fallback (not ISO-8859-1: real files use 0x80–0x9F for €/quotes).
- Import inference: leading-zero strings ("00501") and >15-digit strings
  stay TEXT (data-destruction protection); conservative date matching; and
  `= + @`-prefixed fields import as literal text — CSV injection defense
  (OWASP). Import never creates live formulas.
- Export: computed values; minimal RFC-4180 quoting; CRLF; UTF-8 **with**
  BOM (Windows Excel double-click); numbers full-precision machine form;
  dates ISO 8601; formulas export results; display-mode as option.
