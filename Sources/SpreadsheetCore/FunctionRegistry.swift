import Foundation

/// Context handed to function implementations.
public struct FunctionContext {
    public let eval: EvalContext

    init(eval: EvalContext) {
        self.eval = eval
    }

    /// Evaluate a raw argument expression (for lazy functions).
    public func evaluate(_ expr: FormulaExpr) throws -> EvalValue {
        try FormulaEvaluator.evalValue(expr, context: eval)
    }

    public func evaluateScalar(_ expr: FormulaExpr) throws -> CellValue {
        try evaluate(expr).toScalar()
    }
}

/// A built-in spreadsheet function.
public struct BuiltinFunction: Sendable {
    public let name: String
    public let minArgs: Int
    public let maxArgs: Int?
    let isLazy: Bool
    let evalEager: (@Sendable ([EvalValue], FunctionContext) throws -> CellValue)?
    let evalLazy: (@Sendable ([FormulaExpr], FunctionContext) throws -> CellValue)?

    /// Eagerly-evaluated function: receives evaluated argument values.
    static func eager(
        _ name: String, min: Int, max: Int?,
        _ body: @escaping @Sendable ([EvalValue], FunctionContext) throws -> CellValue
    ) -> BuiltinFunction {
        BuiltinFunction(name: name, minArgs: min, maxArgs: max, isLazy: false,
                        evalEager: body, evalLazy: nil)
    }

    /// Lazily-evaluated function: receives raw argument expressions
    /// (IF-family: untaken branches must not be evaluated).
    static func lazy(
        _ name: String, min: Int, max: Int?,
        _ body: @escaping @Sendable ([FormulaExpr], FunctionContext) throws -> CellValue
    ) -> BuiltinFunction {
        BuiltinFunction(name: name, minArgs: min, maxArgs: max, isLazy: true,
                        evalEager: nil, evalLazy: body)
    }
}

public enum FunctionRegistry {
    /// Functions whose value can change without any input changing.
    /// GETPIVOTDATA reads cells its arguments don't name (inside the pivot,
    /// rewritten on refresh), so it recalculates with every change too.
    public static let volatileFunctions: Set<String> = ["NOW", "TODAY", "RAND", "RANDBETWEEN", "GETPIVOTDATA"]

    /// Functions whose value depends on where a cell or reference is, not
    /// only on what it holds: they recalculate when a row or column insert
    /// or delete moves them or their references (CalculationEngine.apply).
    /// INDIRECT, OFFSET and CELL belong here once they exist.
    public static let positionFunctions: Set<String> = ["ROW", "COLUMN"]

    public static func function(named name: String) -> BuiltinFunction? {
        all[name.uppercased()]
    }

    public static var functionNames: [String] { Array(all.keys).sorted() }

    static let all: [String: BuiltinFunction] = {
        var map: [String: BuiltinFunction] = [:]
        let groups: [[BuiltinFunction]] = [
            MathFunctions.all,
            StatisticalFunctions.all,
            LogicalFunctions.all,
            TextFunctions.all,
            DateTimeFunctions.all,
            LookupFunctions.all,
            InfoFunctions.all,
            FinancialFunctions.all,
            PivotFunctions.all,
        ]
        for group in groups {
            for fn in group {
                map[fn.name] = fn
            }
        }
        return map
    }()
}

// MARK: - Shared argument helpers

func numArg(_ v: EvalValue) throws -> Double {
    try Coerce.number(v.toScalar())
}

func intArg(_ v: EvalValue) throws -> Int {
    try Coerce.int(v.toScalar())
}

func strArg(_ v: EvalValue) throws -> String {
    try Coerce.string(v.toScalar())
}

func boolArg(_ v: EvalValue) throws -> Bool {
    try Coerce.boolean(v.toScalar())
}

func optionalNum(_ args: [EvalValue], _ i: Int, default def: Double) throws -> Double {
    i < args.count ? try numArg(args[i]) : def
}

