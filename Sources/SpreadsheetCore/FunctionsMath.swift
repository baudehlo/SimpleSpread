import Foundation

enum MathFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = basics + rounding + integers + conditional

    private static let basics: [BuiltinFunction] = [
        .eager("SUM", min: 1, max: nil) { args, _ in
            .number(try Coerce.collectNumbers(args).reduce(0, +))
        },
        .eager("PRODUCT", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args)
            return .number(nums.isEmpty ? 0 : nums.reduce(1, *))
        },
        .eager("ABS", min: 1, max: 1) { args, _ in .number(abs(try numArg(args[0]))) },
        .eager("SIGN", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            return .number(n > 0 ? 1 : (n < 0 ? -1 : 0))
        },
        .eager("SQRT", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            guard n >= 0 else { throw CellError.num }
            return .number(n.squareRoot())
        },
        .eager("SQRTPI", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            guard n >= 0 else { throw CellError.num }
            return .number((n * Double.pi).squareRoot())
        },
        .eager("EXP", min: 1, max: 1) { args, _ in
            let r = exp(try numArg(args[0]))
            guard r.isFinite else { throw CellError.num }
            return .number(r)
        },
        .eager("LN", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            guard n > 0 else { throw CellError.num }
            return .number(log(n))
        },
        .eager("LOG", min: 1, max: 2) { args, _ in
            let n = try numArg(args[0])
            let base = try optionalNum(args, 1, default: 10)
            guard n > 0, base > 0, base != 1 else { throw CellError.num }
            return .number(log(n) / log(base))
        },
        .eager("LOG10", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            guard n > 0 else { throw CellError.num }
            return .number(log10(n))
        },
    ]

    private static let rounding: [BuiltinFunction] = [
        .eager("PI", min: 0, max: 0) { _, _ in .number(Double.pi) },
        .eager("INT", min: 1, max: 1) { args, _ in
            .number((try numArg(args[0])).rounded(.down))
        },
        // ROUND and friends work on the 15-significant-digit decimal value,
        // like Excel: ROUND(1.005,2) = 1.01 although 1.005 is stored as
        // 1.00499999999999989...
        .eager("TRUNC", min: 1, max: 2) { args, _ in
            .number(try decimalRound(args, .towardZero))
        },
        .eager("ROUND", min: 1, max: 2) { args, _ in
            .number(try decimalRound(args, .halfAwayFromZero))
        },
        .eager("ROUNDUP", min: 1, max: 2) { args, _ in
            .number(try decimalRound(args, .awayFromZero))
        },
        .eager("ROUNDDOWN", min: 1, max: 2) { args, _ in
            .number(try decimalRound(args, .towardZero))
        },
        .eager("MROUND", min: 2, max: 2) { args, _ in
            let n = try numArg(args[0])
            let factor = try numArg(args[1])
            if factor == 0 { return .number(0) }
            guard (n >= 0) == (factor >= 0) || n == 0 else { throw CellError.num }
            let multiples = roundedToFifteenDigits(n / factor).rounded(.toNearestOrAwayFromZero)
            return .number(multiples * factor)
        },
        .eager("CEILING", min: 1, max: 2) { args, _ in
            let n = try numArg(args[0])
            let factor = try optionalNum(args, 1, default: 1)
            if factor == 0 { return .number(0) }
            guard !(n > 0 && factor < 0) else { throw CellError.num }
            return .number(fuzzyCeil(n / factor) * factor)
        },
        .eager("FLOOR", min: 1, max: 2) { args, _ in
            let n = try numArg(args[0])
            let factor = try optionalNum(args, 1, default: 1)
            if factor == 0 { return .number(0) }
            guard !(n > 0 && factor < 0) else { throw CellError.num }
            return .number(fuzzyFloor(n / factor) * factor)
        },
        .eager("MOD", min: 2, max: 2) { args, _ in
            let a = try numArg(args[0])
            let b = try numArg(args[1])
            guard b != 0 else { throw CellError.div0 }
            return .number(a - b * (a / b).rounded(.down))
        },
        .eager("QUOTIENT", min: 2, max: 2) { args, _ in
            let a = try numArg(args[0])
            let b = try numArg(args[1])
            guard b != 0 else { throw CellError.div0 }
            return .number((a / b).rounded(.towardZero))
        },
    ]

    private static let integers: [BuiltinFunction] = [
        .eager("POWER", min: 2, max: 2) { args, _ in
            let a = try numArg(args[0])
            let b = try numArg(args[1])
            if a == 0 && b == 0 { throw CellError.num }
            let r = pow(a, b)
            guard r.isFinite else { throw CellError.num }
            return .number(r)
        },
        .eager("EVEN", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            let magnitude = fuzzyCeil(abs(n) / 2) * 2
            return .number(n < 0 ? -magnitude : magnitude)
        },
        .eager("ODD", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            let magnitude = fuzzyCeil((abs(n) - 1) / 2) * 2 + 1
            return .number(n < 0 ? -magnitude : magnitude)
        },
        .eager("FACT", min: 1, max: 1) { args, _ in
            let n = try intArg(args[0])
            guard n >= 0, n <= 170 else { throw CellError.num }
            var result = 1.0
            if n > 1 {
                for i in 2...n { result *= Double(i) }
            }
            return .number(result)
        },
        .eager("COMBIN", min: 2, max: 2) { args, _ in
            let n = try intArg(args[0])
            let k = try intArg(args[1])
            guard n >= 0, k >= 0, k <= n else { throw CellError.num }
            // C(n, k) >= 2^min(k, n-k), so the product overflows (and the
            // loop stops) within about 1,030 steps, however large n is.
            var result = 1.0
            for i in 0..<min(k, n - k) {
                result = result * Double(n - i) / Double(i + 1)
                guard result.isFinite else { throw CellError.num }
            }
            return .number(result.rounded())
        },
        .eager("GCD", min: 1, max: nil) { args, _ in
            let ints = try gcdArguments(args)
            return .number(Double(ints.reduce(0) { gcd($0, $1) }))
        },
        .eager("LCM", min: 1, max: nil) { args, _ in
            let ints = try gcdArguments(args)
            if ints.contains(0) { return .number(0) }
            var result = 1
            for value in ints {
                let (product, overflow) = (result / gcd(result, value)).multipliedReportingOverflow(by: value)
                // Excel: a result of 2^53 or more is #NUM!.
                guard !overflow, product < excelIntegerLimit else { throw CellError.num }
                result = product
            }
            return .number(Double(result))
        },
        .eager("RAND", min: 0, max: 0) { _, ctx in
            .number(ctx.eval.clock.random())
        },
        .eager("RANDBETWEEN", min: 2, max: 2) { args, ctx in
            let low = try intArg(args[0])
            let high = try intArg(args[1])
            guard low <= high else { throw CellError.num }
            let span = Double(high - low + 1)
            let r = ctx.eval.clock.random()
            return .number(Double(low) + (span * r).rounded(.down))
        },
    ]

    private static let conditional: [BuiltinFunction] = [
        .eager("SUMIF", min: 2, max: 3) { args, _ in
            let cells = try matchingCells(criteriaPairs(Array(args.prefix(2)), from: 0))
            let sumGrid = GridArg(args.count > 2 ? args[2] : args[0])
            return .number(try criteriaNumbers(sumGrid, at: cells).reduce(0, +))
        },
        .eager("SUMIFS", min: 3, max: nil) { args, _ in
            let sumGrid = GridArg(args[0])
            let pairs = try criteriaPairs(args, from: 1)
            guard pairs.allSatisfy({ $0.0.rows == sumGrid.rows && $0.0.columns == sumGrid.columns }) else {
                throw CellError.value
            }
            return .number(try criteriaNumbers(sumGrid, at: matchingCells(pairs)).reduce(0, +))
        },
        .eager("SUMPRODUCT", min: 1, max: nil) { args, _ in
            let grids = args.map(GridArg.init)
            guard let first = grids.first else { return .number(0) }
            for g in grids {
                guard g.rows == first.rows, g.columns == first.columns else { throw CellError.value }
            }
            var total = 0.0
            for r in 0..<first.rows {
                for c in 0..<first.columns {
                    var product = 1.0
                    for g in grids {
                        let v = g.value(atRow: r, column: c)
                        switch v {
                        case .number(let n): product *= n
                        case .bool(let b): product *= b ? 1 : 0
                        case .error(let e): throw e
                        default: product = 0
                        }
                    }
                    total += product
                }
            }
            return .number(total)
        },
        .eager("SUMSQ", min: 1, max: nil) { args, _ in
            .number(try Coerce.collectNumbers(args).reduce(0) { $0 + $1 * $1 })
        },
    ]
}

