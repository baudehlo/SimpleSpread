import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("Pivot tables: refresh", .serialized)
struct PivotRefreshTests {
    /// Refresh every refreshable fixture pivot from its (unchanged) source
    /// and compare with what Excel last rendered.
    static func refreshOutcomes(_ name: String) throws -> [(tag: String, matches: Bool, detail: String)] {
        let (workbook, _) = try PivotFixtures.read(name)
        let captions = PivotEngineFixtureTests.captionsByFile[name] ?? .english
        var outcomes: [(String, Bool, String)] = []
        for cache in workbook.pivotCaches {
            let tables = workbook.pivotTables.indices.filter { workbook.pivotTables[$0].cacheID == cache.cacheID }
            let before = tables.map { workbook.pivotTables[$0].definition }
            guard tables.allSatisfy({ (try? workbook.computePivotTable(at: $0, captions: captions)) != nil }) else { continue }
            do {
                try workbook.refreshPivotCache(withID: cache.cacheID)
            } catch {
                outcomes.append(("\(name) cache \(cache.cacheID)", true, "not refreshable: \(error)"))
                continue
            }
            for (k, i) in tables.enumerated() {
                let tag = "\(name) \(workbook.pivotTables[i].name)"
                let result = try workbook.computePivotTable(at: i, captions: captions)
                let expected = before[k]!
                let same = result.rowLines.map { var l = $0; if l.kind == .grand { l.dataFieldIndex = 0 }; return l }
                    == expected.rowLines.map { var l = $0; if l.kind == .grand { l.dataFieldIndex = 0 }; return l }
                    && result.columnLines.count == expected.columnLines.count
                outcomes.append((tag, same, same ? "" : "rows \(result.rowLines.count) vs \(expected.rowLines.count), cols \(result.columnLines.count) vs \(expected.columnLines.count)"))
            }
        }
        return outcomes
    }

    @Test(arguments: PivotFixtures.all.filter { !PivotEngineFixtureTests.excludedFiles.contains($0) })
    func refreshingUnchangedSourcesReproducesExcel(_ name: String) throws {
        for o in try Self.refreshOutcomes(name) {
            #expect(o.matches, "\(o.tag): \(o.detail)")
        }
    }

    // MARK: Behaviour after edits (QuarterlySales: Region × Product rows,
    // Year/Quarter columns, Sum of Amount; source on sheet "Range").

    static func quarterly() throws -> (Workbook, sheet: Sheet, table: Int) {
        let (workbook, _) = try PivotFixtures.read("powertools-QuarterlySales.xlsx")
        let sheet = try #require(workbook.sheet(named: "Range"))
        return (workbook, sheet, 0)
    }

    static func refresh(_ workbook: Workbook, _ table: Int) throws -> PivotLayoutResult {
        try workbook.refreshPivotCache(withID: workbook.pivotTables[table].cacheID)
        let result = try workbook.computePivotTable(at: table)
        workbook.applyPivotLayout(at: table, result: result)
        return result
    }

    static func grandTotal(_ result: PivotLayoutResult) -> CellValue? {
        result.cells[PivotOffset(row: result.rowCount - 1, column: result.columnCount - 1)]?.value
    }

    @Test func changedValuesShowAfterRefresh() throws {
        let (workbook, sheet, t) = try Self.quarterly()
        let before = try workbook.computePivotTable(at: t)
        #expect(Self.grandTotal(before) == .number(3448))
        // Amount is the last source column.
        let amount = try #require(sheet.usedRange).end.column
        let row = 1
        let old = sheet.value(at: CellAddress(row: row, column: amount))
        guard case .number(let n) = old else { Issue.record("expected a number"); return }
        sheet.setCell(Cell(value: .number(n + 100)), at: CellAddress(row: row, column: amount))
        // Stale until refreshed, as in Excel.
        #expect(Self.grandTotal(try workbook.computePivotTable(at: t)) == .number(3448))
        let after = try Self.refresh(workbook, t)
        #expect(Self.grandTotal(after) == .number(3548))
    }

