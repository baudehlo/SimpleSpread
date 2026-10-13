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

/// What a pivot cell is, for styling.
public enum PivotCellRole: Sendable {
    case header, rowLabel, columnLabel, subtotalLabel, grandTotalLabel
    case value, subtotalValue, grandTotalValue
    case filterLabel, filterValue
}

/// One cell the pivot draws.
public struct PivotRenderedCell: Equatable, Sendable {
    public var value: CellValue
    public var role: PivotCellRole = .value
    /// Number format the pivot applies (nil: leave as is / General).
    public var numberFormat: NumberFormat?
    public var indent: Int
    public var pivotButton: Bool

    public init(value: CellValue, numberFormat: NumberFormat? = nil, indent: Int = 0, pivotButton: Bool = false,
                role: PivotCellRole = .value) {
        self.value = value
        self.role = role
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

    public init(rowLines: [PivotAxisLine], columnLines: [PivotAxisLine], firstHeaderRow: Int, firstDataRow: Int,
                firstDataCol: Int, rowCount: Int, columnCount: Int, cells: [PivotOffset: PivotRenderedCell],
                pageRows: Int, pageColumns: Int, isEmpty: Bool) {
        self.rowLines = rowLines
        self.columnLines = columnLines
        self.firstHeaderRow = firstHeaderRow
        self.firstDataRow = firstDataRow
        self.firstDataCol = firstDataCol
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cells = cells
        self.pageRows = pageRows
        self.pageColumns = pageColumns
        self.isEmpty = isEmpty
    }
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
        if let reason = definition.validate(against: cache) { return reason }
        for filter in definition.filters where !Self.supportsFilter(filter) {
            return "it uses a \(filter.type) filter"
        }
        for d in definition.dataFields {
            switch d.showDataAs {
            case .normal, .percentOfTotal, .percentOfRow, .percentOfCol, .index,
                 .difference, .percent, .percentDiff, .runTotal:
                break
            default:
                return "it shows values as \(d.showDataAs.rawValue)"
            }
        }
        if definition.layout.subtotalHiddenItems { return "it includes hidden items in totals" }
        return nil
    }

    static func supportsFilter(_ filter: PivotFilter) -> Bool {
        if filter.type == "count" { return !filter.top10Percent }
        if filter.type.hasPrefix("date") { return !filter.conditions.isEmpty }
        return false
    }

    // MARK: Fields

    private func isGrouping(_ f: Int) -> Bool {
        Self.isGrouping(cache, f)
    }

    static func isGrouping(_ cache: PivotCacheData, _ f: Int) -> Bool {
        guard f >= 0, f < cache.fields.count, let g = cache.fields[f].group else { return false }
        return g.range != nil || !g.discreteMap.isEmpty
    }

    /// How many items a pivot field's `<item x>` can index.
    static func axisItemCount(_ cache: PivotCacheData, _ f: Int) -> Int {
        guard f >= 0, f < cache.fields.count else { return 0 }
        return isGrouping(cache, f) ? (cache.fields[f].group?.items.count ?? 0) : cache.fields[f].sharedItems.count
    }

    private func axisItems(_ f: Int) -> [PivotValue] {
        guard f >= 0, f < cache.fields.count else { return [] }
        return isGrouping(f) ? (cache.fields[f].group?.items ?? []) : cache.fields[f].sharedItems
    }

    /// The value of cache field `f` in record `r` (group fields: their group label).
    func raw(_ r: Int, _ f: Int) -> PivotValue {
        guard f >= 0, f < columns.count else { return .missing }
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
        guard f >= 0, f < columns.count, let column = columns[f], r >= 0, r < cache.records.count,
              column < cache.records[r].count else { return nil }
        switch cache.records[r][column] {
        case .shared(let i): return i
        case .value(let v): return sharedIndexByValue[f][v]
        }
    }

