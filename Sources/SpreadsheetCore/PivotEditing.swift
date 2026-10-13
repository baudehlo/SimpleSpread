import Foundation

// Editing a pivot table's definition the way Excel's field list does.
// These change only the definition; callers recompute and apply the layout.

/// The field list's areas.
public enum PivotArea: String, CaseIterable, Sendable {
    case filters, columns, rows, values
}

/// Excel's report layouts.
public enum PivotForm: String, CaseIterable, Sendable {
    case compact, outline, tabular
}

extension PivotDefinition {
    /// An empty pivot over `cache`, as Excel 2016 creates one.
    public static func new(name: String, cache: PivotCacheData) -> PivotDefinition {
        PivotDefinition(
            name: name,
            fields: cache.fields.map { _ in PivotFieldSettings(showAll: false) },
            layout: PivotLayout(compact: true, compactData: true, outline: true, outlineData: true,
                                dataCaption: "Values", indent: 0, hideValuesRow: true))
    }

    /// The area a field is in (Values is separate: a field can be in both).
    public func axisArea(of field: Int) -> PivotArea? {
        if rowFields.contains(field) { return .rows }
        if columnFields.contains(field) { return .columns }
        if pageFields.contains(where: { $0.field == field }) { return .filters }
        return nil
    }

    /// Fields (or the Values pseudo-field) in an axis area, in order.
    public func fields(in area: PivotArea) -> [Int] {
        switch area {
        case .rows: return rowFields
        case .columns: return columnFields
        case .filters: return pageFields.map(\.field)
        case .values: return dataFields.map(\.field)
        }
    }

    /// Give a field its items (all values, ascending) when it first goes on
    /// an axis; Excel keeps them afterwards.
    mutating func ensureItems(_ f: Int, cache: PivotCacheData) {
        guard f >= 0, fields[f].items.isEmpty else { return }
        var order = cache.ascendingItemOrder(f)
        if fields[f].sort == .descending { order.reverse() }
        var items = order.map { PivotItem(kind: .data, index: $0) }
        for kind in fields[f].subtotals { items.append(PivotItem(kind: kind)) }
        fields[f].items = items
    }

    /// Excel's "(previous)" and "(next)" base items for Show Values As.
    public static let previousBaseItem = 1048828
    public static let nextBaseItem = 1048829

    /// Give field `f` a new item list. `moved` maps the positions of items
    /// that are still there, old to new. Everything that names an item by
    /// its position follows it: Show Values As base items on this field and
    /// its report filter's selected item. (Hidden and collapsed state live on
    /// the items themselves.) A base item that's gone falls back to the
    /// first item; a selected filter item that's gone selects all.
    public mutating func replaceItems(field f: Int, with items: [PivotItem], moved: [Int: Int]) {
        fields[f].items = items
        for d in dataFields.indices where dataFields[d].baseField == f {
            let b = dataFields[d].baseItem
            guard b != Self.previousBaseItem && b != Self.nextBaseItem else { continue }
            dataFields[d].baseItem = moved[b] ?? 0
        }
        for p in pageFields.indices where pageFields[p].field == f {
            if let s = pageFields[p].selectedItem { pageFields[p].selectedItem = moved[s] }
        }
    }

    /// Old → new positions of the data items both lists hold (by item index).
    static func positionMap(from old: [PivotItem], to new: [PivotItem]) -> [Int: Int] {
        var newPosition: [Int: Int] = [:]
        for (p, item) in new.enumerated() where item.kind == .data {
            if let x = item.index, newPosition[x] == nil { newPosition[x] = p }
        }
        var moved: [Int: Int] = [:]
        for (p, item) in old.enumerated() where item.kind == .data {
            if let x = item.index, let q = newPosition[x] { moved[p] = q }
        }
        return moved
    }

