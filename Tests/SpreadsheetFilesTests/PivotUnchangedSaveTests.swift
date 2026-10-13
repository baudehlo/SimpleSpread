import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// A pivot nobody touched is written back exactly as read: its table part
/// byte for byte (unless it holds conditional formats, which are removed —
/// see patchedPivotTable), its records part byte for byte, and its cache
/// definition byte for byte unless a fact had to be patched (the records
/// link's id, or a table/name source resolved to a range).
@Suite("Pivot tables: saved unchanged", .serialized)
struct PivotUnchangedSaveTests {
    static func parts(_ data: Data, matching fragment: String) throws -> [String: Data] {
        let zip = try ZipArchiveReader(data: data)
        var out: [String: Data] = [:]
        for entry in zip.entries where entry.name.contains(fragment) && entry.name.hasSuffix(".xml") && !entry.name.contains("_rels") {
            out[entry.name] = try zip.contents(named: entry.name)
        }
        return out
    }

    @Test(arguments: PivotFixtures.all)
    func untouchedPivotPartsAreWrittenBackExactly(_ name: String) throws {
        let (workbook, _) = try PivotFixtures.read(name)
        guard !workbook.pivotTables.isEmpty else { return }
        let written = try XLSXWriter.data(for: workbook)
        let writtenTables = Set(try Self.parts(written, matching: "pivotTables/pivotTable").values)
        for table in workbook.pivotTables {
            // The part exactly as it was in the file.
            let bytes = try #require(table.payload as? PivotTablePayload).definition
            guard !String(decoding: bytes, as: UTF8.self).contains("conditionalFormats") else { continue }
            #expect(writtenTables.contains(bytes), "\(name): \(table.name) was rewritten")
        }
        let writtenRecords = Set(try Self.parts(written, matching: "pivotCache/pivotCacheRecords").values)
        let usedCaches = workbook.pivotCaches.compactMap { $0.payload as? PivotCachePayload }
        for payload in usedCaches {
            if let records = payload.records { #expect(writtenRecords.contains(records), "\(name): records rewritten") }
        }
    }

    @Test func anUntouchedCacheDefinitionIsWrittenBackExactly() throws {
        // The synthetic package's cache needs no patching: same source, same
        // records link id.
        let builder = PivotPackageBuilder()
        let (workbook, _) = try builder.read()
        let original = try Self.parts(builder.build(), matching: "pivotCache/pivotCacheDefinition")
        let written = try Self.parts(XLSXWriter.data(for: workbook), matching: "pivotCache/pivotCacheDefinition")
        #expect(Array(written.values) == Array(original.values))
    }
}
