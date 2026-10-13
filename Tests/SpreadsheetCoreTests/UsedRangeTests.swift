import Foundation
import Testing
@testable import SpreadsheetCore

@Suite("Sheet used range")
struct UsedRangeTests {
    @Test func boundsFollowAddsAndRemovals() {
        let sheet = Sheet(id: 1, name: "S")
        func set(_ a1: String, _ v: Double?) {
            sheet.setCell(v.map { Cell(value: .number($0)) } ?? Cell(), at: CellAddress(a1: a1)!)
        }
        #expect(sheet.usedRange == nil)
        set("C3", 1)
        #expect(sheet.usedRange?.a1 == "C3")
        set("B5", 1); set("F2", 1)
        #expect(sheet.usedRange?.a1 == "B2:F5")
        set("D4", nil) // absent: no change
        set("D4", 1); set("D4", nil) // interior
        #expect(sheet.usedRange?.a1 == "B2:F5")
        set("F2", nil) // boundary
        #expect(sheet.usedRange?.a1 == "B3:C5")
        set("B5", nil)
        #expect(sheet.usedRange?.a1 == "C3")
        set("C3", nil)
        #expect(sheet.usedRange == nil)
        set("A1", 1)
        #expect(sheet.usedRange?.a1 == "A1")
        sheet.removeAllCells()
        #expect(sheet.usedRange == nil)
    }

    @Test func boundsFollowBulkReplacement() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(a1: "B2")!)
        #expect(sheet.usedRange?.a1 == "B2")
        WorkbookOperations.insertRows(in: wb, sheetID: sheet.id, at: 0, count: 3)
        #expect(sheet.usedRange?.a1 == "B5")
        WorkbookOperations.deleteColumns(in: wb, sheetID: sheet.id, at: 0, count: 1)
        #expect(sheet.usedRange?.a1 == "A5")
        let other = Sheet(id: 9, name: "O")
        other.setCell(Cell(value: .number(1)), at: CellAddress(a1: "Z9")!)
        sheet.adoptContents(of: other)
        #expect(sheet.usedRange?.a1 == "Z9")
        // Adopted storage is independent: growing one leaves the other.
        other.setCell(Cell(value: .number(1)), at: CellAddress(a1: "AA10")!)
        #expect(sheet.usedRange?.a1 == "Z9")
    }

    /// Was a scan of every cell per call (and per whole-column reference
    /// evaluated): 1,000 calls on 200k cells took seconds in debug.
    @Test func repeatedCallsAreCheap() {
        let sheet = Sheet(id: 1, name: "S")
        for r in 0..<20_000 {
            for c in 0..<10 { sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: r, column: c)) }
        }
        var rows = 0
        let start = Date()
        for _ in 0..<1_000 { rows += sheet.usedRange?.rowCount ?? 0 }
        let elapsed = Date().timeIntervalSince(start)
        #expect(rows == 20_000_000)
        #expect(elapsed < 0.5, "usedRange x1000 took \(elapsed)s")
    }
}
