import Foundation

// Grouping a pivot field: dates by years/quarters/months/days, numbers into
// equal ranges (Excel's Group…). Grouping changes the cache, so every pivot
// table sharing it sees the grouped field.

public enum PivotDateGrouping: String, CaseIterable, Sendable {
    case years, quarters, months, days

    var groupBy: PivotFieldGroup.GroupBy {
        switch self {
        case .years: return .years
        case .quarters: return .quarters
        case .months: return .months
        case .days: return .days
        }
    }

    /// Excel's name for the extra field a coarser level adds.
    var fieldName: String { rawValue.capitalized }
}

extension PivotFieldGroup {
    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Group items for a date range: "<start", the parts, ">end".
    static func dateItems(_ groupBy: GroupBy, start: Double, end: Double) -> [PivotValue] {
        func dateText(_ serial: Double) -> String {
            NumberFormatEngine.displayString(for: .number(serial), format: NumberFormat(code: "m/d/yyyy"))
        }
        var items: [PivotValue] = [.string("<" + dateText(start))]
        switch groupBy {
        case .years:
            let y0 = ExcelDate.components(fromSerial: start)?.year ?? 1900
            let y1 = ExcelDate.components(fromSerial: end)?.year ?? y0
            items += (y0...max(y0, y1)).map { .string(String($0)) }
        case .quarters:
            items += (1...4).map { .string("Qtr\($0)") }
        case .months:
            items += monthNames.map { .string($0) }
        case .days:
            for m in 1...12 {
                for d in 1...ExcelDate.daysInMonth(year: 2000, month: m) { items.append(.string("\(d)-\(monthNames[m - 1])")) }
            }
        case .hours:
            items += (0..<24).map { .string(String($0)) }
        case .minutes, .seconds:
            items += (0..<60).map { .string(String(format: ":%02d", $0)) }
        case .range:
            break
        }
        items.append(.string(">" + dateText(end)))
        return items
    }

    /// The most items a grouped field may have: Excel's limit on a pivot
    /// field's items. (An outlier in auto-ranged data could otherwise ask
    /// for hundreds of millions of groups.)
    public static let maxItems = 1_048_576

    /// Numeric range grouping, in one place: the labels grouping and
    /// refresh write and the bucket the engine puts each value in.
    ///
    /// Over whole numbers (whole data, start and step) each range is closed
    /// — "0-4", "5-9" — and the last one holds `end`; otherwise ranges are
    /// continuous — "0-1", "1-2", each from its low value up to the next,
    /// the last one up to and including `end` (as Excel labels them).
    /// Items are "<start", the ranges, ">end".
    struct NumberRanges {
        var start: Double
        var end: Double
        var step: Double
        var closed: Bool
        var count: Int

        /// nil when the ranges are invalid or too many (see maxItems).
        init?(start: Double, end: Double, interval: Double, integers: Bool) {
            guard start.isFinite, end.isFinite, interval.isFinite, interval > 0, end >= start else { return nil }
            let closed = integers && interval == interval.rounded() && start == start.rounded()
            let span = (end - start) / interval
            let ranges = closed ? span.rounded(.down) + 1 : max(1, span.rounded(.up))
            guard ranges.isFinite, ranges <= Double(PivotFieldGroup.maxItems - 2) else { return nil }
            self.start = start
            self.end = end
            self.step = interval
            self.closed = closed
            self.count = Int(ranges)
        }

        var items: [PivotValue] {
            var items: [PivotValue] = [.string("<" + Self.text(start))]
            items.reserveCapacity(count + 2)
            for b in 0..<count {
                let low = start + Double(b) * step
                items.append(.string(Self.text(low) + "-" + Self.text(low + step - (closed ? 1 : 0))))
            }
            items.append(.string(">" + Self.text(closed ? start + Double(count) * step : end)))
            return items
        }

        /// A label number: whole numbers without a decimal point, others to
        /// 15 significant digits (so 0.1 steps read 0.3, not 0.30000000000000004).
        static func text(_ x: Double) -> String {
            if x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
            var s = String(format: "%.15g", x)
            if s.contains("."), !s.contains("e") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
            return s
        }

        /// Item index of `v` among `itemCount` items laid out as above.
        static func bucket(_ v: Double, start: Double, end: Double, interval: Double, itemCount n: Int) -> Int? {
            guard n >= 2, v.isFinite else { return nil }
            if v < start { return 0 }
            if v > end { return n - 1 }
            guard interval > 0, n >= 3 else { return nil }
            // A hair of tolerance, so 0.3 lands in "0.3-0.4" despite 0.3/0.1
            // being 2.9999999999999996.
            let q = (v - start) / interval
            guard let k = pivotCheckedInt((q + 1e-9 * max(1, abs(q))).rounded(.down)) else { return n - 2 }
            // `end` itself belongs to the last range, never to ">end".
            return min(max(k, 0) + 1, n - 2)
        }
    }

