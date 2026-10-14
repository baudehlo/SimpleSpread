import Foundation

/// A cell's number format, stored as an Excel/OOXML format code string.
/// The empty string (or "General") means General formatting.
public struct NumberFormat: Hashable, Sendable, Codable {
    public var code: String

    public init(code: String) {
        self.code = code
    }

    public static let general = NumberFormat(code: "")
    public static let integer = NumberFormat(code: "0")
    public static let decimal2 = NumberFormat(code: "0.00")
    public static let thousands = NumberFormat(code: "#,##0")
    public static let thousandsDecimal2 = NumberFormat(code: "#,##0.00")
    public static let percentInteger = NumberFormat(code: "0%")
    public static let percent = NumberFormat(code: "0.00%")
    public static let currency = NumberFormat(code: "$#,##0.00")
    public static let date = NumberFormat(code: "m/d/yyyy")
    public static let time = NumberFormat(code: "h:mm:ss AM/PM")
    public static let dateTime = NumberFormat(code: "m/d/yyyy h:mm")
    public static let scientific = NumberFormat(code: "0.00E+00")
    public static let text = NumberFormat(code: "@")

    public var isGeneral: Bool {
        code.isEmpty || code.caseInsensitiveCompare("General") == .orderedSame
    }

    /// True if the (first section of the) format renders as a date/time.
    public var isDateTime: Bool {
        NumberFormatEngine.sectionIsDateTime(NumberFormatEngine.sections(of: code).first ?? "")
    }

    /// True if this is the text-only format ("@"), which suppresses type inference.
    public var isTextFormat: Bool {
        code.trimmingCharacters(in: .whitespaces) == "@"
    }

    /// OOXML builtin numFmtId -> format code (ECMA-376 Part 1, §18.8.30).
    public static let builtinFormats: [Int: String] = [
        0: "General",
        1: "0",
        2: "0.00",
        3: "#,##0",
        4: "#,##0.00",
        9: "0%",
        10: "0.00%",
        11: "0.00E+00",
        12: "# ?/?",
        13: "# ??/??",
        14: "m/d/yyyy",
        15: "d-mmm-yy",
        16: "d-mmm",
        17: "mmm-yy",
        18: "h:mm AM/PM",
        19: "h:mm:ss AM/PM",
        20: "h:mm",
        21: "h:mm:ss",
        22: "m/d/yyyy h:mm",
        37: "#,##0 ;(#,##0)",
        38: "#,##0 ;[Red](#,##0)",
        39: "#,##0.00;(#,##0.00)",
        40: "#,##0.00;[Red](#,##0.00)",
        45: "mm:ss",
        46: "[h]:mm:ss",
        47: "mm:ss.0",
        48: "##0.0E+0",
        49: "@",
    ]

    /// Reverse lookup: format code -> builtin id, for compact XLSX output.
    public static func builtinID(for code: String) -> Int? {
        if code.isEmpty { return 0 }
        return builtinFormats.first { $0.value == code }?.key
    }

    public static func builtin(_ id: Int) -> NumberFormat? {
        builtinFormats[id].map { NumberFormat(code: $0 == "General" ? "" : $0) }
    }
}

/// Renders cell values using Excel-style number format codes.
///
/// Supported: digit placeholders 0/#/?, decimal point, thousands grouping,
/// trailing-comma scaling (also before a literal: `#,##0,"K"`), percent,
/// scientific E+/E-, quoted literals, backslash escapes, underscore-space and
/// asterisk (treated as single space / ignored), @ text placeholder,
/// multi-section pos;neg;zero;text, conditional sections
/// (`[>=1000]0,"K";0`), color codes (stripped), and date/time tokens
/// (y/m/d/h/s, fractional seconds, AM/PM, elapsed [h] [m] [s]).
/// Numbers are rounded for display on their 15-significant-digit decimal
/// form, as Excel does (0.145 in `0%` is 15%), and never pass through a
/// fixed-width integer, so any magnitude renders exactly.
/// Unsupported (falls back to General): fraction formats (?/?).
public enum NumberFormatEngine {
    // MARK: General

