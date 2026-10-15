import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Opening a file lists what it holds that saving would not write back.
@Suite("Unsupported content report")
struct UnsupportedContentTests {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A package with one or more sheets plus whatever extra parts (and
    /// their content type overrides) a test needs.
    static func package(sheets: [(name: String, state: String?, xml: String)],
                        sharedStrings: String? = nil, workbookExtra: String = "",
                        extraParts: [(path: String, contentType: String?, data: Data)] = [],
                        extraDefaults: [(String, String)] = []) throws -> Data {
        var zip = ZipArchiveWriter()
        var types = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for (ext, type) in extraDefaults { types += "<Default Extension=\"\(ext)\" ContentType=\"\(type)\"/>" }
        types += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in sheets.indices {
            types += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        for part in extraParts {
            if let type = part.contentType { types += "<Override PartName=\"/\(part.path)\" ContentType=\"\(type)\"/>" }
        }
        types += "</Types>"
        zip.addEntry(name: "[Content_Types].xml", data: Data((header + types).utf8))
        zip.addEntry(name: "_rels/.rels", data: Data((header +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "</Relationships>").utf8))
        var sheetList = ""
        var rels = ""
        for (i, sheet) in sheets.enumerated() {
            let state = sheet.state.map { " state=\"\($0)\"" } ?? ""
            sheetList += "<sheet name=\"\(sheet.name)\" sheetId=\"\(i + 1)\"\(state) r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
            zip.addEntry(name: "xl/worksheets/sheet\(i + 1).xml", data: Data((header +
                "<worksheet xmlns=\"\(main)\" xmlns:r=\"\(rns)\">" + sheet.xml + "</worksheet>").utf8))
        }
        if sharedStrings != nil {
            rels += "<Relationship Id=\"rIdS\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        }
        zip.addEntry(name: "xl/workbook.xml", data: Data((header +
            "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rns)\">\(workbookExtra)<sheets>\(sheetList)</sheets></workbook>").utf8))
        zip.addEntry(name: "xl/_rels/workbook.xml.rels", data: Data((header +
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>").utf8))
        if let sharedStrings {
            zip.addEntry(name: "xl/sharedStrings.xml", data: Data((header + sharedStrings).utf8))
        }
        for part in extraParts { zip.addEntry(name: part.path, data: part.data) }
        return try zip.finalize()
    }

    static func unsupported(_ data: Data) throws -> [String] {
        var report = XLSXReadReport()
        _ = try XLSXReader.read(data: data, report: &report)
        return report.unsupportedContent
    }

    static let plainSheet = "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>"

    @Test func ourOwnFilesReportNothing() throws {
        let workbook = Workbook.newDocument()
        let sheet = workbook.sheets[0]
        sheet.setCell(Cell(value: .string("hi")), at: CellAddress(row: 0, column: 0))
        sheet.columnWidths[2] = 80
        sheet.hiddenRows = [4]
        sheet.mergedRanges = [CellRange(a1: "B2:C3")!]
        sheet.autoFilter = AutoFilter(range: CellRange(a1: "A1:C9")!)
        workbook.addSheet(named: "Second").isHidden = true
        #expect(try Self.unsupported(XLSXWriter.data(for: workbook)) == [])
        #expect(try Self.unsupported(Self.package(sheets: [("S", nil, Self.plainSheet)])) == [])
    }

    @Test func packagePartsAreCountedAndNamed() throws {
        let xml = Data("<x/>".utf8)
        let chart = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
        let data = try Self.package(
            sheets: [("S", nil, Self.plainSheet)],
            extraParts: [
                ("xl/charts/chart1.xml", chart, xml), ("xl/charts/chart2.xml", chart, xml),
                ("xl/charts/style1.xml", "application/vnd.ms-office.chartstyle+xml", xml),
                ("xl/drawings/drawing1.xml", "application/vnd.openxmlformats-officedocument.drawing+xml", xml),
                ("xl/media/image1.png", nil, Data([0x89, 0x50])),
                ("docProps/thumbnail.jpeg", nil, Data([0xFF, 0xD8])),
                ("xl/comments1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml", xml),
                ("xl/threadedComments/threadedComment1.xml", "application/vnd.ms-excel.threadedcomments+xml", xml),
                ("xl/tables/table1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml", xml),
                ("xl/externalLinks/externalLink1.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.externalLink+xml", xml),
                ("xl/vbaProject.bin", "application/vnd.ms-office.vbaProject", xml),
                ("xl/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml", xml),
                ("xl/calcChain.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml", xml),
                ("customXml/item1.xml", nil, xml),
                ("xl/mystery.bin", "application/x-something-new", xml),
            ],
            extraDefaults: [("png", "image/png"), ("jpeg", "image/jpeg")])
        #expect(try Self.unsupported(data) == [
            "2 charts", "1 image", "comments", "1 table", "links to other workbooks", "macros", "other content",
        ])
    }

    @Test func shapesAloneAreNamed() throws {
        let data = try Self.package(sheets: [("S", nil, Self.plainSheet)], extraParts: [
            ("xl/drawings/drawing1.xml", "application/vnd.openxmlformats-officedocument.drawing+xml", Data("<x/>".utf8)),
        ])
        #expect(try Self.unsupported(data) == ["drawings and shapes"])
    }

    /// Most of what a sheet holds outside its cells is carried through a
    /// save (CarriedParts); what the model rewrites (columns, outlines) isn't.
    @Test func worksheetContentIsNamedUnlessCarried() throws {
        let sheet = """
        <sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><cols><col min="1" max="1" width="9" hidden="1"/><col min="2" max="2" width="9" outlineLevel="1"/></cols>\
        <sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData><sheetProtection sheet="1"/>\
        <conditionalFormatting sqref="A1"><cfRule type="cellIs" priority="1" operator="greaterThan"><formula>0</formula></cfRule></conditionalFormatting>\
        <dataValidations count="1"><dataValidation type="list" sqref="B1"><formula1>"a,b"</formula1></dataValidation></dataValidations>\
        <hyperlinks><hyperlink ref="A1" r:id="rId9"/></hyperlinks>\
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/><pageSetup orientation="landscape"/>\
        <extLst><ext uri="{05C60535-1F16-4fd2-B633-F4F36F0B64E0}" xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"><x14:sparklineGroups/></ext></extLst>
        """
        // Hidden columns are kept now; outline levels aren't.
        #expect(try Self.unsupported(Self.package(sheets: [("S", nil, sheet)])) == ["grouped rows or columns"])
        // A sheet in the Strict namespaces isn't carried (so all of it is named).
        let strict = Self.header + "<worksheet xmlns=\"http://purl.oclc.org/ooxml/spreadsheetml/main\">" + sheet + "</worksheet>"
        #expect(XLSXReader.carriedSheet(Data(strict.utf8)) == nil)
    }

    @Test func defaultPrintSetupIsNotReported() throws {
        let sheet = Self.plainSheet + "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
            + "<pageSetup paperSize=\"9\" orientation=\"portrait\" horizontalDpi=\"300\" verticalDpi=\"300\" r:id=\"rId1\"/>"
        #expect(try Self.unsupported(Self.package(sheets: [("S", nil, sheet)])) == [])
        // What LibreOffice writes for a sheet nobody set up for printing.
        let libre = "<sheetPr><pageSetUpPr fitToPage=\"false\"/></sheetPr>" + Self.plainSheet
            + "<printOptions headings=\"false\" gridLines=\"false\" gridLinesSet=\"true\"/>"
            + "<pageSetup paperSize=\"9\" scale=\"100\" fitToWidth=\"1\" fitToHeight=\"1\" pageOrder=\"downThenOver\" orientation=\"portrait\" blackAndWhite=\"false\" draft=\"false\" cellComments=\"none\" firstPageNumber=\"0\" copies=\"1\"/>"
            + "<headerFooter differentFirst=\"false\"><oddHeader></oddHeader><oddFooter> </oddFooter></headerFooter>"
        #expect(try Self.unsupported(Self.package(sheets: [("S", nil, libre)])) == [])
        // Print setup is carried now, so it isn't named either way.
        let footer = Self.plainSheet + "<headerFooter><oddFooter>&amp;CPage &amp;P</oddFooter></headerFooter>"
        #expect(try Self.unsupported(Self.package(sheets: [("S", nil, footer)])) == [])
        let gridlines = Self.plainSheet + "<printOptions gridLines=\"1\"/>"
        #expect(try Self.unsupported(Self.package(sheets: [("S", nil, gridlines)])) == [])
    }

    @Test func rowFormattingIsReadByBothReaders() throws {
        let sheet = "<sheetData><row r=\"1\" s=\"1\" customFormat=\"1\"><c r=\"A1\"><v>1</v></c></row>"
            + "<row r=\"2\" s=\"1\"><c r=\"A2\"><v>1</v></c></row></sheetData>"
        let data = Data((Self.header + "<worksheet xmlns=\"\(Self.main)\">" + sheet + "</worksheet>").utf8)
        for fast in [true, false] {
            let target = Sheet(id: 1, name: "S")
            let found = try XLSXReader.parseWorksheet(data, into: target, sharedStrings: [],
                                                      styleIndexMap: [0: 0, 1: 3], fastSheetData: fast)
            #expect(found.isEmpty, "fast: \(fast)")
            // A row's s counts only with customFormat.
            #expect(target.rowStyles == [0: 3], "fast: \(fast)")
        }
    }

    @Test func richTextIsReported() throws {
        let strings = "<sst xmlns=\"\(Self.main)\"><si><r><t>plain </t></r><r><rPr><b/></rPr><t>bold</t></r></si></sst>"
        let data = try Self.package(sheets: [("S", nil, "<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row></sheetData>")],
                                    sharedStrings: strings)
        #expect(try Self.unsupported(data) == ["rich text formatting"])
        let plainRuns = "<sst xmlns=\"\(Self.main)\"><si><r><t>a</t></r><r><t>b</t></r></si></sst>"
        #expect(try Self.unsupported(Self.package(sheets: [("S", nil, Self.plainSheet)], sharedStrings: plainRuns)) == [])
    }

    @Test func hiddenSheetsStayHidden() throws {
        let data = try Self.package(sheets: [("Shown", nil, Self.plainSheet), ("Hidden", "hidden", Self.plainSheet),
                                             ("Secret", "veryHidden", Self.plainSheet)])
        var report = XLSXReadReport()
        let workbook = try XLSXReader.read(data: data, report: &report)
        #expect(workbook.sheets.map(\.isHidden) == [false, true, true])
        // Very hidden can't be kept: it comes back as plain hidden.
        #expect(report.unsupportedContent == ["“very hidden” sheet settings"])

        let again = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        #expect(again.sheets.map(\.isHidden) == [false, true, true])
    }

    @Test func aWorkbookWithEverySheetHiddenStillShowsOne() throws {
        let workbook = Workbook.newDocument()
        workbook.sheets[0].isHidden = true
        workbook.addSheet(named: "B").isHidden = true
        let xml = XLSXWriter.workbookXML(workbook: workbook)
        #expect(!xml.contains("<sheet name=\"Sheet1\" sheetId=\"1\" state=\"hidden\""))
        let again = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        #expect(again.sheets.map(\.isHidden) == [false, true])
    }

    @Test func theActiveTabIsAVisibleSheet() throws {
        let workbook = Workbook.newDocument()
        workbook.sheets[0].isHidden = true
        workbook.addSheet(named: "B")
        let xml = XLSXWriter.workbookXML(workbook: workbook)
        #expect(xml.contains("activeTab=\"1\""))
    }

    @Test func workbookSettingsAreCarried() throws {
        let data = try Self.package(sheets: [("S", nil, Self.plainSheet)],
                                    workbookExtra: "<workbookProtection lockStructure=\"1\"/>")
        #expect(try Self.unsupported(data) == [])
        let saved = try XLSXWriter.data(for: XLSXReader.read(data: data))
        #expect(try Package(saved).string("xl/workbook.xml").contains("<workbookProtection lockStructure=\"1\"/>"))
        // Protection elements that protect nothing.
        let off = try Self.package(sheets: [("S", nil, Self.plainSheet + "<sheetProtection sheet=\"false\"/>")],
                                   workbookExtra: "<workbookProtection/>")
        #expect(try Self.unsupported(off) == [])
    }

    @Test func realFilesReportTheirCharts() throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Pivots/poi-WithChartSheet.xlsx")
        let found = try Self.unsupported(Data(contentsOf: url))
        #expect(found.contains { $0.hasSuffix("chart sheet") || $0.hasSuffix("chart sheets") }, "\(found)")
        // A chart sheet opens as an empty sheet; its chart is carried on it.
        #expect(!found.contains { $0.hasSuffix("chart") || $0.hasSuffix("charts") }, "\(found)")
        let saved = try Package(XLSXWriter.data(for: XLSXReader.read(data: Data(contentsOf: url))))
        #expect(saved.names(under: "xl/charts/chart").count == 1)
    }

    @Test func publicReadReturnsTheList() throws {
        let data = try Self.package(sheets: [("S", nil, Self.plainSheet), ("Secret", "veryHidden", Self.plainSheet)])
        var unsupported: [String] = []
        _ = try XLSXReader.read(data: data, unsupportedContent: &unsupported, progress: nil)
        #expect(unsupported == ["“very hidden” sheet settings"])
    }
}
