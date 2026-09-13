import Foundation

/// One endpoint of a reference: a column and/or row with absolute flags.
/// Whole-column refs (A:A) have nil row; whole-row refs (1:3) have nil column.
public struct RefComponent: Hashable, Sendable {
    public var column: Int?
    public var row: Int?
    public var columnAbsolute: Bool
    public var rowAbsolute: Bool

    public init(column: Int?, row: Int?, columnAbsolute: Bool = false, rowAbsolute: Bool = false) {
        self.column = column
        self.row = row
        self.columnAbsolute = columnAbsolute
        self.rowAbsolute = rowAbsolute
    }

    var a1: String {
        var s = ""
        if let c = column {
            if columnAbsolute { s += "$" }
            s += CellAddress.columnName(c)
        }
        if let r = row {
            if rowAbsolute { s += "$" }
            s += String(r + 1)
        }
        return s
    }
}

/// A cell or range reference as written in a formula.
public struct ReferenceExpr: Hashable, Sendable {
    public var sheetName: String?
    public var start: RefComponent
    public var end: RefComponent?

    public init(sheetName: String? = nil, start: RefComponent, end: RefComponent? = nil) {
        self.sheetName = sheetName
        self.start = start
        self.end = end
    }

    public var isRange: Bool { end != nil || start.column == nil || start.row == nil }

    /// Formula-text form, quoting the sheet name when needed.
    public var text: String {
        var s = ""
        if let sheet = sheetName {
            s += ReferenceExpr.quoteSheetNameIfNeeded(sheet) + "!"
        }
        s += start.a1
        if let end { s += ":" + end.a1 }
        return s
    }

    public static func quoteSheetNameIfNeeded(_ name: String) -> String {
        let needsQuotes = name.isEmpty
            || name.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_") })
            || (name.first?.isNumber ?? false)
            || looksLikeCellReference(name)
        if needsQuotes {
            return "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return name
    }

    static func looksLikeCellReference(_ name: String) -> Bool {
        CellAddress(a1: name) != nil
    }

    /// Concrete cell range this reference denotes (unclamped; whole-row/col
    /// endpoints use 0 and the max bound). Nil if malformed.
    public func concreteRange() -> CellRange? {
        let startCol = start.column ?? 0
        let startRow = start.row ?? 0
        let endComponent = end ?? start
        let endCol = endComponent.column ?? (CellAddress.maxColumns - 1)
        let endRow = endComponent.row ?? (CellAddress.maxRows - 1)
        // For whole-column refs the start column exists but row is nil:
        let realStartCol = start.column ?? 0
        let realStartRow = start.row ?? 0
        _ = (startCol, startRow)
        return CellRange(start: CellAddress(row: realStartRow, column: realStartCol),
                         end: CellAddress(row: endRow, column: endCol))
    }

    public var isWholeColumn: Bool { start.row == nil }
    public var isWholeRow: Bool { start.column == nil }
}

public enum UnaryOperator: String, Hashable, Sendable {
    case plus = "+"
    case minus = "-"
}

public enum BinaryOperator: String, Hashable, Sendable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case power = "^"
    case concat = "&"
    case equal = "="
    case notEqual = "<>"
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
}

