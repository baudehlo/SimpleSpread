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
            // What the cell shows: its own style, or its row's or column's.
            let shown = old != 0 ? old : sheet.inheritedStyleIndex(at: address)
            var restyled: Int
            if !addressDependent, let known = mapped[shown] {
                restyled = known
            } else {
                var style = workbook.style(at: shown)
                mutate(address, &style)
                restyled = workbook.styleIndex(for: style)
                if !addressDependent { mapped[shown] = restyled }
            }
            let new = workbook.storableStyleIndex(restyled, at: address, in: sheet)
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

    /// Restyle the selection as one undo step. A selection of whole
    /// columns or rows formats the columns or rows themselves (unless the
    /// change depends on where a cell is, as borders do).
    func applyStyle(to range: CellRange, actionName: String, addressDependent: Bool,
                    _ mutate: (CellAddress, inout CellStyle) -> Void) {
        if !addressDependent, let lines = wholeLines(of: range) {
            restyle(lines, actionName: actionName) { mutate(range.start, &$0) }
            return
        }
        let changed = restyle(range, addressDependent: addressDependent, mutate)
        guard !changed.isEmpty else { return }
        registerStyleUndo(changed, sheetID: activeSheetID, actionName: actionName)
        markChanged()
    }

    // MARK: - Whole rows and columns

    /// Columns or rows selected from end to end.
    enum WholeLines: Equatable {
        case columns(ClosedRange<Int>)
        case rows(ClosedRange<Int>)
    }

    /// The columns (or rows) `range` covers from the first row to the
    /// grid's last (from the first column to the last), as a header click
    /// selects them; nil for any other range.
    func wholeLines(of range: CellRange) -> WholeLines? {
        let layout = GridLayout(sheet: activeSheet)
        let lastRow = min(layout.rowCount, CellAddress.maxRows) - 1
        let lastColumn = min(layout.columnCount, CellAddress.maxColumns) - 1
        if range.start.row == 0, range.end.row >= lastRow {
            return .columns(range.start.column...min(range.end.column, CellAddress.maxColumns - 1))
        }
        if range.start.column == 0, range.end.column >= lastColumn {
            return .rows(range.start.row...min(range.end.row, CellAddress.maxRows - 1))
        }
        return nil
    }

    /// Format whole columns or rows: the format goes on the column or row
    /// (as in Excel's file), so the cells that inherit it aren't touched;
    /// cells with a style of their own are restyled, and where a formatted
    /// row crosses a formatted column (the row's format wins there) the
    /// crossing cell takes both. Work and undo record are bounded by the
    /// styled cells, not the size of the selection.
    func restyle(_ lines: WholeLines, actionName: String, _ mutate: (inout CellStyle) -> Void) {
        let sheet = activeSheet
        let rowStylesBefore = sheet.rowStyles, columnStylesBefore = sheet.columnStyles
        var mapped: [Int: Int] = [:]
        func restyled(_ index: Int) -> Int {
            if let known = mapped[index] { return known }
            var style = workbook.style(at: index)
            mutate(&style)
            let new = workbook.styleIndex(for: style)
            mapped[index] = new
            return new
        }
        func lineStyle(_ index: Int) -> Int? {
            workbook.style(at: index) == .default ? nil : index
        }
        // Cells whose new style is worked out against the old formats.
        var writes: [(CellAddress, Int)] = []
        switch lines {
        case .columns(let columns):
            // One pass over what's stored: a whole column has a million addresses.
            for (address, cell) in sheet.cells where columns.contains(address.column) {
                if cell.styleIndex != 0 {
                    writes.append((address, restyled(cell.styleIndex)))
                } else if let row = sheet.rowStyles[address.row] {
                    writes.append((address, restyled(row)))
                }
            }
            for (row, style) in sheet.rowStyles {
                for column in columns where sheet.cells[CellAddress(row: row, column: column)] == nil {
                    writes.append((CellAddress(row: row, column: column), restyled(style)))
                }
            }
            for column in columns {
                sheet.columnStyles[column] = lineStyle(restyled(sheet.columnStyles[column] ?? 0))
            }
        case .rows(let rows):
            let range = CellRange(start: CellAddress(row: rows.lowerBound, column: 0),
                              end: CellAddress(row: rows.upperBound, column: CellAddress.maxColumns - 1))
            for address in storedAddresses(in: range, sheet: sheet) {
                let own = sheet.cell(at: address).styleIndex
                if own != 0 {
                    writes.append((address, restyled(own)))
                } else if sheet.rowStyles[address.row] == nil, let column = sheet.columnStyles[address.column] {
                    writes.append((address, restyled(column)))
                }
            }
            for (column, style) in sheet.columnStyles {
                for row in rows where sheet.rowStyles[row] == nil
                    && sheet.cells[CellAddress(row: row, column: column)] == nil {
                    writes.append((CellAddress(row: row, column: column), restyled(style)))
                }
            }
            for row in rows {
                sheet.rowStyles[row] = lineStyle(restyled(sheet.rowStyles[row] ?? 0))
            }
        }
        // Stored against the new formats.
        var changed: [StyleSnapshot] = []
        for (address, index) in writes {
            var cell = sheet.cell(at: address)
            let new = workbook.storableStyleIndex(index, at: address, in: sheet)
            guard new != cell.styleIndex else { continue }
            changed.append(StyleSnapshot(address: address, styleIndex: cell.styleIndex))
            cell.styleIndex = new
            sheet.setCell(cell, at: address)
        }
        guard !changed.isEmpty || sheet.rowStyles != rowStylesBefore || sheet.columnStyles != columnStylesBefore
        else { return }
        registerLineStyleUndo(LineStyles(cells: changed, rowStyles: rowStylesBefore, columnStyles: columnStylesBefore),
                              sheetID: sheet.id, actionName: actionName)
        markChanged()
    }

    /// What a whole-row or whole-column format replaced.
    struct LineStyles {
        let cells: [StyleSnapshot]
        let rowStyles: [Int: Int]
        let columnStyles: [Int: Int]
    }

    func registerLineStyleUndo(_ saved: LineStyles, sheetID: Int, actionName: String) {
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    guard let sheet = doc.workbook.sheet(withID: sheetID) else { return }
                    let current = (sheet.rowStyles, sheet.columnStyles)
                    sheet.rowStyles = saved.rowStyles
                    sheet.columnStyles = saved.columnStyles
                    let cells = doc.restoreStyles(saved.cells, sheetID: sheetID)
                    doc.registerLineStyleUndo(LineStyles(cells: cells, rowStyles: current.0, columnStyles: current.1),
                                              sheetID: sheetID, actionName: actionName)
                    doc.markChanged()
                }
            }
            undoManager.setActionName(actionName)
        }
    }
}
