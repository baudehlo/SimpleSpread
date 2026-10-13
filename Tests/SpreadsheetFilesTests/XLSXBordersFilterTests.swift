import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("XLSX borders, hidden rows and AutoFilter")
struct XLSXBordersFilterTests {
    func roundTrip(_ workbook: Workbook) throws -> Workbook {
        try XLSXReader.read(data: XLSXWriter.data(for: workbook))
    }

    func part(_ data: Data, _ name: String) throws -> String {
        String(decoding: try ZipArchiveReader(data: data).contents(named: name), as: UTF8.self)
    }

    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    // MARK: Borders

    @Test func bordersRoundTripWithDedup() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        let red = RGBAColor(red: 255, green: 0, blue: 0)
        let boxed = CellBorders(top: BorderLine(.thin), bottom: BorderLine(.thin),
                                left: BorderLine(.thin), right: BorderLine(.thin))
        let fancy = CellBorders(top: BorderLine(.double, color: red), bottom: BorderLine(.thick),
                                left: BorderLine(.dashDotDot, color: .black), right: BorderLine(.hair))
        let bottomOnly = CellBorders(bottom: BorderLine(.mediumDashed, color: RGBAColor(argbHex: "FF336699")))
        let cases: [(String, CellStyle)] = [
            ("A1", CellStyle(borders: boxed)),
            ("A2", CellStyle(bold: true, borders: boxed)), // same border, different xf
            ("B1", CellStyle(borders: fancy)),
            ("C1", CellStyle(fillColor: red, borders: bottomOnly)),
        ]
        for (addr, style) in cases {
            sheet.setCell(Cell(value: .number(1), styleIndex: wb.styles.index(for: style)), at: a(addr))
        }

        let data = try XLSXWriter.data(for: wb)
        let styles = try part(data, "xl/styles.xml")
        // Empty border + three distinct ones; boxed is shared by two xfs.
        #expect(styles.contains("<borders count=\"4\"><border><left/><right/><top/><bottom/><diagonal/></border>"))
        #expect(styles.contains("borderId=\"1\" xfId=\"0\" applyBorder=\"1\""))
        #expect(styles.components(separatedBy: "borderId=\"1\"").count - 1 == 2)
        #expect(styles.contains("<top style=\"double\"><color rgb=\"FFFF0000\"/></top>"))
        #expect(styles.contains("<left style=\"thin\"/>"))

