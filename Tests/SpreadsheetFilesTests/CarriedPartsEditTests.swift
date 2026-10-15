import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// A workbook as Excel writes one, with what SimpleSpread carries through
/// a save: a chart anchored to cells, a comment with its VML box, a table,
/// conditional formatting, data validation, hyperlinks, a sparkline, a
/// page break, and a second sheet whose chart plots the first.
enum CarriedFixture {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let pkg = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let xdr = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let c = "http://schemas.openxmlformats.org/drawingml/2006/chart"

    static func drawing(fromRow: Int, toRow: Int, fromCol: Int = 4, toCol: Int = 10) -> String {
        header + """
        <xdr:wsDr xmlns:xdr="\(xdr)" xmlns:a="\(a)"><xdr:twoCellAnchor>\
        <xdr:from><xdr:col>\(fromCol)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(fromRow)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>\
        <xdr:to><xdr:col>\(toCol)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(toRow)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>\
        <xdr:graphicFrame macro=""><xdr:nvGraphicFramePr><xdr:cNvPr id="2" name="Chart 1"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>\
        <xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm><a:graphic><a:graphicData uri="\(c)">\
        <c:chart xmlns:c="\(c)" xmlns:r="\(r)" r:id="rId1"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>
        """
    }

    static func chart(_ values: String, categories: String) -> String {
        header + """
        <c:chartSpace xmlns:c="\(c)" xmlns:a="\(a)" xmlns:r="\(r)"><c:chart><c:plotArea><c:layout/><c:barChart>\
        <c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/><c:ser><c:idx val="0"/><c:order val="0"/>\
        <c:cat><c:strRef><c:f>\(categories)</c:f></c:strRef></c:cat><c:val><c:numRef><c:f>\(values)</c:f></c:numRef></c:val>\
        </c:ser><c:axId val="1"/><c:axId val="2"/></c:barChart>\
        <c:catAx><c:axId val="1"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="b"/><c:crossAx val="2"/></c:catAx>\
        <c:valAx><c:axId val="2"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:crossAx val="1"/></c:valAx>\
        </c:plotArea></c:chart></c:chartSpace>
        """
    }

    static let comments = header + """
    <comments xmlns="\(main)"><authors><author>Matt</author></authors><commentList>\
    <comment ref="B3" authorId="0"><text><r><t>Check this</t></r></text></comment></commentList></comments>
    """

    static let vml = """
    <xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel">\
    <o:shapelayout v:ext="edit"><o:idmap v:ext="edit" data="1"/></o:shapelayout>\
    <v:shapetype id="_x0000_t202" coordsize="21600,21600" o:spt="202" path="m,l,21600r21600,l21600,xe"><v:path gradientshapeok="t" o:connecttype="rect"/></v:shapetype>\
    <v:shape id="_x0000_s1025" type="#_x0000_t202" style="position:absolute;visibility:hidden"><v:textbox/>\
    <x:ClientData ObjectType="Note"><x:MoveWithCells/><x:SizeWithCells/><x:Anchor>2, 15, 1, 10, 4, 15, 5, 4</x:Anchor>\
    <x:AutoFill>False</x:AutoFill><x:Row>2</x:Row><x:Column>1</x:Column></x:ClientData></v:shape></xml>
    """

    static let table = header + """
    <table xmlns="\(main)" id="1" name="Sales" displayName="Sales" ref="A1:C5" totalsRowShown="0">\
    <autoFilter ref="A1:C5"/><tableColumns count="3"><tableColumn id="1" name="Region"/>\
    <tableColumn id="2" name="Amount"/><tableColumn id="3" name="Total" ><calculatedColumnFormula>B2*2</calculatedColumnFormula></tableColumn>\
    </tableColumns><tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>
    """

