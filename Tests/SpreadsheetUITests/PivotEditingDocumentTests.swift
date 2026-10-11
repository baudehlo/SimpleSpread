import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

@MainActor
@Suite("Pivot tables: editing in a document")
struct PivotEditingDocumentTests {
    func a(_ s: String) -> CellAddress { CellAddress(a1: s)! }

    /// A document whose first sheet holds Region | Units data in A1:B5.
    func document() -> SpreadsheetDocument {
        let doc = SpreadsheetDocument()
        for (r, row) in [("Region", "Units"), ("East", "10"), ("West", "5"), ("East", "7"), ("North", "2")].enumerated() {
            doc.commitInput(row.0, at: CellAddress(row: r, column: 0))
            doc.commitInput(row.1, at: CellAddress(row: r, column: 1))
        }
        doc.undoManager.removeAllActions()
        return doc
    }

    func text(_ doc: SpreadsheetDocument, _ s: String) -> String { doc.displayString(at: a(s)) }

    @Test func suggestedSourceIsTheFilledRegion() {
        let doc = document()
        doc.selection.select(a("A3"))
        #expect(doc.suggestedPivotSource()?.a1 == "A1:B5")
        doc.selection.select(range: CellRange(a1: "A1:B3")!)
        #expect(doc.suggestedPivotSource()?.a1 == "A1:B3")
    }

    @Test func insertingAPivotMakesANewSheetAndSelectsIt() {
        let doc = document()
        let dataSheet = doc.activeSheetID
        #expect(doc.insertPivotTable(source: CellRange(a1: "A1:B5")!))
        #expect(doc.activeSheetID != dataSheet)
        #expect(doc.workbook.pivotTables.count == 1)
        #expect(doc.activePivotIndex == 0)
        #expect(doc.selection.activeCell == a("A3"))
        // Undo removes the sheet and the pivot.
        doc.undoManager.undo()
        #expect(doc.workbook.pivotTables.isEmpty)
        #expect(doc.workbook.sheets.count == 1)
    }

    @Test func editingLaysOutAndUndoes() {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        #expect(doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) })
        #expect(doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 1, in: .values, cache: c) })
        #expect(text(doc, "A3") == "Row Labels")
        #expect(text(doc, "A4") == "East" && text(doc, "B4") == "17")
        #expect(text(doc, "A7") == "Grand Total" && text(doc, "B7") == "24")
        #expect(doc.isModified)
        doc.undoManager.undo()
        #expect(text(doc, "B4") == "")
        #expect(doc.workbook.pivotTables[0].definition?.dataFields.isEmpty == true)
        doc.undoManager.redo()
        #expect(text(doc, "B4") == "17")
    }

    @Test func groupingRedrawsAndUndoes() {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 1, in: .rows, cache: c) }
        doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .values, cache: c) }
        #expect(text(doc, "A4") == "2")
        #expect(doc.regroupPivot(0, actionName: "Group") { try $0.groupPivotField(table: 0, field: 1, interval: 5) })
        // Units 2, 5, 7, 10 from 2 by 5: 2-6 and 7-11.
        #expect(text(doc, "A4") == "2-6" && text(doc, "B4") == "2")
        #expect(text(doc, "A5") == "7-11" && text(doc, "B5") == "2")
        doc.undoManager.undo()
        #expect(text(doc, "A4") == "2")
        #expect(doc.workbook.pivotCache(withID: doc.workbook.pivotTables[0].cacheID)?.data?.fields[1].group == nil)
    }

    @Test func groupingTextSaysWhy() {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) }
        #expect(!doc.regroupPivot(0, actionName: "Group") { try $0.groupPivotField(table: 0, field: 0, interval: 5) })
        #expect(doc.notice?.message == "Couldn’t group the field.")
        #expect(!doc.undoManager.canUndo || doc.undoManager.undoActionName != "Group")
    }

    @Test func refreshPicksUpSourceEdits() {
        let doc = document()
        let dataSheet = doc.activeSheetID
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in
            d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c)
        }
        let pivotSheet = doc.activeSheetID
        doc.selectSheet(withID: dataSheet)
        doc.commitInput("100", at: a("B5"))
        doc.selectSheet(withID: pivotSheet)
        #expect(text(doc, "B5") == "2")      // stale until refreshed
        #expect(doc.refreshPivot(0))
        #expect(text(doc, "B5") == "100")
        doc.undoManager.undo()
        #expect(text(doc, "B5") == "2")
        #expect(doc.refreshAllPivots())
        #expect(text(doc, "B5") == "100")
    }

    @Test func growingOverDataAsksFirst() {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 1, in: .values, cache: c) }
        doc.commitInput("keep", at: a("A6"))
        var asked = 0
        doc.confirm = { _, _ in asked += 1; return false }
        #expect(!doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) })
        #expect(asked == 1)
        #expect(text(doc, "A6") == "keep")
        #expect(doc.workbook.pivotTables[0].definition?.rowFields.isEmpty == true)
        doc.confirm = { _, _ in true }
        #expect(doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) })
        #expect(text(doc, "A6") != "keep")
    }

    @Test func typingIntoAnEditablePivotPointsAtThePanel() {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) }
        doc.commitInput("x", at: a("A4"))
        #expect(doc.notice?.detail.contains("PivotTable Fields") == true)
    }

    @Test func pivotsFromExcelThatCantBeRecomputedSaySo() throws {
        // As if from Excel with a cache saved without records.
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        let cacheIndex = doc.workbook.pivotCaches.indices.first!
        doc.workbook.pivotCaches[cacheIndex].data?.hasRecords = false
        #expect(!doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) })
        #expect(doc.notice?.detail.contains("no saved records") == true)
        doc.notice = nil
        #expect(!doc.refreshAllPivots())
        #expect(doc.notice != nil)
    }

    @Test func rolesDescribeThePivotCells() {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in
            d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c)
        }
        #expect(doc.pivotRole(at: a("A3")) == .header)
        #expect(doc.pivotRole(at: a("A4")) == .rowLabel)
        #expect(doc.pivotRole(at: a("B4")) == .value)
        #expect(doc.pivotRole(at: a("A7")) == .grandTotalLabel)
        #expect(doc.pivotRole(at: a("B7")) == .grandTotalValue)
        #expect(doc.pivotRole(at: a("D1")) == nil)
    }

    @Test func savedAndReopenedPivotsStayEditable() throws {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in
            d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pivot-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        let reopened = try SpreadsheetDocument.open(url: url)
        reopened.selectSheet(withID: reopened.workbook.pivotTables[0].sheetID)
        #expect(reopened.pivotEditBlocker(0) == nil)
        #expect(reopened.editPivot(0, actionName: "Sort") { d, c in d.setSort(.descending, field: 0, cache: c) })
        #expect(reopened.displayString(at: a("A4")) == "West")
    }
}
