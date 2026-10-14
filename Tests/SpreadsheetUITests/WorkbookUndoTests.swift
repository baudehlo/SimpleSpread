import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Everything an undo of a workbook-level command must put back.
private struct DocState: Equatable {
    struct SheetState: Equatable {
        var id: Int
        var name: String
        var cells: [CellAddress: Cell]
        var columnWidths: [Int: CGFloat]
        var rowHeights: [Int: CGFloat]
        var frozenRows: Int
        var frozenColumns: Int
        var mergedRanges: [CellRange]
        var hiddenRows: Set<Int>
        var autoFilter: AutoFilter?
        var isHidden: Bool
        var usedRange: CellRange?
    }
    struct PivotState: Equatable {
        var sheetID: Int
        var name: String
        var cacheID: Int
        var location: CellRange
        var definition: PivotDefinition?
        var isModified: Bool
        var preservedXML: Data?
    }
    struct CacheState: Equatable {
        var cacheID: Int
        var sources: [PivotSourceRange]
        var fields: [String]?
        var isModified: Bool
    }
    var sheets: [SheetState]
    var styles: [CellStyle]
    var definedNames: [DefinedName]
    var pivots: [PivotState]
    var caches: [CacheState]
    var activeSheetID: Int
    var selection: SelectionState

    @MainActor init(_ doc: SpreadsheetDocument) {
        let wb = doc.workbook
        sheets = wb.sheets.map {
            SheetState(id: $0.id, name: $0.name, cells: $0.cells, columnWidths: $0.columnWidths,
                       rowHeights: $0.rowHeights, frozenRows: $0.frozenRows, frozenColumns: $0.frozenColumns,
                       mergedRanges: $0.mergedRanges, hiddenRows: $0.hiddenRows, autoFilter: $0.autoFilter,
                       isHidden: $0.isHidden, usedRange: $0.usedRange)
        }
        styles = wb.styles.styles
        definedNames = wb.definedNames
        pivots = wb.pivotTables.map {
            PivotState(sheetID: $0.sheetID, name: $0.name, cacheID: $0.cacheID, location: $0.location,
                       definition: $0.definition, isModified: $0.isModified,
                       preservedXML: ($0.payload as? PivotTablePayload)?.definition)
        }
        caches = wb.pivotCaches.map {
            CacheState(cacheID: $0.cacheID, sources: $0.sourceRanges, fields: $0.data?.fields.map(\.name),
                       isModified: $0.isModified)
        }
        activeSheetID = doc.activeSheetID
        selection = doc.selection
    }
}