    static let sheet1 = header + """
    <worksheet xmlns="\(main)" xmlns:r="\(r)" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
    xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac" mc:Ignorable="x14ac">\
    <sheetPr><tabColor rgb="FFFF0000"/></sheetPr><dimension ref="A1:C5"/>\
    <sheetViews><sheetView tabSelected="1" workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15" x14ac:dyDescent="0.25"/>\
    <sheetData>\
    <row r="1"><c r="A1" t="inlineStr"><is><t>Region</t></is></c><c r="B1" t="inlineStr"><is><t>Amount</t></is></c><c r="C1" t="inlineStr"><is><t>Total</t></is></c></row>\
    <row r="2"><c r="A2" t="inlineStr"><is><t>North</t></is></c><c r="B2"><v>4</v></c><c r="C2"><f>B2*2</f><v>8</v></c></row>\
    <row r="3"><c r="A3" t="inlineStr"><is><t>South</t></is></c><c r="B3"><v>2</v></c><c r="C3"><f>B3*2</f><v>4</v></c></row>\
    <row r="4"><c r="A4" t="inlineStr"><is><t>East</t></is></c><c r="B4"><v>7</v></c><c r="C4"><f>B4*2</f><v>14</v></c></row>\
    <row r="5"><c r="A5" t="inlineStr"><is><t>West</t></is></c><c r="B5"><v>1</v></c><c r="C5"><f>B5*2</f><v>2</v></c></row>\
    </sheetData><sheetProtection sheet="1" objects="1" scenarios="1"/>\
    <conditionalFormatting sqref="B2:B5"><cfRule type="expression" dxfId="0" priority="1"><formula>B2&gt;3</formula></cfRule></conditionalFormatting>\
    <dataValidations count="1"><dataValidation type="whole" allowBlank="1" sqref="B2:B10"><formula1>0</formula1><formula2>100</formula2></dataValidation></dataValidations>\
    <hyperlinks><hyperlink ref="A7" r:id="rId4"/><hyperlink ref="A8" location="Notes!A1" display="Notes"/></hyperlinks>\
    <pageMargins left="0.5" right="0.5" top="1" bottom="1" header="0.3" footer="0.3"/>\
    <pageSetup orientation="landscape"/><headerFooter><oddFooter>&amp;CPage &amp;P</oddFooter></headerFooter>\
    <rowBreaks count="1" manualBreakCount="1"><brk id="4" max="16383" man="1"/></rowBreaks>\
    <drawing r:id="rId1"/><legacyDrawing r:id="rId2"/><tableParts count="1"><tablePart r:id="rId3"/></tableParts>\
    <extLst><ext uri="{05C60535-1F16-4fd2-B633-F4F36F0B64E0}" xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
    <x14:sparklineGroups xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main"><x14:sparklineGroup><x14:colorSeries rgb="FF376092"/>\
    <x14:sparklines><x14:sparkline><xm:f>Data!B2:B5</xm:f><xm:sqref>D5</xm:sqref></x14:sparkline></x14:sparklines>\
    </x14:sparklineGroup></x14:sparklineGroups></ext></extLst></worksheet>
    """

    static let sheet2 = header + """
    <worksheet xmlns="\(main)" xmlns:r="\(r)"><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData>\
    <conditionalFormatting sqref="A1"><cfRule type="expression" dxfId="0" priority="1"><formula>A1&lt;Data!$B$2</formula></cfRule></conditionalFormatting>\
    <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/><drawing r:id="rId1"/></worksheet>
    """

    static let styles = header + """
    <styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
    <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
    <dxfs count="1"><dxf><font><color rgb="FF9C0006"/></font><fill><patternFill><bgColor rgb="FFFFC7CE"/></patternFill></fill></dxf></dxfs>\
    </styleSheet>
    """

