import Foundation

// The pivot engine: computes a pivot table's axis lines, geometry and
// rendered cells from its cache and definition, the way Excel lays them out.
// Rules and their evidence: docs/RESEARCH.md §Pivot engine; each was checked
// against the cells Excel itself wrote in the real-file fixtures.

/// UI-language captions Excel renders but doesn't store in the file.
public struct PivotCaptions: Sendable, Equatable {
    public var rowLabels = "Row Labels"
    public var columnLabels = "Column Labels"
    public var grandTotal = "Grand Total"
    public var total = "Total"
    public var all = "(All)"
    public var multipleItems = "(Multiple Items)"
    public var blank = "(blank)"

    public static let english = PivotCaptions()

    public init() {}

    public init(rowLabels: String, columnLabels: String, grandTotal: String, total: String,
                all: String, multipleItems: String, blank: String = "(blank)") {
        self.rowLabels = rowLabels
        self.columnLabels = columnLabels
        self.grandTotal = grandTotal
        self.total = total
        self.all = all
        self.multipleItems = multipleItems
        self.blank = blank
    }
}

/// One cell the pivot draws.
public struct PivotRenderedCell: Equatable, Sendable {
    public var value: CellValue
    /// Number format the pivot applies (nil: leave as is / General).
    public var numberFormat: NumberFormat?
    public var indent: Int
    public var pivotButton: Bool

    public init(value: CellValue, numberFormat: NumberFormat? = nil, indent: Int = 0, pivotButton: Bool = false) {
        self.value = value
        self.numberFormat = numberFormat
        self.indent = indent
        self.pivotButton = pivotButton
    }
}

/// Position relative to the top-left of the pivot body (`location ref`);
/// report-filter cells have negative rows.
public struct PivotOffset: Hashable, Sendable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) { self.row = row; self.column = column }
}

/// What the engine produces.
public struct PivotLayoutResult: Sendable {
    public var rowLines: [PivotAxisLine]
    public var columnLines: [PivotAxisLine]
    public var firstHeaderRow: Int
    public var firstDataRow: Int
    public var firstDataCol: Int
    /// Body size (the `location ref` extent).
    public var rowCount: Int
    public var columnCount: Int
    public var cells: [PivotOffset: PivotRenderedCell]
    /// Report filter block size (rowPageCount / colPageCount).
    public var pageRows: Int
    public var pageColumns: Int
    /// True for Excel's placeholder pivot with no fields.
    public var isEmpty: Bool
}

public struct PivotEngineError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

public struct PivotEngine {
    public let cache: PivotCacheData
    public let definition: PivotDefinition
    public var captions: PivotCaptions

    private let columns: [Int?]
    private let sharedIndexByValue: [[PivotValue: Int]]
    /// For each field: item x -> position in the pivot field's items list.
    private let positions: [[Int: Int]]
    private var dataFieldCount: Int { definition.dataFields.count }

    public init(cache: PivotCacheData, definition: PivotDefinition, captions: PivotCaptions = .english) {
        self.cache = cache
        self.definition = definition
        self.captions = captions
        columns = cache.recordColumns
        sharedIndexByValue = cache.fields.map { field in
            var map: [PivotValue: Int] = [:]
            for (i, v) in field.sharedItems.enumerated() where map[v] == nil { map[v] = i }
            return map
        }
        positions = definition.fields.map { field in
            var map: [Int: Int] = [:]
            for (p, item) in field.items.enumerated() where item.kind == .data {
                if let x = item.index { map[x] = p }
            }
            return map
        }
    }

    /// Why this pivot can't be computed (it stays preserve-only), or nil.
    public var unsupportedReason: String? {
        if cache.isOLAP { return "it reads from OLAP or the Data Model" }
        if cache.hasCalculatedItems { return "it has calculated items" }
        if !cache.hasRecords { return "its cache has no saved records" }
        if definition.fields.count != cache.fields.count { return "its fields don't match its cache" }
        for f in definition.fields where f.showAll && f.axis != nil && f.axis != .values {
            _ = f // showAll="1" (items with no data) isn't verified against Excel yet
            return "it shows items with no data"
        }
        for filter in definition.filters where !Self.supportsFilter(filter) {
            return "it uses a \(filter.type) filter"
        }
        for d in definition.dataFields {
            switch d.showDataAs {
            case .normal, .percentOfTotal, .percentOfRow, .percentOfCol, .index:
                break
            case .difference, .percent, .percentDiff, .runTotal:
                // Verified only when the base field isn't on an axis (#N/A).
                let onAxis = definition.rowFields.contains(d.baseField) || definition.columnFields.contains(d.baseField)
                if onAxis { return "it shows values as \(d.showDataAs.rawValue)" }
            default:
                return "it shows values as \(d.showDataAs.rawValue)"
            }
        }
        if definition.layout.subtotalHiddenItems { return "it includes hidden items in totals" }
        if definition.layout.pageWrap > 0 { return "its report filters wrap" }
        if definition.fields.contains(where: \.insertBlankRow) { return "it inserts blank rows" }
        return nil
    }

