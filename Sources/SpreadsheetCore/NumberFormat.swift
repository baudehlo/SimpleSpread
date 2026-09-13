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
/// trailing-comma scaling, percent, scientific E+/E-, quoted literals,
/// backslash escapes, underscore-space and asterisk (treated as single space /
/// ignored), @ text placeholder, multi-section pos;neg;zero;text, color codes
/// (stripped), and date/time tokens (y/m/d/h/s, AM/PM, elapsed [h] [m] [s]).
/// Unsupported (falls back to General): fraction formats (?/?), conditional
/// sections ([>100]).
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

    /// Format a number using a format code (General if empty).
    public static func formatNumber(_ n: Double, code: String) -> String {
        guard n.isFinite else { return CellError.num.rawValue }
        let trimmedCode = code.trimmingCharacters(in: .whitespaces)
        if trimmedCode.isEmpty || trimmedCode.caseInsensitiveCompare("General") == .orderedSame {
            return generalString(for: n)
        }
        let secs = sections(of: code)
        // Section selection: 1 = all; 2 = pos+zero / neg; 3 = pos / neg / zero.
        var section: String
        var useAbs = false
        if secs.count == 1 {
            section = secs[0]
        } else if n > 0 || (n == 0 && secs.count < 3) {
            section = secs[0]
        } else if n < 0 {
            section = secs[1]
            useAbs = true
        } else {
            section = secs[2]
        }
        section = stripBracketModifiers(section)
        if section.isEmpty { return "" }
        if sectionIsDateTime(section) {
            return formatDateTime(n, section: section)
        }
        if isUnsupportedSection(section) {
            return generalString(for: n)
        }
        if section.caseInsensitiveCompare("General") == .orderedSame {
            return generalString(for: useAbs ? abs(n) : n)
        }
        var rendered = renderNumericSection(section, value: useAbs ? abs(n) : n)
        // One-section formats show negatives with a leading minus unless the
        // pattern handles sign itself.
        if secs.count == 1, n < 0, !rendered.hasPrefix("-") {
            // renderNumericSection works on the signed value; nothing to add here.
        }
        if rendered.isEmpty { rendered = "0" }
        return rendered
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

        func flushCommasAsLiteral() {
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
        scaleCommas = pendingCommas
        return (tokens, grouping, scaleCommas, percentCount)
    }

    static func renderNumericSection(_ section: String, value: Double) -> String {
        let (tokens, grouping, scaleCommas, percentCount) = tokenizeNumeric(section)

        var n = value
        for _ in 0..<percentCount { n *= 100 }
        for _ in 0..<scaleCommas { n /= 1000 }

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

        var exponentValue = 0
        var mantissa = n
        let hasExponent = tokens.contains { if case .exponent = $0 { return true }; return false }
        if hasExponent {
            if mantissa != 0 {
                // Normalize so the integer part has `intPlaceholders` digits.
                let targetDigits = max(1, intPlaceholders)
                let magnitude = Int(floor(log10(abs(mantissa))))
                exponentValue = magnitude - (targetDigits - 1)
                // Round exponent to a multiple of targetDigits for engineering-style ##0.0E+0
                mantissa = mantissa / pow(10, Double(exponentValue))
            }
        }

        let negative = mantissa < 0 || (mantissa == 0 && n < 0)
        var absValue = abs(mantissa)

        // Round to the fraction placeholder count.
        let factor = pow(10.0, Double(fracPlaceholders))
        absValue = (absValue * factor).rounded() / factor

        var intDigits = String(Int64(min(absValue.rounded(.down), 9.2e18)))
        let fracValue = absValue - absValue.rounded(.down)
        var fracDigits = ""
        if fracPlaceholders > 0 {
            let scaled = (fracValue * factor).rounded()
            fracDigits = String(Int64(scaled))
            if fracDigits.count < fracPlaceholders {
                fracDigits = String(repeating: "0", count: fracPlaceholders - fracDigits.count) + fracDigits
            } else if fracDigits.count > fracPlaceholders {
                // carry occurred (e.g. 0.999 -> "1000"); bump integer part
                intDigits = String((Int64(intDigits) ?? 0) + 1)
                fracDigits = String(repeating: "0", count: fracPlaceholders)
            }
        }
        if intDigits == "0" && intPlaceholders == 0 {
            intDigits = ""
        }
        if grouping && !intDigits.isEmpty {
            intDigits = groupDigits(intDigits)
        }

        // Distribute integer digits over placeholders right-to-left; the leftmost
        // placeholder absorbs all overflow digits.
        var out = ""
        var intSlotIndex = 0 // counts placeholders seen so far in the int zone
        var fracIndex = 0
        zone = 0
        var emittedSign = false

        func integerChunk(forSlot slot: Int) -> String {
            // slot is 0-based from the left among intPlaceholders slots.
            // Digits (with group separators embedded) are assigned from the right:
            // last slot gets last digit char (skipping separator ownership rules:
            // separators attach to the digit on their right's chunk boundary).
            // Simplest correct approach: compute how many raw digit chars belong
            // to slots to the right of this one, then take the remainder.
            let plainCount = intDigits.filter { $0.isNumber }.count
            let slotsRightOfThis = intPlaceholders - slot - 1
            let digitsFromRight = min(plainCount, slotsRightOfThis)
            let digitsForThisSlot: Int
            if slot == 0 {
                digitsForThisSlot = max(0, plainCount - (intPlaceholders - 1))
            } else {
                digitsForThisSlot = plainCount - digitsFromRight >= 1 && slotsRightOfThis < plainCount ? 1 : 0
            }
            // Build chunk by walking intDigits from the left, tracking digit ordinal.
            var startOrdinal = 0
            if slot == 0 {
                startOrdinal = 0
            } else {
                startOrdinal = max(0, plainCount - (intPlaceholders - slot))
            }
            let endOrdinal = startOrdinal + digitsForThisSlot
            var chunk = ""
            var ordinal = 0
            for ch in intDigits {
                if ch.isNumber {
                    if ordinal >= startOrdinal && ordinal < endOrdinal { chunk.append(ch) }
                    ordinal += 1
                } else {
                    // group separator: include if the NEXT digit belongs to this chunk
                    if ordinal >= startOrdinal && ordinal < endOrdinal && ordinal != startOrdinal { chunk.append(ch) }
                    else if ordinal == startOrdinal && ordinal > 0 && ordinal < endOrdinal && slot == 0 { /* leading separator dropped */ }
                    else if ordinal > startOrdinal && ordinal < endOrdinal { chunk.append(ch) }
                }
            }
            return chunk
        }

        for t in tokens {
            switch t {
            case .digit(let placeholder):
                if zone == 0 {
                    if !emittedSign && negative { out += "-"; emittedSign = true }
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
                if !emittedSign && negative && zone == 0 && intSlotIndex == 0 && !s.trimmingCharacters(in: .whitespaces).isEmpty && s != "(" {
                    // sign goes before the first digits, after leading currency symbols
                }
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
        // If pattern had no digit placeholders at all but is numeric, append General.
        if intPlaceholders == 0 && fracPlaceholders == 0 && !tokens.contains(where: { if case .textPlaceholder = $0 { return true }; return false }) {
            if negative && !emittedSign { out = "-" + out }
            return out + generalString(for: abs(value))
        }
        if negative && !emittedSign && intPlaceholders == 0 {
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

    static func formatDateTime(_ serial: Double, section: String) -> String {
        guard serial >= -694324, let comps = ExcelDate.components(fromSerial: serial) else {
            // Excel shows ##### for negative date serials; we surface the raw number.
            return generalString(for: serial)
        }
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
                let totalSeconds = serial * 86400
                if inner.hasPrefix("h") {
                    out += String(Int((totalSeconds / 3600).rounded(.down)))
                } else if inner.hasPrefix("m") {
                    out += String(Int((totalSeconds / 60).rounded(.down)))
                } else if inner.hasPrefix("s") {
                    out += String(Int(totalSeconds.rounded(.down)))
                }
                lastDateToken = inner.first ?? " "
                i = section.index(after: close)
            case "y":
                let (count, next) = run(of: "y", from: i)
                out += count <= 2 ? String(format: "%02d", comps.year % 100) : String(comps.year)
                lastDateToken = "y"
                i = next
            case "m":
                let (count, next) = run(of: "m", from: i)
                let isMinutes = lastDateToken == "h" || nextDateTokenAfter(next) == "s"
                if isMinutes {
                    out += count >= 2 ? String(format: "%02d", comps.minute) : String(comps.minute)
                    lastDateToken = "m"
                } else {
                    switch count {
                    case 1: out += String(comps.month)
                    case 2: out += String(format: "%02d", comps.month)
                    case 3: out += String(monthNames[comps.month - 1].prefix(3))
                    case 5: out += String(monthNames[comps.month - 1].prefix(1))
                    default: out += monthNames[comps.month - 1]
                    }
                    lastDateToken = "M"
                }
                i = next
            case "d":
                let (count, next) = run(of: "d", from: i)
                switch count {
                case 1: out += String(comps.day)
                case 2: out += String(format: "%02d", comps.day)
                case 3: out += String(dayNames[comps.weekday - 1].prefix(3))
                default: out += dayNames[comps.weekday - 1]
                }
                lastDateToken = "d"
                i = next
            case "h":
                let (count, next) = run(of: "h", from: i)
                var hour = comps.hour
                if hasAMPM {
                    hour = hour % 12
                    if hour == 0 { hour = 12 }
                }
                out += count >= 2 ? String(format: "%02d", hour) : String(hour)
                lastDateToken = "h"
                i = next
            case "s":
                let (count, next) = run(of: "s", from: i)
                let sec = Int(comps.second.rounded())
                out += count >= 2 ? String(format: "%02d", sec) : String(sec)
                lastDateToken = "s"
                i = next
            case "a":
                let upper = section[i...].uppercased()
                if upper.hasPrefix("AM/PM") {
                    out += comps.hour < 12 ? "AM" : "PM"
                    i = section.index(i, offsetBy: 5)
                } else if upper.hasPrefix("A/P") {
                    let isUpper = section[i] == "A"
                    out += (comps.hour < 12) ? (isUpper ? "A" : "a") : (isUpper ? "P" : "p")
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
}
