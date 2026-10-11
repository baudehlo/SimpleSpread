import Foundation

// Refreshing a pivot cache from its source range, and carrying the pivot
// tables' settings across to the new cache (Excel's Refresh).

extension PivotValue {
    /// Excel's ascending item order: numbers and dates by value, then text
    /// (case- and accent-insensitive), then booleans, errors, blanks last.
    static func ascending(_ a: PivotValue, _ b: PivotValue) -> Bool {
        func rank(_ v: PivotValue) -> Int {
            switch v {
            case .number, .date: return 0
            case .string: return 1
            case .bool: return 2
            case .error: return 3
            case .missing: return 4
            }
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        switch (a, b) {
        case (.number(let x), .number(let y)), (.date(let x), .date(let y)),
             (.number(let x), .date(let y)), (.date(let x), .number(let y)):
            return x < y
        case (.string(let x), .string(let y)):
            return x.compare(y, options: [.caseInsensitive, .diacriticInsensitive],
                             locale: Locale(identifier: "en_US")) == .orderedAscending
        case (.bool(let x), .bool(let y)):
            return !x && y
        case (.error(let x), .error(let y)):
            return x.rawValue < y.rawValue
        default:
            return false
        }
    }

    /// Identity for matching items across refreshes (text ignores case).
    var matchKey: PivotValue {
        if case .string(let s) = self { return .string(s.lowercased()) }
        if case .date(let d) = self { return .number(d) }
        return self
    }
}

public enum PivotCacheBuilder {
    /// Read a source range (header row plus records) into cache data.
    /// Calculated fields of `previous` are kept; grouping is re-derived where
    /// supported.
    public static func build(sheet: Sheet, range: CellRange, workbook: Workbook,
                             previous: PivotCacheData? = nil) throws -> PivotCacheData {
        guard range.rowCount >= 2 else {
            throw PivotEngineError("the source needs a header row and at least one row of data")
        }
        // Headers: the displayed text; duplicates get a number suffix.
        var names: [String] = []
        for c in range.start.column...range.end.column {
            let address = CellAddress(row: range.start.row, column: c)
            let cell = sheet.cell(at: address)
            let text = NumberFormatEngine.displayString(for: cell.value, format: workbook.style(at: cell.styleIndex).numberFormat)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                throw PivotEngineError("the field name in \(address.a1) is blank; every source column needs a heading")
            }
            var name = text, n = 2
            while names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { name = text + String(n); n += 1 }
            names.append(name)
        }

        var fields: [PivotCacheField] = []
        var keys: [[PivotValue: Int]] = []
        var records: [[PivotRecordValue]] = Array(repeating: [], count: range.rowCount - 1)
        for (k, c) in (range.start.column...range.end.column).enumerated() {
            var field = PivotCacheField(name: names[k])
            var map: [PivotValue: Int] = [:]
            for r in (range.start.row + 1)...range.end.row {
                let cell = sheet.cell(at: CellAddress(row: r, column: c))
                let format = workbook.style(at: cell.styleIndex).numberFormat
                if r == range.start.row + 1 { field.numberFormat = format }
                let value: PivotValue
                switch cell.value {
                case .empty: value = .missing
                case .number(let n): value = format.isDateTime ? .date(n) : .number(n)
                case .string(let s): value = s.isEmpty ? .missing : .string(s)
                case .bool(let b): value = .bool(b)
                case .error(let e): value = .error(e)
                }
                let key = value.matchKey
                let index: Int
                if let existing = map[key] {
                    index = existing
                } else {
                    index = field.sharedItems.count
                    field.sharedItems.append(value)
                    map[key] = index
                }
                records[r - range.start.row - 1].append(.shared(index))
            }
            fields.append(field)
            keys.append(map)
        }

        // Fields that aren't source columns (calculated fields, group fields)
        // follow in their old order; old indices map to new ones.
        if let previous {
            var newIndex: [Int: Int] = [:]
            for (i, old) in previous.fields.enumerated() where old.isDatabaseField {
                newIndex[i] = fields.firstIndex { $0.isDatabaseField && $0.name.caseInsensitiveCompare(old.name) == .orderedSame }
            }
            var next = fields.count
            for (i, old) in previous.fields.enumerated() where !old.isDatabaseField {
                newIndex[i] = next
                next += 1
            }
            for (i, old) in previous.fields.enumerated() where !old.isDatabaseField {
                var field = old
                if let group = old.group {
                    field.group = try regroup(group, fieldIndex: i, previous: previous, fields: fields, newIndex: newIndex)
                }
                fields.append(field)
            }
            // Groups on source columns themselves (dates grouped in place, or
            // a base pointing at its group field).
            for (i, old) in previous.fields.enumerated() where old.isDatabaseField {
                guard let group = old.group, let j = newIndex[i] ?? nil else { continue }
                fields[j].group = try regroup(group, fieldIndex: i, previous: previous, fields: fields, newIndex: newIndex)
            }
        }
        return PivotCacheData(fields: fields, records: records)
    }