    static func supportsFilter(_ filter: PivotFilter) -> Bool {
        if filter.type == "count" { return !filter.top10Percent }
        if filter.type.hasPrefix("date") { return !filter.conditions.isEmpty }
        return false
    }

    // MARK: Fields

    private func isGrouping(_ f: Int) -> Bool {
        guard let g = cache.fields[f].group else { return false }
        return g.range != nil || !g.discreteMap.isEmpty
    }

    private func axisItems(_ f: Int) -> [PivotValue] {
        isGrouping(f) ? (cache.fields[f].group?.items ?? []) : cache.fields[f].sharedItems
    }

    /// The value of cache field `f` in record `r` (group fields: their group label).
    func raw(_ r: Int, _ f: Int) -> PivotValue {
        let column = columns[f]
        if column == nil, isGrouping(f) {
            guard let ix = itemIndex(r, f) else { return .missing }
            let items = axisItems(f)
            return ix >= 0 && ix < items.count ? items[ix] : .missing
        }
        guard let column else { return .missing }
        return cache.value(record: r, column: column, field: f)
    }

    private func sharedIndex(_ r: Int, _ f: Int) -> Int? {
        guard let column = columns[f], r < cache.records.count, column < cache.records[r].count else { return nil }
        switch cache.records[r][column] {
        case .shared(let i): return i
        case .value(let v): return sharedIndexByValue[f][v]
        }
    }

    /// Index into the field's axis items (shared or group items).
    func itemIndex(_ r: Int, _ f: Int) -> Int? {
        if let g = cache.fields[f].group {
            let base = g.base ?? f
            if !g.discreteMap.isEmpty {
                guard let bi = sharedIndex(r, base), bi >= 0, bi < g.discreteMap.count else { return nil }
                return g.discreteMap[bi]
            }
            if let range = g.range {
                return Self.bucket(range, itemCount: g.items.count, value: raw(r, base))
            }
        }
        return sharedIndex(r, f)
    }

    static func bucket(_ range: PivotFieldGroup.Range, itemCount n: Int, value: PivotValue) -> Int? {
        let v: Double
        switch value {
        case .number(let x), .date(let x): v = x
        default: return nil
        }
        if range.groupBy == .range {
            let start = range.startNumber ?? 0, end = range.endNumber ?? 0
            if v < start { return 0 }
            if v > end { return n - 1 }
            return Int(((v - start) / range.interval).rounded(.down)) + 1
        }
        if let s = range.startDate, v < s { return 0 }
        if let e = range.endDate, v > e { return n - 1 }
        guard let c = ExcelDate.components(fromSerial: v) else { return nil }
        switch range.groupBy {
        case .years:
            guard let s = range.startDate.flatMap(ExcelDate.components(fromSerial:)) else { return nil }
            return c.year - s.year + 1
        case .quarters: return (c.month - 1) / 3 + 1
        case .months: return c.month
        case .days:
            let step = Int(range.interval)
            if step <= 1 {
                // Day of year in a leap-year calendar: 1-Jan = 1 ... 31-Dec = 366.
                var day = c.day
                for m in 1..<c.month { day += ExcelDate.daysInMonth(year: 2000, month: m) }
                return day
            }
            guard let s = range.startDate else { return nil }
            return Int(((v - s.rounded(.down)) / Double(step)).rounded(.down)) + 1
        case .hours: return c.hour + 1
        case .minutes: return c.minute + 1
        case .seconds: return Int(c.second) + 1
        case .range: return nil
        }
    }

    // MARK: Aggregation

