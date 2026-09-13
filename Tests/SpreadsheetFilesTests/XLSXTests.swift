import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("XLSX round trip")
struct XLSXRoundTripTests {
    func roundTrip(_ workbook: Workbook) throws -> Workbook {
        let data = try XLSXWriter.data(for: workbook)
        return try XLSXReader.read(data: data)
    }

    @Test func valuesRoundTrip() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(42)), at: CellAddress(a1: "A1")!)
        sheet.setCell(Cell(value: .number(3.14159)), at: CellAddress(a1: "A2")!)
        sheet.setCell(Cell(value: .string("hello")), at: CellAddress(a1: "B1")!)
        sheet.setCell(Cell(value: .bool(true)), at: CellAddress(a1: "C1")!)
        sheet.setCell(Cell(value: .bool(false)), at: CellAddress(a1: "C2")!)
        sheet.setCell(Cell(value: .error(.div0)), at: CellAddress(a1: "D1")!)
        sheet.setCell(Cell(value: .number(-1.5e-8)), at: CellAddress(a1: "E1")!)

        let read = try roundTrip(wb)
        let s = read.sheets[0]
        #expect(s.value(at: CellAddress(a1: "A1")!) == .number(42))
        #expect(s.value(at: CellAddress(a1: "A2")!) == .number(3.14159))
        #expect(s.value(at: CellAddress(a1: "B1")!) == .string("hello"))
        #expect(s.value(at: CellAddress(a1: "C1")!) == .bool(true))
        #expect(s.value(at: CellAddress(a1: "C2")!) == .bool(false))
        #expect(s.value(at: CellAddress(a1: "D1")!) == .error(.div0))
        #expect(s.value(at: CellAddress(a1: "E1")!) == .number(-1.5e-8))
    }

    @Test func stringEdgeCasesRoundTrip() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        let cases: [(String, String)] = [
            ("A1", "  leading and trailing  "),
            ("A2", "line1\nline2"),
            ("A3", "quotes \" and <tags> & ampersands"),
            ("A4", "émoji 🎉 unicode ☃"),
            ("A5", "control\u{07}char"),
            ("A6", "literal _x0041_ escape"),
            ("A7", "shared"), ("B7", "shared"), // dedup exercise
        ]
        for (addr, text) in cases {
            sheet.setCell(Cell(value: .string(text)), at: CellAddress(a1: addr)!)
        }
        let read = try roundTrip(wb)
        let s = read.sheets[0]
        for (addr, text) in cases {
            #expect(s.value(at: CellAddress(a1: addr)!) == .string(text), "mismatch at \(addr)")
        }
    }

    @Test func formulasRoundTripWithCachedValues() throws {
        let wb = Workbook.newDocument()
        let engine = CalculationEngine(workbook: wb)
        let id = wb.sheets[0].id
        engine.setCellValue(.number(2), at: AbsoluteAddress(sheetID: id, address: CellAddress(a1: "A1")!))
        engine.setCellValue(.number(3), at: AbsoluteAddress(sheetID: id, address: CellAddress(a1: "A2")!))
        engine.setCellFormula("SUM(A1:A2)", at: AbsoluteAddress(sheetID: id, address: CellAddress(a1: "B1")!))
        engine.setCellFormula("IF(A1<5,\"low\",\"high\")", at: AbsoluteAddress(sheetID: id, address: CellAddress(a1: "B2")!))

        let read = try roundTrip(wb)
        let s = read.sheets[0]
        #expect(s.cell(at: CellAddress(a1: "B1")!).formula == "SUM(A1:A2)")
        #expect(s.value(at: CellAddress(a1: "B1")!) == .number(5)) // cached value read back
        #expect(s.cell(at: CellAddress(a1: "B2")!).formula == "IF(A1<5,\"low\",\"high\")")
        #expect(s.value(at: CellAddress(a1: "B2")!) == .string("low"))
        // Recalculation over the loaded workbook agrees.
        let engine2 = CalculationEngine(workbook: read)
        _ = engine2
        #expect(read.sheets[0].value(at: CellAddress(a1: "B1")!) == .number(5))
    }

    @Test func multiSheetRoundTrip() throws {
        let wb = Workbook.newDocument()
        let budget = wb.addSheet(named: "Budget 2026")
        let odd = wb.addSheet(named: "O'Brien & Sons")
        wb.sheets[0].setCell(Cell(value: .number(1)), at: CellAddress(a1: "A1")!)
        budget.setCell(Cell(value: .number(2)), at: CellAddress(a1: "A1")!)
        odd.setCell(Cell(value: .empty, formula: "'Budget 2026'!A1*10"), at: CellAddress(a1: "A1")!)

        let read = try roundTrip(wb)
        #expect(read.sheets.count == 3)
        #expect(read.sheets.map(\.name) == ["Sheet1", "Budget 2026", "O'Brien & Sons"])
        #expect(read.sheets[2].cell(at: CellAddress(a1: "A1")!).formula == "'Budget 2026'!A1*10")
        let engine = CalculationEngine(workbook: read)
        _ = engine
        #expect(read.sheets[2].value(at: CellAddress(a1: "A1")!) == .number(20))
    }

    @Test func stylesRoundTrip() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        var bold = CellStyle()
        bold.bold = true
        bold.italic = true
        bold.underline = true
        bold.fontSize = 16
        bold.textColor = RGBAColor(red: 255, green: 0, blue: 0)
        bold.fillColor = RGBAColor(red: 255, green: 255, blue: 0)
        bold.horizontalAlignment = .center
        bold.verticalAlignment = .top
        bold.wrapText = true
        sheet.setCell(Cell(value: .string("styled"), styleIndex: wb.styles.index(for: bold)),
                      at: CellAddress(a1: "A1")!)

        var money = CellStyle()
        money.numberFormat = NumberFormat(code: "$#,##0.00")
        sheet.setCell(Cell(value: .number(1234.5), styleIndex: wb.styles.index(for: money)),
                      at: CellAddress(a1: "B1")!)

        var custom = CellStyle()
        custom.numberFormat = NumberFormat(code: "0.000 \"units\"")
        sheet.setCell(Cell(value: .number(9), styleIndex: wb.styles.index(for: custom)),
                      at: CellAddress(a1: "C1")!)

        let read = try roundTrip(wb)
        let s = read.sheets[0]
        let readBold = read.style(at: s.cell(at: CellAddress(a1: "A1")!).styleIndex)
        #expect(readBold.bold && readBold.italic && readBold.underline)
        #expect(readBold.fontSize == 16)
        #expect(readBold.textColor == RGBAColor(red: 255, green: 0, blue: 0))
        #expect(readBold.fillColor == RGBAColor(red: 255, green: 255, blue: 0))
        #expect(readBold.horizontalAlignment == .center)
        #expect(readBold.verticalAlignment == .top)
        #expect(readBold.wrapText)
        let readMoney = read.style(at: s.cell(at: CellAddress(a1: "B1")!).styleIndex)
        #expect(readMoney.numberFormat.code == "$#,##0.00")
        let readCustom = read.style(at: s.cell(at: CellAddress(a1: "C1")!).styleIndex)
        #expect(readCustom.numberFormat.code == "0.000 \"units\"")
    }

    @Test func datesRoundTripAsFormattedNumbers() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        var dateStyle = CellStyle()
        dateStyle.numberFormat = .date
        let serial = ExcelDate.serial(year: 2026, month: 9, day: 13)
        sheet.setCell(Cell(value: .number(serial), styleIndex: wb.styles.index(for: dateStyle)),
                      at: CellAddress(a1: "A1")!)
        let read = try roundTrip(wb)
        let cell = read.sheets[0].cell(at: CellAddress(a1: "A1")!)
        #expect(cell.value == .number(serial))
        #expect(read.style(at: cell.styleIndex).numberFormat.isDateTime)
    }

    @Test func layoutRoundTrip() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(a1: "A1")!)
        sheet.columnWidths[0] = 150
        sheet.rowHeights[2] = 44
        sheet.frozenRows = 2
        sheet.frozenColumns = 1
        sheet.mergedRanges = [CellRange(a1: "B2:C3")!]

        let read = try roundTrip(wb)
        let s = read.sheets[0]
        #expect(abs(Double(s.columnWidths[0] ?? 0) - 150) < 1.0)
        #expect(abs(Double(s.rowHeights[2] ?? 0) - 44) < 0.01)
        #expect(s.frozenRows == 2)
        #expect(s.frozenColumns == 1)
        #expect(s.mergedRanges == [CellRange(a1: "B2:C3")!])
    }

    @Test func emptyWorkbookRoundTrip() throws {
        let wb = Workbook.newDocument()
        let read = try roundTrip(wb)
        #expect(read.sheets.count == 1)
        #expect(read.sheets[0].cells.isEmpty)
    }

    @Test func styleOnEmptyCellRoundTrips() throws {
        let wb = Workbook.newDocument()
        var fill = CellStyle()
        fill.fillColor = RGBAColor(red: 0, green: 128, blue: 255)
        wb.sheets[0].setCell(Cell(styleIndex: wb.styles.index(for: fill)), at: CellAddress(a1: "D4")!)
        let read = try roundTrip(wb)
        let style = read.style(at: read.sheets[0].cell(at: CellAddress(a1: "D4")!).styleIndex)
        #expect(style.fillColor == RGBAColor(red: 0, green: 128, blue: 255))
    }
}

