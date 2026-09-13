import Foundation

extension CellError: Error {}

/// A sheet-qualified cell address.
public struct AbsoluteAddress: Hashable, Sendable, CustomStringConvertible {
    public var sheetID: Int
    public var address: CellAddress

    public init(sheetID: Int, address: CellAddress) {
        self.sheetID = sheetID
        self.address = address
    }

    public var description: String { "sheet\(sheetID)!\(address.a1)" }
}

/// Time/randomness providers, injectable for deterministic tests.
public struct EvalClock: Sendable {
    public var todaySerial: @Sendable () -> Double
    public var nowSerial: @Sendable () -> Double
    public var random: @Sendable () -> Double

    public init(
        todaySerial: @escaping @Sendable () -> Double = { ExcelDate.todaySerial() },
        nowSerial: @escaping @Sendable () -> Double = { ExcelDate.nowSerial() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.todaySerial = todaySerial
        self.nowSerial = nowSerial
        self.random = random
    }

    /// Fixed clock for tests.
    public static func fixed(today: Double, now: Double? = nil, random: Double = 0.5) -> EvalClock {
        EvalClock(todaySerial: { today }, nowSerial: { now ?? today }, random: { random })
    }
}

/// Everything an expression needs to evaluate: the workbook, the cell being
/// computed, and deterministic providers.
public struct EvalContext {
    public let workbook: Workbook
    public let sheetID: Int
    public let address: CellAddress
    public let clock: EvalClock

    public init(workbook: Workbook, sheetID: Int, address: CellAddress, clock: EvalClock = EvalClock()) {
        self.workbook = workbook
        self.sheetID = sheetID
        self.address = address
        self.clock = clock
    }
}

/// A reference resolved against the workbook: a concrete sheet + clamped rect.
/// Whole-column/row references are clamped to the sheet's used range.
public struct ResolvedRange {
    public let sheet: Sheet
    public let sheetID: Int
    public let range: CellRange
    /// True when the underlying reference was a single cell (not a range).
    public let isSingleCell: Bool
    /// True when the clamped range is empty (whole-column ref on empty sheet).
    public let isEmpty: Bool

    public var rowCount: Int { isEmpty ? 0 : range.rowCount }
    public var columnCount: Int { isEmpty ? 0 : range.columnCount }
    public var cellCount: Int { isEmpty ? 0 : range.cellCount }

    /// Value at 0-based (row, column) offsets within the range.
    public func value(atRow row: Int, column: Int) -> CellValue {
        guard !isEmpty else { return .empty }
        let addr = CellAddress(row: range.start.row + row, column: range.start.column + column)
        return sheet.value(at: addr)
    }

    /// Iterate all values in row-major order (including empties).
    public func forEachValue(_ body: (CellValue) throws -> Void) rethrows {
        guard !isEmpty else { return }
        // For sparse large ranges, iterate storage instead of the rect.
        if range.cellCount > 4096 && range.cellCount > sheet.cells.count * 4 {
            for (addr, cell) in sheet.cells where range.contains(addr) {
                try body(cell.value)
            }
            return
        }
        for r in range.start.row...range.end.row {
            for c in range.start.column...range.end.column {
                try body(sheet.value(at: CellAddress(row: r, column: c)))
            }
        }
    }

    /// All values in strict row-major order (use only for bounded ranges).
    public func allValues() -> [CellValue] {
        guard !isEmpty else { return [] }
        var out: [CellValue] = []
        out.reserveCapacity(min(cellCount, 65536))
        for r in range.start.row...range.end.row {
            for c in range.start.column...range.end.column {
                out.append(sheet.value(at: CellAddress(row: r, column: c)))
            }
        }
        return out
    }
}

/// A value flowing through evaluation: a scalar or a resolved range.
public enum EvalValue {
    case scalar(CellValue)
    case range(ResolvedRange)

    /// Collapse to a scalar; multi-cell ranges are a #VALUE! error
    /// (no implicit intersection, matching our documented v1 semantics).
    public func toScalar() throws -> CellValue {
        switch self {
        case .scalar(let v):
            return v
        case .range(let r):
            if r.isSingleCell || r.cellCount == 1 {
                return r.isEmpty ? .empty : r.value(atRow: 0, column: 0)
            }
            throw CellError.value
        }
    }
}

// MARK: - Evaluator

public enum FormulaEvaluator {
    /// Evaluate a parsed formula to a cell value. Never throws; errors become
    /// error values.
    public static func evaluate(_ expr: FormulaExpr, context: EvalContext) -> CellValue {
        do {
            let v = try evalValue(expr, context: context)
            let scalar = try v.toScalar()
            // Normalize non-finite numbers to #NUM!.
            if case .number(let n) = scalar, !n.isFinite {
                return .error(.num)
            }
            return scalar
        } catch let e as CellError {
            return .error(e)
        } catch {
            return .error(.value)
        }
    }

