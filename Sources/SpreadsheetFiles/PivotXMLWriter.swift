import Foundation
import SpreadsheetCore

/// Generates pivot cache and table parts from the typed pivot model, for
/// pivots SimpleSpread has refreshed, edited or created. When the pivot came
/// from a file, what the model doesn't cover is carried over from the
/// original part: root attributes (versions, flags, namespaces), the cache
/// source, pivot style, filters and extension lists. Cell formatting rules
/// (`formats`, `chartFormats`) are not carried: they address items by
/// position, which a refresh can change.
enum PivotXMLWriter {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let x14 = "http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"

    /// Attributes and raw child fragments of an existing part.
    struct CarryOver {
        var rootAttributes: [String: String] = [:]
        var fragments: [String: String] = [:]

        init() {}

        /// Read the root attributes and the named root-level children.
        init(_ data: Data, root: String, keep children: Set<String>) throws {
            var attributes: [String: String] = [:]
            try XMLRewriter.scan(data) { element in
                if element.path == [root] { attributes = element.attributes }
                return element.path.count == 1 ? .keep : .drop
            }
            rootAttributes = attributes
            for child in children {
                if let fragment = try XMLRewriter.fragments(of: data, where: { $0.path == [root, child] }).first {
                    fragments[child] = fragment
                }
            }
        }
    }

    // MARK: Values

