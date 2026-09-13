import Foundation

/// The result of interpreting raw user/import input for a cell.
public struct ParsedInput: Equatable, Sendable {
    /// Stored value (for formulas, the placeholder value before calculation).
    public var value: CellValue
    /// Formula text without '=' if the input was a formula.
    public var formulaText: String?
    /// A number format the input implies ("5%" -> percent), nil = leave as-is.
    public var suggestedFormat: NumberFormat?
}

/// One shared parsing pipeline for typed entry, paste, and CSV import
/// (en-US conventions: '.' decimal, ',' grouping, M/D date order).
public enum ValueParser {
    /// Interpret raw input text.
    ///
    /// - Parameters:
    ///   - allowFormulas: false for CSV/paste import (CSV-injection defense:
    ///     "=..." imports as literal text).
    ///   - textFormat: true when the target cell has the Plain Text format,
    ///     which suppresses ALL inference including formulas.
    ///   - referenceDate: "today" used for year-less dates (injectable for tests).
    public static func parse(
        _ input: String,
        allowFormulas: Bool = true,
        textFormat: Bool = false,
        referenceDate: Date = Date()
    ) -> ParsedInput {
        if textFormat {
            return ParsedInput(value: input.isEmpty ? .empty : .string(input),
                               formulaText: nil, suggestedFormat: nil)
        }
        if input.isEmpty {
            return ParsedInput(value: .empty, formulaText: nil, suggestedFormat: nil)
        }
        if input.hasPrefix("'") {
            // Leading apostrophe forces text (apostrophe not displayed).
            return ParsedInput(value: .string(String(input.dropFirst())),
                               formulaText: nil, suggestedFormat: nil)
        }
        if allowFormulas, input.hasPrefix("="), input.count > 1 {
            return ParsedInput(value: .number(0), formulaText: String(input.dropFirst()),
                               suggestedFormat: nil)
        }
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Booleans
        if trimmed.caseInsensitiveCompare("TRUE") == .orderedSame {
            return ParsedInput(value: .bool(true), formulaText: nil, suggestedFormat: nil)
        }
        if trimmed.caseInsensitiveCompare("FALSE") == .orderedSame {
            return ParsedInput(value: .bool(false), formulaText: nil, suggestedFormat: nil)
        }

        // Error literals ("#N/A" typed or re-imported)
        if trimmed.hasPrefix("#"), let err = CellError.parse(trimmed) {
            return ParsedInput(value: .error(err), formulaText: nil, suggestedFormat: nil)
        }

        // Percent
        if trimmed.hasSuffix("%") {
            let body = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            if let n = parsePlainNumber(body), !shouldPreserveAsText(body) {
                let format: NumberFormat = body.contains(".") ? .percent : .percentInteger
                return ParsedInput(value: .number(n / 100), formulaText: nil,
                                   suggestedFormat: format)
            }
        }

        // Currency
        if trimmed.hasPrefix("$") || trimmed.hasPrefix("-$") {
            var body = trimmed
            var negative = false
            if body.hasPrefix("-") { negative = true; body = String(body.dropFirst()) }
            body = String(body.dropFirst()) // "$"
            if let n = parsePlainNumber(body), !shouldPreserveAsText(body) {
                return ParsedInput(value: .number(negative ? -n : n), formulaText: nil,
                                   suggestedFormat: .currency)
            }
        }

        // Plain number (with leading-zero / precision preservation rules)
        if let n = parsePlainNumber(trimmed) {
            if shouldPreserveAsText(trimmed) {
                return ParsedInput(value: .string(input), formulaText: nil, suggestedFormat: nil)
            }
            return ParsedInput(value: .number(n), formulaText: nil, suggestedFormat: nil)
        }

        // Date / time / datetime
        if let (serial, format) = parseDateTimeText(trimmed, referenceDate: referenceDate) {
            return ParsedInput(value: .number(serial), formulaText: nil, suggestedFormat: format)
        }

        return ParsedInput(value: .string(input), formulaText: nil, suggestedFormat: nil)
    }

