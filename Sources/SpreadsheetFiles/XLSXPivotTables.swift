import Foundation
import SpreadsheetCore

// Pivot table preservation: read the pivot parts of an XLSX package into the
// workbook's pivot model, and write them back on save.
//
// The parts are carried verbatim. On save only what edits can invalidate is
// patched: the table's location, the cache's source sheet/range, relationship
// ids. Stylesheet references inside the parts (numFmtId, dxfId, pivot style
// names) stay valid because the writer re-emits the stylesheet entries they
// point at under their original ids (see PreservedStyles).
//
// Pivots are preserved only when that is known to be safe; anything else is
// dropped as before, leaving its rendered cells as plain values. Dropped:
// caches fed by a data connection, OLAP or the Data Model (they need
// connections.xml and workbook extensions SimpleSpread doesn't keep),
// scenario caches, sources naming a table or defined name that can't be
// resolved to a range, Strict-namespace parts, and 1904-date workbooks (the
// cache's serial numbers would disagree with the converted cells).

/// What the reader couldn't carry over.
struct XLSXReadReport {
    struct DroppedPivot: Equatable {
        /// Host sheet and table name, or nil for a cache with no table.
        var sheetName: String?
        var tableName: String?
        var cacheID: Int?
        var reason: String
    }
    var droppedPivots: [DroppedPivot] = []
    /// What the file holds that saving will not write back (see UnsupportedContent).
    var unsupportedContent: [String] = []
}

struct ExternalRelationship: Equatable, Sendable {
    let id: String
    let type: String
    let target: String
}

struct PivotCachePayload: PreservedPartPayload {
    var definition: Data
    var records: Data?
    /// External relationships of the definition part (an external workbook
    /// source's r:id points at one). Written back under their original ids.
    var externalRelationships: [ExternalRelationship]
}

struct PivotTablePayload: PreservedPartPayload {
    var definition: Data
}

enum OOXMLNamespace {
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let strictRelationships = "http://purl.oclc.org/ooxml/officeDocument/relationships"
    static let allRelationships = [relationships, strictRelationships]
}

enum PivotRelationshipType {
    static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let pivotTable = base + "pivotTable"
    static let cacheDefinition = base + "pivotCacheDefinition"
    static let cacheRecords = base + "pivotCacheRecords"
}

enum PivotContentType {
    static let table = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml"
    static let cacheDefinition = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml"
    static let cacheRecords = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheRecords+xml"
}

/// The id attribute in either relationships namespace, whatever its prefix.
private func relationshipIDAttribute(of element: XMLRewriter.Element) -> String? {
    for ns in OOXMLNamespace.allRelationships {
        if let name = element.attributeName(local: "id", namespace: ns) { return name }
    }
    return nil
}

private func xmlBool(_ value: String?, default def: Bool) -> Bool {
    guard let v = value?.lowercased() else { return def }
    return v == "1" || v == "true"
}

// MARK: - Reading

extension XLSXReader {
    struct SheetPart {
        let sheetID: Int
        /// Position in workbook.xml <sheets> (what localSheetId counts).
        let sheetIndex: Int
        let path: String
    }

    struct PivotReadContext {
        let zip: ZipArchiveReader
        let workbookInfo: WorkbookInfo
        let workbookRels: [Relationship]
        let sheetParts: [SheetPart]
        let stylesData: Data?
        let customFormats: [Int: String]
    }

    /// One worksheetSource or rangeSet as written.
    struct SourceElement: Equatable {
        var ref: String?
        var sheet: String?
        var name: String?
        var relID: String?
    }

    struct CacheDefinitionInfo {
        var isTransitional = false
        var saveData = true
        var invalid = false
        var recordsRelID: String?
        var sourceType: String?
        var worksheetSource: SourceElement?
        var rangeSets: [SourceElement] = []
        var numberFormatIDs: Set<Int> = []
        /// x15 sourceConnection / pivotCacheIdVersion: tied to a data
        /// connection or the Data Model whatever the cacheSource type says.
        var usesConnection = false
    }

