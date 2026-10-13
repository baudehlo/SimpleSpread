import Foundation

/// Structural edits (insert/delete rows/columns, sheet ops) with formula
/// rewriting across the whole workbook. Callers should run
/// `CalculationEngine.rebuildAll()` afterwards.
public enum WorkbookOperations {
    // MARK: Rows & columns

    public static func insertRows(in workbook: Workbook, sheetID: Int, at index: Int, count: Int) {
        guard count > 0 else { return }
        shift(workbook: workbook, sheetID: sheetID, axisIsRow: true, index: index, count: count)
    }

    public static func deleteRows(in workbook: Workbook, sheetID: Int, at index: Int, count: Int) {
        guard count > 0 else { return }
        shift(workbook: workbook, sheetID: sheetID, axisIsRow: true, index: index, count: -count)
    }

    public static func insertColumns(in workbook: Workbook, sheetID: Int, at index: Int, count: Int) {
        guard count > 0 else { return }
        shift(workbook: workbook, sheetID: sheetID, axisIsRow: false, index: index, count: count)
    }

    public static func deleteColumns(in workbook: Workbook, sheetID: Int, at index: Int, count: Int) {
        guard count > 0 else { return }
        shift(workbook: workbook, sheetID: sheetID, axisIsRow: false, index: index, count: -count)
    }

    private static func shift(workbook: Workbook, sheetID: Int, axisIsRow: Bool, index: Int, count: Int) {
        guard let sheet = workbook.sheet(withID: sheetID) else { return }
        let editedSheetName = sheet.name

        // 1. Remap cell storage on the edited sheet.
        var newCells: [CellAddress: Cell] = [:]
        newCells.reserveCapacity(sheet.cells.count)
        for (addr, cell) in sheet.cells {
            let pos = axisIsRow ? addr.row : addr.column
            if count < 0 {
                let delEnd = index - count - 1 // index + |count| - 1
                if pos >= index && pos <= delEnd { continue } // deleted
                let newPos = pos > delEnd ? pos + count : pos
                let newAddr = axisIsRow
                    ? CellAddress(row: newPos, column: addr.column)
                    : CellAddress(row: addr.row, column: newPos)
                newCells[newAddr] = cell
            } else {
                let newPos = pos >= index ? pos + count : pos
                let newAddr = axisIsRow
                    ? CellAddress(row: newPos, column: addr.column)
                    : CellAddress(row: addr.row, column: newPos)
                newCells[newAddr] = cell
            }
        }
        sheet.cells = newCells

        // 2. Remap sizing metadata.
        if axisIsRow {
            sheet.rowHeights = remapIndexMap(sheet.rowHeights, index: index, count: count)
        } else {
            sheet.columnWidths = remapIndexMap(sheet.columnWidths, index: index, count: count)
        }

        // 3. Remap merged ranges, hidden rows and the AutoFilter.
        sheet.mergedRanges = sheet.mergedRanges.compactMap { range in
            remapRange(range, axisIsRow: axisIsRow, index: index, count: count)
        }
        if axisIsRow {
            sheet.hiddenRows = Set(sheet.hiddenRows.compactMap { remapIndex($0, index: index, count: count) })
        }
        if let filter = sheet.autoFilter {
            sheet.autoFilter = remapAutoFilter(filter, axisIsRow: axisIsRow, index: index, count: count)
        }

        // 4. Rewrite formulas everywhere.
        rewriteFormulas(in: workbook) { expr, ownSheetName in
            expr.adjustedForStructuralChange(axisIsRow: axisIsRow, index: index, count: count,
                                             editedSheet: editedSheetName, ownSheet: ownSheetName)
        }

        // 5. Keep preserved pivot tables and their sources in step.
        shiftPivots(in: workbook, sheetID: sheetID, sheetName: editedSheetName,
                    axisIsRow: axisIsRow, index: index, count: count)
    }

    // MARK: Pivot tables

    /// How a row/column insert or delete affects a pivot table's drawn area.
    enum PivotEffect: Equatable {
        case unaffected
        case shifted(by: Int)
        case removed
        /// The edit cuts through the table (Excel refuses these).
        case split
    }

    static func pivotEffect(of table: PivotTable, axisIsRow: Bool, index: Int, count: Int) -> PivotEffect {
        let occupied = table.occupiedRange
        let first = axisIsRow ? occupied.start.row : occupied.start.column
        let last = axisIsRow ? occupied.end.row : occupied.end.column
        let limit = axisIsRow ? CellAddress.maxRows : CellAddress.maxColumns
        if count > 0 {
            // Pushed off the sheet edge its cells are lost: as good as a split.
            if index <= first { return last + count < limit ? .shifted(by: count) : .split }
            if index > last { return .unaffected }
            return .split
        }
        let delEnd = index - count - 1
        if delEnd < first { return .shifted(by: count) }
        if index > last { return .unaffected }
        if index <= first && delEnd >= last { return .removed }
        return .split
    }

