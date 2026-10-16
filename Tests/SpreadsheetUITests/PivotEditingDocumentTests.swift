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

    /// A big table, as in the benchmark's complex.xlsx: Insert ▸ PivotTable…
    /// opens at once (it took minutes, so the dialog seemed never to come).
    @Test func suggestedSourceIsQuickOnABigTable() {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Data")
        for r in 0..<20_001 {
            for c in 0..<8 { sheet.setCell(Cell(value: r == 0 ? .string("H\(c)") : .number(Double(r * c))), at: CellAddress(row: r, column: c)) }
        }
        let doc = SpreadsheetDocument(workbook: wb)
        doc.selection.select(a("A1"))
        let clock = ContinuousClock()
        var source: CellRange?
        let elapsed = clock.measure { source = doc.suggestedPivotSource() }
        #expect(source?.a1 == "A1:H20001")
        #expect(elapsed < .milliseconds(500), "\(elapsed)")
    }

    /// The PivotTable Fields panel stays on a pivot while cells outside it
    /// are selected (the source data, on another sheet), and still edits it.
    @Test func thePanelStaysOnThePivotWhileYouLookAtTheData() throws {
        let doc = document()
        let dataSheet = doc.activeSheetID
        doc.selection.select(a("A1"))
        #expect(doc.insertPivotTable(source: CellRange(a1: "A1:B5")!))
        let pivot = try #require(doc.activePivotIndex)
        #expect(doc.pivotPanelIndex == pivot)
        // Off to the source data on its own sheet.
        doc.activeSheetID = dataSheet
        doc.selection.select(a("B3"))
        #expect(doc.activePivotIndex == nil)
        #expect(doc.pivotPanelIndex == pivot)
        // An edit from the panel still lands on the pivot.
        doc.editPivot(pivot, actionName: "Add Field") { d, c in d.place(field: 1, in: .values, cache: c) }
        #expect(doc.workbook.pivotTables[pivot].definition?.dataFields.count == 1)
        // Gone with its sheet.
        doc.activeSheetID = doc.workbook.pivotTables[pivot].sheetID
        doc.confirm = { _, _, _ in true }
        doc.deleteActiveSheet()
        #expect(doc.pivotPanelIndex == nil)
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

    @Test func insertingOnThisSheetAsksBeforeReplacingCells() {
        let doc = document()
        let sheet = doc.activeSheetID
        doc.commitInput("keep", at: a("E10"))
        // The 18 x 3 placeholder from D1 covers D3:F20, E10 included.
        var asked: [String] = []
        doc.confirm = { message, detail, _ in asked.append(message + " " + detail); return false }
        #expect(!doc.insertPivotTable(source: CellRange(a1: "A1:B5")!, destination: .existing(sheetID: sheet, at: a("D1"))))
        #expect(asked.count == 1 && asked[0].contains("E10"))
        #expect(text(doc, "E10") == "keep")
        #expect(doc.workbook.pivotTables.isEmpty && doc.workbook.pivotCaches.isEmpty)
        #expect(doc.undoManager.undoActionName != "Insert PivotTable")

        doc.confirm = { _, _, _ in true }
        #expect(doc.insertPivotTable(source: CellRange(a1: "A1:B5")!, destination: .existing(sheetID: sheet, at: a("D1"))))
        #expect(text(doc, "E10") == "")
        doc.undoManager.undo()
        #expect(text(doc, "E10") == "keep")
        #expect(doc.workbook.pivotTables.isEmpty)
    }

    /// iPad: the question can't block, so the insert is refused, asked, and
    /// run again (once, already answered) if the user agrees.
    @Test func confirmLaterRunsTheCommandAgainOnceAgreed() {
        let doc = document()
        let sheet = doc.activeSheetID
        doc.commitInput("keep", at: a("E10"))
        var proceed: (() -> Void)?
        doc.confirmLater = { message, _, button, go in
            #expect(message.contains("Replace it?") && button == "Replace")
            proceed = go
        }
        #expect(!doc.insertPivotTable(source: CellRange(a1: "A1:B5")!, destination: .existing(sheetID: sheet, at: a("D1"))))
        #expect(text(doc, "E10") == "keep" && doc.workbook.pivotTables.isEmpty)
        proceed?()
        #expect(doc.workbook.pivotTables.count == 1)
        #expect(text(doc, "E10") == "")
        // The answer was for that one command: the next one asks again.
        proceed = nil
        doc.commitInput("again", at: CellAddress(row: 40, column: 4))
        #expect(!doc.insertPivotTable(source: CellRange(a1: "A1:B5")!, destination: .existing(sheetID: sheet, at: a("D30"))))
        #expect(proceed != nil)
    }

    @Test func confirmLaterMergesTheSelectionItWasAskedAbout() {
        let doc = SpreadsheetDocument()
        doc.commitInput("a", at: a("A1"))
        doc.commitInput("b", at: a("B1"))
        var proceed: (() -> Void)?
        doc.confirmLater = { _, _, _, go in proceed = go }
        doc.selection.select(range: CellRange(a1: "A1:B1")!)
        doc.mergeSelection(.merge)
        #expect(doc.activeSheet.mergedRanges.isEmpty)
        doc.selection.select(a("D4")) // must not change what is merged
        proceed?()
        #expect(doc.activeSheet.mergedRanges == [CellRange(a1: "A1:B1")!])
        #expect(text(doc, "B1") == "")
    }

    @Test func insertingOverItsOwnDataIsRefused() {
        let doc = document()
        let sheet = doc.activeSheetID
        doc.confirm = { _, _, _ in Issue.record("shouldn't ask"); return true }
        #expect(!doc.insertPivotTable(source: CellRange(a1: "A1:B5")!, destination: .existing(sheetID: sheet, at: a("B2"))))
        #expect(doc.notice?.message.contains("its own data") == true)
        #expect(text(doc, "B3") == "5" && doc.workbook.pivotTables.isEmpty)
    }

    @Test func insertingOverAnotherPivotIsRefused() {
        let doc = document()
        let sheet = doc.activeSheetID
        #expect(doc.insertPivotTable(source: CellRange(a1: "A1:B5")!, destination: .existing(sheetID: sheet, at: a("D1"))))
        doc.selectSheet(withID: sheet)
        #expect(!doc.insertPivotTable(source: CellRange(a1: "A1:B5")!, destination: .existing(sheetID: sheet, at: a("E5"))))
        #expect(doc.notice?.message.contains("PivotTable1") == true)
        #expect(doc.workbook.pivotTables.count == 1)
    }

    @Test func aFailedInsertLeavesTheUndoStackAlone() {
        let doc = document()
        doc.commitInput("typed", at: a("H1"))
        let before = doc.undoManager.undoActionName
        // A blank heading: the source can't be read.
        #expect(!doc.insertPivotTable(source: CellRange(a1: "A1:C5")!))
        #expect(doc.notice?.message == "Couldn’t create the pivot table.")
        #expect(doc.workbook.sheets.count == 1)
        #expect(text(doc, "H1") == "typed" && doc.undoManager.undoActionName == before)
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
        doc.confirm = { _, _, _ in asked += 1; return false }
        #expect(!doc.editPivot(0, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) })
        #expect(asked == 1)
        #expect(text(doc, "A6") == "keep")
        #expect(doc.workbook.pivotTables[0].definition?.rowFields.isEmpty == true)
        doc.confirm = { _, _, _ in true }
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

    @Test func drawingReadsRolesStoredAtLayoutAndNeverRecomputes() throws {
        let doc = document()
        doc.insertPivotTable(source: CellRange(a1: "A1:B5")!)
        doc.editPivot(0, actionName: "Add Field") { d, c in
            d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c)
        }
        #expect(doc.workbook.pivotTables[0].cellRoles?.isEmpty == false)
        // Make the pivot impossible to compute: drawing must not notice,
        // since it reads the roles stored when the layout was applied.
        let c = doc.workbook.pivotCaches.indices.first!
        doc.workbook.pivotCaches[c].data?.hasRecords = false
        doc.commitInput("unrelated", at: a("H20"))
        #expect(doc.pivotRole(at: a("B4")) == .value)
        #expect(doc.pivotRole(at: a("A7")) == .grandTotalLabel)
        // Moving the table (rows inserted above) keeps roles relative to it.
        doc.workbook.pivotCaches[c].data?.hasRecords = true
        doc.selection.select(a("A1"))
        doc.insertRows(at: 0, count: 2)
        #expect(doc.pivotRole(at: a("B6")) == .value)
    }

    @Test func pivotsFromAFileGetRolesOnFirstDraw() throws {
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
        #expect(reopened.workbook.pivotTables[0].cellRoles == nil)
        #expect(reopened.pivotRole(at: a("B4")) == .value)
        #expect(reopened.workbook.pivotTables[0].cellRoles != nil)
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
