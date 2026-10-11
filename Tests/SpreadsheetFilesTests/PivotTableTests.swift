import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Referential checks on a written package's pivot tables: everything Excel
/// follows from one part to another must land where it should. Compared
/// against the original file the pivots came from.
struct PivotPackageChecker {
    let original: Package
    let written: Package
    let workbook: Workbook

    /// Content type for a part: its Override, else the Default for its extension.
    static func contentTypes(_ package: Package) throws -> (overrides: [String: String], defaults: [String: String]) {
        var overrides: [String: String] = [:], defaults: [String: String] = [:]
        try XMLRewriter.scan(package.part("[Content_Types].xml")) { element in
            if element.localName == "Override", let name = element.attributes["PartName"] {
                overrides[name] = element.attributes["ContentType"]
            }
            if element.localName == "Default", let ext = element.attributes["Extension"] {
                defaults[ext.lowercased()] = element.attributes["ContentType"]
            }
            return .keep
        }
        return (overrides, defaults)
    }

    static func rootRelationships(_ package: Package) throws -> [XLSXReader.Relationship] {
        try XLSXReader.parseRelationships(package.part("_rels/.rels"), baseDir: "")
    }

    /// The workbook part's path and relationships.
    static func workbookPart(_ package: Package) throws -> (path: String, rels: [XLSXReader.Relationship]) {
        let path = try rootRelationships(package).first { $0.type.hasSuffix("/officeDocument") }!.target
        return (path, try package.relationships(of: path))
    }

    /// pivotCache cacheId -> definition part path.
    static func pivotCaches(_ package: Package) throws -> [Int: String] {
        let (path, rels) = try workbookPart(package)
        var result: [Int: String] = [:]
        try XMLRewriter.scan(package.part(path)) { element in
            if element.path == ["workbook", "pivotCaches", "pivotCache"],
               let id = Int(element.attributes["cacheId"] ?? ""),
               let key = element.attributeName(local: "id", namespace: OOXMLNamespace.relationships),
               let rel = rels.first(where: { $0.id == element.attributes[key] }) {
                #expect(result[id] == nil, "duplicate cacheId \(id)")
                #expect(rel.type == PivotRelationshipType.cacheDefinition)
                result[id] = rel.target
            }
            return .keep
        }
        return result
    }

    /// Custom number formats (id -> code) and raw dxfs of a package.
    static func styles(_ package: Package) throws -> (formats: [Int: String], dxfs: [String], tableStyles: Set<String>) {
        let (_, rels) = try workbookPart(package)
        guard let stylesPath = rels.first(where: { $0.type.hasSuffix("/styles") })?.target else {
            return ([:], [], [])
        }
        let data = try package.part(stylesPath)
        var formats: [Int: String] = [:]
        var tableStyles: Set<String> = []
        try XMLRewriter.scan(data) { element in
            if element.path == ["styleSheet", "numFmts", "numFmt"],
               let id = Int(element.attributes["numFmtId"] ?? "") {
                formats[id] = element.attributes["formatCode"]
            }
            if element.path == ["styleSheet", "tableStyles", "tableStyle"], let name = element.attributes["name"] {
                tableStyles.insert(name)
            }
            return .keep
        }
        let dxfs = try XMLRewriter.fragments(of: data) { $0.path == ["styleSheet", "dxfs", "dxf"] }
        return (formats, dxfs, tableStyles)
    }

    /// Pivot table parts with the sheet (part path) that links each.
    static func pivotTableParts(_ package: Package) throws -> [(sheet: String, table: String)] {
        let (_, rels) = try workbookPart(package)
        var result: [(String, String)] = []
        for sheetRel in rels where sheetRel.type.hasSuffix("/worksheet") {
            for rel in try package.relationships(of: sheetRel.target) where rel.type.hasSuffix("/pivotTable") {
                result.append((sheetRel.target, rel.target))
            }
        }
        return result
    }