func optionalInt(_ args: [EvalValue], _ i: Int, default def: Int) throws -> Int {
    i < args.count ? try intArg(args[i]) : def
}

func optionalBool(_ args: [EvalValue], _ i: Int, default def: Bool) throws -> Bool {
    i < args.count ? try boolArg(args[i]) : def
}

/// Uniform 2-D view over an argument: a range keeps its shape; a scalar is 1x1.
struct GridArg {
    let rows: Int
    let columns: Int
    private let resolved: ResolvedRange?
    private let scalar: CellValue?

    init(_ v: EvalValue) {
        switch v {
        case .range(let r):
            resolved = r
            scalar = nil
            rows = max(r.rowCount, r.isEmpty ? 0 : 1)
            columns = max(r.columnCount, r.isEmpty ? 0 : 1)
        case .scalar(let s):
            resolved = nil
            scalar = s
            rows = 1
            columns = 1
        }
    }

    var cellCount: Int { rows * columns }

    func value(atRow row: Int, column: Int) -> CellValue {
        if let r = resolved { return r.value(atRow: row, column: column) }
        return scalar ?? .empty
    }

    func forEach(_ body: (CellValue) throws -> Void) rethrows {
        for r in 0..<rows {
            for c in 0..<columns {
                try body(value(atRow: r, column: c))
            }
        }
    }

    /// Row-major flattened values.
    var allValues: [CellValue] {
        var out: [CellValue] = []
        out.reserveCapacity(cellCount)
        forEach { out.append($0) }
        return out
    }
}

// MARK: - Criteria engine
//
// The one implementation behind SUMIF, SUMIFS, COUNTIF, COUNTIFS, AVERAGEIF,
// AVERAGEIFS, MAXIFS and MINIFS (Excel semantics):
// - every cell of a criteria range is tested against its criterion; an error
//   cell is a value like any other (it matches "#N/A" or "<>5", not ">0") and
//   is never thrown;
// - an error in a cell that is aggregated (sum/average/max range) propagates;
// - *IFS ranges must all have the criteria range's shape, else #VALUE!.

/// (range, criterion) pairs from alternating arguments starting at `start`.
func criteriaPairs(_ args: [EvalValue], from start: Int) throws -> [(GridArg, Criterion)] {
    guard (args.count - start) % 2 == 0, args.count > start else { throw CellError.na }
    var pairs: [(GridArg, Criterion)] = []
    var i = start
    while i + 1 < args.count {
        pairs.append((GridArg(args[i]), Criterion.parse(try args[i + 1].toScalar())))
        i += 2
    }
    return pairs
}

/// The cells, in row-major order over the first range's shape, where ALL
/// criteria hold. Ranges of different shapes are #VALUE!.
func matchingCells(_ pairs: [(GridArg, Criterion)]) throws -> [(row: Int, column: Int)] {
    guard let first = pairs.first else { return [] }
    let rows = first.0.rows, cols = first.0.columns
    for (grid, _) in pairs {
        guard grid.rows == rows, grid.columns == cols else { throw CellError.value }
    }
    var out: [(row: Int, column: Int)] = []
    for r in 0..<rows {
        for c in 0..<cols where pairs.allSatisfy({ $0.1.matches($0.0.value(atRow: r, column: c)) }) {
            out.append((r, c))
        }
    }
    return out
}

/// The numbers at `cells` of `values` (text, booleans and blanks skipped; an
/// error in a matched cell propagates). `values` is read by offset, so a
/// SUMIF sum range of another size lines up from its top-left cell.
func criteriaNumbers(_ values: GridArg, at cells: [(row: Int, column: Int)]) throws -> [Double] {
    var out: [Double] = []
    for (r, c) in cells {
        switch values.value(atRow: r, column: c) {
        case .number(let n): out.append(n)
        case .error(let e): throw e
        default: break
        }
    }
    return out
}
