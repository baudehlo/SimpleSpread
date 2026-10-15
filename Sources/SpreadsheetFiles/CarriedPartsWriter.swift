import Foundation
import SpreadsheetCore

// Writing CarriedParts back into the package (see CarriedParts.swift).

extension XLSXWriter {
    /// CT_Worksheet's children in schema order.
    static let worksheetElementOrder = [
        "sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "sheetCalcPr",
        "sheetProtection", "protectedRanges", "scenarios", "autoFilter", "sortState", "dataConsolidate",
        "customSheetViews", "mergeCells", "phoneticPr", "conditionalFormatting", "dataValidations",
        "hyperlinks", "printOptions", "pageMargins", "pageSetup", "headerFooter", "rowBreaks", "colBreaks",
        "customProperties", "cellWatches", "ignoredErrors", "smartTags", "drawing", "legacyDrawing",
        "legacyDrawingHF", "drawingHF", "picture", "oleObjects", "controls", "webPublishItems", "tableParts",
        "extLst",
    ]

    /// CT_Workbook's children in schema order.
    static let workbookElementOrder = [
        "fileVersion", "fileSharing", "workbookPr", "workbookProtection", "bookViews", "sheets",
        "functionGroups", "externalReferences", "definedNames", "calcPr", "oleSize", "customWorkbookViews",
        "pivotCaches", "smartTagPr", "smartTagTypes", "webPublishing", "fileRecoveryPr", "webPublishObjects",
        "extLst",
    ]

    /// Carried elements grouped by where they go in their parent's schema
    /// sequence (an mc:AlternateContent goes where the element it wraps
    /// would; an element the schema doesn't list, just before extLst).
    static func carriedElementsBySlot(_ elements: [CarriedElement], order: [String]) -> [String: [String]] {
        var slots: [String: [String]] = [:]
        for element in elements {
            var name = element.name
            if name == "AlternateContent", let root = try? XMLNode.parse(element.xml),
               let wrapped = root.elements.first?.elements.first?.localName {
                name = wrapped
            }
            if !order.contains(name) { name = "extLst" }
            slots[name, default: []].append(element.xml)
        }
        return slots
    }

    struct CarriedPackage {
        var entries: [(path: String, data: Data)] = []
        var overrides: [(partName: String, contentType: String)] = []
        var defaults: [(extension: String, contentType: String)] = []
        var workbookRelationships: [PackageRelationship] = []
        var packageRelationships: [PackageRelationship] = []
        /// Carried `<workbook>` children, relationship ids brought up to date.
        var workbookElements: [CarriedElement] = []
        var workbookRootAttributes: [String: String] = [:]
        /// By sheet position.
        var sheets: [Int: CarriedSheet] = [:]
        var sheetRelationships: [Int: [PackageRelationship]] = [:]
        /// Table header cells to write as text (Excel needs a table's header
        /// cells to read as its column names), by sheet position.
        var headerCells: [Int: [CellAddress: String]] = [:]
    }

