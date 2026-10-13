import Foundation

// Putting computed pivot layouts into the workbook: the cells a pivot draws,
// its location, and its definition's axis lines and geometry.

extension Workbook {
    /// Compute a pivot table (which must have typed data and definition).
    public func computePivotTable(at index: Int, captions: PivotCaptions = .english) throws -> PivotLayoutResult {
        let table = pivotTables[index]
        guard let definition = table.definition, let data = pivotCache(withID: table.cacheID)?.data else {
            throw PivotEngineError("its definition couldn't be read")
        }
        return try PivotEngine(cache: data, definition: definition, captions: captions).compute()
    }

    /// Where a pivot would sit with `result`: the body keeps its top-left
    /// corner unless the report filters need more room above it.
    public func pivotPlacement(for index: Int, result: PivotLayoutResult) -> (location: CellRange, occupied: CellRange) {
        let start = pivotTables[index].location.start
        let roomAbove = result.pageRows > 0 ? result.pageRows + 1 : 0
        let top = CellAddress(row: max(start.row, roomAbove), column: start.column)
        let location = CellRange(start: top, end: CellAddress(row: top.row + max(1, result.rowCount) - 1,
                                                              column: top.column + max(1, result.columnCount) - 1))
        var probe = pivotTables[index]
        probe.location = location
        probe.pageFieldRows = result.pageRows
        probe.pageFieldColumns = result.pageColumns
        return (location, probe.occupiedRange)
    }

    /// What applying `result` would overwrite outside the pivot's current
    /// area: non-empty cells, and other pivot tables.
    public func pivotLayoutConflicts(for index: Int, result: PivotLayoutResult) -> (cells: [CellAddress], tables: [String]) {
        let table = pivotTables[index]
        guard sheet(withID: table.sheetID) != nil else { return ([], []) }
        let (location, occupied) = pivotPlacement(for: index, result: result)
        guard location.end.isValid else { return ([location.end], []) }
        return pivotAreaConflicts(onSheet: table.sheetID, area: occupied, except: index, outside: table.occupiedRange)
    }

    /// What a pivot table drawn over `area` would overwrite: non-empty cells
    /// (outside `current`, the area it already covers) and other pivot
    /// tables (any but table `except`).
    public func pivotAreaConflicts(onSheet sheetID: Int, area: CellRange, except index: Int? = nil,
                                   outside current: CellRange? = nil) -> (cells: [CellAddress], tables: [String]) {
        guard let sheet = sheet(withID: sheetID) else { return ([], []) }
        var cells: [CellAddress] = []
        for (address, cell) in sheet.cells where area.contains(address) && !(current?.contains(address) ?? false) {
            if !cell.value.isEmpty || cell.formula != nil { cells.append(address) }
        }
        let tables = pivotTables.enumerated().filter { i, other in
            i != index && other.sheetID == sheetID && other.occupiedRange.intersects(area)
        }.map(\.element.name)
        return (cells.sorted(), tables)
    }

    /// Write `result` into the sheet and the pivot's definition. The old area
    /// is cleared first; cells the new layout leaves out stay empty.
    public func applyPivotLayout(at index: Int, result: PivotLayoutResult) {
        let table = pivotTables[index]
        guard let sheet = sheet(withID: table.sheetID) else { return }
        let (location, occupied) = pivotPlacement(for: index, result: result)
        for address in sheet.cells.keys where table.occupiedRange.contains(address) || occupied.contains(address) {
            sheet.setCell(Cell(), at: address)
        }
        pivotTables[index].location = location
        pivotTables[index].pageFieldRows = result.pageRows
        pivotTables[index].pageFieldColumns = result.pageColumns
        if var definition = pivotTables[index].definition {
            definition.rowLines = result.rowLines
            definition.columnLines = result.columnLines
            definition.firstHeaderRow = result.firstHeaderRow
            definition.firstDataRow = result.firstDataRow
            definition.firstDataCol = result.firstDataCol
            pivotTables[index].definition = definition
        }
        pivotTables[index].isModified = true
        pivotTables[index].cellRoles = result.cells.mapValues(\.role)
        for (offset, rendered) in result.cells {
            let address = CellAddress(row: location.start.row + offset.row, column: location.start.column + offset.column)
            guard address.isValid else { continue }
            let style = CellStyle(numberFormat: rendered.numberFormat ?? .general, pivotButton: rendered.pivotButton,
                                  indent: rendered.indent)
            sheet.setCell(Cell(value: rendered.value, styleIndex: styleIndex(for: style)), at: address)
        }
    }
}
