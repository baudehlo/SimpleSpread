import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Writing pivots from the typed model (what refresh, edit and create do):
/// regenerate every computable fixture pivot and check nothing is lost.
@Suite("Pivot tables: generated parts", .serialized)
struct PivotGenerationTests {
    /// Recompute and regenerate every computable pivot in a fixture.
    static func regenerate(_ name: String) throws -> (original: Workbook, regenerated: Workbook, indices: [Int]) {
        let (original, _) = try PivotFixtures.read(name)
        let (workbook, _) = try PivotFixtures.read(name)
        let captions = PivotEngineFixtureTests.captionsByFile[name] ?? .english
        var computed: [Int] = []
        for i in workbook.pivotTables.indices {
            guard let result = try? workbook.computePivotTable(at: i, captions: captions) else { continue }
            workbook.applyPivotLayout(at: i, result: result)
            computed.append(i)
        }
        for c in workbook.pivotCaches.indices
        where workbook.pivotTables.enumerated().contains(where: { computed.contains($0.offset) && $0.element.cacheID == workbook.pivotCaches[c].cacheID }) {
            workbook.pivotCaches[c].isModified = true
        }
        return (original, workbook, computed)
    }

    static func resolvedRecords(_ data: PivotCacheData) -> [[PivotValue]] {
        let columns = data.recordColumns
        return data.records.indices.map { r in
            columns.enumerated().compactMap { f, column in column.map { data.value(record: r, column: $0, field: f) } }
        }
    }

    @Test(arguments: PivotFixtures.all.filter { !PivotEngineFixtureTests.excludedFiles.contains($0) })
    func regeneratedPivotsSurviveARoundTrip(_ name: String) throws {
        let (original, workbook, computed) = try Self.regenerate(name)
        guard !computed.isEmpty else { return }
        let data = try XLSXWriter.data(for: workbook)
        try PivotPackageChecker(original: Package(PivotFixtures.data(name)), written: Package(data), workbook: workbook)
            .checkPackageIntegrity()
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: data, report: &report)
        #expect(report.droppedPivots.isEmpty, "\(name): \(report.droppedPivots)")
        #expect(reread.pivotTables.count == original.pivotTables.count)

        for i in computed {
            let before = original.pivotTables[i]
            let sheetName = original.sheet(withID: before.sheetID)!.name
            guard let after = reread.pivotTables.first(where: {
                reread.sheet(withID: $0.sheetID)?.name == sheetName && $0.name == before.name
            }) else { Issue.record("\(name): \(before.name) missing after save"); continue }
            let tag = "\(name) \(sheetName)!\(before.name)"
            #expect(after.location == before.location, "\(tag) location")
            #expect(after.pageFieldRows == before.pageFieldRows, "\(tag) page rows")

            // Definition: everything the model holds comes back.
            let d0 = try #require(before.definition), d1 = try #require(after.definition)
            #expect(d1.rowFields == d0.rowFields, "\(tag) rowFields")
            #expect(d1.columnFields == d0.columnFields, "\(tag) colFields")
            #expect(d1.pageFields == d0.pageFields, "\(tag) pageFields")
            #expect(d1.dataFields == d0.dataFields, "\(tag) dataFields")
            #expect(d1.rowLines == d0.rowLines || d1.rowLines.map { var l = $0; l.dataFieldIndex = l.kind == .grand ? 0 : l.dataFieldIndex; return l } == d0.rowLines.map { var l = $0; l.dataFieldIndex = l.kind == .grand ? 0 : l.dataFieldIndex; return l }, "\(tag) rowItems")
            #expect(d1.layout == d0.layout || { var l = d0.layout; l.hideValuesRow = d1.layout.hideValuesRow; return l == d1.layout }(), "\(tag) layout")
            #expect(d1.fields.count == d0.fields.count)
            for (f, (a, b)) in zip(d0.fields, d1.fields).enumerated() {
                #expect(a == b, "\(tag) pivotField \(f)")
            }
            #expect(d1.filters.count == d0.filters.count, "\(tag) filters")

            // Cache: field definitions and every record value.
            let c0 = try #require(original.pivotCache(withID: before.cacheID)?.data)
            let c1 = try #require(reread.pivotCache(withID: after.cacheID)?.data)
            #expect(c1.fields.map(\.name) == c0.fields.map(\.name), "\(tag) cache fields")
            #expect(c1.fields.map(\.formula) == c0.fields.map(\.formula), "\(tag) formulas")
            #expect(c1.fields.map(\.group) == c0.fields.map(\.group), "\(tag) groups")
            #expect(c1.fields.map(\.numberFormat.code) == c0.fields.map(\.numberFormat.code), "\(tag) formats")
            #expect(Self.resolvedRecords(c1) == Self.resolvedRecords(c0), "\(tag) records")
            for f in c0.fields.indices where !c1.fields[f].sharedItems.isEmpty {
                #expect(c1.fields[f].sharedItems == c0.fields[f].sharedItems, "\(tag) shared items \(f)")
            }

            // Cells the pivot draws: unchanged from what Excel wrote.
            let s0 = original.sheet(withID: before.sheetID)!, s1 = reread.sheet(withID: after.sheetID)!
            before.occupiedRange.forEachAddress { addr in
                #expect(PivotEngineFixtureTests.sameValue(s0.value(at: addr), s1.value(at: addr)), "\(tag) \(addr.a1)")
            }

            // And recomputing after the save gives the same layout again.
            let index = reread.pivotTables.firstIndex { $0.sheetID == after.sheetID && $0.name == after.name }!
            let again = try reread.computePivotTable(at: index, captions: PivotEngineFixtureTests.captionsByFile[name] ?? .english)
            #expect(again.rowLines.count == d0.rowLines.count && again.columnLines.count == d0.columnLines.count, "\(tag) recompute")
        }
    }

    @Test func generatedFilesAreIdempotent() throws {
        let (_, workbook, computed) = try Self.regenerate("calamine-pivots.xlsx")
        #expect(!computed.isEmpty)
        let once = try XLSXWriter.data(for: workbook)
        let reread = try XLSXReader.read(data: once)
        let twice = try XLSXWriter.data(for: reread)
        let a = try Package(once), b = try Package(twice)
        #expect(a.partNames == b.partNames)
        for part in a.partNames where !part.contains("pivotCacheDefinition") {
            #expect(try a.part(part) == b.part(part), "\(part) changed on the second save")
        }
    }
}
