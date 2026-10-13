import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

@MainActor
@Suite("Toolbar commands")
struct ToolbarCommandTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    func column(_ doc: SpreadsheetDocument, _ values: [String], from top: String) {
        let start = a(top)
        for (i, v) in values.enumerated() {
            doc.commitInput(v, at: CellAddress(row: start.row + i, column: start.column))
        }
    }

    @Test func autoSumSingleCellSumsNumbersAbove() {
        let doc = SpreadsheetDocument()
        column(doc, ["Qty", "1", "2", "3"], from: "A1")
        doc.selection.select(a("A5"))
        doc.autoSum()
        #expect(doc.activeSheet.cell(at: a("A5")).formula == "SUM(A2:A4)")
        #expect(doc.activeSheet.value(at: a("A5")) == .number(6))
        doc.undoManager.undo()
        #expect(doc.activeSheet.cell(at: a("A5")).isDefault)
    }

    @Test func autoSumFallsBackToTheLeft() {
        let doc = SpreadsheetDocument()
        doc.commitInput("4", at: a("A1"))
        doc.commitInput("5", at: a("B1"))
        doc.selection.select(a("C1"))
        doc.autoSum("MAX")
        #expect(doc.activeSheet.value(at: a("C1")) == .number(5))
    }

    @Test func autoSumRangeTotalsEachColumnBelow() {
        let doc = SpreadsheetDocument()
        column(doc, ["1", "2"], from: "A1")
        column(doc, ["10", "20"], from: "B1")
        doc.selection.select(range: CellRange(a1: "A1:B2")!)
        doc.autoSum()
        #expect(doc.activeSheet.value(at: a("A3")) == .number(3))
        #expect(doc.activeSheet.value(at: a("B3")) == .number(30))
        doc.undoManager.undo() // one step undoes both totals
        #expect(doc.activeSheet.cell(at: a("A3")).isDefault)
        #expect(doc.activeSheet.cell(at: a("B3")).isDefault)
    }

    @Test func autoSumRangeUsesEmptyBottomRow() {
        let doc = SpreadsheetDocument()
        column(doc, ["1", "2"], from: "A1")
        doc.selection.select(range: CellRange(a1: "A1:A3")!)
        doc.autoSum("AVERAGE")
        #expect(doc.activeSheet.cell(at: a("A3")).formula == "AVERAGE(A1:A2)")
        #expect(doc.activeSheet.cell(at: a("A4")).isDefault)
    }

    @Test func decimalsFromGeneralStartAtShownDigits() {
        let doc = SpreadsheetDocument()
        doc.commitInput("12.5", at: a("A1"))
        doc.selection.select(a("A1"))
        doc.adjustDecimals(by: 1)
        #expect(doc.style(at: a("A1")).numberFormat.code == "0.00")
        doc.adjustDecimals(by: -1)
        doc.adjustDecimals(by: -1)
        #expect(doc.style(at: a("A1")).numberFormat.code == "0")
        #expect(doc.displayString(at: a("A1")) == "13")
    }

    @Test func decimalsAdjustCurrency() {
        let doc = SpreadsheetDocument()
        doc.commitInput("$1,234.50", at: a("A1"))
        doc.selection.select(a("A1"))
        doc.setNumberFormat(.currency)
        doc.adjustDecimals(by: -1)
        #expect(doc.displayString(at: a("A1")) == "$1,234.5")
    }

    @Test func fontSizeGrowsRowsAndUndoesInOneStep() {
        let doc = SpreadsheetDocument()
        doc.commitInput("Title", at: a("A1"))
        doc.selection.select(a("A1"))
        doc.setFontSize(24)
        #expect(doc.style(at: a("A1")).fontSize == 24)
        #expect(doc.activeSheet.rowHeight(0) == SpreadsheetDocument.rowHeight(forFontSize: 24))
        #expect(doc.activeSheet.rowHeight(0) > doc.activeSheet.defaultRowHeight)
        doc.undoManager.undo()
        #expect(doc.style(at: a("A1")).fontSize == nil)
        #expect(doc.activeSheet.rowHeights[0] == nil)
        doc.undoManager.redo()
        #expect(doc.style(at: a("A1")).fontSize == 24)
        #expect(doc.activeSheet.rowHeight(0) > doc.activeSheet.defaultRowHeight)
        // Smaller text never shrinks the row; the default size stores nil.
        doc.setFontSize(12)
        #expect(doc.style(at: a("A1")).fontSize == nil)
        #expect(doc.activeSheet.rowHeight(0) > doc.activeSheet.defaultRowHeight)
    }

    @Test func defaultFontSizeKeepsDefaultRowHeight() {
        #expect(SpreadsheetDocument.rowHeight(forFontSize: CellStyle.defaultFontSize) == 22)
    }

    @Test func fontNameDefaultStoresNil() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("A1"))
        doc.setFontName("Georgia")
        #expect(doc.style(at: a("A1")).fontName == "Georgia")
        doc.setFontName(CellStyle.defaultFontName)
        #expect(doc.style(at: a("A1")).fontName == nil)
    }

    @Test func wrapAndVerticalAlignment() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("A1"))
        doc.toggleWrapText()
        doc.setVerticalAlignment(.top)
        #expect(doc.style(at: a("A1")).wrapText)
        #expect(doc.style(at: a("A1")).verticalAlignment == .top)
        doc.toggleWrapText()
        #expect(!doc.style(at: a("A1")).wrapText)
    }

    @Test func indentClampsAndLeftAligns() {
        let doc = SpreadsheetDocument()
        doc.commitInput("42", at: a("A1"))
        doc.selection.select(a("A1"))
        doc.adjustIndent(by: -1)
        #expect(doc.style(at: a("A1")).indent == 0)
        doc.adjustIndent(by: 1)
        #expect(doc.style(at: a("A1")).indent == 1)
        #expect(doc.style(at: a("A1")).horizontalAlignment == .left)
        for _ in 0..<20 { doc.adjustIndent(by: 1) }
        #expect(doc.style(at: a("A1")).indent == 15)
    }

    @Test func formatPainterTilesSourceStyles() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("A1"))
        doc.toggleBold()
        doc.selection.select(a("A2"))
        doc.toggleItalic()
        doc.selection.select(range: CellRange(a1: "A1:A2")!)
        doc.beginFormatPainter()
        #expect(doc.formatPainterStyles != nil)

        doc.selection.select(range: CellRange(a1: "C1:C4")!)
        doc.applyFormatPainter()
        #expect(doc.formatPainterStyles == nil)
        #expect(doc.style(at: a("C1")).bold && !doc.style(at: a("C1")).italic)
        #expect(doc.style(at: a("C2")).italic && !doc.style(at: a("C2")).bold)
        #expect(doc.style(at: a("C3")).bold)
        #expect(doc.style(at: a("C4")).italic)
        doc.undoManager.undo()
        #expect(doc.style(at: a("C1")) == CellStyle())
    }

    @Test func formatPainterSingleClickPaintsSourceShape() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: CellRange(a1: "A1:B1")!)
        doc.toggleBold()
        doc.beginFormatPainter()
        doc.selection.select(a("D5"))
        doc.applyFormatPainter()
        #expect(doc.style(at: a("D5")).bold && doc.style(at: a("E5")).bold)
        #expect(doc.selection.range == CellRange(a1: "D5:E5")!)
    }
}
