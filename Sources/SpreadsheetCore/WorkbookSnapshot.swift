import Foundation

/// A workbook's state saved in memory for undo: take one before a command,
/// call `releaseUnchangedCells` once it has run, and `restore` to put the
/// workbook back as it was.
///
/// Taking one is cheap (`Workbook.copy()`): every table is shared with the
/// live workbook, copy-on-write. Memory: what a snapshot ends up holding is
/// the old version of whatever the command rewrote — the edited sheet's
/// cell table after a row or column insert or delete, the cell tables of
/// other sheets whose formulas it rewrote or whose values the recalculation
/// changed (volatile functions such as NOW and RAND change every time), a
/// deleted sheet, the old pivot definitions — for as long as the step
/// stays on the undo stack. A cell table costs about 100 bytes a cell
/// (~1 GB for 1,048,576 x 10; the XLSX snapshot undo used before kept 24
/// MB). Cell tables the command did not touch are let go
/// (`releaseUnchangedCells`): held, they would make the next edit to that
/// sheet copy its whole table and keep both. The smaller per-sheet tables
/// (row heights, merges, hidden rows) and the style table stay shared,
/// which costs nothing until one changes.
public final class WorkbookSnapshot {
    /// Nil once restored.
    private var saved: Workbook?
    /// Sheets whose cell table the snapshot let go because the command
    /// left it alone: at restore time the live table is that same table.
    private var unchangedCells: Set<Int> = []

    public init(of workbook: Workbook) {
        saved = workbook.copy()
    }

    /// Call right after the command ran on `workbook`: drop the cell tables
    /// it didn't change.
    public func releaseUnchangedCells(comparedTo workbook: Workbook) {
        for sheet in saved?.sheets ?? [] where !unchangedCells.contains(sheet.id) {
            guard let live = workbook.sheet(withID: sheet.id), live.cellsVersion == sheet.cellsVersion else { continue }
            sheet.removeAllCells()
            unchangedCells.insert(sheet.id)
        }
    }

    /// Ids of the sheets whose cell table the snapshot holds (tests).
    var sheetsWithSavedCells: Set<Int> {
        Set(saved?.sheets.map(\.id) ?? []).subtracting(unchangedCells)
    }

    /// Put the saved state back into `workbook` in place (the calculation
    /// engine and the views hold that instance); sheets keep their ids, so
    /// cell undo records still find them. `workbook` must be in the state
    /// the command left it in (undo guarantees that), as the cell tables
    /// let go are taken from it. Frozen panes are a view setting, as in
    /// Excel: sheets that are still there keep theirs. The caller rebuilds
    /// the engine if formulas changed.
    ///
    /// A snapshot is restored once: it hands its tables over and keeps
    /// nothing, so an undo record that lives on a little after it ran
    /// doesn't pin the tables now in use (the next edit would copy them).
    public func restore(into workbook: Workbook) {
        guard let restored = saved else {
            assertionFailure("a snapshot is restored once")
            return
        }
        saved = nil
        for sheet in restored.sheets {
            guard let live = workbook.sheet(withID: sheet.id) else {
                assert(!unchangedCells.contains(sheet.id), "a sheet the command left alone has gone")
                continue
            }
            if unchangedCells.contains(sheet.id) { sheet.adoptCells(of: live) }
            sheet.frozenRows = live.frozenRows
            sheet.frozenColumns = live.frozenColumns
        }
        workbook.replaceContents(with: restored)
    }
}