    struct PivotTableInfo {
        var isTransitional = false
        var name: String?
        var cacheID: Int?
        var locationRef: String?
        var rowPageCount = 0
        var colPageCount = 0
        var numberFormatIDs: Set<Int> = []
        /// x15:pivotTableUISettings@sourceDataName names a Data Model connection.
        var usesConnection = false
    }

    static func inspectCacheDefinition(_ data: Data) throws -> CacheDefinitionInfo {
        var info = CacheDefinitionInfo()
        try XMLRewriter.scan(data) { element in
            if let id = Int(element.attributes["numFmtId"] ?? "") { info.numberFormatIDs.insert(id) }
            if element.localName == "sourceConnection" || element.localName == "pivotCacheIdVersion" {
                info.usesConnection = true
            }
            func source() -> SourceElement {
                SourceElement(ref: element.attributes["ref"], sheet: element.attributes["sheet"],
                              name: element.attributes["name"],
                              relID: relationshipIDAttribute(of: element).flatMap { element.attributes[$0] })
            }
            switch element.path {
            case ["pivotCacheDefinition"]:
                info.isTransitional = element.namespaceURI == OOXMLNamespace.main
                info.saveData = xmlBool(element.attributes["saveData"], default: true)
                info.invalid = xmlBool(element.attributes["invalid"], default: false)
                info.recordsRelID = relationshipIDAttribute(of: element).flatMap { element.attributes[$0] }
            case ["pivotCacheDefinition", "cacheSource"]:
                info.sourceType = element.attributes["type"] ?? "worksheet"
            case ["pivotCacheDefinition", "cacheSource", "worksheetSource"]:
                info.worksheetSource = source()
            case ["pivotCacheDefinition", "cacheSource", "consolidation", "rangeSets", "rangeSet"]:
                info.rangeSets.append(source())
            default:
                break
            }
            return .keep
        }
        return info
    }

    static func inspectPivotTable(_ data: Data) throws -> PivotTableInfo {
        var info = PivotTableInfo()
        try XMLRewriter.scan(data) { element in
            if let id = Int(element.attributes["numFmtId"] ?? "") { info.numberFormatIDs.insert(id) }
            if element.localName == "pivotTableUISettings", element.attributes["sourceDataName"] != nil {
                info.usesConnection = true
            }
            switch element.path {
            case ["pivotTableDefinition"]:
                info.isTransitional = element.namespaceURI == OOXMLNamespace.main
                info.name = element.attributes["name"]
                info.cacheID = Int(element.attributes["cacheId"] ?? "")
            case ["pivotTableDefinition", "location"]:
                info.locationRef = element.attributes["ref"]
                info.rowPageCount = Int(element.attributes["rowPageCount"] ?? "") ?? 0
                info.colPageCount = Int(element.attributes["colPageCount"] ?? "") ?? 0
            default:
                break
            }
            return .keep
        }
        return info
    }

    /// A table (ListObject) a cache source may name.
    struct TableInfo {
        let name: String
        let displayName: String
        let sheetID: Int
        /// The table range minus any totals row (what a pivot reads).
        let dataRange: CellRange
    }

    static func readTables(_ ctx: PivotReadContext) -> [TableInfo] {
        var tables: [TableInfo] = []
        for part in ctx.sheetParts {
            guard let rels = try? relationships(of: part.path, in: ctx.zip) else { continue }
            for rel in rels where !rel.isExternal && rel.type.hasSuffix("/table") {
                guard let data = try? zipData(ctx.zip, rel.target) else { continue }
                var attrs: [String: String] = [:]
                try? XMLRewriter.scan(data) { element in
                    if element.path == ["table"] { attrs = element.attributes }
                    return element.path.count == 1 ? .keep : .drop
                }
                guard let name = attrs["name"] ?? attrs["displayName"], let ref = attrs["ref"],
                      let range = CellRange(a1: ref),
                      (Int(attrs["headerRowCount"] ?? "") ?? 1) > 0 else { continue }
                let totals = Int(attrs["totalsRowCount"] ?? "") ?? 0
                let endRow = range.end.row - max(0, totals)
                guard endRow >= range.start.row else { continue }
                tables.append(TableInfo(
                    name: name, displayName: attrs["displayName"] ?? name, sheetID: part.sheetID,
                    dataRange: CellRange(start: range.start,
                                         end: CellAddress(row: endRow, column: range.end.column))))
            }
        }
        return tables
    }

