import Foundation

// GETPIVOTDATA: read a value out of a pivot table by naming it.
//
// It never aggregates anything itself. It finds the axis lines the pivot's
// definition says it rendered (rowItems/colItems) and returns the cell Excel
// drew at their crossing. That works for every pivot with a parsed definition,
// computable here or not, because SimpleSpread never changes a pivot's
// rendered cells without updating its definition too.

enum PivotFunctions {
    static let all: [BuiltinFunction] = [
        // GETPIVOTDATA(data_field, pivot_table, [field1, item1], ...)
        .eager("GETPIVOTDATA", min: 2, max: 254) { args, ctx in
            let dataField = try args[0].toScalar()
            if case .error(let e) = dataField { throw e }
            guard case .range(let ref) = args[1] else { throw CellError.ref }
            guard args.count % 2 == 0 else { throw CellError.ref } // a field without an item
            var constraints: [(field: String, item: CellValue)] = []
            for i in stride(from: 2, to: args.count, by: 2) {
                let field = try args[i].toScalar()
                if case .error(let e) = field { throw e }
                let item = try args[i + 1].toScalar()
                if case .error(let e) = item { throw e }
                constraints.append((Coerce.displayText(field), item))
            }
            let workbook = ctx.eval.workbook
            // Several pivots in the range: Excel uses the most recently
            // created; the last one listed is the nearest we know.
            guard let table = workbook.pivotTables.last(where: {
                $0.sheetID == ref.sheetID && $0.occupiedRange.contains(ref.range.start)
            }), let cache = workbook.pivotCache(withID: table.cacheID)?.data,
                let address = table.dataCellAddress(dataField: Coerce.displayText(dataField),
                                                    constraints: constraints, cache: cache),
                let sheet = workbook.sheet(withID: table.sheetID)
            else { throw CellError.ref }
            // Microsoft: "the value of that cell is returned regardless of
            // whether it is a string, number, error, or blank cell". A formula
            // can't produce a blank, so a blank shows as 0 (as =A1 would).
            let value = sheet.value(at: address)
            return value.isEmpty ? .number(0) : value
        },
    ]
}

extension PivotTable {
    /// The sheet cell GETPIVOTDATA reads for a data field and field/item
    /// constraints, or nil when they don't name a cell the pivot shows
    /// (GETPIVOTDATA's #REF!).
    ///
    /// - `dataField` is a data field's name ("Sum of Sales") or its source
    ///   field's name ("Sales"), ignoring case.
    /// - Each constraint names a row, column or report-filter field (by cache
    ///   field name or custom caption, ignoring case) and an item by its label:
    ///   text ignoring case, numbers and dates by value. A report filter must
    ///   be set to exactly that item.
    /// - On each axis the constrained fields must lead the axis: all of them
    ///   picks an item line, a leading part picks that part's subtotal line
    ///   (which must be shown), none picks the grand total line.
    public func dataCellAddress(dataField: String, constraints: [(field: String, item: CellValue)],
                                cache: PivotCacheData) -> CellAddress? {
        guard let definition, definition.fields.count == cache.fields.count else { return nil }
        let dataFields = definition.dataFields
        guard let d = dataFields.firstIndex(where: { Self.sameText($0.name, dataField) })
            ?? dataFields.firstIndex(where: { $0.field < cache.fields.count && Self.sameText(cache.fields[$0.field].name, dataField) })
        else { return nil }

        // Item positions each constrained field may take.
        let axisFields = (definition.rowFields + definition.columnFields + definition.pageFields.map(\.field))
            .filter { $0 >= 0 && $0 < cache.fields.count }
        var wanted: [Int: Set<Int>] = [:]
        for (name, item) in constraints {
            guard let f = axisFields.first(where: { f in
                Self.sameText(cache.fields[f].name, name) || definition.fields[f].name.map { Self.sameText($0, name) } == true
            }) else { return nil }
            let items = definition.fields[f].items
            let axisItems = cache.fields[f].axisItems
            // Hidden items are filtered out of the pivot: nothing to read.
            let matching = Set(items.indices.filter { p in
                items[p].kind == .data && !items[p].hidden && Self.item(items[p], axisItems: axisItems, matches: item)
            })
            wanted[f] = (wanted[f] ?? matching).intersection(matching)
            guard wanted[f]?.isEmpty == false else { return nil }
        }

        // A report filter only shows data for the item it's set to.
        for page in definition.pageFields {
            guard let positions = wanted.removeValue(forKey: page.field) else { continue }
            guard let selected = Self.selection(of: page, in: definition.fields[page.field]),
                  positions.contains(selected) else { return nil }
        }

        guard let row = lineIndex(definition.rowLines, fields: definition.rowFields, isRow: true, wanted: wanted,
                                  dataField: d, definition: definition),
              let column = lineIndex(definition.columnLines, fields: definition.columnFields, isRow: false,
                                     wanted: wanted, dataField: d, definition: definition)
        else { return nil }

        let address = CellAddress(row: location.start.row + definition.firstDataRow + row,
                                  column: location.start.column + definition.firstDataCol + column)
        return location.contains(address) ? address : nil
    }

