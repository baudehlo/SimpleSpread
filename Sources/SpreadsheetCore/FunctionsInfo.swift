import Foundation

enum InfoFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = predicates + valueInfo

    private static let predicates: [BuiltinFunction] = [
        .lazy("ISBLANK", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .empty = v { return .bool(true) }
            return .bool(false)
        },
        .lazy("ISNUMBER", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .number = v { return .bool(true) }
            return .bool(false)
        },
        .lazy("ISTEXT", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .string = v { return .bool(true) }
            return .bool(false)
        },
        .lazy("ISNONTEXT", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .string = v { return .bool(false) }
            return .bool(true)
        },
        .lazy("ISLOGICAL", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .bool = v { return .bool(true) }
            return .bool(false)
        },
        .lazy("ISERROR", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .error = v { return .bool(true) }
            return .bool(false)
        },
        .lazy("ISERR", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .error(let e) = v { return .bool(e != .na) }
            return .bool(false)
        },
        .lazy("ISNA", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .error(.na) = v { return .bool(true) }
            return .bool(false)
        },
    ]

    private static let valueInfo: [BuiltinFunction] = [
        .eager("ISEVEN", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            return .bool(Int(n.rounded(.towardZero)) % 2 == 0)
        },
        .eager("ISODD", min: 1, max: 1) { args, _ in
            let n = try numArg(args[0])
            return .bool(Int(n.rounded(.towardZero)) % 2 != 0)
        },
        .eager("N", min: 1, max: 1) { args, _ in
            let v = try args[0].toScalar()
            switch v {
            case .number(let n): return .number(n)
            case .bool(let b): return .number(b ? 1 : 0)
            case .error(let e): throw e
            default: return .number(0)
            }
        },
        .eager("NA", min: 0, max: 0) { _, _ in .error(.na) },
        .lazy("TYPE", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            switch v {
            case .number, .empty: return .number(1)
            case .string: return .number(2)
            case .bool: return .number(4)
            case .error: return .number(16)
            }
        },
        .lazy("ERROR.TYPE", min: 1, max: 1) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            guard case .error(let e) = v else { throw CellError.na }
            return .number(Double(e.errorTypeCode))
        },
    ]
}