    /// Resolve a source naming a defined name or table to a sheet range.
    static func resolveNamedSource(_ name: String, sheetHint: String?, ctx: PivotReadContext,
                                   workbook: Workbook, tables: [TableInfo]) -> PivotSourceRange? {
        func matches(_ a: String) -> Bool { a.caseInsensitiveCompare(name) == .orderedSame }

        // Defined names: a sheet-scoped one on the hinted sheet wins, then workbook scope.
        let hintedIndex = sheetHint.flatMap { hint in
            ctx.sheetParts.first { workbook.sheet(withID: $0.sheetID)?.name
                .caseInsensitiveCompare(hint) == .orderedSame }?.sheetIndex
        }
        let names = ctx.workbookInfo.definedNames.filter { matches($0.name) }
        let candidate = names.first { $0.localSheetIndex != nil && $0.localSheetIndex == hintedIndex }
            ?? names.first { $0.localSheetIndex == nil }
        if let defined = candidate {
            var formula = defined.formula.trimmingCharacters(in: .whitespacesAndNewlines)
            if formula.hasPrefix("=") { formula.removeFirst() }
            guard let expr = try? FormulaParser.parse(formula), case .reference(var ref) = expr,
                  let sheetName = ref.sheetName, let sheet = workbook.sheet(named: sheetName) else {
                return nil
            }
            ref.sheetName = nil
            ref.start.columnAbsolute = false
            ref.start.rowAbsolute = false
            ref.end?.columnAbsolute = false
            ref.end?.rowAbsolute = false
            return PivotSourceRange(target: .sheet(id: sheet.id), ref: ref.text)
        }
        if let table = tables.first(where: { matches($0.name) || matches($0.displayName) }) {
            return PivotSourceRange(target: .sheet(id: table.sheetID), ref: table.dataRange.a1)
        }
        return nil
    }

