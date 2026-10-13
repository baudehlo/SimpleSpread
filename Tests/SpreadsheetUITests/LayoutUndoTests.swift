import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

/// Undo of layout commands touches only what the command changed, and
/// resizing rows and columns is undoable (review #31).
@MainActor
@Suite("Layout undo")
struct LayoutUndoTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    @Test func undoingAHideLeavesLaterResizeAndFreezeAlone() {
        let doc = SpreadsheetDocument()
        doc.hideRows(4...4)
        doc.setRowHeight(1, height: 60)
        doc.freezePanes(rows: 1, columns: 0)
        // The newest step is the resize: undo it, then the hide.
        #expect(doc.undoManager.undoActionName == "Row Height")
        doc.undoManager.undo()
        #expect(doc.activeSheet.rowHeights[1] == nil)
        #expect(doc.activeSheet.hiddenRows == [4])
        doc.undoManager.undo()
        #expect(doc.activeSheet.hiddenRows.isEmpty)
        // The freeze is a view setting, like Excel's, and stays.
        #expect(doc.activeSheet.frozenRows == 1)
        doc.undoManager.redo()
        #expect(doc.activeSheet.hiddenRows == [4])
        doc.undoManager.redo()
        #expect(doc.activeSheet.rowHeights[1] == 60)
        #expect(doc.activeSheet.frozenRows == 1)
    }

    @Test func layoutUndoKeepsChangesMadeOutsideTheUndoStack() {
        let doc = SpreadsheetDocument()
        doc.hideRows(2...3)
        // Changes made after the command without an undo step of their own
        // (here directly on the sheet, as a file reload or a view setting
        // would) survive undoing it.
        doc.activeSheet.rowHeights[7] = 40
        doc.activeSheet.hiddenRows.insert(9)
        doc.freezePanes(rows: 2, columns: 1)
        doc.undoManager.undo()
        #expect(doc.activeSheet.hiddenRows == [9])
        #expect(doc.activeSheet.rowHeights[7] == 40)
        #expect(doc.activeSheet.frozenRows == 2 && doc.activeSheet.frozenColumns == 1)
        doc.undoManager.redo()
        #expect(doc.activeSheet.hiddenRows == [2, 3, 9])
    }

    @Test func filterUndoRestoresOnlyTheFilterAndItsRows() {
        let doc = SpreadsheetDocument()
        let rows = [["Fruit", "Qty"], ["Pear", "3"], ["Apple", "5"], ["Fig", "1"]]
        for (i, row) in rows.enumerated() {
            for (j, text) in row.enumerated() { doc.commitInput(text, at: CellAddress(row: i, column: j)) }
        }
        doc.selection.select(a("A1"))
        doc.toggleAutoFilter()
        doc.setColumnFilter(1, ColumnFilter(conditions: [FilterCondition(.greaterThan, "2")]))
        #expect(doc.activeSheet.hiddenRows == [3])
        doc.activeSheet.mergedRanges.append(r("D1:E1"))   // not an undoable step
        doc.undoManager.undo()
        #expect(doc.activeSheet.hiddenRows.isEmpty)
        #expect(doc.activeAutoFilter?.columns.isEmpty == true)
        #expect(doc.activeSheet.mergedRanges == [r("D1:E1")])
        doc.undoManager.undo()
        #expect(doc.activeAutoFilter == nil)
    }

    @Test func mergeUndoRemovesOnlyItsOwnMerge() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: r("A1:B1"))
        doc.mergeSelection(.merge)
        doc.selection.select(range: r("A3:B3"))
        doc.mergeSelection(.merge)
        #expect(doc.activeSheet.mergedRanges == [r("A1:B1"), r("A3:B3")])
        doc.undoManager.undo()
        #expect(doc.activeSheet.mergedRanges == [r("A1:B1")])
        doc.undoManager.redo()
        #expect(Set(doc.activeSheet.mergedRanges.map(\.description)) == ["A1:B1", "A3:B3"])
    }

    @Test func columnResizeIsOneUndoStepPerDrag() {
        let doc = SpreadsheetDocument()
        doc.setColumnWidth(2, width: 120)
        doc.setColumnWidth(2, width: 140)
        doc.setColumnWidth(2, width: 150) // one drag: three updates
        #expect(doc.activeSheet.columnWidths[2] == 150)
        #expect(doc.undoManager.undoActionName == "Column Width")
        doc.undoManager.undo()
        #expect(doc.activeSheet.columnWidths[2] == nil)
        #expect(!doc.undoManager.canUndo)
        doc.undoManager.redo()
        #expect(doc.activeSheet.columnWidths[2] == 150)
    }

    @Test func separateResizesAreSeparateSteps() {
        let doc = SpreadsheetDocument()
        doc.setColumnWidth(0, width: 80)
        doc.setColumnWidth(1, width: 90)   // another column: a new step
        doc.commitInput("x", at: a("A1"))
        doc.setColumnWidth(1, width: 200)  // after an edit: a new step
        doc.undoManager.undo()
        #expect(doc.activeSheet.columnWidths[1] == 90)
        doc.undoManager.undo()
        doc.undoManager.undo()
        #expect(doc.activeSheet.columnWidths[1] == nil)
        #expect(doc.activeSheet.columnWidths[0] == 80)
        doc.undoManager.undo()
        #expect(doc.activeSheet.columnWidths[0] == nil)
    }

    @Test func rowResizeUndoes() {
        let doc = SpreadsheetDocument()
        doc.setRowHeight(3, height: 40)
        doc.setRowHeight(3, height: 48)
        doc.undoManager.undo()
        #expect(doc.activeSheet.rowHeights[3] == nil)
        doc.undoManager.redo()
        #expect(doc.activeSheet.rowHeights[3] == 48)
    }

    @Test func resizingToTheSameSizeAddsNoStep() {
        let doc = SpreadsheetDocument()
        doc.setColumnWidth(0, width: doc.activeSheet.columnWidth(0))
        #expect(!doc.undoManager.canUndo)
    }
}
