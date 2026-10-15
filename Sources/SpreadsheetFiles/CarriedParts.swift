import Foundation
import SpreadsheetCore

// What an opened XLSX holds beyond the model, carried through to the next
// save: charts, images and shapes, comments, tables, conditional formatting,
// data validation, hyperlinks, print setup, protection, the theme, links to
// other workbooks, … (see CarriedPartsReader for what is and isn't kept).
//
// Parts are written back as read, at their original paths, with their
// relationships rebuilt under their original ids. Worksheet elements the
// writer doesn't produce are kept as XML fragments and spliced back in
// schema order. Edits that move cells, or rename or remove sheets, adjust
// what points at cells: anchors, comment and range references, and formulas
// (CarriedContent).

/// A relationship of a carried part or sheet.
struct CarriedRelationship: Sendable, Equatable {
    enum Target: Sendable, Equatable {
        /// A carried part, by package path.
        case part(String)
        /// A worksheet the writer writes, by sheet id.
        case sheet(Int)
        /// TargetMode="External": the URI as written.
        case external(String)
    }

    var id: String
    var type: String
    var target: Target
}

struct CarriedPart: Sendable {
    var data: Data
    /// The part's content type.
    var contentType: String
    /// True when [Content_Types].xml gave it an Override (otherwise its
    /// extension's Default applies).
    var hasOverride: Bool
    var relationships: [CarriedRelationship]

    enum Kind {
        case drawing, chart, vml, comments, threadedComments, table, other
    }

    var kind: Kind {
        let type = contentType.lowercased()
        if type.contains("officedocument.drawing+xml") { return .drawing }
        if type.contains("drawingml.chart+xml") || type.contains("ms-office.chartex+xml") { return .chart }
        if type.contains("vmldrawing") { return .vml }
        if type.contains("spreadsheetml.comments+xml") { return .comments }
        if type.contains("ms-excel.threadedcomments+xml") { return .threadedComments }
        if type.contains("spreadsheetml.table+xml") { return .table }
        return .other
    }
}

/// An XML element kept as written, by its local name.
struct CarriedElement: Sendable, Equatable {
    var name: String
    var xml: String
}

struct CarriedSheet: Sendable {
    /// `<worksheet>` children the writer doesn't make, in file order.
    var elements: [CarriedElement] = []
    /// The worksheet's relationships, but for pivot tables (the writer's own).
    var relationships: [CarriedRelationship] = []
    /// Prefixed namespace declarations and `mc:Ignorable` of the original
    /// `<worksheet>`, which the carried elements may rely on.
    var rootAttributes: [String: String] = [:]
}

struct CarriedParts: CarriedContent {
    var parts: [String: CarriedPart] = [:]
    var sheets: [Int: CarriedSheet] = [:]
    /// `<workbook>` children the writer doesn't make.
    var workbookElements: [CarriedElement] = []
    var workbookRelationships: [CarriedRelationship] = []
    var workbookRootAttributes: [String: String] = [:]
    /// Relationships of the package itself (custom document properties).
    var packageRelationships: [CarriedRelationship] = []
    /// Default content types by extension (lowercased), for parts without
    /// an override.
    var defaultContentTypes: [String: String] = [:]

    var isEmpty: Bool {
        parts.isEmpty && workbookElements.isEmpty && workbookRelationships.isEmpty
            && packageRelationships.isEmpty && sheets.values.allSatisfy { $0.elements.isEmpty && $0.relationships.isEmpty }
    }

    /// Every part reachable from `relationships`.
    func parts(reachableFrom relationships: [CarriedRelationship]) -> Set<String> {
        var found: Set<String> = []
        var queue = relationships
        while let rel = queue.popLast() {
            guard case .part(let path) = rel.target, found.insert(path).inserted, let part = parts[path] else { continue }
            queue += part.relationships
        }
        return found
    }

    // MARK: Edits

