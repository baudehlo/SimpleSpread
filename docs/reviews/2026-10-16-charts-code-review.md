# SimpleSpread — `charts` branch code review, 16 October 2026

## Scope and method

- **What was reviewed:** the charts work for the `charts` branch.
  - **The branch has no commits yet.** `charts` points at the same commit as `main` (`20a8ccd`, v1.9.0). The work is
    uncommitted in a separate worktree
    (`/private/tmp/claude-501/…/scratchpad/charts`), last edited at 09:51.
  - I froze a copy of that worktree at 10:03 and reviewed the copy, so the live worktree was never touched. Any edit
    made there after 10:03 is not covered.
  - The change has 25 files and about 3,900 added lines:
    - **New files (about 2,750 lines of source):** `ChartSettings.swift`, `ChartXML.swift`, `XLSXChartEditor.swift`,
      `XLSXCharts.swift`, `ChartPanel.swift`, `SheetCharts.swift`, `SpreadsheetDocument+Charts.swift`.
    - **Edited files:** `GridController`, `GridRenderer`, `App`, `Clipboard`, `ContentView`, `SpreadsheetDocument`, and
      the Mac and iPad grid views.
    - **Tests and docs:** about 800 lines of tests, an Excel-made fixture, and notes in `docs/PLAN.md`.