/// Parsed formula expression tree.
public indirect enum FormulaExpr: Hashable, Sendable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case errorLiteral(CellError)
    case reference(ReferenceExpr)
    /// An identifier that is not a known reference/function/constant; evaluates to #NAME?.
    case unknownName(String)
    case unary(UnaryOperator, FormulaExpr)
    case percent(FormulaExpr)
    case binary(BinaryOperator, FormulaExpr, FormulaExpr)
    case function(String, [FormulaExpr])
    case paren(FormulaExpr)

    // MARK: Serialization back to canonical formula text (no leading '=').

    public var text: String {
        switch self {
        case .number(let n):
            return NumberFormatEngine.generalString(for: n)
        case .string(let s):
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .boolean(let b):
            return b ? "TRUE" : "FALSE"
        case .errorLiteral(let e):
            return e.rawValue
        case .reference(let ref):
            return ref.text
        case .unknownName(let name):
            return name
        case .unary(let op, let e):
            return op.rawValue + e.text
        case .percent(let e):
            return e.text + "%"
        case .binary(let op, let l, let r):
            return l.text + op.rawValue + r.text
        case .function(let name, let args):
            return name + "(" + args.map(\.text).joined(separator: ",") + ")"
        case .paren(let e):
            return "(" + e.text + ")"
        }
    }

    // MARK: Reference walking / transformation

    /// All references in the expression.
    public var references: [ReferenceExpr] {
        switch self {
        case .reference(let r): return [r]
        case .unary(_, let e), .percent(let e), .paren(let e): return e.references
        case .binary(_, let l, let r): return l.references + r.references
        case .function(_, let args): return args.flatMap(\.references)
        default: return []
        }
    }

    /// Rewrite every reference via `transform`; returning nil turns that
    /// reference into #REF!.
    public func mappingReferences(_ transform: (ReferenceExpr) -> ReferenceExpr?) -> FormulaExpr {
        switch self {
        case .reference(let r):
            if let newRef = transform(r) { return .reference(newRef) }
            return .errorLiteral(.ref)
        case .unary(let op, let e):
            return .unary(op, e.mappingReferences(transform))
        case .percent(let e):
            return .percent(e.mappingReferences(transform))
        case .paren(let e):
            return .paren(e.mappingReferences(transform))
        case .binary(let op, let l, let r):
            return .binary(op, l.mappingReferences(transform), r.mappingReferences(transform))
        case .function(let name, let args):
            return .function(name, args.map { $0.mappingReferences(transform) })
        default:
            return self
        }
    }

    /// Shift relative references by (rows, columns) — copy/paste and fill
    /// semantics. Absolute components stay put; refs shifted off-grid become #REF!.
    public func adjustedForCopy(byRows rows: Int, columns: Int) -> FormulaExpr {
        mappingReferences { ref in
            var ref = ref
            func shift(_ c: RefComponent) -> RefComponent? {
                var c = c
                if let row = c.row, !c.rowAbsolute {
                    let newRow = row + rows
                    guard newRow >= 0, newRow < CellAddress.maxRows else { return nil }
                    c.row = newRow
                }
                if let col = c.column, !c.columnAbsolute {
                    let newCol = col + columns
                    guard newCol >= 0, newCol < CellAddress.maxColumns else { return nil }
                    c.column = newCol
                }
                return c
            }
            guard let newStart = shift(ref.start) else { return nil }
            ref.start = newStart
            if let end = ref.end {
                guard let newEnd = shift(end) else { return nil }
                ref.end = newEnd
            }
            return ref
        }
    }

    /// Adjust references for rows/columns inserted or deleted in `sheetName`
    /// (nil = the sheet owning this formula). All references (absolute too)
    /// shift; ranges spanning the edit expand/contract; refs to deleted
    /// cells become #REF!.
    ///
    /// - Parameters:
    ///   - axisIsRow: true when rows changed, false for columns.
    ///   - index: first affected row/column index.
    ///   - count: positive = inserted, negative = deleted.
    ///   - editedSheet: name of the sheet where the edit happened.
    ///   - ownSheet: name of the sheet owning this formula.
    public func adjustedForStructuralChange(
        axisIsRow: Bool, index: Int, count: Int,
        editedSheet: String, ownSheet: String
    ) -> FormulaExpr {
        mappingReferences { ref in
            let target = ref.sheetName ?? ownSheet
            guard target.caseInsensitiveCompare(editedSheet) == .orderedSame else { return ref }
            var ref = ref

            func adjust(_ value: Int, isStart: Bool, partnerValue: Int?) -> Int? {
                if count > 0 {
                    // Insertion at `index`: positions >= index shift down/right.
                    return value >= index ? value + count : value
                } else {
                    // Deletion of [index, index+|count|-1].
                    let delCount = -count
                    let delEnd = index + delCount - 1
                    if value < index { return value }
                    if value > delEnd { return value + count }
                    // Endpoint inside the deleted span.
                    if let partner = partnerValue {
                        // Part of a range: contract toward the surviving side.
                        if isStart {
                            // start inside deletion: move to `index` if partner survives past delEnd
                            if partner > delEnd { return index }
                            return nil
                        } else {
                            // end inside deletion: move to index-1 if partner is before index
                            if partner < index { return index - 1 }
                            return nil
                        }
                    }
                    return nil // single cell deleted -> #REF!
                }
            }

            if axisIsRow {
                let startRow = ref.start.row
                let endRow = ref.end?.row
                if let sr = startRow {
                    let partner = ref.end == nil ? nil : endRow
                    guard let newStart = adjust(sr, isStart: true, partnerValue: partner) else { return nil }
                    ref.start.row = newStart
                }
                if ref.end != nil, let er = endRow {
                    guard let newEnd = adjust(er, isStart: false, partnerValue: startRow) else { return nil }
                    ref.end?.row = newEnd
                }
            } else {
                let startCol = ref.start.column
                let endCol = ref.end?.column
                if let sc = startCol {
                    let partner = ref.end == nil ? nil : endCol
                    guard let newStart = adjust(sc, isStart: true, partnerValue: partner) else { return nil }
                    ref.start.column = newStart
                }
                if ref.end != nil, let ec = endCol {
                    guard let newEnd = adjust(ec, isStart: false, partnerValue: startCol) else { return nil }
                    ref.end?.column = newEnd
                }
            }
            return ref
        }
    }

    /// Rewrite sheet-qualified references when a sheet is renamed.
    public func renamingSheet(from oldName: String, to newName: String) -> FormulaExpr {
        mappingReferences { ref in
            var ref = ref
            if let sheet = ref.sheetName, sheet.caseInsensitiveCompare(oldName) == .orderedSame {
                ref.sheetName = newName
            }
            return ref
        }
    }

    /// True if the expression calls any volatile function.
    public var isVolatile: Bool {
        switch self {
        case .function(let name, let args):
            if FunctionRegistry.volatileFunctions.contains(name.uppercased()) { return true }
            return args.contains { $0.isVolatile }
        case .unary(_, let e), .percent(let e), .paren(let e):
            return e.isVolatile
        case .binary(_, let l, let r):
            return l.isVolatile || r.isVolatile
        default:
            return false
        }
    }
}