    /// Normalized form of a part (lexical differences removed), with
    /// `adjust` applied to both sides of a comparison.
    static func normalized(_ data: Data, _ adjust: @escaping XMLRewriter.Visitor = { _ in .keep }) throws -> String {
        String(decoding: try XMLRewriter.rewrite(data, adjust), as: UTF8.self)
    }

    func checkPackageIntegrity() throws {
        // Every internal relationship resolves; every part has a content type.
        let (overrides, defaults) = try Self.contentTypes(written)
        for name in written.partNames where !name.hasSuffix("/") {
            if name == "[Content_Types].xml" { continue }
            if name.hasSuffix(".rels") { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            #expect(overrides["/" + name] != nil || defaults[ext] != nil, "\(name) has no content type")
            if name.hasPrefix("xl/pivot") {
                #expect(overrides["/" + name] != nil, "\(name) needs an Override")
            }
        }
        for partName in overrides.keys {
            #expect(written.has(String(partName.dropFirst())), "Override for missing part \(partName)")
        }
        for name in written.partNames where name.hasSuffix(".rels") {
            let base = name.replacingOccurrences(of: "_rels/", with: "")
            let source = String(base.dropLast(5))
            let rels = try XLSXReader.parseRelationships(written.part(name),
                                                         baseDir: XLSXReader.directory(of: source))
            #expect(Set(rels.map(\.id)).count == rels.count, "duplicate relationship ids in \(name)")
            for rel in rels where !rel.isExternal {
                #expect(written.has(rel.target), "\(name): \(rel.id) -> missing \(rel.target)")
            }
        }
    }

    func checkPivots() throws {
        try checkPackageIntegrity()
        let caches = try Self.pivotCaches(written)
        let tables = try Self.pivotTableParts(written)
        #expect(tables.count == workbook.pivotTables.count)
        #expect(caches.count == workbook.pivotCaches.count)
        #expect(Set(tables.map(\.table)).count == tables.count, "a pivot table part is linked twice")

        let originalStyles = try Self.styles(original)
        let writtenStyles = try Self.styles(written)
        let originalCaches = try Self.pivotCaches(original)
        let originalTables = try Self.pivotTableParts(original)

        // Caches: records link, records verbatim, definition unchanged apart
        // from the attributes the writer owns.
        for (cacheID, path) in caches {
            let rels = try written.relationships(of: path)
            var info = try XLSXReader.inspectCacheDefinition(written.part(path))
            if let recordsID = info.recordsRelID {
                let rel = rels.first { $0.id == recordsID }
                #expect(rel?.type == PivotRelationshipType.cacheRecords, "cache \(cacheID) records link")
            } else {
                #expect(!info.saveData || info.invalid, "cache \(cacheID) saves data but has no records")
            }
            for rel in rels where !rel.isExternal {
                #expect(rel.id == info.recordsRelID, "cache \(cacheID) has a stray relationship \(rel.id)")
            }
            let model = workbook.pivotCache(withID: cacheID)!
            let sources = info.worksheetSource.map { [$0] } ?? info.rangeSets
            #expect(sources.count == model.sourceRanges.count)
            for (element, source) in zip(sources, model.sourceRanges) {
                switch source.target {
                case .sheet(let id):
                    #expect(element.sheet == workbook.sheet(withID: id)?.name)
                    #expect(element.ref == source.ref)
                    #expect(element.name == nil)
                case .detached(let name):
                    #expect(element.sheet == name)
                case .external:
                    #expect(element.relID.map { id in rels.contains { $0.id == id && $0.isExternal } } == true)
                }
            }

            guard let originalPath = originalCaches[cacheID] else {
                Issue.record("cache \(cacheID) isn't in the original"); continue
            }
            let originalRels = try original.relationships(of: originalPath)
            let originalInfo = try XLSXReader.inspectCacheDefinition(original.part(originalPath))
            if let originalRecords = originalInfo.recordsRelID.flatMap({ id in originalRels.first { $0.id == id } }),
               let recordsID = info.recordsRelID, let rel = rels.first(where: { $0.id == recordsID }) {
                #expect(try written.part(rel.target) == original.part(originalRecords.target),
                        "cache \(cacheID) records changed")
            }
            for ext in originalRels where ext.isExternal {
                #expect(rels.contains { $0.id == ext.id && $0.isExternal && $0.target == ext.target && $0.type == ext.type })
            }
            // Mask owned attributes on both sides, then compare.
            let mask: XMLRewriter.Visitor = { element in
                if element.path == ["pivotCacheDefinition"] {
                    for ns in OOXMLNamespace.allRelationships {
                        if let key = element.attributeName(local: "id", namespace: ns) { element.attributes[key] = nil }
                    }
                    element.attributes["refreshOnLoad"] = nil
                }
                if element.localName == "worksheetSource" || element.localName == "rangeSet" {
                    for key in ["sheet", "ref", "name"] { element.attributes[key] = nil }
                }
                return .keep
            }
            #expect(try Self.normalized(written.part(path), mask) == Self.normalized(original.part(originalPath), mask),
                    "cache \(cacheID) definition changed beyond source/link attributes")
            info.numberFormatIDs.subtract(originalInfo.numberFormatIDs)
            #expect(info.numberFormatIDs.isEmpty)
            try checkStyleReferences(in: written.part(path), originalPart: original.part(originalPath),
                                     originalStyles: originalStyles, writtenStyles: writtenStyles, label: path)
        }

