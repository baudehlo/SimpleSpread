import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Round two of the Excel oracle: column-only and value-only pivots, show
/// values as difference/percent/running total, custom subtotals, blank
/// rows, items with no data, wrapped filters, Values on rows, and summaries
/// over errors and blanks. Written when SIMPLESPREAD_PIVOT_ORACLE2_OUT names
/// a file.
enum PivotOracleRound2 {
    static func make() throws -> Workbook {
        let wb = try PivotOracleWorkbook.make()
        // Drop round one's pivot sheets; keep the data.
        let data = wb.sheet(named: "Data")!
        for sheet in wb.sheets where sheet.id != data.id {
            WorkbookOperations.deleteSheet(in: wb, sheetID: sheet.id)
        }
        // Data2: numbers with errors and blanks.
        let data2 = wb.addSheet(named: "Data2")
        for (c, h) in ["Group", "Value"].enumerated() { data2.setCell(Cell(value: .string(h)), at: CellAddress(row: 0, column: c)) }
        let values: [CellValue] = [.number(1), .number(2), .error(.div0), .empty, .number(5), .string("x"), .number(7), .empty]
        for (r, v) in values.enumerated() {
            data2.setCell(Cell(value: .string(r % 2 == 0 ? "A" : (r < 6 ? "B" : "C"))), at: CellAddress(row: r + 1, column: 0))
            data2.setCell(Cell(value: v), at: CellAddress(row: r + 1, column: 1))
        }
        let source = CellRange(start: CellAddress(row: 0, column: 0), end: data.usedRange!.end)
        let (region, product, rep, _, units, price, _) = (0, 1, 2, 3, 4, 5, 6)

        func pivot(_ name: String, on dataSheet: Sheet? = nil, range: CellRange? = nil,
                   _ edit: (inout PivotDefinition, PivotCacheData) -> Void) throws {
            let sheet = wb.addSheet(named: name)
            let t = try wb.createPivotTable(sourceSheetID: (dataSheet ?? data).id, source: range ?? source,
                                            destinationSheetID: sheet.id, at: CellAddress(a1: "A3")!)
            let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
            edit(&wb.pivotTables[t].definition!, cache)
            wb.applyPivotLayout(at: t, result: try wb.computePivotTable(at: t))
        }
        func position(_ d: PivotDefinition, _ c: PivotCacheData, _ field: Int, _ value: String) -> Int {
            d.fields[field].items.firstIndex { $0.index.map { c.fields[field].axisItems[$0].matchKey } == PivotValue.string(value).matchKey }!
        }

        try pivot("ColumnsOnly") { d, c in d.place(field: product, in: .columns, cache: c); d.place(field: units, in: .values, cache: c) }
        try pivot("ValuesOnly") { d, c in d.place(field: units, in: .values, cache: c); d.place(field: price, in: .values, cache: c) }
        try pivot("ValuesOnlySingle") { d, c in d.place(field: units, in: .values, cache: c) }
        for (name, mode) in [("Difference", PivotShowDataAs.difference), ("Percent", .percent), ("PercentDiff", .percentDiff)] {
            try pivot(name) { d, c in
                d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .columns, cache: c)
                d.place(field: units, in: .values, cache: c)
                d.dataFields[0].showDataAs = mode
                d.dataFields[0].baseField = product
                d.dataFields[0].baseItem = position(d, c, product, "Figs")
            }
        }
        try pivot("DifferencePrevious") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: units, in: .values, cache: c)
            d.dataFields[0].showDataAs = .difference
            d.dataFields[0].baseField = region
            d.dataFields[0].baseItem = 1048828
        }
        try pivot("RunTotal") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c)
            d.dataFields[0].showDataAs = .runTotal
            d.dataFields[0].baseField = product
        }
        try pivot("CustomSubtotals") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c)
            d.fields[region].subtotals = [.sum, .countA, .avg]
            d.fields[region].items = d.fields[region].items.filter { $0.kind == .data } + [.sum, .countA, .avg].map { PivotItem(kind: $0) }
        }
        try pivot("BlankRows") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: product, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c)
            d.fields[region].insertBlankRow = true
        }
        try pivot("ShowAll") { d, c in
            d.place(field: region, in: .rows, cache: c); d.place(field: rep, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c)
            d.fields[rep].showAll = true
        }
        try pivot("PageWrap") { d, c in
            d.place(field: region, in: .filters, cache: c); d.place(field: product, in: .filters, cache: c)
            d.place(field: rep, in: .filters, cache: c)
            d.place(field: units, in: .values, cache: c)
            d.layout.pageWrap = 2
        }
        try pivot("ValuesOnRows") { d, c in
            d.place(field: region, in: .rows, cache: c)
            d.place(field: units, in: .values, cache: c); d.place(field: price, in: .values, cache: c)
            d.removeFromAxes(pivotValuesFieldIndex)
            d.place(field: pivotValuesFieldIndex, in: .rows, cache: c)
        }
        let range2 = CellRange(a1: "A1:B9")!
        for fn in [PivotSubtotal.sum, .count, .countNums, .average, .max, .min] {
            try pivot("Errors\(fn.caption)\(fn == .countNums ? "Nums" : "")", on: data2, range: range2) { d, c in
                d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c)
                d.setSubtotal(fn, forDataField: 0, cache: c)
            }
        }
        return wb
    }
}

