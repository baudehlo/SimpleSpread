import Foundation
import SpreadsheetCore

/// Parses pivot cache and pivot table parts into the typed pivot model.
enum PivotXMLParser {
    /// Number formats by id: the workbook's custom formats plus builtins.
    struct FormatTable: Sendable {
        var custom: [Int: String]

        func format(_ id: Int?) -> NumberFormat? {
            guard let id else { return nil }
            if let code = custom[id] {
                let format = NumberFormat(code: code)
                return format.isGeneral ? .general : format
            }
            return NumberFormat.builtin(id) ?? (id == 0 ? .general : nil)
        }
    }

    static func value(element: String, attributes: [String: String]) -> PivotValue? {
        let v = attributes["v"]
        switch element {
        case "m": return .missing
        case "n": return v.flatMap(Double.init).map(PivotValue.number) ?? .missing
        case "s": return .string(XML.decodeIllegalCharacters(v ?? ""))
        case "b": return .bool(v == "1" || v?.lowercased() == "true")
        case "d": return v.flatMap(XLSXReader.isoDateToSerial).map(PivotValue.date) ?? .missing
        case "e": return .error(v.flatMap(CellError.parse) ?? .na)
        default: return nil
        }
    }

    private static func bool(_ s: String?, _ def: Bool) -> Bool {
        guard let s = s?.lowercased() else { return def }
        return s == "1" || s == "true"
    }

    // MARK: Cache

    static func parseCache(definition: Data, records: Data?, formats: FormatTable) throws -> PivotCacheData {
        var fields: [PivotCacheField] = []
        var hasCalculatedItems = false, isOLAP = false
        var current: PivotCacheField?
        var group: PivotFieldGroup?
        var inSharedItems = false, inGroupItems = false, inDiscrete = false

        // Elements are visited in document order; close-out happens when the
        // next field starts (scan has no end callbacks), so collect then flush.
        func flush() {
            if var field = current {
                field.group = group
                fields.append(field)
            }
            current = nil
            group = nil
        }

        try XMLRewriter.scan(definition) { element in
            let path = element.path
            let attrs = element.attributes
            if path.count == 2 {
                if path[1] == "calculatedItems" { hasCalculatedItems = true; return .drop }
                if path[1] == "cacheHierarchies" { isOLAP = true; return .drop }
            }
            guard path.count >= 3, path[0] == "pivotCacheDefinition", path[1] == "cacheFields" else {
                return path.count >= 2 && path[1] == "extLst" ? .drop : .keep
            }
            if path.count == 3 && path[2] == "cacheField" {
                flush()
                current = PivotCacheField(
                    name: XML.decodeIllegalCharacters(attrs["name"] ?? ""),
                    numberFormat: formats.format(Int(attrs["numFmtId"] ?? "")) ?? .general,
                    formula: attrs["formula"],
                    isDatabaseField: bool(attrs["databaseField"], true))
                inSharedItems = false; inGroupItems = false; inDiscrete = false
                return .keep
            }
            guard path.count >= 4, current != nil else { return .keep }
            switch (path.count, path[3]) {
            case (4, "sharedItems"):
                inSharedItems = true; inGroupItems = false; inDiscrete = false
            case (4, "fieldGroup"):
                inSharedItems = false
                group = PivotFieldGroup(parent: Int(attrs["par"] ?? ""), base: Int(attrs["base"] ?? ""))
            case (4, "extLst"):
                return .drop
            default:
                break
            }
            if path.count == 5 && inSharedItems && path[3] == "sharedItems",
               let v = value(element: element.localName, attributes: attrs) {
                current?.sharedItems.append(v)
            }
            if path.count == 5 && path[3] == "fieldGroup" {
                switch path[4] {
                case "rangePr":
                    let groupBy = PivotFieldGroup.GroupBy(rawValue: attrs["groupBy"] ?? "range") ?? .range
                    group?.range = PivotFieldGroup.Range(
                        groupBy: groupBy,
                        autoStart: bool(attrs["autoStart"], true), autoEnd: bool(attrs["autoEnd"], true),
                        startNumber: attrs["startNum"].flatMap(Double.init),
                        endNumber: attrs["endNum"].flatMap(Double.init),
                        startDate: attrs["startDate"].flatMap(XLSXReader.isoDateToSerial),
                        endDate: attrs["endDate"].flatMap(XLSXReader.isoDateToSerial),
                        interval: attrs["groupInterval"].flatMap(Double.init) ?? 1)
                case "discretePr": inDiscrete = true; inGroupItems = false
                case "groupItems": inGroupItems = true; inDiscrete = false
                default: break
                }
            }
            if path.count == 6 && path[3] == "fieldGroup" {
                if inDiscrete && path[4] == "discretePr" && element.localName == "x" {
                    group?.discreteMap.append(Int(attrs["v"] ?? "") ?? 0)
                } else if inGroupItems && path[4] == "groupItems",
                          let v = value(element: element.localName, attributes: attrs) {
                    group?.items.append(v)
                }
            }
            return .keep
        }
        flush()

        var rows: [[PivotRecordValue]] = []
        if let records {
            var row: [PivotRecordValue]?
            try XMLRewriter.scan(records) { element in
                let path = element.path
                if path.count == 2 && path[1] == "r" {
                    if let row { rows.append(row) }
                    row = []
                } else if path.count == 3 && path[1] == "r" {
                    if element.localName == "x" {
                        row?.append(.shared(Int(element.attributes["v"] ?? "") ?? 0))
                    } else if let v = value(element: element.localName, attributes: element.attributes) {
                        row?.append(.value(v))
                    }
                } else if path.count == 2 && path[1] == "extLst" {
                    return .drop
                }
                return .keep
            }
            if let row { rows.append(row) }
        }
        return PivotCacheData(fields: fields, records: rows, hasCalculatedItems: hasCalculatedItems,
                              isOLAP: isOLAP, hasRecords: records != nil)
    }

