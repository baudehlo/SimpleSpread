import Foundation
import SpreadsheetCore

// Reading what an XLSX holds beyond the model into CarriedParts.
//
// Carried: every part a worksheet links to (drawings with their charts and
// images, comments and their VML, threaded comments, tables, OLE objects
// and controls, printer settings, …), the parts those link to in turn, the
// worksheet elements the writer doesn't produce, and at workbook level the
// theme, links to other workbooks, the people behind threaded comments,
// custom XML and custom document properties.
//
// Not carried, and still reported at open as lost on save: anything that
// needs workbook-level parts or settings SimpleSpread doesn't keep — chart
// sheets, macros, slicers and timelines, data connections, query tables and
// the Data Model, linked data types, change history, signatures, add-ins.
// A part is carried only if everything it links to is; a worksheet element
// pointing at a part that isn't goes too, so no link is left dangling.
// Sheets in the Strict namespaces aren't carried either.

extension XLSXReader {
    /// `<worksheet>` children the writer produces itself.
    static let writtenWorksheetElements: Set<String> = [
        "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "autoFilter", "mergeCells",
    ]

    /// `<workbook>` children carried as written. (bookViews, sheets,
    /// definedNames and pivotCaches are the writer's; calcPr and extLst are
    /// left out: they hold settings and links to parts that aren't kept.)
    static let carriedWorkbookElements: Set<String> = [
        "fileSharing", "workbookProtection", "functionGroups", "externalReferences", "oleSize",
        "customWorkbookViews", "smartTagPr", "smartTagTypes", "webPublishing", "fileRecoveryPr",
        "webPublishObjects",
    ]

    /// Relationship types carried from the workbook part, by suffix.
    static let carriedWorkbookRelationships = ["/theme", "/externalLink", "/customXml", "/person"]
    /// Relationship types carried from the package root, by suffix.
    static let carriedPackageRelationships = ["/custom-properties"]
    /// Worksheet relationships never carried (the writer's own, or parts
    /// that need workbook-level caches).
    static let uncarriedSheetRelationships = ["/pivotTable", "/slicer", "/timeline"]

    /// True for parts whose content type SimpleSpread can carry.
    static func isCarriable(contentType rawType: String) -> Bool {
        let type = rawType.lowercased()
        let never = [
            // Read and written by SimpleSpread, or rebuilt.
            "spreadsheetml.sheet.main+xml", "spreadsheetml.template.main+xml", "spreadsheetml.worksheet+xml",
            "spreadsheetml.styles+xml", "spreadsheetml.sharedstrings+xml", "spreadsheetml.calcchain+xml",
            "spreadsheetml.pivottable+xml", "spreadsheetml.pivotcachedefinition+xml",
            "spreadsheetml.pivotcacherecords+xml", "package.core-properties+xml",
            "officedocument.extended-properties+xml", "package.relationships+xml",
            // Need workbook-level parts or settings that aren't kept.
            "spreadsheetml.chartsheet+xml", "ms-excel.slicer", "ms-excel.timeline",
            "spreadsheetml.connections+xml", "spreadsheetml.querytable+xml", "officedocument.model+data",
            "ms-excel.model", "ms-excel.rdrichvalue", "ms-excel.rdsupportingpropertybag", "ms-excel.rdrichvaluetypes",
            "ms-excel.richvaluerel", "ms-excel.rdarray", "spreadsheetml.sheetmetadata+xml",
            "spreadsheetml.volatiledependencies+xml", "vbaproject", "macroenabled", "ms-excel.macrosheet",
            "ms-excel.intlmacrosheet", "spreadsheetml.dialogsheet+xml", "vbadata", "spreadsheetml.revision",
            "spreadsheetml.usernames+xml", "digital-signature", "ms-office.webextension",
        ]
        return !never.contains { type.contains($0) }
    }

    struct CarriedReadContext {
        let zip: ZipArchiveReader
        let types: ContentTypes
        let rootRels: [Relationship]
        let workbookPath: String
        let workbookData: Data
        let workbookRels: [Relationship]
        let sheetParts: [SheetPart]
        /// Each sheet's carried elements (`carriedSheet`), by sheet id.
        let sheets: [Int: CarriedSheet]
    }

