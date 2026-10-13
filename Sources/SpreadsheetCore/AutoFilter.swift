import Foundation

/// A sheet's AutoFilter (XLSX `autoFilter`): a header row with a filter
/// button per column, over the data rows beneath it.
public struct AutoFilter: Hashable, Sendable {
    /// Header row plus data rows.
    public var range: CellRange
    /// Criteria keyed by column offset within `range` (XLSX `colId`).
    public var columns: [Int: ColumnFilter]

    public init(range: CellRange, columns: [Int: ColumnFilter] = [:]) {
        self.range = range
        self.columns = columns
    }

    public var headerRow: Int { range.start.row }

    /// The rows the filter shows or hides (everything under the header).
    public var dataRows: ClosedRange<Int>? {
        range.end.row > range.start.row ? (range.start.row + 1)...range.end.row : nil
    }

    public var isFiltering: Bool { columns.values.contains { $0.isActive } }
}

/// One column's criteria. Values and conditions combine with AND, as in
/// Excel, though Excel's own UI only ever sets one of them.
public struct ColumnFilter: Hashable, Sendable {
    /// Shown display texts (XLSX `filters/filter@val`); nil shows all.
    public var values: Set<String>?
    /// With `values`, whether empty cells show (XLSX `filters@blank`).
    public var includeBlanks: Bool
    /// Up to two comparisons (XLSX `customFilters`).
    public var conditions: [FilterCondition]
    /// Join the two conditions with AND (true) or OR.
    public var matchAll: Bool
    /// A criterion SimpleSpread cannot evaluate (top 10, dynamic, color),
    /// kept as XML and written back as it was. It hides nothing here.
    public var preservedXML: String?

    public init(values: Set<String>? = nil, includeBlanks: Bool = true,
                conditions: [FilterCondition] = [], matchAll: Bool = true,
                preservedXML: String? = nil) {
        self.values = values
        self.includeBlanks = includeBlanks
        self.conditions = conditions
        self.matchAll = matchAll
        self.preservedXML = preservedXML
    }

    public var isActive: Bool { values != nil || !conditions.isEmpty || preservedXML != nil }

    /// The key texts share when they are equal ignoring case, as
    /// `caseInsensitiveCompare` judges it ("Straße" matches "STRASSE").
    public static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Whether a cell passes, given its display text. To test many cells,
    /// use `matcher()`, which folds the value list once.
    public func passes(_ value: CellValue, displayText: String) -> Bool {
        matcher()(value, displayText)
    }

    /// `passes` with the value list prepared once: testing a cell against
    /// the shown values is then one hash lookup.
    public func matcher() -> (CellValue, String) -> Bool {
        let shown = values.map { Set($0.map(Self.folded)) }
        return { value, displayText in self.passes(value, displayText: displayText, shown: shown) }
    }

    private func passes(_ value: CellValue, displayText: String, shown: Set<String>?) -> Bool {
        if let shown {
            if value.isEmpty || displayText.isEmpty {
                if !includeBlanks { return false }
            } else if !shown.contains(Self.folded(displayText)) {
                return false
            }
        }
        if !conditions.isEmpty {
            let results = conditions.map { $0.matches(value, displayText: displayText) }
            if matchAll ? results.contains(false) : !results.contains(true) { return false }
        }
        return true
    }
}

/// A comparison against a cell (XLSX `customFilter`). Text tests use the
/// `*` and `?` wildcards (`~` escapes), as Excel stores "contains" and
/// "begins with" as wildcard equality.
public struct FilterCondition: Hashable, Sendable {
    public enum Operator: String, Hashable, Sendable, CaseIterable {
        case equal, notEqual, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
    }

    public var op: Operator
    public var value: String

    public init(_ op: Operator, _ value: String) {
        self.op = op
        self.value = value
    }

    public func matches(_ cell: CellValue, displayText: String) -> Bool {
        // Numbers compare numerically when the criterion is a number.
        if case .number(let n) = cell, let target = Double(value.trimmingCharacters(in: .whitespaces)) {
            switch op {
            case .equal: return n == target
            case .notEqual: return n != target
            case .greaterThan: return n > target
            case .greaterThanOrEqual: return n >= target
            case .lessThan: return n < target
            case .lessThanOrEqual: return n <= target
            }
        }
        switch op {
        case .equal:
            return Self.wildcardMatch(displayText, pattern: value)
        case .notEqual:
            return !Self.wildcardMatch(displayText, pattern: value)
        default:
            // Text ordering comparisons skip numbers and blanks, as in Excel.
            if case .number = cell { return false }
            if cell.isEmpty { return false }
            let order = displayText.compare(value, options: [.caseInsensitive])
            switch op {
            case .greaterThan: return order == .orderedDescending
            case .greaterThanOrEqual: return order != .orderedAscending
            case .lessThan: return order == .orderedAscending
            case .lessThanOrEqual: return order != .orderedDescending
            default: return false
            }
        }
    }