    /// The line on one axis that `wanted` names, as an index into `lines`.
    private func lineIndex(_ lines: [PivotAxisLine], fields: [Int], isRow: Bool, wanted: [Int: Set<Int>],
                           dataField d: Int, definition: PivotDefinition) -> Int? {
        // An axis with no fields is one line (the values themselves).
        if fields.isEmpty { return lines.count <= 1 ? 0 : nil }
        let dataFieldCount = definition.dataFields.count
        let valuesLevel = fields.firstIndex(of: pivotValuesFieldIndex)
        if valuesLevel == nil && dataFieldCount > 1 {
            // Several data fields and no Values field on this axis: it must be
            // on the other one (else the definition is inconsistent).
            let other = isRow ? definition.columnFields : definition.rowFields
            guard other.contains(pivotValuesFieldIndex) else { return nil }
        }

        // What each level must hold; the Values level holds the data field.
        let required: [Set<Int>?] = fields.map { f in f == pivotValuesFieldIndex ? [d] : wanted[f] }
        // The constrained levels must lead the axis: k of them, then none
        // (a Values level past them is named by the line's data field).
        let k = required.firstIndex(where: { $0 == nil }) ?? fields.count
        guard !fields.indices.contains(where: { $0 >= k && wanted[fields[$0]] != nil }) else { return nil }
        // Without trailing Values levels (a subtotal or grand line names
        // its data field by `i`, not by a tuple member).
        var bare = k
        while bare > 0 && fields[bare - 1] == pivotValuesFieldIndex { bare -= 1 }
        let valuesBelow = valuesLevel.map { $0 >= bare } ?? false

        // Full tuples: the previous line's first `repeated` members, then
        // this line's (rowItems/colItems encoding, ECMA-376 §18.10.1.44).
        var tuples: [[Int]] = []
        var previous: [Int] = []
        for line in lines {
            if line.kind == .grand {
                tuples.append([])
                previous = []
                continue
            }
            let tuple = Array(previous.prefix(line.repeated)) + line.members
            tuples.append(tuple)
            previous = tuple
        }
        func matches(_ tuple: [Int], _ count: Int) -> Bool {
            tuple.count == count && (0..<count).allSatisfy { required[$0]!.contains(tuple[$0]) }
        }

        // Every field constrained: the item line itself.
        if k == fields.count,
           let i = lines.indices.first(where: { lines[$0].kind == .data && matches(tuples[$0], k) }) {
            return i
        }
        // Nothing constrained: the grand total line (one per data field when
        // the Values field is on this axis with several data fields).
        if bare == 0 {
            let grands = lines.indices.filter { lines[$0].kind == .grand }
            if valuesLevel != nil && dataFieldCount > 1 {
                if let i = grands.first(where: { lines[$0].dataFieldIndex == d }) { return i }
                // Excel 2007 sometimes left `i` off grand lines; they're in order.
                if grands.count == dataFieldCount && grands.allSatisfy({ lines[$0].dataFieldIndex == 0 }) {
                    return grands[d]
                }
            } else if let i = grands.first {
                return i
            }
        }
        guard bare > 0, k < fields.count else { return nil }
        // A leading part: its (default) subtotal line...
        if let i = lines.indices.first(where: { i in
            lines[i].kind == .default && matches(tuples[i], bare)
                && (!(valuesBelow && dataFieldCount > 1) || lines[i].dataFieldIndex == d)
        }) {
            return i
        }
        // ...or a line of its own that shows the total: a collapsed item, a
        // Values row under it, or a row field with its subtotal at the top.
        let f = fields[k - 1]
        let showsTotal: (Int) -> Bool = { p in
            if f == pivotValuesFieldIndex { return true }
            let settings = definition.fields[f]
            if p < settings.items.count && !settings.items[p].showDetails { return true }
            return isRow && settings.outline && settings.subtotalTop && settings.subtotals == [.default]
                && !(valuesBelow && dataFieldCount > 1)
        }
        return lines.indices.first { i in
            lines[i].kind == .data && matches(tuples[i], k) && showsTotal(tuples[i][k - 1])
        }
    }

    /// The single item a report filter is set to (by position), if any:
    /// its selected item, or the one item left visible.
    private static func selection(of page: PivotPageField, in settings: PivotFieldSettings) -> Int? {
        if let item = page.selectedItem { return item }
        let items = settings.items
        let visible = items.indices.filter { items[$0].kind == .data && !items[$0].hidden }
        // Mirrors the label Excel shows in the filter cell (see PivotEngine).
        guard settings.multipleItemSelectionAllowed, items.contains(where: \.hidden), visible.count == 1 else { return nil }
        return visible[0]
    }

    /// Whether a GETPIVOTDATA item argument names this pivot item.
    private static func item(_ item: PivotItem, axisItems: [PivotValue], matches arg: CellValue) -> Bool {
        if let name = item.name { return sameText(name, Coerce.displayText(arg)) }
        guard let x = item.index, x >= 0, x < axisItems.count else { return false }
        switch (axisItems[x], arg) {
        case (.number(let n), .number(let m)), (.date(let n), .number(let m)):
            return n == m
        case (.number(let n), .string(let s)), (.date(let n), .string(let s)):
            return Coerce.parseNumericText(s) == n
        case (.string(let s), _):
            // Group labels are text even when they look like numbers ("1965").
            return sameText(s, Coerce.displayText(arg))
        case (.bool(let b), .bool(let c)):
            return b == c
        case (.bool(let b), .string(let s)):
            return sameText(b ? "TRUE" : "FALSE", s)
        case (.missing, .string(let s)):
            return sameText(s, PivotCaptions.english.blank)
        default:
            return false
        }
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}
