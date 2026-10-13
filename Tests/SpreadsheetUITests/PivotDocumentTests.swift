import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// A document with Data!A1:B4 feeding a pivot table drawn at Report!B5:C8,
/// with one report filter in row 3 (so it occupies B3:C8).
@MainActor
private func makePivotDocument(rowField: Int = 0) -> SpreadsheetDocument {
    let wb = Workbook()
    let data = wb.addSheet(named: "Data")
    let report = wb.addSheet(named: "Report")
    for (i, row) in [("Name", "Qty"), ("a", "1"), ("b", "2"), ("a", "3")].enumerated() {
        data.setCell(Cell(value: .string(row.0)), at: CellAddress(row: i, column: 0))
        data.setCell(Cell(value: Double(row.1).map(CellValue.number) ?? .string(row.1)), at: CellAddress(row: i, column: 1))
    }
    report.setCell(Cell(value: .string("Name")), at: CellAddress(a1: "B3")!)
    report.setCell(Cell(value: .string("(All)")), at: CellAddress(a1: "C3")!)
    for (i, row) in [("Row Labels", "Sum of Qty"), ("a", "4"), ("b", "2"), ("Grand Total", "6")].enumerated() {
        report.setCell(Cell(value: .string(row.0)), at: CellAddress(row: 4 + i, column: 1))
        report.setCell(Cell(value: Double(row.1).map(CellValue.number) ?? .string(row.1)), at: CellAddress(row: 4 + i, column: 2))
    }
    let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    let definition = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <pivotCacheDefinition xmlns="\(main)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId1" recordCount="3">\
    <cacheSource type="worksheet"><worksheetSource ref="A1:B4" sheet="Data"/></cacheSource><cacheFields count="2">\
    <cacheField name="Name" numFmtId="0"><sharedItems count="2"><s v="a"/><s v="b"/></sharedItems></cacheField>\
    <cacheField name="Qty" numFmtId="0"><sharedItems containsSemiMixedTypes="0" containsString="0" containsNumber="1" minValue="1" maxValue="3"/></cacheField>\
    </cacheFields></pivotCacheDefinition>
    """
    let records = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <pivotCacheRecords xmlns="\(main)" count="3"><r><x v="0"/><n v="1"/></r><r><x v="1"/><n v="2"/></r><r><x v="0"/><n v="3"/></r></pivotCacheRecords>
    """
    let table = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <pivotTableDefinition xmlns="\(main)" name="Sales" cacheId="4" dataCaption="Values">\
    <location ref="B5:C8" firstHeaderRow="1" firstDataRow="1" firstDataCol="1" rowPageCount="1" colPageCount="1"/>\
    <pivotFields count="2"><pivotField axis="axisRow" showAll="0"><items count="3"><item x="0"/><item x="1"/><item t="default"/></items></pivotField>\
    <pivotField dataField="1" showAll="0"/></pivotFields><rowFields count="1"><field x="\(rowField)"/></rowFields>\
    <rowItems count="3"><i><x/></i><i><x v="1"/></i><i t="grand"><x/></i></rowItems><colItems count="1"><i/></colItems>\
    <dataFields count="1"><dataField name="Sum of Qty" fld="1" baseField="0" baseItem="0"/></dataFields></pivotTableDefinition>
    """
    wb.pivotCaches = [PivotCache(cacheID: 4, sourceRanges: [PivotSourceRange(target: .sheet(id: data.id), ref: "A1:B4")],
                                 payload: PivotCachePayload(definition: Data(definition.utf8), records: Data(records.utf8),
                                                            externalRelationships: []))]
    wb.pivotTables = [PivotTable(sheetID: report.id, name: "Sales", cacheID: 4, location: CellRange(a1: "B5:C8")!,
                                 pageFieldRows: 1, pageFieldColumns: 1,
                                 payload: PivotTablePayload(definition: Data(table.utf8)))]
    wb.preservedStyles = PreservedStyles()
    let doc = SpreadsheetDocument(workbook: wb)
    doc.selectSheet(withID: report.id)
    return doc
}

@MainActor
@Suite("Pivot tables in a document")
struct PivotDocumentTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    @Test func typingIntoAPivotTableIsRefused() {
        let doc = makePivotDocument()
        doc.commitInput("99", at: a("C6"))
        #expect(doc.activeSheet.value(at: a("C6")) == .number(4))
        #expect(doc.notice?.message == "You can’t change part of a pivot table.")
        #expect(doc.notice?.detail.contains("“Sales”") == true)
        #expect(!doc.isModified)
        #expect(!doc.undoManager.canUndo)
    }

    @Test func theFilterAreaIsProtectedToo() {
        let doc = makePivotDocument()
        doc.commitInput("x", at: a("C3"))
        #expect(doc.activeSheet.value(at: a("C3")) == .string("(All)"))
        #expect(doc.notice != nil)
    }

    @Test func typingBesideItIsFine() {
        let doc = makePivotDocument()
        doc.commitInput("note", at: a("D6"))
        doc.commitInput("above", at: a("B1"))
        #expect(doc.activeSheet.value(at: a("D6")) == .string("note"))
        #expect(doc.notice == nil)
    }

    @Test func editingTheSourceDataIsAllowed() {
        // Like Excel: the pivot keeps showing its cache until refreshed.
        let doc = makePivotDocument()
        doc.selectSheet(withID: doc.workbook.sheet(named: "Data")!.id)
        doc.commitInput("10", at: a("B2"))
        #expect(doc.activeSheet.value(at: a("B2")) == .number(10))
        #expect(doc.notice == nil)
    }

    @Test func clearingPartOfItIsRefused() {
        let doc = makePivotDocument()
        doc.selection.select(range: r("C5:D7"))
        doc.clearSelectionContents()
        #expect(doc.activeSheet.value(at: a("C6")) == .number(4))
        #expect(doc.notice != nil)
        #expect(doc.workbook.pivotTables.count == 1)
    }

    @Test func deletingTheWholeTableRemovesItUndoably() throws {
        let doc = makePivotDocument()
        doc.selection.select(range: r("A1:D10"))
        doc.clearSelectionContents()
        #expect(doc.notice == nil)
        #expect(doc.workbook.pivotTables.isEmpty)
        #expect(doc.workbook.pivotCaches.isEmpty)
        #expect(doc.activeSheet.value(at: a("C6")) == .empty)

        doc.undoManager.undo()
        #expect(doc.workbook.pivotTables.count == 1)
        #expect(doc.workbook.pivotCaches.count == 1)
        #expect(doc.activeSheet.value(at: a("C6")) == .number(4))
        // The restored table belongs to the (re-created) Report sheet.
        let table = try #require(doc.workbook.pivotTables.first)
        #expect(doc.workbook.sheet(withID: table.sheetID)?.name == "Report")
        let data = try #require(doc.workbook.sheet(named: "Data"))
        #expect(doc.workbook.pivotCaches.first?.sourceRanges.first?.target == .sheet(id: data.id))
    }

    @Test func pasteOntoItIsRefused() {
        let doc = makePivotDocument()
        doc.selection.select(a("A6"))
        doc.paste(text: "1\t2\t3")
        #expect(doc.activeSheet.value(at: a("A6")) == .empty) // nothing written at all
        #expect(doc.activeSheet.value(at: a("B6")) == .string("a"))
        #expect(doc.notice != nil)

        doc.notice = nil
        doc.selection.select(range: r("E1:E2"))
        let payload = doc.selectionPayload()
        doc.selection.select(a("C7"))
        doc.paste(payload: payload, sourceOrigin: a("E1"))
        #expect(doc.activeSheet.value(at: a("C7")) == .number(2))
        #expect(doc.notice != nil)
    }

    @Test func fillIntoItIsRefusedButFillingOutOfItWorks() {
        let doc = makePivotDocument()
        doc.commitInput("7", at: a("C1"))
        doc.fill(from: r("C1"), to: r("C1:C4"))
        #expect(doc.notice != nil)
        #expect(doc.activeSheet.value(at: a("C2")) == .empty)

        doc.notice = nil
        doc.fill(from: r("C8"), to: r("C8:C10")) // from the Grand Total downwards
        #expect(doc.notice == nil)
        #expect(doc.activeSheet.value(at: a("C10")) == .number(6))
    }

    @Test func cuttingFromItIsRefused() {
        let doc = makePivotDocument()
        doc.selection.select(range: r("B5:C8"))
        doc.copySelectionToPasteboard(cut: true)
        #expect(doc.notice != nil)
        #expect(doc.activeSheet.value(at: a("C6")) == .number(4))
        #expect(doc.workbook.pivotTables.count == 1)
    }

    @Test func copiedPivotCellsDropTheFieldButton() {
        let doc = makePivotDocument()
        var cell = doc.activeSheet.cell(at: a("B5"))
        cell.styleIndex = doc.workbook.styleIndex(for: CellStyle(bold: true, pivotButton: true))
        doc.activeSheet.setCell(cell, at: a("B5"))
        doc.selection.select(a("B5"))
        let payload = doc.selectionPayload()
        #expect(payload.entries.first?.style == CellStyle(bold: true))
    }

    @Test func undoingAPivotRemovalKeepsEarlierUndoWorking() {
        // Removal snapshots the whole workbook; cell undo records made before
        // it must still find their sheet afterwards.
        let doc = makePivotDocument()
        doc.commitInput("hello", at: a("Z1"))
        doc.selection.select(range: r("A1:D10"))
        doc.clearSelectionContents()
        doc.undoManager.undo() // pivot back
        #expect(doc.workbook.pivotTables.count == 1)
        doc.undoManager.undo() // typing undone
        #expect(doc.activeSheet.value(at: a("Z1")) == .empty)
        doc.undoManager.redo()
        #expect(doc.activeSheet.value(at: a("Z1")) == .string("hello"))
    }

    @Test func fillingOutOfItDropsTheFieldButton() {
        let doc = makePivotDocument()
        var cell = doc.activeSheet.cell(at: a("C8"))
        cell.styleIndex = doc.workbook.styleIndex(for: CellStyle(bold: true, pivotButton: true))
        doc.activeSheet.setCell(cell, at: a("C8"))
        doc.fill(from: r("C8"), to: r("C8:C10"))
        #expect(doc.style(at: a("C10")) == CellStyle(bold: true))
        #expect(doc.style(at: a("C8")).pivotButton)
    }

    @Test func clearFormattingKeepsFieldButtonsInsideIt() {
        let doc = makePivotDocument()
        var cell = doc.activeSheet.cell(at: a("B5"))
        cell.styleIndex = doc.workbook.styleIndex(for: CellStyle(bold: true, pivotButton: true))
        doc.activeSheet.setCell(cell, at: a("B5"))
        doc.selection.select(range: r("B5:C8"))
        doc.clearFormattingInSelection()
        #expect(doc.style(at: a("B5")) == CellStyle(pivotButton: true))
    }

    @Test func formattingItIsAllowed() {
        let doc = makePivotDocument()
        doc.selection.select(range: r("B5:C8"))
        doc.toggleBold()
        #expect(doc.style(at: a("C6")).bold)
        #expect(doc.notice == nil)
    }

    @Test func rowEditsThroughItAreRefused() {
        let doc = makePivotDocument()
        doc.insertRows(at: 5) // inside the body
        #expect(doc.notice?.message == "You can’t insert or delete rows through a pivot table.")
        #expect(doc.workbook.pivotTables.first?.location.a1 == "B5:C8")
        #expect(!doc.undoManager.canUndo)

        doc.notice = nil
        doc.deleteRows(at: 3) // the blank row between filter and body
        #expect(doc.notice != nil)
        #expect(doc.activeSheet.value(at: a("C6")) == .number(4))
    }

    @Test func rowEditsAboveMoveItAndUndoMovesItBack() {
        let doc = makePivotDocument()
        doc.insertRows(at: 0, count: 2)
        #expect(doc.notice == nil)
        #expect(doc.workbook.pivotTables.first?.location.a1 == "B7:C10")
        #expect(doc.activeSheet.value(at: a("C8")) == .number(4))
        // The cells are protected at their new home.
        doc.commitInput("1", at: a("C8"))
        #expect(doc.notice != nil)
        doc.notice = nil
        doc.undoManager.undo()
        #expect(doc.workbook.pivotTables.first?.location.a1 == "B5:C8")
    }

    @Test func columnEditsFollowTheSameRules() {
        let doc = makePivotDocument()
        doc.insertColumns(at: 2) // column C, inside
        #expect(doc.notice?.message == "You can’t insert or delete columns through a pivot table.")
        doc.notice = nil
        doc.insertColumns(at: 0)
        #expect(doc.workbook.pivotTables.first?.location.a1 == "C5:D8")
        doc.deleteColumns(at: 2, count: 2) // all of its columns
        #expect(doc.notice == nil)
        #expect(doc.workbook.pivotTables.isEmpty)
    }

    @Test func sheetOperationsKeepPivotsConsistent() throws {
        let doc = makePivotDocument()
        let data = try #require(doc.workbook.sheet(named: "Data"))
        doc.selectSheet(withID: data.id)
        doc.renameActiveSheet(to: "Raw")
        let saved = try Package(XLSXWriter.data(for: doc.workbook))
        let source = try saved.elements(["pivotCacheDefinition", "cacheSource", "worksheetSource"],
                                        in: "xl/pivotCache/pivotCacheDefinition1.xml")
        #expect(source == [["ref": "A1:B4", "sheet": "Raw"]])

        doc.deleteActiveSheet()
        #expect(doc.workbook.pivotCaches.first?.hasDetachedSource == true)
        doc.undoManager.undo()
        let restored = try #require(doc.workbook.sheet(named: "Raw"))
        #expect(doc.workbook.pivotCaches.first?.sourceRanges.first?.target == .sheet(id: restored.id))
    }

    @Test func savingAndReopeningKeepsThePivot() throws {
        let doc = makePivotDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pivot-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        let reopened = try SpreadsheetDocument.open(url: url)
        let table = try #require(reopened.workbook.pivotTables.first)
        #expect(table.name == "Sales" && table.location.a1 == "B5:C8" && table.pageFieldRows == 1)
        #expect(reopened.workbook.pivotCaches.first?.sourceRanges.first?.ref == "A1:B4")
    }

    @Test func aMalformedPivotFromAFileDrawsAndIsKeptAsIs() throws {
        // <field x="5"/> with two fields: drawing used to trap the process.
        let doc = makePivotDocument(rowField: 5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pivot-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        let reopened = try SpreadsheetDocument.open(url: url)
        reopened.selectSheet(withID: try #require(reopened.workbook.pivotTables.first).sheetID)
        #expect(reopened.pivotRole(at: a("C6")) == nil)
        #expect(reopened.pivotEditBlocker(0)?.contains("field 5") == true)
        #expect(!reopened.refreshPivot(0))
        #expect(reopened.displayString(at: a("C6")) == "4") // Excel's cells stay as they were
    }
}

/// Minimal package inspection for these tests.
struct Package {
    let zip: ZipArchiveReader
    init(_ data: Data) throws { zip = try ZipArchiveReader(data: data) }
    func elements(_ path: [String], in partName: String) throws -> [[String: String]] {
        var found: [[String: String]] = []
        try XMLRewriter.scan(zip.contents(named: partName)) { element in
            if element.path == path { found.append(element.attributes) }
            return .keep
        }
        return found
    }
}
