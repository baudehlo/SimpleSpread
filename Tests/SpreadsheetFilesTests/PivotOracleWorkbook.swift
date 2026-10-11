import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// A workbook of pivots made in SimpleSpread, for checking against Excel:
/// Excel refreshes it and its output is compared with ours
/// (PivotOracleComparisonTests). Written when SIMPLESPREAD_PIVOT_ORACLE_OUT
/// names a file.
enum PivotOracleWorkbook {
    static let regions = ["East", "West", "North", "South"]
    static let products = ["Apples", "Pears", "Figs", "Dates", "Plums"]
    static let reps = ["Zoë", "adam", "Bea", "Émile", "carl", "Dana"]
    /// Mixed values: text, numbers, booleans, errors, blanks, case variants.
    static let mixed: [CellValue] = [.string("b"), .number(3), .bool(true), .error(.na), .empty, .string("B"),
                                     .string("a"), .number(-1), .bool(false), .string("Ä"), .number(10), .string("z")]

    static func make() throws -> Workbook {
        let wb = Workbook()
        let data = wb.addSheet(named: "Data")
        let headers = ["Region", "Product", "Rep", "Date", "Units", "Price", "Mixed"]
        for (c, h) in headers.enumerated() { data.setCell(Cell(value: .string(h)), at: CellAddress(row: 0, column: c)) }
        let dateStyle = wb.styleIndex(for: CellStyle(numberFormat: NumberFormat(code: "m/d/yyyy")))
        let priceStyle = wb.styleIndex(for: CellStyle(numberFormat: NumberFormat(code: "0.00")))
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let rowCount = 48
        for r in 1...rowCount {
            data.setCell(Cell(value: .string(regions[next(regions.count)])), at: CellAddress(row: r, column: 0))
            data.setCell(Cell(value: .string(products[next(products.count)])), at: CellAddress(row: r, column: 1))
            data.setCell(Cell(value: .string(reps[next(reps.count)])), at: CellAddress(row: r, column: 2))
            let date = ExcelDate.serial(year: 2024 + next(2), month: 1 + next(12), day: 1 + next(28))
            data.setCell(Cell(value: .number(date), styleIndex: dateStyle), at: CellAddress(row: r, column: 3))
            data.setCell(Cell(value: .number(Double(1 + next(20)))), at: CellAddress(row: r, column: 4))
            data.setCell(Cell(value: .number(Double(50 + next(400)) / 100), styleIndex: priceStyle), at: CellAddress(row: r, column: 5))
            data.setCell(Cell(value: mixed[(r - 1) % mixed.count]), at: CellAddress(row: r, column: 6))
        }
        let source = CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: rowCount, column: 6))
        let (region, product, rep, date, units, price, mixedField) = (0, 1, 2, 3, 4, 5, 6)

        func pivot(_ sheetName: String, _ edit: (inout PivotDefinition, PivotCacheData) -> Void) throws {
            let sheet = wb.addSheet(named: sheetName)
            let t = try wb.createPivotTable(sourceSheetID: data.id, source: source, destinationSheetID: sheet.id,
                                            at: CellAddress(a1: "A3")!)
            let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
            edit(&wb.pivotTables[t].definition!, cache)
            wb.applyPivotLayout(at: t, result: try wb.computePivotTable(at: t))
        }
        func position(_ d: PivotDefinition, _ cache: PivotCacheData, field: Int, _ value: PivotValue) -> Int {
            d.fields[field].items.firstIndex { $0.index.map { cache.fields[field].axisItems[$0].matchKey } == value.matchKey }!
        }

        try pivot("Rows") { d, c in d.place(field: region, in: .rows, cache: c); d.place(field: units, in: .values, cache: c) }
        try pivot("Nested") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c)
        }
        try pivot("CrossTab") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .columns, cache: c)
            d.place(field: units, in: .values, cache: c)
        }
        try pivot("TwoValues") { d, c in
            d.place(field: product, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c); d.place(field: price, in: .values, cache: c)
            d.setSubtotal(.average, forDataField: 1, cache: c)
        }
        try pivot("Tabular") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: rep, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c); d.setForm(.tabular)
        }
        try pivot("Outline") { d, c in
            d.place(field: product, in: .rows, cache: c); d.place(field: region, in: .rows, cache: c)
            d.place(field: price, in: .values, cache: c); d.setForm(.outline)
        }
        try pivot("Filtered") { d, c in
            d.place(field: region, in: .filters, cache: c); d.place(field: product, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c)
            d.selectPageItem(field: region, item: position(d, c, field: region, .string("East")))
        }
        try pivot("HiddenSortedCollapsed") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c)
            let north = position(d, c, field: region, .string("North"))
            d.setVisibleItems(field: region, positions: Set(d.fields[region].items.indices).subtracting([north]))
            d.setSort(.descending, field: region, cache: c)
            d.setShowDetails(false, field: region, item: position(d, c, field: region, .string("West")))
        }
        try pivot("AllFunctions") { d, c in
            d.place(field: region, in: .rows, cache: c)
            for (i, fn) in PivotSubtotal.allCases.enumerated() {
                d.place(field: i == 1 ? rep : price, in: .values, cache: c)
                d.setSubtotal(fn, forDataField: i, cache: c)
            }
        }
        try pivot("ShowAs") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .columns, cache: c)
            for (i, mode) in [PivotShowDataAs.percentOfTotal, .percentOfRow, .percentOfCol, .index].enumerated() {
                d.place(field: units, in: .values, cache: c)
                d.setShowDataAs(mode, forDataField: i)
            }
            d.removeFromAxes(pivotValuesFieldIndex)
            d.place(field: pivotValuesFieldIndex, in: .rows, cache: c)
        }
        try pivot("Dates") { d, c in d.place(field: date, in: .rows, cache: c); d.place(field: units, in: .values, cache: c) }
        try pivot("MixedSorted") { d, c in
            d.place(field: mixedField, in: .rows, cache: c); d.place(field: units, in: .values, cache: c)
            d.setSort(.ascending, field: mixedField, cache: c)
        }
        try pivot("Reps") { d, c in
            d.place(field: rep, in: .rows, cache: c); d.place(field: units, in: .values, cache: c)
            d.setSort(.ascending, field: rep, cache: c)
        }
        return wb
    }
}

@Suite("Pivot oracle workbook")
struct PivotOracleWorkbookTests {
    @Test func buildsAndSaves() throws {
        let wb = try PivotOracleWorkbook.make()
        #expect(wb.pivotTables.count == 13)
        let data = try XLSXWriter.data(for: wb)
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: data, report: &report)
        #expect(report.droppedPivots.isEmpty)
        #expect(reread.pivotTables.count == 13)
        if let out = ProcessInfo.processInfo.environment["SIMPLESPREAD_PIVOT_ORACLE_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
    }
}
