import Foundation
import Testing
@testable import SpreadsheetCore

/// Timing guards for the pivot engine: computing a pivot must take one pass
/// over the records, not one per output cell. (The cell-by-cell engine took
/// about two minutes in a debug build for the 100k-record case below.)
@Suite("Pivot engine: timing", .serialized)
struct PivotEnginePerformanceTests {
    /// `count` records of Product (500 items) | Region (6 items) | Units.
    static func cache(records count: Int) -> PivotCacheData {
        let products = (0..<500).map { PivotValue.string("Product \($0)") }
        let regions = ["North", "South", "East", "West", "Central", "Overseas"].map(PivotValue.string)
        var records: [[PivotRecordValue]] = []
        records.reserveCapacity(count)
        for r in 0..<count {
            records.append([.shared((r * 7919) % 500), .shared((r * 31) % 6), .value(.number(Double(r % 97)))])
        }
        return PivotCacheData(fields: [
            PivotCacheField(name: "Product", sharedItems: products),
            PivotCacheField(name: "Region", sharedItems: regions),
            PivotCacheField(name: "Units"),
        ], records: records)
    }

    static func definition(_ cache: PivotCacheData, showAs: PivotShowDataAs = .normal) -> PivotDefinition {
        var d = PivotDefinition.new(name: "P", cache: cache)
        d.place(field: 0, in: .rows, cache: cache)
        d.place(field: 1, in: .columns, cache: cache)
        d.place(field: 2, in: .values, cache: cache)
        d.dataFields[0].showDataAs = showAs
        return d
    }

    static func time(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    @Test func hundredThousandRecordsIntoFiveHundredBySix() throws {
        let cache = Self.cache(records: 100_000)
        var result: PivotLayoutResult?
        let seconds = try Self.time {
            result = try PivotEngine(cache: cache, definition: Self.definition(cache)).compute()
        }
        print("pivot compute, 100k records, 500 x 6: \(seconds) s")
        #expect(result?.rowLines.count == 501)    // 500 items + grand total
        #expect(result?.columnLines.count == 7)   // 6 items + grand total
        #expect(seconds < 10, "took \(seconds) s")
    }

    @Test func percentOfRowStaysOnePass() throws {
        let cache = Self.cache(records: 100_000)
        var result: PivotLayoutResult?
        let seconds = try Self.time {
            result = try PivotEngine(cache: cache, definition: Self.definition(cache, showAs: .percentOfRow)).compute()
        }
        print("pivot compute, 100k records, 500 x 6, % of row: \(seconds) s")
        // Every row's grand total is 100%.
        let grandColumn = try #require(result).firstDataCol + 6
        #expect(result?.cells[PivotOffset(row: 2, column: grandColumn)]?.value == .number(1))
        #expect(seconds < 10, "took \(seconds) s")
    }
}
