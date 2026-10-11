import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Builds a small XLSX package with one pivot table, with knobs for the
/// irregularities a reader has to survive.
struct PivotPackageBuilder {
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let pkgRel = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    /// Attributes for <worksheetSource>.
    var worksheetSource = #"ref="A1:B4" sheet="Data""#
    /// Root attributes of the cache definition besides xmlns.
    var cacheRootAttributes = #"r:id="rId1" refreshOnLoad="1""#
    /// Prefix the cache definition binds the relationships namespace to.
    var relPrefix = "r"
    var cacheSourceType = "worksheet"
    var includeRecords = true
    var recordsInRels = true
    var extraCacheRels = ""
    var workbookCacheID = 9
    var tableCacheID = 9
    var listCacheInWorkbook = true
    var tableLinksCache = true
    var location = #"ref="A3:B6" firstHeaderRow="1" firstDataRow="1" firstDataCol="1""#
    var date1904 = false
    var definedNames = ""
    var dataSheetRels = ""
    var extraParts: [(String, String)] = []
    var tableExtra = ""
    var cacheFieldNumFmt = 0
    var dataFieldNumFmt: Int?
    var stylesNumFmts = ""
    var stylesDxfs = ""

    func build() -> Data {
        var zip = ZipArchiveWriter()
        func add(_ name: String, _ text: String) { zip.addEntry(name: name, data: Data(text.utf8)) }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        add("[Content_Types].xml", header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/></Types>
        """)
        add("_rels/.rels", header + """
        <Relationships xmlns="\(Self.pkgRel)"><Relationship Id="rId1" Type="\(Self.relType)officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        let caches = listCacheInWorkbook
            ? "<pivotCaches><pivotCache cacheId=\"\(workbookCacheID)\" r:id=\"rId9\"/></pivotCaches>" : ""
        add("xl/workbook.xml", header + """
        <workbook xmlns="\(Self.main)" xmlns:r="\(Self.rel)"><workbookPr date1904="\(date1904 ? 1 : 0)"/>\
        <sheets><sheet name="Data" sheetId="1" r:id="rId1"/><sheet name="Report" sheetId="2" r:id="rId2"/></sheets>\
        \(definedNames.isEmpty ? "" : "<definedNames>\(definedNames)</definedNames>")\(caches)</workbook>
        """)
        add("xl/_rels/workbook.xml.rels", header + """
        <Relationships xmlns="\(Self.pkgRel)">\
        <Relationship Id="rId1" Type="\(Self.relType)worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="\(Self.relType)worksheet" Target="worksheets/sheet2.xml"/>\
        <Relationship Id="rId3" Type="\(Self.relType)styles" Target="styles.xml"/>\
        <Relationship Id="rId9" Type="\(Self.relType)pivotCacheDefinition" Target="pivotCache/pivotCacheDefinition1.xml"/>\
        </Relationships>
        """)
        add("xl/styles.xml", header + """
        <styleSheet xmlns="\(Self.main)">\(stylesNumFmts)<cellXfs count="1"><xf numFmtId="0"/></cellXfs>\(stylesDxfs)</styleSheet>
        """)
        add("xl/worksheets/sheet1.xml", header + """
        <worksheet xmlns="\(Self.main)"><sheetData>\
        <row r="1"><c r="A1" t="inlineStr"><is><t>Name</t></is></c><c r="B1" t="inlineStr"><is><t>Qty</t></is></c></row>\
        <row r="2"><c r="A2" t="inlineStr"><is><t>a</t></is></c><c r="B2"><v>1</v></c></row>\
        <row r="3"><c r="A3" t="inlineStr"><is><t>b</t></is></c><c r="B3"><v>2</v></c></row>\
        <row r="4"><c r="A4" t="inlineStr"><is><t>a</t></is></c><c r="B4"><v>3</v></c></row>\
        </sheetData></worksheet>
        """)
        if !dataSheetRels.isEmpty {
            add("xl/worksheets/_rels/sheet1.xml.rels", header + "<Relationships xmlns=\"\(Self.pkgRel)\">\(dataSheetRels)</Relationships>")
        }
        add("xl/worksheets/sheet2.xml", header + """
        <worksheet xmlns="\(Self.main)"><sheetData>\
        <row r="3"><c r="A3" t="inlineStr"><is><t>Row Labels</t></is></c><c r="B3" t="inlineStr"><is><t>Sum of Qty</t></is></c></row>\
        <row r="4"><c r="A4" t="inlineStr"><is><t>a</t></is></c><c r="B4"><v>4</v></c></row>\
        <row r="5"><c r="A5" t="inlineStr"><is><t>b</t></is></c><c r="B5"><v>2</v></c></row>\
        <row r="6"><c r="A6" t="inlineStr"><is><t>Grand Total</t></is></c><c r="B6"><v>6</v></c></row>\
        </sheetData></worksheet>
        """)
        add("xl/worksheets/_rels/sheet2.xml.rels", header + """
        <Relationships xmlns="\(Self.pkgRel)"><Relationship Id="rId1" Type="\(Self.relType)pivotTable" Target="../pivotTables/pivotTable1.xml"/></Relationships>
        """)
        let cacheRoot = cacheRootAttributes.replacingOccurrences(of: "r:id", with: "\(relPrefix):id")
        let source = cacheSourceType == "worksheet"
            ? "<cacheSource type=\"worksheet\"><worksheetSource \(worksheetSource.replacingOccurrences(of: "r:id", with: "\(relPrefix):id"))/></cacheSource>"
            : "<cacheSource type=\"\(cacheSourceType)\" connectionId=\"1\"/>"
        add("xl/pivotCache/pivotCacheDefinition1.xml", header + """
        <pivotCacheDefinition xmlns="\(Self.main)" xmlns:\(relPrefix)="\(Self.rel)" \(cacheRoot) recordCount="3">\
        \(source)<cacheFields count="2">\
        <cacheField name="Name" numFmtId="0"><sharedItems count="2"><s v="a"/><s v="b"/></sharedItems></cacheField>\
        <cacheField name="Qty" numFmtId="\(cacheFieldNumFmt)"><sharedItems containsSemiMixedTypes="0" containsString="0" containsNumber="1" containsInteger="1" minValue="1" maxValue="3"/></cacheField>\
        </cacheFields></pivotCacheDefinition>
        """)
        var cacheRels = extraCacheRels
        if recordsInRels {
            cacheRels += "<Relationship Id=\"rId1\" Type=\"\(Self.relType)pivotCacheRecords\" Target=\"pivotCacheRecords1.xml\"/>"
        }
        if !cacheRels.isEmpty {
            add("xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels", header + "<Relationships xmlns=\"\(Self.pkgRel)\">\(cacheRels)</Relationships>")
        }
        if includeRecords {
            add("xl/pivotCache/pivotCacheRecords1.xml", header + """
            <pivotCacheRecords xmlns="\(Self.main)" count="3"><r><x v="0"/><n v="1"/></r><r><x v="1"/><n v="2"/></r><r><x v="0"/><n v="3"/></r></pivotCacheRecords>
            """)
        }
        let dataFieldFormat = dataFieldNumFmt.map { " numFmtId=\"\($0)\"" } ?? ""
        add("xl/pivotTables/pivotTable1.xml", header + """
        <pivotTableDefinition xmlns="\(Self.main)" name="PivotTable1" cacheId="\(tableCacheID)" dataCaption="Values">\
        <location \(location)/>\
        <pivotFields count="2"><pivotField axis="axisRow" showAll="0"><items count="3"><item x="0"/><item x="1"/><item t="default"/></items></pivotField>\
        <pivotField dataField="1" showAll="0"/></pivotFields>\
        <rowFields count="1"><field x="0"/></rowFields>\
        <rowItems count="3"><i><x/></i><i><x v="1"/></i><i t="grand"><x/></i></rowItems>\
        <colItems count="1"><i/></colItems>\
        <dataFields count="1"><dataField name="Sum of Qty" fld="1" baseField="0" baseItem="0"\(dataFieldFormat)/></dataFields>\
        \(tableExtra)\
        <pivotTableStyleInfo name="PivotStyleLight16" showRowHeaders="1" showColHeaders="1"/></pivotTableDefinition>
        """)
        if tableLinksCache {
            add("xl/pivotTables/_rels/pivotTable1.xml.rels", header + """
            <Relationships xmlns="\(Self.pkgRel)"><Relationship Id="rId1" Type="\(Self.relType)pivotCacheDefinition" Target="../pivotCache/pivotCacheDefinition1.xml"/></Relationships>
            """)
        }
        for (name, text) in extraParts { add(name, text) }
        return zip.finalize()
    }

    func read() throws -> (Workbook, XLSXReadReport) {
        var report = XLSXReadReport()
        let workbook = try XLSXReader.read(data: build(), report: &report)
        return (workbook, report)
    }
}

@Suite("Pivot tables: reading irregular files")
struct PivotReaderEdgeTests {
    private func dropReason(_ builder: PivotPackageBuilder) throws -> String? {
        let (workbook, report) = try builder.read()
        if workbook.pivotTables.isEmpty { return report.droppedPivots.first?.reason ?? "dropped silently" }
        return nil
    }

