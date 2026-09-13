import Foundation

/// Shared type-coercion rules (Excel/Google Sheets semantics).
///
/// Two regimes exist and must not be mixed up:
/// - OPERATORS and direct literal args coerce aggressively (bool -> 1/0,
///   numeric text -> number, blank -> 0; failure -> #VALUE!).
/// - RANGE-consuming aggregates SKIP text/booleans/blanks inside references
///   without coercing (see Aggregate helpers).
public enum Coerce {
    // MARK: Scalar coercion (operator regime)

    public static func number(_ v: CellValue) throws -> Double {
        switch v {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .empty: return 0
        case .string(let s):
            if let n = parseNumericText(s) { return n }
            throw CellError.value
        case .error(let e): throw e
        }
    }

    public static func int(_ v: CellValue) throws -> Int {
        let n = try number(v)
        guard n.isFinite, abs(n) < 9e15 else { throw CellError.num }
        return Int(n.rounded(.down))
    }

    public static func string(_ v: CellValue) throws -> String {
        if case .error(let e) = v { throw e }
        return displayText(v)
    }

    public static func boolean(_ v: CellValue) throws -> Bool {
        switch v {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .empty: return false
        case .string(let s):
            if s.caseInsensitiveCompare("TRUE") == .orderedSame { return true }
            if s.caseInsensitiveCompare("FALSE") == .orderedSame { return false }
            throw CellError.value
        case .error(let e): throw e
        }
    }

    /// Text form used by '&' and text functions: numbers in General form,
    /// booleans as TRUE/FALSE, blank as "".
    public static func displayText(_ v: CellValue) -> String {
        v.rawDisplayString
    }

    /// Parse text as a number the way operators do: plain/scientific numbers,
    /// thousands separators, leading/trailing whitespace, percent suffix,
    /// currency prefix. (Date-string coercion in arithmetic is not supported.)
    public static func parseNumericText(_ s: String) -> Double? {
        var text = s.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var multiplier = 1.0
        if text.hasSuffix("%") {
            multiplier = 0.01
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        var negative = false
        if text.hasPrefix("-") {
            negative = true
            text = String(text.dropFirst())
        } else if text.hasPrefix("+") {
            text = String(text.dropFirst())
        }
        if text.hasPrefix("$") {
            text = String(text.dropFirst())
        }
        // Reject anything that isn't digits, separators, or exponent notation.
        text = text.replacingOccurrences(of: ",", with: "")
        guard !text.isEmpty else { return nil }
        guard let value = strictDouble(text) else { return nil }
        return (negative ? -value : value) * multiplier
    }

    /// Double parsing that rejects Swift-isms like "0x1p3", "inf", "nan", "1_000".
    static func strictDouble(_ s: String) -> Double? {
        var hasDigit = false
        var hasDot = false
        var hasExp = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber { hasDigit = true }
            else if c == "." {
                if hasDot || hasExp { return nil }
                hasDot = true
            } else if c == "e" || c == "E" {
                if hasExp || !hasDigit { return nil }
                hasExp = true
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "+" || s[next] == "-" {
                    i = next
                }
                // exponent must have at least one digit
                let after = s.index(after: i)
                guard after < s.endIndex, s[after].isNumber else { return nil }
            } else {
                return nil
            }
            i = s.index(after: i)
        }
        guard hasDigit else { return nil }
        return Double(s)
    }

    // MARK: Comparison (no cross-type coercion; type ranking)

    /// Excel/Sheets comparison semantics. Returns negative/zero/positive.
    /// - same types compare naturally (text case-insensitively)
    /// - blank coerces to the other operand's zero value
    /// - mixed types rank: number < text < boolean
    public static func compare(_ a: CellValue, _ b: CellValue) -> Int {
        func rank(_ v: CellValue) -> Int {
            switch v {
            case .number: return 0
            case .string: return 1
            case .bool: return 2
            default: return 3
            }
        }
        switch (a, b) {
        case (.empty, .empty):
            return 0
        case (.empty, _):
            return compare(zeroValue(like: b), b)
        case (_, .empty):
            return compare(a, zeroValue(like: a))
        case (.number(let x), .number(let y)):
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.string(let x), .string(let y)):
            let lx = x.lowercased(), ly = y.lowercased()
            return lx < ly ? -1 : (lx > ly ? 1 : 0)
        case (.bool(let x), .bool(let y)):
            if x == y { return 0 }
            return x ? 1 : -1
        default:
            let ra = rank(a), rb = rank(b)
            return ra < rb ? -1 : (ra > rb ? 1 : 0)
        }
    }

    static func zeroValue(like v: CellValue) -> CellValue {
        switch v {
        case .number: return .number(0)
        case .string: return .string("")
        case .bool: return .bool(false)
        default: return .number(0)
        }
    }

    // MARK: Aggregate collection (range regime)

    /// Flatten args into numbers with the range/literal asymmetry:
    /// range cells: numbers only (text/bool/blank skipped; errors thrown);
    /// direct scalars: full coercion (blank skipped, unparseable text throws).
    public static func collectNumbers(_ args: [EvalValue]) throws -> [Double] {
        var out: [Double] = []
        for arg in args {
            switch arg {
            case .range(let r):
                try r.forEachValue { v in
                    switch v {
                    case .number(let n): out.append(n)
                    case .error(let e): throw e
                    default: break
                    }
                }
            case .scalar(let v):
                switch v {
                case .empty: break
                case .error(let e): throw e
                default: out.append(try number(v))
                }
            }
        }
        return out
    }

    /// Like collectNumbers but "A-variant" (AVERAGEA etc.): in ranges, text
    /// counts as 0 and booleans as 1/0; blanks still skipped.
    public static func collectNumbersA(_ args: [EvalValue]) throws -> [Double] {
        var out: [Double] = []
        for arg in args {
            switch arg {
            case .range(let r):
                try r.forEachValue { v in
                    switch v {
                    case .number(let n): out.append(n)
                    case .string: out.append(0)
                    case .bool(let b): out.append(b ? 1 : 0)
                    case .error(let e): throw e
                    case .empty: break
                    }
                }
            case .scalar(let v):
                switch v {
                case .empty: break
                case .error(let e): throw e
                default: out.append(try number(v))
                }
            }
        }
        return out
    }

    /// Flatten args to all non-empty cell values (COUNTA-style; errors kept).
    public static func collectValues(_ args: [EvalValue]) -> [CellValue] {
        var out: [CellValue] = []
        for arg in args {
            switch arg {
            case .range(let r):
                r.forEachValue { v in
                    if !v.isEmpty { out.append(v) }
                }
            case .scalar(let v):
                if !v.isEmpty { out.append(v) }
            }
        }
        return out
    }
}