    /// Lay out the carried parts. `taken`: paths the writer writes itself.
    /// Workbook relationship ids start at `firstWorkbookRelID`, package ones
    /// at `firstPackageRelID`.
    static func carriedPackage(for workbook: Workbook, taken: Set<String>,
                               firstWorkbookRelID: Int, firstPackageRelID: Int) -> CarriedPackage {
        var package = CarriedPackage()
        guard let carried = workbook.carriedContent as? CarriedParts else { return package }
        var sheetPaths: [Int: String] = [:]
        for (i, sheet) in workbook.sheets.enumerated() { sheetPaths[sheet.id] = "xl/worksheets/sheet\(i + 1).xml" }

        // Parts still in use, under paths that don't collide with the writer's.
        var roots = carried.workbookRelationships + carried.packageRelationships
        for sheet in workbook.sheets { roots += carried.sheets[sheet.id]?.relationships ?? [] }
        let reachable = carried.parts(reachableFrom: roots).sorted()
        var paths: [String: String] = [:]
        var used = taken
        for path in reachable {
            var candidate = path
            var n = 1
            while used.contains(candidate) || used.contains(XLSXReader.relsPath(for: candidate)) {
                let dir = XLSXReader.directory(of: path), file = XLSXReader.fileName(of: path)
                let dot = file.lastIndex(of: ".") ?? file.endIndex
                candidate = (dir.isEmpty ? "" : dir + "/") + file[..<dot] + "_\(n)" + file[dot...]
                n += 1
            }
            paths[path] = candidate
            used.insert(candidate)
            used.insert(XLSXReader.relsPath(for: candidate))
        }

        func packageRelationships(_ rels: [CarriedRelationship], from base: String) -> [PackageRelationship] {
            rels.compactMap { rel in
                switch rel.target {
                case .external(let uri):
                    return PackageRelationship(id: rel.id, type: rel.type, target: uri, isExternal: true)
                case .sheet(let id):
                    guard let path = sheetPaths[id] else { return nil }
                    return PackageRelationship(id: rel.id, type: rel.type, target: relativePath(path, from: base))
                case .part(let path):
                    guard let written = paths[path] else { return nil }
                    return PackageRelationship(id: rel.id, type: rel.type, target: relativePath(written, from: base))
                }
            }
        }

        // Tables: header cells and column names must agree.
        var tables: [String: Data] = [:]
        for (position, sheet) in workbook.sheets.enumerated() {
            for rel in carried.sheets[sheet.id]?.relationships ?? [] {
                guard case .part(let path) = rel.target, let part = carried.parts[path], part.kind == .table,
                      let root = try? XMLNode.parse(part.data) else { continue }
                var cells: [CellAddress: String] = [:]
                if syncTableHeaders(root, sheet: sheet, overrides: &cells) { tables[path] = root.document }
                if !cells.isEmpty { package.headerCells[position, default: [:]].merge(cells) { a, _ in a } }
            }
        }

        // The parts, their relationships and content types.
        var defaults = ["rels": "application/vnd.openxmlformats-package.relationships+xml", "xml": "application/xml"]
        for path in reachable {
            guard let part = carried.parts[path], let written = paths[path] else { continue }
            package.entries.append((written, tables[path] ?? part.data))
            let rels = packageRelationships(part.relationships, from: XLSXReader.directory(of: written))
            if !rels.isEmpty {
                package.entries.append((XLSXReader.relsPath(for: written), Data(relationshipsXML(rels).utf8)))
            }
            let file = XLSXReader.fileName(of: written)
            let ext = file.lastIndex(of: ".").map { String(file[file.index(after: $0)...]).lowercased() } ?? ""
            if part.hasOverride || ext.isEmpty || written != path {
                package.overrides.append(("/" + written, part.contentType))
            } else if let existing = defaults[ext] {
                if existing.caseInsensitiveCompare(part.contentType) != .orderedSame {
                    package.overrides.append(("/" + written, part.contentType))
                }
            } else {
                defaults[ext] = part.contentType
                package.defaults.append((ext, part.contentType))
            }
        }

        // Sheets.
        for (position, sheet) in workbook.sheets.enumerated() {
            guard let carriedSheet = carried.sheets[sheet.id] else { continue }
            package.sheets[position] = carriedSheet
            let rels = packageRelationships(carriedSheet.relationships, from: "xl/worksheets")
            if !rels.isEmpty { package.sheetRelationships[position] = rels }
        }

        // Workbook and package relationships get ids after the writer's;
        // carried workbook elements are updated to match.
        var renumbered: [String: String] = [:]
        var next = firstWorkbookRelID
        for rel in packageRelationships(carried.workbookRelationships, from: "xl") {
            let id = "rId\(next)"
            next += 1
            renumbered[rel.id] = id
            package.workbookRelationships.append(PackageRelationship(id: id, type: rel.type, target: rel.target,
                                                                     isExternal: rel.isExternal))
        }
        package.workbookElements = carried.workbookElements.map { element in
            guard !renumbered.isEmpty, let root = try? XMLNode.parse(element.xml) else { return element }
            var changed = false
            root.forEach { node in
                for (key, value) in node.attributes
                where !key.hasPrefix("xmlns") && XMLRewriter.localName(key) == "id" && key.contains(":") {
                    if let id = renumbered[value] { node.attributes[key] = id; changed = true }
                }
            }
            return changed ? CarriedElement(name: element.name, xml: root.xml) : element
        }
        package.workbookRootAttributes = carried.workbookRootAttributes
        next = firstPackageRelID
        for rel in packageRelationships(carried.packageRelationships, from: "") {
            package.packageRelationships.append(PackageRelationship(id: "rId\(next)", type: rel.type, target: rel.target,
                                                                    isExternal: rel.isExternal))
            next += 1
        }
        return package
    }

    /// Give a table's columns the names its header cells show, as Excel
    /// requires: unique, and never empty. A header cell with no text (a
    /// column just inserted) or one that repeats a name gets the column's
    /// name written into it (`overrides`). True if the table changed.
    static func syncTableHeaders(_ root: XMLNode, sheet: Sheet, overrides: inout [CellAddress: String]) -> Bool {
        guard root.localName == "table", (Int(root.attributes["headerRowCount"] ?? "") ?? 1) > 0,
              let ref = root.attributes["ref"], let range = CellRange(a1: ref),
              let columns = root.firstChild("tableColumns") else { return false }
        var changed = false
        var names: Set<String> = []
        for (offset, column) in columns.elements.enumerated() where column.localName == "tableColumn" {
            let address = CellAddress(row: range.start.row, column: range.start.column + offset)
            let current = column.attributes["name"] ?? ""
            var name: String
            switch sheet.value(at: address) {
            case .string(let text) where !text.isEmpty: name = text
            case .number(let n): name = serialNumberString(n)
            case .bool(let b): name = b ? "TRUE" : "FALSE"
            case .error(let e): name = e.rawValue
            default: name = current.isEmpty ? "Column\(offset + 1)" : current
            }
            var unique = name
            var n = 2
            while names.contains(unique.lowercased()) {
                unique = name + String(n)
                n += 1
            }
            names.insert(unique.lowercased())
            if sheet.value(at: address) != .string(unique) { overrides[address] = unique }
            if unique != current {
                column.attributes["name"] = unique
                changed = true
            }
        }
        return changed
    }

    /// `path` relative to the directory `base` ("xl/worksheets" to
    /// "xl/drawings/drawing1.xml" is "../drawings/drawing1.xml").
    static func relativePath(_ path: String, from base: String) -> String {
        let from = base.split(separator: "/").map(String.init)
        let to = path.split(separator: "/").map(String.init)
        var common = 0
        while common < from.count, common < to.count - 1, from[common] == to[common] { common += 1 }
        return (Array(repeating: "..", count: from.count - common) + to[common...]).joined(separator: "/")
    }

    /// Root attributes for a carried element's parent: the original root's
    /// prefixed namespace declarations and mc:Ignorable, rendered.
    static func rootAttributesXML(_ attributes: [String: String]) -> String {
        attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(XML.escapeAttribute($0.value))\"" }.joined()
    }
}