    /// Group items for numeric ranges (see NumberRanges).
    static func numberItems(start: Double, end: Double, interval: Double, integers: Bool) -> [PivotValue]? {
        NumberRanges(start: start, end: end, interval: interval, integers: integers)?.items
    }
}

extension Workbook {
    /// The numeric values of a database field (dates as serials).
    private func numericValues(_ data: PivotCacheData, field f: Int) -> [Double] {
        data.fields[f].sharedItems.compactMap { v -> Double? in
            switch v { case .number(let n), .date(let n): return n; default: return nil }
        }
    }

    /// Group the field `f` of table `index`'s cache by date parts, finest
    /// level in place and coarser levels as new fields placed before it.
    public func groupPivotField(table index: Int, field f: Int, byDates levels: Set<PivotDateGrouping>) throws {
        let cacheID = pivotTables[index].cacheID
        guard let c = pivotCaches.firstIndex(where: { $0.cacheID == cacheID }), var data = pivotCaches[c].data else {
            throw PivotEngineError("its cache couldn't be read")
        }
        guard data.fields[f].isDatabaseField, data.fields[f].group == nil else {
            throw PivotEngineError("“\(data.fields[f].name)” is already grouped")
        }
        try Self.requireNoBlanks(data, field: f)
        let values = numericValues(data, field: f)
        guard let lo = values.min(), let hi = values.max(),
              data.fields[f].sharedItems.allSatisfy({
                  switch $0 { case .date, .number: return true; default: return false }
              })
        else { throw PivotEngineError("only fields of dates can be grouped by date") }
        let ordered = PivotDateGrouping.allCases.reversed().filter(levels.contains) // finest first
        guard let finest = ordered.first else { return }
        let start = lo.rounded(.down), end = (hi + 1).rounded(.down)
        func range(_ level: PivotDateGrouping) -> PivotFieldGroup.Range {
            PivotFieldGroup.Range(groupBy: level.groupBy, startDate: start, endDate: end)
        }
        // Coarser levels: new fields after the existing ones.
        var newFields: [Int] = []
        for level in ordered.dropFirst() {
            data.fields.append(PivotCacheField(
                name: uniqueFieldName(level.fieldName, in: data), isDatabaseField: false,
                group: PivotFieldGroup(base: f, range: range(level),
                                       items: PivotFieldGroup.dateItems(level.groupBy, start: start, end: end))))
            newFields.append(data.fields.count - 1)
        }
        // Chain finest -> coarser through `par`.
        let chain = [f] + newFields
        data.fields[f].group = PivotFieldGroup(parent: chain.count > 1 ? chain[1] : nil, base: f, range: range(finest),
                                               items: PivotFieldGroup.dateItems(finest.groupBy, start: start, end: end))
        for (k, g) in newFields.enumerated() where k + 2 < chain.count {
            data.fields[g].group?.parent = chain[k + 2]
        }
        try applyGrouping(cacheIndex: c, data: data, field: f, newFields: newFields)
    }

    /// Group the numeric field `f` into ranges of `interval` from `start` to
    /// `end` (nil: the data's minimum / maximum).
    public func groupPivotField(table index: Int, field f: Int, interval: Double,
                                start: Double? = nil, end: Double? = nil) throws {
        let cacheID = pivotTables[index].cacheID
        guard let c = pivotCaches.firstIndex(where: { $0.cacheID == cacheID }), var data = pivotCaches[c].data else {
            throw PivotEngineError("its cache couldn't be read")
        }
        guard data.fields[f].isDatabaseField, data.fields[f].group == nil else {
            throw PivotEngineError("“\(data.fields[f].name)” is already grouped")
        }
        try Self.requireNoBlanks(data, field: f)
        let values = numericValues(data, field: f)
        guard let lo = values.min(), let hi = values.max(), interval > 0,
              data.fields[f].sharedItems.allSatisfy({ if case .number = $0 { return true }; return false })
        else { throw PivotEngineError("only fields of numbers can be grouped into ranges") }
        let s = start ?? lo, e = end ?? hi
        guard e >= s else { throw PivotEngineError("the ranges must end after they start") }
        guard let items = PivotFieldGroup.numberItems(start: s, end: e, interval: interval,
                                                      integers: values.allSatisfy { $0 == $0.rounded() }) else {
            throw Self.tooManyGroups(data.fields[f].name, interval: interval)
        }
        data.fields[f].group = PivotFieldGroup(
            base: f,
            range: PivotFieldGroup.Range(groupBy: .range, autoStart: start == nil, autoEnd: end == nil,
                                         startNumber: s, endNumber: e, interval: interval),
            items: items)
        try applyGrouping(cacheIndex: c, data: data, field: f, newFields: [])
    }