@Suite("XLSX reading foreign files")
struct XLSXForeignFileTests {
    /// Build a minimal in-memory XLSX the way OTHER producers write them:
    /// r-less rows/cells, shared formulas, rich-text strings, inline strings.
    func makeForeignXLSX(
        worksheetXML: String,
        sharedStringsXML: String? = nil,
        workbookExtra: String = "",
        stylesXML: String? = nil
    ) -> Data {
        var zip = ZipArchiveWriter()
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        zip.addEntry(name: "[Content_Types].xml", data: Data((header +
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "</Types>").utf8))
        zip.addEntry(name: "_rels/.rels", data: Data((header +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "</Relationships>").utf8))
        zip.addEntry(name: "xl/workbook.xml", data: Data((header +
            "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rns)\">\(workbookExtra)"
            + "<sheets><sheet name=\"Data\" sheetId=\"7\" r:id=\"rId1\"/></sheets></workbook>").utf8))
        var rels = "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/data.xml\"/>"
        if sharedStringsXML != nil {
            rels += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        }
        if stylesXML != nil {
            rels += "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        }
        zip.addEntry(name: "xl/_rels/workbook.xml.rels", data: Data((header +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>").utf8))
        if let ss = sharedStringsXML {
            zip.addEntry(name: "xl/sharedStrings.xml", data: Data((header + ss).utf8))
        }
        if let st = stylesXML {
            zip.addEntry(name: "xl/styles.xml", data: Data((header + st).utf8))
        }
        // Non-standard worksheet part name on purpose.
        zip.addEntry(name: "xl/worksheets/data.xml", data: Data((header +
            "<worksheet xmlns=\"\(main)\">" + worksheetXML + "</worksheet>").utf8))
        return zip.finalize()
    }

    @Test func readsRowlessAndRlessCells() throws {
        // Google-Sheets-style: no r attributes anywhere.
        let data = makeForeignXLSX(worksheetXML:
            "<sheetData><row><c><v>1</v></c><c><v>2</v></c></row>"
            + "<row><c><v>3</v></c></row></sheetData>")
        let wb = try XLSXReader.read(data: data)
        let s = wb.sheets[0]
        #expect(s.name == "Data")
        #expect(s.value(at: CellAddress(a1: "A1")!) == .number(1))
        #expect(s.value(at: CellAddress(a1: "B1")!) == .number(2))
        #expect(s.value(at: CellAddress(a1: "A2")!) == .number(3))
    }

    @Test func readsPartialRAttributes() throws {
        // Cell with r jumps ahead; following r-less cell continues after it.
        let data = makeForeignXLSX(worksheetXML:
            "<sheetData><row r=\"3\"><c r=\"C3\"><v>1</v></c><c><v>2</v></c></row></sheetData>")
        let wb = try XLSXReader.read(data: data)
        #expect(wb.sheets[0].value(at: CellAddress(a1: "C3")!) == .number(1))
        #expect(wb.sheets[0].value(at: CellAddress(a1: "D3")!) == .number(2))
    }

    @Test func readsSharedFormulas() throws {
        let data = makeForeignXLSX(worksheetXML:
            "<sheetData>"
            + "<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"B1\"><f t=\"shared\" ref=\"B1:B3\" si=\"0\">A1*2</f><v>2</v></c></row>"
            + "<row r=\"2\"><c r=\"A2\"><v>2</v></c><c r=\"B2\"><f t=\"shared\" si=\"0\"/><v>4</v></c></row>"
            + "<row r=\"3\"><c r=\"A3\"><v>3</v></c><c r=\"B3\"><f t=\"shared\" si=\"0\"/><v>6</v></c></row>"
            + "</sheetData>")
        let wb = try XLSXReader.read(data: data)
        let s = wb.sheets[0]
        #expect(s.cell(at: CellAddress(a1: "B1")!).formula == "A1*2")
        #expect(s.cell(at: CellAddress(a1: "B2")!).formula == "A2*2")
        #expect(s.cell(at: CellAddress(a1: "B3")!).formula == "A3*2")
        let engine = CalculationEngine(workbook: wb)
        _ = engine
        #expect(s.value(at: CellAddress(a1: "B3")!) == .number(6))
    }

    @Test func readsRichTextSharedStrings() throws {
        let ss = "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"1\" uniqueCount=\"1\">"
            + "<si><r><t>plain </t></r><r><rPr><b/></rPr><t>bold</t></r></si></sst>"
        let data = makeForeignXLSX(
            worksheetXML: "<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row></sheetData>",
            sharedStringsXML: ss)
        let wb = try XLSXReader.read(data: data)
        #expect(wb.sheets[0].value(at: CellAddress(a1: "A1")!) == .string("plain bold"))
    }

    @Test func readsInlineStrings() throws {
        let data = makeForeignXLSX(worksheetXML:
            "<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>inline!</t></is></c></row></sheetData>")
        let wb = try XLSXReader.read(data: data)
        #expect(wb.sheets[0].value(at: CellAddress(a1: "A1")!) == .string("inline!"))
    }

    @Test func readsDate1904Workbooks() throws {
        // Style 1 = date format. Value 100 in 1904 system = 1462+100 in 1900.
        let styles = "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border/></borders>"
            + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
            + "<xf numFmtId=\"14\" fontId=\"0\" fillId=\"0\" borderId=\"0\" applyNumberFormat=\"1\"/></cellXfs>"
            + "</styleSheet>"
        let data = makeForeignXLSX(
            worksheetXML: "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>100</v></c>"
                + "<c r=\"B1\"><v>100</v></c></row></sheetData>",
            workbookExtra: "<workbookPr date1904=\"1\"/>",
            stylesXML: styles)
        let wb = try XLSXReader.read(data: data)
        // Date-formatted cell shifted to the 1900 system; plain number untouched.
        #expect(wb.sheets[0].value(at: CellAddress(a1: "A1")!) == .number(1562))
        #expect(wb.sheets[0].value(at: CellAddress(a1: "B1")!) == .number(100))
    }

    @Test func readsBuiltinNumberFormatIDs() throws {
        let styles = "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border/></borders>"
            + "<cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
            + "<xf numFmtId=\"10\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellXfs>"
            + "</styleSheet>"
        let data = makeForeignXLSX(
            worksheetXML: "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>0.5</v></c></row></sheetData>",
            stylesXML: styles)
        let wb = try XLSXReader.read(data: data)
        let style = wb.style(at: wb.sheets[0].cell(at: CellAddress(a1: "A1")!).styleIndex)
        #expect(style.numberFormat.code == "0.00%")
    }

    @Test func missingStylesAndStringsTolerated() throws {
        let data = makeForeignXLSX(worksheetXML:
            "<sheetData><row r=\"1\"><c r=\"A1\"><v>5</v></c></row></sheetData>")
        let wb = try XLSXReader.read(data: data)
        #expect(wb.sheets[0].value(at: CellAddress(a1: "A1")!) == .number(5))
    }

    @Test func strResultAndErrorCells() throws {
        let data = makeForeignXLSX(worksheetXML:
            "<sheetData><row r=\"1\">"
            + "<c r=\"A1\" t=\"str\"><f>CONCATENATE(\"a\",\"b\")</f><v>ab</v></c>"
            + "<c r=\"B1\" t=\"e\"><f>1/0</f><v>#DIV/0!</v></c>"
            + "</row></sheetData>")
        let wb = try XLSXReader.read(data: data)
        #expect(wb.sheets[0].value(at: CellAddress(a1: "A1")!) == .string("ab"))
        #expect(wb.sheets[0].value(at: CellAddress(a1: "B1")!) == .error(.div0))
    }

    @Test func garbageRejected() {
        #expect(throws: (any Error).self) {
            _ = try XLSXReader.read(data: Data("not an xlsx".utf8))
        }
    }
}