    static func readPivotTables(_ ctx: PivotReadContext, into workbook: Workbook) -> [XLSXReadReport.DroppedPivot] {
        typealias Dropped = XLSXReadReport.DroppedPivot
        var dropped: [Dropped] = []

        // Every pivot table part the sheets link to, in sheet order.
        struct TablePart {
            let sheetID: Int
            let path: String
        }
        var tableParts: [TablePart] = []
        var seenTableParts: Set<String> = []
        for part in ctx.sheetParts {
            guard let rels = try? relationships(of: part.path, in: ctx.zip) else { continue }
            for rel in rels where !rel.isExternal && rel.type.hasSuffix("/pivotTable") {
                if seenTableParts.insert(rel.target).inserted {
                    tableParts.append(TablePart(sheetID: part.sheetID, path: rel.target))
                }
            }
        }
        guard !tableParts.isEmpty else { return [] }

        func sheetName(_ id: Int) -> String? { workbook.sheet(withID: id)?.name }
        func dropAll(_ reason: String) -> [Dropped] {
            tableParts.map { part in
                let name = (try? zipData(ctx.zip, part.path)).flatMap { try? inspectPivotTable($0).name }
                return Dropped(sheetName: sheetName(part.sheetID), tableName: name, cacheID: nil, reason: reason)
            }
        }
        if ctx.workbookInfo.date1904 {
            return dropAll("the workbook uses the 1904 date system")
        }

        // Caches, keyed by their definition part path.
        struct LoadedCache {
            let cache: PivotCache
            let numberFormatIDs: Set<Int>
        }
        var caches: [String: LoadedCache] = [:]
        var cacheFailures: [String: (cacheID: Int, reason: String)] = [:]
        var cacheOrder: [String] = []
        let tables = readTables(ctx)
        // A cache id listed twice can't be told apart by the tables using it.
        let idCounts = Dictionary(grouping: ctx.workbookInfo.pivotCaches, by: \.cacheID).mapValues(\.count)

        for meta in ctx.workbookInfo.pivotCaches {
            guard let rel = ctx.workbookRels.first(where: { $0.id == meta.relID }),
                  !rel.isExternal, rel.type.hasSuffix("/pivotCacheDefinition") else { continue }
            let path = rel.target
            func fail(_ reason: String) { cacheFailures[path] = (meta.cacheID, reason) }
            guard caches[path] == nil, cacheFailures[path] == nil else {
                fail("two cache ids share one cache definition")
                caches[path] = nil
                continue
            }
            guard idCounts[meta.cacheID] == 1 else { fail("the cache id \(meta.cacheID) is listed twice"); continue }
            guard let data = try? zipData(ctx.zip, path),
                  let info = try? inspectCacheDefinition(data) else {
                fail("the cache definition is missing or unreadable"); continue
            }
            guard info.isTransitional else { fail("the cache uses Strict namespaces"); continue }
            guard !info.usesConnection else { fail("the cache reads from an external data connection"); continue }
            guard let rels = try? relationships(of: path, in: ctx.zip) else {
                fail("the cache's relationships are unreadable"); continue
            }

            // Records: required unless saveData="0" or invalid="1".
            var records: Data?
            if let recordsID = info.recordsRelID {
                guard let recordsRel = rels.first(where: { $0.id == recordsID }), !recordsRel.isExternal,
                      recordsRel.type.hasSuffix("/pivotCacheRecords"),
                      let recordsData = try? zipData(ctx.zip, recordsRel.target) else {
                    fail("the cache records are missing"); continue
                }
                records = recordsData
            } else if info.saveData && !info.invalid {
                fail("the cache records are missing"); continue
            }
            let unexpected = rels.filter { !$0.isExternal && $0.id != info.recordsRelID }
            guard unexpected.isEmpty else {
                fail("the cache links to parts SimpleSpread doesn't keep"); continue
            }
            let externals = rels.filter(\.isExternal)
                .map { ExternalRelationship(id: $0.id, type: $0.type, target: $0.target) }

            // Sources.
            enum Resolution {
                case range(PivotSourceRange)
                case unsupported(String)
            }
            func resolve(_ element: SourceElement) -> Resolution {
                if let relID = element.relID {
                    guard externals.contains(where: { $0.id == relID }) else {
                        return .unsupported("the cache source's link is missing")
                    }
                    return .range(PivotSourceRange(target: .external, ref: element.ref ?? ""))
                }
                if let ref = element.ref {
                    guard let sheet = element.sheet, !sheet.isEmpty else {
                        return .unsupported("the cache source has no sheet")
                    }
                    if let live = workbook.sheet(named: sheet) {
                        return .range(PivotSourceRange(target: .sheet(id: live.id), ref: ref))
                    }
                    return .range(PivotSourceRange(target: .detached(sheetName: sheet), ref: ref))
                }
                if let name = element.name {
                    if let resolved = resolveNamedSource(name, sheetHint: element.sheet, ctx: ctx,
                                                         workbook: workbook, tables: tables) {
                        return .range(resolved)
                    }
                    return .unsupported("the cache source “\(name)” isn't a range SimpleSpread can find")
                }
                return .unsupported("the cache has no source range")
            }

            let elements: [SourceElement]
            switch info.sourceType {
            case "worksheet":
                elements = info.worksheetSource.map { [$0] } ?? []
            case "consolidation":
                elements = info.rangeSets
            case "external":
                fail("the cache reads from an external data connection"); continue
            default:
                fail("the cache's \(info.sourceType ?? "unknown") source isn't supported"); continue
            }
            guard !elements.isEmpty else { fail("the cache has no source range"); continue }
            var sources: [PivotSourceRange] = []
            var sourceFailure: String?
            for element in elements {
                switch resolve(element) {
                case .range(let range): sources.append(range)
                case .unsupported(let reason): sourceFailure = sourceFailure ?? reason
                }
            }
            if let reason = sourceFailure { fail(reason); continue }

            caches[path] = LoadedCache(
                cache: PivotCache(cacheID: meta.cacheID, sourceRanges: sources,
                                  payload: PivotCachePayload(definition: data, records: records,
                                                             externalRelationships: externals)),
                numberFormatIDs: info.numberFormatIDs)
            cacheOrder.append(path)
        }

        // Tables.
        var keptTables: [PivotTable] = []
        var usedCaches: Set<String> = []
        var numberFormatIDs: Set<Int> = []
        for part in tableParts {
            let host = sheetName(part.sheetID)
            guard let data = try? zipData(ctx.zip, part.path),
                  let info = try? inspectPivotTable(data) else {
                dropped.append(Dropped(sheetName: host, tableName: nil, cacheID: nil,
                                       reason: "the pivot table definition is unreadable"))
                continue
            }
            func drop(_ reason: String, cacheID: Int? = nil) {
                dropped.append(Dropped(sheetName: host, tableName: info.name, cacheID: cacheID ?? info.cacheID,
                                       reason: reason))
            }
            guard info.isTransitional else { drop("the pivot table uses Strict namespaces"); continue }
            guard !info.usesConnection else { drop("the pivot table reads from the Data Model"); continue }
            guard let name = info.name, let cacheID = info.cacheID,
                  let ref = info.locationRef, let location = CellRange(a1: ref) else {
                drop("the pivot table definition is incomplete"); continue
            }
            guard let rels = try? relationships(of: part.path, in: ctx.zip) else {
                drop("the pivot table's relationships are unreadable"); continue
            }
            let cacheRels = rels.filter { !$0.isExternal && $0.type.hasSuffix("/pivotCacheDefinition") }
            guard cacheRels.count == 1, rels.filter({ !$0.isExternal }).count == 1 else {
                drop("the pivot table's links aren't the expected single cache"); continue
            }
            let cachePath = cacheRels[0].target
            if let failure = cacheFailures[cachePath] {
                drop(failure.reason, cacheID: failure.cacheID); continue
            }
            guard let loaded = caches[cachePath] else {
                drop("the pivot table's cache isn't listed in the workbook"); continue
            }
            guard loaded.cache.cacheID == cacheID else {
                drop("the pivot table's cache id doesn't match its cache"); continue
            }
            usedCaches.insert(cachePath)
            numberFormatIDs.formUnion(info.numberFormatIDs)
            keptTables.append(PivotTable(
                sheetID: part.sheetID, name: name, cacheID: cacheID, location: location,
                pageFieldRows: info.rowPageCount, pageFieldColumns: info.colPageCount,
                payload: PivotTablePayload(definition: data)))
        }

        guard !keptTables.isEmpty else { return dropped }
        // Typed views for the engine (nil where a part doesn't parse). Caches
        // parse on first use; their records are most of a pivot's bytes.
        let formats = PivotXMLParser.FormatTable(custom: ctx.customFormats)
        for path in cacheOrder where usedCaches.contains(path) {
            guard var cache = caches[path]?.cache, let loaded = caches[path] else { continue }
            if let payload = cache.payload as? PivotCachePayload {
                cache.loadDataLazily {
                    try? PivotXMLParser.parseCache(definition: payload.definition, records: payload.records, formats: formats)
                }
            }
            workbook.pivotCaches.append(cache)
            numberFormatIDs.formUnion(loaded.numberFormatIDs)
        }
        for i in keptTables.indices {
            if let payload = keptTables[i].payload as? PivotTablePayload {
                keptTables[i].definition = try? PivotXMLParser.parseTable(payload.definition, formats: formats)
            }
        }
        workbook.pivotTables = keptTables

        var preserved = PreservedStyles()
        for id in numberFormatIDs where id >= 164 {
            if let code = ctx.customFormats[id] { preserved.numberFormats[id] = code }
        }
        if let styles = ctx.stylesData {
            preserved.differentialFormats = (try? XMLRewriter.fragments(of: styles) {
                $0.path == ["styleSheet", "dxfs", "dxf"]
            }) ?? []
            try? XMLRewriter.scan(styles) { element in
                if element.path.count > 3, element.path.prefix(3) == ["styleSheet", "dxfs", "dxf"],
                   element.localName == "numFmt", let id = Int(element.attributes["numFmtId"] ?? ""), id >= 164 {
                    preserved.reservedNumberFormatIDs.insert(id)
                }
                return .keep
            }
            preserved.tableStyles = (try? XMLRewriter.fragments(of: styles) {
                $0.path == ["styleSheet", "tableStyles"]
            })?.first
        }
        workbook.preservedStyles = preserved
        return dropped
    }
}

