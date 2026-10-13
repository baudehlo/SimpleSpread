import Foundation
import SpreadsheetCore

/// Range commands over the cells a sheet actually stores. The store is
/// sparse, so a whole-column selection or ⌘A on a big sheet is mostly
/// addresses with nothing in them; formatting, clearing formats, merging
/// and sorting walk the stored cells (and, for formatting, the blanks among
/// them) instead of building every address in the rectangle.
extension SpreadsheetDocument {
    /// Selections up to this many cells format every cell in them, blank or
    /// not, so text typed into a blank later picks up the format.
    static let formatEveryCellLimit = 100_000

    /// The part of `range` inside `other`, if they overlap.
    static func intersection(_ range: CellRange, _ other: CellRange) -> CellRange? {
        guard range.intersects(other) else { return nil }
        return CellRange(start: CellAddress(row: max(range.start.row, other.start.row),
                                            column: max(range.start.column, other.start.column)),
                         end: CellAddress(row: min(range.end.row, other.end.row),
                                          column: min(range.end.column, other.end.column)))
    }

    /// The stored (non-default) cells inside `range`, found by looking up
    /// the range's addresses or by scanning the store, whichever is fewer.
    func storedAddresses(in range: CellRange, sheet: Sheet) -> [CellAddress] {
        if range.cellCount <= sheet.cells.count {
            var result: [CellAddress] = []
            range.forEachAddress { if sheet.cells[$0] != nil { result.append($0) } }
            return result
        }
        return sheet.cells.keys.filter { range.contains($0) }
    }

    /// The cells a formatting command over `range` changes.
    ///
    /// Up to `formatEveryCellLimit` cells: every address, as before. A
    /// bigger selection (whole columns or rows, ⌘A on a big sheet) covers
    /// the cells inside the used range: the stored ones and the blanks
    /// among them, as Excel formats a blank in the middle of a table. Blank
    /// cells past the data are left alone; SimpleSpread has no whole-column
    /// formats, and filling the grid's spare rows with formatted blanks
    /// grew the sheet by 50 rows every time. When even the used part is
    /// mostly empty (a few cells far apart), only stored cells are touched,
    /// so the work is bounded by what the sheet holds.
    func forEachFormattingTarget(in range: CellRange, sheet: Sheet, _ body: (CellAddress) -> Void) {
        if range.cellCount <= Self.formatEveryCellLimit {
            range.forEachAddress(body)
            return
        }
        guard let used = sheet.usedRange, let clipped = Self.intersection(range, used) else { return }
        if clipped.cellCount <= max(Self.formatEveryCellLimit, 2 * sheet.cells.count) {
            clipped.forEachAddress(body)
        } else {
            for address in storedAddresses(in: clipped, sheet: sheet) { body(address) }
        }
    }

    // MARK: - Style-only undo

    /// A cell's style before a formatting command. Formatting leaves values
    /// and formulas alone, so undo puts back styles only (no recalculation,
    /// and a twentieth of the memory of whole-cell snapshots).
    struct StyleSnapshot {
        let address: CellAddress
        let styleIndex: Int
    }

    /// Restyle the formatting targets of `range` on the active sheet,
    /// returning the old styles of the cells that changed. Unless the
    /// mutation depends on the address, each distinct style is worked out
    /// once.
    func restyle(_ range: CellRange, addressDependent: Bool,
                 _ mutate: (CellAddress, inout CellStyle) -> Void) -> [StyleSnapshot] {
        let sheet = activeSheet
        var changed: [StyleSnapshot] = []
        var mapped: [Int: Int] = [:]
        // Collected first: restyling writes to the store being walked.
        var targets: [CellAddress] = []
        forEachFormattingTarget(in: range, sheet: sheet) { targets.append($0) }
        for address in targets {
            var cell = sheet.cell(at: address)
            let old = cell.styleIndex
            let new: Int
            if !addressDependent, let known = mapped[old] {
                new = known
            } else {
                var style = workbook.style(at: old)
                mutate(address, &style)
                new = workbook.styleIndex(for: style)
                if !addressDependent { mapped[old] = new }
            }
            guard new != old else { continue }
            changed.append(StyleSnapshot(address: address, styleIndex: old))
            cell.styleIndex = new
            sheet.setCell(cell, at: address)
        }
        return changed
    }

    /// Put back styles (keeping each cell's value and formula), returning
    /// the styles they replaced, for redo.
    func restoreStyles(_ snapshots: [StyleSnapshot], sheetID: Int) -> [StyleSnapshot] {
        guard let sheet = workbook.sheet(withID: sheetID) else { return [] }
        var replaced: [StyleSnapshot] = []
        replaced.reserveCapacity(snapshots.count)
        for snap in snapshots {
            var cell = sheet.cell(at: snap.address)
            replaced.append(StyleSnapshot(address: snap.address, styleIndex: cell.styleIndex))
            cell.styleIndex = snap.styleIndex
            sheet.setCell(cell, at: snap.address)
        }
        return replaced
    }

    func registerStyleUndo(_ snapshots: [StyleSnapshot], sheetID: Int, actionName: String) {
        guard !snapshots.isEmpty else { return }
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    let redo = doc.restoreStyles(snapshots, sheetID: sheetID)
                    doc.registerStyleUndo(redo, sheetID: sheetID, actionName: actionName)
                    doc.markChanged()
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Restyle the selection as one undo step.
    func applyStyle(to range: CellRange, actionName: String, addressDependent: Bool,
                    _ mutate: (CellAddress, inout CellStyle) -> Void) {
        let changed = restyle(range, addressDependent: addressDependent, mutate)
        guard !changed.isEmpty else { return }
        registerStyleUndo(changed, sheetID: activeSheetID, actionName: actionName)
        markChanged()
    }
}