/// ceil that forgives float fuzz below Excel's 15 significant digits
/// (1.9999999999999998 -> 2) but not a real difference
/// (1.0000000001 -> 2): the tolerance is relative, not absolute.
func fuzzyCeil(_ x: Double) -> Double {
    roundedToFifteenDigits(x).rounded(.up)
}

func fuzzyFloor(_ x: Double) -> Double {
    roundedToFifteenDigits(x).rounded(.down)
}

/// Excel rejects GCD/LCM arguments (and LCM results) of 2^53 or more.
private let excelIntegerLimit = 9007199254740992

/// GCD/LCM arguments: truncated, non-negative and below 2^53.
private func gcdArguments(_ args: [EvalValue]) throws -> [Int] {
    try Coerce.collectNumbers(args).map { n in
        guard n >= 0, let i = checkedInt(n, limit: Double(excelIntegerLimit)) else { throw CellError.num }
        return i
    }
}

/// ROUND/ROUNDUP/ROUNDDOWN/TRUNC(x, [places]) on the decimal value.
private func decimalRound(_ args: [EvalValue], _ rule: DecimalDigits.Rounding) throws -> Double {
    let n = try numArg(args[0])
    let places = try optionalInt(args, 1, default: 0)
    guard let result = excelRound(n, places: places, rule) else { throw CellError.num }
    return result
}

private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = abs(a), b = abs(b)
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

private func lcm(_ a: Int, _ b: Int) -> Int {
    if a == 0 || b == 0 { return 0 }
    return abs(a / gcd(a, b) * b)
}