// MARK: - Criteria (SUMIF/COUNTIF family)

/// A parsed criterion: an optional comparison operator plus a target value.
public struct Criterion {
    public enum Operator {
        case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
    }

    public let op: Operator
    public let target: CellValue

    /// Build from a criterion argument value (string with optional operator
    /// prefix, or a direct number/bool).
    public static func parse(_ v: CellValue) -> Criterion {
        guard case .string(let raw) = v else {
            return Criterion(op: .equal, target: v)
        }
        let prefixes: [(String, Operator)] = [
            (">=", .greaterOrEqual), ("<=", .lessOrEqual), ("<>", .notEqual),
            ("=", .equal), (">", .greater), ("<", .less),
        ]
        var op = Operator.equal
        var rest = raw
        for (prefix, candidate) in prefixes where raw.hasPrefix(prefix) {
            op = candidate
            rest = String(raw.dropFirst(prefix.count))
            break
        }
        // Parse remainder: number, boolean, else text.
        let target: CellValue
        if rest.isEmpty {
            target = .empty
        } else if let n = Coerce.parseNumericText(rest) {
            target = .number(n)
        } else if rest.caseInsensitiveCompare("TRUE") == .orderedSame {
            target = .bool(true)
        } else if rest.caseInsensitiveCompare("FALSE") == .orderedSame {
            target = .bool(false)
        } else {
            target = .string(rest)
        }
        return Criterion(op: op, target: target)
    }

    public init(op: Operator, target: CellValue) {
        self.op = op
        self.target = target
    }

    public func matches(_ v: CellValue) -> Bool {
        switch op {
        case .equal:
            switch target {
            case .empty:
                // "" or "=" matches blank cells (and empty strings)
                if case .empty = v { return true }
                if case .string(let s) = v { return s.isEmpty }
                return false
            case .number(let t):
                if case .number(let n) = v { return n == t }
                return false
            case .bool(let t):
                if case .bool(let b) = v { return b == t }
                return false
            case .string(let pattern):
                guard case .string(let s) = v else { return false }
                return Criterion.wildcardMatch(pattern: pattern, text: s)
            case .error(let t):
                if case .error(let e) = v { return e == t }
                return false
            }
        case .notEqual:
            switch target {
            case .empty:
                // "<>" matches non-empty
                if case .empty = v { return false }
                if case .string(let s) = v { return !s.isEmpty }
                return true
            case .string(let pattern):
                if case .string(let s) = v {
                    return !Criterion.wildcardMatch(pattern: pattern, text: s)
                }
                return true // non-text (incl. blank) matches "<>text"
            case .number(let t):
                if case .number(let n) = v { return n != t }
                return true
            case .bool(let t):
                if case .bool(let b) = v { return b != t }
                return true
            case .error(let t):
                if case .error(let e) = v { return e != t }
                return true
            }
        case .less, .lessOrEqual, .greater, .greaterOrEqual:
            // Same-type comparisons only; other types silently excluded.
            let cmp: Int
            switch (v, target) {
            case (.number(let n), .number(let t)):
                cmp = n < t ? -1 : (n > t ? 1 : 0)
            case (.string(let s), .string(let t)):
                let ls = s.lowercased(), lt = t.lowercased()
                cmp = ls < lt ? -1 : (ls > lt ? 1 : 0)
            case (.bool(let b), .bool(let t)):
                cmp = (b == t) ? 0 : (b ? 1 : -1)
            default:
                return false
            }
            switch op {
            case .less: return cmp < 0
            case .lessOrEqual: return cmp <= 0
            case .greater: return cmp > 0
            case .greaterOrEqual: return cmp >= 0
            default: return false
            }
        }
    }

    /// Whole-string wildcard match, case-insensitive. `?` = one char,
    /// `*` = any run, `~` escapes the next character.
    public static func wildcardMatch(pattern: String, text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())

        // Iterative glob match with backtracking on '*'.
        var pi = 0, ti = 0
        var starPi = -1, starTi = -1
        while ti < t.count {
            if pi < p.count, p[pi] == "~", pi + 1 < p.count {
                if p[pi + 1] == t[ti] { pi += 2; ti += 1; continue }
            } else if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1; continue
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi; starTi = ti; pi += 1; continue
            }
            if starPi >= 0 {
                starTi += 1
                ti = starTi
                pi = starPi + 1
                continue
            }
            return false
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        // Trailing "~x" with nothing left to match
        return pi == p.count
    }
}
