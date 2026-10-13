import Foundation
import Testing
@testable import SpreadsheetCore

/// Item order and everything that names an item by its position: Show
/// Values As base items, report filter selections, sorting of grouped
/// fields, and filters that outlive their field.
@Suite("Pivot tables: item positions and order")
struct PivotItemOrderTests {
    /// Region | Units | Date in A1:C`n`, a pivot over it on its own sheet.
    static func workbook(_ rows: [(String, Double, Double?)]) throws -> (Workbook, data: Sheet, table: Int) {
        let wb = Workbook()
        let data = wb.addSheet(named: "Data")
        let dateStyle = wb.styleIndex(for: CellStyle(numberFormat: NumberFormat(code: "m/d/yyyy")))
        for (c, h) in ["Region", "Units", "Date"].enumerated() { data.setCell(Cell(value: .string(h)), at: CellAddress(row: 0, column: c)) }
        for (r, row) in rows.enumerated() {
            data.setCell(Cell(value: .string(row.0)), at: CellAddress(row: r + 1, column: 0))
            data.setCell(Cell(value: .number(row.1)), at: CellAddress(row: r + 1, column: 1))
            if let d = row.2 { data.setCell(Cell(value: .number(d), styleIndex: dateStyle), at: CellAddress(row: r + 1, column: 2)) }
        }
        let report = wb.addSheet(named: "Report")
        let t = try wb.createPivotTable(sourceSheetID: data.id, source: CellRange(a1: "A1:C\(rows.count + 1)")!,
                                        destinationSheetID: report.id, at: CellAddress(a1: "A3")!)
        return (wb, data, t)
    }

    static let sales: [(String, Double, Double?)] = [("East", 10, 45300), ("West", 5, 45400), ("East", 7, 45500), ("North", 2, 45600)]

    static func edit(_ wb: Workbook, _ t: Int, _ change: (inout PivotDefinition, PivotCacheData) -> Void) throws -> PivotLayoutResult {
        let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
        change(&wb.pivotTables[t].definition!, cache)
        let result = try wb.computePivotTable(at: t)
        wb.applyPivotLayout(at: t, result: result)
        return result
    }

    /// Row label -> value, top to bottom.
    static func rows(_ result: PivotLayoutResult) -> [(String, CellValue?)] {
        (result.firstDataRow..<result.rowCount).map { r in
            let label = result.cells[PivotOffset(row: r, column: 0)]?.value
            let text: String
            switch label {
            case .string(let s)?: text = s
            case .number(let n)?: text = String(n)
            default: text = ""
            }
            return (text, result.cells[PivotOffset(row: r, column: result.firstDataCol)]?.value)
        }
    }

    func position(_ wb: Workbook, _ t: Int, field: Int, _ label: String) -> Int {
        let d = wb.pivotTables[t].definition!, c = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
        return d.fields[field].items.firstIndex { $0.index.map { c.fields[field].axisItems[$0] } == .string(label) }!
    }

    // MARK: (a) positions follow sorting and refreshing

