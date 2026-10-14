import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

@MainActor
@Suite("Clipboard origin, TSV quoting and filtered fill")
struct ClipboardScaleQuotingFilterTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    // MARK: Copy origin travels with the payload (#19)

    @Test func payloadCarriesItsOrigin() throws {
        let source = SpreadsheetDocument()
        source.commitInput("=A1", at: a("B2"))
        source.selection.select(a("B2"))
        let payload = source.selectionPayload()
        #expect(payload.sourceOrigin == a("B2"))

        // Another window, or the same app after a relaunch: only the JSON
        // on the pasteboard survives.
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipboardPayload.self, from: data)
        let target = SpreadsheetDocument()
        target.selection.select(a("D5"))
        target.paste(payload: decoded)
        #expect(target.activeSheet.cell(at: a("D5")).formula == "C4")
    }

    @Test func payloadsWithoutAnOriginDecode() throws {
        let json = #"{"rows":1,"columns":1,"isCut":false,"entries":[]}"#
        let payload = try JSONDecoder().decode(ClipboardPayload.self, from: Data(json.utf8))
        #expect(payload.sourceOrigin == nil)
    }

    // MARK: Paste scales (#15)

    @Test func largePasteIsFast() {
        let doc = SpreadsheetDocument()
        for row in 0..<200 {
            for column in 0..<50 {
                doc.commitInput(String(row * 50 + column), at: CellAddress(row: row, column: column))
            }
        }
        doc.selection.select(range: r("A1:AX200")) // 10,000 cells
        let payload = doc.selectionPayload()
        doc.selection.select(a("BA1"))
        let start = Date()
        doc.paste(payload: payload)
        let elapsed = Date().timeIntervalSince(start)
        #expect(doc.activeSheet.value(at: CellAddress(row: 199, column: 52 + 49)) == .number(9999))
        // Was quadratic: 8,000 cells took 3 s.
        #expect(elapsed < 1.5, "10k-cell paste took \(elapsed)s")
    }

    @Test func pasteStillClearsCellsThePayloadLeavesEmpty() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        doc.selection.select(range: r("A1:B2"))
        let payload = doc.selectionPayload()
        doc.commitInput("victim", at: a("D4"))
        doc.commitInput("=D4", at: a("F1"))
        doc.selection.select(a("C3"))
        doc.paste(payload: payload)
        #expect(doc.activeSheet.value(at: a("C3")) == .number(1))
        #expect(doc.activeSheet.value(at: a("D4")) == .empty)
        // The cleared cell's dependents recalculate.
        #expect(doc.activeSheet.value(at: a("F1")) != .string("victim"))
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("D4")) == .string("victim"))
        #expect(doc.activeSheet.value(at: a("C3")) == .empty)
    }

    // MARK: TSV quoting (#32)

    @Test func copiedTSVQuotesFieldsThatNeedIt() {
        let doc = SpreadsheetDocument()
        doc.commitInput("line1\nline2", at: a("A1"))
        doc.commitInput("plain", at: a("B1"))
        doc.commitInput("say \"hi\"", at: a("C1"))
        doc.commitInput("\"quoted\" start", at: a("D1"))
        doc.commitInput("tab\there", at: a("E1"))
        doc.selection.select(range: r("A1:E1"))
        #expect(doc.selectionTSV()
            == "\"line1\nline2\"\tplain\tsay \"hi\"\t\"\"\"quoted\"\" start\"\t\"tab\there\"")
    }

    @Test func pastedTSVUnquotesMultiLineCells() {
        let doc = SpreadsheetDocument()
        doc.selection.select(a("A1"))
        doc.paste(text: "\"line1\nline2\"\tnext\r\nsecond\t\"a \"\"b\"\"\"\r\n")
        #expect(doc.activeSheet.value(at: a("A1")) == .string("line1\nline2"))
        #expect(doc.activeSheet.value(at: a("B1")) == .string("next"))
        #expect(doc.activeSheet.value(at: a("A2")) == .string("second"))
        #expect(doc.activeSheet.value(at: a("B2")) == .string("a \"b\""))
        #expect(doc.activeSheet.value(at: a("A3")) == .empty)
        #expect(doc.selection.range == r("A1:B2"))
    }

    @Test func tsvRoundTrips() {
        let doc = SpreadsheetDocument()
        let texts = ["line1\nline2", "say \"hi\"", "\"lead", "tab\tin", "5\" screen"]
        for (i, text) in texts.enumerated() { doc.commitInput(text, at: CellAddress(row: 0, column: i)) }
        doc.selection.select(range: CellRange(start: a("A1"), end: CellAddress(row: 0, column: texts.count - 1)))
        let tsv = doc.selectionTSV()
        doc.selection.select(a("A5"))
        doc.paste(text: tsv)
        for i in texts.indices {
            #expect(doc.activeSheet.value(at: CellAddress(row: 4, column: i)) == .string(texts[i]))
        }
    }

    // MARK: Filtered rows (#20)

    /// Fruit/Qty/Double table, filtered to hide Pear (row 3).
    func filtered() -> SpreadsheetDocument {
        let doc = SpreadsheetDocument()
        let rows = [["Fruit", "Qty", "Double"], ["Apple", "5", "=B2*2"], ["Pear", "3", "=B3*2"],
                    ["Fig", "1", "=B4*2"]]
        for (i, row) in rows.enumerated() {
            for (j, text) in row.enumerated() { doc.commitInput(text, at: CellAddress(row: i, column: j)) }
        }
        doc.selection.select(a("A1"))
        doc.toggleAutoFilter()
        doc.setColumnFilter(0, ColumnFilter(values: ["Apple", "Fig"]))
        #expect(doc.activeSheet.hiddenRows == [2])
        return doc
    }

    @Test func fillDownSkipsFilteredRows() {
        let doc = filtered()
        doc.selection.select(range: r("B2:B4"))
        doc.fillDown()
        #expect(doc.activeSheet.value(at: a("B3")) == .number(3)) // hidden: untouched
        #expect(doc.activeSheet.value(at: a("B4")) == .number(5))
        doc.undoManager.undo()
        #expect(doc.activeSheet.value(at: a("B4")) == .number(1))
    }

    @Test func fillDownFormulasTranslateToTheirRealRow() {
        let doc = filtered()
        doc.commitInput("=B2+100", at: a("D2"))
        doc.selection.select(range: r("D2:D4"))
        doc.fillDown()
        #expect(doc.activeSheet.cell(at: a("D3")).isDefault)
        #expect(doc.activeSheet.cell(at: a("D4")).formula == "B4+100")
    }

    @Test func fillRightSkipsFilteredRows() {
        let doc = filtered()
        doc.selection.select(range: r("A2:B4"))
        doc.fillRight()
        #expect(doc.activeSheet.value(at: a("B2")) == .string("Apple"))
        #expect(doc.activeSheet.value(at: a("B3")) == .number(3))
        #expect(doc.activeSheet.value(at: a("B4")) == .string("Fig"))
    }

    @Test func fillHandleSkipsFilteredRows() {
        let doc = filtered()
        doc.fill(from: r("B2"), to: r("B2:B4"))
        #expect(doc.activeSheet.value(at: a("B3")) == .number(3))
        #expect(doc.activeSheet.value(at: a("B4")) == .number(5))
    }

    @Test func fillCoversRowsHiddenByHand() {
        let doc = SpreadsheetDocument()
        doc.commitInput("x", at: a("A1"))
        doc.commitInput("y", at: a("A2"))
        doc.hideRows(1...1)
        doc.selection.select(range: r("A1:A3"))
        doc.fillDown()
        #expect(doc.activeSheet.value(at: a("A2")) == .string("x"))
    }

    @Test func pastingOneCellIntoAFilteredSelectionSkipsHiddenRows() {
        let doc = filtered()
        doc.commitInput("new", at: a("E1"))
        doc.selection.select(a("E1"))
        let payload = doc.selectionPayload()
        doc.selection.select(range: r("A2:A4"))
        doc.paste(payload: payload)
        #expect(doc.activeSheet.value(at: a("A2")) == .string("new"))
        #expect(doc.activeSheet.value(at: a("A3")) == .string("Pear"))
        #expect(doc.activeSheet.value(at: a("A4")) == .string("new"))
    }

    @Test func pastingABlockLandsContiguously() {
        // Excel pastes a block over filter-hidden rows too.
        let doc = filtered()
        doc.commitInput("p", at: a("E1"))
        doc.commitInput("q", at: a("E2"))
        doc.selection.select(range: r("E1:E2"))
        let payload = doc.selectionPayload()
        doc.selection.select(a("A2"))
        doc.paste(payload: payload)
        #expect(doc.activeSheet.value(at: a("A2")) == .string("p"))
        #expect(doc.activeSheet.value(at: a("A3")) == .string("q"))
    }
}

@MainActor
@Suite("HTML clipboard")
struct HTMLClipboardTests {
    @Test func multiLineCellIsOneHTMLCell() {
        let doc = SpreadsheetDocument()
        doc.commitInput("line one\nline two", at: CellAddress(a1: "A1")!)
        doc.commitInput("a & <b>", at: CellAddress(a1: "B1")!)
        doc.selection.select(range: CellRange(a1: "A1:B1")!)
        let html = doc.selectionHTML()
        #expect(html.contains("<tr><td>line one<br style=\"mso-data-placement:same-cell\">line two</td><td>a &amp; &lt;b&gt;</td></tr>"))
        #expect(html.components(separatedBy: "<tr>").count == 2) // one row
    }

    @Test func crlfIsOneBreak() {
        #expect(SpreadsheetDocument.htmlCell("a\r\nb").components(separatedBy: "<br").count == 2)
    }
}