    @Test func baselineIsKept() throws {
        let (workbook, report) = try PivotPackageBuilder().read()
        #expect(report.droppedPivots.isEmpty)
        let table = try #require(workbook.pivotTables.first)
        #expect(table.name == "PivotTable1" && table.cacheID == 9 && table.location.a1 == "A3:B6")
        #expect(workbook.sheet(withID: table.sheetID)?.name == "Report")
        let data = try #require(workbook.sheet(named: "Data"))
        #expect(workbook.pivotCaches.first?.sourceRanges == [PivotSourceRange(target: .sheet(id: data.id), ref: "A1:B4")])
    }

    @Test func relationshipPrefixIsResolvedByNamespace() throws {
        var builder = PivotPackageBuilder()
        builder.relPrefix = "ns1"
        let (workbook, report) = try builder.read()
        #expect(report.droppedPivots.isEmpty)
        let payload = try #require(workbook.pivotCaches.first?.payload as? PivotCachePayload)
        #expect(payload.records != nil)
        // Written back under the producer's prefix, pointing at the records.
        let written = try Package(XLSXWriter.data(for: workbook))
        let xml = try written.string("xl/pivotCache/pivotCacheDefinition1.xml")
        #expect(xml.contains("ns1:id=\"rId1\""))
        #expect(!xml.contains(" r:id="))
    }