    /// Excel-like "General" rendering of a number: whole numbers plain,
    /// up to ~10 significant digits, scientific notation for extreme magnitudes.
    public static func generalString(for n: Double) -> String {
        if n == 0 { return "0" }
        guard n.isFinite else { return CellError.num.rawValue }
        let absN = abs(n)
        if absN < 9.007199254740992e15, n == n.rounded(), absN < 1e15 {
            return String(Int64(n))
        }
        if absN >= 1e11 || absN < 1e-9 {
            return scientificString(n, mantissaDigits: 5)
        }
        let digitsBefore = max(1, Int(floor(log10(absN))) + 1)
        let decimals = max(0, 10 - digitsBefore)
        var s = String(format: "%.\(decimals)f", n)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    // MARK: Number -> text for round trips and coercion
    //
    // `generalString` is for the grid only (it keeps ~10 significant digits
    // to fit a cell). Text that is read back in -- formula constants, the
    // cell editor -- uses `roundTripString`; the text a number becomes in a
    // formula (`&`, text functions, criteria built with `&`) uses
    // `textCoercionString`, Excel's 15 significant digits.

    /// The shortest text that reads back as exactly `n`: plain decimal from
    /// 1E-9 up to 1E+15, otherwise scientific ("1.2345678901234567E+20").
    /// Both the formula lexer and `ValueParser` read it back exactly.
    public static func roundTripString(for n: Double) -> String {
        guard n.isFinite else { return CellError.num.rawValue }
        if n == 0 { return "0" }
        // Swift's description is the shortest representation that round-trips.
        guard let (digits, exponent) = decimalDigits(of: abs(n).description) else {
            return n.description
        }
        return (n < 0 ? "-" : "") + layOut(digits: digits, exponent: exponent)
    }

    /// Excel's number-to-text coercion: 15 significant digits, plain decimal
    /// from 1E-9 up to 1E+15, otherwise scientific ("1.23456789012346E+17").
    public static func textCoercionString(for n: Double) -> String {
        guard n.isFinite else { return CellError.num.rawValue }
        if n == 0 { return "0" }
        guard let (digits, exponent) = decimalDigits(of: String(format: "%.14e", abs(n))),
              digits != "0" else { return "0" }
        return (n < 0 ? "-" : "") + layOut(digits: digits, exponent: exponent)
    }

    /// Significant digits (no leading/trailing zeros) and the decimal
    /// exponent of the first one, from "123.45", "0.001", "1.5e-07" or
    /// "1.23400000000000e+05". Nil for anything else.
    static func decimalDigits(of text: String) -> (String, Int)? {
        let lower = text.lowercased()
        var mantissa = Substring(lower)
        var exp = 0
        if let e = lower.firstIndex(of: "e") {
            mantissa = lower[..<e]
            guard let x = Int(lower[lower.index(after: e)...]) else { return nil }
            exp = x
        }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = parts[0]
        let fracPart = parts.count == 2 ? parts[1] : ""
        let all = Array(intPart + fracPart)
        guard !all.isEmpty, all.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let firstNonZero = all.firstIndex(where: { $0 != "0" }) else { return ("0", 0) }
        var digits = String(all[firstNonZero...])
        while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast() }
        // The first significant digit sits at 10^(intPart.count - 1 - firstNonZero).
        return (digits, exp + intPart.count - 1 - firstNonZero)
    }

    /// Plain decimal for 1E-9 <= x < 1E+15, scientific (Excel style,
    /// two-digit exponent minimum) outside it.
    static func layOut(digits: String, exponent: Int) -> String {
        if exponent >= 15 || exponent < -9 {
            var s = String(digits.first!)
            if digits.count > 1 { s += "." + digits.dropFirst() }
            let magnitude = abs(exponent)
            return s + (exponent < 0 ? "E-" : "E+") + (magnitude < 10 ? "0" : "") + String(magnitude)
        }
        if exponent < 0 {
            return "0." + String(repeating: "0", count: -exponent - 1) + digits
        }
        let intCount = exponent + 1
        if digits.count <= intCount {
            return digits + String(repeating: "0", count: intCount - digits.count)
        }
        let split = digits.index(digits.startIndex, offsetBy: intCount)
        return String(digits[..<split]) + "." + String(digits[split...])
    }

    static func scientificString(_ n: Double, mantissaDigits: Int) -> String {
        var s = String(format: "%.\(mantissaDigits)E", n)
        // Trim trailing zeros in the mantissa: 1.00000E+21 -> 1E+21
        if let eIndex = s.firstIndex(of: "E") {
            var mantissa = String(s[s.startIndex..<eIndex])
            let exponent = String(s[eIndex...])
            if mantissa.contains(".") {
                while mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
            }
            s = mantissa + exponent
        }
        return s
    }

    // MARK: Public formatting entry point

    /// Format a cell value for display using the given format code.
    public static func displayString(for value: CellValue, format: NumberFormat) -> String {
        switch value {
        case .empty: return ""
        case .error(let e): return e.rawValue
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .string(let s):
            let secs = sections(of: format.code)
            if secs.count >= 4 {
                return renderTextSection(secs[3], text: s)
            }
            if secs.count == 1, secs[0].contains("@") {
                return renderTextSection(secs[0], text: s)
            }
            return s
        case .number(let n):
            return formatNumber(n, code: format.code)
        }
    }

    /// What a date/time format shows for a serial outside 0 ... 2958465
    /// (Excel fills the cell with #).
    public static let invalidDateDisplay = "#####"

    /// Format a number using a format code (General if empty).
    public static func formatNumber(_ n: Double, code: String) -> String {
        render(n, code: code) ?? invalidDateDisplay
    }

    /// TEXT(): like `formatNumber`, but a date format given a serial it
    /// cannot show is #VALUE!, as in Excel.
    static func formatForTEXT(_ n: Double, code: String) throws -> String {
        guard let text = render(n, code: code) else { throw CellError.value }
        return text
    }