    /// A group carried to the rebuilt cache: discrete groups remap by value;
    /// range groups keep their items, or recompute bounds and the labels that
    /// depend on them when the bounds are automatic.
    static func regroup(_ group: PivotFieldGroup, fieldIndex: Int, previous: PivotCacheData,
                        fields: [PivotCacheField], newIndex: [Int: Int?]) throws -> PivotFieldGroup {
        var result = group
        result.parent = group.parent.flatMap { newIndex[$0] ?? nil }
        guard let oldBase = group.base else { return result }
        guard let base = newIndex[oldBase] ?? nil, base < fields.count, fields[base].isDatabaseField else {
            throw PivotEngineError("the grouped field “\(previous.fields[fieldIndex].name)” no longer has its source column")
        }
        result.base = base
        if !group.discreteMap.isEmpty {
            var items = group.items
            var byValue: [PivotValue: Int] = [:]
            for (i, g) in group.discreteMap.enumerated() where i < previous.fields[oldBase].sharedItems.count {
                byValue[previous.fields[oldBase].sharedItems[i].matchKey] = g
            }
            result.discreteMap = fields[base].sharedItems.map { item in
                if let g = byValue[item.matchKey] { return g }
                items.append(item)
                byValue[item.matchKey] = items.count - 1
                return items.count - 1
            }
            result.items = items
            return result
        }
        guard var range = group.range else { return result }
        let values = fields[base].sharedItems.compactMap { v -> Double? in
            switch v { case .number(let n), .date(let n): return n; default: return nil }
        }
        guard let lo = values.min(), let hi = values.max() else { return result }
        if range.groupBy == .range {
            let start = range.autoStart ? lo : (range.startNumber ?? lo)
            let end = range.autoEnd ? hi : (range.endNumber ?? hi)
            if start == range.startNumber && end == range.endNumber { return result }
            range.startNumber = start
            range.endNumber = end
            let step = range.interval > 0 ? range.interval : 1
            let buckets = Int(((end - start) / step).rounded(.down)) + 1
            func text(_ x: Double) -> String { x == x.rounded() ? String(Int64(x)) : "\(x)" }
            var items: [PivotValue] = [.string("<" + text(start))]
            for b in 0..<buckets {
                let low = start + Double(b) * step
                items.append(.string(text(low) + "-" + text(low + step - (step == step.rounded() ? 1 : 0))))
            }
            items.append(.string(">" + text(start + Double(buckets) * step)))
            result.items = items
            result.range = range
            return result
        }
        let startDate = range.autoStart ? lo.rounded(.down) : (range.startDate ?? lo.rounded(.down))
        let endDate = range.autoEnd ? (hi + 1).rounded(.down) : (range.endDate ?? (hi + 1).rounded(.down))
        if startDate == range.startDate && endDate == range.endDate { return result }
        range.startDate = startDate
        range.endDate = endDate
        result.range = range
        func dateText(_ serial: Double) -> String {
            NumberFormatEngine.displayString(for: .number(serial), format: NumberFormat(code: "m/d/yyyy"))
        }
        let first: PivotValue = .string("<" + dateText(startDate))
        let last: PivotValue = .string(">" + dateText(endDate))
        if range.groupBy == .years,
           let y0 = ExcelDate.components(fromSerial: startDate)?.year, let y1 = ExcelDate.components(fromSerial: endDate)?.year {
            result.items = [first] + (y0...max(y0, y1)).map { .string(String($0)) } + [last]
        } else if !group.items.isEmpty {
            // Fixed parts (months, quarters, days, times) keep their labels.
            result.items[0] = first
            result.items[result.items.count - 1] = last
        }
        return result
    }
}

extension PivotDefinition {
    /// This definition carried over to a rebuilt cache: fields matched by
    /// name, item settings (hidden, collapsed, captions) matched by value,
    /// manual order kept with new items appended in ascending order.
    public func remapped(from old: PivotCacheData, to new: PivotCacheData) throws -> PivotDefinition {
        var fieldMap: [Int: Int] = [:]
        for (i, field) in old.fields.enumerated() {
            if let j = new.fields.firstIndex(where: { $0.name.caseInsensitiveCompare(field.name) == .orderedSame }) {
                fieldMap[i] = j
            }
        }
        let used = rowFields + columnFields + pageFields.map(\.field) + dataFields.map(\.field)
        for f in used where f >= 0 && fieldMap[f] == nil {
            throw PivotEngineError("the field “\(old.fields[f].name)” is no longer in the source")
        }
        func map(_ f: Int) -> Int { f < 0 ? f : fieldMap[f]! }

        var result = self
        result.fields = new.fields.map { _ in PivotFieldSettings(showAll: false) }
        for (i, settings) in fields.enumerated() {
            guard let j = fieldMap[i] else { continue }
            var s = settings
            if !settings.items.isEmpty || settings.axis != nil {
                s.items = Self.remapItems(settings, oldItems: old.fields[i].axisItems, newItems: new.fields[j].axisItems)
            }
            result.fields[j] = s
        }
        result.rowFields = rowFields.map(map)
        result.columnFields = columnFields.map(map)
        result.pageFields = pageFields.map { page in
            var p = page
            p.field = map(page.field)
            if let item = page.selectedItem, item < fields[page.field].items.count,
               let x = fields[page.field].items[item].index, x < old.fields[page.field].axisItems.count {
                let key = old.fields[page.field].axisItems[x].matchKey
                let newItems = new.fields[p.field].axisItems
                p.selectedItem = result.fields[p.field].items.firstIndex { item in
                    item.index.map { $0 < newItems.count && newItems[$0].matchKey == key } ?? false
                }
            }
            return p
        }
        result.dataFields = dataFields.map { d in
            var d = d
            d.field = map(d.field)
            d.baseField = fieldMap[d.baseField] ?? 0
            return d
        }
        result.filters = filters.compactMap { filter in
            guard let f = fieldMap[filter.field] else { return nil }
            var filter = filter
            filter.field = f
            return filter
        }
        return result
    }

