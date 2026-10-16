#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// The grid's editor, key handling and Edit-menu actions, driven without a
/// window (as the code review reproduced #7 and #39).
@MainActor
@Suite("Grid editing")
struct GridEditingTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    func makeGrid() -> (SpreadsheetDocument, SpreadsheetGridView) {
        let doc = SpreadsheetDocument()
        let grid = SpreadsheetGridView()
        grid.document = doc
        return (doc, grid)
    }

    func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    // MARK: The editor's target (#7)

    @Test func editCommitsToTheSheetItWasTypedOn() {
        let (doc, grid) = makeGrid()
        let sheet1 = doc.activeSheetID
        doc.selection.select(a("A1"))
        grid.beginEditing(mode: .enter, initialText: "typed on sheet1")
        #expect(doc.hasPendingEdit)
        doc.addSheet() // click the + tab while typing
        #expect(!grid.isEditing)
        #expect(doc.workbook.sheet(withID: sheet1)?.value(at: a("A1")) == .string("typed on sheet1"))
        #expect(doc.activeSheet.value(at: a("A1")) == .empty)
    }

    @Test func switchingSheetsCommitsTheEditWhereItWasTyped() {
        let (doc, grid) = makeGrid()
        let sheet1 = doc.activeSheetID
        let sheet2 = doc.workbook.addSheet().id
        doc.selection.select(a("B2"))
        grid.beginEditing(mode: .enter, initialText: "hello")
        doc.selectSheet(withID: sheet2)
        #expect(!doc.hasPendingEdit)
        #expect(doc.workbook.sheet(withID: sheet1)?.value(at: a("B2")) == .string("hello"))
        #expect(doc.workbook.sheet(withID: sheet2)?.value(at: a("B2")) == .empty)
    }

    @Test func aLateCommitStillLandsOnTheEditorsSheet() {
        // Even if something switches the sheet without the choke point.
        let (doc, grid) = makeGrid()
        let sheet1 = doc.activeSheetID
        let sheet2 = doc.workbook.addSheet().id
        doc.selection.select(a("A1"))
        grid.beginEditing(mode: .enter, initialText: "x")
        doc.activeSheetID = sheet2
        grid.commitEditorIfNeeded()
        #expect(doc.workbook.sheet(withID: sheet1)?.value(at: a("A1")) == .string("x"))
        #expect(doc.workbook.sheet(withID: sheet2)?.value(at: a("A1")) == .empty)
    }

    @Test func insertingRowsCommitsTheEditFirst() {
        let (doc, grid) = makeGrid()
        doc.selection.select(a("A5"))
        grid.beginEditing(mode: .enter, initialText: "row five")
        doc.insertRows(at: 4)
        // Typed into A5, then the row moved down with everything else.
        #expect(doc.activeSheet.value(at: a("A6")) == .string("row five"))
        #expect(doc.activeSheet.value(at: a("A5")) == .empty)
    }

    @Test func savingCommitsTheEdit() throws {
        let (doc, grid) = makeGrid()
        doc.selection.select(a("C3"))
        grid.beginEditing(mode: .enter, initialText: "42")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-edit-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        #expect(!grid.isEditing)
        #expect(!doc.isModified)
        let reopened = try SpreadsheetDocument.open(url: url)
        #expect(reopened.activeSheet.value(at: a("C3")) == .number(42))
    }

    @Test func fillAndPasteCommitTheEditFirst() {
        let (doc, grid) = makeGrid()
        doc.selection.select(a("A1"))
        grid.beginEditing(mode: .enter, initialText: "7")
        doc.selection.select(range: CellRange(a1: "A1:A3")!)
        doc.fillDown()
        #expect(doc.activeSheet.value(at: a("A3")) == .number(7))
    }

    @Test func cancelLeavesTheCellAlone() {
        let (doc, grid) = makeGrid()
        doc.commitInput("old", at: a("A1"))
        doc.selection.select(a("A1"))
        grid.beginEditing(mode: .edit, initialText: "new")
        grid.cancelEditing()
        #expect(!doc.hasPendingEdit)
        doc.commitPendingEdit()
        #expect(doc.activeSheet.value(at: a("A1")) == .string("old"))
    }

    // MARK: Formula bar (#7)

    @Test func formulaBarTypingIsCommittedWhereItWasTyped() {
        let doc = SpreadsheetDocument()
        let bar = FormulaBarEditor()
        bar.document = doc
        doc.selection.select(a("B2"))
        bar.sync()
        bar.userEdited("=1+1")
        #expect(doc.hasPendingEdit)
        // The user clicks another cell: the typing goes to B2, as in Excel.
        doc.selection.select(a("D4"))
        doc.commitPendingEdit()
        #expect(doc.activeSheet.value(at: a("B2")) == .number(2))
        #expect(doc.activeSheet.value(at: a("D4")) == .empty)
        #expect(!doc.hasPendingEdit)
    }

    @Test func formulaBarFocusWithoutTypingChangesNothing() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1.50", at: a("A1"))
        let bar = FormulaBarEditor()
        bar.document = doc
        doc.selection.select(a("A1"))
        bar.sync()
        #expect(!doc.hasPendingEdit)
        let revision = doc.revision
        bar.endEditing()
        #expect(doc.revision == revision)
        #expect(doc.activeSheet.value(at: a("A1")) == .number(1.5))
    }

    @Test func formulaBarCancelRestoresTheCell() {
        let doc = SpreadsheetDocument()
        doc.commitInput("keep", at: a("A1"))
        let bar = FormulaBarEditor()
        bar.document = doc
        doc.selection.select(a("A1"))
        bar.sync()
        bar.userEdited("lose")
        bar.cancel()
        #expect(bar.text == "keep")
        doc.commitPendingEdit()
        #expect(doc.activeSheet.value(at: a("A1")) == .string("keep"))
    }

    // MARK: Keyboard (#39)

    @Test func endHelpAndFunctionKeysDoNotStartAnEdit() {
        let (doc, grid) = makeGrid()
        doc.selection.select(a("A1"))
        let keys: [(String, UInt16)] = [
            (String(UnicodeScalar(NSEndFunctionKey)!), 119),
            (String(UnicodeScalar(NSHelpFunctionKey)!), 114),
            (String(UnicodeScalar(NSF5FunctionKey)!), 96),
            (String(UnicodeScalar(NSF13FunctionKey)!), 105),
        ]
        for (chars, code) in keys {
            grid.keyDown(with: key(chars, keyCode: code))
            #expect(!grid.isEditing, "key \(code) started an edit")
        }
        // An arrow afterwards must not write a private-use character.
        grid.keyDown(with: key(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125))
        #expect(doc.activeSheet.value(at: a("A1")) == .empty)
    }

    @Test func typingAPrintableKeyStartsAnEdit() {
        let (doc, grid) = makeGrid()
        doc.selection.select(a("A1"))
        grid.keyDown(with: key("q", keyCode: 12))
        #expect(grid.isEditing)
        #expect(grid.editMode == .enter)
        grid.commitEditorIfNeeded()
        #expect(doc.activeSheet.value(at: a("A1")) == .string("q"))
    }

    @Test func controlCharactersDoNotStartAnEdit() {
        let (_, grid) = makeGrid()
        grid.keyDown(with: key("\u{1}", keyCode: 0, flags: .control))
        #expect(!grid.isEditing)
    }

    // MARK: Edit menu through the responder chain (#6)

    @Test func gridAnswersTheStandardEditActions() {
        let (doc, grid) = makeGrid()
        doc.commitInput("1", at: a("A1"))
        doc.commitInput("2", at: a("B3"))
        grid.selectAll(nil)
        #expect(doc.selection.range == CellRange(a1: "A1:B3"))
        grid.delete(nil)
        #expect(doc.activeSheet.value(at: a("B3")) == .empty)
        grid.undo(nil)
        #expect(doc.activeSheet.value(at: a("B3")) == .number(2))
        grid.redo(nil)
        #expect(doc.activeSheet.value(at: a("B3")) == .empty)
    }

    @Test func undoMenuItemIsValidatedAgainstTheDocument() {
        let (doc, grid) = makeGrid()
        let undoItem = NSMenuItem(title: "Undo", action: #selector(SpreadsheetGridView.undo(_:)), keyEquivalent: "z")
        #expect(!grid.validateMenuItem(undoItem))
        doc.commitInput("x", at: a("A1"))
        #expect(grid.validateMenuItem(undoItem))
        #expect(undoItem.title == "Undo Typing")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(SpreadsheetGridView.copy(_:)), keyEquivalent: "c")
        #expect(grid.validateMenuItem(copyItem))
    }

    /// ⌘D on one row copies the row above (⌘R: the column to the left), as
    /// Excel does; the selection stays put.
    @Test func fillDownAndRightFromASingleRowOrColumn() {
        let doc = SpreadsheetDocument()
        doc.commitInput("7", at: CellAddress(a1: "B2")!)
        doc.commitInput("=B2*2", at: CellAddress(a1: "C2")!)
        doc.selection.select(range: CellRange(a1: "B3:C3")!)
        doc.fillDown()
        #expect(doc.displayString(at: CellAddress(a1: "B3")!) == "7")
        #expect(doc.activeSheet.cell(at: CellAddress(a1: "C3")!).formula == "B3*2")
        #expect(doc.selection.range == CellRange(a1: "B3:C3")!)
        doc.selection.select(CellAddress(a1: "D2")!)
        doc.fillRight()
        #expect(doc.activeSheet.cell(at: CellAddress(a1: "D2")!).formula == "C2*2")
        #expect(doc.selection.activeCell == CellAddress(a1: "D2")!)
        // Nothing above row 1, nothing left of column A.
        doc.selection.select(CellAddress(a1: "A1")!)
        let revision = doc.revision
        doc.fillDown()
        doc.fillRight()
        #expect(doc.revision == revision)
    }
}
#endif