    /// nil = a date/time section with an out-of-range serial.
    private static func render(_ n: Double, code: String) -> String? {
        guard n.isFinite else { return CellError.num.rawValue }
        let trimmedCode = code.trimmingCharacters(in: .whitespaces)
        if trimmedCode.isEmpty || trimmedCode.caseInsensitiveCompare("General") == .orderedSame {
            return generalString(for: n)
        }
        let secs = sections(of: code)
        let (index, useAbs) = sectionIndex(for: n, sections: secs)
        var section = stripBracketModifiers(secs[index])
        if section.isEmpty { return "" }
        if sectionIsDateTime(section) {
            return formatDateTime(n, section: section)
        }
        if isUnsupportedSection(section) {
            return generalString(for: n)
        }
        let value = useAbs ? abs(n) : n
        if section.caseInsensitiveCompare("General") == .orderedSame {
            return generalString(for: value)
        }
        section = renderNumericSection(section, value: value)
        return section.isEmpty ? "0" : section
    }

    /// Which section shows `n`, and whether it shows |n| (the section itself
    /// stands for "negative", so no minus sign).
    ///
    /// Without conditions: 1 section = all; 2 = (positive and zero) /
    /// negative; 3+ = positive / negative / zero.
    /// With conditions (`[>=1000]`) in the first two sections, Excel tests
    /// the first section's condition, then the second's; a number neither
    /// takes goes to the third section when both have conditions, else to the
    /// second. It keeps its minus sign unless the chosen section can only
    /// hold negative numbers: its own condition (`[<0]`, `[<=-1000]`,
    /// `[=-5]`), or for an unconditioned second section, the opposite of the
    /// first's (`[>=0]`, `[>-10]`). Checked against Excel for the web.
    static func sectionIndex(for n: Double, sections secs: [String]) -> (index: Int, useAbs: Bool) {
        let c1 = secs.count > 0 ? sectionCondition(secs[0]) : nil
        let c2 = secs.count > 1 ? sectionCondition(secs[1]) : nil
        guard c1 != nil || c2 != nil else {
            if secs.count == 1 || n > 0 || (n == 0 && secs.count < 3) { return (0, false) }
            if n < 0 { return (1, true) }
            return (2, false)
        }
        let index: Int
        if let c1, c1.holds(for: n) {
            index = 0
        } else if let c2, c2.holds(for: n) {
            index = 1
        } else if c1 != nil && c2 != nil {
            index = secs.count > 2 ? 2 : 0
        } else if c1 != nil {
            index = secs.count > 1 ? 1 : 0
        } else {
            index = 0
        }
        var useAbs = false
        if n < 0 {
            if index == 0, let c1 { useAbs = c1.isNegativeOnly }
            if index == 1 {
                useAbs = (c2?.isNegativeOnly ?? false)
                    || (c2 == nil && (c1?.complementIsNegativeOnly ?? false))
            }
        }
        return (index, useAbs)
    }

    /// A section's `[op value]` condition.
    struct SectionCondition: Equatable {
        let op: String
        let value: Double

        func holds(for n: Double) -> Bool {
            switch op {
            case "<": return n < value
            case "<=": return n <= value
            case ">": return n > value
            case ">=": return n >= value
            case "<>": return n != value
            default: return n == value
            }
        }

        /// True when only negative numbers (or zero, which has no sign)
        /// meet the condition: `[<0]`, `[<=0]`, `[<=-1000]`, `[=-5]`.
        var isNegativeOnly: Bool {
            switch op {
            case "<", "<=": return value <= 0
            case "=": return value < 0
            default: return false
            }
        }

        /// True when only negative numbers (or zero) fail the condition
        /// (`[>=0]`, `[>-10]`), so the section after it holds only negatives.
        var complementIsNegativeOnly: Bool {
            switch op {
            case ">=", ">": return value <= 0
            default: return false
            }
        }
    }

    /// The first `[op number]` bracket outside quotes, if any.
    static func sectionCondition(_ section: String) -> SectionCondition? {
        guard section.utf8.contains(UInt8(ascii: "[")) else { return nil }
        var inQuotes = false
        var i = section.startIndex
        while i < section.endIndex {
            let c = section[i]
            if c == "\"" { inQuotes.toggle() }
            if c == "\\" { i = section.index(after: i) }
            else if c == "[", !inQuotes, let close = section[i...].firstIndex(of: "]") {
                let inner = section[section.index(after: i)..<close].trimmingCharacters(in: .whitespaces)
                for op in ["<=", ">=", "<>", "<", ">", "="] where inner.hasPrefix(op) {
                    let operand = inner.dropFirst(op.count).trimmingCharacters(in: .whitespaces)
                    if let value = Double(operand), value.isFinite {
                        return SectionCondition(op: op, value: value)
                    }
                    break
                }
                i = close
            }
            if i < section.endIndex { i = section.index(after: i) }
        }
        return nil
    }

    // MARK: Sections