// MARK: - Writing

extension XLSXWriter {
    struct PackageRelationship {
        let id: String
        let type: String
        let target: String
        var isExternal = false
    }

    struct PivotPackage {
        var entries: [(path: String, data: Data)] = []
        var contentTypes: [(partName: String, contentType: String)] = []
        var workbookRelationships: [PackageRelationship] = []
        /// `<pivotCaches>` for workbook.xml, or "" without pivots.
        var workbookElement = ""
        /// Worksheet relationships by sheet position.
        var sheetRelationships: [Int: [PackageRelationship]] = [:]
    }

    /// Number formats the generated (modified) pivot parts refer to.
    static func generatedPivotFormats(_ workbook: Workbook) -> [NumberFormat] {
        var formats: [NumberFormat] = []
        for cache in workbook.pivotCaches where cache.isModified {
            formats += cache.data?.fields.map(\.numberFormat) ?? []
        }
        for table in workbook.pivotTables where table.isModified {
            guard let d = table.definition else { continue }
            formats += d.fields.compactMap(\.numberFormat) + d.dataFields.compactMap(\.numberFormat)
        }
        return formats
    }

    /// The parts to write for a cache: generated when modified, else as read.
    static func cachePayload(_ cache: PivotCache, workbook: Workbook,
                             formatID: (NumberFormat) -> Int) throws -> PivotCachePayload? {
        let original = cache.payload as? PivotCachePayload
        guard cache.isModified, let data = cache.data else { return original }
        let definitions = workbook.pivotTables.filter { $0.cacheID == cache.cacheID }.compactMap(\.definition)
        let listed = PivotXMLWriter.listedFields(data, definitions: definitions)
        let carry = try original.map {
            try PivotXMLWriter.CarryOver($0.definition, root: "pivotCacheDefinition", keep: ["cacheSource", "extLst"])
        } ?? PivotXMLWriter.CarryOver()
        let fallbackSource = "<cacheSource type=\"worksheet\"><worksheetSource ref=\"A1\" sheet=\"Sheet1\"/></cacheSource>"
        let definition = PivotXMLWriter.cacheDefinitionXML(
            data, listed: listed, carry: carry, sourceFallback: fallbackSource,
            refreshedDate: ExcelDate.nowSerial(), formatID: formatID)
        return PivotCachePayload(definition: Data(definition.utf8),
                                 records: Data(PivotXMLWriter.recordsXML(data, listed: listed).utf8),
                                 externalRelationships: original?.externalRelationships ?? [])
    }

