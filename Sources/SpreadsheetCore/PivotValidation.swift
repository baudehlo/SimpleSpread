import Foundation

// Checks that a pivot read from a file is well formed before the engine
// touches it. Pivot parts index into each other (fields into the cache,
// items into shared items, groups into fields); a file with a bad index
// would otherwise trap the process — and pivots are computed while drawing.
// A pivot that fails is kept verbatim and not computed (preserve-only).

extension PivotDefinition {
    /// Why this definition can't be computed against `cache`, or nil when
    /// every index it holds points at something that exists.
    public func validate(against cache: PivotCacheData) -> String? {
        if let reason = cache.validate() { return reason }
        let n = cache.fields.count
        guard fields.count == n else { return "its fields don't match its cache" }
        func exists(_ f: Int) -> Bool { f >= 0 && f < n }
        func missing(_ f: Int) -> String { "it refers to field \(f), which its cache doesn't have" }

        var placed = Set<Int>()
        var valuesFields = 0
        for f in rowFields + columnFields {
            if f == pivotValuesFieldIndex { valuesFields += 1; continue }
            guard exists(f) else { return missing(f) }
            guard placed.insert(f).inserted else { return "it puts field \(f) on its axes twice" }
        }
        if valuesFields > 1 { return "it puts Values on its axes twice" }
        for page in pageFields {
            guard exists(page.field) else { return missing(page.field) }
            guard placed.insert(page.field).inserted else { return "it puts field \(page.field) on its axes twice" }
            if let item = page.selectedItem {
                let items = fields[page.field].items
                guard item >= 0, item < items.count, items[item].kind == .data else {
                    return "its report filter selects an item that doesn't exist"
                }
            }
        }
        for d in dataFields where !exists(d.field) { return missing(d.field) }
        for filter in filters {
            guard exists(filter.field) else { return missing(filter.field) }
            if let top = filter.top10Value, !(top.isFinite && top >= 0) {
                return "it has a top-10 filter of \(top) items"
            }
        }
        // Items of fields on an axis index the field's items (shared or group).
        for f in placed {
            let count = PivotEngine.axisItemCount(cache, f)
            for item in fields[f].items where item.kind == .data {
                guard let x = item.index, x >= 0, x < count else {
                    return "an item of “\(cache.fields[f].name)” refers to a value its cache doesn't have"
                }
            }
        }
        guard (0...255).contains(layout.indent) else { return "its indent of \(layout.indent) is out of range" }
        guard (0...255).contains(layout.pageWrap) else { return "its report filter wrap of \(layout.pageWrap) is out of range" }
        return nil
    }
}

extension PivotCacheData {
    /// Why the cache can't be computed from, or nil.
    func validate() -> String? {
        let n = fields.count
        for (f, field) in fields.enumerated() {
            guard let g = field.group else { continue }
            if let b = g.base, !(b >= 0 && b < n) { return "the grouping of “\(field.name)” refers to a missing field" }
            if let p = g.parent, !(p >= 0 && p < n) { return "the grouping of “\(field.name)” refers to a missing field" }
            if let r = g.range {
                // Ranges group a source column's values.
                guard fields[g.base ?? f].isDatabaseField else {
                    return "the grouping of “\(field.name)” isn't based on a source column"
                }
                // A blank or text value fits no range: it would drop out of
                // the rows but still count in the totals.
                if fields[g.base ?? f].sharedItems.contains(where: { !$0.isNumeric }) {
                    return "its grouped field “\(fields[g.base ?? f].name)” has blank or text cells"
                }
                let bounds = [r.startNumber, r.endNumber, r.startDate, r.endDate].compactMap { $0 }
                guard r.interval.isFinite, r.interval > 0, bounds.allSatisfy(\.isFinite) else {
                    return "the grouping of “\(field.name)” has an invalid interval or bounds"
                }
            }
        }
        if let name = calculatedFieldCycle() { return "its calculated field “\(name)” refers to itself" }
        return nil
    }

    /// The first calculated field whose formula leads back to itself.
    func calculatedFieldCycle() -> String? {
        func index(named name: String) -> Int? {
            fields.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        var references: [Int: [Int]] = [:]
        for (f, field) in fields.enumerated() {
            guard let formula = field.formula else { continue }
            references[f] = PivotCalculatedField.tokenize(formula).compactMap { token in
                if case .name(let name) = token, let i = index(named: name), fields[i].formula != nil { return i }
                return nil
            }
        }
        // Depth-first search for a back edge.
        var state: [Int: Bool] = [:] // false = on the stack, true = done
        func cycles(from f: Int) -> Bool {
            if let done = state[f] { return !done }
            state[f] = false
            for g in references[f] ?? [] where cycles(from: g) { return true }
            state[f] = true
            return false
        }
        for f in references.keys.sorted() where cycles(from: f) { return fields[f].name }
        return nil
    }
}

/// `x` as an Int when it is finite and in range (Int(Double) traps otherwise).
func pivotCheckedInt(_ x: Double) -> Int? {
    guard x.isFinite, x > -9.0e15, x < 9.0e15 else { return nil }
    return Int(x)
}