    @Test func missingRecordsDropThePivot() throws {
        var builder = PivotPackageBuilder()
        builder.includeRecords = false
        #expect(try dropReason(builder) == "the cache records are missing")
        builder = PivotPackageBuilder()
        builder.recordsInRels = false
        builder.includeRecords = false
        #expect(try dropReason(builder) == "the cache records are missing")
    }

    @Test func cacheWithoutSavedDataIsKeptWithoutRecords() throws {
        var builder = PivotPackageBuilder()
        builder.cacheRootAttributes = #"saveData="0""#
        builder.includeRecords = false
        builder.recordsInRels = false
        let (workbook, report) = try builder.read()
        #expect(report.droppedPivots.isEmpty)
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(!written.has("xl/pivotCache/pivotCacheRecords1.xml"))
        #expect(!written.has("xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels"))
        #expect(try !written.string("xl/pivotCache/pivotCacheDefinition1.xml").contains(":id="))
    }

    @Test func invalidCacheMayOmitRecords() throws {
        var builder = PivotPackageBuilder()
        builder.cacheRootAttributes = #"invalid="1" refreshOnLoad="1""#
        builder.includeRecords = false
        builder.recordsInRels = false
        #expect(try dropReason(builder) == nil)
    }

    @Test func mismatchedCacheIDDropsTheTable() throws {
        var builder = PivotPackageBuilder()
        builder.tableCacheID = 3
        #expect(try dropReason(builder) == "the pivot table's cache id doesn't match its cache")
    }

    @Test func tableWithoutCacheLinkIsDropped() throws {
        var builder = PivotPackageBuilder()
        builder.tableLinksCache = false
        #expect(try dropReason(builder) == "the pivot table's links aren't the expected single cache")
    }