    static func aggregate(_ fn: PivotSubtotal, _ values: [PivotValue]) -> CellValue? {
        guard !values.isEmpty else { return nil }
        var nums: [Double] = []
        var nonBlank = 0
        var firstError: CellError?
        for v in values {
            switch v {
            case .missing: continue
            case .number(let x), .date(let x): nums.append(x); nonBlank += 1
            case .error(let e): if firstError == nil { firstError = e }; nonBlank += 1
            case .string, .bool: nonBlank += 1
            }
        }
        switch fn {
        case .count: return nonBlank > 0 ? .number(Double(nonBlank)) : nil
        case .countNums: return nonBlank > 0 ? .number(Double(nums.count)) : nil
        default: break
        }
        if let firstError { return .error(firstError) }
        if nonBlank == 0 { return nil }
        switch fn {
        case .sum: return .number(nums.reduce(0, +))
        case .average: return nums.isEmpty ? .error(.div0) : .number(nums.reduce(0, +) / Double(nums.count))
        case .max: return .number(nums.max() ?? 0)
        case .min: return .number(nums.min() ?? 0)
        case .product: return .number(nums.isEmpty ? 0 : nums.reduce(1, *))
        case .stdDev, .var, .stdDevp, .varp:
            let population = fn == .stdDevp || fn == .varp
            let n = nums.count
            if n == 0 || (n < 2 && !population) { return .error(.div0) }
            let mean = nums.reduce(0, +) / Double(n)
            let ss = nums.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            let variance = ss / Double(population ? n : n - 1)
            return .number(fn == .stdDev || fn == .stdDevp ? variance.squareRoot() : variance)
        case .count, .countNums: return nil
        }
    }

    private static func function(for kind: PivotItem.Kind) -> PivotSubtotal? {
        switch kind {
        case .sum: return .sum
        case .countA: return .count
        case .count: return .countNums
        case .avg: return .average
        case .max: return .max
        case .min: return .min
        case .product: return .product
        case .stdDev: return .stdDev
        case .stdDevP: return .stdDevp
        case .var: return .var
        case .varP: return .varp
        default: return nil
        }
    }