    /// Put a field on an axis area (taking it off any other axis). Adding to
    /// Values adds a data field instead (see addDataField).
    public mutating func place(field f: Int, in area: PivotArea, at position: Int? = nil, cache: PivotCacheData) {
        if area == .values {
            addDataField(field: f, cache: cache, at: position)
            return
        }
        detachFromAxes(f)
        // Report filters choose items; label, date and top-N filters don't
        // apply there (Excel clears them).
        if area == .filters { filters.removeAll { $0.field == f } }
        if f != pivotValuesFieldIndex {
            ensureItems(f, cache: cache)
        }
        func insert(_ list: inout [Int]) {
            let p = min(max(0, position ?? list.count), list.count)
            list.insert(f, at: p)
        }
        switch area {
        case .rows:
            insert(&rowFields)
            if f >= 0 { fields[f].axis = .row }
            layout.dataOnRows = rowFields.contains(pivotValuesFieldIndex)
        case .columns:
            insert(&columnFields)
            if f >= 0 { fields[f].axis = .column }
            if f == pivotValuesFieldIndex { layout.dataOnRows = false }
        case .filters:
            guard f >= 0 else { return }
            let p = min(max(0, position ?? pageFields.count), pageFields.count)
            pageFields.insert(PivotPageField(field: f), at: p)
            fields[f].axis = .page
        case .values:
            break
        }
    }

    /// Take a field off the row, column and filter areas, with any label,
    /// date or top-N filter on it (nothing on screen would show it).
    public mutating func removeFromAxes(_ f: Int) {
        detachFromAxes(f)
        filters.removeAll { $0.field == f }
    }

    /// Take a field off the axes, keeping its filters (it's being moved).
    private mutating func detachFromAxes(_ f: Int) {
        rowFields.removeAll { $0 == f }
        columnFields.removeAll { $0 == f }
        pageFields.removeAll { $0.field == f }
        if f >= 0 { fields[f].axis = nil }
    }

    /// Add a value field summarizing `field` (Sum for numbers, else Count).
    public mutating func addDataField(field f: Int, cache: PivotCacheData, at position: Int? = nil) {
        let numeric = cache.records.indices.allSatisfy { r in
            guard let column = cache.recordColumns[f] else { return true }
            switch cache.value(record: r, column: column, field: f) {
            case .number, .date, .missing: return true
            default: return false
            }
        } && cache.fields[f].group == nil
        let subtotal: PivotSubtotal = numeric || cache.fields[f].formula != nil ? .sum : .count
        let p = min(max(0, position ?? dataFields.count), dataFields.count)
        dataFields.insert(PivotDataField(name: uniqueDataFieldName(subtotal: subtotal, field: f, cache: cache),
                                         field: f, subtotal: subtotal), at: p)
        fields[f].isDataField = true
        syncValuesField()
    }

    public mutating func removeDataField(at index: Int) {
        guard dataFields.indices.contains(index) else { return }
        let f = dataFields.remove(at: index).field
        fields[f].isDataField = dataFields.contains { $0.field == f }
        // Top-N filters rank by a value field (by position): drop the ones
        // ranking by this one and renumber the rest.
        filters.removeAll { $0.type == "count" && $0.measureField == index }
        for i in filters.indices where filters[i].measureField > index { filters[i].measureField -= 1 }
        syncValuesField()
    }

    public mutating func moveDataField(from: Int, to: Int) {
        guard dataFields.indices.contains(from) else { return }
        let d = dataFields.remove(at: from)
        let target = min(max(0, to), dataFields.count)
        dataFields.insert(d, at: target)
        // Top-N filters name their value field by position: follow the move.
        var order = Array(0..<dataFields.count) // order[new position] = old position
        order.insert(order.remove(at: from), at: target)
        var newIndex: [Int: Int] = [:]
        for (new, old) in order.enumerated() { newIndex[old] = new }
        for i in filters.indices { filters[i].measureField = newIndex[filters[i].measureField] ?? filters[i].measureField }
    }

