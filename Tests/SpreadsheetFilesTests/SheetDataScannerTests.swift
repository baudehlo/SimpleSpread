import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// The byte scanner for `<sheetData>` must read exactly what the XMLParser
/// path reads.
@Suite("Fast sheetData scanner")
struct SheetDataScannerTests {
    let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    func expectSameSheets(_ a: Sheet, _ b: Sheet, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.cells == b.cells, "cells: \(label)", sourceLocation: sourceLocation)
        #expect(a.rowHeights == b.rowHeights, "row heights: \(label)", sourceLocation: sourceLocation)
        #expect(a.hiddenRows == b.hiddenRows, "hidden rows: \(label)", sourceLocation: sourceLocation)
        #expect(a.columnWidths == b.columnWidths, "columns: \(label)", sourceLocation: sourceLocation)
        #expect(a.mergedRanges == b.mergedRanges, "merges: \(label)", sourceLocation: sourceLocation)
        #expect(a.autoFilter == b.autoFilter, "filter: \(label)", sourceLocation: sourceLocation)
        #expect(a.frozenRows == b.frozenRows && a.frozenColumns == b.frozenColumns, "panes: \(label)",
                sourceLocation: sourceLocation)
        #expect(a.defaultRowHeight == b.defaultRowHeight, "default height: \(label)", sourceLocation: sourceLocation)
    }

    /// Parse one worksheet both ways.
    func bothWays(_ sheetXML: String, sharedStrings: [String] = ["zero", "one", "two"],
                  sourceLocation: SourceLocation = #_sourceLocation) throws -> Sheet {
        let data = Data(sheetXML.utf8)
        let fast = Sheet(id: 1, name: "S"), slow = Sheet(id: 1, name: "S")
        let styles = [0: 0, 1: 5, 2: 7]
        try XLSXReader.parseWorksheet(data, into: fast, sharedStrings: sharedStrings, styleIndexMap: styles)
        try XLSXReader.parseWorksheet(data, into: slow, sharedStrings: sharedStrings, styleIndexMap: styles,
                                      fastSheetData: false)
        expectSameSheets(fast, slow, sheetXML, sourceLocation: sourceLocation)
        return fast
    }

    @Test func everyFixtureReadsTheSame() throws {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "xlsx" }
        #expect(files.count >= 20)
        for url in files {
            let data = try Data(contentsOf: url)
            var r1 = XLSXReadReport(), r2 = XLSXReadReport()
            guard let fast = try? XLSXReader.read(data: data, report: &r1) else {
                #expect(throws: (any Error).self) { try XLSXReader.read(data: data, report: &r2, fastSheetData: false) }
                continue
            }
            let slow = try XLSXReader.read(data: data, report: &r2, fastSheetData: false)
            #expect(fast.sheets.count == slow.sheets.count)
            for (a, b) in zip(fast.sheets, slow.sheets) {
                expectSameSheets(a, b, "\(url.lastPathComponent) / \(a.name)")
            }
            #expect(fast.styles.styles == slow.styles.styles)
        }
    }

    @Test func edgeCases() throws {
        let sheet = try bothWays("""
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="\(main)" xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac">
        <dimension ref="A1:D9"/><sheetFormatPr defaultRowHeight="15"/><cols><col min="1" max="2" width="12"/></cols>
        <sheetData>
          <row r="1" spans="1:4" x14ac:dyDescent="0.25" ht="20" customHeight="1">
            <c r="A1" t="s"><v>1</v></c><c r="B1" s="1"><v>3.25</v></c><c r="C1" t="b"><v>1</v></c>
            <c r="D1" t="e"><v>#N/A</v></c>
          </row>
          <row r="3" hidden="true">
            <c r="A3" t="str"><f>"a"&amp;"b"</f><v>ab</v></c>
            <c r="B3" t="inlineStr"><is><r><t>rich </t></r><r><rPr><b/></rPr><t xml:space="preserve">text &lt;&#x41;&#66;&gt;</t></r></is></c>
            <c r='C3' t='n'><v>1.5E-3</v></c><c r="D3"><v> 7 </v></c>
          </row>
          <!-- a comment -->
          <row><c><v>10</v></c><c><v>11</v></c><c r="E4"/><c r="F4" s="2"/></row>
          <row r="5"><c r="A5"><f t="shared" ref="A5:A7" si="0">B5*2</f><v>0</v></c><c r="B5"><v>4</v></c></row>
          <row r="6"><c r="A6"><f t="shared" si="0"/><v>0</v></c></row>
          <row r="7"><c r="A7"><f t="shared" si="0"></f></c><c r="B7" t="d"><v>2026-03-04T12:00:00</v></c></row>
          <row r="8"><c r="A8" t="str"><v>line_x000D_break</v></c><c r="B8"><v>00012</v></c><c r="C8"><v>0.30000000000000004</v></c>
            <c r="D8" t="weird"><v>9</v></c><c r="XFE8"><v>1</v></c><c r="$A$9"><v>2</v></c><c r="b8"><v>3</v></c></row>
          <row r="9"><c r="A9" t="s"><v>99</v></c><c r="B9" t="s"><v>2</v></c><c r="C9"><![CDATA[ignored]]><v>5</v></c></row>
        </sheetData>
        <mergeCells count="1"><mergeCell ref="A1:B1"/></mergeCells>
        </worksheet>
        """)
        #expect(sheet.cells.count > 15)
        #expect(sheet.value(at: CellAddress(a1: "B3")!) == .string("rich text <AB>"))
        #expect(sheet.cell(at: CellAddress(a1: "A6")!).formula == "B6*2")
        #expect(sheet.hiddenRows == [2])
    }

    @Test func namespacePrefixes() throws {
        _ = try bothWays("""
        <x:worksheet xmlns:x="\(main)"><x:sheetData><x:row r="2"><x:c r="B2" t="s"><x:v>0</x:v></x:c>
        <x:c r="C2"><x:f>B2</x:f><x:v>1</x:v></x:c></x:row></x:sheetData><x:mergeCells count="1">
        <x:mergeCell ref="B2:C2"/></x:mergeCells></x:worksheet>
        """)
    }

    @Test func emptyAndMissingSheetData() throws {
        _ = try bothWays("<worksheet xmlns=\"\(main)\"><sheetData/></worksheet>")
        _ = try bothWays("<worksheet xmlns=\"\(main)\"><sheetData></sheetData></worksheet>")
        _ = try bothWays("<worksheet xmlns=\"\(main)\"><dimension ref=\"A1\"/></worksheet>")
    }

    @Test func malformedSheetDataFallsBackToXMLParser() throws {
        // An unknown entity: the scanner gives up and XMLParser decides.
        let xml = "<worksheet xmlns=\"\(main)\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"str\"><v>&bogus;</v></c></row></sheetData></worksheet>"
        let fast = Sheet(id: 1, name: "S"), slow = Sheet(id: 1, name: "S")
        let fastError = Result { try XLSXReader.parseWorksheet(Data(xml.utf8), into: fast, sharedStrings: [], styleIndexMap: [:]) }
        let slowError = Result { try XLSXReader.parseWorksheet(Data(xml.utf8), into: slow, sharedStrings: [], styleIndexMap: [:], fastSheetData: false) }
        #expect((try? fastError.get()) == nil && (try? slowError.get()) == nil) // both reject it
    }

    @Test func progressAndCancel() throws {
        var rows = ""
        for r in 1...40_000 { rows += "<row r=\"\(r)\"><c r=\"A\(r)\"><v>\(r)</v></c><c r=\"B\(r)\" t=\"s\"><v>1</v></c></row>" }
        let data = Data("<worksheet xmlns=\"\(main)\"><sheetData>\(rows)</sheetData></worksheet>".utf8)
        var seen: [Double] = []
        try XLSXReader.parseWorksheet(data, into: Sheet(id: 1, name: "S"), sharedStrings: ["a", "b"], styleIndexMap: [:]) {
            seen.append($0); return true
        }
        #expect(seen.count >= 2)
        #expect(throws: XLSXError.cancelled) {
            try XLSXReader.parseWorksheet(data, into: Sheet(id: 1, name: "S"), sharedStrings: ["a", "b"],
                                          styleIndexMap: [:]) { _ in false }
        }
    }
}

