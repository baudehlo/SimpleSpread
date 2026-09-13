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

        // 3. Remap merged ranges.
        sheet.mergedRanges = sheet.mergedRanges.compactMap { range in
            remapRange(range, axisIsRow: axisIsRow, index: index, count: count)
        }

        // 4. Rewrite formulas everywhere.
        rewriteFormulas(in: workbook) { expr, ownSheetName in
            expr.adjustedForStructuralChange(axisIsRow: axisIsRow, index: index, count: count,
                                             editedSheet: editedSheetName, ownSheet: ownSheetName)
        }
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
