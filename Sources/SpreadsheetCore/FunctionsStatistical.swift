import Foundation

enum StatisticalFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = counting + extremes + distribution + spread

    private static let counting: [BuiltinFunction] = [
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
            .number(Double(try matchingCells(criteriaPairs(args, from: 0)).count))
        },
        .eager("COUNTIFS", min: 2, max: nil) { args, _ in
            .number(Double(try matchingCells(criteriaPairs(args, from: 0)).count))
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
    ]

    private static let extremes: [BuiltinFunction] = [
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
    ]

    private static let distribution: [BuiltinFunction] = [
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
    ]

    private static let spread: [BuiltinFunction] = [
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
            let cells = try matchingCells(criteriaPairs(Array(args.prefix(2)), from: 0))
            let nums = try criteriaNumbers(GridArg(args.count > 2 ? args[2] : args[0]), at: cells)
            guard !nums.isEmpty else { throw CellError.div0 }
            return .number(nums.reduce(0, +) / Double(nums.count))
        },
        .eager("AVERAGEIFS", min: 3, max: nil) { args, _ in
            let nums = try filteredNumbers(args)
            guard !nums.isEmpty else { throw CellError.div0 }
            return .number(nums.reduce(0, +) / Double(nums.count))
        },
    ]

    /// AVERAGEIFS/MAXIFS/MINIFS(values, range1, criterion1, ...): the
    /// numbers of `values` where every criterion holds.
    private static func filteredNumbers(_ args: [EvalValue]) throws -> [Double] {
        let grid = GridArg(args[0])
        let pairs = try criteriaPairs(args, from: 1)
        guard pairs.allSatisfy({ $0.0.rows == grid.rows && $0.0.columns == grid.columns }) else {
            throw CellError.value
        }
        return try criteriaNumbers(grid, at: matchingCells(pairs))
    }

    /// Shared MAXIFS/MINIFS implementation.
    private static func filteredExtreme(_ args: [EvalValue], isMax: Bool) throws -> Double {
        let nums = try filteredNumbers(args)
        return (isMax ? nums.max() : nums.min()) ?? 0
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
        guard let lower = checkedInt(rank), let upper = checkedInt(rank, rounding: .up) else {
            throw CellError.num
        }
        if lower == upper { return sorted[lower] }
        let frac = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }
}