    static func tooManyGroups(_ name: String, interval: Double) -> PivotEngineError {
        PivotEngineError("grouping “\(name)” by \(PivotFieldGroup.NumberRanges.text(interval)) would make more than "
                         + "\(PivotFieldGroup.maxItems.formatted()) groups; choose a larger step or set where the ranges start and end")
    }

    /// Remove a field's grouping (and the extra date-level fields it added).
    public func ungroupPivotField(table index: Int, field f: Int) throws {
        let cacheID = pivotTables[index].cacheID
        guard let c = pivotCaches.firstIndex(where: { $0.cacheID == cacheID }), var data = pivotCaches[c].data,
              data.fields[f].group != nil, data.fields[f].isDatabaseField else { return }
        let extra = data.fields.indices.filter { !data.fields[$0].isDatabaseField && data.fields[$0].group?.base == f }
        data.fields[f].group = nil
        // Drop the extra fields (they're last in the cache when we added them).
        let keep = data.fields.indices.filter { !extra.contains($0) }
        var remap: [Int: Int] = [:]
        for (new, old) in keep.enumerated() { remap[old] = new }
        data.fields = keep.map { data.fields[$0] }
        for i in data.fields.indices {
            if let p = data.fields[i].group?.parent { data.fields[i].group?.parent = remap[p] }
            if let b = data.fields[i].group?.base { data.fields[i].group?.base = remap[b] }
        }
        for t in pivotTables.indices where pivotTables[t].cacheID == cacheID {
            guard var d = pivotTables[t].definition else { continue }
            for g in extra { d.removeFromAxes(g); while let i = d.dataFields.firstIndex(where: { $0.field == g }) { d.removeDataField(at: i) } }
            d.fields = keep.map { d.fields[$0] }
            d.rowFields = d.rowFields.map { $0 < 0 ? $0 : remap[$0]! }
            d.columnFields = d.columnFields.map { $0 < 0 ? $0 : remap[$0]! }
            d.pageFields = d.pageFields.map { var p = $0; p.field = remap[p.field]!; return p }
            d.dataFields = d.dataFields.map { var x = $0; x.field = remap[x.field]!; x.baseField = remap[x.baseField] ?? 0; return x }
            d.filters = d.filters.compactMap { var x = $0; guard let g = remap[x.field] else { return nil }; x.field = g; return x }
            let fieldIndex = remap[f] ?? f
            // The grouped items give way to the field's own values.
            d.replaceItems(field: fieldIndex, with: [], moved: [:])
            if d.fields[fieldIndex].axis != nil { d.ensureItems(fieldIndex, cache: data) }
            pivotTables[t].definition = d
            pivotTables[t].isModified = true
        }
        pivotCaches[c].data = data
        pivotCaches[c].isModified = true
    }

    /// Excel won't group a field with blank cells into dates or ranges
    /// ("Cannot group that selection"): a blank fits no group, so it would
    /// drop out of the rows while still counting in the totals.
    static func requireNoBlanks(_ data: PivotCacheData, field f: Int) throws {
        if data.fields[f].sharedItems.contains(.missing) {
            throw PivotEngineError("“\(data.fields[f].name)” has blank cells, and a field with blanks can’t be grouped")
        }
    }

    private func uniqueFieldName(_ base: String, in data: PivotCacheData) -> String {
        var name = base, n = 2
        while data.fields.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = base + String(n); n += 1 }
        return name
    }

    /// Store a regrouped cache and give every table sharing it settings for
    /// the new fields; the grouped field's items become the group items, and
    /// new date levels go before it on its axis.
    private func applyGrouping(cacheIndex c: Int, data: PivotCacheData, field f: Int, newFields: [Int]) throws {
        let cacheID = pivotCaches[c].cacheID
        for t in pivotTables.indices where pivotTables[t].cacheID == cacheID {
            guard var d = pivotTables[t].definition else { continue }
            for _ in newFields { d.fields.append(PivotFieldSettings(showAll: false)) }
            let axis = d.axisArea(of: f)
            let hadItems = !d.fields[f].items.isEmpty
            // The field's values give way to its groups; whatever named one
            // of its items by position falls back.
            d.replaceItems(field: f, with: [], moved: [:])
            // Group items keep their own order (<start, parts, >end).
            if hadItems || axis != nil { d.ensureItems(f, cache: data) }
            if let axis {
                let position = d.fields(in: axis).firstIndex(of: f) ?? 0
                // Inserting finest-first at the same spot leaves coarsest first.
                for g in newFields {
                    d.place(field: g, in: axis, at: position, cache: data)
                    let count = data.fields[g].axisItems.count
                    d.fields[g].items = (0..<count).map { PivotItem(kind: .data, index: $0) } + [PivotItem(kind: .default)]
                }
            }
            pivotTables[t].definition = d
            pivotTables[t].isModified = true
        }
        pivotCaches[c].data = data
        pivotCaches[c].isModified = true
    }
}