    /// Split a format code on ';' respecting quoted literals and backslash escapes.
    public static func sections(of code: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var chars = code.makeIterator()
        while let c = chars.next() {
            if c == "\"" { inQuotes.toggle(); current.append(c); continue }
            if c == "\\" { current.append(c); if let n = chars.next() { current.append(n) }; continue }
            if c == ";" && !inQuotes { result.append(current); current = ""; continue }
            current.append(c)
        }
        result.append(current)
        return result
    }

    /// Remove [Red]/[Color n]/[$...] and condition brackets, keeping elapsed [h]/[m]/[s].
    static func stripBracketModifiers(_ section: String) -> String {
        var out = ""
        var i = section.startIndex
        while i < section.endIndex {
            let c = section[i]
            if c == "\"" {
                // copy quoted literal wholesale
                out.append(c)
                i = section.index(after: i)
                while i < section.endIndex {
                    out.append(section[i])
                    if section[i] == "\"" { i = section.index(after: i); break }
                    i = section.index(after: i)
                }
                continue
            }
            if c == "[" {
                if let close = section[i...].firstIndex(of: "]") {
                    let inner = String(section[section.index(after: i)..<close])
                    let lower = inner.lowercased()
                    if lower.allSatisfy({ "hms".contains($0) }) && !inner.isEmpty {
                        // elapsed time token — keep
                        out.append(contentsOf: section[i...close])
                    } else if lower.hasPrefix("$") {
                        // currency/locale token like [$€-407]: keep the symbol part
                        let symbol = inner.dropFirst().split(separator: "-").first.map(String.init) ?? ""
                        if !symbol.isEmpty { out.append(contentsOf: "\"\(symbol)\"") }
                    }
                    // colors and conditions: dropped
                    i = section.index(after: close)
                    continue
                }
            }
            out.append(c)
            i = section.index(after: i)
        }
        return out
    }

    /// True if a section contains date/time tokens (outside quotes/escapes).
    public static func sectionIsDateTime(_ section: String) -> Bool {
        var inQuotes = false
        var i = section.startIndex
        while i < section.endIndex {
            let c = section[i]
            if c == "\"" { inQuotes.toggle(); i = section.index(after: i); continue }
            if c == "\\" { i = section.index(after: i); if i < section.endIndex { i = section.index(after: i) }; continue }
            if !inQuotes {
                let lower = Character(c.lowercased())
                if "ymdhs".contains(lower) {
                    // 's' could be part of a literal; but bare letters outside quotes
                    // are format tokens in Excel codes.
                    return true
                }
                if c == "A" || c == "a" {
                    // AM/PM marker
                    let rest = section[i...].uppercased()
                    if rest.hasPrefix("AM/PM") || rest.hasPrefix("A/P") { return true }
                }
                if c == "[" {
                    if let close = section[i...].firstIndex(of: "]") {
                        let inner = section[section.index(after: i)..<close].lowercased()
                        if !inner.isEmpty && inner.allSatisfy({ "hms".contains($0) }) { return true }
                        i = section.index(after: close)
                        continue
                    }
                }
            }
            i = section.index(after: i)
        }
        return false
    }

    static func isUnsupportedSection(_ section: String) -> Bool {
        // Fraction formats: '/' between digit placeholders.
        var inQuotes = false
        for c in section {
            if c == "\"" { inQuotes.toggle(); continue }
            if !inQuotes && c == "/" { return true }
        }
        return false
    }

    // MARK: Numeric section rendering

    private enum NumToken {
        case digit(Character)   // 0, #, ?
        case decimalPoint
        case literal(String)
        case percent
        case exponent(String)   // "E+" or "E-"
        case textPlaceholder
    }

    private static func tokenizeNumeric(_ section: String) -> (tokens: [NumToken], grouping: Bool, scaleCommas: Int, percentCount: Int) {
        var tokens: [NumToken] = []
        var grouping = false
        var scaleCommas = 0
        var percentCount = 0
        var i = section.startIndex
        var seenDigit = false
        var pendingCommas = 0

        // Commas after a digit placeholder that are not followed by another
        // placeholder scale by 1000 each, whatever comes next ("K", end).
        func flushCommasAsLiteral() {
            scaleCommas += pendingCommas
            pendingCommas = 0
        }

        while i < section.endIndex {
            let c = section[i]
            switch c {
            case "0", "#", "?":
                if pendingCommas > 0 {
                    // commas between digit placeholders enable grouping
                    grouping = true
                    pendingCommas = 0
                }
                seenDigit = true
                tokens.append(.digit(c))
                i = section.index(after: i)
            case ".":
                flushCommasAsLiteral()
                tokens.append(.decimalPoint)
                i = section.index(after: i)
            case ",":
                if seenDigit { pendingCommas += 1 }
                i = section.index(after: i)
            case "%":
                flushCommasAsLiteral()
                percentCount += 1
                tokens.append(.percent)
                i = section.index(after: i)
            case "E", "e":
                let next = section.index(after: i)
                if next < section.endIndex, section[next] == "+" || section[next] == "-" {
                    tokens.append(.exponent(String(c) + String(section[next])))
                    i = section.index(after: next)
                } else {
                    tokens.append(.literal(String(c)))
                    i = section.index(after: i)
                }
            case "\"":
                flushCommasAsLiteral()
                var literal = ""
                i = section.index(after: i)
                while i < section.endIndex, section[i] != "\"" {
                    literal.append(section[i])
                    i = section.index(after: i)
                }
                if i < section.endIndex { i = section.index(after: i) }
                tokens.append(.literal(literal))
            case "\\":
                flushCommasAsLiteral()
                i = section.index(after: i)
                if i < section.endIndex {
                    tokens.append(.literal(String(section[i])))
                    i = section.index(after: i)
                }
            case "_":
                // width-alignment: render as a space
                flushCommasAsLiteral()
                i = section.index(after: i)
                if i < section.endIndex { i = section.index(after: i) }
                tokens.append(.literal(" "))
            case "*":
                // repeat-fill: ignored (skip the fill char)
                flushCommasAsLiteral()
                i = section.index(after: i)
                if i < section.endIndex { i = section.index(after: i) }
            case "@":
                flushCommasAsLiteral()
                tokens.append(.textPlaceholder)
                i = section.index(after: i)
            default:
                flushCommasAsLiteral()
                tokens.append(.literal(String(c)))
                i = section.index(after: i)
            }
        }
        // trailing commas after the last digit placeholder scale by 1000 each
        scaleCommas += pendingCommas
        return (tokens, grouping, scaleCommas, percentCount)
    }

