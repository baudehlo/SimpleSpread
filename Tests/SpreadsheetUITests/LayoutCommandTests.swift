import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

@MainActor
@Suite("Borders, merge, freeze, sort and filter commands")
struct LayoutCommandTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    func table(_ doc: SpreadsheetDocument) {
        let rows = [["Fruit", "Qty"], ["Pear", "3"], ["Apple", "5"], ["Fig", "1"]]
        for (i, row) in rows.enumerated() {
            for (j, text) in row.enumerated() {
                doc.commitInput(text, at: CellAddress(row: i, column: j))
            }
        }
    }

    // MARK: Borders

    @Test func outsideBordersOnlyTouchTheEdges() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: r("B2:C3"))
        doc.applyBorders(.outside)
        let b2 = doc.style(at: a("B2")).borders
        #expect(b2.top != nil && b2.left != nil && b2.bottom == nil && b2.right == nil)
        let c3 = doc.style(at: a("C3")).borders
        #expect(c3.bottom != nil && c3.right != nil && c3.top == nil && c3.left == nil)
        doc.applyBorders(.thickBottom)
        #expect(doc.style(at: a("C3")).borders.bottom?.style == .medium)
        doc.applyBorders(.none)
        #expect(doc.style(at: a("B2")).borders.isEmpty)
        doc.undoManager.undo()
        doc.undoManager.undo()
        #expect(doc.style(at: a("C3")).borders.bottom?.style == .thin)
    }

    @Test func allAndInsideBorders() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: r("A1:B2"))
        doc.applyBorders(.inside)
        #expect(doc.style(at: a("A1")).borders == CellBorders(bottom: BorderLine(), right: BorderLine()))
        doc.applyBorders(.all)
        #expect(doc.style(at: a("B2")).borders == CellBorders(top: BorderLine(), bottom: BorderLine(),
                                                              left: BorderLine(), right: BorderLine()))
    }

    // MARK: Merge

    @Test func mergeAndCenterAsksBeforeDiscardingValues() {
        let doc = SpreadsheetDocument()
        doc.commitInput("keep", at: a("A1"))
        doc.commitInput("lose", at: a("B1"))
        doc.selection.select(range: r("A1:B1"))
        var asked = 0
        doc.confirm = { _, _, button in asked += 1; #expect(button == "Merge"); return false }
        doc.mergeSelection(.mergeAndCenter)
        #expect(asked == 1)
        #expect(doc.activeSheet.mergedRanges.isEmpty)

        doc.confirm = { _, _, _ in true }
        doc.mergeSelection(.mergeAndCenter)
        #expect(doc.activeSheet.mergedRanges == [r("A1:B1")])
        #expect(doc.activeSheet.value(at: a("B1")) == .empty)
        #expect(doc.style(at: a("A1")).horizontalAlignment == .center)
        #expect(doc.selectionHasMerge)

        doc.undoManager.undo()
        #expect(doc.activeSheet.mergedRanges.isEmpty)
        #expect(doc.activeSheet.value(at: a("B1")) == .string("lose"))
        #expect(doc.style(at: a("A1")).horizontalAlignment == .automatic)
    }

    @Test func mergeAcrossAndUnmerge() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: r("A1:C2"))
        doc.mergeSelection(.mergeAcross)
        #expect(Set(doc.activeSheet.mergedRanges) == [r("A1:C1"), r("A2:C2")])
        doc.selection.select(range: r("B2"))
        doc.toggleMergeAndCenter() // on a merged cell: unmerge
        #expect(doc.activeSheet.mergedRanges == [r("A1:C1")])
    }

    @Test func mergingReplacesOverlappingMerges() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: r("A1:B1"))
        doc.mergeSelection(.merge)
        doc.selection.select(range: r("A1:C2"))
        doc.mergeSelection(.merge)
        #expect(doc.activeSheet.mergedRanges == [r("A1:C2")])
    }

    // MARK: Freeze

    @Test func freezePanesAtSelection() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("C3"))
        doc.freezePanesAtSelection()
        #expect(doc.activeSheet.frozenRows == 2 && doc.activeSheet.frozenColumns == 2)
        doc.freezePanes(rows: 1, columns: 0)
        #expect(doc.activeSheet.frozenRows == 1 && doc.activeSheet.frozenColumns == 0)
        #expect(doc.hasFrozenPanes)
        doc.freezePanes(rows: 0, columns: 0)
        #expect(!doc.hasFrozenPanes)
    }

    // MARK: Sort

    @Test func quickSortFindsTheTableAndItsHeader() {
        let doc = SpreadsheetDocument()
        table(doc)
        doc.selection.select(a("B3"))
        doc.quickSort(ascending: false)
        #expect(doc.displayString(at: a("A1")) == "Fruit")
        #expect((1...3).map { doc.displayString(at: CellAddress(row: $0, column: 0)) } == ["Apple", "Pear", "Fig"])
        doc.undoManager.undo()
        #expect((1...3).map { doc.displayString(at: CellAddress(row: $0, column: 0)) } == ["Pear", "Apple", "Fig"])
    }

    @Test func sortRefusesMergedCells() {
        let doc = SpreadsheetDocument()
        table(doc)
        doc.confirm = { _, _, _ in true }
        doc.selection.select(range: r("A3:B3"))
        doc.mergeSelection(.merge)
        #expect(!doc.activeSheet.mergedRanges.isEmpty)
        doc.selection.select(a("A2"))
        doc.quickSort(ascending: true)
        #expect(doc.notice != nil)
        #expect(doc.displayString(at: a("A2")) == "Pear") // unchanged
    }

    // MARK: Filter

    @Test func filterHidesRowsAndUndoes() {
        let doc = SpreadsheetDocument()
        table(doc)
        doc.selection.select(a("A1"))
        doc.toggleAutoFilter()
        #expect(doc.activeAutoFilter?.range == r("A1:B4"))
        doc.setColumnFilter(1, ColumnFilter(conditions: [FilterCondition(.greaterThan, "2")]))
        #expect(doc.activeSheet.hiddenRows == [3]) // Fig, 1
        #expect(doc.selectionStatistics().count == 1)

        doc.selection.select(range: r("B2:B4"))
        #expect(doc.selectionStatistics().sum == 8) // hidden Fig left out

        doc.undoManager.undo()
        #expect(doc.activeSheet.hiddenRows.isEmpty)
        doc.undoManager.redo()
        #expect(doc.activeSheet.hiddenRows == [3])

        doc.toggleAutoFilter() // remove: rows come back
        #expect(doc.activeAutoFilter == nil)
        #expect(doc.activeSheet.hiddenRows.isEmpty)
    }

    @Test func sortingAFilteredTableRefilters() {
        let doc = SpreadsheetDocument()
        table(doc)
        doc.selection.select(a("A1"))
        doc.toggleAutoFilter()
        doc.setColumnFilter(0, ColumnFilter(values: ["Pear", "Fig"]))
        #expect(doc.activeSheet.hiddenRows == [2])
        doc.selection.select(a("A2"))
        doc.quickSort(ascending: true) // Apple, Fig, Pear
        #expect(doc.displayString(at: a("A2")) == "Apple")
        #expect(doc.activeSheet.hiddenRows == [1])
    }

    @Test func filterNeedsData() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("D5"))
        doc.toggleAutoFilter()
        #expect(doc.activeAutoFilter == nil)
        #expect(doc.notice != nil)
    }

    // MARK: Hidden rows

    @Test func hideAndUnhideRows() {
        let doc = SpreadsheetDocument()
        doc.hideRows(2...3)
        #expect(doc.activeSheet.hiddenRows == [2, 3])
        doc.unhideRows(1...4)
        #expect(doc.activeSheet.hiddenRows.isEmpty)
        doc.undoManager.undo()
        #expect(doc.activeSheet.hiddenRows == [2, 3])
    }

    @Test func hiddenRowsTakeNoSpace() {
        let doc = SpreadsheetDocument()
        doc.hideRows(1...1)
        let l = GridLayout(sheet: doc.activeSheet)
        #expect(l.rowHeight(1) == 0)
        #expect(l.yOffset(ofRow: 2) == l.rowHeight(0))
        #expect(l.row(atY: l.rowHeight(0) + 1) == 2)
    }
}