    @Test func cacheMissingFromWorkbookDropsTheTable() throws {
        var builder = PivotPackageBuilder()
        builder.listCacheInWorkbook = false
        #expect(try dropReason(builder) == "the pivot table's cache isn't listed in the workbook")
    }

    @Test func duplicateCacheIDsAreDropped() throws {
        // A second <pivotCache> entry reusing id 9 for another relationship.
        let zip = try ZipArchiveReader(data: PivotPackageBuilder().build())
        var writer = ZipArchiveWriter()
        for entry in zip.entries {
            var bytes = try zip.contents(of: entry)
            if entry.name == "xl/workbook.xml" {
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(
                    of: "</pivotCaches>", with: "<pivotCache cacheId=\"9\" r:id=\"rId3\"/></pivotCaches>").utf8)
            }
            writer.addEntry(name: entry.name, data: bytes)
        }
        var report = XLSXReadReport()
        let workbook = try XLSXReader.read(data: writer.finalize(), report: &report)
        #expect(workbook.pivotTables.isEmpty)
        #expect(report.droppedPivots.map(\.reason) == ["the cache id 9 is listed twice"])
    }

    @Test func dataModelMarkersDropWorksheetTypedCaches() throws {
        var builder = PivotPackageBuilder()
        builder.tableExtra = #"<extLst><ext uri="{E67621CE-5B39-4880-91FE-76760E9C1902}" xmlns:x15="http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"><x15:pivotTableUISettings sourceDataName="ThisWorkbookDataModel"/></ext></extLst>"#
        #expect(try dropReason(builder) == "the pivot table reads from the Data Model")
        // Plain UI settings without a connection are fine.
        builder.tableExtra = #"<extLst><ext uri="{E67621CE-5B39-4880-91FE-76760E9C1902}" xmlns:x15="http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"><x15:pivotTableUISettings/></ext></extLst>"#
        #expect(try dropReason(builder) == nil)
    }

    @Test func extensionPivotCacheListsAreNotTheMainList() throws {
        // x15 lists in the workbook extLst repeat ids; only <pivotCaches> counts.
        let zip = try ZipArchiveReader(data: PivotPackageBuilder().build())
        var writer = ZipArchiveWriter()
        for entry in zip.entries {
            var bytes = try zip.contents(of: entry)
            if entry.name == "xl/workbook.xml" {
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "</workbook>", with:
                    #"<extLst><ext uri="{A2CB5862-8E78-49c6-8D9D-AF26E26ADB89}" xmlns:x15="http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"><x15:timelineCachePivotCaches><pivotCache cacheId="9" r:id="rId9"/></x15:timelineCachePivotCaches></ext></extLst></workbook>"#).utf8)
            }
            writer.addEntry(name: entry.name, data: bytes)
        }
        var report = XLSXReadReport()
        let workbook = try XLSXReader.read(data: writer.finalize(), report: &report)
        #expect(report.droppedPivots.isEmpty)
        #expect(workbook.pivotTables.count == 1)
    }

    @Test func connectionSourcesAreDropped() throws {
        var builder = PivotPackageBuilder()
        builder.cacheSourceType = "external"
        #expect(try dropReason(builder) == "the cache reads from an external data connection")
    }

    @Test func unexpectedInternalCacheLinkIsDropped() throws {
        var builder = PivotPackageBuilder()
        builder.extraCacheRels = "<Relationship Id=\"rId7\" Type=\"\(PivotPackageBuilder.relType)customXml\" Target=\"../customXml/item1.xml\"/>"
        #expect(try dropReason(builder) == "the cache links to parts SimpleSpread doesn't keep")
    }

    @Test func malformedLocationIsDropped() throws {
        var builder = PivotPackageBuilder()
        builder.location = #"ref="not a range" firstHeaderRow="1" firstDataRow="1" firstDataCol="1""#
        #expect(try dropReason(builder) == "the pivot table definition is incomplete")
    }

