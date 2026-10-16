# UI tests (Mac)

These tests use the app the way a person does. They open the real document
window, click and drag in it, type, use the menus, dialogs, popovers and
panels, and read what's on screen. The unit tests check the engine. These
check that you can actually use the product: that a dialog opens and stays
open, that a panel survives a click on the sheet, that a 20,000-row workbook
stays responsive.

They are slow (about 3 minutes), so CI doesn't run them. Run them before a
release, and after any change to a dialog, menu, panel or the grid's mouse
handling:

    scripts/ui-tests.sh                  # all of them
    scripts/ui-tests.sh PivotScenario    # those matching a filter
    scripts/ui-tests.sh --ipad           # then the iPad XCUITests too

Without `SIMPLESPREAD_UI_TESTS=1` (which the script sets), plain `swift test`
skips them.

## What's here

- `MenuSweepTests`: every menu command (from the `DocumentCommand` catalog
  the menus are built from) runs on five documents: blank, the demo, a sales
  table, a complex.xlsx-sized workbook and Excel's own charts. Each command,
  when enabled, must change something you can see, within 2 s (5 s on the
  big one). A dialog or bar it opens must show and stay open. A new menu
  command is covered as soon as it's in the catalog.
- `PivotScenarioTests`, `ChartScenarioTests`, `DialogScenarioTests`,
  `GridScenarioTests`: whole tasks, start to finish. Examples: make a pivot
  and tick fields; insert, move, restyle and delete a chart; sort, find and
  filter; type, fill, resize and use header menus.
- `Support/AppWindow.swift`: the harness (below).
- `Support/Corpus.swift`: the documents.

## How the harness works

`AppWindow` puts the real `DocumentWindowView` in a window off-screen
(nothing appears on your screen or takes focus) and makes it key within the
test process.

- **The grid** gets its mouse events directly.
- **SwiftUI** gets events through the window. `NSApplication.isActive` is
  swizzled to true, so the first click isn't spent activating the app.
- **AppKit controls** (buttons, segmented controls, pop-ups, text fields)
  are operated as an accessibility press would, because their mouse
  tracking loops can't run in a test host.
- **Text on screen** is read with Vision text recognition. Tests find
  things by what they say ("Create", "PivotTable Fields") rather than by
  coordinates.

Each test writes `.build/ui-test-artifacts/<test>/`:

- `trace.log`: every step as it happens.
- A screenshot for each failed check.
- With `SIMPLESPREAD_UI_SHOTS=1`, a screenshot of every step the test notes.

## Limits, and what to do about them

- **AppKit can end the test host silently, with a zero exit status.** It
  happens when something calls `NSApp.postEvent`/`nextEvent`, or drives a
  popover after it closed. The script treats a run without a final result
  as a failure and prints the last steps from the trace.
- **SwiftUI checkboxes in a list (the filter popover's values) can't be
  toggled.** Neither synthesized clicks nor `performClick` reach their
  binding. Filter by condition instead, or check the model.
- **SwiftUI keyboard shortcuts (`.keyboardShortcut(.defaultAction)`) don't
  fire from a synthesized Return.** Click the button.
- **Clicking a disabled SwiftUI button closes a popover in the test host.**
  Don't.
- **Tests must run one at a time** (`--no-parallel`): each needs its window
  to be the key window.
