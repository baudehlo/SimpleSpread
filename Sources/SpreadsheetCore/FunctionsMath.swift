import Foundation

enum MathFunctions {
    static let all: [BuiltinFunction] = [
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
        .eager("PI", min: 0, max: 0) { _, _ in .number(Double.pi) },
        .eager("INT", min: 1, max: 1) { args, _ in
            .number((try numArg(args[0])).rounded(.down))
        },
        .eager("TRUNC", min: 1, max: 2) { args, _ in
            let n = try numArg(args[0])
            let places = try optionalInt(args, 1, default: 0)
            let f = pow(10.0, Double(places))
            return .number((n * f).rounded(.towardZero) / f)
        },
        .eager("ROUND", min: 1, max: 2) { args, _ in
            let n = try numArg(args[0])
            let places = try optionalInt(args, 1, default: 0)
            let f = pow(10.0, Double(places))
            return .number((n * f).rounded(.toNearestOrAwayFromZero) / f)
        },
        .eager("ROUNDUP", min: 1, max: 2) { args, _ in
            let n = try numArg(args[0])
            let places = try optionalInt(args, 1, default: 0)
            let f = pow(10.0, Double(places))
            let scaled = n * f
            // Round away from zero, tolerating float fuzz on exact values.
            let result = scaled >= 0 ? fuzzyCeil(scaled) : -fuzzyCeil(-scaled)
            return .number(result / f)
        },
        .eager("ROUNDDOWN", min: 1, max: 2) { args, _ in
            let n = try numArg(args[0])
            let places = try optionalInt(args, 1, default: 0)
            let f = pow(10.0, Double(places))
            let scaled = n * f
            let result = scaled >= 0 ? fuzzyFloor(scaled) : -fuzzyFloor(-scaled)
            return .number(result / f)
        },
        .eager("MROUND", min: 2, max: 2) { args, _ in
            let n = try numArg(args[0])
            let factor = try numArg(args[1])
            if factor == 0 { return .number(0) }
            guard (n >= 0) == (factor >= 0) || n == 0 else { throw CellError.num }
            return .number((n / factor).rounded(.toNearestOrAwayFromZero) * factor)
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
            var result = 1.0
            for i in 0..<min(k, n - k) {
                result = result * Double(n - i) / Double(i + 1)
            }
            return .number(result.rounded())
        },
        .eager("GCD", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args).map { $0.rounded(.down) }
            guard nums.allSatisfy({ $0 >= 0 }) else { throw CellError.num }
            let ints = nums.map { Int($0) }
            let g = ints.reduce(0) { gcd($0, $1) }
            return .number(Double(g))
        },
        .eager("LCM", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args).map { $0.rounded(.down) }
            guard nums.allSatisfy({ $0 >= 0 }) else { throw CellError.num }
            let ints = nums.map { Int($0) }
            if ints.contains(0) { return .number(0) }
            let l = ints.reduce(1) { lcm($0, $1) }
            return .number(Double(l))
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
        .eager("SUMIF", min: 2, max: 3) { args, _ in
            let range = GridArg(args[0])
            let criterion = Criterion.parse(try args[1].toScalar())
            let sumGrid = args.count > 2 ? GridArg(args[2]) : range
            var total = 0.0
            for r in 0..<range.rows {
                for c in 0..<range.columns {
                    let v = range.value(atRow: r, column: c)
                    if case .error(let e) = v { throw e }
                    guard criterion.matches(v) else { continue }
                    let sv = sumGrid.value(atRow: r, column: c)
                    if case .error(let e) = sv { throw e }
                    if case .number(let n) = sv { total += n }
                }
            }
            return .number(total)
        },
        .eager("SUMIFS", min: 3, max: nil) { args, _ in
            guard (args.count - 1) % 2 == 0 else { throw CellError.na }
            let sumGrid = GridArg(args[0])
            var pairs: [(GridArg, Criterion)] = []
            var i = 1
            while i + 1 < args.count {
                pairs.append((GridArg(args[i]), Criterion.parse(try args[i + 1].toScalar())))
                i += 2
            }
            guard pairs.allSatisfy({ $0.0.rows == sumGrid.rows && $0.0.columns == sumGrid.columns }) else {
                throw CellError.value
            }
            var total = 0.0
            for idx in try matchingIndices(criteriaPairs: pairs) {
                let v = sumGrid.value(atRow: idx / sumGrid.columns, column: idx % sumGrid.columns)
                if case .error(let e) = v { throw e }
                if case .number(let n) = v { total += n }
            }
            return .number(total)
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

/// ceil that forgives float fuzz just below an integer (1.9999999999999998 -> 2).
func fuzzyCeil(_ x: Double) -> Double {
    let nearest = x.rounded()
    if abs(x - nearest) < 1e-9 { return nearest }
    return x.rounded(.up)
}

func fuzzyFloor(_ x: Double) -> Double {
    let nearest = x.rounded()
    if abs(x - nearest) < 1e-9 { return nearest }
    return x.rounded(.down)
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