        // Tables: one cache link that agrees with cacheId; unchanged apart
        // from location and the dropped conditional formats.
        for (sheetPath, tablePath) in tables {
            let info = try XLSXReader.inspectPivotTable(written.part(tablePath))
            let rels = try written.relationships(of: tablePath)
            #expect(rels.count == 1 && rels[0].type == PivotRelationshipType.cacheDefinition)
            #expect(caches[info.cacheID ?? -1] == rels.first?.target, "\(tablePath) cacheId disagrees with its link")
            let xml = try written.string(tablePath)
            #expect(!xml.contains("conditionalFormats"), "\(tablePath) keeps conditional formats")

            // Match to the model and the original by sheet position + name.
            let (wbPath, wbRels) = try Self.workbookPart(written)
            _ = wbPath
            let sheetIndex = wbRels.filter { $0.type.hasSuffix("/worksheet") }
                .firstIndex { $0.target == sheetPath }!
            let sheet = workbook.sheets[sheetIndex]
            let model = workbook.pivotTables(onSheet: sheet.id).filter { $0.name == info.name }
            #expect(model.count == 1, "\(sheet.name)!\(info.name ?? "?") not uniquely in the model")
            if let model = model.first {
                #expect(info.locationRef == model.location.a1)
            }

            let candidates = try originalTables.filter { pair in
                try XLSXReader.inspectPivotTable(original.part(pair.table)).name == info.name
                    && pair.sheet.hasSuffix(".xml")
            }
            let mask: XMLRewriter.Visitor = { element in
                if element.path == ["pivotTableDefinition", "location"] { element.attributes["ref"] = nil }
                if element.path.count > 1 && element.localName == "conditionalFormats" { return .drop }
                return .keep
            }
            let mine = try Self.normalized(written.part(tablePath), mask)
            #expect(try candidates.contains { try Self.normalized(original.part($0.table), mask) == mine },
                    "\(tablePath) changed beyond its location")
            if let originalPart = candidates.first?.table {
                try checkStyleReferences(in: written.part(tablePath), originalPart: original.part(originalPart),
                                         originalStyles: originalStyles, writtenStyles: writtenStyles,
                                         label: tablePath)
            }
            // Custom pivot styles must exist.
            for styleInfo in try written.elements(["pivotTableDefinition", "pivotTableStyleInfo"], in: tablePath) {
                if let name = styleInfo["name"], !name.hasPrefix("PivotStyle") {
                    #expect(writtenStyles.tableStyles.contains(name), "\(tablePath) style \(name) missing")
                }
            }
        }
    }

    /// numFmtId / dxfId references must mean in the written stylesheet what
    /// they meant in the original.
    func checkStyleReferences(in part: Data, originalPart: Data,
                              originalStyles: (formats: [Int: String], dxfs: [String], tableStyles: Set<String>),
                              writtenStyles: (formats: [Int: String], dxfs: [String], tableStyles: Set<String>),
                              label: String) throws {
        var formatIDs: Set<Int> = [], dxfIDs: Set<Int> = []
        try XMLRewriter.scan(part) { element in
            if let id = Int(element.attributes["numFmtId"] ?? "") { formatIDs.insert(id) }
            if let id = Int(element.attributes["dxfId"] ?? "") { dxfIDs.insert(id) }
            return .keep
        }
        for id in formatIDs where id >= 164 {
            #expect(writtenStyles.formats[id] == originalStyles.formats[id],
                    "\(label): numFmtId \(id) is \(writtenStyles.formats[id] ?? "missing"), was \(originalStyles.formats[id] ?? "missing")")
        }
        func canonicalDxf(_ s: String) throws -> String {
            // Namespace declarations copied from the root differ; compare content.
            try Self.normalized(Data(s.utf8)) { element in
                for key in element.attributes.keys where key == "xmlns" || key.hasPrefix("xmlns:") {
                    element.attributes[key] = nil
                }
                return .keep
            }
        }
        for id in dxfIDs {
            #expect(id < writtenStyles.dxfs.count, "\(label): dxfId \(id) out of range")
            if id < writtenStyles.dxfs.count && id < originalStyles.dxfs.count {
                #expect(try canonicalDxf(writtenStyles.dxfs[id]) == canonicalDxf(originalStyles.dxfs[id]),
                        "\(label): dxf \(id) differs")
            }
        }
    }
}

