import Foundation

/// What an opened XLSX holds that SimpleSpread reads past and will not
/// write back: saving over the file removes it. Collected at read time from
/// the package's content types, the workbook part, each worksheet's
/// elements and the shared strings, and shown to the user before a save
/// would destroy it.
struct UnsupportedContent: Equatable {
    /// In the order they are listed to the user (most visible first).
    enum Kind: Int, CaseIterable, Comparable {
        case charts, chartSheets, images, drawings, comments, tables, pivotTables
        case slicers, timelines, sparklines
        case conditionalFormatting, dataValidation, hyperlinks
        case externalLinks, dataConnections, dataModel, richData
        case macros, formControls, embeddedObjects
        case sheetProtection, workbookProtection
        case printSettings, hiddenColumns, columnFormatting, rowFormatting, outlines, richText
        case veryHiddenSheets, customViews, scenarios, changeHistory, customProperties, addIns, signatures
        case other

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// (singular, plural) for kinds listed with a count, else nil.
        var countedNoun: (String, String)? {
            switch self {
            case .charts: return ("chart", "charts")
            case .chartSheets: return ("chart sheet", "chart sheets")
            case .images: return ("image", "images")
            case .tables: return ("table", "tables")
            case .pivotTables: return ("pivot table", "pivot tables")
            default: return nil
            }
        }

        var label: String {
            switch self {
            case .charts: return "charts"
            case .chartSheets: return "chart sheets"
            case .images: return "images"
            case .drawings: return "drawings and shapes"
            case .comments: return "comments"
            case .tables: return "tables"
            case .pivotTables: return "pivot tables"
            case .slicers: return "slicers"
            case .timelines: return "timelines"
            case .sparklines: return "sparklines"
            case .conditionalFormatting: return "conditional formatting"
            case .dataValidation: return "data validation"
            case .hyperlinks: return "hyperlinks"
            case .externalLinks: return "links to other workbooks"
            case .dataConnections: return "data connections"
            case .dataModel: return "a data model"
            case .richData: return "linked data types or pictures in cells"
            case .macros: return "macros"
            case .formControls: return "form controls"
            case .embeddedObjects: return "embedded objects"
            case .sheetProtection: return "sheet protection"
            case .workbookProtection: return "workbook protection"
            case .printSettings: return "print settings"
            case .hiddenColumns: return "hidden columns"
            case .columnFormatting: return "column formatting"
            case .rowFormatting: return "row formatting"
            case .outlines: return "grouped rows or columns"
            case .richText: return "rich text formatting"
            case .veryHiddenSheets: return "“very hidden” sheet settings"
            case .customViews: return "custom views"
            case .scenarios: return "scenarios"
            case .changeHistory: return "change history"
            case .customProperties: return "custom document properties"
            case .addIns: return "add-in data"
            case .signatures: return "digital signatures"
            case .other: return "other content"
            }
        }
    }

    private(set) var counts: [Kind: Int] = [:]

    var isEmpty: Bool { counts.isEmpty }

    mutating func add(_ kind: Kind, count: Int = 1) {
        guard count > 0 else { return }
        counts[kind, default: 0] += count
    }

    mutating func formUnion(_ kinds: Set<Kind>) {
        for kind in kinds { add(kind) }
    }

    /// Human-readable, in display order: "3 charts", "comments", …
    var descriptions: [String] {
        var kinds = counts.keys.sorted()
        // Shapes are only worth naming when there are no charts or images
        // (which live in the same drawing parts).
        if counts[.charts] != nil || counts[.images] != nil { kinds.removeAll { $0 == .drawings } }
        return kinds.map { kind in
            guard let (one, many) = kind.countedNoun, let n = counts[kind] else { return kind.label }
            return n == 1 ? "1 \(one)" : "\(n) \(many)"
        }
    }

    // MARK: Package parts

    /// Classify every part in the package by its content type.
    static func scanPackage(_ zip: ZipArchiveReader) -> UnsupportedContent {
        var found = UnsupportedContent()
        guard let typesData = try? zip.contents(named: "[Content_Types].xml"),
              let types = try? ContentTypes.parse(typesData) else { return found }
        for entry in zip.entries where !entry.name.hasSuffix("/") && entry.name != "[Content_Types].xml" {
            guard let type = types.contentType(ofPart: entry.name) else { continue }
            if let kind = kind(forContentType: type, partName: entry.name) {
                found.add(kind)
            }
        }
        return found
    }

