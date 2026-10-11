import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// SimpleSpread's pivots against Excel's own computation of the same pivots
/// (see Fixtures/ExcelOracle/README.md).
@Suite("Pivot tables: Excel oracle", .serialized)
struct PivotOracleComparisonTests {
    static func excel(_ name: String) throws -> Workbook {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/ExcelOracle/\(name)")
        return try XLSXReader.read(data: Data(contentsOf: url))
    }

    @Test func everyCreatedPivotMatchesExcel() throws {
        try Self.compare(ours: PivotOracleWorkbook.make(), excel: Self.excel("created-pivots-refreshed-by-excel.xlsx"))
    }

    @Test func roundTwoMatchesExcel() throws {
        try Self.compare(ours: PivotOracleRound2.make(), excel: Self.excel("round2-refreshed-by-excel.xlsx"))
    }

    @Test func groupingMatchesExcel() throws {
        try Self.compare(ours: PivotOracleRound3.make(), excel: Self.excel("round3-refreshed-by-excel.xlsx"))
    }

    static func compare(ours: Workbook, excel: Workbook) throws {
        #expect(excel.pivotTables.count == ours.pivotTables.count)
        for t in ours.pivotTables {
            let sheetName = ours.sheet(withID: t.sheetID)!.name
            guard let e = excel.pivotTables.first(where: { excel.sheet(withID: $0.sheetID)?.name == sheetName }) else {
                Issue.record("\(sheetName) missing from Excel's file"); continue
            }
            #expect(e.location == t.location, "\(sheetName) location")
            let so = ours.sheet(withID: t.sheetID)!, se = excel.sheet(withID: e.sheetID)!
            t.occupiedRange.union(e.occupiedRange).forEachAddress { a in
                #expect(PivotEngineFixtureTests.sameValue(se.value(at: a), so.value(at: a)),
                        "\(sheetName)!\(a.a1): ours \(so.value(at: a)), Excel \(se.value(at: a))")
                let fo = ours.style(at: so.cell(at: a).styleIndex), fe = excel.style(at: se.cell(at: a).styleIndex)
                #expect(fo.indent == fe.indent, "\(sheetName)!\(a.a1) indent")
                #expect(fo.pivotButton == fe.pivotButton, "\(sheetName)!\(a.a1) button")
            }
            let dt = try #require(t.definition), de = try #require(e.definition)
            #expect(dt.rowLines == de.rowLines, "\(sheetName) rowItems")
            #expect(dt.columnLines == de.columnLines, "\(sheetName) colItems")
            for (f, (a, b)) in zip(dt.fields, de.fields).enumerated() {
                #expect(a.items.map(\.index) == b.items.map(\.index), "\(sheetName) field \(f) item order")
            }
        }
    }
}