    func applying(_ edit: CarriedContentEdit,
                  rewriteFormula: (String, String?) -> String) -> (any CarriedContent)? {
        var result = self
        switch edit {
        case .structural(let change, let sheetName):
            result.applyStructural(change, sheetName: sheetName, rewriteFormula)
        case .renameSheet(_, let from, let to):
            result.rewriteFormulas(mentioning: from) { node, own in
                let renamed = Self.renameSheetSites(in: node, from: from, to: to)
                return Self.rewriteFormulaSites(in: node) { rewriteFormula($0, own) } || renamed
            }
        case .deleteSheet(let id, let name):
            result.sheets[id] = nil
            result.rewriteFormulas(mentioning: name) { node, own in
                Self.rewriteFormulaSites(in: node) { rewriteFormula($0, own) }
            }
        }
        return result
    }

    private mutating func applyStructural(_ change: StructuralChange, sheetName: String,
                                          _ rewriteFormula: (String, String?) -> String) {
        let owned = parts(reachableFrom: sheets[change.sheetID]?.relationships ?? [])
        // The edited sheet's own parts: positions and formulas.
        var removedParts: Set<String> = []
        for path in owned {
            // Images, printer settings and the like hold no positions.
            guard var part = parts[path], part.kind != .other, let root = try? XMLNode.parse(part.data) else { continue }
            var changed = Self.rewriteFormulaSites(in: root) { rewriteFormula($0, sheetName) }
            switch part.kind {
            case .drawing: changed = Self.adjustAnchors(in: root, change) || changed
            case .comments, .threadedComments: changed = Self.adjustComments(in: root, change) || changed
            case .vml: changed = Self.adjustVML(in: root, change) || changed
            case .table:
                switch Self.adjustTable(root, change) {
                case .unchanged: break
                case .changed: changed = true
                case .removed: removedParts.insert(path); continue
                }
            case .chart, .other: break
            }
            if changed {
                part.data = root.document
                parts[path] = part
            }
        }
        if var sheet = sheets[change.sheetID] {
            // A table that went takes its <tablePart> and relationship along.
            let gone = Set(sheet.relationships.filter {
                if case .part(let path) = $0.target { return removedParts.contains(path) }
                return false
            }.map(\.id))
            sheet.relationships.removeAll { gone.contains($0.id) }
            sheet.elements = sheet.elements.compactMap { element in
                guard let root = try? XMLNode.parse(element.xml) else { return element }
                var changed = Self.rewriteFormulaSites(in: root) { rewriteFormula($0, sheetName) }
                if !gone.isEmpty, root.localName == "tableParts" {
                    root.removeElements { $0.localName == "tablePart" && Self.relationshipID(of: $0).map(gone.contains) == true }
                    root.attributes["count"] = String(root.elements.count)
                    changed = true
                }
                switch Self.adjustSheetElement(root, change) {
                case .removed: return nil
                case .changed: changed = true
                case .unchanged: break
                }
                if root.localName == "tableParts", root.elements.isEmpty { return nil }
                return changed ? CarriedElement(name: element.name, xml: root.xml) : element
            }
            sheets[change.sheetID] = sheet
        }
        // Everything else: formulas naming the edited sheet.
        rewriteFormulas(mentioning: sheetName, skippingParts: owned, skippingSheet: change.sheetID) { node, _ in
            Self.rewriteFormulaSites(in: node) { rewriteFormula($0, nil) }
        }
    }

    /// Run `rewrite` over every part and sheet element that may mention
    /// `name` (all of them when the name can't be searched for as written).
    /// `rewrite` gets the element tree and the name of the sheet it
    /// belongs to, and returns true when it changed something.
    private mutating func rewriteFormulas(mentioning name: String,
                                          skippingParts skipped: Set<String> = [], skippingSheet: Int? = nil,
                                          _ rewrite: (XMLNode, String?) -> Bool) {
        // Escaped or quoted forms differ from the name: check everything.
        let searchable = !name.contains(where: { "&<>'\"".contains($0) })
        func mayMention(_ text: String) -> Bool {
            !searchable || text.range(of: name, options: .caseInsensitive) != nil
        }
        for (path, part) in parts where !skipped.contains(path) {
            guard [.chart, .drawing, .vml, .table].contains(part.kind),
                  mayMention(String(decoding: part.data, as: UTF8.self)),
                  let root = try? XMLNode.parse(part.data), rewrite(root, nil) else { continue }
            parts[path]?.data = root.document
        }
        for (id, sheet) in sheets where id != skippingSheet {
            var updated = sheet
            updated.elements = sheet.elements.map { element in
                guard mayMention(element.xml), let root = try? XMLNode.parse(element.xml), rewrite(root, nil)
                else { return element }
                return CarriedElement(name: element.name, xml: root.xml)
            }
            sheets[id] = updated
        }
    }