    // MARK: Table

    static func parseTable(_ data: Data, formats: FormatTable) throws -> PivotDefinition {
        var definition = PivotDefinition(name: "", fields: [])
        var layout = PivotLayout()
        var line: PivotAxisLine?
        var lineAxis = ""

        func flushLine() {
            guard let l = line else { return }
            if lineAxis == "rowItems" { definition.rowLines.append(l) } else { definition.columnLines.append(l) }
            line = nil
        }

        try XMLRewriter.scan(data) { element in
            let path = element.path
            let a = element.attributes
            if path.count == 1 {
                definition.name = a["name"] ?? ""
                layout.compact = bool(a["compact"], true)
                layout.compactData = bool(a["compactData"], true)
                layout.outline = bool(a["outline"], false)
                layout.outlineData = bool(a["outlineData"], false)
                layout.gridDropZones = bool(a["gridDropZones"], false)
                layout.rowGrandTotals = bool(a["rowGrandTotals"], true)
                layout.colGrandTotals = bool(a["colGrandTotals"], true)
                layout.dataOnRows = bool(a["dataOnRows"], false)
                layout.dataPosition = a["dataPosition"].flatMap { Int($0) }
                layout.showHeaders = bool(a["showHeaders"], true)
                layout.dataCaption = a["dataCaption"] ?? "Values"
                layout.grandTotalCaption = a["grandTotalCaption"]
                layout.rowHeaderCaption = a["rowHeaderCaption"]
                layout.colHeaderCaption = a["colHeaderCaption"]
                layout.errorCaption = a["errorCaption"]
                layout.showError = bool(a["showError"], false)
                layout.missingCaption = a["missingCaption"]
                layout.showMissing = bool(a["showMissing"], true)
                layout.indent = Int(a["indent"] ?? "") ?? 1
                layout.mergeItem = bool(a["mergeItem"], false)
                layout.pageWrap = Int(a["pageWrap"] ?? "") ?? 0
                layout.pageOverThenDown = bool(a["pageOverThenDown"], false)
                layout.subtotalHiddenItems = bool(a["subtotalHiddenItems"], false)
                return .keep
            }
            guard path.count >= 2 else { return .keep }
            switch path[1] {
            case "pivotFields":
                if path.count == 3 {
                    var subtotals: [PivotItem.Kind] = []
                    if bool(a["defaultSubtotal"], true) { subtotals.append(.default) }
                    let flags: [(String, PivotItem.Kind)] = [
                        ("sumSubtotal", .sum), ("countASubtotal", .countA), ("avgSubtotal", .avg),
                        ("maxSubtotal", .max), ("minSubtotal", .min), ("productSubtotal", .product),
                        ("countSubtotal", .count), ("stdDevSubtotal", .stdDev), ("stdDevPSubtotal", .stdDevP),
                        ("varSubtotal", .var), ("varPSubtotal", .varP),
                    ]
                    for (attribute, kind) in flags where bool(a[attribute], false) { subtotals.append(kind) }
                    definition.fields.append(PivotFieldSettings(
                        axis: a["axis"].flatMap(PivotFieldSettings.Axis.init(rawValue:)),
                        isDataField: bool(a["dataField"], false),
                        sort: a["sortType"].flatMap(PivotFieldSettings.Sort.init(rawValue:)) ?? .manual,
                        subtotals: subtotals,
                        compact: bool(a["compact"], true), outline: bool(a["outline"], true),
                        subtotalTop: bool(a["subtotalTop"], true), insertBlankRow: bool(a["insertBlankRow"], false),
                        showAll: bool(a["showAll"], true), name: a["name"],
                        numberFormat: formats.format(a["numFmtId"].flatMap { Int($0) }),
                        multipleItemSelectionAllowed: bool(a["multipleItemSelectionAllowed"], false),
                        subtotalCaption: a["subtotalCaption"]))
                } else if path.count == 5 && path[3] == "items" && element.localName == "item",
                          !definition.fields.isEmpty {
                    let kind = PivotItem.Kind(rawValue: a["t"] ?? "data") ?? .data
                    definition.fields[definition.fields.count - 1].items.append(PivotItem(
                        kind: kind, index: a["x"].flatMap { Int($0) }, hidden: bool(a["h"], false),
                        showDetails: bool(a["sd"], true), name: a["n"]))
                } else if path.count >= 4 && path[3] == "extLst" {
                    if element.localName == "pivotField", bool(a["fillDownLabels"], false), !definition.fields.isEmpty {
                        definition.fields[definition.fields.count - 1].fillDownLabels = true
                    }
                }
            case "rowFields", "colFields":
                if path.count == 3, let x = Int(a["x"] ?? "") {
                    if path[1] == "rowFields" { definition.rowFields.append(x) } else { definition.columnFields.append(x) }
                }
            case "rowItems", "colItems":
                if path.count == 3 {
                    flushLine()
                    lineAxis = path[1]
                    line = PivotAxisLine(kind: PivotItem.Kind(rawValue: a["t"] ?? "data") ?? .data,
                                         repeated: Int(a["r"] ?? "") ?? 0,
                                         dataFieldIndex: Int(a["i"] ?? "") ?? 0)
                } else if path.count == 4 && element.localName == "x" {
                    line?.members.append(Int(a["v"] ?? "") ?? 0)
                }
            case "location":
                if path.count == 2 {
                    definition.firstHeaderRow = Int(a["firstHeaderRow"] ?? "") ?? 1
                    definition.firstDataRow = Int(a["firstDataRow"] ?? "") ?? 1
                    definition.firstDataCol = Int(a["firstDataCol"] ?? "") ?? 0
                }
            case "filters":
                if path.count == 3 && element.localName == "filter", let field = Int(a["fld"] ?? "") {
                    definition.filters.append(PivotFilter(
                        field: field, type: a["type"] ?? "", measureField: Int(a["iMeasureFld"] ?? "") ?? 0,
                        evalOrder: Int(a["evalOrder"] ?? "") ?? -1))
                } else if !definition.filters.isEmpty {
                    let last = definition.filters.count - 1
                    switch element.localName {
                    case "customFilters":
                        definition.filters[last].conditionsAreAnd = bool(a["and"], false)
                    case "customFilter":
                        definition.filters[last].conditions.append(
                            .init(op: a["operator"] ?? "equal", value: a["val"] ?? ""))
                    case "top10":
                        definition.filters[last].top10Value = a["val"].flatMap(Double.init)
                        definition.filters[last].top10Top = bool(a["top"], true)
                        definition.filters[last].top10Percent = bool(a["percent"], false)
                    default:
                        break
                    }
                }
            case "pageFields":
                if path.count == 3, let field = Int(a["fld"] ?? "") {
                    definition.pageFields.append(PivotPageField(field: field, selectedItem: a["item"].flatMap { Int($0) }))
                }
            case "dataFields":
                if path.count == 3, let field = Int(a["fld"] ?? "") {
                    definition.dataFields.append(PivotDataField(
                        name: a["name"] ?? "", field: field,
                        subtotal: PivotSubtotal(rawValue: a["subtotal"] ?? "sum") ?? .sum,
                        showDataAs: PivotShowDataAs(rawValue: a["showDataAs"] ?? "normal") ?? .normal,
                        baseField: Int(a["baseField"] ?? "") ?? 0, baseItem: Int(a["baseItem"] ?? "") ?? 0,
                        numberFormat: formats.format(a["numFmtId"].flatMap { Int($0) })))
                }
            case "pivotTableStyleInfo":
                definition.styleName = a["name"]
            case "extLst":
                if element.localName == "pivotTableDefinition", bool(a["hideValuesRow"], false) {
                    layout.hideValuesRow = true
                }
            default:
                break
            }
            return .keep
        }
        flushLine()
        definition.layout = layout
        return definition
    }
}

// MARK: - Typed views of preserved pivots

extension PivotCache {
    /// The cache's data, parsed from its preserved parts.
    public func parsedData(styles: PreservedStyles?) throws -> PivotCacheData {
        guard let payload = payload as? PivotCachePayload else {
            throw XLSXError.invalidPackage("pivot cache \(cacheID) has no XML payload")
        }
        return try PivotXMLParser.parseCache(definition: payload.definition, records: payload.records,
                                             formats: .init(custom: styles?.numberFormats ?? [:]))
    }
}

extension PivotTable {
    /// The table's definition, parsed from its preserved part.
    public func parsedDefinition(styles: PreservedStyles?) throws -> PivotDefinition {
        guard let payload = payload as? PivotTablePayload else {
            throw XLSXError.invalidPackage("pivot table \(name) has no XML payload")
        }
        return try PivotXMLParser.parseTable(payload.definition, formats: .init(custom: styles?.numberFormats ?? [:]))
    }
}