    /// Case-insensitive match with `*` (any run), `?` (one character) and
    /// `~` escaping the next character.
    public static func wildcardMatch(_ text: String, pattern: String) -> Bool {
        enum Token: Equatable { case literal(Character), any, one }
        var tokens: [Token] = []
        var escaped = false
        for c in pattern.lowercased() {
            if escaped { tokens.append(.literal(c)); escaped = false; continue }
            switch c {
            case "~": escaped = true
            case "*": tokens.append(.any)
            case "?": tokens.append(.one)
            default: tokens.append(.literal(c))
            }
        }
        if escaped { tokens.append(.literal("~")) }
        let chars = Array(text.lowercased())
        // Classic two-pointer glob match with backtracking to the last `*`.
        var t = 0, p = 0
        var starP = -1, starT = 0
        while t < chars.count {
            if p < tokens.count {
                switch tokens[p] {
                case .any:
                    starP = p; starT = t; p += 1
                    continue
                case .one:
                    t += 1; p += 1
                    continue
                case .literal(let c) where c == chars[t]:
                    t += 1; p += 1
                    continue
                default:
                    break
                }
            }
            guard starP >= 0 else { return false }
            p = starP + 1
            starT += 1
            t = starT
        }
        while p < tokens.count, tokens[p] == .any { p += 1 }
        return p == tokens.count
    }
}

// MARK: - Evaluation

extension Workbook {
    /// The text a cell shows, which value filters match against.
    public func displayText(of sheet: Sheet, at address: CellAddress) -> String {
        let cell = sheet.cell(at: address)
        return NumberFormatEngine.displayString(for: cell.value, format: style(at: cell.styleIndex).numberFormat)
    }

    /// Re-run a sheet's AutoFilter: extend it over rows added directly below
    /// it, then hide the data rows that fail and show the ones that pass.
    public func applyAutoFilter(onSheetID sheetID: Int) {
        guard let sheet = sheet(withID: sheetID), var filter = sheet.autoFilter else { return }
        filter.range.end.row = Self.extendedFilterEnd(filter.range, in: sheet)
        sheet.autoFilter = filter
        guard let rows = filter.dataRows else { return }
        let tests = columnTests(filter)
        for row in rows {
            if rowPasses(row, tests, sheet: sheet) {
                sheet.hiddenRows.remove(row)
            } else {
                sheet.hiddenRows.insert(row)
            }
        }
    }

    public func rowPassesFilter(_ row: Int, filter: AutoFilter, sheet: Sheet) -> Bool {
        rowPasses(row, columnTests(filter), sheet: sheet)
    }

    /// Each active column's test, prepared once per filter run.
    private func columnTests(_ filter: AutoFilter) -> [(column: Int, test: (CellValue, String) -> Bool)] {
        filter.columns.filter { $0.value.isActive }.map { offset, criteria in
            (filter.range.start.column + offset, criteria.matcher())
        }
    }

    private func rowPasses(_ row: Int, _ tests: [(column: Int, test: (CellValue, String) -> Bool)],
                           sheet: Sheet) -> Bool {
        for (column, test) in tests {
            let address = CellAddress(row: row, column: column)
            if !test(sheet.value(at: address), displayText(of: sheet, at: address)) { return false }
        }
        return true
    }

    /// Excel grows a filter over data typed directly beneath it: keep going
    /// down while the next row has something in the filter's columns.
    public static func extendedFilterEnd(_ range: CellRange, in sheet: Sheet) -> Int {
        var end = range.end.row
        let columns = range.start.column...range.end.column
        while end + 1 < CellAddress.maxRows,
              columns.contains(where: { !sheet.value(at: CellAddress(row: end + 1, column: $0)).isEmpty }) {
            end += 1
        }
        return end
    }

    /// Distinct display texts in one filter column's data rows, in sort
    /// order, with whether any cell is blank (for the filter's value list).
    public func filterValues(onSheetID sheetID: Int, columnOffset: Int) -> (values: [String], hasBlanks: Bool) {
        guard let sheet = sheet(withID: sheetID), let filter = sheet.autoFilter,
              let rows = filter.dataRows else { return ([], false) }
        let column = filter.range.start.column + columnOffset
        // Keyed by the case-folded text; the first spelling seen is listed.
        var seen: [String: (text: String, value: CellValue, row: Int)] = [:]
        var hasBlanks = false
        for row in rows {
            let address = CellAddress(row: row, column: column)
            let value = sheet.value(at: address)
            let text = displayText(of: sheet, at: address)
            if value.isEmpty || text.isEmpty {
                hasBlanks = true
            } else {
                let key = ColumnFilter.folded(text)
                if seen[key] == nil { seen[key] = (text, value, row) }
            }
        }
        // Values that compare equal keep the order they appear in.
        let ordered = seen.values.sorted { lhs, rhs in
            switch SortComparison.compare(lhs.value, rhs.value) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.row < rhs.row
            }
        }
        return (ordered.map(\.text), hasBlanks)
    }
}
