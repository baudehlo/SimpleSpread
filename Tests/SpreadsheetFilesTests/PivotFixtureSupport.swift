import Foundation
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Access to the vendored pivot fixtures (see Fixtures/Pivots/README.md).
enum PivotFixtures {
    static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Pivots")
    }

    static var all: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".xlsx") }.sorted()
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func read(_ name: String) throws -> (Workbook, XLSXReadReport) {
        var report = XLSXReadReport()
        let workbook = try XLSXReader.read(data: data(name), report: &report)
        return (workbook, report)
    }
}

/// A written package opened for inspection.
struct Package {
    let zip: ZipArchiveReader

    init(_ data: Data) throws {
        zip = try ZipArchiveReader(data: data)
    }

    var partNames: [String] { zip.entries.map(\.name) }

    func part(_ name: String) throws -> Data { try zip.contents(named: name) }

    func string(_ name: String) throws -> String { String(decoding: try part(name), as: UTF8.self) }

    func has(_ name: String) -> Bool { zip.entry(named: name) != nil }

    func relationships(of partPath: String) throws -> [XLSXReader.Relationship] {
        try XLSXReader.relationships(of: partPath, in: zip)
    }

    /// Attributes of every element at `path` (local names) in a part.
    func elements(_ path: [String], in partName: String) throws -> [[String: String]] {
        var found: [[String: String]] = []
        try XMLRewriter.scan(part(partName)) { element in
            if element.path == path { found.append(element.attributes) }
            return .keep
        }
        return found
    }
}

/// The edits the "after edits" fixture tests apply, with what they expect.
enum PivotFixtureEdits {
    struct Expectation {
        /// Per table (sheet name after edits + table name): the new location.
        var locations: [String: String] = [:]
        /// Per cache id: the new source refs.
        var sources: [Int: [String]] = [:]
        /// Cell values that should now sit at each table's new location.
        var cells: [String: [CellAddress: CellValue]] = [:]
    }

    /// Rename every live source sheet, insert two rows and a column above
    /// and left of every pivot table's sheet, and a row inside every source.
    static func apply(to workbook: Workbook) -> Expectation {
        var expectation = Expectation()
        let sourceSheets = Set(workbook.pivotCaches.flatMap(\.sourceRanges).compactMap { range -> Int? in
            if case .sheet(let id) = range.target { return id } else { return nil }
        })
        let hostSheets = Set(workbook.pivotTables.map(\.sheetID))

        // Snapshot each table's cells before anything moves.
        var before: [(sheetID: Int, name: String, cells: [(CellAddress, CellValue)])] = []
        for table in workbook.pivotTables {
            let sheet = workbook.sheet(withID: table.sheetID)!
            var cells: [(CellAddress, CellValue)] = []
            table.location.forEachAddress { cells.append(($0, sheet.value(at: $0))) }
            before.append((table.sheetID, table.name, cells))
        }

        for id in sourceSheets.sorted() {
            let name = workbook.sheet(withID: id)!.name
            WorkbookOperations.renameSheet(in: workbook, sheetID: id, to: String(("X " + name).prefix(31)))
        }
        // Row/column shifts on hosts that aren't also sources (keeps the
        // expected source refs simple).
        var shifted: Set<Int> = []
        for id in hostSheets.sorted() where !sourceSheets.contains(id) {
            if WorkbookOperations.pivotTableSplit(in: workbook, sheetID: id, axisIsRow: true, index: 0, count: 2) == nil,
               WorkbookOperations.pivotTableSplit(in: workbook, sheetID: id, axisIsRow: false, index: 0, count: 1) == nil {
                WorkbookOperations.insertRows(in: workbook, sheetID: id, at: 0, count: 2)
                WorkbookOperations.insertColumns(in: workbook, sheetID: id, at: 0, count: 1)
                shifted.insert(id)
            }
        }
        // A row inside each source range on sheets hosting no pivot.
        for cache in workbook.pivotCaches {
            for range in cache.sourceRanges {
                guard case .sheet(let id) = range.target, !hostSheets.contains(id),
                      let parsed = CellRange(a1: range.ref.replacingOccurrences(of: "$", with: "")),
                      parsed.rowCount > 1 else { continue }
                _ = parsed
            }
        }
        for id in sourceSheets.sorted() where !hostSheets.contains(id) {
            WorkbookOperations.insertRows(in: workbook, sheetID: id, at: 1, count: 1)
        }

        for (sheetID, name, cells) in before {
            guard let table = workbook.pivotTables.first(where: { $0.sheetID == sheetID && $0.name == name }) else { continue }
            let key = "\(workbook.sheet(withID: sheetID)!.name)!\(name)"
            let dr = shifted.contains(sheetID) ? 2 : 0, dc = shifted.contains(sheetID) ? 1 : 0
            var moved: [CellAddress: CellValue] = [:]
            for (addr, value) in cells { moved[CellAddress(row: addr.row + dr, column: addr.column + dc)] = value }
            expectation.cells[key] = moved
            expectation.locations[key] = table.location.a1
        }
        for cache in workbook.pivotCaches {
            expectation.sources[cache.cacheID] = cache.sourceRanges.map(\.ref)
        }
        return expectation
    }
}
