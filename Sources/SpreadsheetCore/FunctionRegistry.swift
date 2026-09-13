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
    public static let volatileFunctions: Set<String> = ["NOW", "TODAY", "RAND", "RANDBETWEEN"]

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

/// Evaluate a multi-criteria (range, criterion) pairing: returns the set of
/// row-major indices (over the first range's shape) matching ALL pairs.
/// All ranges must share dimensions or #VALUE! is thrown.
func matchingIndices(criteriaPairs: [(GridArg, Criterion)]) throws -> [Int] {
    guard let first = criteriaPairs.first else { return [] }
    let rows = first.0.rows, cols = first.0.columns
    for (grid, _) in criteriaPairs {
        guard grid.rows == rows, grid.columns == cols else { throw CellError.value }
    }
    var out: [Int] = []
    for idx in 0..<(rows * cols) {
        let r = idx / cols, c = idx % cols
        var all = true
        for (grid, criterion) in criteriaPairs {
            let v = grid.value(atRow: r, column: c)
            if case .error(let e) = v { throw e }
            if !criterion.matches(v) { all = false; break }
        }
        if all { out.append(idx) }
    }
    return out
}