    static func renderNumericSection(_ section: String, value: Double) -> String {
        let (tokens, grouping, scaleCommas, percentCount) = tokenizeNumeric(section)

        // Count placeholders in integer / fraction / exponent zones.
        var intPlaceholders = 0
        var fracPlaceholders = 0
        var expPlaceholders = 0
        var zone = 0 // 0=int, 1=frac, 2=exp
        for t in tokens {
            switch t {
            case .decimalPoint: if zone == 0 { zone = 1 }
            case .exponent: zone = 2
            case .digit:
                if zone == 0 { intPlaceholders += 1 }
                else if zone == 1 { fracPlaceholders += 1 }
                else { expPlaceholders += 1 }
            default: break
            }
        }

        // |value| as decimal digits at Excel's 15 significant digits; percent
        // and comma scaling move the decimal point exactly.
        var decimal = DecimalDigits(value)
        decimal.shift(by: 2 * percentCount - 3 * scaleCommas)

        var exponentValue = 0
        let hasExponent = tokens.contains { if case .exponent = $0 { return true }; return false }
        if hasExponent, !decimal.isZero {
            // Normalize so the integer part has `intPlaceholders` digits.
            let targetDigits = max(1, intPlaceholders)
            // value = 0.d1d2... × 10^exponent, so d1 is the 10^(exponent-1) digit.
            exponentValue = decimal.exponent - targetDigits
            decimal.shift(by: -exponentValue)
            // Rounding can carry into a new digit: 9.999 -> 10.00E+00 is
            // 1.00E+01.
            if decimal.rounded(fractionDigits: fracPlaceholders).integerDigitCount > targetDigits {
                exponentValue += 1
                decimal.shift(by: -1)
            }
        }

        let negative = value < 0
        let rounded = decimal.rounded(fractionDigits: fracPlaceholders)
        var intDigits = rounded.integerString
        let fracDigits = rounded.fractionString(count: fracPlaceholders)
        // '#'-only integer zones drop a bare zero (0.5 with "#.##" -> ".5").
        let intZonePlaceholderChars: [Character] = {
            var chars: [Character] = []
            var z = 0
            for t in tokens {
                switch t {
                case .decimalPoint: if z == 0 { z = 1 }
                case .exponent: z = 2
                case .digit(let c): if z == 0 { chars.append(c) }
                default: break
                }
            }
            return chars
        }()
        if intDigits == "0" && (intPlaceholders == 0 || intZonePlaceholderChars.allSatisfy({ $0 == "#" })) {
            intDigits = ""
        }
        if grouping && !intDigits.isEmpty {
            intDigits = groupDigits(intDigits)
        }

        // Distribute the (possibly grouped) integer digit string over the
        // placeholder slots: the rightmost placeholders take one digit each and
        // the leftmost absorbs all overflow. Group separators travel with the
        // digit that FOLLOWS them.
        var chunks = [String](repeating: "", count: max(intPlaceholders, 1))
        do {
            let plainCount = intDigits.filter { $0.isNumber }.count
            let slots = max(intPlaceholders, 1)
            var ordinal = 0
            var pendingSeparator = ""
            for ch in intDigits {
                if ch.isNumber {
                    let slot = max(0, slots - (plainCount - ordinal))
                    chunks[slot] += pendingSeparator
                    chunks[slot].append(ch)
                    pendingSeparator = ""
                    ordinal += 1
                } else {
                    pendingSeparator.append(ch)
                }
            }
        }

        var out = ""
        var intSlotIndex = 0 // placeholders seen so far in the int zone
        var fracIndex = 0
        zone = 0

        func integerChunk(forSlot slot: Int) -> String {
            slot < chunks.count ? chunks[slot] : ""
        }

        for t in tokens {
            switch t {
            case .digit(let placeholder):
                if zone == 0 {
                    let chunk = integerChunk(forSlot: intSlotIndex)
                    if chunk.isEmpty {
                        switch placeholder {
                        case "0": out += "0"
                        case "?": out += " "
                        default: break
                        }
                    } else {
                        out += chunk
                    }
                    intSlotIndex += 1
                } else if zone == 1 {
                    if fracIndex < fracDigits.count {
                        let idx = fracDigits.index(fracDigits.startIndex, offsetBy: fracIndex)
                        let d = fracDigits[idx]
                        // trailing '#' suppresses trailing zeros
                        if d == "0" && placeholder == "#" {
                            let remaining = fracDigits[idx...]
                            if remaining.allSatisfy({ $0 == "0" }) {
                                fracIndex += 1
                                continue
                            }
                        }
                        if d == "0" && placeholder == "?" {
                            let remaining = fracDigits[idx...]
                            if remaining.allSatisfy({ $0 == "0" }) {
                                out += " "
                                fracIndex += 1
                                continue
                            }
                        }
                        out.append(d)
                        fracIndex += 1
                    } else if placeholder == "0" {
                        out += "0"
                    } else if placeholder == "?" {
                        out += " "
                    }
                } else {
                    // exponent digits handled when the exponent token is emitted
                    break
                }
            case .decimalPoint:
                if zone == 0 { zone = 1 }
                // omit the point if there are no fraction digits to show
                let willShowFrac: Bool
                if fracPlaceholders == 0 {
                    willShowFrac = false
                } else if fracDigits.allSatisfy({ $0 == "0" }) {
                    // shown only if any frac placeholder is '0'
                    willShowFrac = section.contains(".0")
                } else {
                    willShowFrac = true
                }
                if willShowFrac { out += "." }
            case .literal(let s):
                out += s
            case .percent:
                out += "%"
            case .exponent(let e):
                zone = 2
                out += String(e.first!)
                if exponentValue < 0 {
                    out += "-"
                } else if e.hasSuffix("+") {
                    out += "+"
                }
                var expStr = String(abs(exponentValue))
                if expStr.count < expPlaceholders {
                    expStr = String(repeating: "0", count: expPlaceholders - expStr.count) + expStr
                }
                out += expStr
                // digits already emitted; skip remaining digit tokens in exp zone
            case .textPlaceholder:
                out += generalString(for: value)
            }
        }
        // Excel and Sheets put the minus sign in front of the whole rendered
        // section, literals included: "$#,##0.00" shows -14.62 as "-$14.62"
        // (not "$-14.62"), and 0.00" kg" shows "-5.00 kg".
        if negative {
            out = "-" + out
        }
        return out
    }