    @Test func sourceWithoutSheetIsDropped() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"ref="A1:B4""#
        #expect(try dropReason(builder) == "the cache source has no sheet")
    }

    @Test func workbooksOn1904DatesDropPivots() throws {
        var builder = PivotPackageBuilder()
        builder.date1904 = true
        #expect(try dropReason(builder) == "the workbook uses the 1904 date system")
    }

    @Test func sourceOnAMissingSheetIsKeptDetached() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"ref="A1:B4" sheet="Archive""#
        let (workbook, _) = try builder.read()
        #expect(workbook.pivotCaches.first?.sourceRanges == [PivotSourceRange(target: .detached(sheetName: "Archive"), ref: "A1:B4")])
        // Never ask Excel to refresh on open from a source that isn't there.
        let written = try Package(XLSXWriter.data(for: workbook))
        let xml = try written.string("xl/pivotCache/pivotCacheDefinition1.xml")
        #expect(!xml.contains("refreshOnLoad"))
        #expect(xml.contains(#"sheet="Archive""#))
    }

    @Test func refreshOnLoadIsLeftAloneOtherwise() throws {
        let (workbook, _) = try PivotPackageBuilder().read()
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(try written.string("xl/pivotCache/pivotCacheDefinition1.xml").contains(#"refreshOnLoad="1""#))
    }

    @Test func sourceSheetNameMatchesCaseInsensitively() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"ref="A1:B4" sheet="DATA""#
        let (workbook, _) = try builder.read()
        let data = try #require(workbook.sheet(named: "Data"))
        #expect(workbook.pivotCaches.first?.sourceRanges.first?.target == .sheet(id: data.id))
        // Written with the sheet's actual name.
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(try written.string("xl/pivotCache/pivotCacheDefinition1.xml").contains(#"sheet="Data""#))
    }

    @Test func unresolvableNameIsDropped() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"name="Nowhere""#
        #expect(try dropReason(builder) == "the cache source “Nowhere” isn't a range SimpleSpread can find")
    }

    @Test func definedNameResolvesAndScopedNameWins() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"name="Sales""#
        builder.definedNames = "<definedName name=\"Sales\">Data!$A$1:$B$3</definedName>"
        var (workbook, _) = try builder.read()
        #expect(workbook.pivotCaches.first?.sourceRanges.first?.ref == "A1:B3")

        // A sheet-scoped name on the hinted sheet beats the workbook one.
        builder.worksheetSource = #"name="Sales" sheet="Data""#
        builder.definedNames = "<definedName name=\"Sales\">Data!$A$1:$B$3</definedName>"
            + "<definedName name=\"Sales\" localSheetId=\"0\">Data!$A$1:$B$4</definedName>"
        (workbook, _) = try builder.read()
        #expect(workbook.pivotCaches.first?.sourceRanges.first?.ref == "A1:B4")
    }

    @Test func nonRangeDefinedNameIsDropped() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"name="Sales""#
        builder.definedNames = "<definedName name=\"Sales\">OFFSET(Data!$A$1,0,0,4,2)</definedName>"
        #expect(try dropReason(builder) == "the cache source “Sales” isn't a range SimpleSpread can find")
    }

    @Test func tableSourceExcludesTheTotalsRow() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"name="SalesTable""#
        builder.dataSheetRels = "<Relationship Id=\"rId1\" Type=\"\(PivotPackageBuilder.relType)table\" Target=\"../tables/table1.xml\"/>"
        builder.extraParts = [("xl/tables/table1.xml", """
        <?xml version="1.0" encoding="UTF-8"?><table xmlns="\(PivotPackageBuilder.main)" id="1" name="SalesTable" \
        displayName="SalesTable" ref="A1:B5" totalsRowCount="1"><tableColumns count="2"><tableColumn id="1" name="Name"/>\
        <tableColumn id="2" name="Qty"/></tableColumns></table>
        """)]
        let (workbook, report) = try builder.read()
        #expect(report.droppedPivots.isEmpty)
        let data = try #require(workbook.sheet(named: "Data"))
        #expect(workbook.pivotCaches.first?.sourceRanges == [PivotSourceRange(target: .sheet(id: data.id), ref: "A1:B4")])
        let written = try Package(XLSXWriter.data(for: workbook))
        let source = try written.elements(["pivotCacheDefinition", "cacheSource", "worksheetSource"],
                                          in: "xl/pivotCache/pivotCacheDefinition1.xml")
        #expect(source == [["ref": "A1:B4", "sheet": "Data"]])
    }

    @Test func externalWorkbookSourceNeedsItsLink() throws {
        var builder = PivotPackageBuilder()
        builder.worksheetSource = #"ref="A1:B4" sheet="Sheet1" r:id="rId5""#
        #expect(try dropReason(builder) == "the cache source's link is missing")
        builder.extraCacheRels = "<Relationship Id=\"rId5\" Type=\"\(PivotPackageBuilder.relType)externalLinkPath\" Target=\"file:///Other%20Book.xlsx\" TargetMode=\"External\"/>"
        let (workbook, _) = try builder.read()
        #expect(workbook.pivotCaches.first?.sourceRanges == [PivotSourceRange(target: .external, ref: "A1:B4")])
        let written = try Package(XLSXWriter.data(for: workbook))
        let rels = try written.string("xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels")
        #expect(rels.contains(#"Id="rId5""#) && rels.contains(#"TargetMode="External""#))
        #expect(rels.contains(#"Target="file:///Other%20Book.xlsx""#))
        // Records take a free id rather than colliding.
        #expect(try written.string("xl/pivotCache/pivotCacheDefinition1.xml").contains(#"r:id="rId1""#))
    }
}