    /// Index into the field's axis items (shared or group items).
    func itemIndex(_ r: Int, _ f: Int) -> Int? {
        guard f >= 0, f < cache.fields.count else { return nil }
        if let g = cache.fields[f].group {
            let base = g.base ?? f
            if !g.discreteMap.isEmpty {
                guard let bi = sharedIndex(r, base), bi >= 0, bi < g.discreteMap.count else { return nil }
                return g.discreteMap[bi]
            }
            if let range = g.range {
                // A grouping field's own record value never feeds itself.
                guard base != f || columns[f] != nil else { return nil }
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
        guard n > 0, v.isFinite else { return nil }
        if range.groupBy == .range {
            let start = range.startNumber ?? 0, end = range.endNumber ?? 0
            if v < start { return 0 }
            if v > end { return n - 1 }
            guard range.interval > 0, let k = pivotCheckedInt(((v - start) / range.interval).rounded(.down)) else { return nil }
            return min(k + 1, n - 1)
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
            guard let step = pivotCheckedInt(range.interval.rounded(.down)) else { return nil }
            if step <= 1 {
                // Day of year in a leap-year calendar: 1-Jan = 1 ... 31-Dec = 366.
                var day = c.day
                for m in 1..<c.month { day += ExcelDate.daysInMonth(year: 2000, month: m) }
                return day
            }
            guard let s = range.startDate,
                  let k = pivotCheckedInt(((v - s.rounded(.down)) / Double(step)).rounded(.down)) else { return nil }
            return k + 1
        case .hours: return c.hour + 1
        case .minutes: return c.minute + 1
        case .seconds: return pivotCheckedInt(c.second.rounded(.down)).map { $0 + 1 }
        case .range: return nil
        }
    }

    // MARK: Aggregation

    static func aggregate(_ fn: PivotSubtotal, _ values: [PivotValue]) -> CellValue? {
        PivotAccumulator.summarizing(values).result(fn)
    }

    static func function(for kind: PivotItem.Kind) -> PivotSubtotal? {
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

    /// The summary of field `f` over some records, reading each source
    /// field's running summary from `summary`. A calculated field applies its
    /// formula to the sums of the fields it names (as Excel does).
    func value(field f: Int, subtotal: PivotSubtotal, recordCount: Int,
               summary: (Int) -> PivotAccumulator?, visiting: Set<Int> = []) -> CellValue? {
        guard f >= 0, f < cache.fields.count else { return nil }
        if let formula = cache.fields[f].formula {
            guard recordCount > 0 else { return nil }
            // A formula that leads back to itself is refused up front
            // (validate); never recurse forever all the same.
            guard !visiting.contains(f) else { return .error(.ref) }
            return PivotCalculatedField.evaluate(formula) { name in
                guard let i = fieldIndex(named: name) else { return .error(.name) }
                if cache.fields[i].formula != nil {
                    return value(field: i, subtotal: .sum, recordCount: recordCount, summary: summary,
                                 visiting: visiting.union([f])) ?? .number(0)
                }
                return summary(i)?.result(.sum) ?? .number(0)
            }
        }
        return summary(f)?.result(subtotal)
    }

    /// The summary of field `f` over `records` (summing them on the spot).
    func value(field f: Int, subtotal: PivotSubtotal, records: [Int]) -> CellValue? {
        value(field: f, subtotal: subtotal, recordCount: records.count) { i in
            var a = PivotAccumulator(keepValues: true)
            for r in records { a.add(raw(r, i)) }
            return a
        }
    }

    /// Source fields a summary of `f` reads: itself, or the fields a
    /// calculated field's formula names (through other calculated fields).
    func sourceFields(of f: Int, visiting: Set<Int> = []) -> Set<Int> {
        guard f >= 0, f < cache.fields.count, !visiting.contains(f) else { return [] }
        guard let formula = cache.fields[f].formula else { return [f] }
        var out = Set<Int>()
        for case .name(let name) in PivotCalculatedField.tokenize(formula) {
            guard let i = fieldIndex(named: name) else { continue }
            out.formUnion(sourceFields(of: i, visiting: visiting.union([f])))
        }
        return out
    }

    // MARK: Filtering

    func filteredRecords() -> [Int] {
        var pageSelection: [Int: Int] = [:]
        for page in definition.pageFields where page.field >= 0 && page.field < definition.fields.count {
            if let item = page.selectedItem, item >= 0, item < definition.fields[page.field].items.count,
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
            guard filter.measureField >= 0, filter.measureField < definition.dataFields.count else { return records }
            let dataField = definition.dataFields[filter.measureField]
            let keys = records.map { itemIndex($0, f) }
            var byItem: [Int?: [Int]] = [:]
            var order: [Int?] = []
            for (r, key) in zip(records, keys) {
                if byItem[key] == nil { order.append(key) }
                byItem[key, default: []].append(r)
            }
            // Each item's score once (not once per comparison).
            var score: [Int?: Double] = [:]
            for key in order {
                if case .number(let n)? = value(field: dataField.field, subtotal: dataField.subtotal,
                                                 records: byItem[key] ?? []) {
                    score[key] = n
                } else {
                    score[key] = 0
                }
            }
            let wanted = filter.top10Value ?? 10
            let n = wanted >= Double(order.count) ? order.count : (wanted > 0 ? Int(wanted) : 0)
            let ranked = order.sorted { filter.top10Top ? score[$0]! > score[$1]! : score[$0]! < score[$1]! }
            let keep = Set(ranked.prefix(n))
            return zip(records, keys).filter { keep.contains($0.1) }.map(\.0)
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

    /// The entries of one axis. `keys[f][k]` is the item index of field `f`
    /// in the k-th of `recordCount` filtered records.
    func axisEntries(_ fields: [Int], keys: [Int: [Int?]], recordCount: Int, grand: Bool, isRow: Bool) -> [AxisEntry] {
        let n = fields.count
        if n == 0 { return [AxisEntry(kind: .data, tuple: [], dataField: 0)] }
        if !fields.contains(where: { $0 != pivotValuesFieldIndex }) {
            return (0..<dataFieldCount).map { AxisEntry(kind: .data, tuple: [$0], dataField: $0) }
        }
        let root = Node()
        let columns = fields.filter { $0 != pivotValuesFieldIndex }.map { (positions[$0], keys[$0] ?? []) }
        for k in 0..<recordCount {
            var path: [Int] = []
            var ok = true
            for (position, xs) in columns {
                guard k < xs.count, let x = xs[k], let p = position[x] else { ok = false; break }
                path.append(p)
            }
            guard ok else { continue }
            var node = root
            for p in path {
                if let next = node.children[p] { node = next } else {
                    let next = Node()
                    node.children[p] = next
                    node = next
                }
            }
        }
        // Fields showing items with no data list every visible item.
        let nonValues = fields.filter { $0 != pivotValuesFieldIndex }
        func augment(_ node: Node, _ depth: Int) {
            guard depth < nonValues.count else { return }
            let f = nonValues[depth]
            if definition.fields[f].showAll {
                for (p, item) in definition.fields[f].items.enumerated()
                where item.kind == .data && !item.hidden && node.children[p] == nil {
                    node.children[p] = Node()
                }
            }
            for child in node.children.values { augment(child, depth + 1) }
        }
        augment(root, 0)

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
                if isRow && f != pivotValuesFieldIndex && definition.fields[f].insertBlankRow {
                    out.append(AxisEntry(kind: .blank, tuple: tuple, dataField: current))
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
        // With column fields but no row fields Excel keeps a label column for
        // the value field's name (checked in Excel).
        let firstDataCol = rowFields.isEmpty
            ? (colFields.contains { $0 != pivotValuesFieldIndex } ? 1 : 0)
            : (labelColumns.last! + 1)
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
        // Each record's item on every axis field, worked out once.
        var keys: [Int: [Int?]] = [:]
        for f in definition.rowFields + definition.columnFields where f != pivotValuesFieldIndex && keys[f] == nil {
            keys[f] = records.map { itemIndex($0, f) }
        }
        let rows = axisEntries(definition.rowFields, keys: keys, recordCount: records.count,
                               grand: layout.rowGrandTotals, isRow: true)
        let cols = axisEntries(definition.columnFields, keys: keys, recordCount: records.count,
                               grand: layout.colGrandTotals, isRow: false)
        let rowLines = Self.encode(rows), columnLines = Self.encode(cols)
        let g = geometry()
        let table = ValueTable(self, records: records, keys: keys)
        var cells: [PivotOffset: PivotRenderedCell] = [:]
        render(rows: rows, rowLines: rowLines, cols: cols, columnLines: columnLines, table: table,
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
        // Excel writes an error item's label as text ("#N/A"), checked in Excel.
        case .error(let e): return .string(e.xlsxRepresentation)
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

    /// The item indices a tuple constrains (Values levels constrain nothing).
    private func path(_ fields: [Int], _ tuple: [Int]) -> [Int] {
        var out: [Int] = []
        for (level, p) in tuple.enumerated() {
            let f = fields[level]
            guard f != pivotValuesFieldIndex, let x = definition.fields[f].items[p].index else { continue }
            out.append(x)
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

    /// Running summaries for every (row path, column path) a record reaches,
    /// built in one pass over the records. A path is the item indices of the
    /// leading non-Values fields of an axis; a record counts towards every
    /// prefix of its paths (so subtotals and grand totals come for free).
    /// A record with no item for some field still counts in the shorter
    /// prefixes, as it would when filtering records by conditions.
    struct ValueTable {
        /// Children of each path node, by item index (node 0 is the root).
        private var rowTrie: [[Int: Int]] = [[:]]
        private var columnTrie: [[Int: Int]] = [[:]]
        /// First accumulator of each (row node, column node) reached.
        private var groups: [Int: Int] = [:]
        private var accumulators: [PivotAccumulator] = []
        /// Accumulator slot of each source field summarized.
        private var slots: [Int: Int] = [:]

        init(_ engine: PivotEngine, records: [Int], keys: [Int: [Int?]]) {
            let definition = engine.definition
            var fields = Set<Int>()
            for d in definition.dataFields { fields.formUnion(engine.sourceFields(of: d.field)) }
            let ordered = fields.sorted()
            for (s, f) in ordered.enumerated() { slots[f] = s }
            // Variances need every number; other summaries only running totals.
            var kinds = definition.dataFields.map(\.subtotal)
            for f in definition.rowFields + definition.columnFields where f >= 0 && f < definition.fields.count {
                kinds += definition.fields[f].subtotals.compactMap(PivotEngine.function(for:))
            }
            let fresh = PivotAccumulator(keepValues: kinds.contains(where: \.needsValues))
            let rowKeys = definition.rowFields.filter { $0 != pivotValuesFieldIndex }.map { keys[$0] ?? [] }
            let columnKeys = definition.columnFields.filter { $0 != pivotValuesFieldIndex }.map { keys[$0] ?? [] }

            func nodes(_ trie: inout [[Int: Int]], _ keys: [[Int?]], _ k: Int) -> [Int] {
                var out = [0]
                var node = 0
                for xs in keys {
                    guard k < xs.count, let x = xs[k] else { break }
                    if let next = trie[node][x] {
                        node = next
                    } else {
                        trie.append([:])
                        trie[node][x] = trie.count - 1
                        node = trie.count - 1
                    }
                    out.append(node)
                }
                return out
            }

            let width = ordered.count
            var values = [PivotValue](repeating: .missing, count: width)
            for (k, r) in records.enumerated() {
                let rowNodes = nodes(&rowTrie, rowKeys, k)
                let columnNodes = nodes(&columnTrie, columnKeys, k)
                for (s, f) in ordered.enumerated() { values[s] = engine.raw(r, f) }
                for rn in rowNodes {
                    for cn in columnNodes {
                        let key = rn << 32 | cn
                        let first: Int
                        if let existing = groups[key] {
                            first = existing
                        } else {
                            first = accumulators.count
                            groups[key] = first
                            accumulators.append(contentsOf: repeatElement(fresh, count: max(1, width)))
                        }
                        // Every group counts its records, even with no fields to sum.
                        if width == 0 { accumulators[first].add(.missing) }
                        for s in 0..<width { accumulators[first + s].add(values[s]) }
                    }
                }
            }
        }

        private static func node(_ trie: [[Int: Int]], _ path: [Int]) -> Int? {
            var node = 0
            for x in path {
                guard let next = trie[node][x] else { return nil }
                node = next
            }
            return node
        }

        /// The records under a row path and a column path, as a group; nil
        /// when no record matches both.
        func group(_ rowPath: [Int], _ columnPath: [Int]) -> Int? {
            guard let rn = Self.node(rowTrie, rowPath), let cn = Self.node(columnTrie, columnPath) else { return nil }
            return groups[rn << 32 | cn]
        }

        func recordCount(_ group: Int) -> Int { accumulators[group].records }

        func summary(_ group: Int, field f: Int) -> PivotAccumulator? {
            slots[f].map { accumulators[group + $0] }
        }
    }

    private func value(_ table: ValueTable, _ group: Int, field f: Int, subtotal: PivotSubtotal) -> CellValue? {
        value(field: f, subtotal: subtotal, recordCount: table.recordCount(group)) { table.summary(group, field: $0) }
    }

    private func cellValue(row: AxisEntry, column: AxisEntry, table: ValueTable) -> CellValue? {
        guard dataFieldCount > 0 else { return nil }
        var d = 0
        if definition.rowFields.contains(pivotValuesFieldIndex) { d = row.dataField }
        if definition.columnFields.contains(pivotValuesFieldIndex) { d = column.dataField }
        guard d >= 0, d < dataFieldCount else { return nil }
        let dataField = definition.dataFields[d]
        if row.kind == .data && isBlankParent(definition.rowFields, row.tuple) { return nil }
        if column.kind == .data && isBlankParent(definition.columnFields, column.tuple) { return nil }
        let rowPath = row.kind == .grand ? [] : path(definition.rowFields, row.tuple)
        let columnPath = column.kind == .grand ? [] : path(definition.columnFields, column.tuple)
        var function = dataField.subtotal
        for kind in [row.kind, column.kind] { if let fn = Self.function(for: kind) { function = fn } }
        switch dataField.showDataAs {
        case .difference, .percent, .percentDiff, .runTotal:
            return baseFieldValue(dataField, function: function, row: row, column: column,
                                  rowPath: rowPath, columnPath: columnPath, table: table)
        default:
            break
        }
        guard let group = table.group(rowPath, columnPath) else {
            // Shown as a share or index, an empty intersection is 0 (checked in Excel).
            return dataField.showDataAs == .normal ? nil : .number(0)
        }
        guard let v = value(table, group, field: dataField.field, subtotal: function) else { return nil }
        guard dataField.showDataAs != .normal, case .number(let n) = v else { return v }
        func total(_ rowPath: [Int], _ columnPath: [Int]) -> Double? {
            guard let group = table.group(rowPath, columnPath),
                  case .number(let t)? = value(table, group, field: dataField.field, subtotal: function)
            else { return nil }
            return t
        }
        func ratio(_ t: Double?) -> CellValue {
            guard let t, t != 0 else { return .error(.div0) }
            return .number(n / t)
        }
        switch dataField.showDataAs {
        case .percentOfTotal: return ratio(total([], []))
        case .percentOfRow: return ratio(total(rowPath, []))
        case .percentOfCol: return ratio(total([], columnPath))
        case .index:
            guard let grand = total([], []), let rowTotal = total(rowPath, []), let colTotal = total([], columnPath),
                  rowTotal != 0, colTotal != 0 else { return .error(.div0) }
            return .number(n * grand / (rowTotal * colTotal))
        default:
            return .error(.na) // base field not on an axis (others are refused up front)
        }
    }

    /// Show-values-as relative to an item of a base field: difference from,
    /// % of, % difference from, and running total. Rules checked in Excel:
    /// the base item's own cells and totals along the base field are blank
    /// (% of shows 1 for the base item); a missing base counts as 0 for a
    /// difference and blanks a percentage; "previous"/"next" use neighbouring
    /// visible items; running totals sum down the base field within each
    /// parent and leave parents and the grand total blank.
    private func baseFieldValue(_ dataField: PivotDataField, function: PivotSubtotal, row: AxisEntry,
                                column: AxisEntry, rowPath: [Int], columnPath: [Int], table: ValueTable) -> CellValue? {
        let bf = dataField.baseField
        let entry: AxisEntry, level: Int, onRows: Bool
        if let l = definition.rowFields.firstIndex(of: bf) {
            entry = row; level = l; onRows = true
        } else if let l = definition.columnFields.firstIndex(of: bf) {
            entry = column; level = l; onRows = false
        } else {
            return .error(.na)
        }
        guard entry.kind == .data, entry.tuple.count > level else { return nil }
        let axisFields = onRows ? definition.rowFields : definition.columnFields
        // Where the base field sits in the path (Values levels aren't in it).
        let slot = axisFields[..<level].filter { $0 != pivotValuesFieldIndex }.count
        let items = definition.fields[bf].items
        let ordered = items.indices.filter { items[$0].kind == .data && !items[$0].hidden }
        let p = entry.tuple[level]
        func valueAt(_ q: Int) -> Double? {
            guard let x = items[q].index else { return nil }
            var rows = rowPath, columns = columnPath
            if onRows {
                guard slot < rows.count else { return nil }
                rows[slot] = x
            } else {
                guard slot < columns.count else { return nil }
                columns[slot] = x
            }
            guard let group = table.group(rows, columns),
                  case .number(let n)? = value(table, group, field: dataField.field, subtotal: function)
            else { return nil }
            return n
        }
        if dataField.showDataAs == .runTotal {
            guard let i = ordered.firstIndex(of: p) else { return nil }
            let values = ordered[...i].compactMap(valueAt)
            return values.isEmpty ? nil : .number(values.reduce(0, +))
        }
        let b: Int?
        switch dataField.baseItem {
        case 1048828: b = ordered.firstIndex(of: p).flatMap { $0 > 0 ? ordered[$0 - 1] : nil }
        case 1048829: b = ordered.firstIndex(of: p).flatMap { $0 + 1 < ordered.count ? ordered[$0 + 1] : nil }
        default: b = items.indices.contains(dataField.baseItem) ? dataField.baseItem : nil
        }
        guard let b else { return nil }
        if b == p { return dataField.showDataAs == .percent && valueAt(p) != nil ? .number(1) : nil }
        let v = valueAt(p), base = valueAt(b)
        switch dataField.showDataAs {
        case .difference:
            guard v != nil || base != nil else { return nil }
            return .number((v ?? 0) - (base ?? 0))
        case .percent:
            guard let base else { return nil }
            return base == 0 ? .error(.div0) : .number((v ?? 0) / base)
        default: // percentDiff
            guard let base else { return nil }
            return base == 0 ? .error(.div0) : .number(((v ?? 0) - base) / base)
        }
    }

    private func render(rows: [AxisEntry], rowLines: [PivotAxisLine], cols: [AxisEntry], columnLines: [PivotAxisLine],
                        table: ValueTable, geometry g: Geometry, into cells: inout [PivotOffset: PivotRenderedCell]) {
        let layout = definition.layout
        let rowFields = definition.rowFields, colFields = definition.columnFields
        let fhr = g.firstHeaderRow, fdr = g.firstDataRow, fdc = g.firstDataCol
        let lc = g.labelColumns
        let hr = fdr - 1
        func put(_ r: Int, _ c: Int, _ v: CellValue, format: NumberFormat? = nil, indent: Int = 0, button: Bool = false,
                 role: PivotCellRole = .header) {
            cells[PivotOffset(row: r, column: c)] = PivotRenderedCell(value: v, numberFormat: format, indent: indent,
                                                                      pivotButton: button, role: role)
        }
        let showHeaders = layout.showHeaders

        // Caption row.
        if g.captionRow && !colFields.isEmpty {
            if dataFieldCount == 1 && showHeaders && !rowFields.isEmpty {
                put(0, 0, .string(dataFieldName(0)), button: true)
            }
            if rowFields.isEmpty && fdc > 0 && dataFieldCount == 1 {
                put(fdr, 0, .string(dataFieldName(0)), role: .header)
            }
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
                    put(fhr, c, .string(grandCaption(onAxis: colFields, dataField: entry.dataField)), role: .grandTotalLabel)
                    continue
                }
                if entry.kind != .data {
                    let level = entry.tuple.count - 1
                    put(fhr + level, c, .string(subtotalCaption(colFields[level], entry.tuple[level], entry.kind)),
                        role: .subtotalLabel)
                    continue
                }
                for level in entry.tuple.indices {
                    let f = colFields[level]
                    let fill = f != pivotValuesFieldIndex && definition.fields[f].fillDownLabels
                    guard level >= line.repeated || fill else { continue }
                    let v: CellValue = f == pivotValuesFieldIndex ? .string(dataFieldName(entry.tuple[level]))
                        : label(f, entry.tuple[level])
                    put(fhr + level, c, v, format: labelFormat(f, v), role: .columnLabel)
                }
            }
        }

        // Row labels and values.
        let valuesOnColumns = colFields.contains(pivotValuesFieldIndex)
        let valuesOnRows = rowFields.contains(pivotValuesFieldIndex)
        for (ri, (entry, line)) in zip(rows, rowLines).enumerated() {
            let r = fdr + ri
            if entry.kind == .blank { continue }
            if !rowFields.isEmpty {
                if entry.kind == .grand {
                    put(r, 0, .string(grandCaption(onAxis: rowFields, dataField: entry.dataField)), role: .grandTotalLabel)
                } else if entry.kind != .data {
                    let level = entry.tuple.count - 1
                    put(r, lc[level], .string(subtotalCaption(rowFields[level], entry.tuple[level], entry.kind)),
                        role: .subtotalLabel)
                } else {
                    for level in entry.tuple.indices {
                        let f = rowFields[level]
                        let fill = f != pivotValuesFieldIndex && definition.fields[f].fillDownLabels && !fieldCompact(f)
                        guard level >= line.repeated || fill else { continue }
                        let v: CellValue = f == pivotValuesFieldIndex ? .string(dataFieldName(entry.tuple[level]))
                            : label(f, entry.tuple[level])
                        let depth = level - lc.firstIndex(of: lc[level])!
                        let indent = depth > 0 && fieldCompact(rowFields[level - 1]) ? depth * (layout.indent + 1) : 0
                        let parent = entry.tuple.count < rowFields.count
                        put(r, lc[level], v, format: labelFormat(f, v), indent: indent,
                            role: parent && level == entry.tuple.count - 1 ? .subtotalLabel : .rowLabel)
                    }
                }
            }
            for (ci, column) in cols.enumerated() {
                let d = valuesOnColumns ? column.dataField : (valuesOnRows ? entry.dataField : 0)
                let format = dataFieldCount > 0 ? definition.dataFields[d].numberFormat : nil
                if let v = cellValue(row: entry, column: column, table: table) {
                    let role: PivotCellRole
                    if entry.kind == .grand || column.kind == .grand {
                        role = .grandTotalValue
                    } else if entry.kind != .data || column.kind != .data || entry.tuple.count < rowFields.count {
                        role = .subtotalValue
                    } else {
                        role = .value
                    }
                    put(r, fdc + ci, v, format: format, role: role)
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
            cells[PivotOffset(row: r, column: c)] = PivotRenderedCell(value: .string(cache.fields[f].name), pivotButton: true,
                                                                      role: .filterLabel)
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
            cells[PivotOffset(row: r, column: c + 1)] = PivotRenderedCell(value: value, role: .filterValue)
        }
    }
}