    // MARK: Formulas

    /// Elements whose text is a formula, by local name.
    static let formulaElements: Set<String> = [
        "f", // chart series and labels (c:f, c15:f, cx:f); x14 rules and sparklines (xm:f)
        "formula", "formula1", "formula2", // conditional formatting, data validation
        "calculatedColumnFormula", "totalsRowFormula", // tables
        "FmlaLink", "FmlaRange", "FmlaTxbx", "FmlaGroup", // VML form controls
    ]

    /// Rewrite every formula in the tree; true if one changed.
    static func rewriteFormulaSites(in root: XMLNode, _ rewrite: (String) -> String) -> Bool {
        var changed = false
        root.forEach { node in
            if formulaElements.contains(node.localName), !node.elements.contains(where: { _ in true }) {
                let text = node.text
                let leadingEquals = text.hasPrefix("=")
                let body = leadingEquals ? String(text.dropFirst()) : text
                guard !body.isEmpty else { return }
                let rewritten = rewrite(body)
                if rewritten != body {
                    node.text = (leadingEquals ? "=" : "") + rewritten
                    changed = true
                }
            }
            // A hyperlink to a place in the workbook; a shape's text taken from a cell.
            for key in ["location", "textlink"] {
                guard let value = node.attributes[key], !value.isEmpty,
                      key == "textlink" || node.localName == "hyperlink" else { continue }
                let rewritten = rewrite(value)
                if rewritten != value {
                    node.attributes[key] = rewritten
                    changed = true
                }
            }
        }
        return changed
    }