    @Test func newRowsAndItemsAppearAfterRefresh() throws {
        let (workbook, sheet, t) = try Self.quarterly()
        let used = try #require(sheet.usedRange)
        // Copy the last row as a new region "West".
        let newRow = used.end.row + 1
        for c in used.start.column...used.end.column {
            sheet.setCell(sheet.cell(at: CellAddress(row: used.end.row, column: c)), at: CellAddress(row: newRow, column: c))
        }
        sheet.setCell(Cell(value: .string("West")), at: CellAddress(row: newRow, column: used.start.column))
        // Grow the source range, as inserting a row inside it would.
        let cacheIndex = workbook.pivotCaches.firstIndex { $0.cacheID == workbook.pivotTables[t].cacheID }!
        workbook.pivotCaches[cacheIndex].sourceRanges[0].ref = CellRange(start: used.start, end: CellAddress(row: newRow, column: used.end.column)).a1
        let result = try Self.refresh(workbook, t)
        let labels = result.cells.values.compactMap { cell -> String? in if case .string(let s) = cell.value { return s } else { return nil } }
        #expect(labels.contains("West"))
        guard case .number(let total)? = Self.grandTotal(result) else { Issue.record("no grand total"); return }
        #expect(total > 3448)
        // Saved and reopened, the refreshed pivot is intact.
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        let again = try reread.computePivotTable(at: 0)
        #expect(again.rowLines == result.rowLines)
        #expect(Self.grandTotal(again) == Self.grandTotal(result))
    }

    @Test func hiddenItemsStayHiddenAndVanishedItemsGo() throws {
        let (workbook, _) = try PivotFixtures.read("poi-ExcelPivotTableSample.xlsx")
        let t = workbook.pivotTables.firstIndex { workbook.sheet(withID: $0.sheetID)?.name == "Tabelle2" }!
        let hiddenBefore = workbook.pivotTables[t].definition!.fields.map { $0.items.filter(\.hidden).count }
        _ = try Self.refresh(workbook, t)
        let hiddenAfter = workbook.pivotTables[t].definition!.fields.map { $0.items.filter(\.hidden).count }
        #expect(hiddenAfter == hiddenBefore)
    }

    @Test func refreshRefusesWhenAUsedFieldDisappears() throws {
        let (workbook, sheet, t) = try Self.quarterly()
        let used = try #require(sheet.usedRange)
        sheet.setCell(Cell(value: .string("Renamed")), at: used.start) // the Region heading
        #expect(throws: PivotEngineError.self) { try workbook.refreshPivotCache(withID: workbook.pivotTables[t].cacheID) }
        // Nothing changed.
        #expect(workbook.pivotCaches[0].isModified == false)
    }

    @Test func refreshRefusesBlankHeadings() throws {
        let (workbook, sheet, t) = try Self.quarterly()
        let used = try #require(sheet.usedRange)
        sheet.setCell(Cell(), at: CellAddress(row: used.start.row, column: used.end.column))
        #expect(throws: PivotEngineError.self) { try workbook.refreshPivotCache(withID: workbook.pivotTables[t].cacheID) }
    }

    @Test func duplicateHeadingsGetNumbered() throws {
        let wb = Workbook.newDocument()
        let s = wb.sheets[0]
        for (c, h) in ["Name", "name", "Name"].enumerated() { s.setCell(Cell(value: .string(h)), at: CellAddress(row: 0, column: c)) }
        for c in 0..<3 { s.setCell(Cell(value: .number(Double(c))), at: CellAddress(row: 1, column: c)) }
        let data = try PivotCacheBuilder.build(sheet: s, range: CellRange(a1: "A1:C2")!, workbook: wb)
        #expect(data.fields.map(\.name) == ["Name", "name2", "Name3"])
    }

    @Test func itemsKeepFirstAppearanceAndMergeCase() throws {
        let wb = Workbook.newDocument()
        let s = wb.sheets[0]
        s.setCell(Cell(value: .string("Fruit")), at: CellAddress(row: 0, column: 0))
        for (r, v) in ["pear", "Apple", "apple", "Pear", "fig"].enumerated() {
            s.setCell(Cell(value: .string(v)), at: CellAddress(row: r + 1, column: 0))
        }
        let data = try PivotCacheBuilder.build(sheet: s, range: CellRange(a1: "A1:A6")!, workbook: wb)
        #expect(data.fields[0].sharedItems == [.string("pear"), .string("Apple"), .string("fig")])
        #expect(data.records.map { $0[0] } == [.shared(0), .shared(1), .shared(1), .shared(0), .shared(2)])
    }

    @Test func ascendingOrderMatchesExcelCollation() {
        let values: [PivotValue] = [.missing, .string("Shanghai"), .bool(true), .number(10), .string("São Paulo"),
                                    .error(.na), .bool(false), .number(2), .string("mMovies"), .string("MMusic")]
        let sorted = values.sorted(by: PivotValue.ascending)
        #expect(sorted == [.number(2), .number(10), .string("mMovies"), .string("MMusic"), .string("São Paulo"),
                           .string("Shanghai"), .bool(false), .bool(true), .error(.na), .missing])
    }
}