    /// The part to write for a table: generated when modified, else as read.
    static func tablePayload(_ table: PivotTable, formatID: (NumberFormat) -> Int) throws -> PivotTablePayload? {
        let original = table.payload as? PivotTablePayload
        guard table.isModified, let d = table.definition else { return original }
        let carry = try original.map {
            try PivotXMLWriter.CarryOver($0.definition, root: "pivotTableDefinition",
                                         keep: ["pivotTableStyleInfo", "filters", "extLst"])
        } ?? PivotXMLWriter.CarryOver()
        let layout = PivotLayoutResult(
            rowLines: d.rowLines, columnLines: d.columnLines, firstHeaderRow: d.firstHeaderRow,
            firstDataRow: d.firstDataRow, firstDataCol: d.firstDataCol, rowCount: table.location.rowCount,
            columnCount: table.location.columnCount, cells: [:], pageRows: table.pageFieldRows,
            pageColumns: table.pageFieldColumns, isEmpty: false)
        let xml = PivotXMLWriter.tableDefinitionXML(d, cacheID: table.cacheID, result: layout,
                                                    location: table.location, carry: carry, formatID: formatID)
        return PivotTablePayload(definition: Data(xml.utf8))
    }

    /// Lay out the pivot parts. Workbook relationship ids start at
    /// `firstWorkbookRelID` (the writer's own come first).
    static func pivotPackage(for workbook: Workbook, firstWorkbookRelID: Int,
                             formatID: (NumberFormat) -> Int = { _ in 0 }) throws -> PivotPackage {
        var package = PivotPackage()
        // Only tables on live sheets whose cache exists, and only caches in use.
        let liveTables = workbook.sheets.flatMap { sheet in
            workbook.pivotTables(onSheet: sheet.id).filter { workbook.pivotCache(withID: $0.cacheID) != nil }
        }
        let usedIDs = Set(liveTables.map(\.cacheID))
        let caches = workbook.pivotCaches.filter { usedIDs.contains($0.cacheID) }
        guard !caches.isEmpty else { return package }

        var cachePartNumber: [Int: Int] = [:]
        var pivotCacheEntries = ""
        for (i, cache) in caches.enumerated() {
            guard let payload = try cachePayload(cache, workbook: workbook, formatID: formatID) else { continue }
            let n = i + 1
            cachePartNumber[cache.cacheID] = n
            let definitionPath = "xl/pivotCache/pivotCacheDefinition\(n).xml"

            var rels = payload.externalRelationships.map {
                PackageRelationship(id: $0.id, type: $0.type, target: $0.target, isExternal: true)
            }
            var recordsID: String?
            if let records = payload.records {
                let taken = Set(rels.map(\.id))
                var k = 1
                while taken.contains("rId\(k)") { k += 1 }
                recordsID = "rId\(k)"
                let recordsPath = "xl/pivotCache/pivotCacheRecords\(n).xml"
                rels.append(PackageRelationship(id: "rId\(k)", type: PivotRelationshipType.cacheRecords,
                                                target: "pivotCacheRecords\(n).xml"))
                package.entries.append((recordsPath, records))
                package.contentTypes.append(("/" + recordsPath, PivotContentType.cacheRecords))
            }
            let definition = try patchedCacheDefinition(cache, payload: payload, recordsRelID: recordsID,
                                                        workbook: workbook)
            package.entries.append((definitionPath, definition))
            package.contentTypes.append(("/" + definitionPath, PivotContentType.cacheDefinition))
            if !rels.isEmpty {
                package.entries.append(("xl/pivotCache/_rels/pivotCacheDefinition\(n).xml.rels",
                                        Data(relationshipsXML(rels).utf8)))
            }

            let relID = "rId\(firstWorkbookRelID + i)"
            package.workbookRelationships.append(PackageRelationship(
                id: relID, type: PivotRelationshipType.cacheDefinition,
                target: "pivotCache/pivotCacheDefinition\(n).xml"))
            pivotCacheEntries += "<pivotCache cacheId=\"\(cache.cacheID)\" r:id=\"\(relID)\"/>"
        }
        package.workbookElement = "<pivotCaches>\(pivotCacheEntries)</pivotCaches>"

        var tableNumber = 0
        for (sheetIndex, sheet) in workbook.sheets.enumerated() {
            var sheetRels: [PackageRelationship] = []
            for table in workbook.pivotTables(onSheet: sheet.id) {
                guard let cacheN = cachePartNumber[table.cacheID],
                      let payload = try tablePayload(table, formatID: formatID) else { continue }
                tableNumber += 1
                let path = "xl/pivotTables/pivotTable\(tableNumber).xml"
                package.entries.append((path, try patchedPivotTable(table, payload: payload)))
                package.contentTypes.append(("/" + path, PivotContentType.table))
                package.entries.append(("xl/pivotTables/_rels/pivotTable\(tableNumber).xml.rels",
                                        Data(relationshipsXML([PackageRelationship(
                                            id: "rId1", type: PivotRelationshipType.cacheDefinition,
                                            target: "../pivotCache/pivotCacheDefinition\(cacheN).xml")]).utf8)))
                sheetRels.append(PackageRelationship(
                    id: "rId\(sheetRels.count + 1)", type: PivotRelationshipType.pivotTable,
                    target: "../pivotTables/pivotTable\(tableNumber).xml"))
            }
            if !sheetRels.isEmpty { package.sheetRelationships[sheetIndex] = sheetRels }
        }
        return package
    }