    /// What losing a part of this type means; nil for parts SimpleSpread
    /// reads, rebuilds, or can drop without anyone noticing.
    static func kind(forContentType rawType: String, partName: String) -> Kind? {
        let type = rawType.lowercased()
        // Thumbnails are regenerated by whoever shows them.
        if type.hasPrefix("image/") { return partName.lowercased().hasPrefix("docprops/") ? nil : .images }
        let rules: [(String, Kind?)] = [
            // Read and written (or rebuilt) by SimpleSpread.
            ("spreadsheetml.sheet.main+xml", nil), ("spreadsheetml.template.main+xml", nil),
            ("spreadsheetml.worksheet+xml", nil), ("spreadsheetml.styles+xml", nil),
            ("spreadsheetml.sharedstrings+xml", nil), ("spreadsheetml.calcchain+xml", nil),
            ("spreadsheetml.pivottable+xml", nil), ("spreadsheetml.pivotcachedefinition+xml", nil),
            ("spreadsheetml.pivotcacherecords+xml", nil), ("package.relationships+xml", nil),
            ("package.core-properties+xml", nil), ("officedocument.extended-properties+xml", nil),
            // Safe to drop: theme (colours read as automatic), printer
            // driver blobs (print settings are judged from the sheet),
            // custom XML data stores, volatile caches, dynamic-array
            // metadata, people lists behind threaded comments.
            ("officedocument.theme+xml", nil), ("officedocument.themeoverride+xml", nil),
            ("spreadsheetml.printersettings", nil), ("customxmlproperties+xml", nil),
            ("spreadsheetml.volatiledependencies+xml", nil), ("spreadsheetml.sheetmetadata+xml", nil),
            ("ms-excel.person+xml", nil), ("vmldrawing", nil),
            ("ms-office.chartstyle+xml", nil), ("ms-office.chartcolorstyle+xml", nil),
            ("drawingml.chartshapes+xml", nil),
            // Lost on save.
            ("drawingml.chart+xml", .charts), ("ms-office.chartex+xml", .charts),
            ("spreadsheetml.chartsheet+xml", .chartSheets),
            ("officedocument.drawing+xml", .drawings), ("drawingml.diagram", .drawings),
            ("spreadsheetml.comments+xml", .comments), ("ms-excel.threadedcomments+xml", .comments),
            ("spreadsheetml.table+xml", .tables),
            ("ms-excel.slicer+xml", .slicers), ("ms-excel.slicercache+xml", .slicers),
            ("ms-excel.timeline+xml", .timelines), ("ms-excel.timelinecache+xml", .timelines),
            ("spreadsheetml.externallink+xml", .externalLinks),
            ("spreadsheetml.connections+xml", .dataConnections), ("spreadsheetml.querytable+xml", .dataConnections),
            ("officedocument.model+data", .dataModel), ("ms-excel.model", .dataModel),
            ("ms-excel.rdrichvalue", .richData), ("ms-excel.rdsupportingpropertybag", .richData),
            ("ms-excel.rdrichvaluetypes", .richData), ("ms-excel.richvaluerel", .richData),
            ("ms-excel.rdarray", .richData),
            ("vbaproject", .macros), ("macroenabled", .macros), ("ms-excel.macrosheet", .macros),
            ("ms-excel.intlmacrosheet", .macros), ("spreadsheetml.dialogsheet+xml", .macros),
            ("vbadata", .macros),
            ("ms-office.activex", .formControls), ("ms-excel.controlproperties+xml", .formControls),
            ("officedocument.oleobject", .embeddedObjects), ("officedocument.package", .embeddedObjects),
            ("spreadsheetml.revisionheaders+xml", .changeHistory), ("spreadsheetml.revisionlog+xml", .changeHistory),
            ("spreadsheetml.usernames+xml", .changeHistory),
            ("officedocument.custom-properties+xml", .customProperties),
            ("ms-office.webextension", .addIns), ("ms-office.webextensiontaskpanes", .addIns),
            ("digital-signature", .signatures),
        ]
        for (fragment, kind) in rules where type.contains(fragment) { return kind }
        // Generic XML (custom XML items and the like) carries nothing visible.
        if type == "application/xml" || type == "text/xml" { return nil }
        return .other
    }
}

/// `[Content_Types].xml`: a type per extension, and overrides per part.
struct ContentTypes {
    var defaults: [String: String] = [:]
    var overrides: [String: String] = [:]

    func contentType(ofPart name: String) -> String? {
        let key = "/" + name.lowercased()
        if let type = overrides[key] { return type }
        guard let dot = name.lastIndex(of: "."), !name[dot...].contains("/") else { return nil }
        return defaults[String(name[name.index(after: dot)...]).lowercased()]
    }

    static func parse(_ data: Data) throws -> ContentTypes {
        final class Delegate: NSObject, XMLParserDelegate {
            var types = ContentTypes()
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                let local = name.split(separator: ":").last.map(String.init) ?? name
                if local == "Default", let ext = attributes["Extension"], let type = attributes["ContentType"] {
                    types.defaults[ext.lowercased()] = type
                } else if local == "Override", let part = attributes["PartName"],
                          let type = attributes["ContentType"] {
                    types.overrides[part.lowercased()] = type
                }
            }
        }
        let delegate = Delegate()
        try XLSXReader.runParser(data, delegate: delegate)
        return delegate.types
    }
}
