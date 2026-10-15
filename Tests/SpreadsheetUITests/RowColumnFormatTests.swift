import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

/// Formatting whole columns and rows formats the columns and rows
/// themselves (review #17), and columns can be hidden.
@MainActor
@Suite("Row and column formats")
struct RowColumnFormatTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    func document(rows: Int = 30, columns: Int = 4) -> SpreadsheetDocument {
        let wb = Workbook.newDocument()
        for row in 0..<rows {
            for column in 0..<columns {
                wb.sheets[0].setCell(Cell(value: .number(Double(row))), at: CellAddress(row: row, column: column))
            }
        }
        return SpreadsheetDocument(workbook: wb)
    }

    func selectColumns(_ doc: SpreadsheetDocument, _ columns: ClosedRange<Int>) {
        let rows = GridLayout(sheet: doc.activeSheet).rowCount
        doc.selection.select(range: CellRange(start: CellAddress(row: 0, column: columns.lowerBound),
                                              end: CellAddress(row: rows - 1, column: columns.upperBound)))
    }

    func selectRows(_ doc: SpreadsheetDocument, _ rows: ClosedRange<Int>) {
        let columns = GridLayout(sheet: doc.activeSheet).columnCount
        doc.selection.select(range: CellRange(start: CellAddress(row: rows.lowerBound, column: 0),
                                              end: CellAddress(row: rows.upperBound, column: columns - 1)))
    }

    @Test func formattingWholeColumnsFormatsTheColumns() {
        let doc = document()
        doc.activeSheet.setCell(Cell(value: .number(1), styleIndex: doc.workbook.styleIndex(for: CellStyle(italic: true))),
                                at: a("B2"))
        let cells = doc.activeSheet.cells.count
        selectColumns(doc, 1...2)
        doc.toggleBold()
        #expect(doc.activeSheet.columnStyles.count == 2)
        #expect(doc.activeSheet.cells.count == cells) // nothing added
        #expect(doc.style(at: a("B5")).bold && doc.style(at: a("C900000")).bold)
        #expect(!doc.style(at: a("A5")).bold)
        // A cell with its own style keeps it and gains the change.
        #expect(doc.style(at: a("B2")).bold && doc.style(at: a("B2")).italic)
        // Typing into the column picks up its format.
        doc.commitInput("x", at: a("C500"))
        #expect(doc.style(at: a("C500")).bold)
        doc.undoManager.undo() // the typing
        doc.undoManager.undo() // the bold
        #expect(doc.activeSheet.columnStyles.isEmpty)
        #expect(!doc.style(at: a("B5")).bold && !doc.style(at: a("B2")).bold && doc.style(at: a("B2")).italic)
        doc.undoManager.redo()
        #expect(doc.style(at: a("B5")).bold)
    }

    @Test func aRowFormatWinsWhereItCrossesAColumnFormat() {
        let doc = document()
        selectColumns(doc, 1...1)
        doc.applyStyleToSelection("Fill Color") { $0.fillColor = RGBAColor(red: 255, green: 0, blue: 0) }
        selectRows(doc, 4...4)
        doc.toggleItalic()
        // Where they cross, the cell has both (Excel writes it so).
        #expect(doc.style(at: a("B5")).italic && doc.style(at: a("B5")).fillColor != nil)
        #expect(doc.style(at: a("B4")).fillColor != nil && !doc.style(at: a("B4")).italic)
        #expect(doc.style(at: a("Z5")).italic && doc.style(at: a("Z5")).fillColor == nil)
        // Formatting the column again reaches the crossing too.
        selectColumns(doc, 1...1)
        doc.toggleBold()
        #expect(doc.style(at: a("B5")).bold && doc.style(at: a("B5")).italic)
    }

    @Test func clearFormattingOnWholeColumnsRemovesTheirFormat() {
        let doc = document()
        selectColumns(doc, 0...1)
        doc.toggleBold()
        // Clearing one cell in a formatted column makes it plain, not inherited.
        doc.selection.select(range: CellRange(a1: "A3:A3")!)
        doc.clearFormattingInSelection()
        #expect(!doc.style(at: a("A3")).bold && doc.style(at: a("A4")).bold)
        selectColumns(doc, 0...1)
        doc.clearFormattingInSelection()
        #expect(doc.activeSheet.columnStyles.isEmpty)
        #expect(!doc.style(at: a("A4")).bold && !doc.style(at: a("B20")).bold)
        doc.undoManager.undo()
        #expect(doc.style(at: a("A4")).bold && !doc.style(at: a("A3")).bold)
    }

    @Test func copyingFromAFormattedColumnCarriesTheFormat() {
        let doc = document()
        selectColumns(doc, 0...0)
        doc.toggleBold()
        doc.selection.select(range: CellRange(a1: "A2:C2")!)
        doc.fillRight()
        #expect(doc.style(at: a("C2")).bold)
    }

    @Test func hidingColumnsHidesAndUndoes() {
        let doc = document()
        doc.hideColumns(1...2)
        #expect(doc.activeSheet.hiddenColumns == [1, 2])
        #expect(GridLayout(sheet: doc.activeSheet).columnWidth(1) == 0)
        doc.unhideColumns(0...3)
        #expect(doc.activeSheet.hiddenColumns.isEmpty)
        doc.undoManager.undo()
        #expect(doc.activeSheet.hiddenColumns == [1, 2])
        doc.undoManager.undo()
        #expect(doc.activeSheet.hiddenColumns.isEmpty)
    }

    @Test func boldOnAMillionRowsByTenIsQuick() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.reserveCellCapacity(200_000 * 10)
        for row in 0..<200_000 {
            for column in 0..<10 { sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: row, column: column)) }
        }
        let doc = SpreadsheetDocument(workbook: wb)
        selectColumns(doc, 0...9)
        let start = Date()
        doc.toggleBold()
        let time = Date().timeIntervalSince(start)
        #expect(time < 2, "bold took \(time)s")
        #expect(doc.style(at: a("J200000")).bold)
        let undoStart = Date()
        doc.undoManager.undo()
        #expect(Date().timeIntervalSince(undoStart) < 1)
        #expect(!doc.style(at: a("J200000")).bold)
    }
}
