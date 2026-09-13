import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

@Suite("Selection model")
struct SelectionTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    @Test func basicSelectAndExtend() {
        var sel = SelectionState()
        sel.select(a("B2"))
        #expect(sel.range == CellRange(a1: "B2"))
        #expect(sel.activeCell == a("B2"))
        sel.extend(to: a("D4"))
        #expect(sel.range == CellRange(a1: "B2:D4"))
        #expect(sel.activeCell == a("B2")) // anchor stays active
        sel.extend(to: a("A1"))
        #expect(sel.range == CellRange(a1: "A1:B2")) // extend above/left of anchor
    }

    @Test func arrowMovement() {
        var sel = SelectionState()
        sel.select(a("B2"))
        sel.move(.down)
        #expect(sel.activeCell == a("B3"))
        sel.move(.right)
        #expect(sel.activeCell == a("C3"))
        sel.move(.up)
        sel.move(.up)
        #expect(sel.activeCell == a("C1"))
        sel.move(.up) // clamps at top
        #expect(sel.activeCell == a("C1"))
        sel.move(.left)
        sel.move(.left)
        sel.move(.left) // clamps at left
        #expect(sel.activeCell == a("A1"))
    }

    @Test func shiftArrowExtension() {
        var sel = SelectionState()
        sel.select(a("B2"))
        sel.extendMove(.down)
        sel.extendMove(.right)
        #expect(sel.range == CellRange(a1: "B2:C3"))
        #expect(sel.anchor == a("B2"))
        sel.extendMove(.up)
        sel.extendMove(.up)
        #expect(sel.range == CellRange(a1: "B1:C2"))
    }

    @Test func moveCollapsesRange() {
        var sel = SelectionState()
        sel.select(range: CellRange(a1: "B2:D4")!)
        sel.move(.down)
        #expect(sel.isSingleCell)
        #expect(sel.activeCell == a("B3")) // moves from active cell
    }

    @Test func dataEdgeNavigation() {
        let sheet = Sheet(id: 1, name: "S")
        for row in [0, 1, 2, 5, 6] {
            sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: row, column: 0))
        }
        func edge(from: String, _ dir: SelectionState.Direction) -> CellAddress {
            SelectionState.dataEdge(from: a(from), direction: dir, sheet: sheet,
                                    rowLimit: 100, columnLimit: 26)
        }
        // Inside a block: run to its end.
        #expect(edge(from: "A1", .down) == a("A3"))
        // At block end with a gap: jump to the next block's start.
        #expect(edge(from: "A3", .down) == a("A6"))
        // Last block end: jump to sheet boundary.
        #expect(edge(from: "A7", .down) == CellAddress(row: 99, column: 0))
        // From empty space: next non-empty.
        #expect(edge(from: "A20", .up) == a("A7"))
        // No data in that direction: boundary.
        #expect(edge(from: "C5", .right) == CellAddress(row: 4, column: 25))
    }
}

@Suite("Grid layout")
struct GridLayoutTests {
    @Test func offsetsAndHitTesting() {
        let sheet = Sheet(id: 1, name: "S")
        sheet.defaultColumnWidth = 100
        sheet.defaultRowHeight = 20
        sheet.columnWidths[1] = 150 // column B wider
        sheet.rowHeights[0] = 40    // row 1 taller
        let layout = GridLayout(sheet: sheet)

        #expect(layout.xOffset(ofColumn: 0) == 0)
        #expect(layout.xOffset(ofColumn: 1) == 100)
        #expect(layout.xOffset(ofColumn: 2) == 250)
        #expect(layout.yOffset(ofRow: 0) == 0)
        #expect(layout.yOffset(ofRow: 1) == 40)
        #expect(layout.yOffset(ofRow: 2) == 60)

        #expect(layout.column(atX: 50) == 0)
        #expect(layout.column(atX: 100) == 1)
        #expect(layout.column(atX: 249) == 1)
        #expect(layout.column(atX: 250) == 2)
        #expect(layout.row(atY: 39) == 0)
        #expect(layout.row(atY: 40) == 1)

        let rect = layout.rect(of: CellAddress(a1: "B1")!)
        #expect(rect == CGRect(x: 100, y: 0, width: 150, height: 40))
    }

    @Test func growsWithUsedRange() {
        let sheet = Sheet(id: 1, name: "S")
        var layout = GridLayout(sheet: sheet)
        #expect(layout.rowCount == 200)
        #expect(layout.columnCount == 26)
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: 500, column: 30))
        layout = GridLayout(sheet: sheet)
        #expect(layout.rowCount == 550)
        #expect(layout.columnCount == 40)
    }

    @Test func visibleRangeComputation() {
        let sheet = Sheet(id: 1, name: "S")
        sheet.defaultColumnWidth = 100
        sheet.defaultRowHeight = 20
        let layout = GridLayout(sheet: sheet)
        let rows = layout.visibleRows(in: CGRect(x: 0, y: 100, width: 500, height: 200))
        #expect(rows == 5...15)
        let cols = layout.visibleColumns(in: CGRect(x: 150, y: 0, width: 300, height: 100))
        #expect(cols == 1...4)
    }
}