    /// Sheet names outside formulas: a pivot chart's source
    /// ("[Book1.xlsx]Sheet1!PivotTable1"), a consolidation range's sheet.
    @discardableResult
    static func renameSheetSites(in root: XMLNode, from: String, to: String) -> Bool {
        var changed = false
        root.forEach { node in
            if node.localName == "dataRef", let sheet = node.attributes["sheet"],
               sheet.caseInsensitiveCompare(from) == .orderedSame {
                node.attributes["sheet"] = to
                changed = true
            }
            guard node.localName == "name", node.elements.isEmpty else { return }
            // A pivot chart's <c:pivotSource> names its pivot table so.
            let text = node.text
            guard text.hasPrefix("["), let bang = text.lastIndex(of: "!") else { return }
            let head = text[..<bang]
            guard let close = head.lastIndex(of: "]") else { return }
            let book = head[...close]
            var sheet = String(head.dropFirst(book.count))
            let quoted = sheet.hasPrefix("'") && sheet.hasSuffix("'") && sheet.count >= 2
            if quoted { sheet = String(sheet.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            guard sheet.caseInsensitiveCompare(from) == .orderedSame else { return }
            let renamed = quoted || ReferenceExpr.quoteSheetNameIfNeeded(to) != to
                ? "'" + to.replacingOccurrences(of: "'", with: "''") + "'" : to
            node.text = String(book) + renamed + String(text[bang...])
            changed = true
        }
        return changed
    }

    static func relationshipID(of node: XMLNode) -> String? {
        node.attributes.first { $0.key == "r:id" || ($0.key.hasSuffix(":id") && !$0.key.hasPrefix("xmlns")) }?.value
    }
}

// MARK: - Positions

/// What an adjustment did to an element.
enum CarriedAdjustment {
    case unchanged, changed, removed
}

extension CarriedParts {
    /// A space-separated list of ranges (`sqref`) after `change`; nil when
    /// every range went.
    static func adjusted(sqref: String, _ change: StructuralChange) -> String? {
        let ranges = sqref.split(whereSeparator: \.isWhitespace).compactMap { item -> String? in
            guard let range = CellRange(a1: String(item)) else { return String(item) }
            return adjusted(range, change)?.a1
        }
        return ranges.isEmpty ? nil : ranges.joined(separator: " ")
    }

    /// A range after `change`, with formula semantics (it grows and
    /// shrinks); nil when all of it was deleted.
    static func adjusted(_ range: CellRange, _ change: StructuralChange) -> CellRange? {
        let ref = ReferenceExpr(start: RefComponent(column: range.start.column, row: range.start.row),
                                end: range.isSingleCell ? nil
                                    : RefComponent(column: range.end.column, row: range.end.row))
        guard let moved = change.adjusting(ref), moved.isOnGrid,
              let startColumn = moved.start.column, let startRow = moved.start.row else { return nil }
        let end = moved.end ?? moved.start
        guard let endColumn = end.column, let endRow = end.row else { return nil }
        return CellRange(start: CellAddress(row: startRow, column: startColumn),
                         end: CellAddress(row: endRow, column: endColumn))
    }

    /// A row or column index for an anchor: where it lands, or the edit's
    /// first index when it was deleted (anchors close up).
    static func anchorPosition(_ pos: Int, _ change: StructuralChange) -> Int {
        change.position(after: pos) ?? change.index
    }

    /// Drawing anchors (`xdr:twoCellAnchor`, `xdr:oneCellAnchor`, and an
    /// OLE object's or control's `<anchor>`). Objects set not to move with
    /// cells stay put; "move but don't size" keeps their size.
    static func adjustAnchors(in root: XMLNode, _ change: StructuralChange) -> Bool {
        var changed = false
        let axis = change.axisIsRow ? "row" : "col"
        let offset = change.axisIsRow ? "rowOff" : "colOff"
        root.forEach { node in
            let local = node.localName
            guard local == "twoCellAnchor" || local == "oneCellAnchor" || local == "anchor" else { return }
            func flag(_ key: String) -> Bool { node.attributes[key] == "1" || node.attributes[key] == "true" }
            let moves: Bool, sizes: Bool
            if local == "anchor" {
                moves = flag("moveWithCells")
                sizes = flag("sizeWithCells")
            } else {
                let editAs = node.attributes["editAs"] ?? (local == "twoCellAnchor" ? "twoCell" : "oneCell")
                moves = editAs != "absolute"
                sizes = editAs == "twoCell"
            }
            guard moves || sizes else { return }
            guard let from = node.firstChild("from"), let fromPos = from.firstChild(axis),
                  let oldFrom = Int(fromPos.text.trimmingCharacters(in: .whitespaces)) else { return }
            let newFrom = anchorPosition(oldFrom, change)
            if newFrom != oldFrom || change.deletes(oldFrom) {
                fromPos.text = String(newFrom)
                if change.deletes(oldFrom) { from.firstChild(offset)?.text = "0" }
                changed = true
            }
            guard let to = node.firstChild("to"), let toPos = to.firstChild(axis),
                  let oldTo = Int(toPos.text.trimmingCharacters(in: .whitespaces)) else { return }
            let newTo = sizes ? anchorPosition(oldTo, change) : oldTo + (newFrom - oldFrom)
            if newTo != oldTo || (sizes && change.deletes(oldTo)) {
                toPos.text = String(max(newTo, newFrom))
                if sizes && change.deletes(oldTo) { to.firstChild(offset)?.text = "0" }
                changed = true
            }
        }
        return changed
    }

    /// Comments and threaded comments: they move with their cell and go
    /// with it.
    static func adjustComments(in root: XMLNode, _ change: StructuralChange) -> Bool {
        var changed = false
        root.prune { node in
            guard node.localName == "comment" || node.localName == "threadedComment",
                  let ref = node.attributes["ref"], let address = CellAddress(a1: ref) else { return true }
            guard let moved = change.address(after: address) else {
                changed = true
                return false
            }
            if moved != address {
                node.attributes["ref"] = moved.a1
                changed = true
            }
            return true
        }
        return changed
    }

    /// VML shapes: a comment's box goes with its cell; every shape's anchor
    /// moves. (VML isn't always well-formed XML; a part that doesn't parse
    /// is written back as it was.)
    static func adjustVML(in root: XMLNode, _ change: StructuralChange) -> Bool {
        var changed = false
        root.prune { node in
            guard node.localName == "shape", let data = node.firstChild("ClientData") else { return true }
            let rowNode = data.firstChild("Row"), columnNode = data.firstChild("Column")
            if let position = change.axisIsRow ? rowNode : columnNode,
               let old = Int(position.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if let moved = change.position(after: old) {
                    if moved != old {
                        position.text = String(moved)
                        changed = true
                    }
                } else if data.attributes["ObjectType"] == "Note" {
                    changed = true
                    return false
                }
            }
            if let anchor = data.firstChild("Anchor") {
                // LeftColumn, LeftOffset, TopRow, TopOffset, RightColumn, RightOffset, BottomRow, BottomOffset
                var values = anchor.text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if values.count == 8, values.allSatisfy({ $0 != nil }) {
                    let indexes = change.axisIsRow ? [2, 6] : [0, 4]
                    var moved = false
                    for i in indexes {
                        let new = anchorPosition(values[i]!, change)
                        if new != values[i]! { values[i] = new; moved = true }
                    }
                    if moved {
                        anchor.text = values.map { String($0!) }.joined(separator: ", ")
                        changed = true
                    }
                }
            }
            return true
        }
        return changed
    }

    /// A table moves, grows and shrinks with its cells; columns inserted or
    /// deleted inside it add or remove table columns. Deleting its header
    /// row, or all of it, removes the table (its cells stay).
    static func adjustTable(_ root: XMLNode, _ change: StructuralChange) -> CarriedAdjustment {
        guard root.localName == "table", let ref = root.attributes["ref"], let range = CellRange(a1: ref) else {
            return .unchanged
        }
        let headerRows = Int(root.attributes["headerRowCount"] ?? "") ?? 1
        if change.axisIsRow, headerRows > 0, change.deletes(range.start.row) { return .removed }
        // A table keeps at least one row under its header.
        guard let moved = adjusted(range, change), moved.rowCount > max(0, headerRows) else { return .removed }
        var changed = moved != range
        root.attributes["ref"] = moved.a1
        for node in [root.firstChild("autoFilter"), root.firstChild("sortState")].compactMap({ $0 }) {
            if let filterRef = node.attributes["ref"], let filterRange = CellRange(a1: filterRef) {
                node.attributes["ref"] = adjusted(filterRange, change)?.a1 ?? moved.a1
            }
        }
        root.forEach { node in
            if node.localName == "sortCondition", let r = node.attributes["ref"], let condition = CellRange(a1: r),
               let new = adjusted(condition, change) {
                node.attributes["ref"] = new.a1
            }
        }
        // Columns inside the table.
        if !change.axisIsRow, let columns = root.firstChild("tableColumns") {
            var list = columns.elements
            let first = range.start.column
            if change.isInsert, change.index > first, change.index <= range.end.column {
                var ids = Set(list.compactMap { Int($0.attributes["id"] ?? "") })
                var names = Set(list.compactMap { $0.attributes["name"]?.lowercased() })
                var nextID = (ids.max() ?? 0) + 1
                var fresh: [XMLNode] = []
                for _ in 0..<change.count {
                    var n = 1
                    while names.contains("column\(n)") { n += 1 }
                    names.insert("column\(n)")
                    ids.insert(nextID)
                    let prefix = XMLRewriter.prefix(of: columns.name)
                    fresh.append(XMLNode(name: prefix.isEmpty ? "tableColumn" : prefix + ":tableColumn",
                                         attributes: ["id": String(nextID), "name": "Column\(n)"]))
                    nextID += 1
                }
                list.insert(contentsOf: fresh, at: min(change.index - first, list.count))
                changed = true
            } else if !change.isInsert {
                let before = list.count
                list = list.enumerated().filter { !change.deletes(first + $0.offset) }.map(\.element)
                if list.isEmpty { return .removed }
                changed = changed || list.count != before
            }
            columns.removeElements { _ in true }
            columns.children += list.map { .element($0) }
            columns.attributes["count"] = String(list.count)
        }
        return changed ? .changed : .unchanged
    }

    /// A worksheet element outside `<sheetData>`: range references move
    /// (and go when deleted), page breaks follow their rows or columns,
    /// OLE objects and controls their anchors.
    static func adjustSheetElement(_ root: XMLNode, _ change: StructuralChange) -> CarriedAdjustment {
        var changed = adjustAnchors(in: root, change)
        let removable: Set<String> = [
            "conditionalFormatting", "dataValidation", "protectedRange", "ignoredError", "hyperlink",
            "sparkline", "cellWatch", "inputCells", "brk",
        ]
        func keep(_ node: XMLNode) -> Bool {
            let local = node.localName
            if let sqref = node.attributes["sqref"] {
                guard let new = adjusted(sqref: sqref, change) else { changed = true; return !removable.contains(local) }
                if new != sqref { node.attributes["sqref"] = new; changed = true }
            }
            if let sqrefNode = node.firstChild("sqref"), sqrefNode.elements.isEmpty {
                let old = sqrefNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let new = adjusted(sqref: old, change) else { changed = true; return false }
                if new != old { sqrefNode.text = new; changed = true }
            }
            if ["hyperlink", "sortState", "sortCondition"].contains(local),
               let ref = node.attributes["ref"], let range = CellRange(a1: ref) {
                guard let new = adjusted(range, change) else {
                    changed = true
                    return local != "hyperlink" && local != "sortCondition"
                }
                if new != range { node.attributes["ref"] = new.a1; changed = true }
            }
            if local == "cellWatch" || local == "inputCells", let r = node.attributes["r"],
               let address = CellAddress(a1: r) {
                guard let moved = change.address(after: address) else { changed = true; return false }
                if moved != address { node.attributes["r"] = moved.a1; changed = true }
            }
            return true
        }
        let rootKept = keep(root)
        root.prune(keep)
        // Page breaks: a row break's id is the row after it (0-based).
        if (root.localName == "rowBreaks" && change.axisIsRow) || (root.localName == "colBreaks" && !change.axisIsRow) {
            root.prune { node in
                guard node.localName == "brk", let id = Int(node.attributes["id"] ?? "") else { return true }
                guard let moved = change.position(after: id) else { changed = true; return false }
                if moved != id { node.attributes["id"] = String(moved); changed = true }
                return true
            }
            root.attributes["count"] = String(root.elements.count)
            if root.attributes["manualBreakCount"] != nil {
                root.attributes["manualBreakCount"] = String(root.elements.filter {
                    $0.attributes["man"] == "1" || $0.attributes["man"] == "true"
                }.count)
            }
            if root.elements.isEmpty { return .removed }
        }
        guard changed else { return .unchanged }
        // Containers left empty go too, and counts are brought up to date.
        let containers: Set<String> = [
            "dataValidations", "hyperlinks", "protectedRanges", "ignoredErrors", "conditionalFormattings",
            "sparklines", "sparklineGroup", "sparklineGroups", "cellWatches", "scenarios", "ext", "extLst",
        ]
        root.prune { node in
            if node.localName == "dataValidations" || node.localName == "scenarios" {
                node.attributes["count"] = node.attributes["count"].map { _ in String(node.elements.count) }
            }
            return !(containers.contains(node.localName) && node.elements.isEmpty)
        }
        if root.localName == "dataValidations" { root.attributes["count"] = String(root.elements.count) }
        if !rootKept || (containers.contains(root.localName) && root.elements.isEmpty)
            || (root.localName == "conditionalFormatting" && root.elements.isEmpty) {
            return .removed
        }
        return .changed
    }
}