- **Focus (owner's instruction):** fundamental flaws, clear performance mistakes, and structural or architecture
  problems. Nit-picks, style and minor issues are left out.
- **How the review was done:**
  - Two reviewers worked in parallel. One covered chart XML: reading, writing, editing, and how charts fit into the
    carried parts. The other covered drawing, interaction, undo, the Chart panel and the Mac/iPad layering. I checked the
    build, the tests and how the pieces fit together.
  - Findings marked **confirmed** were reproduced with throwaway tests in separate copies. **From reading** means the
    finding comes from reading the code.
  - Timings come from debug builds unless stated. Swift Charts is a system framework, so the render timings in #1 are
    mostly release-speed code already.
- **Baseline:**
  - The branch builds cleanly with `-warnings-as-errors` in both debug and release, which is what CI requires.
  - All **948 tests pass**, including the new chart tests.
  - iPad UI tests (`iOS/SimpleSpreadUITests/ChartTests.swift`) were not run: the simulator was out of scope.

---

## 1. Summary

**The core design is right.** A chart exists only as its OOXML parts inside `workbook.carriedContent`. `SheetChart`
(what is drawn) and `ChartSettings` (what the panel edits) are always derived from those parts and never stored beside
them. Because of that:

- Save writes the parts byte for byte.
- Undo is a value swap.
- Background-save snapshots copy charts for free.
- Row and column inserts, deletes and sheet renames reuse the existing anchor and formula rewrite.

A reviewer checked this. A chart was inserted, 2 rows were inserted above it, its title was changed, and then
undo/undo/redo/redo ran. The anchor moved row 0 → 2 → 0 → 2, the reference `A1:B4` → `A3:B6` and back, and the title
followed every step. Renaming a sheet whose name needs quotes (`'It''s Q1'`) was also correct. Part paths, rIds and
`cNvPr` ids do not collide. The charts of a deleted sheet drop out at save. Edits made in place keep Excel's
`c14`/`c16` data and the part's own namespace prefixes. Edits are checked against Excel for the web through an oracle
fixture.

**The problems fall into four groups:**

1. **Nothing bounds chart data.** It is copied out four times, into arrays, into `SheetChart`, into `PlottedSeries`
   and into one Swift Charts mark per point, and nothing limits it at any stage.
   - Swift Charts renders synchronously inside the main-thread draw. A 5,000-point line chart takes 0.6–5.3 s and a
     20,000-point one takes **32.6 s** (#1).
   - Repeated category labels are made unique by appending zero-width spaces, which is quadratic. A series over an
     explicit full-height range (`$B$1:$B$1048576`) never finishes (#2).
   - Odd counts in chart XML crash the app as soon as the sheet is shown (#3).

   This is the same missing validation layer that the 13 October review found for cells and pivots (§3.4 there).
2. **Changing a chart's type or data range rebuilds the plot** from the panel's model. That silently drops everything
   the model doesn't hold: trendlines, per-point colours, series data labels, markers, the `c15`/`c16` extensions and
   secondary axes. This contradicts the README's "Excel opens them as Excel would have made them" (#4).
3. **Every edit re-reads every chart on the active sheet, on the main thread,** whether or not the edit touches chart
   data. Each draw also hashes every point of every chart to find its cached image (#5). Typing, row-resize drags,
   nudges and colour drags all pay this cost.
4. **There are three reference resolvers, and they disagree.** One reads cells, one writes caches and one serves the
   panel. As a result:
   - series over defined names go blank after a type change (#6);
   - written caches include hidden rows that the display leaves out;
   - the caches are never refreshed at save, so Quick Look and other cache-only readers show stale charts (#11).

**Ship blockers:** #1–#3. Bound the data at one place, render off the draw pass, and clamp XML integers.

**Fix next:** #4. Patch series in place instead of rebuilding them, or warn before a rebuild loses something.

---

## 2. Findings at a glance

Severity scale:

- **Critical:** a crash, a hang or silent data loss that users will plausibly hit.
- **High:** wrong output users will hit, or a major performance cliff.
- **Medium:** real, but narrower.

| # | Severity | Finding | Area | Checked |
|---|---|---|---|---|
| 1 | Critical | Charts render one Swift Charts mark per point, synchronously, in the main-thread draw; 20k points = 32.6 s, repeated on each data edit, resize, zoom and appearance change | UI | confirmed |
| 2 | High | Repeated or blank category labels padded with zero-width spaces (quadratic); series ranges are never clipped to the data, so a full-height range never finishes | UI + Files | confirmed |
| 3 | High | Odd chart XML crashes the app when the sheet is drawn (`ptCount="-1"`, `ser idx="-1"`); a huge `pt idx` stalls 5 s per revision or runs out of memory | Files | confirmed |
| 4 | High | A type change or new data range rebuilds the plot and silently drops trendlines, `dPt`, series labels, markers, `c15`/`c16` ext and secondary axes | Files | confirmed |
| 5 | High (perf) | Every revision re-reads and re-formats every series of every chart; every draw hashes every point; nudges, resize drags and colour drags pay it per tick | UI + Files | confirmed (timed) |
| 6 | Medium | After a type change, a series over a defined name or external link becomes blank (empty cache written) | Files | confirmed |
| 7 | Medium | Insert ▸ Chart from column headers charts ~200 rows, mostly blank, and saves those references | Files + UI | confirmed (Files half) |
| 8 | Medium | Deleting, moving or resizing a chart that is in a group acts on the whole group; only the first chart in a group is shown | Files | confirmed |
| 9 | Medium | Combo charts with a secondary axis draw every series on one scale (the % line lies flat at zero) | Files + UI | from reading + fixture |
| 10 | Medium | Data labels set on a series read as "off"; turning the toggle on rewrites every series | Files | confirmed |
| 11 | Medium | Number caches are written once and never refreshed, so the saved file's cached values go stale after edits | Files | confirmed |
| 12 | Medium | The image cache has no pixel or byte budget: one chart at zoom × Retina can be 35–530 MB | UI | from reading (arithmetic) |
| 13 | Medium | A chart dragged across a frozen-pane line jumps by the scroll offset and is dropped far away | UI | from reading |
| 14 | Medium | Charts cannot be reached by keyboard or VoiceOver | UI | from reading |

Totals: **1 Critical, 4 High, 9 Medium.**

---

## 3. Architecture

### 3.1 Keeping the parts as the model: keep it

This is the best decision in the branch, and it is why undo, snapshots, background save and structural edits needed no
chart-specific code. Do not add a parallel chart model to fix the performance findings. Add caching **per part**,
keyed by the part's bytes (see §3.3).

### 3.2 No layer bounds the data

Points are copied with no limit through four stages:

1. `SeriesReader` arrays
2. `SheetChart.Series`
3. `PlottedSeries`, with the string growth from #2
4. one Swift Charts mark per point

None of these has a cap, and nothing clips a reference to the sheet's used range. One reduction step, sized by the
plot's pixel width (min/max per pixel column for line and area, stride sampling for scatter, a cap for bars), placed
where the series are read, would fix #1, #2, #5 and #12 together. Clamping XML integers in one helper fixes #3.

### 3.3 Two caches with the wrong keys

- `ChartState.cache` (`SpreadsheetDocument+Charts.swift:21-33`) is keyed by the global `revision`. That is too coarse:
  every edit anywhere misses it.
- The image cache's `ImageKey` (`SheetCharts.swift:25-49`) holds the whole `SheetChart`. That is too fine and too
  costly: each lookup hashes and compares every value, category and colour. That is 0.55 ms per chart per pane at 20k
  points, and up to 4 panes per frame.

**Fix:** compute one content fingerprint per chart when it is read, and use it for both caches. Re-read a chart only
when an edit touches the ranges it references (the document knows which cells changed). Re-parse only the parts whose
bytes changed: today a nudge changes the drawing part, and that re-parses every chart part on the sheet.

### 3.4 Three reference resolvers

| Resolver | Accepts | Hidden rows |
|---|---|---|
| `SeriesReader.cells` / `displayCells` (`XLSXCharts.swift:449-510`) | unions, `=`, parentheses | left out |
| `ChartCache.cells` via `ChartRange(formula:)` (`ChartXML.swift:415-466`) | one area only | included |
| `ChartSettings.dataRange` / `seriesInRows` | one area only | — |

The panel calls a chart "editable" when every series has a `c:f`. But only the first resolver can actually follow
names, external references or unions. So the panel offers edits that the cache writer cannot carry out (#6), and the
caches it writes do not match what is drawn.

**Fix:** use one `ChartReference` type that is parsed once and serves the reader, the cache writer and the panel.
"Editable" should mean "every reference resolves through it".

### 3.5 The editor is "patch or rebuild everything"

`XLSXChartEditor` compares the old and new settings and maps them to XML by flattened series index. It patches a few
fields in place. Anything else (`needsRebuild`, `:221-226`) deletes every `*Chart` group and regenerates `<c:ser>`
from `ChartSettings` (#4). The module header says "touch only what changes". That will only hold if the editor works
per series: keep each existing `<c:ser>` node, move it into the new group element, rewrite only `f` and the cache for
changed references, add or drop the few children specific to the chart kind, and build new nodes only for added
series.

### 3.6 Layering

- `SheetChart` and `ChartSettings` live in SpreadsheetFiles, so `GridController` and `GridRenderer` now
  `import SpreadsheetFiles`, and the document calls `XLSXChartEditor` directly. This follows from "the parts are the
  model" and is acceptable, but `PLAN.md` should say it.
- Charts exist only where a workbook carries `CarriedParts`. A new or CSV-imported document creates one on the first
  insert.
- Mac and iPad share all chart interaction in `GridController`. The platform files add only hooks (the context menu,
  and `selectedChartHit` for the iPad pan). No platform code has leaked into the shared model.

---

## 4. Findings in detail

### #1 Critical — Charts render one mark per point, synchronously, inside the main-thread draw

- **Where:**
  - `SheetCharts.swift:41-61` (`SheetChartLayer.image`: `ImageRenderer`, called from `draw` at `:76`)
  - `:224-228` and `:289-341` (one `LineMark`/`BarMark`/`AreaMark` per point)
  - `GridRenderer.swift:303`
  - `copyChartToPasteboard` (`SheetCharts.swift:161-170`)
- **What happens:** a fresh render runs whenever the image key changes:
  - when a chart first shows
  - after each committed edit to any cell it plots
  - after each resize, at release
  - after each zoom or backing-scale step
  - after a light/dark switch
  - on Copy Chart

  Each render builds every mark, with a categorical x domain of every label, inside `NSView.draw` / `UIView.draw`.
  There is no data reduction and no off-main rendering.
- **Evidence (confirmed; line chart at 480×288, scale 2):**

  | Points | Labels | Render |
  |---|---|---|
  | 5,000 | unique | 0.61 s |
  | 5,000 | 12 month labels | 1.29 s |
  | 5,000 | 3 labels repeated | 5.3 s |
  | 20,000 | 12 month labels | **32.6 s** |

  A 3 × 12-point chart renders in 7–10 ms, so small charts are fine.
- **Scenario:** open a file with a line chart over a year of hourly readings (8,760 rows). The window hangs for tens of
  seconds on first draw, again on every edit to that column, and again on every resize or zoom of the chart. Insert ▸
  Chart over a large column does the same.
- **Fix:**
  - Reduce each series to about 2× the plot's pixel width before building marks.
  - Plot line, area and scatter on a numeric x (the point index) and label the axis from the category array.
  - Render outside `draw(_:)`: schedule the render, show the previous image or a placeholder box meanwhile, then
    invalidate.

### #2 High — Quadratic label padding; ranges never clipped to the data

- **Where:** `SheetCharts.swift:400-409` (`PlottedSeries.make`) and `XLSXCharts.swift:449-510` (`SeriesReader`).
- **What happens:**
  - **Padding.** The k-th repeat of a label gets k U+200B characters appended, so N points over L distinct labels make
    about N²/2L characters. Blank cells all share one label, and so do month, region and weekday names, so this is the
    normal case. The long strings then also go into Swift Charts' domain and text measuring, which is why repeated
    labels render 9× slower in #1.
  - **Unclipped ranges.** `SeriesReader` walks every row of the reference with no clip to the used range, and formats
    every category cell.
- **Evidence (confirmed, blank categories):** 5k → 139 ms; 10k → 480 ms; 20k → 1,845 ms. 20k points over 12 month
  labels produce 16.7 M characters. By the same curve, 100k blank categories take about 46 s, and a
  `$B$1:$B$1048576` category reference (a whole column selected by hand, as LibreOffice and others write it) is about
  5 × 10¹¹ characters and runs out of memory.
- **Fix:**
  - Never make labels unique by growing strings. Plot by point index and print `labels[i]` in `AxisValueLabel`.
  - Clip references to the sheet's used range before reading.

### #3 High — Odd chart XML crashes the app when the sheet is drawn

- **Where:**
  - `XLSXCharts.swift:577-586` (`cached`: `[String?](repeating: nil, count: ptCount)`, and growth up to `idx`)
  - `:302-304` and `:636-637` (`accent`: `palette[index % 6]`)
  - reached from `GridController.renderer()` → `document.activeCharts` on every draw after a revision
- **Evidence (confirmed):**
  - `<c:ptCount val="-1"/>` → `Fatal error: Can't construct Array with count < 0`.
  - `<c:idx val="-1"/>` → `Fatal error: Index out of range`.
  - `<c:pt idx="30000000">` → 30 M entries and 5.0 s, **repeated on every revision**. `idx="2000000000"` runs out of
    memory.
- **Scenario:** a corrupt file, a buggy third-party writer, or a crafted file crashes SimpleSpread as soon as the sheet
  with the chart is shown. Any unsaved work in other windows is lost.
- **Fix:**
  - One bounded-integer helper for the chart reader: treat negatives as invalid, cap `ptCount` and `idx` (at
    `CellAddress.maxRows`, and at most `ptCount`), and use `max(0, …)` before any palette index.
  - Apply the same helper to the anchor `col`/`row` and `dPt idx` reads.
  - Add a chart-XML fuzz test.

### #4 High — A type change or new data range silently drops series formatting

- **Where:** `XLSXChartEditor.swift:221-226` (`needsRebuild`) and `:303-327` (`rebuildPlot`).
- **What happens:** any change between chart families (column ↔ line ↔ area, or anything ↔ pie or scatter), and any
  new data range, deletes every `*Chart` group and regenerates `<c:ser>` from `ChartSettings`. Everything the settings
  don't model is lost:
  - trendlines and error bars
  - per-point colours (`dPt`)
  - series-level data labels and their number formats
  - markers, dashes, gradient fills, `smooth`
  - `gapWidth`/`overlap`/`varyColors`
  - the `c15`/`c16` extensions (data-label ranges, filtered series, `uniqueId`)
  - secondary axes
- **Evidence (confirmed):** Excel's clustered column from the fixture, with a linear trendline added, changed to Line:
  the trendline goes true → false, and `c16:uniqueId` goes true → false.
- **Scenario:** a user opens an Excel report whose column chart has a trendline and custom point colours, tries "Line"
  in the Chart panel, and saves. Excel now shows a plain default line chart. Excel itself keeps these when you change
  the type. Undo restores them, but nothing tells the user anything was lost.
- **Fix:** rebuild per series, keeping the existing nodes (§3.5). Until then, warn before a rebuild of a chart whose
  series have unmodelled children.

### #5 High (performance) — Work grows with total chart data on every revision and every draw

- **Where:**
  - `SpreadsheetDocument+Charts.swift:21-33` (cache keyed only by `revision`)
  - `XLSXCharts.swift:186-198` (re-reads every series and number-formats every category, once per series, even when
    the series share one category range)
  - `SheetCharts.swift:25-49` (`ImageKey` hashes the whole chart)
  - `GridRenderer.swift:73-77, 303` (once per pane, up to 4 with frozen panes)
- **Evidence (confirmed, debug):**
  - An edit to an unrelated cell: 7.3 ms (5k points) and 28.6 ms (20k points) for one chart.
  - 10 charts × 3 series × 5k points: 216 ms per revision.
  - Image-cache lookup: 0.55 ms per chart per pane at 20k points.
- **Where the cost multiplies:**
  - **Row and column resize drags** call `markChanged()` on every mouse move, so every tick re-reads every chart.
  - **Each arrow-key nudge** rewrites the drawing part. Its bytes change, so every chart part on the sheet is parsed
    again. Each nudge is also its own undo step: holding → for 1 s leaves about 30 "Move Chart" steps.
  - **Each `ColorPicker` tick** in the Chart panel runs parse → edit → serialise → re-parse every chart → a fresh render
    (#1).
- **Fix:** see §3.3. Also fold repeated nudges into one undo step, as `resize` already does with `lastResizeStep`.

### #6 Medium — Series over defined names or external links go blank after a type change

- **Where:** `ChartXML.swift:420-466`; `XLSXCharts.swift:349-367`.
- **What happens:** the settings accept any `c:f`, such as `Book1.xlsx!SalesNorth` or `[1]Sheet1!$B$2:$B$7`. On a
  rebuild, `ChartCache` can't resolve those and writes `<c:ptCount val="0"/>`. The reader then falls back to that empty
  cache.
- **Evidence (confirmed):** values `[120,…,181]` before a column → line change, `[]` after.
- **Scenario:** dynamic-range charts over named ranges are a common Excel pattern. They go blank on screen and in the
  saved cache.
- **Fix:** use one resolver (§3.4). Keep the old cache when the formula is unchanged and cannot be resolved, or mark
  such charts not editable for type and range changes.

### #7 Medium — Insert ▸ Chart from column headers charts ~200 mostly blank rows

- **Where:** `ChartSettings.swift:146-210` (`series(from:)` never trims), fed by `SpreadsheetDocument+Charts.swift:54-56`
  and `GridController.swift:177-182`. A header selection spans `GridLayout.rowCount`, at least 200.
- **What happens:** a 7-row table selected by its A:D headers gives `Sales!$B$2:$B$200`, with 199 categories of which
  193 are blank. Those references are saved. With #2, blank labels are also the slow path. Excel trims a whole-column
  selection to the data.
- **Fix:** intersect the block with the used range, or with the last row and column that hold data inside it.

### #8 Medium — Delete, move and resize act on a whole group

- **Where:** `XLSXChartEditor.swift:106-179` (`locate` matches any descendant; `delete` removes `found.anchor`). On
  reading, `XLSXCharts.swift:157-163` keeps only the first chart under an anchor.
- **Evidence (confirmed):** a group of {chart, text box "Note kept by user"}. Deleting the chart removes the text box
  too, and the drawing part with it.
- **Scenario:** dashboards often group a chart with a caption or a second chart. Deleting "the chart" silently removes
  the rest of the group.
- **Fix:** remove only the chart's `graphicFrame`, and the group if it becomes empty. Or treat grouped charts as read
  only. Read every chart in an anchor, not only the first.

### #9 Medium — Secondary-axis combos draw on one scale

- **Where:** `XLSXCharts.swift:269-369` (series carry no axis); `SheetChart.Series` (`:31-45`).
- **What happens:** each group's `axId` is ignored, so every series goes on the primary value axis. The fixture's own
  combo (`chart10.xml`, Excel's default "Clustered Column – Line on Secondary Axis") has its line on a right-hand axis.
  `ChartReadingTests` passes because it checks only the series kinds.
- **Scenario:** revenue in thousands with margin % on the secondary axis is the main reason people use this combo. The %
  line is drawn flat at zero.
- **Fix:** record `secondary` per series from the group's value axis, and draw a trailing scale. Until then, mark the
  chart as approximate. Note that `PLAN.md` lists secondary axes as "not covered" only for *editing*.

### #10 Medium — Data labels set per series read as off

- **Where:** `XLSXCharts.swift:296-298` reads only the group's `<c:dLbls>`.
- **Evidence (confirmed):** a series with `<c:dLbls><c:showVal val="1"/>` reads `showsDataLabels == false`.
- **What happens:** the chart shows no labels and the panel toggle shows off. Turning the toggle on rewrites the labels
  of every series.
- **Fix:** read labels per series (the series value, else the group's), show "mixed" in the panel, and accept
  `val="true"`.

### #11 Medium — Saved number caches go stale

- **Where:** caches are written only at insert or rebuild (`ChartXML.swift:415-472`). Save writes chart parts byte for
  byte (`XLSXCharts.swift:4-6`).
- **Evidence (confirmed):** insert a chart, set B2 = 999, save and re-read: the part still holds `<c:v>120</c:v>`.
  Rows inserted inside a range also leave `ptCount` wrong.
- **Scenario:** Excel and Numbers recompute from the cells. Quick Look, Files and Mail previews, and many converters
  read only the cache, so they show the old chart. SimpleSpread itself falls back to the cache for references it
  can't follow.
- **Fix:** at save, in the background copy, refresh `numCache`/`strCache` for every reference the shared resolver can
  follow. This is a small pass like `syncTableHeaders`.

### #12 Medium — The image cache has no budget

- **Where:** `SheetCharts.swift:47-60, 69-76`.
- **What happens:**
  - The image covers the chart's whole frame at backing scale × zoom, and nothing caps it.
  - 480×288 at 400 % on Retina is scale 8, about 35 MB. A dashboard-size 1600×1300 chart is about **530 MB** in one
    image.
  - An iPad pinch makes a new key every 0.5 of scale.
  - The cache holds up to 48 images, plus a full copy of each chart's data inside its key.
  - This risks a memory kill on iPad.
- **Fix:** cap the rendered pixels (4–8 MP) and let Core Graphics scale the image up. Evict by bytes, keep one scale per
  chart, and key the cache by fingerprint.

### #13 Medium — Dragging across a frozen pane jumps

- **Where:** `GridController.swift:326-340`, with `unshifted()` at `:541-546` and `GridGeometry.swift:26-36`.
- **What happens:** the drag delta is mapped through whichever pane the pointer is over **now**.
- **Scenario:** freeze the header row, scroll down 500 rows, and drag a chart upward. As the pointer crosses the freeze
  line, the chart jumps by the scroll offset, and `placeChart` commits it far from where it was dropped. Resize does
  the same.
- **Fix:** compute move and resize deltas in view space. Use pane mapping only for the starting frame.

### #14 Medium — Charts are invisible to keyboard and VoiceOver

- **Where:** `GridController.swift:610-631, 782-784`; `SheetCharts.swift`.
- **What happens:** a chart is pixels inside the grid.
  - No accessibility element exists for it, and rasterising throws away Swift Charts' own accessibility and audio
    graphs.
  - Only a pointer can select a chart, so a keyboard-only user cannot select, edit, move or delete one.
- **Fix:** add one accessibility element per visible chart (title, kind, series and range, frame, with a press action
  that selects it), and a "Select Next Chart" command.

---

## 5. Test gaps that matter

- **Scale:** no chart test has more than about 20 points. Add timing guards like `RenderTimingTests` for a 10k–100k
  point line chart and for repeated or blank categories. Today both would hang the suite (#1, #2).
- **Malformed XML:** nothing tests negative or huge `ptCount`, `idx`, `col` or `row`, missing `plotArea` children, or a
  broken chart part next to good ones (#3).
- **Rebuild fidelity:** `kindChangesRebuildThePlot` checks only the kind and the values. Assert what survives:
  trendline, `dPt`, series `dLbls`, `c15`/`c16`, secondary axis (#4).
- **References:** no series over a defined name, an external link (`[1]Sheet!…`) or a union goes through an edit (#6).
- **Drawings:** no grouped shapes, and no charts mixed with pictures, go through delete or move (#8).
- **Caches:** no check that caches match the cells after an edit and a save (#11).
- **Interaction:** `ChartInteractionTests` run unscrolled, unfrozen, unzoomed and with no hidden rows. Nothing tests a
  drag across a freeze line, a zoomed hit-test, or a chart anchored over hidden rows (#13).
- **Work bounds:** nothing tests that a resize drag, a run of nudges or a colour drag stays bounded in work and in undo
  steps (#5).
- **Structural undo:** the reviewer's probe showed that chart edits mixed with structural undo stay in step, but no
  test pins it. Add `structuralEditAndUndoKeepChartInStep` as a real test.
- **The combo test** asserts series kinds but not the secondary axis, so #9 passes unnoticed.

---

## 6. Strengths (keep these)

- Charts have one source of truth: the parts. Undo, snapshots, background save and structural edits work with no
  chart-specific code, and this was verified end to end.
- Edits made in place keep the part's prefixes and Excel's extension data, and put new elements in schema order.
- Twocell, onecell and absolute anchors are all handled. Chartex inside `mc:AlternateContent` is found and drawn as a
  labelled box, not dropped.
- Only reachable parts are written, so orphaned style and colour parts and a deleted sheet's charts drop out on their
  own. There are no rId or part-number collisions.
- A drag redraws the existing image. Only one `placeChart` (one undo step) runs at release, and a click without
  movement changes nothing.
- Mac and iPad share all chart interaction, and the platform files only add hooks.
- The Excel-for-the-web oracle fixture (`charts-by-excel.xlsx`, `ChartOracleFiles`) is a real interoperability check,
  not a self-consistency one.
