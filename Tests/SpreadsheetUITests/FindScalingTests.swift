import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

/// Find on big sheets: typing does not search every cell on the main
/// thread; the search runs in the background once typing pauses, and only
/// the last query's result lands (review #17).
@MainActor
@Suite("Find on big sheets")
struct FindScalingTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    /// `rows` × 3 text cells: "item <row>", "x<row>", and a formula.
    func bigDocument(rows: Int) -> SpreadsheetDocument {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        for row in 0..<rows {
            sheet.setCell(Cell(value: .string("item \(row)")), at: CellAddress(row: row, column: 0))
            sheet.setCell(Cell(value: .string("x\(row)")), at: CellAddress(row: row, column: 1))
            sheet.setCell(Cell(value: .number(Double(row)), formula: "ROW()-1"), at: CellAddress(row: row, column: 2))
        }
        return SpreadsheetDocument(workbook: wb)
    }

    func waitForFind(_ doc: SpreadsheetDocument) async throws {
        // Generous: CI runners under load are many times slower than a desk Mac.
        let deadline = Date().addingTimeInterval(120)
        while doc.isFindSearching, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!doc.isFindSearching)
    }

    func seconds(_ body: () -> Void) -> Double {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    @Test func typingOnABigSheetDoesNotSearchOnTheMainThread() async throws {
        // 30,000 cells: over the 20,000 that Find searches at once, so this
        // takes the background path, and quick enough for a loaded CI runner.
        let doc = bigDocument(rows: 10_000)
        var keystrokes: [Double] = []
        for prefix in ["i", "it", "ite", "item", "item ", "item 9", "item 99", "item 999"] {
            keystrokes.append(seconds { doc.setFindQuery(prefix) })
        }
        let worst = keystrokes.max() ?? 0
        #expect(worst < 0.1, "a keystroke took \(worst)s")
        #expect(doc.findStatus == "Searching…")
        try await waitForFind(doc)
        // item 999 and item 9990-9999.
        #expect(doc.findMatches.count == 11)
        #expect(doc.findMatches.first == a("A1000"))
        #expect(doc.findStatus == "1 of 11")
        #expect(doc.selection.activeCell == a("A1000"))
    }

    @Test func narrowingAQueryRechecksOnlyThePreviousMatches() async throws {
        let doc = bigDocument(rows: 60_000)
        doc.setFindQuery("item 5")
        try await waitForFind(doc)
        #expect(doc.findMatches.count == 11_111) // 5, 50-59, 500-599, 5000-5999, 50000-59999
        // Few enough candidates now to answer at once.
        doc.setFindQuery("item 512")
        #expect(!doc.isFindSearching)
        #expect(doc.findMatches == ([512] + Array(5120...5129) + Array(51_200...51_299)).map { CellAddress(row: $0, column: 0) })
        // A different query searches everything again.
        doc.setFindQuery("x7")
        try await waitForFind(doc)
        #expect(doc.findMatches.count == 1_111) // x7, x70-79, x700-799, x7000-7999
        #expect(doc.findMatches.allSatisfy { $0.column == 1 })
    }

    @Test func findNextFinishesAPendingSearch() {
        let doc = bigDocument(rows: 30_000)
        doc.selection.select(a("A1"))
        doc.setFindQuery("item 2999")
        #expect(doc.isFindSearching)
        doc.findNext() // Return before the search finished
        #expect(!doc.isFindSearching)
        #expect(doc.findMatches == [a("A3000")] + (29_990...29_999).map { CellAddress(row: $0, column: 0) })
        #expect(doc.selection.activeCell == a("A29991"))
    }

    @Test func anEditStartsTheSearchOver() async throws {
        let doc = bigDocument(rows: 30_000)
        doc.setFindQuery("item 1")
        try await waitForFind(doc)
        let before = doc.findMatches.count
        doc.commitInput("item 1 again", at: a("D1"))
        // The edit is not among the old matches, so this must search all.
        doc.setFindQuery("item 1 ")
        try await waitForFind(doc)
        #expect(doc.findMatches == [a("D1")])
        #expect(before > 1)
    }

    @Test func clearingTheQueryCancelsTheSearch() async throws {
        let doc = bigDocument(rows: 30_000)
        doc.setFindQuery("item")
        doc.setFindQuery("")
        #expect(!doc.isFindSearching)
        #expect(doc.findMatches.isEmpty)
        #expect(doc.findStatus == "")
        try await Task.sleep(for: .milliseconds(400))
        #expect(doc.findMatches.isEmpty)
    }
}
