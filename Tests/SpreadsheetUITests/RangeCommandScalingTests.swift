import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

/// Formatting, merge and sort commands over big selections work over the
/// stored cells instead of every address in the rectangle (review §3.5),
/// and the status bar sums whole columns.
@MainActor
@Suite("Range commands on big selections")
struct RangeCommandScalingTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    func seconds(_ body: () -> Void) -> Double {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    /// A document over `rows` × `columns` numbers, built without the engine.
    func bigDocument(rows: Int, columns: Int) -> SpreadsheetDocument {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.reserveCellCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                sheet.setCell(Cell(value: .number(Double(row))), at: CellAddress(row: row, column: column))
            }
        }
        return SpreadsheetDocument(workbook: wb)
    }

    func wholeColumns(_ doc: SpreadsheetDocument, _ columns: ClosedRange<Int>) -> CellRange {
        // As a header click selects: down to the grid's last row.
        let rows = GridLayout(sheet: doc.activeSheet).rowCount
        return CellRange(start: CellAddress(row: 0, column: columns.lowerBound),
                         end: CellAddress(row: rows - 1, column: columns.upperBound))
    }

    @Test func boldOverABigSelectionIsQuickAndUndoes() {
        let doc = bigDocument(rows: 100_000, columns: 4)
        doc.selection.select(range: r("A1:D100000"))
        let time = seconds { doc.toggleBold() }
        #expect(time < 8, "bold took \(time)s")
        #expect(doc.style(at: a("A1")).bold && doc.style(at: a("D100000")).bold)
        let undoTime = seconds { doc.undoManager.undo() }
        #expect(undoTime < 8, "undo took \(undoTime)s")
        #expect(!doc.style(at: a("A1")).bold && !doc.style(at: a("D100000")).bold)
        #expect(doc.activeSheet.value(at: a("C5")) == .number(4))
        doc.undoManager.redo()
        #expect(doc.style(at: a("B7")).bold)
    }

    @Test func formattingWholeColumnsDoesNotGrowTheSheet() {
        let doc = bigDocument(rows: 60_000, columns: 2)
        doc.activeSheet.setCell(Cell(), at: a("A5")) // a hole in the data
        let used = doc.activeSheet.usedRange
        let cellCount = doc.activeSheet.cells.count
        doc.selection.select(range: wholeColumns(doc, 0...3))
        doc.toggleItalic()
        // The columns take the format: no cell is added, blanks show it.
        #expect(doc.activeSheet.usedRange == used)
        #expect(doc.activeSheet.cells.count == cellCount)
        #expect(doc.activeSheet.columnStyles.count == 4)
        #expect(doc.style(at: a("B60000")).italic)
        #expect(doc.style(at: a("A5")).italic)
        #expect(doc.style(at: a("D900000")).italic)
        doc.undoManager.undo()
        #expect(doc.activeSheet.columnStyles.isEmpty)
        #expect(!doc.style(at: a("B1")).italic)
    }

    @Test func smallSelectionsStillFormatBlankCells() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: r("B2:C3"))
        doc.toggleBold()
        #expect(doc.style(at: a("C3")).bold)
        #expect(doc.activeSheet.cells.count == 4)
        doc.undoManager.undo()
        #expect(doc.activeSheet.cells.isEmpty)
    }

    @Test func bordersAndClearFormattingOverWholeColumns() {
        let doc = bigDocument(rows: 60_000, columns: 2)
        doc.selection.select(range: wholeColumns(doc, 0...1))
        let used = doc.activeSheet.usedRange
        let bordersTime = seconds { doc.applyBorders(.all) }
        #expect(bordersTime < 8, "borders took \(bordersTime)s")
        #expect(doc.activeSheet.usedRange == used)
        #expect(!doc.style(at: a("A30000")).borders.isEmpty)
        let clearTime = seconds { doc.clearFormattingInSelection() }
        #expect(clearTime < 8, "clear formatting took \(clearTime)s")
        #expect(doc.style(at: a("A30000")).borders.isEmpty)
        doc.undoManager.undo()
        #expect(!doc.style(at: a("A30000")).borders.isEmpty)
        doc.undoManager.undo()
        #expect(doc.style(at: a("A30000")).borders.isEmpty)
    }

    @Test func sortingWholeColumnsSnapshotsOnlyWhatMoves() {
        let doc = SpreadsheetDocument()
        for (i, text) in ["Name", "pear", "apple", "fig"].enumerated() {
            doc.commitInput(text, at: CellAddress(row: i, column: 0))
        }
        doc.selection.select(range: CellRange(start: a("A1"), end: CellAddress(row: CellAddress.maxRows - 1, column: 0)))
        let time = seconds { doc.sort(range: doc.selection.range, keys: [SortKey(column: 0)], hasHeader: true) }
        #expect(time < 3, "sort took \(time)s")
        #expect((0...3).map { doc.displayString(at: CellAddress(row: $0, column: 0)) } == ["Name", "apple", "fig", "pear"])
        doc.undoManager.undo()
        #expect((0...3).map { doc.displayString(at: CellAddress(row: $0, column: 0)) } == ["Name", "pear", "apple", "fig"])
    }

    @Test func mergeOverABigRangeIsQuick() {
        let doc = bigDocument(rows: 60_000, columns: 2)
        doc.confirm = { _, _, _ in true }
        doc.selection.select(range: wholeColumns(doc, 0...1))
        let time = seconds { doc.mergeSelection(.mergeAndCenter) }
        #expect(time < 8, "merge took \(time)s")
        #expect(doc.activeSheet.value(at: a("A1")) == .number(0))
        #expect(doc.activeSheet.value(at: a("B2")) == .empty)
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("B2")) == .number(1))
        #expect(doc.activeSheet.mergedRanges.isEmpty)
    }

    @Test func statusBarSumsAWholeColumnOfAMillionRows() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        for row in 0..<CellAddress.maxRows where row.isMultiple(of: 1000) {
            sheet.setCell(Cell(value: .number(1)), at: CellAddress(row: row, column: 0))
        }
        let doc = SpreadsheetDocument(workbook: wb)
        doc.selection.select(range: CellRange(start: a("A1"), end: CellAddress(row: CellAddress.maxRows - 1, column: 0)))
        var stats = doc.selectionStatistics()
        let time = seconds { stats = doc.selectionStatistics() }
        #expect(stats.count == 1049)
        #expect(stats.sum == 1049)
        #expect(time < 1, "statistics took \(time)s")
    }
}