@Suite("Pivot tables: writing after edits")
struct PivotWriterEditTests {
    private func cacheSource(_ written: Package) throws -> [String: String]? {
        try written.elements(["pivotCacheDefinition", "cacheSource", "worksheetSource"],
                             in: "xl/pivotCache/pivotCacheDefinition1.xml").first
    }

    private func location(_ written: Package) throws -> String? {
        try written.elements(["pivotTableDefinition", "location"], in: "xl/pivotTables/pivotTable1.xml").first?["ref"]
    }

    @Test func renamingTheSourceSheetUpdatesTheSource() throws {
        let (workbook, _) = try PivotPackageBuilder().read()
        let data = try #require(workbook.sheet(named: "Data"))
        WorkbookOperations.renameSheet(in: workbook, sheetID: data.id, to: "Sales & Returns")
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(try cacheSource(written) == ["ref": "A1:B4", "sheet": "Sales & Returns"])
    }

    @Test func insertingRowsMovesTableAndGrowsSource() throws {
        let (workbook, _) = try PivotPackageBuilder().read()
        let data = try #require(workbook.sheet(named: "Data"))
        let report = try #require(workbook.sheet(named: "Report"))
        WorkbookOperations.insertRows(in: workbook, sheetID: report.id, at: 0, count: 2)
        WorkbookOperations.insertRows(in: workbook, sheetID: data.id, at: 2, count: 1)
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(try location(written) == "A5:B8")
        #expect(try cacheSource(written)?["ref"] == "A1:B5")
        // The table's cells moved with it.
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        #expect(reread.sheet(named: "Report")?.value(at: CellAddress(a1: "A5")!) == .string("Row Labels"))
    }