    static func rels(_ list: [(id: String, type: String, target: String, external: Bool)]) -> String {
        header + "<Relationships xmlns=\"\(pkg)\">" + list.map {
            "<Relationship Id=\"\($0.id)\" Type=\"\(relBase)\($0.type)\" Target=\"\($0.target)\"\($0.external ? " TargetMode=\"External\"" : "")/>"
        }.joined() + "</Relationships>"
    }

    static func package() throws -> Data {
        let ct = "application/vnd.openxmlformats-officedocument."
        var types = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        types += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        types += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        types += "<Default Extension=\"vml\" ContentType=\"\(ct)vmlDrawing\"/>"
        for (part, type) in [
            ("/xl/workbook.xml", "spreadsheetml.sheet.main+xml"), ("/xl/worksheets/sheet1.xml", "spreadsheetml.worksheet+xml"),
            ("/xl/worksheets/sheet2.xml", "spreadsheetml.worksheet+xml"), ("/xl/styles.xml", "spreadsheetml.styles+xml"),
            ("/xl/theme/theme1.xml", "theme+xml"), ("/xl/drawings/drawing1.xml", "drawing+xml"),
            ("/xl/drawings/drawing2.xml", "drawing+xml"), ("/xl/charts/chart1.xml", "drawingml.chart+xml"),
            ("/xl/charts/chart2.xml", "drawingml.chart+xml"), ("/xl/comments1.xml", "spreadsheetml.comments+xml"),
            ("/xl/tables/table1.xml", "spreadsheetml.table+xml"),
        ] {
            types += "<Override PartName=\"\(part)\" ContentType=\"\(ct)\(type)\"/>"
        }
        types += "</Types>"
        let parts: [(String, String)] = [
            ("[Content_Types].xml", types),
            ("_rels/.rels", rels([("rId1", "officeDocument", "xl/workbook.xml", false)])),
            ("xl/workbook.xml", header + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(r)\"><sheets>"
                + "<sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Notes\" sheetId=\"2\" r:id=\"rId2\"/>"
                + "</sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", rels([
                ("rId1", "worksheet", "worksheets/sheet1.xml", false), ("rId2", "worksheet", "worksheets/sheet2.xml", false),
                ("rId3", "styles", "styles.xml", false), ("rId4", "theme", "theme/theme1.xml", false)])),
            ("xl/styles.xml", styles),
            // A real theme (Excel's default, from a fixture).
            ("xl/theme/theme1.xml", String(decoding: try ZipArchiveReader(data: Data(contentsOf: Bundle.module.resourceURL!
                .appendingPathComponent("Fixtures/Pivots/poi-DataTableCities.xlsx"))).contents(named: "xl/theme/theme1.xml"),
                as: UTF8.self)),
            ("xl/worksheets/sheet1.xml", sheet1),
            ("xl/worksheets/_rels/sheet1.xml.rels", rels([
                ("rId1", "drawing", "../drawings/drawing1.xml", false), ("rId2", "vmlDrawing", "../drawings/vmlDrawing1.vml", false),
                ("rId3", "table", "../tables/table1.xml", false), ("rId5", "comments", "../comments1.xml", false),
                ("rId4", "hyperlink", "https://example.com/", true)])),
            ("xl/worksheets/sheet2.xml", sheet2),
            ("xl/worksheets/_rels/sheet2.xml.rels", rels([("rId1", "drawing", "../drawings/drawing2.xml", false)])),
            ("xl/drawings/drawing1.xml", drawing(fromRow: 6, toRow: 20)),
            ("xl/drawings/_rels/drawing1.xml.rels", rels([("rId1", "chart", "../charts/chart1.xml", false)])),
            ("xl/drawings/drawing2.xml", drawing(fromRow: 1, toRow: 10)),
            ("xl/drawings/_rels/drawing2.xml.rels", rels([("rId1", "chart", "../charts/chart2.xml", false)])),
            ("xl/charts/chart1.xml", chart("Data!$B$2:$B$5", categories: "Data!$A$2:$A$5")),
            ("xl/charts/chart2.xml", chart("Data!$B$2:$B$5", categories: "Data!$A$2:$A$5")),
            ("xl/comments1.xml", comments),
            ("xl/drawings/vmlDrawing1.vml", vml),
            ("xl/tables/table1.xml", table),
        ]
        var zip = ZipArchiveWriter()
        for (name, text) in parts { zip.addEntry(name: name, data: Data(text.utf8)) }
        return try zip.finalize()
    }
}

