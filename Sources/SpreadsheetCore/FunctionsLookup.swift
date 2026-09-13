import Foundation

enum LookupFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = lookups + referencing

    private static let lookups: [BuiltinFunction] = [
        .eager("VLOOKUP", min: 3, max: 4) { args, _ in
            let key = try args[0].toScalar()
            if case .error(let e) = key { throw e }
            let grid = GridArg(args[1])
            let index = try intArg(args[2])
            guard index >= 1, index <= grid.columns else { throw CellError.value }
            let sorted = try optionalBool(args, 3, default: true)
            guard let row = try lookupPosition(
                key: key, count: grid.rows, sorted: sorted,
                valueAt: { grid.value(atRow: $0, column: 0) }
            ) else { throw CellError.na }
            return grid.value(atRow: row, column: index - 1)
        },
        .eager("HLOOKUP", min: 3, max: 4) { args, _ in
            let key = try args[0].toScalar()
            if case .error(let e) = key { throw e }
            let grid = GridArg(args[1])
            let index = try intArg(args[2])
            guard index >= 1, index <= grid.rows else { throw CellError.value }
            let sorted = try optionalBool(args, 3, default: true)
            guard let col = try lookupPosition(
                key: key, count: grid.columns, sorted: sorted,
                valueAt: { grid.value(atRow: 0, column: $0) }
            ) else { throw CellError.na }
            return grid.value(atRow: index - 1, column: col)
        },
        .eager("XLOOKUP", min: 3, max: 6) { args, _ in
            let key = try args[0].toScalar()
            if case .error(let e) = key { throw e }
            let lookup = GridArg(args[1])
            let result = GridArg(args[2])
            guard lookup.rows == 1 || lookup.columns == 1 else { throw CellError.value }
            let count = lookup.cellCount
            guard result.cellCount == count || result.rows == count || result.columns == count else {
                throw CellError.value
            }
            let matchMode = try optionalInt(args, 4, default: 0)
            let searchMode = try optionalInt(args, 5, default: 1)
            let values = lookup.allValues
            let position = try xlookupPosition(key: key, values: values,
                                               matchMode: matchMode, searchMode: searchMode)
            guard let pos = position else {
                if args.count > 3 {
                    let missing = try args[3].toScalar()
                    return missing
                }
                throw CellError.na
            }
            let resultValues = result.allValues
            guard pos < resultValues.count else { throw CellError.value }
            return resultValues[pos]
        },
        .eager("MATCH", min: 2, max: 3) { args, _ in
            let key = try args[0].toScalar()
            if case .error(let e) = key { throw e }
            let grid = GridArg(args[1])
            guard grid.rows == 1 || grid.columns == 1 else { throw CellError.na }
            let type = try optionalInt(args, 2, default: 1)
            let values = grid.allValues
            switch type {
            case 0:
                for (i, v) in values.enumerated() where exactMatch(key: key, value: v) {
                    return .number(Double(i + 1))
                }
                throw CellError.na
            case 1:
                // largest value <= key (ascending assumption)
                var best: Int?
                for (i, v) in values.enumerated() {
                    if sameTypeCompare(v, key) <= 0, !v.isEmpty { best = i }
                }
                guard let b = best else { throw CellError.na }
                return .number(Double(b + 1))
            case -1:
                // smallest value >= key (descending assumption)
                var best: Int?
                for (i, v) in values.enumerated() {
                    if sameTypeCompare(v, key) >= 0, !v.isEmpty { best = i }
                }
                guard let b = best else { throw CellError.na }
                return .number(Double(b + 1))
            default:
                throw CellError.value
            }
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
            let key = try args[0].toScalar()
            if case .error(let e) = key { throw e }
            let lookupGrid = GridArg(args[1])
            let values = lookupGrid.allValues
            var best: Int?
            for (i, v) in values.enumerated() {
                if sameTypeCompare(v, key) <= 0, !v.isEmpty { best = i }
            }
            guard let pos = best else { throw CellError.na }
            if args.count > 2 {
                let resultValues = GridArg(args[2]).allValues
                guard pos < resultValues.count else { throw CellError.value }
                return resultValues[pos]
            }
            return values[pos]
        },
    ]

    // MARK: Helpers

    /// VLOOKUP/HLOOKUP search. sorted=false: first exact (wildcard) match.
    /// sorted=true: last value <= key scanning top-to-bottom (Excel semantics
    /// on sorted data; silently wrong on unsorted — by design).
    private static func lookupPosition(
        key: CellValue, count: Int, sorted: Bool, valueAt: (Int) -> CellValue
    ) throws -> Int? {
        if sorted {
            var best: Int?
            for i in 0..<count {
                let v = valueAt(i)
                if v.isEmpty { continue }
                if sameTypeCompare(v, key) <= 0 { best = i }
            }
            return best
        } else {
            for i in 0..<count where exactMatch(key: key, value: valueAt(i)) {
                return i
            }
            return nil
        }
    }

    /// Exact-match comparison for lookups: same-type equality with
    /// case-insensitive + wildcard text matching.
    static func exactMatch(key: CellValue, value: CellValue) -> Bool {
        switch (key, value) {
        case (.string(let pattern), .string(let s)):
            return Criterion.wildcardMatch(pattern: pattern, text: s)
        case (.number(let a), .number(let b)):
            return a == b
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.empty, .empty):
            return true
        default:
            return false
        }
    }

    /// Comparison that only orders same-type values; different types compare
    /// as "greater" so they never match <=/>= scans against the key's type.
    static func sameTypeCompare(_ v: CellValue, _ key: CellValue) -> Int {
        switch (v, key) {
        case (.number(let a), .number(let b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        case (.string(let a), .string(let b)):
            let la = a.lowercased(), lb = b.lowercased()
            return la < lb ? -1 : (la > lb ? 1 : 0)
        case (.bool(let a), .bool(let b)):
            return a == b ? 0 : (a ? 1 : -1)
        default:
            return 2 // incomparable: excluded from <=/>= scans
        }
    }

    private static func xlookupPosition(
        key: CellValue, values: [CellValue], matchMode: Int, searchMode: Int
    ) throws -> Int? {
        let indices: [Int]
        switch searchMode {
        case 1, 2: indices = Array(0..<values.count)
        case -1, -2: indices = Array((0..<values.count).reversed())
        default: throw CellError.value
        }
        switch matchMode {
        case 0:
            for i in indices where lookupEqual(key: key, value: values[i]) { return i }
            return nil
        case 2:
            for i in indices where exactMatch(key: key, value: values[i]) { return i }
            return nil
        case 1:
            // exact or next greater
            var best: Int?
            for i in 0..<values.count {
                if lookupEqual(key: key, value: values[i]) { return i }
                if sameTypeCompare(values[i], key) == 1 {
                    if let b = best {
                        if sameTypeCompare(values[i], values[b]) < 0 { best = i }
                    } else {
                        best = i
                    }
                }
            }
            return best
        case -1:
            // exact or next smaller
            var best: Int?
            for i in 0..<values.count {
                if lookupEqual(key: key, value: values[i]) { return i }
                if sameTypeCompare(values[i], key) == -1 {
                    if let b = best {
                        if sameTypeCompare(values[i], values[b]) > 0 { best = i }
                    } else {
                        best = i
                    }
                }
            }
            return best
        default:
            throw CellError.value
        }
    }

    /// Equality without wildcards (XLOOKUP match mode 0).
    private static func lookupEqual(key: CellValue, value: CellValue) -> Bool {
        switch (key, value) {
        case (.string(let a), .string(let b)):
            return a.lowercased() == b.lowercased()
        case (.number(let a), .number(let b)):
            return a == b
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.empty, .empty):
            return true
        default:
            return false
        }
    }

    /// Extract the first reference expression from a raw argument (ROW/COLUMN).
    private static func firstReference(in expr: FormulaExpr) -> ReferenceExpr? {
        expr.references.first
    }
}