    static func remapItems(_ settings: PivotFieldSettings, oldItems: [PivotValue], newItems: [PivotValue]) -> [PivotItem] {
        var byKey: [PivotValue: PivotItem] = [:]
        var oldOrder: [PivotValue] = []
        for item in settings.items where item.kind == .data {
            guard let x = item.index, x < oldItems.count else { continue }
            let key = oldItems[x].matchKey
            if byKey[key] == nil { oldOrder.append(key) }
            byKey[key] = item
        }
        var newIndex: [PivotValue: Int] = [:]
        for (i, v) in newItems.enumerated() where newIndex[v.matchKey] == nil { newIndex[v.matchKey] = i }

        var order: [Int]
        let fresh = newItems.indices.filter { byKey[newItems[$0].matchKey] == nil }
            .sorted { PivotValue.ascending(newItems[$0], newItems[$1]) }
        switch settings.sort {
        case .manual:
            order = oldOrder.compactMap { newIndex[$0] } + fresh
        case .ascending, .descending:
            order = newItems.indices.sorted { PivotValue.ascending(newItems[$0], newItems[$1]) }
            if settings.sort == .descending { order.reverse() }
        }
        var items = order.map { x -> PivotItem in
            var item = byKey[newItems[x].matchKey] ?? PivotItem(kind: .data)
            item.index = x
            item.kind = .data
            return item
        }
        for kind in settings.subtotals { items.append(PivotItem(kind: kind)) }
        return items
    }
}

extension Workbook {
    /// Rebuild a cache from its source and carry its tables across. Tables
    /// are not re-laid out here (see computePivotTable / applyPivotLayout).
    public func refreshPivotCache(withID cacheID: Int) throws {
        guard let c = pivotCaches.firstIndex(where: { $0.cacheID == cacheID }) else { return }
        let cache = pivotCaches[c]
        guard let old = cache.data else { throw PivotEngineError("its cache couldn't be read") }
        guard cache.sourceRanges.count == 1, let source = cache.sourceRanges.first else {
            throw PivotEngineError("it combines several ranges")
        }
        let sheetID: Int
        switch source.target {
        case .sheet(let id): sheetID = id
        case .detached(let name): throw PivotEngineError("its source sheet “\(name)” no longer exists")
        case .external: throw PivotEngineError("its source is in another workbook")
        }
        guard let sheet = sheet(withID: sheetID), let range = Self.sourceRange(source.ref, sheet: sheet) else {
            throw PivotEngineError("its source range \(source.ref) isn't valid")
        }
        let data = try PivotCacheBuilder.build(sheet: sheet, range: range, workbook: self, previous: old)
        var definitions: [Int: PivotDefinition] = [:]
        for (i, table) in pivotTables.enumerated() where table.cacheID == cacheID {
            guard let definition = table.definition else { throw PivotEngineError("“\(table.name)” couldn't be read") }
            definitions[i] = try definition.remapped(from: old, to: data)
        }
        pivotCaches[c].data = data
        pivotCaches[c].isModified = true
        for (i, definition) in definitions {
            pivotTables[i].definition = definition
            pivotTables[i].isModified = true
        }
    }

    /// A source reference as a concrete range (whole columns/rows clipped to
    /// the sheet's used area).
    static func sourceRange(_ ref: String, sheet: Sheet) -> CellRange? {
        guard let expr = try? FormulaParser.parse(ref), case .reference(let r) = expr,
              let concrete = r.concreteRange() else { return nil }
        guard r.isWholeColumn || r.isWholeRow else { return concrete }
        guard let used = sheet.usedRange else { return nil }
        let start = CellAddress(row: max(concrete.start.row, used.start.row), column: max(concrete.start.column, used.start.column))
        let end = CellAddress(row: min(concrete.end.row, used.end.row), column: min(concrete.end.column, used.end.column))
        guard start.row <= end.row && start.column <= end.column else { return nil }
        return CellRange(start: start, end: end)
    }
}