    /// Change a value field's summary function; a default name follows it.
    public mutating func setSubtotal(_ subtotal: PivotSubtotal, forDataField index: Int, cache: PivotCacheData) {
        guard dataFields.indices.contains(index) else { return }
        let d = dataFields[index]
        let wasDefault = d.name == Self.defaultDataFieldName(subtotal: d.subtotal, fieldName: cache.fields[d.field].name)
            || d.name.hasPrefix(Self.defaultDataFieldName(subtotal: d.subtotal, fieldName: cache.fields[d.field].name))
        dataFields[index].subtotal = subtotal
        if wasDefault {
            dataFields[index].name = ""
            dataFields[index].name = uniqueDataFieldName(subtotal: subtotal, field: d.field, cache: cache)
        }
    }

    public mutating func setShowDataAs(_ showAs: PivotShowDataAs, forDataField index: Int,
                                       baseField: Int? = nil, baseItem: Int? = nil) {
        guard dataFields.indices.contains(index) else { return }
        dataFields[index].showDataAs = showAs
        if let baseField { dataFields[index].baseField = baseField }
        if let baseItem { dataFields[index].baseItem = baseItem }
    }

    /// Rename a value field (names must be unique among value fields).
    public mutating func renameDataField(at index: Int, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard dataFields.indices.contains(index), !trimmed.isEmpty,
              !dataFields.enumerated().contains(where: { $0.offset != index && $0.element.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return false }
        dataFields[index].name = trimmed
        return true
    }

    /// Show only the items at `visible` positions of a field (Excel's item
    /// filter checklist). Report filters with several items allow multiple
    /// selection.
    public mutating func setVisibleItems(field f: Int, positions visible: Set<Int>) {
        for p in fields[f].items.indices where fields[f].items[p].kind == .data {
            fields[f].items[p].hidden = !visible.contains(p)
        }
        if let page = pageFields.firstIndex(where: { $0.field == f }) {
            pageFields[page].selectedItem = nil
            fields[f].multipleItemSelectionAllowed = fields[f].items.contains { $0.hidden }
        }
    }

    /// Choose one report-filter item (nil = all).
    public mutating func selectPageItem(field f: Int, item: Int?) {
        guard let page = pageFields.firstIndex(where: { $0.field == f }) else { return }
        pageFields[page].selectedItem = item
        if item != nil {
            for p in fields[f].items.indices { fields[f].items[p].hidden = false }
            fields[f].multipleItemSelectionAllowed = false
        }
    }

    /// Sort a field's items (ascending/descending reorders now and on refresh).
    public mutating func setSort(_ sort: PivotFieldSettings.Sort, field f: Int, cache: PivotCacheData) {
        fields[f].sort = sort
        guard sort != .manual else { return }
        // Grouped fields keep their groups' order (Jan…Dec, 0-9, 10-19…).
        var rank: [Int: Int] = [:]
        for (r, x) in cache.ascendingItemOrder(f).enumerated() { rank[x] = r }
        let old = fields[f].items
        let data = old.filter { $0.kind == .data }
        let rest = old.filter { $0.kind != .data }
        var sorted = data.sorted { a, b in
            (a.index.flatMap { rank[$0] } ?? Int.max) < (b.index.flatMap { rank[$0] } ?? Int.max)
        }
        if sort == .descending { sorted.reverse() }
        let items = sorted + rest
        replaceItems(field: f, with: items, moved: Self.positionMap(from: old, to: items))
    }

    /// Expand or collapse an item.
    public mutating func setShowDetails(_ show: Bool, field f: Int, item p: Int) {
        guard fields[f].items.indices.contains(p) else { return }
        fields[f].items[p].showDetails = show
    }

    /// Default subtotals on or off for a field.
    public mutating func setSubtotals(_ on: Bool, field f: Int) {
        fields[f].subtotals = on ? [.default] : []
        let data = fields[f].items.filter { $0.kind == .data }
        fields[f].items = data.isEmpty ? [] : data + (on ? [PivotItem(kind: .default)] : [])
    }

    /// Switch every field to a report layout.
    public mutating func setForm(_ form: PivotForm) {
        switch form {
        case .compact:
            layout.compact = true; layout.compactData = true; layout.outline = true; layout.outlineData = true
        case .outline:
            layout.compact = false; layout.compactData = false; layout.outline = true; layout.outlineData = true
        case .tabular:
            layout.compact = false; layout.compactData = false; layout.outline = false; layout.outlineData = false
        }
        for f in fields.indices {
            fields[f].compact = form == .compact
            fields[f].outline = form != .tabular
        }
    }

    /// The layout every field and the table share, if any.
    public var form: PivotForm? {
        if layout.compact && fields.allSatisfy({ $0.compact && $0.outline }) { return .compact }
        if !layout.compact && layout.outline && fields.allSatisfy({ !$0.compact && $0.outline }) { return .outline }
        if !layout.compact && !layout.outline && fields.allSatisfy({ !$0.outline }) { return .tabular }
        return nil
    }

    // MARK: Helpers

    static func defaultDataFieldName(subtotal: PivotSubtotal, fieldName: String) -> String {
        "\(subtotal.caption) of \(fieldName)"
    }

    func uniqueDataFieldName(subtotal: PivotSubtotal, field f: Int, cache: PivotCacheData) -> String {
        let base = Self.defaultDataFieldName(subtotal: subtotal, fieldName: cache.fields[f].name)
        var name = base, n = 2
        while dataFields.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = base + String(n)
            n += 1
        }
        return name
    }

