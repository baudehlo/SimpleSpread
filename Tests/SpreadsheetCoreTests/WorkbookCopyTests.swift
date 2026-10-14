import Foundation
import Testing
@testable import SpreadsheetCore

@Suite("Workbook copy")
struct WorkbookCopyTests {
    @Test func copiesAreIndependent() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(1), formula: "A2+1"), at: CellAddress(a1: "A1")!)
        sheet.rowHeights[3] = 40
        sheet.hiddenRows = [5]
        sheet.mergedRanges = [CellRange(a1: "B2:C3")!]
        sheet.isHidden = true
        sheet.frozenRows = 1
        wb.definedNames = [DefinedName(name: "Rate", scopeSheetID: nil, formula: "Sheet1!$A$1", hidden: false)]
        let second = wb.addSheet(named: "Data")

        let copy = wb.copy()
        #expect(copy.sheets.map(\.id) == wb.sheets.map(\.id))
        #expect(copy.sheets.map(\.name) == wb.sheets.map(\.name))
        let c = copy.sheets[0]
        #expect(c !== sheet)
        #expect(c.cells == sheet.cells)
        #expect(c.rowHeights == [3: 40] && c.hiddenRows == [5] && c.isHidden && c.frozenRows == 1)
        #expect(c.mergedRanges == sheet.mergedRanges)
        #expect(c.usedRange == sheet.usedRange)
        #expect(copy.definedNames == wb.definedNames)

        // Changing either side leaves the other alone.
        c.setCell(Cell(value: .number(99)), at: CellAddress(a1: "Z9")!)
        sheet.rowHeights[3] = 10
        #expect(sheet.value(at: CellAddress(a1: "Z9")!) == .empty)
        #expect(c.rowHeights[3] == 40)
        #expect(c.usedRange == CellRange(a1: "A1:Z9")!)
        #expect(sheet.usedRange == CellRange(a1: "A1")!)

        // New sheets in the copy don't collide with the original's ids.
        let added = copy.addSheet(named: "More")
        #expect(added.id != second.id && !wb.sheets.contains { $0.id == added.id })
    }

    @Test func copyingAMillionCellsIsCheap() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        for r in 0..<100_000 {
            for c in 0..<10 { sheet.setCell(Cell(value: .number(Double(r))), at: CellAddress(row: r, column: c)) }
        }
        let start = Date()
        for _ in 0..<100 { _ = wb.copy() }
        #expect(Date().timeIntervalSince(start) < 0.5) // copy-on-write: no cell is duplicated
    }
}