    @Test func percentOfAnItemSurvivesSorting() throws {
        let (wb, _, t) = try Self.workbook(Self.sales)
        _ = try Self.edit(wb, t) { d, c in d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c) }
        let east = position(wb, t, field: 0, "East")
        let before = try Self.edit(wb, t) { d, _ in d.setShowDataAs(.percent, forDataField: 0, baseField: 0, baseItem: east) }
        #expect(Self.rows(before).map(\.0) == ["East", "North", "West", "Grand Total"])
        #expect(Self.rows(before)[1].1 == .number(2.0 / 17))
        let after = try Self.edit(wb, t) { d, c in d.setSort(.descending, field: 0, cache: c) }
        #expect(Self.rows(after).map(\.0) == ["West", "North", "East", "Grand Total"])
        // Still "% of East": West is 5/17, East itself 100%.
        #expect(Self.rows(after)[0].1 == .number(5.0 / 17))
        #expect(Self.rows(after)[2].1 == .number(1))
        #expect(wb.pivotTables[t].definition!.dataFields[0].baseItem == position(wb, t, field: 0, "East"))
    }

    @Test func percentOfAnItemSurvivesARefreshThatMovesIt() throws {
        let (wb, data, t) = try Self.workbook(Self.sales)
        _ = try Self.edit(wb, t) { d, c in d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c) }
        let west = position(wb, t, field: 0, "West")
        _ = try Self.edit(wb, t) { d, _ in d.setShowDataAs(.percent, forDataField: 0, baseField: 0, baseItem: west) }
        // North disappears from the source: West moves up a place.
        data.setCell(Cell(value: .string("East")), at: CellAddress(a1: "A5")!)
        try wb.refreshPivotCache(withID: wb.pivotTables[t].cacheID)
        let result = try wb.computePivotTable(at: t)
        #expect(Self.rows(result).map(\.0) == ["East", "West", "Grand Total"])
        #expect(Self.rows(result)[0].1 == .number(19.0 / 5)) // % of West
        #expect(Self.rows(result)[1].1 == .number(1))
    }

    @Test func aReportFilterSelectionSurvivesSorting() throws {
        let (wb, _, t) = try Self.workbook(Self.sales)
        _ = try Self.edit(wb, t) { d, c in d.place(field: 0, in: .filters, cache: c); d.place(field: 1, in: .values, cache: c) }
        let west = position(wb, t, field: 0, "West")
        _ = try Self.edit(wb, t) { d, _ in d.selectPageItem(field: 0, item: west) }
        let result = try Self.edit(wb, t) { d, c in d.setSort(.descending, field: 0, cache: c) }
        #expect(result.cells[PivotOffset(row: -2, column: 1)]?.value == .string("West"))
        #expect(result.cells[PivotOffset(row: 1, column: 0)]?.value == .number(5))
    }

    // MARK: (b) grouped fields sort in their groups' order

    @Test func monthsSortAsMonths() throws {
        // Dates in Jan, Apr, Aug, Dec 2024.
        let (wb, _, t) = try Self.workbook([("A", 1, 45306), ("B", 2, 45392), ("C", 3, 45520), ("D", 4, 45640)])
        _ = try Self.edit(wb, t) { d, c in d.place(field: 2, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c) }
        try wb.groupPivotField(table: t, field: 2, byDates: [.months])
        let ascending = try Self.edit(wb, t) { d, c in d.setSort(.ascending, field: 2, cache: c) }
        #expect(Self.rows(ascending).map(\.0) == ["Jan", "Apr", "Aug", "Dec", "Grand Total"])
        let descending = try Self.edit(wb, t) { d, c in d.setSort(.descending, field: 2, cache: c) }
        #expect(Self.rows(descending).map(\.0) == ["Dec", "Aug", "Apr", "Jan", "Grand Total"])
        // Refresh keeps the order.
        try wb.refreshPivotCache(withID: wb.pivotTables[t].cacheID)
        #expect(Self.rows(try wb.computePivotTable(at: t)).map(\.0) == ["Dec", "Aug", "Apr", "Jan", "Grand Total"])
    }

    @Test func rangesSortByValue() throws {
        let (wb, _, t) = try Self.workbook([("A", 5, nil), ("B", 25, nil), ("C", 105, nil), ("D", 15, nil)])
        _ = try Self.edit(wb, t) { d, c in d.place(field: 1, in: .rows, cache: c); d.place(field: 0, in: .values, cache: c) }
        try wb.groupPivotField(table: t, field: 1, interval: 10, start: 0, end: 110)
        let ascending = try Self.edit(wb, t) { d, c in d.setSort(.ascending, field: 1, cache: c) }
        #expect(Self.rows(ascending).map(\.0) == ["0-9", "10-19", "20-29", "100-109", "Grand Total"])
        let descending = try Self.edit(wb, t) { d, c in d.setSort(.descending, field: 1, cache: c) }
        #expect(Self.rows(descending).map(\.0) == ["100-109", "20-29", "10-19", "0-9", "Grand Total"])
    }

    // MARK: (c) blanks and grouping

    @Test func aFieldWithBlanksCantBeGrouped() throws {
        let (wb, data, t) = try Self.workbook(Self.sales)
        data.setCell(Cell(), at: CellAddress(a1: "C3")!)
        data.setCell(Cell(), at: CellAddress(a1: "B3")!)
        // Rebuild the cache with the blanks in it.
        try wb.refreshPivotCache(withID: wb.pivotTables[t].cacheID)
        #expect(throws: PivotEngineError.self) { try wb.groupPivotField(table: t, field: 1, interval: 10) }
        #expect(throws: PivotEngineError.self) { try wb.groupPivotField(table: t, field: 2, byDates: [.months]) }
        do {
            try wb.groupPivotField(table: t, field: 1, interval: 10)
        } catch let error as PivotEngineError {
            #expect(error.reason.contains("blank"))
        }
    }

    @Test func aRefreshThatBringsBlanksIntoAGroupedFieldIsRefused() throws {
        let (wb, data, t) = try Self.workbook(Self.sales)
        _ = try Self.edit(wb, t) { d, c in d.place(field: 1, in: .rows, cache: c); d.place(field: 0, in: .values, cache: c) }
        try wb.groupPivotField(table: t, field: 1, interval: 5)
        data.setCell(Cell(), at: CellAddress(a1: "B3")!)
        #expect(throws: PivotEngineError.self) { try wb.refreshPivotCache(withID: wb.pivotTables[t].cacheID) }
        // A cache that holds them anyway (from a file) isn't computed.
        let c = wb.pivotCaches.firstIndex { $0.cacheID == wb.pivotTables[t].cacheID }!
        wb.pivotCaches[c].data?.fields[1].sharedItems.append(.missing)
        #expect(throws: PivotEngineError.self) { try wb.computePivotTable(at: t) }
    }

    // MARK: (d) filters follow their field

    @Test func removingAFieldDropsItsFilters() throws {
        let (wb, _, t) = try Self.workbook(Self.sales)
        _ = try Self.edit(wb, t) { d, c in
            d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c)
            d.filters = [PivotFilter(field: 0, type: "count", top10Value: 1)]
        }
        #expect(Self.rows(try wb.computePivotTable(at: t)).map(\.0) == ["East", "Grand Total"])
        // Moving it between rows and columns keeps the filter…
        _ = try Self.edit(wb, t) { d, c in d.place(field: 0, in: .columns, cache: c) }
        #expect(wb.pivotTables[t].definition!.filters.count == 1)
        // …removing it drops the filter, which would otherwise keep cutting
        // the totals with nothing on screen.
        let result = try Self.edit(wb, t) { d, _ in d.removeFromAxes(0) }
        #expect(wb.pivotTables[t].definition!.filters.isEmpty)
        #expect(result.cells[PivotOffset(row: 1, column: 0)]?.value == .number(24))
    }

    @Test func topTenFiltersFollowTheirValueField() throws {
        let (wb, _, t) = try Self.workbook(Self.sales)
        _ = try Self.edit(wb, t) { d, c in
            d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c); d.place(field: 2, in: .values, cache: c)
            d.filters = [PivotFilter(field: 0, type: "count", measureField: 1, top10Value: 1)]
        }
        _ = try Self.edit(wb, t) { d, _ in d.moveDataField(from: 1, to: 0) }
        #expect(wb.pivotTables[t].definition!.filters.first?.measureField == 0)
        _ = try Self.edit(wb, t) { d, _ in d.removeDataField(at: 1) }
        #expect(wb.pivotTables[t].definition!.filters.first?.measureField == 0)
        _ = try Self.edit(wb, t) { d, _ in d.removeDataField(at: 0) }
        #expect(wb.pivotTables[t].definition!.filters.isEmpty)
    }
}