// Serialized: XMLParser instances contend badly when dozens run at once
// (seconds of spinning versus well under one second in sequence).
@Suite("Pivot tables: real files", .serialized)
struct PivotFixtureTests {
    /// Expected outcome per fixture: tables kept, and the drop reasons.
    static let expectations: [String: (kept: Int, dropped: [String])] = [
        "calamine-pivots.xlsx": (5, []),
        "closedxml-ChartsheetAndPivotTable.xlsx": (1, []),
        "closedxml-Pivot_table_conditional_format.xlsx": (1, []),
        "closedxml-PivotCacheWithoutSourceData-input.xlsx": (1, []),
        "closedxml-PivotTable-AllSources-input.xlsx": (5, [
            "the cache reads from an external data connection",
            "the cache's scenario source isn't supported",
        ]),
        "closedxml-PivotTableWithBorder.xlsx": (1, []),
        "closedxml-TemplateWithTableSourcePivotTables.xlsx": (14, []),
        "closedxml-TwoPivotTablesWithSingleSource-input.xlsx": (2, []),
        "docx4j-cr022-data-model.xlsx": (0, [
            "the cache reads from an external data connection",
            "the pivot table reads from the Data Model",
        ]),
        "docx4j-cr022-slicers-timelines.xlsx": (2, []),
        "libreoffice-calcfields.xlsx": (1, []),
        "libreoffice-pivottable_rowcolpage_field_filter.xlsx": (1, []),
        "libreoffice-PivotTableFormatsSubTotals.xlsx": (1, []),
        "libreoffice-shared-nested-dategroup.xlsx": (2, []),
        "libreoffice-shared-numgroup.xlsx": (2, []),
        "openxmlsdk-filter_type.xlsx": (0, Array(repeating: "the pivot table uses Strict namespaces", count: 5)),
        "openxmlsdk-Pivot2.xlsx": (0, Array(repeating: "the cache reads from an external data connection", count: 3)),
        "openxmlsdk-pivot5.xlsx": (3, []),
        "poi-54436.xlsx": (1, []),
        "poi-DataTableCities.xlsx": (1, []),
        "poi-ExcelPivotTableSample.xlsx": (2, []),
        "poi-WithChartSheet.xlsx": (5, []),
        "powertools-QuarterlySales.xlsx": (1, []),
    ]

    @Test func everyFixtureHasAnExpectation() {
        #expect(Set(PivotFixtures.all) == Set(Self.expectations.keys))
    }

