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
        #expect(PivotFieldGroup.numberItems(start: 1, end: 20, interval: 5, integers: true)!.map(\.cellValue)
                == ["<1", "1-5", "6-10", "11-15", "16-20", ">21"].map { CellValue.string($0) })
    }

    @Test func continuousRangesOverFractions() {
        #expect(PivotFieldGroup.numberItems(start: 0, end: 5, interval: 1, integers: false)!.map(\.cellValue)
                == ["<0", "0-1", "1-2", "2-3", "3-4", "4-5", ">5"].map { CellValue.string($0) })
        #expect(PivotFieldGroup.numberItems(start: 0, end: 4.5, interval: 2, integers: false)?.count == 5)
    }

    @Test func theEndValueLandsInTheLastRange() {
        func label(_ v: Double, _ start: Double, _ end: Double, _ step: Double, integers: Bool) -> PivotValue? {
            let items = PivotFieldGroup.numberItems(start: start, end: end, interval: step, integers: integers)!
            let range = PivotFieldGroup.Range(groupBy: .range, startNumber: start, endNumber: end, interval: step)
            return PivotEngine.bucket(range, itemCount: items.count, value: .number(v)).map { items[$0] }
        }
        // Continuous ranges 0-1 … 4-5: 5 is in "4-5" (">5" means more than 5).
        #expect(label(5, 0, 5, 1, integers: false) == .string("4-5"))
        #expect(label(4, 0, 5, 1, integers: false) == .string("4-5"))
        #expect(label(5.01, 0, 5, 1, integers: false) == .string(">5"))
        #expect(label(-0.01, 0, 5, 1, integers: false) == .string("<0"))
        // Closed ranges over whole numbers, as Excel wrote them.
        #expect(label(20, 1, 20, 5, integers: true) == .string("16-20"))
        #expect(label(21, 1, 20, 5, integers: true) == .string(">21"))
        // Decimal steps: no floating-point slips in buckets or labels.
        #expect(label(0.3, 0, 1, 0.1, integers: false) == .string("0.3-0.4"))
        #expect(label(0.7, 0, 1, 0.1, integers: false) == .string("0.7-0.8"))
    }

    @Test func refreshMakesTheSameRangesGroupingDoes() throws {
        // Price holds fractions: continuous ranges, from the data's minimum.
        let (wb, t) = try Self.table(rows: 5)
        let price = 5
        try wb.groupPivotField(table: t, field: price, interval: 1)
        let cacheID = wb.pivotTables[t].cacheID
        let data = try #require(wb.sheet(named: "Data"))
        // A new maximum two steps up: refresh recomputes the automatic end.
        let column = CellAddress(row: 1, column: price)
        let lo = try #require(wb.pivotCache(withID: cacheID)?.data?.fields[price].group?.range?.startNumber)
        data.setCell(Cell(value: .number(lo + 2.5)), at: column)
        try wb.refreshPivotCache(withID: cacheID)
        let refreshed = try #require(wb.pivotCache(withID: cacheID)?.data?.fields[price].group)
        let range = try #require(refreshed.range)
        let values = try #require(wb.pivotCache(withID: cacheID)?.data?.fields[price].sharedItems)
        #expect(refreshed.items == PivotFieldGroup.numberItems(
            start: range.startNumber!, end: range.endNumber!, interval: 1,
            integers: values.allSatisfy { if case .number(let n) = $0 { return n == n.rounded() }; return false }))
    }

    @Test func anOutlierCantMakeMillionsOfGroups() throws {
        let (wb, t) = try Self.table(rows: 5)
        let units = 4
        #expect(throws: PivotEngineError.self) { try wb.groupPivotField(table: t, field: units, interval: 1e-9) }
        try wb.groupPivotField(table: t, field: units, interval: 1)
        let data = try #require(wb.sheet(named: "Data"))
        data.setCell(Cell(value: .number(1e12)), at: CellAddress(row: 1, column: units))
        let cacheID = wb.pivotTables[t].cacheID
        do {
            try wb.refreshPivotCache(withID: cacheID)
            Issue.record("refresh should refuse")
        } catch let error as PivotEngineError {
            #expect(error.reason.contains("groups"))
        }
        // Nothing changed.
        #expect((wb.pivotCache(withID: cacheID)?.data?.fields[units].group?.items.count ?? 0) < 100)
    }

    @Test func aPivotSortedByValuesIsKeptAsIs() throws {
        let xml = """
        <pivotTableDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" name="P" cacheId="1">\
        <location ref="A3:B6" firstHeaderRow="1" firstDataRow="1" firstDataCol="1"/>\
        <pivotFields count="2"><pivotField axis="axisRow" showAll="0" sortType="descending"><items count="3"><item x="0"/><item x="1"/><item t="default"/></items>\
        <autoSortScope><pivotArea dataOnly="0" outline="0" fieldPosition="0"><references count="1"><reference field="4294967294" count="1" selected="0"><x v="0"/></reference></references></pivotArea></autoSortScope>\
        </pivotField><pivotField dataField="1" showAll="0"/></pivotFields>\
        <rowFields count="1"><field x="0"/></rowFields><dataFields count="1"><dataField name="Sum of Qty" fld="1" baseField="0" baseItem="0"/></dataFields>\
        </pivotTableDefinition>
        """
        let definition = try PivotXMLParser.parseTable(Data(xml.utf8), formats: .init(custom: [:]))
        #expect(definition.fields[0].sortsByValue)
        let cache = PivotCacheData(fields: [PivotCacheField(name: "Name", sharedItems: [.string("a"), .string("b")]),
                                            PivotCacheField(name: "Qty")], records: [[.shared(0), .value(.number(1))]])
        #expect(PivotEngine(cache: cache, definition: definition).unsupportedReason == "it sorts items by their values")
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