    /// The first pivot table that inserting/deleting `count` rows or columns
    /// at `index` would cut through, if any. Callers refuse such edits, as
    /// Excel does; deleting every row/column a pivot table spans is allowed
    /// and removes it.
    public static func pivotTableSplit(in workbook: Workbook, sheetID: Int, axisIsRow: Bool,
                                       index: Int, count: Int) -> PivotTable? {
        workbook.pivotTables(onSheet: sheetID).first {
            pivotEffect(of: $0, axisIsRow: axisIsRow, index: index, count: count) == .split
        }
    }

    private static func shiftPivots(in workbook: Workbook, sheetID: Int, sheetName: String,
                                    axisIsRow: Bool, index: Int, count: Int) {
        guard !workbook.pivotTables.isEmpty else { return }
        var removed: Set<Int> = []
        for i in workbook.pivotTables.indices where workbook.pivotTables[i].sheetID == sheetID {
            switch pivotEffect(of: workbook.pivotTables[i], axisIsRow: axisIsRow, index: index, count: count) {
            case .unaffected:
                break
            case .shifted(let delta):
                let loc = workbook.pivotTables[i].location
                workbook.pivotTables[i].location = axisIsRow
                    ? CellRange(start: CellAddress(row: loc.start.row + delta, column: loc.start.column),
                                end: CellAddress(row: loc.end.row + delta, column: loc.end.column))
                    : CellRange(start: CellAddress(row: loc.start.row, column: loc.start.column + delta),
                                end: CellAddress(row: loc.end.row, column: loc.end.column + delta))
            case .removed, .split:
                // A split is refused upstream; should one get here anyway, the
                // definition no longer matches its cells, so the table goes
                // (its cells stay as plain values) rather than corrupt the file.
                removed.insert(i)
            }
        }
        if !removed.isEmpty {
            workbook.pivotTables = workbook.pivotTables.enumerated()
                .filter { !removed.contains($0.offset) }.map(\.element)
            workbook.pruneUnusedPivotCaches()
            workbook.clearStrayPivotButtons()
        }

        for c in workbook.pivotCaches.indices {
            for r in workbook.pivotCaches[c].sourceRanges.indices {
                let source = workbook.pivotCaches[c].sourceRanges[r]
                guard source.target == .sheet(id: sheetID) else { continue }
                switch adjustedSourceRef(source.ref, sheetName: sheetName,
                                         axisIsRow: axisIsRow, index: index, count: count) {
                case .some(let ref):
                    workbook.pivotCaches[c].sourceRanges[r].ref = ref
                case .none:
                    // Every source row/column was deleted: the cache keeps its
                    // snapshot, but there's nothing left to refresh from.
                    workbook.pivotCaches[c].sourceRanges[r].target = .detached(sheetName: sheetName)
                }
            }
        }
    }

    /// Apply a structural edit to a pivot source reference with formula
    /// semantics. Nil when the edit deletes the whole range; an unparseable
    /// reference is returned unchanged.
    static func adjustedSourceRef(_ ref: String, sheetName: String, axisIsRow: Bool,
                                  index: Int, count: Int) -> String? {
        guard let expr = try? FormulaParser.parse(ref), case .reference = expr else { return ref }
        let adjusted = expr.adjustedForStructuralChange(axisIsRow: axisIsRow, index: index, count: count,
                                                        editedSheet: sheetName, ownSheet: sheetName)
        guard case .reference(let newRef) = adjusted else { return nil }
        // Shifted past the sheet edge: nothing valid left to refresh from.
        let ends = [newRef.start] + (newRef.end.map { [$0] } ?? [])
        guard ends.allSatisfy({ ($0.row ?? 0) < CellAddress.maxRows && ($0.column ?? 0) < CellAddress.maxColumns })
        else { return nil }
        return newRef.text
    }

