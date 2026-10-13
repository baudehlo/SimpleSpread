import Foundation

enum LookupFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = lookups + referencing

    private static let lookups: [BuiltinFunction] = [
        .eager("VLOOKUP", min: 3, max: 4) { args, _ in
            let key = try lookupKey(args[0])
            let grid = GridArg(args[1])
            let index = try intArg(args[2])
            guard index >= 1, index <= grid.columns else { throw CellError.value }
            let approximate = try optionalBool(args, 3, default: true)
            guard let row = lookupPosition(
                key: key, count: grid.rows, approximate: approximate,
                valueAt: { grid.value(atRow: $0, column: 0) }
            ) else { throw CellError.na }
            return grid.value(atRow: row, column: index - 1)
        },
        .eager("HLOOKUP", min: 3, max: 4) { args, _ in
            let key = try lookupKey(args[0])
            let grid = GridArg(args[1])
            let index = try intArg(args[2])
            guard index >= 1, index <= grid.rows else { throw CellError.value }
            let approximate = try optionalBool(args, 3, default: true)
            guard let col = lookupPosition(
                key: key, count: grid.columns, approximate: approximate,
                valueAt: { grid.value(atRow: 0, column: $0) }
            ) else { throw CellError.na }
            return grid.value(atRow: index - 1, column: col)
        },
        .eager("XLOOKUP", min: 3, max: 6) { args, _ in
            let key = try lookupKey(args[0])
            let lookup = GridArg(args[1])
            let result = GridArg(args[2])
            guard lookup.rows == 1 || lookup.columns == 1 else { throw CellError.value }
            // A column of keys returns the matching ROW of the return range, a
            // row of keys the matching COLUMN. Without spilling, the cell
            // shows the first value of that row/column, which is what Excel's
            // implicit intersection (and pre-dynamic-array Excel) shows.
            let vertical: Bool
            if lookup.columns == 1, lookup.rows == result.rows {
                vertical = true
            } else if lookup.rows == 1, lookup.columns == result.columns {
                vertical = false
            } else {
                throw CellError.value
            }
            let count = vertical ? lookup.rows : lookup.columns
            let matchMode = try optionalInt(args, 4, default: 0)
            let searchMode = try optionalInt(args, 5, default: 1)
            let position = try xlookupPosition(
                key: key, count: count, matchMode: matchMode, searchMode: searchMode,
                valueAt: { vertical ? lookup.value(atRow: $0, column: 0) : lookup.value(atRow: 0, column: $0) })
            guard let pos = position else {
                if args.count > 3 {
                    return try args[3].toScalar()
                }
                throw CellError.na
            }
            return vertical ? result.value(atRow: pos, column: 0) : result.value(atRow: 0, column: pos)
        },
        .eager("MATCH", min: 2, max: 3) { args, _ in
            let key = try lookupKey(args[0])
            let grid = GridArg(args[1])
            guard grid.rows == 1 || grid.columns == 1 else { throw CellError.na }
            let type = try optionalInt(args, 2, default: 1)
            let count = grid.cellCount
            let valueAt: (Int) -> CellValue = grid.columns == 1
                ? { grid.value(atRow: $0, column: 0) }
                : { grid.value(atRow: 0, column: $0) }
            let position: Int?
            switch type {
            case 0:
                position = (0..<count).first { lookupMatches(key, valueAt($0), wildcards: true) }
            case 1:
                position = binarySearch(key: key, count: count, descending: false, valueAt: valueAt)
            case -1:
                position = binarySearch(key: key, count: count, descending: true, valueAt: valueAt)
            default:
                throw CellError.value
            }
            guard let p = position else { throw CellError.na }
            return .number(Double(p + 1))
        },
        .eager("INDEX", min: 2, max: 3) { args, _ in
            let grid = GridArg(args[0])
            var row = try intArg(args[1])
            var col = try optionalInt(args, 2, default: grid.columns == 1 ? 1 : 0)
            // Single-row ranges allow INDEX(range, n) to mean column n.
            if args.count == 2 && grid.rows == 1 && grid.columns > 1 {
                col = row
                row = 1
            }
            guard row >= 1, row <= grid.rows, col >= 1, col <= grid.columns else {
                throw CellError.ref
            }
            return grid.value(atRow: row - 1, column: col - 1)
        },
        .lazy("CHOOSE", min: 2, max: nil) { args, ctx in
            let index = try Coerce.int(ctx.evaluateScalar(args[0]))
            guard index >= 1, index < args.count else { throw CellError.num }
            return try ctx.evaluateScalar(args[index])
        },
    ]

    private static let referencing: [BuiltinFunction] = [
        .eager("ADDRESS", min: 2, max: 5) { args, _ in
            let row = try intArg(args[0])
            let col = try intArg(args[1])
            let mode = try optionalInt(args, 2, default: 1)
            guard row >= 1, col >= 1, mode >= 1, mode <= 4 else { throw CellError.value }
            let colName = CellAddress.columnName(col - 1)
            let body: String
            switch mode {
            case 1: body = "$\(colName)$\(row)"
            case 2: body = "\(colName)$\(row)"
            case 3: body = "$\(colName)\(row)"
            default: body = "\(colName)\(row)"
            }
            if args.count > 4 {
                let sheet = try strArg(args[4])
                return .string(ReferenceExpr.quoteSheetNameIfNeeded(sheet) + "!" + body)
            }
            return .string(body)
        },
        .lazy("ROW", min: 0, max: 1) { args, ctx in
            if args.isEmpty {
                return .number(Double(ctx.eval.address.row + 1))
            }
            guard let ref = firstReference(in: args[0]) else { throw CellError.value }
            let row = ref.start.row ?? 0
            return .number(Double(row + 1))
        },
        .lazy("COLUMN", min: 0, max: 1) { args, ctx in
            if args.isEmpty {
                return .number(Double(ctx.eval.address.column + 1))
            }
            guard let ref = firstReference(in: args[0]) else { throw CellError.value }
            let col = ref.start.column ?? 0
            return .number(Double(col + 1))
        },
        .eager("ROWS", min: 1, max: 1) { args, _ in
            .number(Double(GridArg(args[0]).rows))
        },
        .eager("COLUMNS", min: 1, max: 1) { args, _ in
            .number(Double(GridArg(args[0]).columns))
        },
        .eager("LOOKUP", min: 2, max: 3) { args, _ in
            let key = try lookupKey(args[0])
            let grid = GridArg(args[1])
            // Wider than tall: search the first row; otherwise the first
            // column. The array form returns from the last row/column.
            let alongRow = grid.columns > grid.rows
            let count = alongRow ? grid.columns : grid.rows
            guard let pos = binarySearch(
                key: key, count: count, descending: false,
                valueAt: { alongRow ? grid.value(atRow: 0, column: $0) : grid.value(atRow: $0, column: 0) }
            ) else { throw CellError.na }
            if args.count > 2 {
                let resultValues = GridArg(args[2]).allValues
                guard pos < resultValues.count else { throw CellError.value }
                return resultValues[pos]
            }
            return alongRow ? grid.value(atRow: grid.rows - 1, column: pos)
                            : grid.value(atRow: pos, column: grid.columns - 1)
        },
    ]

    // MARK: Helpers

    /// The lookup value; an error in it is the result.
    private static func lookupKey(_ arg: EvalValue) throws -> CellValue {
        let key = try arg.toScalar()
        if case .error(let e) = key { throw e }
        return key
    }

    /// VLOOKUP/HLOOKUP search: approximate = Excel's binary search (see
    /// `binarySearch`); exact = first match, wildcards active.
    private static func lookupPosition(
        key: CellValue, count: Int, approximate: Bool, valueAt: (Int) -> CellValue
    ) -> Int? {
        if approximate {
            return binarySearch(key: key, count: count, descending: false, valueAt: valueAt)
        }
        return (0..<count).first { lookupMatches(key, valueAt($0), wildcards: true) }
    }

    /// Lookup equality, the one rule every lookup function uses: same type
    /// only, text case-insensitive (with `* ? ~` wildcards when asked), and a
    /// blank lookup value matches nothing, not even a blank cell — Excel
    /// returns #N/A for it rather than the row of the first empty key.
    static func lookupMatches(_ key: CellValue, _ value: CellValue, wildcards: Bool) -> Bool {
        switch (key, value) {
        case (.string(let k), .string(let v)):
            return wildcards ? Criterion.wildcardMatch(pattern: k, text: v) : k.lowercased() == v.lowercased()
        case (.number(let a), .number(let b)):
            return a == b
        case (.bool(let a), .bool(let b)):
            return a == b
        default:
            return false
        }
    }

    /// Order of `value` against `key` (-1, 0, 1) when they are the same type;
    /// nil for blanks and values of another type, which approximate lookups
    /// skip.
    static func lookupOrder(_ value: CellValue, _ key: CellValue) -> Int? {
        switch (value, key) {
        case (.number(let a), .number(let b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        case (.string(let a), .string(let b)):
            let la = a.lowercased(), lb = b.lowercased()
            return la < lb ? -1 : (la > lb ? 1 : 0)
        case (.bool(let a), .bool(let b)):
            return a == b ? 0 : (a ? 1 : -1)
        default:
            return nil
        }
    }

    /// Excel's approximate match (VLOOKUP/HLOOKUP TRUE, MATCH 1/-1, LOOKUP):
    /// a binary search for the last position whose value is <= key
    /// (>= key when `descending`). On sorted data that is the familiar
    /// "largest value <= key"; on unsorted data it gives the binary-search
    /// answer Excel gives rather than a linear scan's. Blank cells and cells
    /// of another type than the key are skipped: from the midpoint the search
    /// probes forward to the next comparable cell, so `LOOKUP(9.99E+307,A:A)`
    /// finds the last number in a mixed column.
    static func binarySearch(key: CellValue, count: Int, descending: Bool,
                             valueAt: (Int) -> CellValue) -> Int? {
        if key.isEmpty { return nil }
        var lo = 0, hi = count - 1
        var best: Int?
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            var probe = mid
            var order: Int?
            while probe <= hi {
                order = lookupOrder(valueAt(probe), key)
                if order != nil { break }
                probe += 1
            }
            guard let o = order else {
                hi = mid - 1
                continue
            }
            if descending ? o >= 0 : o <= 0 {
                best = probe
                lo = probe + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// XLOOKUP: match mode 0 exact, 2 wildcard, 1 exact-or-next-larger,
    /// -1 exact-or-next-smaller; search mode 1/2 first-to-last, -1/-2
    /// last-to-first (the binary modes ±2 scan linearly, which gives the same
    /// answer on the sorted data they require).
    private static func xlookupPosition(
        key: CellValue, count: Int, matchMode: Int, searchMode: Int, valueAt: (Int) -> CellValue
    ) throws -> Int? {
        let indices: [Int]
        switch searchMode {
        case 1, 2: indices = Array(0..<count)
        case -1, -2: indices = Array((0..<count).reversed())
        default: throw CellError.value
        }
        switch matchMode {
        case 0, 2:
            return indices.first { lookupMatches(key, valueAt($0), wildcards: matchMode == 2) }
        case 1, -1:
            // Exact, else the nearest value on the requested side.
            var best: Int?
            var bestValue: CellValue = .empty
            for i in indices {
                let v = valueAt(i)
                if lookupMatches(key, v, wildcards: false) { return i }
                guard lookupOrder(v, key) == matchMode else { continue }
                if best == nil || lookupOrder(v, bestValue) == -matchMode {
                    best = i
                    bestValue = v
                }
            }
            return best
        default:
            throw CellError.value
        }
    }

    /// Extract the first reference expression from a raw argument (ROW/COLUMN).
    private static func firstReference(in expr: FormulaExpr) -> ReferenceExpr? {
        expr.references.first
    }
}
