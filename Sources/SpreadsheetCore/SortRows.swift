import Foundation

/// One sort level: an absolute column and a direction.
public struct SortKey: Hashable, Sendable {
    public var column: Int
    public var ascending: Bool

    public init(column: Int, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// Excel's sort order. Ascending: numbers, then text (case-insensitive),
/// then FALSE, TRUE, then errors. Blank cells always go last, whichever
/// the direction.
public enum SortComparison {
    private static func rank(_ value: CellValue) -> Int {
        switch value {
        case .number: return 0
        case .string: return 1
        case .bool: return 2
        case .error: return 3
        case .empty: return 4
        }
    }

    /// Ascending comparison of two non-blank values.
    public static func compare(_ a: CellValue, _ b: CellValue) -> ComparisonResult {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb ? .orderedAscending : .orderedDescending }
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.string(let x), .string(let y)):
            return x.compare(y, options: [.caseInsensitive], locale: Locale(identifier: "en_US"))
        case (.bool(let x), .bool(let y)):
            return x == y ? .orderedSame : (x ? .orderedDescending : .orderedAscending)
        case (.error(let x), .error(let y)):
            return x.rawValue.compare(y.rawValue)
        default:
            return .orderedSame
        }
    }

    /// Compare two rows' keys; blanks sort last in either direction.
    static func compareRows(_ a: [CellValue], _ b: [CellValue], keys: [SortKey]) -> ComparisonResult {
        for (i, key) in keys.enumerated() {
            let x = a[i], y = b[i]
            switch (x.isEmpty, y.isEmpty) {
            case (true, true): continue
            case (true, false): return .orderedDescending
            case (false, true): return .orderedAscending
            case (false, false): break
            }
            var result = compare(x, y)
            if !key.ascending {
                if result == .orderedAscending { result = .orderedDescending }
                else if result == .orderedDescending { result = .orderedAscending }
            }
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}

extension WorkbookOperations {
    /// The new order of `rows` sorted by `keys` (stable): element i is the
    /// original row that moves to the i-th position.
    public static func sortedRowOrder(of rows: ClosedRange<Int>, in sheet: Sheet, keys: [SortKey]) -> [Int] {
        let keyed = rows.map { row in
            (row, keys.map { sheet.value(at: CellAddress(row: row, column: $0.column)) })
        }
        // Swift's sort is not stable; index-tiebreak keeps equal rows in order.
        return keyed.enumerated().sorted { lhs, rhs in
            switch SortComparison.compareRows(lhs.element.1, rhs.element.1, keys: keys) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.offset < rhs.offset
            }
        }.map(\.element.0)
    }

    /// The cells of `range` after sorting its rows by `keys`: whole rows move
    /// (values, formulas and formatting), and formulas are translated by
    /// the distance their row moved, as Excel does. Returns only cells that
    /// change, as (address, new cell).
    public static func sortedCells(of range: CellRange, in sheet: Sheet, keys: [SortKey]) -> [(CellAddress, Cell)] {
        let order = sortedRowOrder(of: range.start.row...range.end.row, in: sheet, keys: keys)
        var result: [(CellAddress, Cell)] = []
        for (i, source) in order.enumerated() {
            let target = range.start.row + i
            guard source != target else { continue }
            for column in range.start.column...range.end.column {
                var cell = sheet.cell(at: CellAddress(row: source, column: column))
                if let formula = cell.formula {
                    cell.formula = translatedFormula(formula, byRows: target - source, columns: 0)
                }
                result.append((CellAddress(row: target, column: column), cell))
            }
        }
        return result
    }

    /// Excel's header guess for a sort with no explicit choice: the first
    /// row is a header when all its cells are text and some column below
    /// holds something other than text (or the first row is bold and the
    /// next is not).
    public static func guessHasHeader(_ range: CellRange, in sheet: Sheet, workbook: Workbook) -> Bool {
        guard range.rowCount > 1 else { return false }
        let columns = range.start.column...range.end.column
        let first = range.start.row
        let firstValues = columns.map { sheet.value(at: CellAddress(row: first, column: $0)) }
        guard firstValues.contains(where: { !$0.isEmpty }),
              firstValues.allSatisfy({ if case .string = $0 { return true }; return $0.isEmpty })
        else { return false }
        for column in columns {
            let below = sheet.value(at: CellAddress(row: first + 1, column: column))
            switch below {
            case .number, .bool, .error: return true
            default: break
            }
        }
        let boldHeader = columns.allSatisfy { column in
            let addr = CellAddress(row: first, column: column)
            return sheet.value(at: addr).isEmpty || workbook.style(at: sheet.styleIndex(at: addr)).bold
        }
        let boldBelow = columns.contains { column in
            workbook.style(at: sheet.styleIndex(at: CellAddress(row: first + 1, column: column))).bold
        }
        return boldHeader && !boldBelow
    }
}
