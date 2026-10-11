# SimpleSpread

A native macOS spreadsheet app written entirely in Swift. Native file format
is XLSX; CSV imports and exports. The formula engine covers Google Sheets'
core feature set — 157 functions, real coercion semantics, incremental
recalculation. The spreadsheet stack (model, formula engine, XLSX/ZIP/CSV I/O,
grid) is built from scratch with no third-party libraries; the sole external
dependency is [Sparkle](https://sparkle-project.org) for software updates.

![CI](https://github.com/baudehlo/SimpleSpread/actions/workflows/ci.yml/badge.svg)

![SimpleSpread](docs/screenshot.png)

## Features

- **XLSX native**: reads and writes OOXML SpreadsheetML interoperable with
  Excel, Numbers, and Google Sheets — including a from-scratch ZIP layer,
  shared strings, styles, number formats, formulas with cached values,
  merged ranges, frozen panes, and 1904-date-system normalization on read.
- **Pivot tables**: Insert ▸ PivotTable… and a PivotTable Fields panel
  like Excel's: drag fields into rows, columns, values and filters;
  summarize by sum/count/average/…; show values as % of total/row/column,
  difference, % of, running total; filter, sort, subtotals, blank lines,
  compact/outline/tabular layouts; group dates by years/quarters/months/days
  and numbers into ranges; Data ▸ Refresh (⌥F5). Pivots in files from Excel
  open, recompute, refresh and save intact, and GETPIVOTDATA reads them.
  Layouts are checked cell by cell against real Excel. See
  [docs/PIVOTS.md](docs/PIVOTS.md).
- **CSV done right**: delimiter sniffing, BOM/CP1252 encoding detection,
  quote-aware parsing, injection-safe import (a `=cmd` field is data, not a
  formula), leading-zero preservation, and RFC 4180 export with UTF-8 BOM,
  CRLF, full-precision numbers, and ISO dates.
- **Formula engine**: full operator set with Excel precedence (`-2^2 = 4`,
  `2^3^2 = 64`), Sheets-compatible type coercion and comparison ranking,
  SUMIF/COUNTIF criteria with wildcards, lazy IF, cross-sheet references,
  whole-row/column ranges, volatile functions, cycle detection, and
  iterative solvers for IRR/RATE/XIRR. See [docs/FUNCTIONS.md](docs/FUNCTIONS.md).
- **Spreadsheet-grade editing**: Excel's Ready/Enter/Edit state machine,
  type-to-replace, F2/double-click in-place editing, Cmd+arrow data-edge
  jumps, header selection and resizing with autofit, fill handle with
  formula translation, Fill Down / Fill Right (⌘D / ⌘R), Clear Formatting
  (⌘\), lossless internal clipboard plus TSV interop, and per-gesture undo —
  including undo of row/column/sheet operations.
- **Navigation**: Find (⌘F) with match navigation (⌘G / ⇧⌘G), a name box for
  jump-to-cell, and view zoom from 25%–400% (⌘+/⌘−/⌘0, status-bar control,
  and trackpad pinch).
- **File handling**: Open Recent (File menu) that actually reopens files under
  the sandbox via security-scoped bookmarks, Finder/`open` file association,
  and CSV/TSV/TXT import that forces Save-As to XLSX.
- **Software updates**: in-place auto-update via [Sparkle](https://sparkle-project.org),
  driven by GitHub Releases — a "Check for Updates…" menu item, automatic
  background checks, and one-click download-verify-replace-relaunch. See
  [docs/UPDATES.md](docs/UPDATES.md) for the signing-key and release setup.
- **Formatting**: bold/italic/underline/strikethrough, colors, alignment,
  and the number-format menu (automatic, number, percent, currency, date,
  time, scientific, plain text) backed by a full Excel format-code renderer.

## Performance

Time from launch until the window shows the spreadsheet (median of five
runs, on an M4 Pro Mac with 24 GB of memory and macOS 26.6), compared with
Apple Numbers 14.1 opening the same `.xlsx` files:

| Document | SimpleSpread | Numbers | |
|---|---:|---:|---|
| Empty workbook | 0.78 s | 2.12 s | 2.7× faster |
| Simple (a short invoice with formulas) | 0.79 s | 2.08 s | 2.6× faster |
| Complex (20,000 rows, 80,000 formulas, 7 sheets, 4 pivot tables) | 1.85 s | 5.43 s | 2.9× faster |

SimpleSpread starts with a new, empty document in 0.36 s. The app is 8.0 MB
(a 3.0 MB download); Numbers is 421 MB.

## Building

Requires Xcode 16+ on macOS 14+.

```bash
swift build            # debug build
swift test             # 549 tests
swift run SimpleSpread # run the app directly
./scripts/build-app.sh # assemble SimpleSpread.app + DMG (ad-hoc signed)
```

## Documentation

- [docs/PLAN.md](docs/PLAN.md) — architecture, module map, design decisions,
  testing strategy, roadmap.
- [docs/RESEARCH.md](docs/RESEARCH.md) — the feature-set research (formula
  semantics, XLSX internals, editing UX, CSV) the implementation follows.
- [docs/FUNCTIONS.md](docs/FUNCTIONS.md) — all 157 functions with semantics
  notes and known deviations.
- [docs/PIVOTS.md](docs/PIVOTS.md) — using pivot tables: creating, the
  Fields panel, grouping, refreshing, and Excel features not supported.

## CI & releases

- **CI** (`.github/workflows/ci.yml`): every push/PR builds and runs the
  test suite on macOS 15, then boots the real app headlessly and captures a
  window render as an artifact.
- **Release** (`.github/workflows/build.yml`): manual dispatch with a
  version number → tests → arm64 release build → .app assembly → signing →
  DMG → optional notarization → GitHub Release. Signing/notarization use
  the repository secrets `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, and
  `APPLE_TEAM_ID`; without them the DMG is ad-hoc signed.

## Debug hooks

```bash
SIMPLESPREAD_DEMO=1 swift run SimpleSpread            # seed demo content
SIMPLESPREAD_SCREENSHOT=/tmp/win.png swift run SimpleSpread  # render window to PNG and exit
SIMPLESPREAD_OPEN=/path/file.csv swift run SimpleSpread      # drive the real open→window flow
SIMPLESPREAD_ZOOM=1.5 SIMPLESPREAD_DEMO=1 swift run SimpleSpread  # launch at a zoom level
SIMPLESPREAD_FIND=term SIMPLESPREAD_DEMO=1 swift run SimpleSpread # open the find bar on a term
SIMPLESPREAD_SAMPLE_DIR=/tmp swift test --filter SampleFileGeneration  # emit sample .xlsx/.csv
```
