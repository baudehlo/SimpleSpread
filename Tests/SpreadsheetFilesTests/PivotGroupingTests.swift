import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("Pivot tables: grouping")
struct PivotGroupingTests {
    /// The oracle data with one pivot: `field` on rows, Units summed.
    static func table(rows field: Int) throws -> (Workbook, Int) {
        let wb = try PivotOracleWorkbook.make()
        let data = wb.sheet(named: "Data")!
        let sheet = wb.addSheet(named: "Grouped")
        let t = try wb.createPivotTable(sourceSheetID: data.id, source: CellRange(a1: "A1:G49")!,
                                        destinationSheetID: sheet.id, at: CellAddress(a1: "A3")!)
        let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
        wb.pivotTables[t].definition!.place(field: field, in: .rows, cache: cache)
        wb.pivotTables[t].definition!.place(field: 4, in: .values, cache: cache)
        return (wb, t)
    }

    static func labels(_ wb: Workbook, _ t: Int) throws -> [String] {
        let result = try wb.computePivotTable(at: t)
        return result.cells.compactMap { offset, cell in
            offset.column == 0 && (cell.role == .rowLabel || cell.role == .subtotalLabel) ? (offset.row, cell.value) : nil
        }.sorted { $0.0 < $1.0 }.compactMap { if case .string(let s) = $0.1 { return s }; return nil }
    }

    @Test func closedRangesOverWholeNumbers() {
        #expect(PivotFieldGroup.numberItems(start: 1, end: 20, interval: 5, integers: true).map(\.cellValue)
                == ["<1", "1-5", "6-10", "11-15", "16-20", ">21"].map { CellValue.string($0) })
    }

    @Test func continuousRangesOverFractions() {
        #expect(PivotFieldGroup.numberItems(start: 0, end: 5, interval: 1, integers: false).map(\.cellValue)
                == ["<0", "0-1", "1-2", "2-3", "3-4", "4-5", ">5"].map { CellValue.string($0) })
        #expect(PivotFieldGroup.numberItems(start: 0, end: 4.5, interval: 2, integers: false).count == 5)
    }

    @Test func datesAddCoarserFieldsBeforeTheGroupedOne() throws {
        let (wb, t) = try Self.table(rows: 3)
        try wb.groupPivotField(table: t, field: 3, byDates: [.years, .quarters, .months])
        let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
        #expect(cache.fields.map(\.name).suffix(2) == ["Quarters", "Years"])
        let d = wb.pivotTables[t].definition!
        #expect(d.rowFields == [8, 7, 3])
        #expect(cache.fields[3].group?.parent == 7)
        #expect(cache.fields[7].group?.parent == 8)
        #expect(try Self.labels(wb, t).prefix(3) == ["2024", "Qtr1", "Jan"])
    }

    @Test func ungroupRestoresTheField() throws {
        let (wb, t) = try Self.table(rows: 3)
        let before = try wb.computePivotTable(at: t)
        try wb.groupPivotField(table: t, field: 3, byDates: [.years, .months])
        try wb.ungroupPivotField(table: t, field: 3)
        let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
        #expect(cache.fields.count == 7)
        #expect(cache.fields[3].group == nil)
        #expect(wb.pivotTables[t].definition!.rowFields == [3])
        #expect(try wb.computePivotTable(at: t).cells.count == before.cells.count)
    }

    @Test func refusesUnsuitableFields() throws {
        let (wb, t) = try Self.table(rows: 0)
        #expect(throws: PivotEngineError.self) { try wb.groupPivotField(table: t, field: 0, byDates: [.months]) }
        #expect(throws: PivotEngineError.self) { try wb.groupPivotField(table: t, field: 0, interval: 1) }
        try wb.groupPivotField(table: t, field: 4, interval: 5)
        #expect(throws: PivotEngineError.self) { try wb.groupPivotField(table: t, field: 4, interval: 2) }
    }

    @Test func groupedPivotsSurviveSaving() throws {
        let (wb, t) = try Self.table(rows: 5)
        try wb.groupPivotField(table: t, field: 5, interval: 1, start: 0, end: 5)
        let expected = try Self.labels(wb, t)
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: wb), report: &report)
        #expect(report.droppedPivots.isEmpty)
        #expect(try Self.labels(reread, t) == expected)
        #expect(expected.first == "0-1")
    }
}