    private static func remapIndexMap(_ map: [Int: CGFloat], index: Int, count: Int) -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        for (pos, size) in map {
            if count < 0 {
                let delEnd = index - count - 1
                if pos >= index && pos <= delEnd { continue }
                out[pos > delEnd ? pos + count : pos] = size
            } else {
                out[pos >= index ? pos + count : pos] = size
            }
        }
        return out
    }

    /// Where one row/column index lands after the edit; nil when deleted.
    static func remapIndex(_ pos: Int, index: Int, count: Int) -> Int? {
        if count < 0 {
            let delEnd = index - count - 1
            if pos >= index && pos <= delEnd { return nil }
            return pos > delEnd ? pos + count : pos
        }
        return pos >= index ? pos + count : pos
    }

    /// The filter moves and resizes with its range (a one-cell range still
    /// counts, unlike a merge); per-column criteria follow their columns.
    static func remapAutoFilter(_ filter: AutoFilter, axisIsRow: Bool, index: Int, count: Int) -> AutoFilter? {
        if axisIsRow {
            // Deleting the header row removes the filter, as in Excel.
            guard remapIndex(filter.range.start.row, index: index, count: count) != nil else { return nil }
        }
        var start = axisIsRow ? filter.range.start.row : filter.range.start.column
        var end = axisIsRow ? filter.range.end.row : filter.range.end.column
        if count < 0 {
            let delEnd = index - count - 1
            if start >= index { start = start <= delEnd ? index : start + count }
            if end >= index { end = end <= delEnd ? index - 1 : end + count }
            if end < start { return nil }
        } else {
            if start >= index { start += count }
            if end >= index { end += count }
        }
        var result = filter
        if axisIsRow {
            result.range = CellRange(start: CellAddress(row: start, column: filter.range.start.column),
                                     end: CellAddress(row: end, column: filter.range.end.column))
        } else {
            result.range = CellRange(start: CellAddress(row: filter.range.start.row, column: start),
                                     end: CellAddress(row: filter.range.end.row, column: end))
            var columns: [Int: ColumnFilter] = [:]
            for (offset, criteria) in filter.columns {
                if let column = remapIndex(filter.range.start.column + offset, index: index, count: count) {
                    columns[column - start] = criteria
                }
            }
            result.columns = columns
        }
        return result
    }

    private static func remapRange(_ range: CellRange, axisIsRow: Bool, index: Int, count: Int) -> CellRange? {
        var start = axisIsRow ? range.start.row : range.start.column
        var end = axisIsRow ? range.end.row : range.end.column
        if count < 0 {
            let delEnd = index - count - 1
            if start >= index && end <= delEnd { return nil } // fully deleted
            if start >= index { start = start <= delEnd ? index : start + count }
            if end >= index { end = end <= delEnd ? index - 1 : end + count }
            if end < start { return nil }
        } else {
            if start >= index { start += count }
            if end >= index { end += count }
        }
        let newRange = axisIsRow
            ? CellRange(start: CellAddress(row: start, column: range.start.column),
                        end: CellAddress(row: end, column: range.end.column))
            : CellRange(start: CellAddress(row: range.start.row, column: start),
                        end: CellAddress(row: range.end.row, column: end))
        return newRange.cellCount > 1 ? newRange : nil
    }

    // MARK: Sheet operations

    /// Rename a sheet, rewriting sheet-qualified references in all formulas.
    /// Returns the applied name.
    @discardableResult
    public static func renameSheet(in workbook: Workbook, sheetID: Int, to newName: String) -> String? {
        guard let sheet = workbook.sheet(withID: sheetID) else { return nil }
        let oldName = sheet.name
        guard let applied = workbook.renameSheet(withID: sheetID, to: newName) else { return nil }
        guard applied.caseInsensitiveCompare(oldName) != .orderedSame else { return applied }
        rewriteFormulas(in: workbook) { expr, _ in
            expr.renamingSheet(from: oldName, to: applied)
        }
        return applied
    }

    /// Delete a sheet; formulas referencing it become #REF!.
    @discardableResult
    public static func deleteSheet(in workbook: Workbook, sheetID: Int) -> Bool {
        guard let sheet = workbook.sheet(withID: sheetID) else { return false }
        let name = sheet.name
        guard workbook.removeSheet(withID: sheetID) != nil else { return false }
        // Pivot tables on the sheet go with it; caches it fed keep their
        // snapshot (pivots elsewhere still display) but lose their source.
        workbook.removePivotTables { $0.sheetID == sheetID }
        for c in workbook.pivotCaches.indices {
            for r in workbook.pivotCaches[c].sourceRanges.indices
            where workbook.pivotCaches[c].sourceRanges[r].target == .sheet(id: sheetID) {
                workbook.pivotCaches[c].sourceRanges[r].target = .detached(sheetName: name)
            }
        }
        rewriteFormulas(in: workbook) { expr, _ in
            expr.mappingReferences { ref in
                if let s = ref.sheetName, s.caseInsensitiveCompare(name) == .orderedSame {
                    return nil // -> #REF!
                }
                return ref
            }
        }
        return true
    }

    // MARK: Copy / fill translation

    /// Translate a formula for a copy/paste or fill offset. Unparseable
    /// formulas are returned unchanged.
    public static func translatedFormula(_ text: String, byRows rows: Int, columns: Int) -> String {
        guard rows != 0 || columns != 0 else { return text }
        guard let expr = try? FormulaParser.parse(text) else { return text }
        return expr.adjustedForCopy(byRows: rows, columns: columns).text
    }

    // MARK: Shared

    private static func rewriteFormulas(
        in workbook: Workbook,
        _ transform: (FormulaExpr, _ ownSheetName: String) -> FormulaExpr
    ) {
        for sheet in workbook.sheets {
            for (addr, cell) in sheet.cells {
                guard let formula = cell.formula,
                      let expr = try? FormulaParser.parse(formula) else { continue }
                let newExpr = transform(expr, sheet.name)
                if newExpr != expr {
                    var newCell = cell
                    newCell.formula = newExpr.text
                    sheet.setCell(newCell, at: addr)
                }
            }
        }
    }
}