        let read = try XLSXReader.read(data: data)
        for (addr, style) in cases {
            let got = read.style(at: read.sheets[0].cell(at: a(addr)).styleIndex)
            #expect(got.borders == style.borders, "borders at \(addr)")
            #expect(got.bold == style.bold)
        }
    }

    @Test func everyBorderStyleRoundTrips() throws {
        let wb = Workbook.newDocument()
        for (i, lineStyle) in BorderLineStyle.allCases.enumerated() {
            let style = CellStyle(borders: CellBorders(left: BorderLine(lineStyle)))
            wb.sheets[0].setCell(Cell(value: .empty, styleIndex: wb.styles.index(for: style)),
                                 at: CellAddress(row: i, column: 0))
        }
        let read = try roundTrip(wb)
        for (i, lineStyle) in BorderLineStyle.allCases.enumerated() {
            let got = read.style(at: read.sheets[0].cell(at: CellAddress(row: i, column: 0)).styleIndex)
            #expect(got.borders.left == BorderLine(lineStyle))
        }
    }

    @Test func unborderedXfsKeepBorderZero() throws {
        let wb = Workbook.newDocument()
        wb.sheets[0].setCell(Cell(value: .number(1), styleIndex: wb.styles.index(for: CellStyle(bold: true))),
                             at: a("A1"))
        let styles = try part(XLSXWriter.data(for: wb), "xl/styles.xml")
        #expect(styles.contains("<borders count=\"1\">"))
        #expect(!styles.contains("applyBorder"))
    }

    // MARK: Hidden rows

    @Test func hiddenRowsRoundTripIncludingEmptyRows() throws {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(1)), at: a("A2"))
        sheet.rowHeights[4] = 30
        sheet.hiddenRows = [1, 4, 9] // with a cell, with a height, hidden only
        let data = try XLSXWriter.data(for: wb)
        let xml = try part(data, "xl/worksheets/sheet1.xml")
        #expect(xml.contains("<row r=\"10\" hidden=\"1\"></row>"))
        #expect(xml.contains("<row r=\"5\" ht=\"30\" customHeight=\"1\" hidden=\"1\">"))
        let read = try XLSXReader.read(data: data)
        #expect(read.sheets[0].hiddenRows == [1, 4, 9])
        #expect(read.sheets[0].rowHeights[4] == 30)
        #expect(read.sheets[0].value(at: a("A2")) == .number(1))
    }

    // MARK: AutoFilter

    func filteredWorkbook(name: String = "Sheet1") -> Workbook {
        let wb = Workbook.newDocument()
        wb.sheets[0].name = name
        let sheet = wb.sheets[0]
        for (col, header) in ["Name", "Qty", "Region", "Rank"].enumerated() {
            sheet.setCell(Cell(value: .string(header)), at: CellAddress(row: 0, column: col))
        }
        var filter = AutoFilter(range: CellRange(a1: "A1:D20")!)
        filter.columns[0] = ColumnFilter(values: ["Apple", "Pear & Plum", "<odd>"], includeBlanks: true)
        filter.columns[1] = ColumnFilter(conditions: [FilterCondition(.greaterThan, "5"),
                                                      FilterCondition(.lessThanOrEqual, "100")],
                                         matchAll: true)
        filter.columns[2] = ColumnFilter(conditions: [FilterCondition(.equal, "East*"),
                                                      FilterCondition(.notEqual, "West")],
                                         matchAll: false)
        filter.columns[3] = ColumnFilter(preservedXML: "<top10 percent=\"1\" top=\"0\" val=\"10\"/>")
        sheet.autoFilter = filter
        sheet.hiddenRows = [3, 4]
        return wb
    }

    @Test func autoFilterRoundTrips() throws {
        let wb = filteredWorkbook()
        let read = try roundTrip(wb)
        #expect(read.sheets[0].autoFilter == wb.sheets[0].autoFilter)
        #expect(read.sheets[0].hiddenRows == [3, 4])
        // And stays put over a second save.
        #expect(try roundTrip(read).sheets[0].autoFilter == wb.sheets[0].autoFilter)
    }

    @Test func autoFilterXMLShapeAndPosition() throws {
        let wb = filteredWorkbook()
        wb.sheets[0].mergedRanges = [CellRange(a1: "F1:G1")!]
        let data = try XLSXWriter.data(for: wb)
        let xml = try part(data, "xl/worksheets/sheet1.xml")
        #expect(xml.contains("<filterColumn colId=\"0\"><filters blank=\"1\"><filter val=\"&lt;odd&gt;\"/>"
                             + "<filter val=\"Apple\"/><filter val=\"Pear &amp; Plum\"/></filters></filterColumn>"))
        #expect(xml.contains("<customFilters and=\"1\"><customFilter operator=\"greaterThan\" val=\"5\"/>"
                             + "<customFilter operator=\"lessThanOrEqual\" val=\"100\"/></customFilters>"))
        // Equal is the default operator and is omitted; OR omits "and".
        #expect(xml.contains("<customFilters><customFilter val=\"East*\"/>"
                             + "<customFilter operator=\"notEqual\" val=\"West\"/></customFilters>"))
        #expect(xml.contains("<filterColumn colId=\"3\"><top10 percent=\"1\" top=\"0\" val=\"10\"/></filterColumn>"))
        let sheetData = try #require(xml.range(of: "</sheetData>"))
        let autoFilter = try #require(xml.range(of: "<autoFilter ref=\"A1:D20\">"))
        let merge = try #require(xml.range(of: "<mergeCells"))
        #expect(sheetData.upperBound <= autoFilter.lowerBound)
        #expect(autoFilter.upperBound <= merge.lowerBound)
    }

    @Test func filterWithoutCriteriaIsAnEmptyElement() throws {
        let wb = Workbook.newDocument()
        wb.sheets[0].autoFilter = AutoFilter(range: CellRange(a1: "B2:C9")!,
                                             columns: [1: ColumnFilter()]) // inactive: not written
        let data = try XLSXWriter.data(for: wb)
        #expect(try part(data, "xl/worksheets/sheet1.xml").contains("<autoFilter ref=\"B2:C9\"/>"))
        let read = try XLSXReader.read(data: data)
        #expect(read.sheets[0].autoFilter == AutoFilter(range: CellRange(a1: "B2:C9")!))
    }

    @Test func filterDatabaseDefinedName() throws {
        let wb = filteredWorkbook(name: "My Data")
        let plain = wb.addSheet(named: "Plain")
        _ = plain
        let other = wb.addSheet(named: "Other")
        other.autoFilter = AutoFilter(range: CellRange(a1: "C3:E7")!)
        let workbookXML = try part(XLSXWriter.data(for: wb), "xl/workbook.xml")
        #expect(workbookXML.contains("</sheets><definedNames>"
            + "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">'My Data'!$A$1:$D$20</definedName>"
            + "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"2\" hidden=\"1\">Other!$C$3:$E$7</definedName>"
            + "</definedNames>"))
    }

    @Test func noDefinedNamesWithoutFilters() throws {
        let workbookXML = try part(XLSXWriter.data(for: Workbook.newDocument()), "xl/workbook.xml")
        #expect(!workbookXML.contains("definedNames"))
    }

    // MARK: Files Excel wrote

    /// A one-sheet package laid out the way Excel writes it (prefixed
    /// namespaces on the worksheet root, theme/indexed colors, defined name).
    func excelStylePackage(stylesXML: String, sheetXML: String) -> Data {
        var zip = ZipArchiveWriter()
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        zip.addEntry(name: "[Content_Types].xml", data: Data((header
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "</Types>").utf8))
        zip.addEntry(name: "_rels/.rels", data: Data((header
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "</Relationships>").utf8))
        zip.addEntry(name: "xl/workbook.xml", data: Data((header
            + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rns)\"><sheets>"
            + "<sheet name=\"Sales\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"
            + "<definedNames><definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">Sales!$A$1:$E$6</definedName></definedNames>"
            + "</workbook>").utf8))
        zip.addEntry(name: "xl/_rels/workbook.xml.rels", data: Data((header
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "</Relationships>").utf8))
        zip.addEntry(name: "xl/styles.xml", data: Data((header
            + "<styleSheet xmlns=\"\(main)\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\""
            + " mc:Ignorable=\"x14ac\" xmlns:x14ac=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac\">"
            + stylesXML + "</styleSheet>").utf8))
        zip.addEntry(name: "xl/worksheets/sheet1.xml", data: Data((header
            + "<worksheet xmlns=\"\(main)\" xmlns:r=\"\(rns)\""
            + " xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" mc:Ignorable=\"x14ac xr xr2 xr3\""
            + " xmlns:x14ac=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac\""
            + " xmlns:xr=\"http://schemas.microsoft.com/office/spreadsheetml/2014/revision\""
            + " xr:uid=\"{00000000-0001-0000-0000-000000000000}\">"
            + sheetXML + "</worksheet>").utf8))
        return zip.finalize()
    }

    @Test func readsExcelBorders() throws {
        let styles = "<fonts count=\"1\" x14ac:knownFonts=\"1\"><font><sz val=\"11\"/><color theme=\"1\"/><name val=\"Calibri\"/><family val=\"2\"/><scheme val=\"minor\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"4\"><border><left/><right/><top/><bottom/><diagonal/></border>"
            + "<border><left style=\"thin\"><color indexed=\"64\"/></left><right style=\"thin\"><color indexed=\"64\"/></right>"
            + "<top style=\"thin\"><color indexed=\"64\"/></top><bottom style=\"thin\"><color indexed=\"64\"/></bottom><diagonal/></border>"
            + "<border><left/><right/><top style=\"medium\"><color rgb=\"FFFF0000\"/></top>"
            + "<bottom style=\"double\"><color theme=\"4\" tint=\"-0.249977111117893\"/></bottom><diagonal/></border>"
            + "<border diagonalUp=\"1\"><start style=\"dashDot\"><color rgb=\"FF00B050\"/></start><end style=\"hair\"/>"
            + "<top style=\"none\"/><bottom/><diagonal style=\"thin\"><color rgb=\"FF0000FF\"/></diagonal></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"4\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyBorder=\"1\"/>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"2\" xfId=\"0\" applyBorder=\"1\"/>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"3\" xfId=\"0\"/></cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            // A dxf's own border must not join the border table.
            + "<dxfs count=\"1\"><dxf><border><left style=\"thick\"/></border></dxf></dxfs>"
        let sheet = "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"/><c r=\"B1\" s=\"2\"/><c r=\"C1\" s=\"3\"/></row></sheetData>"
        let wb = try XLSXReader.read(data: excelStylePackage(stylesXML: styles, sheetXML: sheet))
        func borders(_ addr: String) -> CellBorders {
            wb.style(at: wb.sheets[0].cell(at: a(addr)).styleIndex).borders
        }
        let thin = BorderLine(.thin)
        #expect(borders("A1") == CellBorders(top: thin, bottom: thin, left: thin, right: thin))
        #expect(borders("B1") == CellBorders(top: BorderLine(.medium, color: RGBAColor(red: 255, green: 0, blue: 0)),
                                             bottom: BorderLine(.double)))
        #expect(borders("C1") == CellBorders(left: BorderLine(.dashDot, color: RGBAColor(red: 0, green: 0xB0, blue: 0x50)),
                                             right: BorderLine(.hair)))
    }

    @Test func readsExcelAutoFilter() throws {
        let styles = "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs>"
        let sheet = "<dimension ref=\"A1:E6\"/>"
            + "<sheetViews><sheetView tabSelected=\"1\" workbookViewId=\"0\"/></sheetViews>"
            + "<sheetFormatPr defaultRowHeight=\"15\" x14ac:dyDescent=\"0.25\"/>"
            + "<sheetData>"
            + "<row r=\"1\" spans=\"1:5\" x14ac:dyDescent=\"0.25\"><c r=\"A1\"><v>1</v></c></row>"
            + "<row r=\"3\" spans=\"1:5\" hidden=\"1\" x14ac:dyDescent=\"0.25\"><c r=\"A3\"><v>3</v></c></row>"
            + "<row r=\"4\" hidden=\"true\"/>"
            + "</sheetData>"
            + "<autoFilter ref=\"A1:E6\" xr:uid=\"{4D1A9B6E-0000-0000-0000-000000000000}\">"
            + "<filterColumn colId=\"0\"><filters blank=\"1\"><filter val=\"East\"/><filter val=\"North\"/></filters></filterColumn>"
            + "<filterColumn colId=\"1\" showButton=\"0\"><customFilters><customFilter operator=\"lessThan\" val=\"10\"/>"
            + "<customFilter operator=\"greaterThanOrEqual\" val=\"90\"/></customFilters></filterColumn>"
            + "<filterColumn colId=\"2\"><top10 percent=\"1\" val=\"25\" filterVal=\"80\"/></filterColumn>"
            + "<filterColumn colId=\"3\" hiddenButton=\"1\"><dynamicFilter type=\"aboveAverage\" val=\"5.5\"/></filterColumn>"
            + "<filterColumn colId=\"4\"><filters><dateGroupItem year=\"2024\" month=\"3\" dateTimeGrouping=\"month\"/></filters></filterColumn>"
            + "<filterColumn colId=\"5\" hiddenButton=\"1\"/>"
            + "</autoFilter>"
            // A custom view's copy of the filter is not the sheet's.
            + "<customSheetViews><customSheetView guid=\"{00000000-0000-0000-0000-000000000001}\">"
            + "<autoFilter ref=\"Z1:Z2\"/></customSheetView></customSheetViews>"
            + "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
        let data = excelStylePackage(stylesXML: styles, sheetXML: sheet)
        let wb = try XLSXReader.read(data: data)
        let s = wb.sheets[0]
        #expect(s.hiddenRows == [2, 3])
        let filter = try #require(s.autoFilter)
        #expect(filter.range == CellRange(a1: "A1:E6")!)
        #expect(filter.columns[0] == ColumnFilter(values: ["East", "North"], includeBlanks: true))
        #expect(filter.columns[1] == ColumnFilter(conditions: [FilterCondition(.lessThan, "10"),
                                                               FilterCondition(.greaterThanOrEqual, "90")],
                                                  matchAll: false))
        #expect(filter.columns[2]?.preservedXML == "<top10 filterVal=\"80\" percent=\"1\" val=\"25\"/>")
        #expect(filter.columns[3]?.preservedXML == "<dynamicFilter type=\"aboveAverage\" val=\"5.5\"/>")
        #expect(filter.columns[4]?.preservedXML
            == "<filters><dateGroupItem dateTimeGrouping=\"month\" month=\"3\" year=\"2024\"/></filters>")
        #expect(filter.columns[5] == nil) // a hidden button with no criteria
        #expect(filter.columns.count == 5)

        // Written back verbatim, and stable across another save.
        let saved = try XLSXWriter.data(for: wb)
        let xml = try part(saved, "xl/worksheets/sheet1.xml")
        #expect(xml.contains("<filterColumn colId=\"2\"><top10 filterVal=\"80\" percent=\"1\" val=\"25\"/></filterColumn>"))
        #expect(xml.contains("<filterColumn colId=\"4\"><filters><dateGroupItem dateTimeGrouping=\"month\" month=\"3\" year=\"2024\"/></filters></filterColumn>"))
        let reread = try XLSXReader.read(data: saved)
        #expect(reread.sheets[0].autoFilter == filter)
        #expect(reread.sheets[0].hiddenRows == [2, 3])
    }

    @Test func preservedCriterionKeepsForeignNamespaces() throws {
        // A criterion using a prefix bound on the worksheet root keeps that
        // binding; unrelated ones (mc, xr, r) are dropped.
        let sheet = "<sheetData/><autoFilter ref=\"A1:B3\"><filterColumn colId=\"1\">"
            + "<colorFilter dxfId=\"0\" xr:uid=\"{1}\"/></filterColumn></autoFilter>"
        let styles = "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellXfs>"
        let wb = try XLSXReader.read(data: excelStylePackage(stylesXML: styles, sheetXML: sheet))
        let preserved = try #require(wb.sheets[0].autoFilter?.columns[1]?.preservedXML)
        #expect(preserved == "<colorFilter xmlns:xr=\"http://schemas.microsoft.com/office/spreadsheetml/2014/revision\" dxfId=\"0\" xr:uid=\"{1}\"/>")
        #expect(try roundTrip(wb).sheets[0].autoFilter?.columns[1]?.preservedXML == preserved)
    }
}