    static func groupDigits(_ digits: String) -> String {
        var out = ""
        let chars = Array(digits)
        for (i, c) in chars.enumerated() {
            out.append(c)
            let remaining = chars.count - i - 1
            if remaining > 0 && remaining % 3 == 0 { out.append(",") }
        }
        return out
    }

    // MARK: Text section

    static func renderTextSection(_ section: String, text: String) -> String {
        let stripped = stripBracketModifiers(section)
        var out = ""
        var i = stripped.startIndex
        while i < stripped.endIndex {
            let c = stripped[i]
            switch c {
            case "@":
                out += text
                i = stripped.index(after: i)
            case "\"":
                i = stripped.index(after: i)
                while i < stripped.endIndex, stripped[i] != "\"" {
                    out.append(stripped[i])
                    i = stripped.index(after: i)
                }
                if i < stripped.endIndex { i = stripped.index(after: i) }
            case "\\":
                i = stripped.index(after: i)
                if i < stripped.endIndex { out.append(stripped[i]); i = stripped.index(after: i) }
            case "_":
                i = stripped.index(after: i)
                if i < stripped.endIndex { i = stripped.index(after: i) }
                out += " "
            case "*":
                i = stripped.index(after: i)
                if i < stripped.endIndex { i = stripped.index(after: i) }
            default:
                out.append(c)
                i = stripped.index(after: i)
            }
        }
        return out
    }

    // MARK: Date/time rendering