    static func relationshipsXML(_ rels: [PackageRelationship]) -> String {
        var s = xmlHeader
        s += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for rel in rels {
            s += "<Relationship Id=\"\(XML.escapeAttribute(rel.id))\" Type=\"\(XML.escapeAttribute(rel.type))\""
            s += " Target=\"\(XML.escapeAttribute(rel.target))\""
            if rel.isExternal { s += " TargetMode=\"External\"" }
            s += "/>"
        }
        s += "</Relationships>"
        return s
    }

    /// The cache definition with its source ranges and records link brought
    /// up to date.
    static func patchedCacheDefinition(_ cache: PivotCache, payload: PivotCachePayload,
                                       recordsRelID: String?, workbook: Workbook) throws -> Data {
        var sourceIndex = 0
        return try rewriteIfChanged(payload.definition) { element in
            switch element.path {
            case ["pivotCacheDefinition"]:
                let existing = relationshipIDAttribute(of: element)
                if let recordsRelID {
                    if let existing {
                        element.attributes[existing] = recordsRelID
                    } else {
                        let prefix = element.prefix(forNamespace: OOXMLNamespace.relationships) ?? {
                            element.attributes["xmlns:r"] = OOXMLNamespace.relationships
                            return "r"
                        }()
                        element.attributes["\(prefix):id"] = recordsRelID
                    }
                } else if let existing {
                    element.attributes[existing] = nil
                }
                // Never ask Excel to refresh from a source that's gone.
                if cache.hasDetachedSource { element.attributes["refreshOnLoad"] = nil }
            case ["pivotCacheDefinition", "cacheSource", "worksheetSource"],
                 ["pivotCacheDefinition", "cacheSource", "consolidation", "rangeSets", "rangeSet"]:
                defer { sourceIndex += 1 }
                guard sourceIndex < cache.sourceRanges.count else { break }
                let source = cache.sourceRanges[sourceIndex]
                let sheetName: String?
                switch source.target {
                case .sheet(let id): sheetName = workbook.sheet(withID: id)?.name
                case .detached(let name): sheetName = name
                case .external: sheetName = nil
                }
                if let sheetName {
                    element.attributes["sheet"] = sheetName
                    element.attributes["ref"] = source.ref
                    element.attributes["name"] = nil
                }
            default:
                break
            }
            return .keep
        }
    }

    /// `data` rewritten by `visit` — or, when the visit changes nothing, the
    /// original bytes, so a pivot saved unchanged is written back exactly
    /// (the rewriter would otherwise reorder attributes and drop unused
    /// namespace declarations).
    static func rewriteIfChanged(_ data: Data, _ visit: XMLRewriter.Visitor) throws -> Data {
        var changed = false
        let output = try XMLRewriter.rewrite(data) { element in
            let before = element.attributes
            let action = visit(&element)
            if action == .drop || element.attributes != before { changed = true }
            return action
        }
        return changed ? output : data
    }

    /// The pivot table with its location brought up to date. Conditional
    /// formats are removed: they must pair with the sheet's pivot
    /// conditional formatting, which SimpleSpread doesn't keep.
    static func patchedPivotTable(_ table: PivotTable, payload: PivotTablePayload) throws -> Data {
        try rewriteIfChanged(payload.definition) { element in
            if element.path == ["pivotTableDefinition", "location"] {
                element.attributes["ref"] = table.location.a1
            }
            if element.path.count > 1 && element.localName == "conditionalFormats" {
                return .drop
            }
            return .keep
        }
    }
}