    @Test(arguments: PivotFixtures.all)
    func readsExpectedPivots(_ name: String) throws {
        let (workbook, report) = try PivotFixtures.read(name)
        let expected = try #require(Self.expectations[name])
        #expect(workbook.pivotTables.count == expected.kept)
        #expect(report.droppedPivots.map(\.reason).sorted() == expected.dropped.sorted())
        // Kept tables reference kept caches, and every kept cache is used.
        let cacheIDs = Set(workbook.pivotCaches.map(\.cacheID))
        #expect(Set(workbook.pivotTables.map(\.cacheID)) == cacheIDs)
        #expect(cacheIDs.count == workbook.pivotCaches.count)
        #expect((workbook.preservedStyles != nil) == !workbook.pivotTables.isEmpty)
    }

    @Test(arguments: PivotFixtures.all)
    func roundTripKeepsEveryReferenceIntact(_ name: String) throws {
        let originalData = try PivotFixtures.data(name)
        let (workbook, _) = try PivotFixtures.read(name)
        let written = try XLSXWriter.data(for: workbook)
        try PivotPackageChecker(original: Package(originalData), written: Package(written),
                                workbook: workbook).checkPivots()
    }

    @Test(arguments: PivotFixtures.all)
    func savingIsIdempotent(_ name: String) throws {
        let (workbook, _) = try PivotFixtures.read(name)
        let once = try XLSXWriter.data(for: workbook)
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: once, report: &report)
        #expect(report.droppedPivots.isEmpty, "our own output lost pivots: \(report.droppedPivots)")
        #expect(reread.pivotTables.count == workbook.pivotTables.count)
        let twice = try XLSXWriter.data(for: reread)
        // Byte-for-byte: every part of the second save matches the first.
        let a = try Package(once), b = try Package(twice)
        #expect(a.partNames == b.partNames)
        for part in a.partNames {
            #expect(try a.part(part) == b.part(part), "\(name): \(part) changed on the second save")
        }
    }

    @Test(arguments: PivotFixtures.all)
    func pivotCellsSurviveTheRoundTrip(_ name: String) throws {
        let (workbook, _) = try PivotFixtures.read(name)
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
        for table in workbook.pivotTables {
            let before = workbook.sheet(withID: table.sheetID)!
            let after = reread.sheet(named: before.name)!
            table.occupiedRange.forEachAddress { addr in
                #expect(before.value(at: addr) == after.value(at: addr), "\(name) \(before.name)!\(addr.a1)")
                let styleBefore = workbook.style(at: before.cell(at: addr).styleIndex)
                let styleAfter = reread.style(at: after.cell(at: addr).styleIndex)
                #expect(styleBefore == styleAfter, "\(name) \(before.name)!\(addr.a1) style")
            }
        }
    }

    @Test(arguments: PivotFixtures.all)
    func editsKeepEveryReferenceIntact(_ name: String) throws {
        let originalData = try PivotFixtures.data(name)
        let (workbook, _) = try PivotFixtures.read(name)
        guard !workbook.pivotTables.isEmpty else { return }
        let expected = PivotFixtureEdits.apply(to: workbook)
        let writtenData = try XLSXWriter.data(for: workbook)
        try PivotPackageChecker(original: Package(originalData), written: Package(writtenData),
                                workbook: workbook).checkPivots()

        // Re-read: locations, sources and the moved cells all line up.
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: writtenData, report: &report)
        #expect(report.droppedPivots.isEmpty)
        for table in reread.pivotTables {
            let sheet = reread.sheet(withID: table.sheetID)!
            let key = "\(sheet.name)!\(table.name)"
            #expect(expected.locations[key] == table.location.a1, "\(name) \(key)")
            for (addr, value) in expected.cells[key] ?? [:] {
                #expect(sheet.value(at: addr) == value, "\(name) \(key) \(addr.a1)")
            }
        }
        for cache in reread.pivotCaches {
            #expect(expected.sources[cache.cacheID] == cache.sourceRanges.map(\.ref), "\(name) cache \(cache.cacheID)")
            for range in cache.sourceRanges {
                if case .sheet(let id) = range.target {
                    #expect(reread.sheet(withID: id)!.name.hasPrefix("X "), "\(name): source sheet not renamed")
                }
            }
        }
    }

    // MARK: Specific behaviours seen in real files

    @Test func tableSourceBecomesItsRangeWithoutTheTotalsRow() throws {
        let (workbook, _) = try PivotFixtures.read("poi-ExcelPivotTableSample.xlsx")
        let sheet = try #require(workbook.sheet(named: "Tabelle1"))
        let sources = workbook.pivotCaches.flatMap(\.sourceRanges)
        #expect(sources.allSatisfy { $0.target == .sheet(id: sheet.id) })
        #expect(Set(sources.map(\.ref)) == ["A1:C4", "E1:G4"])
        let written = try Package(XLSXWriter.data(for: workbook))
        for (_, path) in try PivotPackageChecker.pivotCaches(written) {
            let source = try #require(try XLSXReader.inspectCacheDefinition(written.part(path)).worksheetSource)
            #expect(source.name == nil && source.sheet == "Tabelle1")
        }
    }

    @Test func definedNameSourceResolvesToItsRange() throws {
        let (workbook, _) = try PivotFixtures.read("closedxml-PivotTable-AllSources-input.xlsx")
        let cache = try #require(workbook.pivotCache(withID: 2))
        let sheet = try #require(workbook.sheet(named: "Defined Name Source"))
        // 'Defined Name Source'!$B$2:$C$3
        #expect(cache.sourceRanges == [PivotSourceRange(target: .sheet(id: sheet.id), ref: "B2:C3")])
    }

    @Test func externalWorkbookSourceIsCarriedVerbatim() throws {
        let (workbook, _) = try PivotFixtures.read("closedxml-PivotTable-AllSources-input.xlsx")
        let cache = try #require(workbook.pivotCache(withID: 3))
        #expect(cache.sourceRanges == [PivotSourceRange(target: .external, ref: "A1:B3")])
        let written = try Package(XLSXWriter.data(for: workbook))
        let path = try #require(try PivotPackageChecker.pivotCaches(written)[3])
        let source = try #require(try XLSXReader.inspectCacheDefinition(written.part(path)).worksheetSource)
        // The external sheet name is NOT this workbook's Sheet1.
        #expect(source.sheet == "Sheet1" && source.ref == "A1:B3")
        let rel = try written.relationships(of: path).first { $0.id == source.relID }
        #expect(rel?.isExternal == true)
        #expect(rel?.target == "PivotTable-AllSources-external-data.xlsx")
        #expect(rel?.type.hasSuffix("/externalLinkPath") == true)
    }

    @Test func consolidationSourcesTrackEachRange() throws {
        let (workbook, _) = try PivotFixtures.read("closedxml-PivotTable-AllSources-input.xlsx")
        let cache = try #require(workbook.pivotCache(withID: 6))
        let sheet = try #require(workbook.sheet(named: "Consolidate"))
        #expect(cache.sourceRanges.map(\.ref) == ["A1:B3", "D1:E2"])
        #expect(cache.sourceRanges.allSatisfy { $0.target == .sheet(id: sheet.id) })
    }

    @Test func pageFieldsWidenTheOccupiedArea() throws {
        let (workbook, _) = try PivotFixtures.read("libreoffice-pivottable_rowcolpage_field_filter.xlsx")
        let table = try #require(workbook.pivotTables.first)
        #expect(table.location.a1 == "A4:B6")
        #expect(table.pageFieldRows == 1)
        #expect(table.occupiedRange.a1 == "A2:B6") // filter row 2, blank row 3
    }

    @Test func differentialFormatsArePreservedInOrder() throws {
        let name = "libreoffice-PivotTableFormatsSubTotals.xlsx"
        let original = try Package(PivotFixtures.data(name))
        let (workbook, _) = try PivotFixtures.read(name)
        let written = try Package(XLSXWriter.data(for: workbook))
        let before = try PivotPackageChecker.styles(original).dxfs
        let after = try PivotPackageChecker.styles(written).dxfs
        #expect(before.count >= 17)
        #expect(after.count == before.count)
    }

    @Test func customNumberFormatsKeepTheirIDs() throws {
        let name = "closedxml-TemplateWithTableSourcePivotTables.xlsx"
        let (workbook, _) = try PivotFixtures.read(name)
        let original = try PivotPackageChecker.styles(Package(PivotFixtures.data(name))).formats
        let preserved = try #require(workbook.preservedStyles).numberFormats
        #expect(preserved[165] != nil)
        #expect(preserved[165] == original[165])
        let written = try PivotPackageChecker.styles(Package(XLSXWriter.data(for: workbook))).formats
        for (id, code) in preserved { #expect(written[id] == code) }
    }

    @Test func pivotConditionalFormatsAreRemoved() throws {
        let name = "closedxml-Pivot_table_conditional_format.xlsx"
        let original = try Package(PivotFixtures.data(name))
        #expect(try PivotPackageChecker.pivotTableParts(original).contains {
            try original.string($0.table).contains("conditionalFormats")
        })
        let (workbook, _) = try PivotFixtures.read(name)
        let written = try Package(XLSXWriter.data(for: workbook))
        for (_, table) in try PivotPackageChecker.pivotTableParts(written) {
            #expect(try !written.string(table).contains("conditionalFormats"))
        }
    }

    @Test func pivotButtonStylesRoundTrip() throws {
        let (workbook, _) = try PivotFixtures.read("poi-54436.xlsx")
        #expect(workbook.styles.styles.contains { $0.pivotButton })
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(try written.string("xl/styles.xml").contains("pivotButton=\"1\""))
    }

    @Test func droppedPivotsLoseTheirFieldButtons() throws {
        // Every pivot here is dropped; its cells mustn't keep Excel's
        // field-button flag with no pivot behind it.
        for name in ["openxmlsdk-Pivot2.xlsx", "docx4j-cr022-data-model.xlsx", "openxmlsdk-filter_type.xlsx"] {
            let (workbook, _) = try PivotFixtures.read(name)
            let used = Set(workbook.sheets.flatMap { $0.cells.values.map(\.styleIndex) })
            #expect(!used.contains { workbook.style(at: $0).pivotButton }, "\(name)")
            // Unused xfs may keep the flag (styles are never pruned); no cell
            // may point at one after a save either.
            let reread = try XLSXReader.read(data: XLSXWriter.data(for: workbook))
            let usedAfter = Set(reread.sheets.flatMap { $0.cells.values.map(\.styleIndex) })
            #expect(!usedAfter.contains { reread.style(at: $0).pivotButton }, "\(name) after save")
        }
    }

    @Test func dxfNumberFormatIDsAreNeverReused() throws {
        for name in ["openxmlsdk-pivot5.xlsx", "closedxml-TemplateWithTableSourcePivotTables.xlsx"] {
            let original = try Package(PivotFixtures.data(name))
            let (workbook, _) = try PivotFixtures.read(name)
            let reserved = try #require(workbook.preservedStyles).reservedNumberFormatIDs
            #expect(!reserved.isEmpty, "\(name)")
            let before = try PivotPackageChecker.styles(original).formats
            let after = try PivotPackageChecker.styles(Package(XLSXWriter.data(for: workbook))).formats
            // A global format may only take a dxf's id if the original did too.
            for id in reserved where after[id] != nil {
                #expect(before[id] == after[id], "\(name): numFmt \(id) reused for \(after[id] ?? "")")
            }
        }
    }

    @Test func droppedPivotsLeaveTheirCellsAndNoParts() throws {
        let name = "openxmlsdk-Pivot2.xlsx"
        let (workbook, _) = try PivotFixtures.read(name)
        let written = try Package(XLSXWriter.data(for: workbook))
        #expect(!written.partNames.contains { $0.hasPrefix("xl/pivot") })
        #expect(try !written.string("xl/workbook.xml").contains("pivotCaches"))
        #expect(workbook.preservedStyles == nil)
        #expect(workbook.sheets.contains { !$0.cells.isEmpty })
    }
}