    static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Render a date/time section; nil when the serial is outside the date
    /// range (Excel shows #####, TEXT returns #VALUE!).
    ///
    /// The time is rounded ONCE, to the precision the section shows (whole
    /// seconds, or tenths/hundredths/thousandths with `ss.0`...), and every
    /// part — date, h/m/s and elapsed [h]/[m]/[s] — comes from that rounded
    /// value. So 12:00:59.6 shows 12:01:00 (not 12:00:60) and 7:12 - 0:12,
    /// a hair under 7 hours in binary, shows [h]:mm 7:00.
    static func formatDateTime(_ serial: Double, section: String) -> String? {
        guard ExcelDate.isValidSerial(serial) else { return nil }
        let subsecondDigits = subsecondPrecision(of: section)
        let unitsPerSecond = pow(10.0, Double(subsecondDigits))
        // Whole units (seconds or fractions of one) since serial 0; < 2^53.
        let totalUnits = (serial * 86400 * unitsPerSecond).rounded()
        let unitsPerDay = 86400 * unitsPerSecond
        let wholeDays = (totalUnits / unitsPerDay).rounded(.down)
        guard let dateComps = ExcelDate.components(fromSerial: wholeDays),
              let unitOfDay = checkedInt(totalUnits - wholeDays * unitsPerDay),
              let unitsPerSecondInt = checkedInt(unitsPerSecond) else { return nil }
        let secondOfDay = unitOfDay / unitsPerSecondInt
        let subsecondUnits = unitOfDay % unitsPerSecondInt
        let hour24 = secondOfDay / 3600
        let minuteOfHour = (secondOfDay % 3600) / 60
        let secondOfMinute = secondOfDay % 60
        let totalSeconds = (totalUnits / unitsPerSecond).rounded(.down)

        let hasAMPM: Bool = {
            let upper = section.uppercased()
            return upper.contains("AM/PM") || upper.contains("A/P")
        }()

        var out = ""
        var i = section.startIndex
        var lastDateToken: Character = " " // tracks h/s adjacency for month-vs-minute

        // Pre-scan for token runs
        func run(of char: Character, from index: String.Index) -> (count: Int, next: String.Index) {
            var count = 0
            var j = index
            while j < section.endIndex, Character(section[j].lowercased()) == char {
                count += 1
                j = section.index(after: j)
            }
            return (count, j)
        }

        // Determine for each m-run whether it means minutes: minutes if the previous
        // date token was h, or the next date token is s.
        func nextDateTokenAfter(_ index: String.Index) -> Character {
            var j = index
            var inQuotes = false
            while j < section.endIndex {
                let c = section[j]
                if c == "\"" { inQuotes.toggle() }
                if !inQuotes {
                    let lower = Character(c.lowercased())
                    if "ymdhs".contains(lower) { return lower }
                }
                j = section.index(after: j)
            }
            return " "
        }

        func whole(_ x: Double) -> String {
            checkedInt(x).map(String.init) ?? ""
        }

        while i < section.endIndex {
            let c = section[i]
            let lower = Character(c.lowercased())
            switch lower {
            case "\"":
                i = section.index(after: i)
                while i < section.endIndex, section[i] != "\"" {
                    out.append(section[i])
                    i = section.index(after: i)
                }
                if i < section.endIndex { i = section.index(after: i) }
            case "\\":
                i = section.index(after: i)
                if i < section.endIndex { out.append(section[i]); i = section.index(after: i) }
            case "[":
                // elapsed token
                guard let close = section[i...].firstIndex(of: "]") else {
                    i = section.index(after: i); continue
                }
                let inner = section[section.index(after: i)..<close].lowercased()
                let digits: String
                if inner.hasPrefix("h") {
                    digits = whole((totalSeconds / 3600).rounded(.down))
                } else if inner.hasPrefix("m") {
                    digits = whole((totalSeconds / 60).rounded(.down))
                } else if inner.hasPrefix("s") {
                    digits = whole(totalSeconds)
                } else {
                    digits = ""
                }
                // [hh], [mm]: at least that many digits.
                out += String(repeating: "0", count: max(0, inner.count - digits.count)) + digits
                lastDateToken = inner.first ?? " "
                i = section.index(after: close)
            case "y":
                let (count, next) = run(of: "y", from: i)
                out += count <= 2 ? String(format: "%02d", dateComps.year % 100) : String(dateComps.year)
                lastDateToken = "y"
                i = next
            case "m":
                let (count, next) = run(of: "m", from: i)
                let isMinutes = lastDateToken == "h" || nextDateTokenAfter(next) == "s"
                if isMinutes {
                    out += count >= 2 ? String(format: "%02d", minuteOfHour) : String(minuteOfHour)
                    lastDateToken = "m"
                } else {
                    let name = monthNames[dateComps.month - 1]
                    switch count {
                    case 1: out += String(dateComps.month)
                    case 2: out += String(format: "%02d", dateComps.month)
                    case 3: out += String(name.prefix(3))
                    case 5: out += String(name.prefix(1))
                    default: out += name
                    }
                    lastDateToken = "M"
                }
                i = next
            case "d":
                let (count, next) = run(of: "d", from: i)
                switch count {
                case 1: out += String(dateComps.day)
                case 2: out += String(format: "%02d", dateComps.day)
                case 3: out += String(dayNames[dateComps.weekday - 1].prefix(3))
                default: out += dayNames[dateComps.weekday - 1]
                }
                lastDateToken = "d"
                i = next
            case "h":
                let (count, next) = run(of: "h", from: i)
                var hour = hour24
                if hasAMPM {
                    hour = hour % 12
                    if hour == 0 { hour = 12 }
                }
                out += count >= 2 ? String(format: "%02d", hour) : String(hour)
                lastDateToken = "h"
                i = next
            case "s":
                let (count, next) = run(of: "s", from: i)
                out += count >= 2 ? String(format: "%02d", secondOfMinute) : String(secondOfMinute)
                i = next
                // Fractional seconds: "ss.0", "ss.00", "ss.000".
                if i < section.endIndex, section[i] == "." {
                    let zerosStart = section.index(after: i)
                    let (zeros, afterZeros) = run(of: "0", from: zerosStart)
                    if zeros > 0 {
                        let digits = String(format: "%0\(subsecondDigits)ld", subsecondUnits)
                        out += "." + String(digits.prefix(zeros))
                            + String(repeating: "0", count: max(0, zeros - digits.count))
                        i = afterZeros
                    }
                }
                lastDateToken = "s"
            case "a":
                let upper = section[i...].uppercased()
                if upper.hasPrefix("AM/PM") {
                    out += hour24 < 12 ? "AM" : "PM"
                    i = section.index(i, offsetBy: 5)
                } else if upper.hasPrefix("A/P") {
                    let isUpper = section[i] == "A"
                    out += (hour24 < 12) ? (isUpper ? "A" : "a") : (isUpper ? "P" : "p")
                    i = section.index(i, offsetBy: 3)
                } else {
                    out.append(c)
                    i = section.index(after: i)
                }
            case "_":
                i = section.index(after: i)
                if i < section.endIndex { i = section.index(after: i) }
                out += " "
            case "*":
                i = section.index(after: i)
                if i < section.endIndex { i = section.index(after: i) }
            default:
                out.append(c)
                i = section.index(after: i)
            }
        }
        return out
    }