@Suite("Carried parts: edits")
struct CarriedPartsEditTests {
    func open() throws -> Workbook { try XLSXReader.read(data: CarriedFixture.package()) }

    func saved(_ workbook: Workbook) throws -> Package {
        let package = try Package(XLSXWriter.data(for: workbook))
        let problems = try package.integrityProblems()
        #expect(problems.isEmpty, "\(problems)")
        return package
    }

    /// The part a sheet's relationship of `type` points at, in a saved package.
    func target(_ package: Package, sheet: Int, type: String) throws -> String? {
        try package.relationships(of: "xl/worksheets/sheet\(sheet).xml").first { $0.type.hasSuffix("/" + type) }?.target
    }

    func text(_ package: Package, sheet: Int, type: String) throws -> String {
        guard let path = try target(package, sheet: sheet, type: type) else { return "" }
        return try package.string(path)
    }

    /// The chart a sheet's drawing shows.
    func chart(_ package: Package, sheet: Int) throws -> String {
        guard let drawing = try target(package, sheet: sheet, type: "drawing"),
              let chart = try package.relationships(of: drawing).first?.target else { return "" }
        return try package.string(chart)
    }

    @Test func nothingIsReportedLost() throws {
        var report = XLSXReadReport()
        _ = try XLSXReader.read(data: CarriedFixture.package(), report: &report)
        #expect(report.unsupportedContent == [])
    }

