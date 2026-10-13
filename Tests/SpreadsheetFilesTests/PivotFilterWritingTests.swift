import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Label/top-N filters are written from the model: after a refresh renumbers
/// fields, the file must name the filter's field by its new number, and a
/// filter whose field left the pivot must be gone.
@Suite("Pivot tables: writing filters")
struct PivotFilterWritingTests {
    /// The synthetic Name | Qty pivot with a top-1 filter on Name.
    static func workbook() throws -> Workbook {
        var builder = PivotPackageBuilder()
        builder.tableExtra = """
        <filters count="1"><filter fld="0" type="count" evalOrder="-1" id="7" iMeasureFld="0" name="keep-me">\
        <autoFilter ref="A1"><filterColumn colId="0"><top10 val="1" filterVal="1"/></filterColumn></autoFilter>\
        </filter></filters>
        """
        return try builder.read().0
    }

    static func filters(_ workbook: Workbook) throws -> [[String: String]] {
        try Package(XLSXWriter.data(for: workbook)).elements(["pivotTableDefinition", "filters", "filter"],
                                                             in: "xl/pivotTables/pivotTable1.xml")
    }

    @Test func aRefreshThatRenumbersFieldsRenumbersTheFilter() throws {
        let workbook = try Self.workbook()
        #expect(workbook.pivotTables[0].definition?.filters.first?.id == 7)
        // The source's columns swap places: Name becomes field 1.
        let data = try #require(workbook.sheet(named: "Data"))
        let rows: [(Double, String)] = [(1, "a"), (2, "b"), (3, "a")]
        data.setCell(Cell(value: .string("Qty")), at: CellAddress(a1: "A1")!)
        data.setCell(Cell(value: .string("Name")), at: CellAddress(a1: "B1")!)
        for (i, row) in rows.enumerated() {
            data.setCell(Cell(value: .number(row.0)), at: CellAddress(row: i + 1, column: 0))
            data.setCell(Cell(value: .string(row.1)), at: CellAddress(row: i + 1, column: 1))
        }
        try workbook.refreshPivotCache(withID: workbook.pivotTables[0].cacheID)
        workbook.applyPivotLayout(at: 0, result: try workbook.computePivotTable(at: 0))
        let written = try Self.filters(workbook)
        #expect(written.count == 1)
        #expect(written.first?["fld"] == "1")
        #expect(written.first?["iMeasureFld"] == "0")
        #expect(written.first?["name"] == "keep-me") // the rest of the original element is kept
        #expect(written.first?["id"] == "7")
        // And it reads back as the same filter on Name.
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        #expect(reread.pivotTables[0].definition?.filters.first?.field == 1)
    }

    @Test func aFilterWhoseFieldWasRemovedIsNotWritten() throws {
        let workbook = try Self.workbook()
        workbook.pivotTables[0].definition?.removeFromAxes(0)
        workbook.applyPivotLayout(at: 0, result: try workbook.computePivotTable(at: 0))
        #expect(try Self.filters(workbook).isEmpty)
    }

    @Test func aFilterMadeHereIsGenerated() throws {
        let workbook = try Self.workbook()
        workbook.pivotTables[0].definition?.filters = [PivotFilter(field: 0, type: "count", top10Value: 2, top10Top: false)]
        workbook.applyPivotLayout(at: 0, result: try workbook.computePivotTable(at: 0))
        let written = try Self.filters(workbook)
        #expect(written.first?["fld"] == "0" && written.first?["type"] == "count")
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        let filter = try #require(reread.pivotTables[0].definition?.filters.first)
        #expect(filter.top10Value == 2 && !filter.top10Top && filter.id != nil)
    }
}
