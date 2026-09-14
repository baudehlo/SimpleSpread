import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

@MainActor
@Suite("Spreadsheet document")
struct DocumentTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    @Test func commitInputParsesTypes() {
        let doc = SpreadsheetDocument()
        doc.commitInput("42", at: a("A1"))
        doc.commitInput("hello", at: a("A2"))
        doc.commitInput("=A1*2", at: a("A3"))
        doc.commitInput("5%", at: a("A4"))
        doc.commitInput("TRUE", at: a("A5"))
        #expect(doc.activeSheet.value(at: a("A1")) == .number(42))
        #expect(doc.activeSheet.value(at: a("A2")) == .string("hello"))
        #expect(doc.activeSheet.value(at: a("A3")) == .number(84))
        #expect(doc.activeSheet.value(at: a("A4")) == .number(0.05))
        #expect(doc.style(at: a("A4")).numberFormat == .percentInteger)
        #expect(doc.activeSheet.value(at: a("A5")) == .bool(true))
        #expect(doc.isModified)
    }

    @Test func formulaRecalculationOnEdit() {
        let doc = SpreadsheetDocument()
        doc.commitInput("10", at: a("A1"))
        doc.commitInput("=A1+5", at: a("B1"))
        #expect(doc.activeSheet.value(at: a("B1")) == .number(15))
        doc.commitInput("20", at: a("A1"))
        #expect(doc.activeSheet.value(at: a("B1")) == .number(25))
    }

    @Test func displayAndEditStrings() {
        let doc = SpreadsheetDocument()
        doc.commitInput("=1+1", at: a("A1"))
        #expect(doc.displayString(at: a("A1")) == "2")
        #expect(doc.editString(at: a("A1")) == "=1+1")
        doc.commitInput("1/2/2026", at: a("A2"))
        #expect(doc.displayString(at: a("A2")) == "1/2/2026")
        #expect(doc.editString(at: a("A2")) == "1/2/2026") // re-parseable form
        doc.commitInput("'=not formula", at: a("A3"))
        #expect(doc.displayString(at: a("A3")) == "=not formula")
        #expect(doc.editString(at: a("A3")) == "'=not formula")
        doc.commitInput("00501", at: a("A4"))
        // Leading-zero strings re-parse as text anyway; no apostrophe needed.
        #expect(doc.editString(at: a("A4")) == "00501")
    }

    @Test func plainTextFormatSuppressesParsing() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("A1"))
        doc.setNumberFormat(.text)
        doc.commitInput("=1+1", at: a("A1"))
        #expect(doc.activeSheet.value(at: a("A1")) == .string("=1+1"))
    }

    @Test func undoRedoTyping() {
        let doc = SpreadsheetDocument()
        doc.commitInput("first", at: a("A1"))
        doc.commitInput("second", at: a("A1"))
        #expect(doc.activeSheet.value(at: a("A1")) == .string("second"))
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("A1")) == .string("first"))
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("A1")) == .empty)
        doc.undoManager.redo()
        #expect(doc.activeSheet.value(at: a("A1")) == .string("first"))
        doc.undoManager.redo()
        #expect(doc.activeSheet.value(at: a("A1")) == .string("second"))
    }

    @Test func undoRestoresFormulasAndDependents() {
        let doc = SpreadsheetDocument()
        doc.commitInput("5", at: a("A1"))
        doc.commitInput("=A1*2", at: a("B1"))
        doc.commitInput("7", at: a("A1"))
        #expect(doc.activeSheet.value(at: a("B1")) == .number(14))
        doc.undoManager.undo() // A1 back to 5
        #expect(doc.activeSheet.value(at: a("B1")) == .number(10)) // dependent recalculated
    }

    @Test func clearSelectionKeepsFormatting() {
        let doc = SpreadsheetDocument()
        doc.commitInput("x", at: a("A1"))
        doc.selection.select(a("A1"))
        doc.toggleBold()
        doc.clearSelectionContents()
        #expect(doc.activeSheet.value(at: a("A1")) == .empty)
        #expect(doc.style(at: a("A1")).bold) // format survives Delete
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("A1")) == .string("x"))
    }

    @Test func styleUndo() {
        let doc = SpreadsheetDocument()
        doc.commitInput("x", at: a("A1"))
        doc.selection.select(a("A1"))
        doc.toggleBold()
        #expect(doc.style(at: a("A1")).bold)
        doc.undoManager.undo()
        #expect(!doc.style(at: a("A1")).bold)
    }

    @Test func rangeStyleApplication() {
        let doc = SpreadsheetDocument()
        doc.selection.select(range: CellRange(a1: "A1:B2")!)
        doc.setNumberFormat(.percent)
        #expect(doc.style(at: a("B2")).numberFormat == .percent)
        #expect(doc.style(at: a("C3")).numberFormat == .general)
    }

    @Test func insertDeleteRowsWithUndo() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        doc.commitInput("2", at: a("A2"))
        doc.commitInput("=SUM(A1:A2)", at: a("A3"))
        doc.insertRows(at: 1, count: 1)
        #expect(doc.activeSheet.value(at: a("A1")) == .number(1))
        #expect(doc.activeSheet.value(at: a("A3")) == .number(2))
        #expect(doc.activeSheet.cell(at: a("A4")).formula == "SUM(A1:A3)")
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("A2")) == .number(2))
        #expect(doc.activeSheet.cell(at: a("A3")).formula == "SUM(A1:A2)")
        #expect(doc.activeSheet.value(at: a("A3")) == .number(3))
    }

    @Test func sheetLifecycleWithUndo() {
        let doc = SpreadsheetDocument()
        doc.commitInput("keep", at: a("A1"))
        doc.addSheet()
        #expect(doc.workbook.sheets.count == 2)
        #expect(doc.activeSheetID == doc.workbook.sheets[1].id)
        doc.commitInput("second sheet", at: a("A1"))
        doc.deleteActiveSheet()
        #expect(doc.workbook.sheets.count == 1)
        #expect(doc.activeSheet.value(at: a("A1")) == .string("keep"))
        doc.undoManager.undo() // restore deleted sheet
        #expect(doc.workbook.sheets.count == 2)
        #expect(doc.workbook.sheets[1].value(at: a("A1")) == .string("second sheet"))
    }

    @Test func renameSheetRewritesReferences() {
        let doc = SpreadsheetDocument()
        doc.addSheet() // Sheet2
        let sheet2ID = doc.activeSheetID
        doc.commitInput("99", at: a("A1"))
        doc.selectSheet(withID: doc.workbook.sheets[0].id)
        doc.commitInput("=Sheet2!A1", at: a("B1"))
        #expect(doc.activeSheet.value(at: a("B1")) == .number(99))
        doc.selectSheet(withID: sheet2ID)
        doc.renameActiveSheet(to: "Data Store")
        doc.selectSheet(withID: doc.workbook.sheets[0].id)
        #expect(doc.activeSheet.cell(at: a("B1")).formula == "'Data Store'!A1")
        #expect(doc.activeSheet.value(at: a("B1")) == .number(99))
    }

    @Test func zoomControls() {
        let doc = SpreadsheetDocument()
        #expect(doc.zoomLevel == 1.0)
        doc.zoomIn()
        #expect(abs(doc.zoomLevel - 1.25) < 0.0001)
        doc.zoomOut()
        #expect(abs(doc.zoomLevel - 1.0) < 0.0001)
        doc.setZoom(10)
        #expect(doc.zoomLevel == SpreadsheetDocument.zoomRange.upperBound)
        doc.setZoom(0.01)
        #expect(doc.zoomLevel == SpreadsheetDocument.zoomRange.lowerBound)
        doc.zoomOut() // clamped at the floor
        #expect(doc.zoomLevel == SpreadsheetDocument.zoomRange.lowerBound)
        doc.resetZoom()
        #expect(doc.zoomLevel == 1.0)
    }

    @Test func findMatchesValuesAndFormulas() {
        let doc = SpreadsheetDocument()
        doc.commitInput("apple", at: a("A1"))
        doc.commitInput("banana", at: a("A2"))
        doc.commitInput("Apple pie", at: a("A3"))
        doc.commitInput("10", at: a("B1"))
        doc.presentFind()
        doc.setFindQuery("apple")
        // Case-insensitive; matches A1 and A3, in row-major order.
        #expect(doc.findMatches == [a("A1"), a("A3")])
        #expect(doc.findStatus == "1 of 2")
        #expect(doc.selection.activeCell == a("A1"))
        doc.findNext()
        #expect(doc.selection.activeCell == a("A3"))
        #expect(doc.findStatus == "2 of 2")
        doc.findNext() // wraps
        #expect(doc.selection.activeCell == a("A1"))
        doc.findPrevious() // wraps back
        #expect(doc.selection.activeCell == a("A3"))
    }

    @Test func findMatchesComputedFormulaValue() {
        let doc = SpreadsheetDocument()
        doc.commitInput("apple", at: a("A1"))
        doc.commitInput("=A1", at: a("C1")) // displays "apple"
        doc.setFindQuery("apple")
        // Both the literal and the formula cell (by its displayed value) match.
        #expect(doc.findMatches == [a("A1"), a("C1")])
    }

    @Test func findMatchesFormulaText() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        doc.commitInput("=SUM(A1:A5)", at: a("B1"))
        doc.setFindQuery("sum")
        #expect(doc.findMatches == [a("B1")])
    }

    @Test func findNoResults() {
        let doc = SpreadsheetDocument()
        doc.commitInput("hello", at: a("A1"))
        doc.setFindQuery("zzz")
        #expect(doc.findMatches.isEmpty)
        #expect(doc.findStatus == "No results")
        doc.findNext() // no crash, no selection change
        #expect(doc.selection.activeCell == a("A1"))
    }

    @Test func findStartsFromSelection() {
        let doc = SpreadsheetDocument()
        for r in 1...5 { doc.commitInput("x", at: a("A\(r)")) }
        doc.selection.select(a("A3"))
        doc.setFindQuery("x")
        // First match at or after A3.
        #expect(doc.selection.activeCell == a("A3"))
        #expect(doc.findStatus == "3 of 5")
    }

    @Test func findScrollRequestBumps() {
        let doc = SpreadsheetDocument()
        doc.commitInput("target", at: a("Z40"))
        let before = doc.scrollTick
        doc.setFindQuery("target")
        #expect(doc.scrollTick > before)
        #expect(doc.selection.activeCell == a("Z40"))
    }

    @Test func selectionStatistics() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        doc.commitInput("2", at: a("A2"))
        doc.commitInput("x", at: a("A3"))
        doc.selection.select(range: CellRange(a1: "A1:A3")!)
        let stats = doc.selectionStatistics()
        #expect(stats.count == 3)
        #expect(stats.numericCount == 2)
        #expect(stats.sum == 3)
        #expect(stats.average == 1.5)
    }

    @Test func saveAndReopen() throws {
        let doc = SpreadsheetDocument()
        doc.commitInput("42", at: a("A1"))
        doc.commitInput("=A1*2", at: a("B1"))
        doc.selection.select(a("A1"))
        doc.toggleBold()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplespread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.xlsx")
        try doc.save(to: url)
        #expect(!doc.isModified)
        #expect(doc.fileURL == url)

        let reopened = try SpreadsheetDocument.open(url: url)
        #expect(reopened.activeSheet.value(at: a("A1")) == .number(42))
        #expect(reopened.activeSheet.cell(at: a("B1")).formula == "A1*2")
        #expect(reopened.activeSheet.value(at: a("B1")) == .number(84))
        #expect(reopened.style(at: a("A1")).bold)
    }

    @Test func openCSVBecomesUntitledWorkbook() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplespread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pricing.csv")
        try Data("a,b\n1,2\n".utf8).write(to: url)
        let doc = try SpreadsheetDocument.open(url: url)
        // CSV import: never write back to the .csv — force Save-As to XLSX.
        #expect(doc.fileURL == nil)
        #expect(doc.suggestedFileName == "pricing.xlsx")
        #expect(doc.saveFileName == "pricing.xlsx")
        #expect(doc.displayName == "pricing")
        #expect(doc.activeSheet.value(at: a("A2")) == .number(1))
        #expect(doc.workbook.sheets[0].name == "pricing")
    }

    @Test func openTSVAndTXTAlsoImport() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplespread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Tab-separated with a .tsv extension.
        let tsv = dir.appendingPathComponent("grid.tsv")
        try Data("x\ty\n3\t4\n".utf8).write(to: tsv)
        let tdoc = try SpreadsheetDocument.open(url: tsv)
        #expect(tdoc.fileURL == nil)
        #expect(tdoc.suggestedFileName == "grid.xlsx")
        #expect(tdoc.activeSheet.value(at: a("A2")) == .number(3))
        #expect(tdoc.activeSheet.value(at: a("B2")) == .number(4))
        // Comma data mislabeled .txt still imports (delimiter sniffed).
        let txt = dir.appendingPathComponent("list.txt")
        try Data("m,n\n5,6\n".utf8).write(to: txt)
        let xdoc = try SpreadsheetDocument.open(url: txt)
        #expect(xdoc.suggestedFileName == "list.xlsx")
        #expect(xdoc.activeSheet.value(at: a("B2")) == .number(6))
    }

    @Test func csvOpenThenSaveGoesToXLSX() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplespread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = dir.appendingPathComponent("report.csv")
        try Data("h\n9\n".utf8).write(to: csv)
        let doc = try SpreadsheetDocument.open(url: csv)
        // Simulate the Save-As the UI forces (fileURL is nil so ⌘S routes here).
        let xlsx = dir.appendingPathComponent(doc.saveFileName)
        #expect(xlsx.lastPathComponent == "report.xlsx")
        try doc.save(to: xlsx)
        // The original CSV is untouched; now bound to the XLSX for future saves.
        #expect(doc.fileURL == xlsx)
        #expect(doc.suggestedFileName == nil)
        #expect(FileManager.default.fileExists(atPath: csv.path))
        let reopened = try SpreadsheetDocument.open(url: xlsx)
        #expect(reopened.fileURL == xlsx) // XLSX opens bound to its file
        #expect(reopened.activeSheet.value(at: a("A2")) == .number(9))
    }

    @Test func csvSheetImportAndExport() throws {
        let doc = SpreadsheetDocument()
        doc.commitInput("x", at: a("A1"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplespread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let csvURL = dir.appendingPathComponent("import me.csv")
        try Data("h1,h2\n5,6\n".utf8).write(to: csvURL)
        try doc.importCSVSheet(from: csvURL)
        #expect(doc.workbook.sheets.count == 2)
        #expect(doc.activeSheet.name == "import me")
        #expect(doc.activeSheet.value(at: a("B2")) == .number(6))

        let outURL = dir.appendingPathComponent("out.csv")
        try doc.exportActiveSheetCSV(to: outURL)
        let text = CSV.decode(data: try Data(contentsOf: outURL))
        #expect(text == "h1,h2\r\n5,6\r\n")
    }
}

@MainActor
@Suite("Clipboard & fill")
struct ClipboardFillTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    @Test func tsvGeneration() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        doc.commitInput("two", at: a("B1"))
        doc.commitInput("3", at: a("A2"))
        doc.selection.select(range: CellRange(a1: "A1:B2")!)
        #expect(doc.selectionTSV() == "1\ttwo\n3\t")
    }

    @Test func internalPasteAdjustsRelativeReferences() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        doc.commitInput("2", at: a("A2"))
        doc.commitInput("=SUM(A1:A2)", at: a("A3"))
        doc.selection.select(a("A3"))
        let payload = doc.selectionPayload()
        doc.selection.select(a("B3"))
        doc.paste(payload: payload, sourceOrigin: a("A3"))
        #expect(doc.activeSheet.cell(at: a("B3")).formula == "SUM(B1:B2)")
        doc.commitInput("10", at: a("B1"))
        doc.commitInput("20", at: a("B2"))
        #expect(doc.activeSheet.value(at: a("B3")) == .number(30))
    }

    @Test func pasteCarriesStyles() {
        let doc = SpreadsheetDocument()
        doc.commitInput("styled", at: a("A1"))
        doc.selection.select(a("A1"))
        doc.toggleBold()
        let payload = doc.selectionPayload()
        doc.selection.select(a("C3"))
        doc.paste(payload: payload, sourceOrigin: a("A1"))
        #expect(doc.style(at: a("C3")).bold)
        #expect(doc.activeSheet.value(at: a("C3")) == .string("styled"))
    }

    @Test func singleCellReplicatesAcrossSelection() {
        let doc = SpreadsheetDocument()
        doc.commitInput("9", at: a("A1"))
        doc.selection.select(a("A1"))
        let payload = doc.selectionPayload()
        doc.selection.select(range: CellRange(a1: "B1:C2")!)
        doc.paste(payload: payload, sourceOrigin: a("A1"))
        for addr in ["B1", "C1", "B2", "C2"] {
            #expect(doc.activeSheet.value(at: a(addr)) == .number(9))
        }
    }

    @Test func pasteOverwritesTargetRect() {
        let doc = SpreadsheetDocument()
        doc.commitInput("old", at: a("B2"))
        doc.commitInput("1", at: a("A1"))
        doc.selection.select(range: CellRange(a1: "A1:B2")!)
        let payload = doc.selectionPayload() // has A1 only; B2 empty in payload? no B2="old" is in range...
        doc.commitInput("victim", at: a("D4"))
        doc.selection.select(a("C3"))
        doc.paste(payload: payload, sourceOrigin: a("A1"))
        // target rect C3:D4 fully overwritten: D4 gets old B2 content
        #expect(doc.activeSheet.value(at: a("C3")) == .number(1))
        #expect(doc.activeSheet.value(at: a("D4")) == .string("old"))
    }

    @Test func externalTextPaste() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("B2"))
        doc.paste(text: "1\t2\n3\thello\n")
        #expect(doc.activeSheet.value(at: a("B2")) == .number(1))
        #expect(doc.activeSheet.value(at: a("C2")) == .number(2))
        #expect(doc.activeSheet.value(at: a("B3")) == .number(3))
        #expect(doc.activeSheet.value(at: a("C3")) == .string("hello"))
        #expect(doc.selection.range == CellRange(a1: "B2:C3"))
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("B2")) == .empty)
    }

    @Test func externalPasteParsesFormulas() {
        let doc = SpreadsheetDocument()
        doc.commitInput("6", at: a("A1"))
        doc.selection.select(a("B1"))
        doc.paste(text: "=A1*7")
        #expect(doc.activeSheet.value(at: a("B1")) == .number(42))
    }

    @Test func fillDownAdjustsFormulas() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        doc.commitInput("2", at: a("A2"))
        doc.commitInput("3", at: a("A3"))
        doc.commitInput("=A1*10", at: a("B1"))
        doc.fill(from: CellRange(a1: "B1")!, to: CellRange(a1: "B1:B3")!)
        #expect(doc.activeSheet.value(at: a("B2")) == .number(20))
        #expect(doc.activeSheet.value(at: a("B3")) == .number(30))
        #expect(doc.activeSheet.cell(at: a("B3")).formula == "A3*10")
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("B2")) == .empty)
        #expect(doc.activeSheet.value(at: a("B1")) == .number(10)) // source untouched
    }

    @Test func fillRepeatsPattern() {
        let doc = SpreadsheetDocument()
        doc.commitInput("a", at: a("A1"))
        doc.commitInput("b", at: a("A2"))
        doc.fill(from: CellRange(a1: "A1:A2")!, to: CellRange(a1: "A1:A6")!)
        #expect(doc.activeSheet.value(at: a("A3")) == .string("a"))
        #expect(doc.activeSheet.value(at: a("A4")) == .string("b"))
        #expect(doc.activeSheet.value(at: a("A5")) == .string("a"))
        #expect(doc.activeSheet.value(at: a("A6")) == .string("b"))
    }

    @Test func payloadRoundTripsThroughJSON() throws {
        let doc = SpreadsheetDocument()
        doc.commitInput("=SUM(A1:A5)", at: a("B1"))
        doc.selection.select(a("B1"))
        let payload = doc.selectionPayload()
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipboardPayload.self, from: data)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].cell.formula == "SUM(A1:A5)")
    }
}