@Suite("Pivot oracle round 2 workbook")
struct PivotOracleRound2Tests {
    @Test func buildsAndSaves() throws {
        let wb = try PivotOracleRound2.make()
        let data = try XLSXWriter.data(for: wb)
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: data, report: &report)
        #expect(report.droppedPivots.isEmpty)
        #expect(reread.pivotTables.count == wb.pivotTables.count)
        if let out = ProcessInfo.processInfo.environment["SIMPLESPREAD_PIVOT_ORACLE2_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
    }
}

/// Round three: grouping made in SimpleSpread (dates by years/quarters/
/// months and days; numbers into ranges). Written when
/// SIMPLESPREAD_PIVOT_ORACLE3_OUT names a file.
enum PivotOracleRound3 {
    static func make() throws -> Workbook {
        let wb = try PivotOracleWorkbook.make()
        let data = wb.sheet(named: "Data")!
        for sheet in wb.sheets where sheet.id != data.id { WorkbookOperations.deleteSheet(in: wb, sheetID: sheet.id) }
        let source = CellRange(start: CellAddress(row: 0, column: 0), end: data.usedRange!.end)
        let (region, date, units, price) = (0, 3, 4, 5)
        func pivot(_ name: String, _ build: (Workbook, Int) throws -> Void) throws {
            let sheet = wb.addSheet(named: name)
            let t = try wb.createPivotTable(sourceSheetID: data.id, source: source, destinationSheetID: sheet.id,
                                            at: CellAddress(a1: "A3")!)
            try build(wb, t)
            wb.applyPivotLayout(at: t, result: try wb.computePivotTable(at: t))
        }
        func edit(_ wb: Workbook, _ t: Int, _ change: (inout PivotDefinition, PivotCacheData) -> Void) {
            let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
            change(&wb.pivotTables[t].definition!, cache)
        }
        try pivot("YearsQuartersMonths") { wb, t in
            edit(wb, t) { d, c in d.place(field: date, in: .rows, cache: c); d.place(field: units, in: .values, cache: c) }
            try wb.groupPivotField(table: t, field: date, byDates: [.years, .quarters, .months])
        }
        try pivot("Months") { wb, t in
            edit(wb, t) { d, c in d.place(field: date, in: .rows, cache: c); d.place(field: units, in: .values, cache: c) }
            try wb.groupPivotField(table: t, field: date, byDates: [.months])
        }
        try pivot("YearsInColumns") { wb, t in
            edit(wb, t) { d, c in
                d.place(field: region, in: .rows, cache: c); d.place(field: date, in: .columns, cache: c)
                d.place(field: units, in: .values, cache: c)
            }
            try wb.groupPivotField(table: t, field: date, byDates: [.years])
        }
        try pivot("Days") { wb, t in
            edit(wb, t) { d, c in d.place(field: date, in: .rows, cache: c); d.place(field: units, in: .values, cache: c) }
            try wb.groupPivotField(table: t, field: date, byDates: [.days])
        }
        try pivot("UnitRanges") { wb, t in
            edit(wb, t) { d, c in d.place(field: units, in: .rows, cache: c); d.place(field: price, in: .values, cache: c) }
            try wb.groupPivotField(table: t, field: units, interval: 5)
        }
        try pivot("PriceRanges") { wb, t in
            edit(wb, t) { d, c in d.place(field: price, in: .rows, cache: c); d.place(field: units, in: .values, cache: c) }
            try wb.groupPivotField(table: t, field: price, interval: 1, start: 0, end: 5)
        }
        return wb
    }
}

@Suite("Pivot oracle round 3 workbook")
struct PivotOracleRound3Tests {
    @Test func buildsAndSaves() throws {
        let wb = try PivotOracleRound3.make()
        let data = try XLSXWriter.data(for: wb)
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: data, report: &report)
        #expect(report.droppedPivots.isEmpty)
        #expect(reread.pivotTables.count == wb.pivotTables.count)
        for t in reread.pivotTables.indices { _ = try reread.computePivotTable(at: t) }
        if let out = ProcessInfo.processInfo.environment["SIMPLESPREAD_PIVOT_ORACLE3_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
    }
}