    /// Excel shows the Values pseudo-field on columns once there are two or
    /// more value fields, and removes it below two.
    mutating func syncValuesField() {
        let has = rowFields.contains(pivotValuesFieldIndex) || columnFields.contains(pivotValuesFieldIndex)
        if dataFields.count >= 2 && !has {
            columnFields.append(pivotValuesFieldIndex)
        } else if dataFields.count < 2 && has {
            rowFields.removeAll { $0 == pivotValuesFieldIndex }
            columnFields.removeAll { $0 == pivotValuesFieldIndex }
            layout.dataOnRows = false
        }
    }
}

/// A placeholder payload for pivots made in SimpleSpread (no original XML).
public struct NewPivotPayload: PreservedPartPayload {
    public init() {}
}

extension Workbook {
    /// Create a pivot table over `source` on sheet `sourceSheetID`, with its
    /// body's top-left at `destination` on `destinationSheetID`. Returns the
    /// new table's index. Lay it out with computePivotTable/applyPivotLayout.
    /// Where a new pivot table with its body at `destination` sits: Excel's
    /// placeholder of 18 rows by 3 columns until fields are added, starting
    /// no higher than row 3 (room for report filters above it).
    public static func newPivotTableArea(at destination: CellAddress) -> CellRange {
        let top = CellAddress(row: max(destination.row, 2), column: destination.column)
        return CellRange(start: top, end: CellAddress(row: top.row + 17, column: top.column + 2))
    }

    /// `data`: the source already read (else it is read here).
    @discardableResult
    public func createPivotTable(sourceSheetID: Int, source: CellRange,
                                 destinationSheetID: Int, at destination: CellAddress,
                                 data: PivotCacheData? = nil) throws -> Int {
        guard let sheet = sheet(withID: sourceSheetID) else { throw PivotEngineError("the source sheet is missing") }
        let data = try data ?? PivotCacheBuilder.build(sheet: sheet, range: source, workbook: self)
        let cacheID = (pivotCaches.map(\.cacheID).max() ?? -1) + 1
        pivotCaches.append(PivotCache(cacheID: cacheID,
                                      sourceRanges: [PivotSourceRange(target: .sheet(id: sourceSheetID), ref: source.a1)],
                                      payload: NewPivotPayload(), data: data, isModified: true))
        var n = 1
        while pivotTables.contains(where: { $0.name.caseInsensitiveCompare("PivotTable\(n)") == .orderedSame }) { n += 1 }
        let name = "PivotTable\(n)"
        let location = Self.newPivotTableArea(at: destination)
        pivotTables.append(PivotTable(sheetID: destinationSheetID, name: name, cacheID: cacheID, location: location,
                                      payload: NewPivotPayload(), definition: .new(name: name, cache: data),
                                      isModified: true))
        if preservedStyles == nil { preservedStyles = PreservedStyles() }
        return pivotTables.count - 1
    }
}
