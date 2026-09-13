import Foundation

enum LogicalFunctions {
    // Split into sub-arrays: one huge literal exceeds older compilers'
    // type-checking budget (CI runners lag the local toolchain).
    static let all: [BuiltinFunction] = conditionals + operators

    private static let conditionals: [BuiltinFunction] = [
        .lazy("IF", min: 2, max: 3) { args, ctx in
            let cond = try ctx.evaluateScalar(args[0])
            if case .error(let e) = cond { return .error(e) }
            let taken = (try Coerce.boolean(cond)) ? args[1] : (args.count > 2 ? args[2] : nil)
            guard let branch = taken else { return .bool(false) }
            return try ctx.evaluateScalar(branch)
        },
        .lazy("IFS", min: 2, max: nil) { args, ctx in
            guard args.count % 2 == 0 else { throw CellError.na }
            var i = 0
            while i + 1 < args.count {
                let cond = try ctx.evaluateScalar(args[i])
                if case .error(let e) = cond { return .error(e) }
                if try Coerce.boolean(cond) {
                    return try ctx.evaluateScalar(args[i + 1])
                }
                i += 2
            }
            throw CellError.na
        },
        .lazy("IFERROR", min: 1, max: 2) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .error = v {
                return args.count > 1 ? try ctx.evaluateScalar(args[1]) : .empty
            }
            return v
        },
        .lazy("IFNA", min: 2, max: 2) { args, ctx in
            let v = ctx.evaluateCapturingErrors(args[0])
            if case .error(.na) = v {
                return try ctx.evaluateScalar(args[1])
            }
            return v
        },
    ]

    private static let operators: [BuiltinFunction] = [
        .eager("AND", min: 1, max: nil) { args, _ in
            .bool(try logicalFold(args, identity: true) { $0 && $1 })
        },
        .eager("OR", min: 1, max: nil) { args, _ in
            .bool(try logicalFold(args, identity: false) { $0 || $1 })
        },
        .eager("XOR", min: 1, max: nil) { args, _ in
            .bool(try logicalFold(args, identity: false) { $0 != $1 })
        },
        .eager("NOT", min: 1, max: 1) { args, _ in
            .bool(!(try boolArg(args[0])))
        },
        .eager("TRUE", min: 0, max: 0) { _, _ in .bool(true) },
        .eager("FALSE", min: 0, max: 0) { _, _ in .bool(false) },
        .lazy("SWITCH", min: 3, max: nil) { args, ctx in
            let subject = try ctx.evaluateScalar(args[0])
            if case .error(let e) = subject { return .error(e) }
            let pairArgs = Array(args.dropFirst())
            let hasDefault = pairArgs.count % 2 == 1
            let pairCount = pairArgs.count / 2
            for i in 0..<pairCount {
                let candidate = try ctx.evaluateScalar(pairArgs[i * 2])
                if case .error(let e) = candidate { return .error(e) }
                if Coerce.compare(subject, candidate) == 0 {
                    return try ctx.evaluateScalar(pairArgs[i * 2 + 1])
                }
            }
            if hasDefault {
                return try ctx.evaluateScalar(pairArgs[pairArgs.count - 1])
            }
            throw CellError.na
        },
    ]

    /// AND/OR/XOR argument folding: range cells that aren't boolean/number are
    /// skipped; direct scalars coerce (text "TRUE"/"FALSE" allowed, other text
    /// -> #VALUE!); no logical values at all -> #VALUE!.
    private static func logicalFold(
        _ args: [EvalValue], identity: Bool, _ combine: (Bool, Bool) -> Bool
    ) throws -> Bool {
        var acc = identity
        var found = false
        for arg in args {
            switch arg {
            case .range(let r):
                try r.forEachValue { v in
                    switch v {
                    case .bool(let b): acc = combine(acc, b); found = true
                    case .number(let n): acc = combine(acc, n != 0); found = true
                    case .error(let e): throw e
                    default: break
                    }
                }
            case .scalar(let v):
                switch v {
                case .empty: break
                case .error(let e): throw e
                default:
                    acc = combine(acc, try Coerce.boolean(v))
                    found = true
                }
            }
        }
        guard found else { throw CellError.value }
        return acc
    }
}

extension FunctionContext {
    /// Evaluate an argument, converting any thrown evaluation error into an
    /// error VALUE (for IFERROR/IS*-style inspection functions).
    func evaluateCapturingErrors(_ expr: FormulaExpr) -> CellValue {
        do {
            return try evaluate(expr).toScalar()
        } catch let e as CellError {
            return .error(e)
        } catch {
            return .error(.value)
        }
    }
}