    private func fieldIndex(named name: String) -> Int? {
        cache.fields.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func value(field f: Int, subtotal: PivotSubtotal, records: [Int]) -> CellValue? {
        if let formula = cache.fields[f].formula {
            guard !records.isEmpty else { return nil }
            return PivotCalculatedField.evaluate(formula) { name in
                guard let i = fieldIndex(named: name) else { return .error(.name) }
                if cache.fields[i].formula != nil {
                    return value(field: i, subtotal: .sum, records: records) ?? .number(0)
                }
                return Self.aggregate(.sum, records.map { raw($0, i) }) ?? .number(0)
            }
        }
        return Self.aggregate(subtotal, records.map { raw($0, f) })
    }

    // MARK: Filtering

    func filteredRecords() -> [Int] {
        var pageSelection: [Int: Int] = [:]
        for page in definition.pageFields {
            if let item = page.selectedItem, item < definition.fields[page.field].items.count,
               let x = definition.fields[page.field].items[item].index {
                pageSelection[page.field] = x
            }
        }
        var hidden: [Int: Set<Int>] = [:]
        for (f, field) in definition.fields.enumerated() where field.axis != nil {
            let set = Set(field.items.filter { $0.hidden }.compactMap(\.index))
            if !set.isEmpty { hidden[f] = set }
        }
        var records: [Int] = []
        for r in cache.records.indices {
            if pageSelection.contains(where: { itemIndex(r, $0.key) != $0.value }) { continue }
            if hidden.contains(where: { entry in itemIndex(r, entry.key).map { entry.value.contains($0) } ?? false }) {
                continue
            }
            records.append(r)
        }
        for filter in definition.filters.sorted(by: { $0.evalOrder < $1.evalOrder }) {
            records = apply(filter, to: records)
        }
        return records
    }

    private func apply(_ filter: PivotFilter, to records: [Int]) -> [Int] {
        let f = filter.field
        if filter.type == "count" {
            guard filter.measureField < definition.dataFields.count else { return records }
            let dataField = definition.dataFields[filter.measureField]
            var byItem: [Int?: [Int]] = [:]
            var order: [Int?] = []
            for r in records {
                let key = itemIndex(r, f)
                if byItem[key] == nil { order.append(key) }
                byItem[key, default: []].append(r)
            }
            func score(_ key: Int?) -> Double {
                if case .number(let n)? = value(field: dataField.field, subtotal: dataField.subtotal,
                                                 records: byItem[key] ?? []) { return n }
                return 0
            }
            let n = Int(filter.top10Value ?? 10)
            let ranked = order.sorted { filter.top10Top ? score($0) > score($1) : score($0) < score($1) }
            let keep = Set(ranked.prefix(n).map { $0 })
            return records.filter { keep.contains(itemIndex($0, f)) }
        }
        // Date filters: compare the date serial with each condition.
        return records.filter { r in
            let x: Double
            switch raw(r, f) {
            case .date(let d), .number(let d): x = d
            default: return false
            }
            let results = filter.conditions.map { condition -> Bool in
                guard let target = Double(condition.value) else { return false }
                switch condition.op {
                case "equal": return x == target
                case "notEqual": return x != target
                case "lessThan": return x < target
                case "lessThanOrEqual": return x <= target
                case "greaterThan": return x > target
                case "greaterThanOrEqual": return x >= target
                default: return false
                }
            }
            return filter.conditionsAreAnd ? results.allSatisfy { $0 } : results.contains(true)
        }
    }

    // MARK: Axis items

    /// One entry on an axis before encoding.
    struct AxisEntry: Equatable {
        var kind: PivotItem.Kind
        var tuple: [Int]
        var dataField: Int
    }

    private final class Node {
        var children: [Int: Node] = [:]
    }

    private func fieldOutline(_ f: Int) -> Bool {
        f == pivotValuesFieldIndex ? definition.layout.outlineData : definition.fields[f].outline
    }

    private func fieldCompact(_ f: Int) -> Bool {
        if f == pivotValuesFieldIndex { return definition.layout.compactData && definition.layout.outlineData }
        let s = definition.fields[f]
        return s.compact && s.outline && definition.layout.compact
    }

    private func subtotalKinds(_ f: Int) -> [PivotItem.Kind] {
        guard f != pivotValuesFieldIndex else { return [] }
        let kinds = definition.fields[f].subtotals
        let custom = kinds.filter { $0 != .default }
        return custom.isEmpty ? kinds.filter { $0 == .default } : custom
    }

    private func expanded(_ f: Int, _ p: Int) -> Bool {
        f == pivotValuesFieldIndex || definition.fields[f].items[p].showDetails
    }

    func axisEntries(_ fields: [Int], records: [Int], grand: Bool, isRow: Bool) -> [AxisEntry] {
        let n = fields.count
        if n == 0 { return [AxisEntry(kind: .data, tuple: [], dataField: 0)] }
        if !fields.contains(where: { $0 != pivotValuesFieldIndex }) {
            return (0..<dataFieldCount).map { AxisEntry(kind: .data, tuple: [$0], dataField: $0) }
        }
        let root = Node()
        for r in records {
            var keys: [Int] = []
            var ok = true
            for f in fields where f != pivotValuesFieldIndex {
                guard let x = itemIndex(r, f), let p = positions[f][x] else { ok = false; break }
                keys.append(p)
            }
            guard ok else { continue }
            var node = root
            for p in keys {
                if let next = node.children[p] { node = next } else {
                    let next = Node()
                    node.children[p] = next
                    node = next
                }
            }
        }
        var out: [AxisEntry] = []
        func emit(_ level: Int, _ path: [Int], _ node: Node, _ dataField: Int) {
            let f = fields[level]
            let last = level == n - 1
            let kids = f == pivotValuesFieldIndex ? Array(0..<dataFieldCount) : node.children.keys.sorted()
            let deeperNonValues = fields[(level + 1)...].contains { $0 != pivotValuesFieldIndex }
            let deeperValues = fields[(level + 1)...].contains(pivotValuesFieldIndex)
            for p in kids {
                let child = f == pivotValuesFieldIndex ? node : node.children[p]!
                let current = f == pivotValuesFieldIndex ? p : dataField
                let tuple = path + [p]
                if last || !expanded(f, p) || (!deeperNonValues && !deeperValues) {
                    out.append(AxisEntry(kind: .data, tuple: tuple, dataField: current))
                    continue
                }
                let own = isRow && fieldOutline(f)
                let kinds = deeperNonValues ? subtotalKinds(f) : []
                let top = own && kinds == [.default] && f != pivotValuesFieldIndex && definition.fields[f].subtotalTop
                if own { out.append(AxisEntry(kind: .data, tuple: tuple, dataField: current)) }
                emit(level + 1, tuple, child, current)
                if !kinds.isEmpty && !top {
                    for kind in kinds {
                        if deeperValues && dataFieldCount > 1 {
                            for d in 0..<dataFieldCount { out.append(AxisEntry(kind: kind, tuple: tuple, dataField: d)) }
                        } else {
                            out.append(AxisEntry(kind: kind, tuple: tuple, dataField: current))
                        }
                    }
                }
            }
        }
        emit(0, [], root, 0)
        if grand {
            if fields.contains(pivotValuesFieldIndex) && dataFieldCount > 1 {
                for d in 0..<dataFieldCount { out.append(AxisEntry(kind: .grand, tuple: [], dataField: d)) }
            } else {
                out.append(AxisEntry(kind: .grand, tuple: [], dataField: 0))
            }
        }
        return out
    }

    static func encode(_ entries: [AxisEntry]) -> [PivotAxisLine] {
        var lines: [PivotAxisLine] = []
        var previous: [Int] = []
        for entry in entries {
            switch entry.kind {
            case .grand:
                lines.append(PivotAxisLine(kind: .grand, repeated: 0, dataFieldIndex: entry.dataField, members: [0]))
                previous = []
                continue
            case .data:
                var r = 0
                while r < entry.tuple.count && r < previous.count && entry.tuple[r] == previous[r] { r += 1 }
                if r == entry.tuple.count && !entry.tuple.isEmpty { r = entry.tuple.count - 1 }
                lines.append(PivotAxisLine(kind: .data, repeated: r, dataFieldIndex: entry.dataField,
                                           members: Array(entry.tuple[r...])))
            default:
                let level = entry.tuple.count - 1
                lines.append(PivotAxisLine(kind: entry.kind, repeated: level, dataFieldIndex: entry.dataField,
                                           members: [entry.tuple[level]]))
            }
            previous = entry.tuple
        }
        return lines
    }

    // MARK: Geometry

    struct Geometry {
        var captionRow: Bool
        var firstHeaderRow: Int
        var firstDataRow: Int
        var firstDataCol: Int
        var labelColumns: [Int]
    }

    func geometry() -> Geometry {
        let rowFields = definition.rowFields, colFields = definition.columnFields
        let layout = definition.layout
        let hasColumns = !colFields.isEmpty
        let onlyValues = colFields == [pivotValuesFieldIndex]
        let captionRow = (hasColumns && !(onlyValues && layout.hideValuesRow))
            || (layout.gridDropZones && !hasColumns && !rowFields.contains(pivotValuesFieldIndex))
        let firstDataRow = (captionRow ? 1 : 0) + max(1, colFields.count)
        let firstHeaderRow = hasColumns ? (captionRow ? 1 : 0) : firstDataRow
        var labelColumns: [Int] = []
        var c = 0
        for (k, _) in rowFields.enumerated() {
            if k > 0 && !fieldCompact(rowFields[k - 1]) { c += 1 }
            labelColumns.append(c)
        }
        let firstDataCol = rowFields.isEmpty ? 0 : (labelColumns.last! + 1)
        return Geometry(captionRow: captionRow, firstHeaderRow: firstHeaderRow, firstDataRow: firstDataRow,
                        firstDataCol: firstDataCol, labelColumns: labelColumns)
    }

    // MARK: Compute

    public func compute() throws -> PivotLayoutResult {
        if let reason = unsupportedReason { throw PivotEngineError(reason) }
        let records = filteredRecords()
        let layout = definition.layout
        let pageRows = definition.pageFields.isEmpty ? 0 : definition.pageFields.count
        if dataFieldCount == 0 && definition.rowFields.isEmpty && definition.columnFields.isEmpty {
            var cells: [PivotOffset: PivotRenderedCell] = [:]
            renderPage(into: &cells)
            return PivotLayoutResult(rowLines: [], columnLines: [], firstHeaderRow: 1, firstDataRow: 1,
                                     firstDataCol: 0, rowCount: 18, columnCount: 3, cells: cells,
                                     pageRows: pageRows, pageColumns: pageRows > 0 ? 1 : 0, isEmpty: true)
        }
        let rows = axisEntries(definition.rowFields, records: records, grand: layout.rowGrandTotals, isRow: true)
        let cols = axisEntries(definition.columnFields, records: records, grand: layout.colGrandTotals, isRow: false)
        let rowLines = Self.encode(rows), columnLines = Self.encode(cols)
        let g = geometry()
        var cells: [PivotOffset: PivotRenderedCell] = [:]
        render(rows: rows, rowLines: rowLines, cols: cols, columnLines: columnLines, records: records,
               geometry: g, into: &cells)
        renderPage(into: &cells)
        return PivotLayoutResult(rowLines: rowLines, columnLines: columnLines,
                                 firstHeaderRow: g.firstHeaderRow, firstDataRow: g.firstDataRow,
                                 firstDataCol: g.firstDataCol, rowCount: g.firstDataRow + rowLines.count,
                                 columnCount: g.firstDataCol + columnLines.count, cells: cells,
                                 pageRows: pageRows, pageColumns: pageRows > 0 ? 1 : 0, isEmpty: false)
    }

    // MARK: Rendering

    private func label(_ f: Int, _ p: Int) -> CellValue {
        let item = definition.fields[f].items[p]
        if let name = item.name { return .string(name) }
        guard let x = item.index else { return .empty }
        let items = axisItems(f)
        guard x >= 0 && x < items.count else { return .empty }
        switch items[x] {
        case .string(let s): return .string(s)
        case .number(let n), .date(let n): return .number(n)
        case .bool(let b): return .string(b ? "TRUE" : "FALSE")
        case .missing: return .string(captions.blank)
        case .error(let e): return .error(e)
        }
    }

    private func text(_ v: CellValue, field f: Int) -> String {
        switch v {
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return NumberFormatEngine.displayString(for: v, format: definition.fields[f].numberFormat ?? .general)
        default:
            return v.rawDisplayString
        }
    }

    private func dataFieldName(_ d: Int) -> String {
        d < definition.dataFields.count ? definition.dataFields[d].name : ""
    }

    private func labelFormat(_ f: Int, _ v: CellValue) -> NumberFormat? {
        guard f != pivotValuesFieldIndex, case .number = v else { return nil }
        return definition.fields[f].numberFormat ?? .general
    }

    private func subtotalCaption(_ f: Int, _ p: Int, _ kind: PivotItem.Kind) -> String {
        let l = text(label(f, p), field: f)
        if kind == .default {
            if let custom = definition.fields[f].subtotalCaption { return custom.replacingOccurrences(of: "?", with: l) }
            return l + " " + captions.total
        }
        let names: [PivotItem.Kind: String] = [
            .sum: "Sum", .countA: "Count", .count: "Count Numbers", .avg: "Average", .max: "Max", .min: "Min",
            .product: "Product", .stdDev: "StdDev", .stdDevP: "StdDevp", .var: "Var", .varP: "Varp",
        ]
        return l + " " + (names[kind] ?? captions.total)
    }

    private func grandCaption(onAxis fields: [Int], dataField d: Int) -> String {
        if fields.contains(pivotValuesFieldIndex) && dataFieldCount > 1 { return captions.total + " " + dataFieldName(d) }
        return definition.layout.grandTotalCaption ?? captions.grandTotal
    }

    private func conditions(_ fields: [Int], _ tuple: [Int]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for (level, p) in tuple.enumerated() {
            let f = fields[level]
            guard f != pivotValuesFieldIndex, let x = definition.fields[f].items[p].index else { continue }
            out.append((f, x))
        }
        return out
    }

    private func isBlankParent(_ fields: [Int], _ tuple: [Int]) -> Bool {
        guard !tuple.isEmpty, tuple.count != fields.count else { return false }
        let level = tuple.count - 1
        let f = fields[level]
        guard f != pivotValuesFieldIndex else { return false }
        if !definition.fields[f].items[tuple[level]].showDetails { return false }
        let top = subtotalKinds(f) == [.default] && definition.fields[f].subtotalTop
        let deeperNonValues = fields[(level + 1)...].contains { $0 != pivotValuesFieldIndex }
        return !(top && deeperNonValues)
    }

    private func cellValue(row: AxisEntry, column: AxisEntry, records: [Int]) -> CellValue? {
        guard dataFieldCount > 0 else { return nil }
        var d = 0
        if definition.rowFields.contains(pivotValuesFieldIndex) { d = row.dataField }
        if definition.columnFields.contains(pivotValuesFieldIndex) { d = column.dataField }
        let dataField = definition.dataFields[d]
        if row.kind == .data && isBlankParent(definition.rowFields, row.tuple) { return nil }
        if column.kind == .data && isBlankParent(definition.columnFields, column.tuple) { return nil }
        let rowConditions = row.kind == .grand ? [] : conditions(definition.rowFields, row.tuple)
        let colConditions = column.kind == .grand ? [] : conditions(definition.columnFields, column.tuple)
        let all = rowConditions + colConditions
        let matching = records.filter { r in all.allSatisfy { itemIndex(r, $0.0) == $0.1 } }
        guard !matching.isEmpty else { return nil }
        var function = dataField.subtotal
        for kind in [row.kind, column.kind] { if let fn = Self.function(for: kind) { function = fn } }
        guard let v = value(field: dataField.field, subtotal: function, records: matching) else { return nil }
        guard dataField.showDataAs != .normal, case .number(let n) = v else { return v }
        func total(_ conds: [(Int, Int)]) -> Double? {
            let recs = records.filter { r in conds.allSatisfy { itemIndex(r, $0.0) == $0.1 } }
            guard !recs.isEmpty, case .number(let t)? = value(field: dataField.field, subtotal: function, records: recs)
            else { return nil }
            return t
        }
        func ratio(_ t: Double?) -> CellValue {
            guard let t, t != 0 else { return .error(.div0) }
            return .number(n / t)
        }
        switch dataField.showDataAs {
        case .percentOfTotal: return ratio(total([]))
        case .percentOfRow: return ratio(total(rowConditions))
        case .percentOfCol: return ratio(total(colConditions))
        case .index:
            guard let grand = total([]), let rowTotal = total(rowConditions), let colTotal = total(colConditions),
                  rowTotal != 0, colTotal != 0 else { return .error(.div0) }
            return .number(n * grand / (rowTotal * colTotal))
        default:
            return .error(.na) // base field not on an axis (others are refused up front)
        }
    }

    private func render(rows: [AxisEntry], rowLines: [PivotAxisLine], cols: [AxisEntry], columnLines: [PivotAxisLine],
                        records: [Int], geometry g: Geometry, into cells: inout [PivotOffset: PivotRenderedCell]) {
        let layout = definition.layout
        let rowFields = definition.rowFields, colFields = definition.columnFields
        let fhr = g.firstHeaderRow, fdr = g.firstDataRow, fdc = g.firstDataCol
        let lc = g.labelColumns
        let hr = fdr - 1
        func put(_ r: Int, _ c: Int, _ v: CellValue, format: NumberFormat? = nil, indent: Int = 0, button: Bool = false) {
            cells[PivotOffset(row: r, column: c)] = PivotRenderedCell(value: v, numberFormat: format, indent: indent,
                                                                      pivotButton: button)
        }
        let showHeaders = layout.showHeaders

        // Caption row.
        if g.captionRow && !colFields.isEmpty {
            if dataFieldCount == 1 && showHeaders { put(0, 0, .string(dataFieldName(0)), button: true) }
            if showHeaders {
                if layout.compact {
                    let caption = colFields == [pivotValuesFieldIndex]
                        ? layout.dataCaption : (layout.colHeaderCaption ?? captions.columnLabels)
                    put(0, fdc, .string(caption), button: true)
                } else {
                    for (j, f) in colFields.enumerated() {
                        put(0, fdc + j, .string(f == pivotValuesFieldIndex ? layout.dataCaption : fieldName(f)), button: true)
                    }
                }
            }
        } else if g.captionRow && layout.gridDropZones && dataFieldCount == 1 && showHeaders {
            put(0, 0, .string(dataFieldName(0)), button: true)
        }

        // Row header row.
        if !rowFields.isEmpty && showHeaders {
            if layout.compact && rowFields.dropLast().allSatisfy(fieldCompact) {
                put(hr, 0, .string(layout.rowHeaderCaption ?? captions.rowLabels), button: true)
            } else {
                for (k, f) in rowFields.enumerated() where cells[PivotOffset(row: hr, column: lc[k])] == nil {
                    put(hr, lc[k], .string(f == pivotValuesFieldIndex ? layout.dataCaption : fieldName(f)), button: true)
                }
            }
        }
        if colFields.isEmpty && dataFieldCount > 0 {
            if layout.gridDropZones {
                put(hr, fdc, .string(captions.total))
            } else if dataFieldCount == 1 || !rowFields.contains(pivotValuesFieldIndex) {
                put(hr, fdc, .string(dataFieldName(0)))
            }
        }

        // Column labels.
        if !colFields.isEmpty {
            for (ci, (entry, line)) in zip(cols, columnLines).enumerated() {
                let c = fdc + ci
                if entry.kind == .grand {
                    put(fhr, c, .string(grandCaption(onAxis: colFields, dataField: entry.dataField)))
                    continue
                }
                if entry.kind != .data {
                    let level = entry.tuple.count - 1
                    put(fhr + level, c, .string(subtotalCaption(colFields[level], entry.tuple[level], entry.kind)))
                    continue
                }
                for level in entry.tuple.indices {
                    let f = colFields[level]
                    let fill = f != pivotValuesFieldIndex && definition.fields[f].fillDownLabels
                    guard level >= line.repeated || fill else { continue }
                    let v: CellValue = f == pivotValuesFieldIndex ? .string(dataFieldName(entry.tuple[level]))
                        : label(f, entry.tuple[level])
                    put(fhr + level, c, v, format: labelFormat(f, v))
                }
            }
        }

        // Row labels and values.
        let valuesOnColumns = colFields.contains(pivotValuesFieldIndex)
        let valuesOnRows = rowFields.contains(pivotValuesFieldIndex)
        for (ri, (entry, line)) in zip(rows, rowLines).enumerated() {
            let r = fdr + ri
            if !rowFields.isEmpty {
                if entry.kind == .grand {
                    put(r, 0, .string(grandCaption(onAxis: rowFields, dataField: entry.dataField)))
                } else if entry.kind != .data {
                    let level = entry.tuple.count - 1
                    put(r, lc[level], .string(subtotalCaption(rowFields[level], entry.tuple[level], entry.kind)))
                } else {
                    for level in entry.tuple.indices {
                        let f = rowFields[level]
                        let fill = f != pivotValuesFieldIndex && definition.fields[f].fillDownLabels && !fieldCompact(f)
                        guard level >= line.repeated || fill else { continue }
                        let v: CellValue = f == pivotValuesFieldIndex ? .string(dataFieldName(entry.tuple[level]))
                            : label(f, entry.tuple[level])
                        let depth = level - lc.firstIndex(of: lc[level])!
                        let indent = depth > 0 && fieldCompact(rowFields[level - 1]) ? depth * (layout.indent + 1) : 0
                        put(r, lc[level], v, format: labelFormat(f, v), indent: indent)
                    }
                }
            }
            for (ci, column) in cols.enumerated() {
                let d = valuesOnColumns ? column.dataField : (valuesOnRows ? entry.dataField : 0)
                let format = dataFieldCount > 0 ? definition.dataFields[d].numberFormat : nil
                if let v = cellValue(row: entry, column: column, records: records) {
                    put(r, fdc + ci, v, format: format)
                }
            }
        }
    }

    private func fieldName(_ f: Int) -> String {
        definition.fields[f].name ?? cache.fields[f].name
    }

    private func renderPage(into cells: inout [PivotOffset: PivotRenderedCell]) {
        let pages = definition.pageFields
        guard !pages.isEmpty else { return }
        let n = pages.count
        let wrap = definition.layout.pageWrap > 0 ? definition.layout.pageWrap : n
        let over = definition.layout.pageOverThenDown
        let rowCount = over ? (n + wrap - 1) / wrap : min(n, wrap)
        for (j, page) in pages.enumerated() {
            let f = page.field
            let row = over ? j / wrap : j % wrap
            let group = over ? j % wrap : j / wrap
            let r = -(rowCount + 1) + row
            let c = group * 3
            cells[PivotOffset(row: r, column: c)] = PivotRenderedCell(value: .string(cache.fields[f].name), pivotButton: true)
            let value: CellValue
            let items = definition.fields[f].items
            if let item = page.selectedItem, item < items.count {
                value = label(f, item)
            } else {
                let visible = items.indices.filter { items[$0].kind == .data && !items[$0].hidden }
                let anyHidden = items.contains { $0.hidden }
                if !anyHidden || !definition.fields[f].multipleItemSelectionAllowed {
                    value = .string(captions.all)
                } else if visible.count == 1 {
                    value = label(f, visible[0])
                } else {
                    value = .string(captions.multipleItems)
                }
            }
            cells[PivotOffset(row: r, column: c + 1)] = PivotRenderedCell(value: value)
        }
    }
}
