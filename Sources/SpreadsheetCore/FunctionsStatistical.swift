import Foundation

enum StatisticalFunctions {
    static let all: [BuiltinFunction] = [
        .eager("AVERAGE", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args)
            guard !nums.isEmpty else { throw CellError.div0 }
            return .number(nums.reduce(0, +) / Double(nums.count))
        },
        .eager("AVERAGEA", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbersA(args)
            guard !nums.isEmpty else { throw CellError.div0 }
            return .number(nums.reduce(0, +) / Double(nums.count))
        },
        .eager("COUNT", min: 1, max: nil) { args, _ in
            var count = 0
            for arg in args {
                switch arg {
                case .range(let r):
                    r.forEachValue { v in
                        if case .number = v { count += 1 }
                    }
                case .scalar(let v):
                    switch v {
                    case .empty, .error: break
                    default: if (try? Coerce.number(v)) != nil { count += 1 }
                    }
                }
            }
            return .number(Double(count))
        },
        .eager("COUNTA", min: 1, max: nil) { args, _ in
            .number(Double(Coerce.collectValues(args).count))
        },
        .eager("COUNTBLANK", min: 1, max: nil) { args, _ in
            var count = 0
            for arg in args {
                let grid = GridArg(arg)
                grid.forEach { v in
                    switch v {
                    case .empty: count += 1
                    case .string(let s) where s.isEmpty: count += 1
                    default: break
                    }
                }
            }
            return .number(Double(count))
        },
        .eager("COUNTIF", min: 2, max: 2) { args, _ in
            let grid = GridArg(args[0])
            let criterion = Criterion.parse(try args[1].toScalar())
            var count = 0
            grid.forEach { v in
                if criterion.matches(v) { count += 1 }
            }
            return .number(Double(count))
        },
        .eager("COUNTIFS", min: 2, max: nil) { args, _ in
            guard args.count % 2 == 0 else { throw CellError.na }
            var pairs: [(GridArg, Criterion)] = []
            var i = 0
            while i + 1 < args.count {
                pairs.append((GridArg(args[i]), Criterion.parse(try args[i + 1].toScalar())))
                i += 2
            }
            return .number(Double(try matchingIndices(criteriaPairs: pairs).count))
        },
        .eager("COUNTUNIQUE", min: 1, max: nil) { args, _ in
            var seen = Set<String>()
            for v in Coerce.collectValues(args) {
                let key: String
                switch v {
                case .number(let n): key = "n:\(n)"
                case .string(let s): key = "s:\(s.lowercased())"
                case .bool(let b): key = "b:\(b)"
                case .error(let e): key = "e:\(e.rawValue)"
                case .empty: continue
                }
                seen.insert(key)
            }
            return .number(Double(seen.count))
        },
        .eager("MAX", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args)
            return .number(nums.max() ?? 0)
        },
        .eager("MIN", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args)
            return .number(nums.min() ?? 0)
        },
        .eager("MAXA", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbersA(args)
            return .number(nums.max() ?? 0)
        },
        .eager("MINA", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbersA(args)
            return .number(nums.min() ?? 0)
        },
        .eager("MAXIFS", min: 3, max: nil) { args, _ in
            .number(try filteredExtreme(args, isMax: true))
        },
        .eager("MINIFS", min: 3, max: nil) { args, _ in
            .number(try filteredExtreme(args, isMax: false))
        },
        .eager("MEDIAN", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args).sorted()
            guard !nums.isEmpty else { throw CellError.num }
            let mid = nums.count / 2
            if nums.count % 2 == 1 { return .number(nums[mid]) }
            return .number((nums[mid - 1] + nums[mid]) / 2)
        },
        .eager("MODE", min: 1, max: nil) { args, _ in
            let nums = try Coerce.collectNumbers(args)
            var counts: [Double: Int] = [:]
            var order: [Double] = []
            for n in nums {
                if counts[n] == nil { order.append(n) }
                counts[n, default: 0] += 1
            }
            var best: Double?
            var bestCount = 1
            for n in order {
                if let c = counts[n], c > bestCount {
                    best = n
                    bestCount = c
                }
            }
            guard let mode = best else { throw CellError.na }
            return .number(mode)
        },
        .eager("LARGE", min: 2, max: 2) { args, _ in
            let nums = try Coerce.collectNumbers([args[0]]).sorted(by: >)
            let n = try intArg(args[1])
            guard n >= 1, n <= nums.count else { throw CellError.num }
            return .number(nums[n - 1])
        },
        .eager("SMALL", min: 2, max: 2) { args, _ in
            let nums = try Coerce.collectNumbers([args[0]]).sorted()
            let n = try intArg(args[1])
            guard n >= 1, n <= nums.count else { throw CellError.num }
            return .number(nums[n - 1])
        },
        .eager("RANK", min: 2, max: 3) { args, _ in
            let value = try numArg(args[0])
            let nums = try Coerce.collectNumbers([args[1]])
            let ascending = try optionalBool(args, 2, default: false)
            guard nums.contains(value) else { throw CellError.na }
            let better = nums.filter { ascending ? $0 < value : $0 > value }.count
            return .number(Double(better + 1))
        },
        .eager("PERCENTILE", min: 2, max: 2) { args, _ in
            let nums = try Coerce.collectNumbers([args[0]]).sorted()
            let p = try numArg(args[1])
            return .number(try percentileInclusive(nums, p))
        },
        .eager("QUARTILE", min: 2, max: 2) { args, _ in
            let nums = try Coerce.collectNumbers([args[0]]).sorted()
            let q = try intArg(args[1])
            guard q >= 0, q <= 4 else { throw CellError.num }
            return .number(try percentileInclusive(nums, Double(q) / 4))
        },
        .eager("STDEV", min: 1, max: nil) { args, _ in
            .number(try deviation(args, sample: true).squareRoot())
        },
        .eager("STDEVP", min: 1, max: nil) { args, _ in
            .number(try deviation(args, sample: false).squareRoot())
        },
        .eager("VAR", min: 1, max: nil) { args, _ in
            .number(try deviation(args, sample: true))
        },
        .eager("VARP", min: 1, max: nil) { args, _ in
            .number(try deviation(args, sample: false))
        },
        .eager("AVERAGEIF", min: 2, max: 3) { args, _ in
            let range = GridArg(args[0])
            let criterion = Criterion.parse(try args[1].toScalar())
            let avgGrid = args.count > 2 ? GridArg(args[2]) : range
            var total = 0.0
            var count = 0
            for r in 0..<range.rows {
                for c in 0..<range.columns {
                    let v = range.value(atRow: r, column: c)
                    if case .error(let e) = v { throw e }
                    guard criterion.matches(v) else { continue }
                    let av = avgGrid.value(atRow: r, column: c)
                    if case .error(let e) = av { throw e }
                    if case .number(let n) = av { total += n; count += 1 }
                }
            }
            guard count > 0 else { throw CellError.div0 }
            return .number(total / Double(count))
        },
        .eager("AVERAGEIFS", min: 3, max: nil) { args, _ in
            guard (args.count - 1) % 2 == 0 else { throw CellError.na }
            let avgGrid = GridArg(args[0])
            var pairs: [(GridArg, Criterion)] = []
            var i = 1
            while i + 1 < args.count {
                pairs.append((GridArg(args[i]), Criterion.parse(try args[i + 1].toScalar())))
                i += 2
            }
            guard pairs.allSatisfy({ $0.0.rows == avgGrid.rows && $0.0.columns == avgGrid.columns }) else {
                throw CellError.value
            }
            var total = 0.0
            var count = 0
            for idx in try matchingIndices(criteriaPairs: pairs) {
                let v = avgGrid.value(atRow: idx / avgGrid.columns, column: idx % avgGrid.columns)
                if case .error(let e) = v { throw e }
                if case .number(let n) = v { total += n; count += 1 }
            }
            guard count > 0 else { throw CellError.div0 }
            return .number(total / Double(count))
        },
    ]

    /// Shared MAXIFS/MINIFS implementation.
    private static func filteredExtreme(_ args: [EvalValue], isMax: Bool) throws -> Double {
        guard (args.count - 1) % 2 == 0 else { throw CellError.na }
        let grid = GridArg(args[0])
        var pairs: [(GridArg, Criterion)] = []
        var i = 1
        while i + 1 < args.count {
            pairs.append((GridArg(args[i]), Criterion.parse(try args[i + 1].toScalar())))
            i += 2
        }
        guard pairs.allSatisfy({ $0.0.rows == grid.rows && $0.0.columns == grid.columns }) else {
            throw CellError.value
        }
        var result: Double?
        for idx in try matchingIndices(criteriaPairs: pairs) {
            let v = grid.value(atRow: idx / grid.columns, column: idx % grid.columns)
            if case .error(let e) = v { throw e }
            if case .number(let n) = v {
                if let current = result {
                    result = isMax ? Swift.max(current, n) : Swift.min(current, n)
                } else {
                    result = n
                }
            }
        }
        return result ?? 0
    }

    private static func deviation(_ args: [EvalValue], sample: Bool) throws -> Double {
        let nums = try Coerce.collectNumbers(args)
        let minCount = sample ? 2 : 1
        guard nums.count >= minCount else { throw CellError.div0 }
        let mean = nums.reduce(0, +) / Double(nums.count)
        let sumSq = nums.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSq / Double(nums.count - (sample ? 1 : 0))
    }

    /// PERCENTILE.INC with linear interpolation.
    private static func percentileInclusive(_ sorted: [Double], _ p: Double) throws -> Double {
        guard !sorted.isEmpty, p >= 0, p <= 1 else { throw CellError.num }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let frac = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }
}