    /// Collect what to carry. Returns it with the package paths it holds.
    static func readCarriedParts(_ ctx: CarriedReadContext) -> CarriedParts {
        var carried = CarriedParts()
        for (ext, type) in ctx.types.defaults { carried.defaultContentTypes[ext] = type }
        let sheetIDs = Dictionary(ctx.sheetParts.map { ($0.path, $0.sheetID) }, uniquingKeysWith: { a, _ in a })

        // Whether a part can be carried, with everything it links to.
        var verdicts: [String: Bool] = [:]
        func carriable(_ path: String) -> Bool {
            if let known = verdicts[path] { return known }
            verdicts[path] = true // a cycle doesn't make it uncarriable
            var ok = false
            if ctx.zip.entry(named: path) != nil, let type = ctx.types.contentType(ofPart: path),
               isCarriable(contentType: type), let rels = try? relationships(of: path, in: ctx.zip) {
                ok = rels.allSatisfy { $0.isExternal || sheetIDs[$0.target] != nil || carriable($0.target) }
            }
            verdicts[path] = ok
            return ok
        }
        // Add a part and what it links to.
        func add(_ path: String) {
            guard carried.parts[path] == nil, let data = try? zipData(ctx.zip, path),
                  let type = ctx.types.contentType(ofPart: path) else { return }
            let rels = (try? relationships(of: path, in: ctx.zip)) ?? []
            carried.parts[path] = CarriedPart(
                data: data, contentType: type, hasOverride: ctx.types.overrides["/" + path.lowercased()] != nil,
                relationships: [])
            // (Carrying them adds parts: work them out before storing.)
            let kept = rels.compactMap(carry)
            carried.parts[path]?.relationships = kept
        }
        func carry(_ rel: Relationship) -> CarriedRelationship? {
            if rel.isExternal { return CarriedRelationship(id: rel.id, type: rel.type, target: .external(rel.target)) }
            if let id = sheetIDs[rel.target] { return CarriedRelationship(id: rel.id, type: rel.type, target: .sheet(id)) }
            guard carriable(rel.target) else { return nil }
            add(rel.target)
            return CarriedRelationship(id: rel.id, type: rel.type, target: .part(rel.target))
        }

        // Worksheets.
        for part in ctx.sheetParts {
            guard var sheet = ctx.sheets[part.sheetID] else { continue }
            let rels = (try? relationships(of: part.path, in: ctx.zip)) ?? []
            for rel in rels where !uncarriedSheetRelationships.contains(where: { rel.type.hasSuffix($0) }) {
                if let kept = carry(rel) { sheet.relationships.append(kept) }
            }
            sheet.elements = keepingReferences(to: Set(sheet.relationships.map(\.id)), in: sheet.elements)
            carried.sheets[part.sheetID] = sheet
        }

        // Workbook and package.
        if let attributes = try? rootAttributes(of: ctx.workbookData) {
            if attributes.isTransitional { carried.workbookRootAttributes = attributes.carried }
            let elements = (try? XMLRewriter.fragments(of: ctx.workbookData) {
                $0.path.count == 2 && carriedWorkbookElements.contains($0.localName)
            }) ?? []
            var kept: [CarriedElement] = []
            for xml in elements {
                guard let root = try? XMLNode.parse(xml) else { continue }
                kept.append(CarriedElement(name: root.localName,
                                           xml: withoutRootDeclarations(root, carried.workbookRootAttributes).xml))
            }
            for rel in ctx.workbookRels where carriedWorkbookRelationships.contains(where: { rel.type.hasSuffix($0) }) {
                if let carriedRel = carry(rel) { carried.workbookRelationships.append(carriedRel) }
            }
            carried.workbookElements = attributes.isTransitional
                ? keepingReferences(to: Set(carried.workbookRelationships.map(\.id)), in: kept) : []
        }
        for rel in ctx.rootRels where carriedPackageRelationships.contains(where: { rel.type.hasSuffix($0) }) {
            if let kept = carry(rel) { carried.packageRelationships.append(kept) }
        }
        return carried
    }