    /// Leading-zero ("00501") and long-digit-string (credit card) protection:
    /// number inference is refused when re-rendering would lose information.
    static func shouldPreserveAsText(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: ",", with: "")
        // Digit-only strings with a leading zero (and >1 digit) stay text.
        if stripped.count > 1, stripped.hasPrefix("0"), !stripped.contains("."),
           stripped.allSatisfy({ $0.isNumber }) {
            return true
        }
        // >15 significant digits would silently lose precision.
        let digits = stripped.filter { $0.isNumber }
        if digits.count > 15, !stripped.lowercased().contains("e") {
            return true
        }
        return false
    }

    /// Strict en-US number: optional sign, digits with optional ',' grouping,
    /// optional decimal, optional exponent.
    public static func parsePlainNumber(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        var body = s
        var negative = false
        if body.hasPrefix("-") { negative = true; body = String(body.dropFirst()) }
        else if body.hasPrefix("+") { body = String(body.dropFirst()) }
        guard !body.isEmpty else { return nil }
        // Validate grouping if commas present: 1,234,567.8
        if body.contains(",") {
            let intPart = body.split(separator: ".", maxSplits: 1)[0]
            let groups = intPart.split(separator: ",", omittingEmptySubsequences: false)
            guard groups.count > 1,
                  let first = groups.first, first.count >= 1, first.count <= 3,
                  !first.isEmpty,
                  groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }),
                  first.allSatisfy(\.isNumber) else { return nil }
            body = body.replacingOccurrences(of: ",", with: "")
        }
        guard let value = Coerce.strictDouble(body) else { return nil }
        return negative ? -value : value
    }

    // MARK: Date & time text parsing

    /// Serial for date-ish text: date, datetime, or time-only. VALUE() semantics.
    public static func parseSerialNumber(from s: String, referenceDate: Date = Date()) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let n = parsePlainNumber(trimmed) { return n }
        if trimmed.hasSuffix("%"),
           let n = parsePlainNumber(String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)) {
            return n / 100
        }
        if trimmed.hasPrefix("$"), let n = parsePlainNumber(String(trimmed.dropFirst())) {
            return n
        }
        if let (serial, _) = parseDateTimeText(trimmed, referenceDate: referenceDate) {
            return serial
        }
        return nil
    }

    /// Date (and optional time) text -> serial.
    public static func parseDateText(_ s: String, referenceDate: Date = Date()) -> Double? {
        guard let (serial, format) = parseDateTimeText(s, referenceDate: referenceDate),
              format.isDateTime || format.code.contains("y") || format.code.contains("d") else {
            return nil
        }
        return serial
    }

    /// Time-only text -> day fraction.
    public static func parseTimeText(_ s: String) -> Double? {
        parseTimeComponents(s.trimmingCharacters(in: .whitespaces))
    }

    /// Full date/time inference. Returns serial + the display format to apply.
    static func parseDateTimeText(_ s: String, referenceDate: Date) -> (Double, NumberFormat)? {
        // Split off a trailing time component if present.
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Time-only first ("3:45", "3:45:10 PM").
        if let frac = parseTimeComponents(trimmed) {
            return (frac, .time)
        }

        // Try to split "date time" on whitespace boundaries from the right.
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for splitIndex in stride(from: parts.count, through: 1, by: -1) {
            let datePart = parts[0..<splitIndex].joined(separator: " ")
            let timePart = parts[splitIndex...].joined(separator: " ")
            guard let dateSerial = parseDateOnly(datePart, referenceDate: referenceDate) else {
                continue
            }
            if timePart.isEmpty {
                return (dateSerial, .date)
            }
            if let frac = parseTimeComponents(timePart) {
                return (dateSerial + frac, .dateTime)
            }
        }
        return nil
    }

    static let monthNamesLookup: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, name) in NumberFormatEngine.monthNames.enumerated() {
            map[name.lowercased()] = i + 1
            map[String(name.prefix(3)).lowercased()] = i + 1
        }
        return map
    }()

    static func parseDateOnly(_ s: String, referenceDate: Date) -> Double? {
        let currentYear = Calendar.current.component(.year, from: referenceDate)

        func makeSerial(year: Int, month: Int, day: Int) -> Double? {
            guard month >= 1, month <= 12, day >= 1,
                  day <= ExcelDate.daysInMonth(year: year, month: month),
                  year >= 1900, year <= 9999 else { return nil }
            return ExcelDate.serial(year: year, month: month, day: day)
        }

        func normalizeYear(_ y: Int) -> Int {
            if y < 30 { return 2000 + y }
            if y < 100 { return 1900 + y }
            return y
        }

        // ISO / slashed numeric forms
        let numericSeparators = CharacterSet(charactersIn: "/-.")
        let comps = s.components(separatedBy: numericSeparators)
        if comps.count == 3, comps.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let a = Int(comps[0])!, b = Int(comps[1])!, c = Int(comps[2])!
            if comps[0].count == 4 {
                // yyyy-M-d
                return makeSerial(year: a, month: b, day: c)
            }
            // M/d/yyyy or M/d/yy
            return makeSerial(year: normalizeYear(c), month: a, day: b)
        }
        if comps.count == 2, comps.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
           s.contains("/") {
            // M/d (current year)
            let a = Int(comps[0])!, b = Int(comps[1])!
            return makeSerial(year: currentYear, month: a, day: b)
        }

        // Month-name forms: "Jan 2, 2025" / "January 2 2025" / "2 Jan 2025" / "2-Jan-2025"
        let cleaned = s.replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: " -"))
            .filter { !$0.isEmpty }
        if cleaned.count == 2 || cleaned.count == 3 {
            var month: Int?
            var day: Int?
            var year: Int?
            for token in cleaned {
                if let m = monthNamesLookup[token.lowercased()] {
                    guard month == nil else { return nil }
                    month = m
                } else if token.allSatisfy(\.isNumber) {
                    let n = Int(token)!
                    if token.count == 4 || n > 31 {
                        guard year == nil else { return nil }
                        year = n
                    } else if day == nil {
                        day = n
                    } else if year == nil {
                        year = normalizeYear(n)
                    } else {
                        return nil
                    }
                } else {
                    return nil
                }
            }
            if let m = month, let d = day {
                return makeSerial(year: year ?? currentYear, month: m, day: d)
            }
        }
        return nil
    }

    static func parseTimeComponents(_ s: String) -> Double? {
        var body = s.trimmingCharacters(in: .whitespaces)
        var meridiem: Int? // 0 = AM, 1 = PM
        let upper = body.uppercased()
        for (suffix, m) in [("AM", 0), ("PM", 1), ("A", 0), ("P", 1)] {
            if upper.hasSuffix(suffix) {
                meridiem = m
                body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        var second = 0.0
        if parts.count == 3 {
            guard let sec = Double(parts[2]), sec >= 0, sec < 60 else { return nil }
            second = sec
        }
        guard hour >= 0, minute >= 0, minute < 60 else { return nil }
        var h = hour
        if let m = meridiem {
            guard hour >= 1, hour <= 12 else { return nil }
            h = hour % 12 + (m == 1 ? 12 : 0)
        } else {
            guard hour < 24 else { return nil }
        }
        return ExcelDate.timeFraction(hour: h, minute: minute, second: second)
    }
}