    static func isoDate(_ serial: Double) -> String {
        guard let c = ExcelDate.components(fromSerial: serial) else { return "1899-12-30T00:00:00" }
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year, c.month, c.day, c.hour, c.minute, Int(c.second.rounded(.down)))
    }

    static func itemXML(_ value: PivotValue) -> String {
        switch value {
        case .missing: return "<m/>"
        case .number(let n): return "<n v=\"\(XLSXWriter.serialNumberString(n))\"/>"
        case .string(let s): return "<s v=\"\(XMLRewriter.escapeAttribute(XML.encodeIllegalCharacters(s)))\"/>"
        case .bool(let b): return "<b v=\"\(b ? 1 : 0)\"/>"
        case .date(let d): return "<d v=\"\(isoDate(d))\"/>"
        case .error(let e): return "<e v=\"\(XMLRewriter.escapeAttribute(e.xlsxRepresentation))\"/>"
        }
    }

    static func attr(_ name: String, _ value: String) -> String {
        " \(name)=\"\(XMLRewriter.escapeAttribute(value))\""
    }

    // MARK: Cache

    /// Which cache fields list their shared items (and so use `<x v>` in
    /// records): fields on an axis or page of any pivot using the cache,
    /// grouping bases, and fields whose pivot field has items.
    static func listedFields(_ data: PivotCacheData, definitions: [PivotDefinition]) -> Set<Int> {
        var listed: Set<Int> = []
        for d in definitions {
            for (f, field) in d.fields.enumerated() where field.axis != nil || !field.items.isEmpty { listed.insert(f) }
            for f in d.rowFields + d.columnFields where f >= 0 { listed.insert(f) }
            for p in d.pageFields { listed.insert(p.field) }
        }
        for (f, field) in data.fields.enumerated() {
            if let base = field.group?.base { listed.insert(base) }
            if field.group?.parent != nil { listed.insert(f) }
        }
        return listed
    }

    static func sharedItemsXML(_ values: [PivotValue], listed: Bool) -> String {
        var strings = false, numbers = false, dates = false, blank = false, long = false
        var allIntegers = true
        var minValue = Double.infinity, maxValue = -Double.infinity
        var minDate = Double.infinity, maxDate = -Double.infinity
        for v in values {
            switch v {
            case .missing: blank = true
            case .string(let s): strings = true; if s.count > 255 { long = true }
            case .bool, .error: strings = true
            case .number(let n):
                numbers = true
                if n != n.rounded() { allIntegers = false }
                minValue = min(minValue, n); maxValue = max(maxValue, n)
            case .date(let d):
                dates = true
                minDate = min(minDate, d); maxDate = max(maxDate, d)
            }
        }
        if dates && numbers { // numbers fold into the date range
            minDate = min(minDate, minValue); maxDate = max(maxDate, maxValue)
        }
        var a = ""
        if !(strings || blank) { a += attr("containsSemiMixedTypes", "0") }
        if !(strings || numbers) && (dates || blank) { a += attr("containsNonDate", "0") }
        if dates { a += attr("containsDate", "1") }
        if !strings { a += attr("containsString", "0") }
        if [strings, numbers, dates].filter({ $0 }).count > 1 { a += attr("containsMixedTypes", "1") }
        if numbers && !dates {
            a += attr("containsNumber", "1")
            if allIntegers { a += attr("containsInteger", "1") }
            a += attr("minValue", XLSXWriter.serialNumberString(minValue))
            a += attr("maxValue", XLSXWriter.serialNumberString(maxValue))
        }
        if blank { a += attr("containsBlank", "1") }
        if dates {
            a += attr("minDate", isoDate(minDate))
            a += attr("maxDate", isoDate((maxDate + 1).rounded(.down)))
        }
        if long { a += attr("longText", "1") }
        guard listed else { return "<sharedItems\(a)/>" }
        a += attr("count", String(values.count))
        return "<sharedItems\(a)>" + values.map(itemXML).joined() + "</sharedItems>"
    }

    static func fieldGroupXML(_ g: PivotFieldGroup) -> String {
        var s = "<fieldGroup"
        if let p = g.parent { s += attr("par", String(p)) }
        if let b = g.base { s += attr("base", String(b)) }
        guard g.range != nil || !g.discreteMap.isEmpty else { return s + "/>" }
        s += ">"
        if let r = g.range {
            s += "<rangePr"
            if !r.autoStart { s += attr("autoStart", "0") }
            if !r.autoEnd { s += attr("autoEnd", "0") }
            if r.groupBy != .range { s += attr("groupBy", r.groupBy.rawValue) }
            if let v = r.startNumber { s += attr("startNum", XLSXWriter.serialNumberString(v)) }
            if let v = r.endNumber { s += attr("endNum", XLSXWriter.serialNumberString(v)) }
            if let v = r.startDate { s += attr("startDate", isoDate(v)) }
            if let v = r.endDate { s += attr("endDate", isoDate(v)) }
            if r.interval != 1 { s += attr("groupInterval", XLSXWriter.serialNumberString(r.interval)) }
            s += "/>"
        } else {
            s += "<discretePr count=\"\(g.discreteMap.count)\">"
            s += g.discreteMap.map { "<x v=\"\($0)\"/>" }.joined()
            s += "</discretePr>"
        }
        s += "<groupItems count=\"\(g.items.count)\">" + g.items.map(itemXML).joined() + "</groupItems>"
        return s + "</fieldGroup>"
    }

    /// The `<cacheFields>` element. `formatID` maps number formats to ids.
    static func cacheFieldsXML(_ data: PivotCacheData, listed: Set<Int>, formatID: (NumberFormat) -> Int) -> String {
        let columns = data.recordColumns
        var s = "<cacheFields count=\"\(data.fields.count)\">"
        for (f, field) in data.fields.enumerated() {
            s += "<cacheField" + attr("name", XML.encodeIllegalCharacters(field.name))
                + attr("numFmtId", String(formatID(field.numberFormat)))
            if let formula = field.formula { s += attr("formula", formula) }
            if !field.isDatabaseField { s += attr("databaseField", "0") }
            var body = ""
            if field.isDatabaseField, let column = columns[f] {
                // Values: listed items, or the distinct inline record values.
                var values = field.sharedItems
                if !listed.contains(f) {
                    var seen: Set<PivotValue> = []
                    values = []
                    for r in data.records.indices {
                        let v = data.value(record: r, column: column, field: f)
                        if seen.insert(v).inserted { values.append(v) }
                    }
                }
                body += sharedItemsXML(values, listed: listed.contains(f))
            }
            if let group = field.group { body += fieldGroupXML(group) }
            s += body.isEmpty ? "/>" : ">" + body + "</cacheField>"
        }
        return s + "</cacheFields>"
    }

    static func recordsXML(_ data: PivotCacheData, listed: Set<Int>) -> String {
        let columns = data.recordColumns
        var s = header
        s += "<pivotCacheRecords xmlns=\"\(OOXMLNamespace.main)\" xmlns:r=\"\(OOXMLNamespace.relationships)\" count=\"\(data.records.count)\">"
        var indexByValue: [Int: [PivotValue: Int]] = [:]
        for f in listed where f < data.fields.count {
            var map: [PivotValue: Int] = [:]
            for (i, v) in data.fields[f].sharedItems.enumerated() where map[v] == nil { map[v] = i }
            indexByValue[f] = map
        }
        for r in data.records.indices {
            s += "<r>"
            for (f, column) in columns.enumerated() {
                guard let column else { continue }
                if let map = indexByValue[f] {
                    let v = data.value(record: r, column: column, field: f)
                    if let i = map[v] { s += "<x v=\"\(i)\"/>"; continue }
                }
                switch data.records[r][column] {
                case .shared(let i):
                    s += itemXML(data.fields[f].sharedItems.indices.contains(i) ? data.fields[f].sharedItems[i] : .missing)
                case .value(let v):
                    s += itemXML(v)
                }
            }
            s += "</r>"
        }
        return s + "</pivotCacheRecords>"
    }

    /// A cache definition for `data`. The source and r:id are filled in by
    /// XLSXWriter.patchedCacheDefinition afterwards.
    static func cacheDefinitionXML(_ data: PivotCacheData, listed: Set<Int>, carry: CarryOver,
                                   sourceFallback: String, refreshedDate: Double,
                                   formatID: (NumberFormat) -> Int) -> String {
        var attributes = carry.rootAttributes
        for key in ["recordCount", "refreshedDate", "refreshedBy", "invalid", "missingItemsLimit",
                    "refreshOnLoad", "saveData", "upgradeOnRefresh"] { attributes[key] = nil }
        for key in attributes.keys where key.hasSuffix(":id") { attributes[key] = nil }
        attributes["xmlns"] = OOXMLNamespace.main
        if attributes.values.contains(OOXMLNamespace.relationships) == false {
            attributes["xmlns:r"] = OOXMLNamespace.relationships
        }
        if attributes["createdVersion"] == nil { attributes["createdVersion"] = "6" }
        attributes["refreshedVersion"] = "6"
        if attributes["minRefreshableVersion"] == nil { attributes["minRefreshableVersion"] = "3" }
        attributes["refreshedBy"] = "SimpleSpread"
        attributes["refreshedDate"] = XLSXWriter.serialNumberString(refreshedDate)
        attributes["missingItemsLimit"] = "0"
        attributes["recordCount"] = String(data.records.count)
        var s = header + "<pivotCacheDefinition"
        for (k, v) in XMLRewriter.orderedAttributes(attributes) { s += attr(k, v) }
        // Placeholder r:id; the writer patches the records link.
        let prefix = attributes.first { $0.value == OOXMLNamespace.relationships && $0.key.hasPrefix("xmlns:") }
            .map { String($0.key.dropFirst(6)) } ?? "r"
        s += attr("\(prefix):id", "rId1") + ">"
        s += carry.fragments["cacheSource"] ?? sourceFallback
        s += cacheFieldsXML(data, listed: listed, formatID: formatID)
        if let ext = carry.fragments["extLst"] { s += ext }
        return s + "</pivotCacheDefinition>"
    }

    // MARK: Table

    static func subtotalAttributes(_ kinds: [PivotItem.Kind]) -> String {
        let flags: [(PivotItem.Kind, String)] = [
            (.sum, "sumSubtotal"), (.countA, "countASubtotal"), (.avg, "avgSubtotal"), (.max, "maxSubtotal"),
            (.min, "minSubtotal"), (.product, "productSubtotal"), (.count, "countSubtotal"),
            (.stdDev, "stdDevSubtotal"), (.stdDevP, "stdDevPSubtotal"), (.var, "varSubtotal"), (.varP, "varPSubtotal"),
        ]
        var s = kinds.contains(.default) ? "" : attr("defaultSubtotal", "0")
        for (kind, name) in flags where kinds.contains(kind) { s += attr(name, "1") }
        return s
    }

    static func pivotFieldsXML(_ d: PivotDefinition, formatID: (NumberFormat) -> Int) -> String {
        var s = "<pivotFields count=\"\(d.fields.count)\">"
        for field in d.fields {
            s += "<pivotField"
            if let name = field.name { s += attr("name", name) }
            if let axis = field.axis { s += attr("axis", axis.rawValue) }
            if field.isDataField { s += attr("dataField", "1") }
            if let format = field.numberFormat, !format.isGeneral { s += attr("numFmtId", String(formatID(format))) }
            if !field.compact { s += attr("compact", "0") }
            if !field.outline { s += attr("outline", "0") }
            if !field.subtotalTop { s += attr("subtotalTop", "0") }
            if field.insertBlankRow { s += attr("insertBlankRow", "1") }
            if field.multipleItemSelectionAllowed { s += attr("multipleItemSelectionAllowed", "1") }
            if !field.showAll { s += attr("showAll", "0") }
            if field.sort != .manual { s += attr("sortType", field.sort.rawValue) }
            if let caption = field.subtotalCaption { s += attr("subtotalCaption", caption) }
            s += subtotalAttributes(field.subtotals)
            var body = ""
            if !field.items.isEmpty {
                body += "<items count=\"\(field.items.count)\">"
                for item in field.items {
                    body += "<item"
                    if let name = item.name { body += attr("n", name) }
                    if item.kind != .data { body += attr("t", item.kind.rawValue) }
                    if item.hidden { body += attr("h", "1") }
                    if !item.showDetails { body += attr("sd", "0") }
                    if let x = item.index { body += attr("x", String(x)) }
                    body += "/>"
                }
                body += "</items>"
            }
            if field.fillDownLabels {
                body += "<extLst><ext uri=\"{2946ED86-A175-432a-8AC1-64E0C546D7DE}\" xmlns:x14=\"\(x14)\">"
                    + "<x14:pivotField fillDownLabels=\"1\"/></ext></extLst>"
            }
            s += body.isEmpty ? "/>" : ">" + body + "</pivotField>"
        }
        return s + "</pivotFields>"
    }

    static func axisLinesXML(_ name: String, _ lines: [PivotAxisLine]) -> String {
        var s = "<\(name) count=\"\(lines.count)\">"
        for line in lines {
            s += "<i"
            if line.kind != .data { s += attr("t", line.kind.rawValue) }
            if line.repeated > 0 { s += attr("r", String(line.repeated)) }
            if line.dataFieldIndex > 0 { s += attr("i", String(line.dataFieldIndex)) }
            if line.members.isEmpty { s += "/>"; continue }
            s += ">" + line.members.map { $0 == 0 ? "<x/>" : "<x v=\"\($0)\"/>" }.joined() + "</i>"
        }
        return s + "</\(name)>"
    }

    /// A pivot table definition for `d` laid out per `layout`.
    static func tableDefinitionXML(_ d: PivotDefinition, cacheID: Int, result: PivotLayoutResult, location: CellRange,
                                   carry: CarryOver, formatID: (NumberFormat) -> Int) -> String {
        var a = carry.rootAttributes
        let owned = ["name", "cacheId", "compact", "compactData", "outline", "outlineData", "gridDropZones",
                     "rowGrandTotals", "colGrandTotals", "dataOnRows", "dataPosition", "showHeaders", "dataCaption",
                     "grandTotalCaption", "rowHeaderCaption", "colHeaderCaption", "errorCaption", "showError",
                     "missingCaption", "showMissing", "indent", "mergeItem", "pageWrap", "pageOverThenDown",
                     "subtotalHiddenItems"]
        for key in owned { a[key] = nil }
        if carry.rootAttributes.isEmpty {
            // A new pivot: what Excel 2016 writes.
            for (k, v) in [("applyNumberFormats", "0"), ("applyBorderFormats", "0"), ("applyFontFormats", "0"),
                           ("applyPatternFormats", "0"), ("applyAlignmentFormats", "0"), ("applyWidthHeightFormats", "1"),
                           ("updatedVersion", "6"), ("minRefreshableVersion", "3"), ("useAutoFormatting", "1"),
                           ("itemPrintTitles", "1"), ("createdVersion", "6"), ("multipleFieldFilters", "0")] {
                a[k] = v
            }
        }
        a["xmlns"] = OOXMLNamespace.main
        let l = d.layout
        a["name"] = d.name
        a["cacheId"] = String(cacheID)
        a["dataCaption"] = l.dataCaption
        if !l.compact { a["compact"] = "0" }
        if !l.compactData { a["compactData"] = "0" }
        if l.outline { a["outline"] = "1" }
        if l.outlineData { a["outlineData"] = "1" }
        if l.gridDropZones { a["gridDropZones"] = "1" }
        if !l.rowGrandTotals { a["rowGrandTotals"] = "0" }
        if !l.colGrandTotals { a["colGrandTotals"] = "0" }
        if l.dataOnRows { a["dataOnRows"] = "1" }
        if let p = l.dataPosition { a["dataPosition"] = String(p) }
        if !l.showHeaders { a["showHeaders"] = "0" }
        if let c = l.grandTotalCaption { a["grandTotalCaption"] = c }
        if let c = l.rowHeaderCaption { a["rowHeaderCaption"] = c }
        if let c = l.colHeaderCaption { a["colHeaderCaption"] = c }
        if let c = l.errorCaption { a["errorCaption"] = c }
        if l.showError { a["showError"] = "1" }
        if let c = l.missingCaption { a["missingCaption"] = c }
        if !l.showMissing { a["showMissing"] = "0" }
        if l.indent != 1 { a["indent"] = String(l.indent) }
        if l.mergeItem { a["mergeItem"] = "1" }
        if l.pageWrap > 0 { a["pageWrap"] = String(l.pageWrap) }
        if l.pageOverThenDown { a["pageOverThenDown"] = "1" }

        var s = header + "<pivotTableDefinition"
        for (k, v) in XMLRewriter.orderedAttributes(a) { s += attr(k, v) }
        s += ">"
        s += "<location" + attr("ref", location.a1) + attr("firstHeaderRow", String(result.firstHeaderRow))
            + attr("firstDataRow", String(result.firstDataRow)) + attr("firstDataCol", String(result.firstDataCol))
        if result.pageRows > 0 {
            s += attr("rowPageCount", String(result.pageRows)) + attr("colPageCount", String(result.pageColumns))
        }
        s += "/>"
        s += pivotFieldsXML(d, formatID: formatID)
        if !d.rowFields.isEmpty {
            s += "<rowFields count=\"\(d.rowFields.count)\">" + d.rowFields.map { "<field x=\"\($0)\"/>" }.joined() + "</rowFields>"
        }
        if !result.rowLines.isEmpty { s += axisLinesXML("rowItems", result.rowLines) }
        if !d.columnFields.isEmpty {
            s += "<colFields count=\"\(d.columnFields.count)\">" + d.columnFields.map { "<field x=\"\($0)\"/>" }.joined() + "</colFields>"
        }
        if !result.columnLines.isEmpty { s += axisLinesXML("colItems", result.columnLines) }
        if !d.pageFields.isEmpty {
            s += "<pageFields count=\"\(d.pageFields.count)\">"
            for p in d.pageFields {
                s += "<pageField" + attr("fld", String(p.field))
                if let item = p.selectedItem { s += attr("item", String(item)) }
                s += attr("hier", "-1") + "/>"
            }
            s += "</pageFields>"
        }
        if !d.dataFields.isEmpty {
            s += "<dataFields count=\"\(d.dataFields.count)\">"
            for df in d.dataFields {
                s += "<dataField" + attr("name", df.name) + attr("fld", String(df.field))
                if df.subtotal != .sum { s += attr("subtotal", df.subtotal.rawValue) }
                if df.showDataAs != .normal { s += attr("showDataAs", df.showDataAs.rawValue) }
                s += attr("baseField", String(df.baseField)) + attr("baseItem", String(df.baseItem))
                if let format = df.numberFormat, !format.isGeneral { s += attr("numFmtId", String(formatID(format))) }
                s += "/>"
            }
            s += "</dataFields>"
        }
        if let style = carry.fragments["pivotTableStyleInfo"] {
            s += style
        } else if let name = d.styleName {
            s += "<pivotTableStyleInfo" + attr("name", name) + " showRowHeaders=\"1\" showColHeaders=\"1\""
                + " showRowStripes=\"0\" showColStripes=\"0\" showLastColumn=\"1\"/>"
        }
        s += filtersXML(d.filters, carried: carry.fragments["filters"])
        s += extensionList(carry.fragments["extLst"], hideValuesRow: l.hideValuesRow)
        return s + "</pivotTableDefinition>"
    }

    /// `<filters>` from the model, so field numbers are current after a
    /// refresh or an edit and a filter whose field was removed is gone. A
    /// filter read from the file keeps its original element (its name,
    /// string values, extensions) with the numbers brought up to date.
    static func filtersXML(_ filters: [PivotFilter], carried: String?) -> String {
        guard !filters.isEmpty else { return "" }
        var originals: [Int: String] = [:]
        if let carried, let fragments = try? XMLRewriter.fragments(of: Data(carried.utf8), where: { $0.path == ["filters", "filter"] }) {
            for fragment in fragments {
                var id: Int?
                try? XMLRewriter.scan(Data(fragment.utf8)) { element in
                    if element.path.count == 1 { id = Int(element.attributes["id"] ?? "") }
                    return .keep
                }
                if let id, originals[id] == nil { originals[id] = fragment }
            }
        }
        var nextID = (filters.compactMap(\.id) + Array(originals.keys)).max().map { $0 + 1 } ?? 1
        var s = "<filters count=\"\(filters.count)\">"
        for filter in filters {
            let id: Int
            if let existing = filter.id { id = existing } else { id = nextID; nextID += 1 }
            if let original = originals[id], let patched = patchedFilter(original, filter, id: id) {
                s += patched
            } else {
                s += generatedFilter(filter, id: id)
            }
        }
        return s + "</filters>"
    }

    private static func patchedFilter(_ original: String, _ filter: PivotFilter, id: Int) -> String? {
        guard let data = try? XMLRewriter.rewrite(Data(original.utf8), { element in
            if element.path.count == 1 {
                element.attributes["fld"] = String(filter.field)
                element.attributes["evalOrder"] = String(filter.evalOrder)
                element.attributes["id"] = String(id)
                if filter.type == "count" || element.attributes["iMeasureFld"] != nil {
                    element.attributes["iMeasureFld"] = String(filter.measureField)
                }
            }
            return .keep
        }) else { return nil }
        var s = String(decoding: data, as: UTF8.self)
        if s.hasPrefix("<?xml"), let declaration = s.range(of: "?>") {
            s = String(s[declaration.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    private static func generatedFilter(_ filter: PivotFilter, id: Int) -> String {
        var s = "<filter" + attr("fld", String(filter.field)) + attr("type", filter.type)
            + attr("evalOrder", String(filter.evalOrder)) + attr("id", String(id))
        if filter.type == "count" { s += attr("iMeasureFld", String(filter.measureField)) }
        s += "><autoFilter ref=\"A1\"><filterColumn colId=\"0\">"
        if filter.type == "count" {
            let value = XLSXWriter.serialNumberString(filter.top10Value ?? 10)
            s += "<top10"
            if !filter.top10Top { s += attr("top", "0") }
            if filter.top10Percent { s += attr("percent", "1") }
            s += attr("val", value) + attr("filterVal", value) + "/>"
        } else {
            s += "<customFilters" + (filter.conditionsAreAnd ? attr("and", "1") : "") + ">"
            for c in filter.conditions {
                s += "<customFilter" + (c.op == "equal" ? "" : attr("operator", c.op)) + attr("val", c.value) + "/>"
            }
            s += "</customFilters>"
        }
        return s + "</filterColumn></autoFilter></filter>"
    }

    /// The table's extLst, making sure x14 hideValuesRow is present when the
    /// layout depends on it.
    static func extensionList(_ original: String?, hideValuesRow: Bool) -> String {
        let marker = "<x14:pivotTableDefinition hideValuesRow=\"1\" xmlns:xm=\"http://schemas.microsoft.com/office/excel/2006/main\"/>"
        guard let original else {
            guard hideValuesRow else { return "" }
            return "<extLst><ext uri=\"{962EF5D1-5CA2-4c93-8EF4-DBF5C05439D2}\" xmlns:x14=\"\(x14)\">\(marker)</ext></extLst>"
        }
        if !hideValuesRow || original.contains("hideValuesRow=\"1\"") { return original }
        // Add the flag to an existing x14:pivotTableDefinition, or a new ext.
        if let data = try? XMLRewriter.rewrite(Data(original.utf8), { element in
            if element.localName == "pivotTableDefinition" && element.path.count == 3 {
                element.attributes["hideValuesRow"] = "1"
            }
            return .keep
        }) {
            var s = String(decoding: data, as: UTF8.self)
            if let decl = s.range(of: "?>\n") { s = String(s[decl.upperBound...]) }
            if s.contains("hideValuesRow") { return s }
            if let close = s.range(of: "</extLst>", options: .backwards) {
                s.replaceSubrange(close, with: "<ext uri=\"{962EF5D1-5CA2-4c93-8EF4-DBF5C05439D2}\" xmlns:x14=\"\(x14)\">\(marker)</ext></extLst>")
            }
            return s
        }
        return original
    }
}