    @Test func deletingTheSourceSheetDetachesAndStopsRefreshOnLoad() throws {
        let (workbook, _) = try PivotPackageBuilder().read()
        let data = try #require(workbook.sheet(named: "Data"))
        WorkbookOperations.deleteSheet(in: workbook, sheetID: data.id)
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(try cacheSource(written) == ["ref": "A1:B4", "sheet": "Data"])
        #expect(try !written.string("xl/pivotCache/pivotCacheDefinition1.xml").contains("refreshOnLoad"))
        // The table is now on the first sheet: its rels follow it.
        #expect(written.has("xl/worksheets/_rels/sheet1.xml.rels"))
        #expect(!written.has("xl/worksheets/_rels/sheet2.xml.rels"))
        // Still readable as a pivot after the save.
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook), report: &report)
        #expect(report.droppedPivots.isEmpty)
        #expect(reread.pivotCaches.first?.sourceRanges.first?.target == .detached(sheetName: "Data"))
    }

    @Test func deletingTheHostSheetRemovesEveryPivotPart() throws {
        let (workbook, _) = try PivotPackageBuilder().read()
        let report = try #require(workbook.sheet(named: "Report"))
        WorkbookOperations.deleteSheet(in: workbook, sheetID: report.id)
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(!written.partNames.contains { $0.contains("pivot") })
        #expect(try !written.string("xl/workbook.xml").contains("pivotCaches"))
        #expect(try !written.string("[Content_Types].xml").contains("pivot"))
        #expect(try !written.string("xl/_rels/workbook.xml.rels").contains("pivot"))
    }

    @Test func reorderingSheetsKeepsTablesWithTheirSheet() throws {
        let (workbook, _) = try PivotPackageBuilder().read()
        let report = try #require(workbook.sheet(named: "Report"))
        workbook.moveSheet(withID: report.id, to: 0)
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(try written.relationships(of: "xl/worksheets/sheet1.xml").map(\.target) == ["xl/pivotTables/pivotTable1.xml"])
        #expect(!written.has("xl/worksheets/_rels/sheet2.xml.rels"))
    }

    @Test func preservedFormatIDsStayAndNewFormatsGoAbove() throws {
        var builder = PivotPackageBuilder()
        builder.stylesNumFmts = ##"<numFmts count="2"><numFmt numFmtId="170" formatCode="0.0%"/><numFmt numFmtId="200" formatCode="#,##0.000"/></numFmts>"##
        builder.cacheFieldNumFmt = 170
        builder.dataFieldNumFmt = 200
        let (workbook, _) = try builder.read()
        #expect(workbook.preservedStyles?.numberFormats == [170: "0.0%", 200: "#,##0.000"])
        // A cell using a preserved code shares its id; a new code goes above.
        let sheet = workbook.sheets[0]
        sheet.setCell(Cell(value: .number(1), styleIndex: workbook.styleIndex(for: CellStyle(numberFormat: NumberFormat(code: "#,##0.000")))),
                      at: CellAddress(a1: "D1")!)
        sheet.setCell(Cell(value: .number(1), styleIndex: workbook.styleIndex(for: CellStyle(numberFormat: NumberFormat(code: "0.00000")))),
                      at: CellAddress(a1: "D2")!)
        let written = try Package(XLSXWriter.data(for: workbook))
        let formats = try PivotPackageChecker.styles(written).formats
        #expect(formats[170] == "0.0%" && formats[200] == "#,##0.000")
        #expect(formats.filter { $0.value == "#,##0.000" }.count == 1)
        #expect(formats.first { $0.value == "0.00000" }.map(\.key) == 201)
    }

    @Test func dxfsKeepTheirPositions() throws {
        var builder = PivotPackageBuilder()
        builder.stylesDxfs = #"<dxfs count="2"><dxf><font><b/></font></dxf><dxf><fill><patternFill><bgColor rgb="FFFFFF00"/></patternFill></fill></dxf></dxfs>"#
        builder.tableExtra = #"<formats count="1"><format dxfId="1"><pivotArea type="all" dataOnly="0" outline="0" fieldPosition="0"/></format></formats>"#
        let (workbook, _) = try builder.read()
        let written = try Package(XLSXWriter.data(for: workbook))
        let dxfs = try PivotPackageChecker.styles(written).dxfs
        try #require(dxfs.count == 2)
        #expect(dxfs[1].contains("FFFFFF00"))
        #expect(try written.string("xl/pivotTables/pivotTable1.xml").contains(#"dxfId="1""#))
    }

    @Test func noPivotsMeansNoPivotOutput() throws {
        let workbook = Workbook.newDocument()
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(!written.partNames.contains { $0.contains("pivot") || $0.hasPrefix("xl/worksheets/_rels") })
        #expect(try !written.string("xl/styles.xml").contains("dxfs"))
    }

    @Test func writtenSyntheticPackagePassesTheChecker() throws {
        let builder = PivotPackageBuilder()
        let (workbook, _) = try builder.read()
        try PivotPackageChecker(original: Package(builder.build()), written: Package(XLSXWriter.data(for: workbook)),
                                workbook: workbook).checkPivots()
    }
}