    /// Fraction-of-a-second digits a section shows: the most 0s after an
    /// `s.` (capped at 3, as in Excel), else 0.
    static func subsecondPrecision(of section: String) -> Int {
        let chars = Array(section.lowercased())
        var best = 0
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { inQuotes.toggle() }
            if !inQuotes, c == "s", i + 1 < chars.count, chars[i + 1] == "." {
                var j = i + 2
                while j < chars.count, chars[j] == "0" { j += 1 }
                best = max(best, min(3, j - i - 2))
            }
            i += 1
        }
        return best
    }
}

// MARK: - Decimal places

extension NumberFormat {
    /// The toolbar's Increase/Decrease Decimal: add (`delta > 0`) or remove
    /// (`delta < 0`) one decimal place in every numeric section, as Excel
    /// does. Returns nil when nothing changes (General, text, date/time, or
    /// no decimals left to remove).
    public func adjustingDecimals(by delta: Int) -> NumberFormat? {
        guard delta != 0, !isGeneral, !isTextFormat else { return nil }
        var changed = false
        let sections = NumberFormatEngine.sections(of: code).map { section -> String in
            guard !NumberFormatEngine.sectionIsDateTime(section),
                  let adjusted = Self.adjustDecimals(in: section, increase: delta > 0)
            else { return section }
            changed = true
            return adjusted
        }
        return changed ? NumberFormat(code: sections.joined(separator: ";")) : nil
    }

    /// Adjust the first number in one section, skipping quoted literals,
    /// escapes, [modifiers] and the `_x` / `*x` padding pairs.
    private static func adjustDecimals(in section: String, increase: Bool) -> String? {
        var chars = Array(section)
        let placeholders: Set<Character> = ["0", "#", "?"]
        var intEnd: Int?      // index just past the integer digits
        var dot: Int?
        var fracEnd: Int?     // index just past the fraction digits
        var inInteger = false
        var i = 0
        scan: while i < chars.count {
            let c = chars[i]
            let isLiteral = c == "\"" || c == "\\" || c == "[" || c == "_" || c == "*"
            if dot != nil {
                if !placeholders.contains(c) { fracEnd = i; break scan }
            } else if inInteger {
                if c == "." { dot = i }
                else if isLiteral || !(placeholders.contains(c) || c == ",") { intEnd = i; break scan }
            } else if placeholders.contains(c) {
                inInteger = true
            } else if c == ".", i + 1 < chars.count, placeholders.contains(chars[i + 1]) {
                dot = i
            } else if isLiteral {
                switch c {
                case "\"":
                    i += 1
                    while i < chars.count, chars[i] != "\"" { i += 1 }
                case "[":
                    while i < chars.count, chars[i] != "]" { i += 1 }
                default:
                    i += 1 // the escaped / padding character
                }
            }
            i += 1
        }
        if dot != nil, fracEnd == nil { fracEnd = chars.count }
        if inInteger, dot == nil, intEnd == nil { intEnd = chars.count }

        if let dot, let fracEnd {
            let digits = fracEnd - dot - 1
            if increase {
                chars.insert("0", at: fracEnd)
            } else if digits <= 1 {
                chars.removeSubrange(dot..<fracEnd)
            } else {
                chars.remove(at: fracEnd - 1)
            }
            return String(chars)
        }
        guard increase, var intEnd else { return nil }
        // Trailing commas scale by thousands; the decimals go before them.
        while intEnd > 0, chars[intEnd - 1] == "," { intEnd -= 1 }
        chars.insert(contentsOf: ".0", at: intEnd)
        return String(chars)
    }
}