@MainActor
@Suite("Workbook-level undo")
struct WorkbookUndoTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    /// Two visible sheets, a hidden one, formulas across sheets, styles,
    /// layout, defined names, a pivot SimpleSpread made (parsed, editable)
    /// and one kept from a file as raw XML (preserve-only).
    func richDocument() -> SpreadsheetDocument {
        let wb = Workbook()
        let main = wb.addSheet(named: "Main")
        let data = wb.addSheet(named: "Data")
        let secret = wb.addSheet(named: "Secret")
        secret.isHidden = true
        secret.setCell(Cell(value: .number(7)), at: a("A1"))
        let bold = wb.styleIndex(for: CellStyle(bold: true))
        for (i, row) in [("Region", "Units"), ("East", "10"), ("West", "5"), ("East", "7"), ("North", "2")].enumerated() {
            data.setCell(Cell(value: .string(row.0), styleIndex: i == 0 ? bold : 0), at: CellAddress(row: i, column: 0))
            data.setCell(Cell(value: Double(row.1).map(CellValue.number) ?? .string(row.1)), at: CellAddress(row: i, column: 1))
        }
        main.setCell(Cell(value: .number(3), styleIndex: bold), at: a("A1"))
        main.setCell(Cell(value: .number(4)), at: a("A2"))
        main.setCell(Cell(formula: "SUM(A1:A2)"), at: a("A3"))
        main.setCell(Cell(formula: "SUM(Data!B2:B5)+Secret!A1"), at: a("B1"))
        main.setCell(Cell(formula: "Rate*2"), at: a("C1"))
        main.setCell(Cell(value: .string("merged")), at: a("D5"))
        main.mergedRanges = [r("D5:E6")]
        main.hiddenRows = [8]
        main.rowHeights = [2: 40, 9: 30]
        main.columnWidths = [1: 150]
        main.frozenRows = 1
        main.frozenColumns = 1
        main.autoFilter = AutoFilter(range: r("A1:B6"))
        data.setCell(Cell(formula: "Main!A3*10"), at: a("C1"))
        wb.definedNames = [
            DefinedName(name: "Rate", scopeSheetID: nil, formula: "Main!$A$1", hidden: false),
            DefinedName(name: "Local", scopeSheetID: data.id, formula: "Data!$B$2:$B$5", hidden: false),
        ]
        // A pivot kept from a file, unread: SimpleSpread writes its XML back as it was.
        let xml = Data("<pivotTableDefinition name=\"Kept\"><location ref=\"H20:I22\"/></pivotTableDefinition>".utf8)
        wb.pivotCaches = [PivotCache(cacheID: 9, sourceRanges: [PivotSourceRange(target: .sheet(id: data.id), ref: "A1:B5")],
                                     payload: PivotCachePayload(definition: Data("<pivotCacheDefinition/>".utf8),
                                                                records: nil, externalRelationships: []))]
        wb.pivotTables = [PivotTable(sheetID: data.id, name: "Kept", cacheID: 9, location: r("H20:I22"),
                                     payload: PivotTablePayload(definition: xml))]
        wb.preservedStyles = PreservedStyles()
        let doc = SpreadsheetDocument(workbook: wb)
        // A parsed pivot of its own, on a new sheet.
        doc.selectSheet(withID: data.id)
        #expect(doc.insertPivotTable(source: r("A1:B5")))
        #expect(doc.editPivot(1, actionName: "Add Field") { d, c in
            d.place(field: 0, in: .rows, cache: c); d.place(field: 1, in: .values, cache: c)
        })
        doc.selectSheet(withID: main.id)
        doc.selection.select(a("B2"))
        doc.undoManager.removeAllActions()
        #expect(doc.activeSheet.value(at: a("B1")) == .number(31))
        #expect(doc.activeSheet.value(at: a("C1")) == .number(6))
        return doc
    }

    /// Run `command`, then check undo and redo put back exactly the state
    /// before and after it, several times over.
    func checkUndoRedo(_ doc: SpreadsheetDocument, actionName: String,
                       sourceLocation: SourceLocation = #_sourceLocation,
                       _ command: () throws -> Void) rethrows {
        let before = DocState(doc)
        try command()
        let after = DocState(doc)
        #expect(after != before, "the command changed nothing", sourceLocation: sourceLocation)
        #expect(doc.undoManager.undoActionName == actionName, sourceLocation: sourceLocation)
        for _ in 0..<3 {
            doc.undoManager.undo()
            #expect(DocState(doc) == before, "undo", sourceLocation: sourceLocation)
            #expect(doc.undoManager.redoActionName == actionName, sourceLocation: sourceLocation)
            doc.undoManager.redo()
            #expect(DocState(doc) == after, "redo", sourceLocation: sourceLocation)
        }
        doc.undoManager.undo()
        #expect(DocState(doc) == before, sourceLocation: sourceLocation)
        // The engine is live after the restore: an edit still recalculates.
        let mainID = doc.workbook.sheet(named: "Main")!.id
        doc.selectSheet(withID: mainID)
        doc.commitInput("100", at: a("A2"))
        #expect(doc.activeSheet.value(at: a("A3")) == .number(103), sourceLocation: sourceLocation)
        #expect(doc.workbook.sheet(named: "Data")?.value(at: a("C1")) == .number(1030), sourceLocation: sourceLocation)
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("A3")) == .number(7), sourceLocation: sourceLocation)
    }

    @Test func insertAndDeleteRowsAndColumns() {
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Insert Rows") { doc.insertRows(at: 1, count: 2) }
        }
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Delete Rows") { doc.deleteRows(at: 1) }
        }
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Insert Columns") { doc.insertColumns(at: 0) }
        }
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Delete Columns") { doc.deleteColumns(at: 4) }
        }
        do {
            // Data's rows: the formulas on Main that read them are rewritten.
            let doc = richDocument()
            doc.selectSheet(withID: doc.workbook.sheet(named: "Data")!.id)
            checkUndoRedo(doc, actionName: "Delete Rows") { doc.deleteRows(at: 2) }
        }
    }

    @Test func sheetCommands() throws {
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Add Sheet") { doc.addSheet() }
        }
        do {
            let doc = richDocument()
            doc.selectSheet(withID: doc.workbook.sheet(named: "Data")!.id)
            checkUndoRedo(doc, actionName: "Delete Sheet") { doc.deleteActiveSheet() }
        }
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Rename Sheet") { doc.renameActiveSheet(to: "Front Page") }
        }
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Reorder Sheets") {
                doc.moveSheet(withID: doc.workbook.sheet(named: "Main")!.id, to: 3)
            }
        }
        do {
            let doc = richDocument()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString).csv")
            try Data("x,y\n1,2\n".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try checkUndoRedo(doc, actionName: "Import CSV") { try doc.importCSVSheet(from: url) }
        }
    }

    @Test func pivotCommands() {
        do {
            let doc = richDocument()
            doc.selectSheet(withID: doc.workbook.sheet(named: "Data")!.id)
            checkUndoRedo(doc, actionName: "Insert PivotTable") { doc.insertPivotTable(source: r("A1:B5")) }
        }
        do {
            let doc = richDocument()
            checkUndoRedo(doc, actionName: "Remove Field") {
                #expect(doc.editPivot(1, actionName: "Remove Field") { d, _ in d.removeFromAxes(0) })
            }
        }
        do {
            let doc = richDocument()
            let mainID = doc.activeSheetID
            doc.selectSheet(withID: doc.workbook.sheet(named: "Data")!.id)
            doc.commitInput("50", at: a("B3"))
            doc.selectSheet(withID: mainID)
            checkUndoRedo(doc, actionName: "Refresh") { #expect(doc.refreshPivot(1)) }
        }
        do {
            // Delete over a whole pivot removes it.
            let doc = richDocument()
            let pivotSheet = doc.workbook.pivotTables[1].sheetID
            doc.selectSheet(withID: pivotSheet)
            doc.selection.select(range: doc.workbook.pivotTables[1].occupiedRange)
            checkUndoRedo(doc, actionName: "Delete") { doc.clearSelectionContents() }
        }
    }

    @Test func pivotsStayEditableAcrossUndoAndRedo() {
        let doc = richDocument()
        #expect(doc.pivotEditBlocker(1) == nil)
        #expect(doc.editPivot(1, actionName: "Remove Field") { d, _ in d.removeFromAxes(0) })
        doc.undoManager.undo()
        #expect(doc.workbook.pivotTables[1].definition != nil)
        #expect(doc.pivotEditBlocker(1) == nil)
        doc.undoManager.redo()
        #expect(doc.pivotEditBlocker(1) == nil)
        // Still editable: another change goes through and lays out.
        #expect(doc.editPivot(1, actionName: "Add Field") { d, c in d.place(field: 0, in: .rows, cache: c) })
        #expect(doc.undoManager.undoActionName == "Add Field")
        // The preserved pivot kept its XML throughout.
        #expect((doc.workbook.pivotTables[0].payload as? PivotTablePayload)?.definition
            == Data("<pivotTableDefinition name=\"Kept\"><location ref=\"H20:I22\"/></pivotTableDefinition>".utf8))
        #expect(doc.workbook.pivotTables[0].definition == nil)
    }

    @Test func whatTheFileWriterDropsSurvivesUndo() {
        let doc = richDocument()
        doc.insertRows(at: 0)
        doc.undoManager.undo()
        let wb = doc.workbook
        #expect(wb.sheet(named: "Secret")?.isHidden == true)
        #expect(wb.definedNames.map(\.name) == ["Rate", "Local"])
        #expect(wb.definedNames[0].formula == "Main!$A$1")
        #expect(wb.pivotTables.count == 2 && wb.pivotTables[0].definition == nil)
        #expect((wb.pivotTables[0].payload as? PivotTablePayload) != nil)
        #expect(doc.activeSheet.value(at: a("C1")) == .number(6)) // the name still resolves
    }

    @Test func cellUndoRecordsStillApplyAcrossStructuralUndo() {
        let doc = richDocument()
        let mainID = doc.activeSheetID
        let dataID = doc.workbook.sheet(named: "Data")!.id
        doc.commitInput("1", at: a("F1"))                      // 1
        doc.insertRows(at: 0)                                  // 2: F1 -> F2
        doc.commitInput("2", at: a("F1"))                      // 3
        doc.selectSheet(withID: dataID)
        doc.commitInput("9", at: a("B2"))                      // 4
        doc.deleteActiveSheet()                                // 5
        doc.renameActiveSheet(to: "Renamed")                   // 6 (the sheet now active)
        doc.commitInput("x", at: a("G1"))                      // 7
        let final = DocState(doc)
        var states: [DocState] = []
        for _ in 0..<7 {
            states.append(DocState(doc))
            doc.undoManager.undo()
        }
        #expect(!doc.undoManager.canUndo)
        let main = doc.workbook.sheet(withID: mainID)!
        #expect(main.value(at: a("F1")) == .empty && main.value(at: a("F2")) == .empty)
        #expect(doc.workbook.sheet(withID: dataID)?.value(at: a("B2")) == .number(10))
        #expect(main.value(at: a("B1")) == .number(31))
        for expected in states.reversed() {
            doc.undoManager.redo()
            #expect(DocState(doc) == expected)
        }
        #expect(DocState(doc) == final)
        #expect(!doc.undoManager.canRedo)
    }

    @Test func aFailedImportLeavesTheUndoStackAlone() {
        let doc = richDocument()
        doc.commitInput("x", at: a("F1"))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).csv")
        #expect(throws: (any Error).self) { try doc.importCSVSheet(from: missing) }
        #expect(doc.undoManager.undoActionName == "Typing")
        #expect(doc.workbook.sheets.count == 4)
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("F1")) == .empty)
    }

    @Test func insertRowUndoRedoOnABigSheetIsFast() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        for r in 0..<20_000 {
            for c in 0..<10 { sheet.setCell(Cell(value: .number(Double(r * 10 + c))), at: CellAddress(row: r, column: c)) }
        }
        let doc = SpreadsheetDocument(workbook: wb)
        let start = Date()
        doc.insertRows(at: 5)
        let inserted = Date()
        doc.undoManager.undo()
        let undone = Date()
        doc.undoManager.redo()
        let end = Date()
        print("200k cells: insert \(inserted.timeIntervalSince(start)) s, undo \(undone.timeIntervalSince(inserted)) s, redo \(end.timeIntervalSince(undone)) s")
        #expect(doc.activeSheet.value(at: a("A7")) == .number(50))
        // ~0.13 s alone (debug), more under a parallel test run; 2.5 s alone
        // with the XLSX snapshot undo this replaced.
        #expect(end.timeIntervalSince(start) < 1.5)
    }
}