    /// The worksheet elements and root attributes to carry, or nil for a
    /// sheet in the Strict namespaces.
    static func carriedSheet(_ data: Data) -> CarriedSheet? {
        // Everything but <sheetData>, which is the writer's (and most of the bytes).
        var rest = data
        if let span = sheetDataSpan(in: data) {
            rest = data.subdata(in: 0..<span.outer.lowerBound)
            rest.append(data.subdata(in: span.outer.upperBound..<data.count))
        }
        guard let attributes = try? rootAttributes(of: rest), attributes.isTransitional,
              let fragments = try? XMLRewriter.fragments(of: rest, where: {
                  $0.path.count == 2 && !writtenWorksheetElements.contains($0.localName)
              }) else { return nil }
        var sheet = CarriedSheet(rootAttributes: attributes.carried)
        for xml in fragments {
            guard let root = try? XMLNode.parse(xml) else { continue }
            sheet.elements.append(CarriedElement(name: root.localName,
                                                 xml: withoutRootDeclarations(root, attributes.carried).xml))
        }
        return sheet
    }

    /// A fragment cut out of a part carries every namespace declaration in
    /// scope there. Drop those the writer's root element makes anyway: the
    /// main and relationships namespaces, and the carried root declarations.
    static func withoutRootDeclarations(_ root: XMLNode, _ rootAttributes: [String: String]) -> XMLNode {
        for (key, value) in root.attributes {
            let redundant = (key == "xmlns" && value == OOXMLNamespace.main)
                || (key == "xmlns:r" && value == OOXMLNamespace.relationships)
                || (key.hasPrefix("xmlns:") && rootAttributes[key] == value)
            if redundant { root.attributes[key] = nil }
        }
        return root
    }

    struct RootAttributes {
        /// Prefixed namespace declarations (but r, which the writer makes)
        /// and mc:Ignorable.
        var carried: [String: String] = [:]
        var isTransitional = false
    }

    static func rootAttributes(of data: Data) throws -> RootAttributes {
        var result = RootAttributes()
        try XMLRewriter.scan(data) { element in
            guard element.path.count == 1 else { return .drop }
            result.isTransitional = element.namespaceURI == OOXMLNamespace.main
            for (key, value) in element.attributes {
                if key.hasPrefix("xmlns:") {
                    // The writer declares r itself.
                    if key == "xmlns:r" { continue }
                    result.carried[key] = value
                } else if XMLRewriter.localName(key) == "Ignorable" {
                    result.carried[key] = value
                }
            }
            return .keep
        }
        return result
    }

    /// `elements` without whatever points at a relationship not in `ids`
    /// (one that wasn't carried, or was never there), and the containers
    /// that leaves empty.
    static func keepingReferences(to ids: Set<String>, in elements: [CarriedElement]) -> [CarriedElement] {
        let containers: Set<String> = [
            "tableParts", "oleObjects", "controls", "AlternateContent", "Choice", "Fallback", "customProperties",
            "slicerList", "timelineRefs", "ext", "extLst",
        ]
        return elements.compactMap { element in
            guard element.xml.contains(":"), let root = try? XMLNode.parse(element.xml) else { return element }
            // Prefixes bound to the relationships namespace (r on the root).
            var prefixes: Set<String> = ["r"]
            root.forEach { node in
                for (key, value) in node.attributes where key.hasPrefix("xmlns:")
                    && OOXMLNamespace.allRelationships.contains(value) {
                    prefixes.insert(String(key.dropFirst(6)))
                }
            }
            func references(_ node: XMLNode) -> Bool {
                node.attributes.contains { key, value in
                    key.contains(":") && !key.hasPrefix("xmlns") && prefixes.contains(XMLRewriter.prefix(of: key))
                        && !ids.contains(value)
                }
            }
            if references(root) { return nil }
            root.prune { node in
                !references(node) && !(containers.contains(node.localName) && node.elements.isEmpty)
            }
            if containers.contains(root.localName) && root.elements.isEmpty { return nil }
            if root.localName == "tableParts" { root.attributes["count"] = String(root.elements.count) }
            return CarriedElement(name: element.name, xml: root.xml)
        }
    }
}