    @Test func aSaveWithoutEditsKeepsEverything() throws {
        let workbook = try open()
        let package = try saved(workbook)
        let original = try Package(CarriedFixture.package())
        // Carried parts are written byte for byte.
        for part in ["xl/charts/chart1.xml", "xl/comments1.xml", "xl/drawings/vmlDrawing1.vml", "xl/theme/theme1.xml"] {
            #expect(try package.part(part) == original.part(part), "\(part)")
        }
        let sheet = try package.string("xl/worksheets/sheet1.xml")
        // In schema order, around the writer's own elements.
        let order = ["<sheetPr>", "<dimension", "<sheetData", "<sheetProtection", "<conditionalFormatting",
                     "<dataValidations", "<hyperlinks", "<pageMargins", "<pageSetup", "<headerFooter", "<rowBreaks",
                     "<drawing", "<legacyDrawing", "<tableParts", "<extLst"]
        let positions = order.map { sheet.range(of: $0)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil }, "\(zip(order, positions).filter { $0.1 == nil }.map(\.0))")
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        #expect(sheet.contains("mc:Ignorable=\"x14ac\""))
        #expect(sheet.components(separatedBy: "<pageMargins").count == 2)
        #expect(sheet.contains("left=\"0.5\""))
        // The conditional format's style is still the first differential format.
        let styles = try package.string("xl/styles.xml")
        #expect(styles.contains("<dxfs count=\"1\"><dxf") && styles.contains("<font><color rgb=\"FF9C0006\"/>"))
        // The external hyperlink keeps its target.
        let links = try package.relationships(of: "xl/worksheets/sheet1.xml")
        #expect(links.contains { $0.isExternal && $0.target == "https://example.com/" })
        // Saving what we wrote changes nothing.
        let again = try saved(XLSXReader.read(data: XLSXWriter.data(for: workbook)))
        for part in package.partNames where part != "docProps/core.xml" {
            #expect(try again.part(part) == package.part(part), "\(part) changed on the second save")
        }
    }

    @Test func insertingRowsMovesWhatPointsAtCells() throws {
        let workbook = try open()
        let data = try #require(workbook.sheet(named: "Data"))
        WorkbookOperations.insertRows(in: workbook, sheetID: data.id, at: 1, count: 2) // above row 2
        let package = try saved(workbook)
        let sheet = try package.string("xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<conditionalFormatting sqref=\"B4:B7\">"))
        #expect(sheet.contains("<formula>B4&gt;3</formula>"))
        #expect(sheet.contains("sqref=\"B4:B12\""))
        #expect(sheet.contains("<hyperlink r:id=\"rId4\" ref=\"A9\"/>"))
        #expect(sheet.contains("<brk id=\"6\" man=\"1\" max=\"16383\"/>"))
        #expect(sheet.contains("<xm:sqref>D7</xm:sqref>"))
        #expect(sheet.contains("<xm:f>Data!B4:B7</xm:f>"))
        // The chart and its anchor.
        #expect(try chart(package, sheet: 1).contains("<c:f>Data!$B$4:$B$7</c:f>"))
        let drawing = try text(package, sheet: 1, type: "drawing")
        #expect(drawing.contains("<xdr:row>8</xdr:row>") && drawing.contains("<xdr:row>22</xdr:row>"))
        // The comment and its box.
        #expect(try text(package, sheet: 1, type: "comments").contains("<comment authorId=\"0\" ref=\"B5\">"))
        let vml = try text(package, sheet: 1, type: "vmlDrawing")
        #expect(vml.contains("<x:Row>4</x:Row>") && vml.contains("<x:Anchor>2, 15, 3, 10, 4, 15, 7, 4</x:Anchor>"))
        // The table: its header is above the edit, so it grows.
        #expect(try text(package, sheet: 1, type: "table").contains("ref=\"A1:C7\""))
        // The other sheet's chart and rule follow the cells too.
        #expect(try chart(package, sheet: 2).contains("<c:f>Data!$B$4:$B$7</c:f>"))
        #expect(try package.string("xl/worksheets/sheet2.xml").contains("<formula>A1&lt;Data!$B$4</formula>"))
        // ...but the other sheet's own anchor doesn't move.
        #expect(try text(package, sheet: 2, type: "drawing").contains("<xdr:row>1</xdr:row>"))
    }

    @Test func deletingRowsRemovesWhatWasOnThem() throws {
        let workbook = try open()
        let data = try #require(workbook.sheet(named: "Data"))
        WorkbookOperations.deleteRows(in: workbook, sheetID: data.id, at: 1, count: 4) // rows 2-5
        let package = try saved(workbook)
        let sheet = try package.string("xl/worksheets/sheet1.xml")
        #expect(!sheet.contains("<conditionalFormatting")) // B2:B5 went
        #expect(sheet.contains("sqref=\"B2:B6\""))            // B2:B10 shrank
        #expect(!sheet.contains("<x14:sparkline>"))          // its cell D5 went
        // The comment on B3 and its box went; the table lost its data rows.
        #expect(try !text(package, sheet: 1, type: "comments").contains("<comment "))
        #expect(try !text(package, sheet: 1, type: "vmlDrawing").contains("<v:shape "))
        #expect(try target(package, sheet: 1, type: "table") == nil)
        #expect(!sheet.contains("<tableParts"))
        // The chart's series lost every row it had.
        #expect(try chart(package, sheet: 1).contains("<c:f>#REF!</c:f>"))
    }

    @Test func renamingASheetRenamesItInChartsAndRules() throws {
        let workbook = try open()
        let data = try #require(workbook.sheet(named: "Data"))
        WorkbookOperations.renameSheet(in: workbook, sheetID: data.id, to: "Sales 2026")
        let notes = try #require(workbook.sheet(named: "Notes"))
        WorkbookOperations.renameSheet(in: workbook, sheetID: notes.id, to: "Read Me")
        let package = try saved(workbook)
        #expect(try chart(package, sheet: 2).contains("<c:f>'Sales 2026'!$B$2:$B$5</c:f>"))
        #expect(try package.string("xl/worksheets/sheet2.xml").contains("<formula>A1&lt;'Sales 2026'!$B$2</formula>"))
        let sheet = try package.string("xl/worksheets/sheet1.xml")
        #expect(sheet.contains("location=\"'Read Me'!A1\""))
        #expect(sheet.contains("<xm:f>'Sales 2026'!B2:B5</xm:f>"))
    }

    @Test func deletingASheetTakesItsPartsAndBreaksReferencesToIt() throws {
        let workbook = try open()
        let data = try #require(workbook.sheet(named: "Data"))
        WorkbookOperations.deleteSheet(in: workbook, sheetID: data.id)
        let package = try saved(workbook)
        #expect(package.names(under: "xl/comments").isEmpty)
        #expect(package.names(under: "xl/tables/").isEmpty)
        #expect(package.names(under: "xl/charts/").count == 1)
        #expect(try chart(package, sheet: 1).contains("<c:f>#REF!</c:f>"))
        #expect(try package.string("xl/worksheets/sheet1.xml").contains("<formula>A1&lt;#REF!</formula>"))
    }

    @Test func insertingAColumnInsideATableAddsATableColumn() throws {
        let workbook = try open()
        let data = try #require(workbook.sheet(named: "Data"))
        WorkbookOperations.insertColumns(in: workbook, sheetID: data.id, at: 1, count: 1) // before B
        let package = try saved(workbook)
        let table = try text(package, sheet: 1, type: "table")
        #expect(table.contains("ref=\"A1:D5\""))
        #expect(table.contains("<tableColumns count=\"4\">"))
        #expect(table.contains("name=\"Column1\""))
        // Excel needs the header cell to say so: it's written into the cell.
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        #expect(reread.sheets[0].value(at: CellAddress(a1: "B1")!) == .string("Column1"))
        #expect(workbook.sheets[0].value(at: CellAddress(a1: "B1")!) == .empty) // the model is left alone
        // Deleting columns removes them again.
        WorkbookOperations.deleteColumns(in: workbook, sheetID: data.id, at: 1, count: 2)
        let after = try text(saved(workbook), sheet: 1, type: "table")
        #expect(after.contains("<tableColumns count=\"2\">") && after.contains("name=\"Region\"") && after.contains("name=\"Total\""))
    }

    @Test func tableColumnNamesFollowTheirHeaderCells() throws {
        let workbook = try open()
        let sheet = workbook.sheets[0]
        sheet.setCell(Cell(value: .string("Area")), at: CellAddress(a1: "A1")!)
        sheet.setCell(Cell(value: .string("Area")), at: CellAddress(a1: "B1")!) // a repeat
        let table = try text(saved(workbook), sheet: 1, type: "table")
        #expect(table.contains("name=\"Area\"") && table.contains("name=\"Area2\""))
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        #expect(reread.sheets[0].value(at: CellAddress(a1: "B1")!) == .string("Area2"))
    }

    @Test func undoPutsCarriedContentBack() throws {
        let workbook = try open()
        let data = try #require(workbook.sheet(named: "Data"))
        let before = try saved(workbook)
        let edit = try #require(WorkbookOperations.deleteRows(in: workbook, sheetID: data.id, at: 1, count: 4))
        _ = edit.undo(in: workbook)
        let after = try saved(workbook)
        for part in before.partNames where part != "docProps/core.xml" {
            #expect(try after.part(part) == before.part(part), "\(part)")
        }
    }

    @Test func aSnapshotKeepsCarriedContent() throws {
        let workbook = try open()
        let snapshot = WorkbookSnapshot(of: workbook)
        WorkbookOperations.deleteSheet(in: workbook, sheetID: workbook.sheets[0].id)
        snapshot.restore(into: workbook)
        #expect(try saved(workbook).names(under: "xl/charts/").count == 2)
    }
}