/// The byte writer for `<sheetData>` must write exactly what the String
/// writer wrote.
@Suite("Fast sheetData writer")
struct SheetDataWriterTests {
    func bothWays(_ workbook: Workbook, sourceLocation: SourceLocation = #_sourceLocation) {
        let styles = StyleParts(workbook: workbook)
        for sheet in workbook.sheets {
            var s1 = SharedStringBuilder(), s2 = SharedStringBuilder()
            let fast = XLSXWriter.worksheetXML(sheet: sheet, workbook: workbook, styles: styles, strings: &s1)
            let slow = XLSXWriter.worksheetXML(sheet: sheet, workbook: workbook, styles: styles, strings: &s2,
                                               fastSheetData: false)
            #expect(fast == slow, "\(sheet.name)", sourceLocation: sourceLocation)
            if fast != slow {
                let a = String(decoding: fast, as: UTF8.self), b = String(decoding: slow, as: UTF8.self)
                let i = zip(a, b).prefix { $0 == $1 }.count
                print("first difference at \(i): \(a.dropFirst(max(0, i - 40)).prefix(120))\n vs \(b.dropFirst(max(0, i - 40)).prefix(120))")
            }
            #expect(s1.strings == s2.strings, sourceLocation: sourceLocation)
        }
    }

    @Test func fixturesWriteTheSame() throws {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "xlsx" }
        for url in files {
            guard let workbook = try? XLSXReader.read(data: Data(contentsOf: url)) else { continue }
            bothWays(workbook)
        }
    }

    @Test func everyKindOfCell() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        let bold = wb.styles.index(for: CellStyle(bold: true))
        func put(_ a1: String, _ cell: Cell) { sheet.setCell(cell, at: CellAddress(a1: a1)!) }
        put("A1", Cell(value: .number(42)))
        put("B1", Cell(value: .number(-0.1 + 0.3)))
        put("C1", Cell(value: .number(1e20)))
        put("D1", Cell(value: .number(-7)))
        put("E1", Cell(value: .number(-0.0)))
        put("A2", Cell(value: .string("text & <tags>")))
        put("B2", Cell(value: .string("again"), styleIndex: bold))
        put("C2", Cell(value: .string("text & <tags>")))
        put("A3", Cell(value: .bool(true)))
        put("B3", Cell(value: .error(.na)))
        put("C3", Cell(value: .error(.circular)))
        put("A4", Cell(value: .number(3), formula: "A1+1&\"x<y\""))
        put("B4", Cell(value: .string("str\u{1}result"), formula: "\"s\""))
        put("C4", Cell(value: .empty, formula: "NOW()"))
        put("D4", Cell(value: .empty, styleIndex: bold))
        put("XFD4", Cell(value: .number(1)))          // last column…
        sheet.rowHeights[4] = 30                       // …next to a row with only a height
        sheet.hiddenRows = [4, 7]
        sheet.rowHeights[9] = 14.5
        put("A9", Cell(value: .number(9)))
        put("A1048576", Cell(value: .number(1)))
        bothWays(wb)
    }

    @Test func randomSheets() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let wb = Workbook.newDocument()
            let sheet = wb.sheets[0]
            for _ in 0..<200 {
                let address = CellAddress(row: Int.random(in: 0..<60, using: &rng), column: Int.random(in: 0..<40, using: &rng))
                let value: CellValue = switch Int.random(in: 0..<4, using: &rng) {
                case 0: .number(Double(Int.random(in: -1000...1000, using: &rng)) / Double(Int.random(in: 1...7, using: &rng)))
                case 1: .string(["a", "b & c", "<", "x"].randomElement(using: &rng)!)
                case 2: .bool(Bool.random(using: &rng))
                default: .number(Double(Int.random(in: -5...5, using: &rng)))
                }
                sheet.setCell(Cell(value: value, formula: Bool.random(using: &rng) ? nil : "A1*2"), at: address)
            }
            for _ in 0..<5 { sheet.rowHeights[Int.random(in: 0..<80, using: &rng)] = 25 }
            for _ in 0..<5 { sheet.hiddenRows.insert(Int.random(in: 0..<80, using: &rng)) }
            bothWays(wb)
        }
    }
}

extension SheetDataWriterTests {
    @Test func columnNamesMatch() {
        for column in Array(0..<800) + [16_383, 18_277, 18_278, 20_000] {
            var bytes: [UInt8] = []
            XLSXWriter.appendColumnName(column, to: &bytes)
            #expect(String(decoding: bytes, as: UTF8.self) == CellAddress.columnName(column), "\(column)")
        }
    }
}
