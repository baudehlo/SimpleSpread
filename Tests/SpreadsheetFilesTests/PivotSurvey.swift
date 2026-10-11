import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Writes every pivot fixture's round trip to SIMPLESPREAD_PIVOT_OUT (for
/// external validation) and prints what was kept or dropped. No-op otherwise.
@Suite("Pivot survey")
struct PivotSurvey {
    @Test func survey() throws {
        guard let out = ProcessInfo.processInfo.environment["SIMPLESPREAD_PIVOT_OUT"] else { return }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for name in PivotFixtures.all {
            let (workbook, report) = try PivotFixtures.read(name)
            print("== \(name): \(workbook.pivotTables.count) tables, \(workbook.pivotCaches.count) caches kept")
            for table in workbook.pivotTables {
                let sheet = workbook.sheet(withID: table.sheetID)?.name ?? "?"
                print("   keep \(sheet)!\(table.name) cache=\(table.cacheID) at \(table.location.a1) occupied=\(table.occupiedRange.a1)")
            }
            for cache in workbook.pivotCaches {
                print("   cache \(cache.cacheID): \(cache.sourceRanges)")
            }
            for drop in report.droppedPivots {
                print("   DROP \(drop.sheetName ?? "?")!\(drop.tableName ?? "?") cache=\(drop.cacheID.map(String.init) ?? "-"): \(drop.reason)")
            }
            let data = try XLSXWriter.data(for: workbook)
            try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
            if let editOut = ProcessInfo.processInfo.environment["SIMPLESPREAD_PIVOT_EDIT_OUT"] {
                try FileManager.default.createDirectory(atPath: editOut, withIntermediateDirectories: true)
                _ = PivotFixtureEdits.apply(to: workbook)
                try XLSXWriter.data(for: workbook)
                    .write(to: URL(fileURLWithPath: editOut).appendingPathComponent(name))
            }
        }
    }
}