    static func evalValue(_ expr: FormulaExpr, context: EvalContext) throws -> EvalValue {
        switch expr {
        case .number(let n):
            return .scalar(.number(n))
        case .string(let s):
            return .scalar(.string(s))
        case .boolean(let b):
            return .scalar(.bool(b))
        case .errorLiteral(let e):
            return .scalar(.error(e))
        case .unknownName:
            return .scalar(.error(.name))
        case .paren(let inner):
            return try evalValue(inner, context: context)
        case .reference(let ref):
            return try resolveReference(ref, context: context)
        case .percent(let inner):
            let v = try scalarOperand(inner, context: context)
            let n = try Coerce.number(v)
            return .scalar(.number(n / 100))
        case .unary(let op, let inner):
            let v = try scalarOperand(inner, context: context)
            if case .error(let e) = v { throw e }
            let n = try Coerce.number(v)
            return .scalar(.number(op == .minus ? -n : n))
        case .binary(let op, let lhs, let rhs):
            return .scalar(try evalBinary(op, lhs, rhs, context: context))
        case .function(let name, let args):
            return .scalar(try evalFunction(name, args, context: context))
        }
    }

    static func scalarOperand(_ expr: FormulaExpr, context: EvalContext) throws -> CellValue {
        try evalValue(expr, context: context).toScalar()
    }

    static func evalBinary(_ op: BinaryOperator, _ lhs: FormulaExpr, _ rhs: FormulaExpr,
                           context: EvalContext) throws -> CellValue {
        let l = try scalarOperand(lhs, context: context)
        let r = try scalarOperand(rhs, context: context)
        if case .error(let e) = l { throw e }
        if case .error(let e) = r { throw e }

        switch op {
        case .add, .subtract, .multiply, .divide, .power:
            let a = try Coerce.number(l)
            let b = try Coerce.number(r)
            switch op {
            case .add: return .number(a + b)
            case .subtract: return .number(a - b)
            case .multiply: return .number(a * b)
            case .divide:
                guard b != 0 else { throw CellError.div0 }
                return .number(a / b)
            case .power:
                if a == 0 && b == 0 { throw CellError.num }
                let result = pow(a, b)
                guard result.isFinite else { throw CellError.num }
                return .number(result)
            default: fatalError("unreachable")
            }
        case .concat:
            return .string(Coerce.displayText(l) + Coerce.displayText(r))
        case .equal, .notEqual, .less, .lessOrEqual, .greater, .greaterOrEqual:
            let cmp = Coerce.compare(l, r)
            switch op {
            case .equal: return .bool(cmp == 0)
            case .notEqual: return .bool(cmp != 0)
            case .less: return .bool(cmp < 0)
            case .lessOrEqual: return .bool(cmp <= 0)
            case .greater: return .bool(cmp > 0)
            case .greaterOrEqual: return .bool(cmp >= 0)
            default: fatalError("unreachable")
            }
        }
    }

    static func evalFunction(_ name: String, _ args: [FormulaExpr],
                             context: EvalContext) throws -> CellValue {
        guard let fn = FunctionRegistry.function(named: name) else {
            throw CellError.name
        }
        guard args.count >= fn.minArgs, fn.maxArgs.map({ args.count <= $0 }) ?? true else {
            throw CellError.na // Sheets: "wrong number of arguments" surfaces as #N/A
        }
        let fnContext = FunctionContext(eval: context)
        if fn.isLazy {
            return try fn.evalLazy!(args, fnContext)
        }
        let values = try args.map { try evalValue($0, context: context) }
        return try fn.evalEager!(values, fnContext)
    }

    static func resolveReference(_ ref: ReferenceExpr, context: EvalContext) throws -> EvalValue {
        let sheet: Sheet
        let sheetID: Int
        if let name = ref.sheetName {
            guard let s = context.workbook.sheet(named: name) else { throw CellError.ref }
            sheet = s
            sheetID = s.id
        } else {
            guard let s = context.workbook.sheet(withID: context.sheetID) else { throw CellError.ref }
            sheet = s
            sheetID = context.sheetID
        }

        let isSingle = ref.end == nil && ref.start.column != nil && ref.start.row != nil
        if isSingle {
            let addr = CellAddress(row: ref.start.row!, column: ref.start.column!)
            guard addr.isValid else { throw CellError.ref }
            let resolved = ResolvedRange(sheet: sheet, sheetID: sheetID,
                                         range: CellRange(addr), isSingleCell: true, isEmpty: false)
            return .range(resolved)
        }

        // Range (possibly whole row/column): clamp open axes to the used range.
        let used = sheet.usedRange
        let endComp = ref.end ?? ref.start
        var startRow = ref.start.row ?? 0
        var endRow = endComp.row ?? (used?.end.row ?? -1)
        var startCol = ref.start.column ?? 0
        var endCol = endComp.column ?? (used?.end.column ?? -1)
        // Normalize reversed bounds (B2:A1 is legal and means A1:B2).
        if startRow > endRow && endComp.row != nil { swap(&startRow, &endRow) }
        if startCol > endCol && endComp.column != nil { swap(&startCol, &endCol) }

        let empty = endRow < startRow || endCol < startCol
        let range = empty
            ? CellRange(CellAddress(row: max(0, startRow), column: max(0, startCol)))
            : CellRange(start: CellAddress(row: startRow, column: startCol),
                        end: CellAddress(row: endRow, column: endCol))
        guard range.start.row >= 0, range.start.column >= 0,
              range.end.row < CellAddress.maxRows, range.end.column < CellAddress.maxColumns else {
            throw CellError.ref
        }
        return .range(ResolvedRange(sheet: sheet, sheetID: sheetID, range: range,
                                    isSingleCell: false, isEmpty: empty))
    }
}
