import Foundation

/// A spreadsheet error value, matching the standard Excel/Google Sheets error set.
public enum CellError: String, Equatable, Hashable, Sendable, CaseIterable, Codable {
    case div0 = "#DIV/0!"
    case value = "#VALUE!"
    case ref = "#REF!"
    case name = "#NAME?"
    case na = "#N/A"
    case num = "#NUM!"
    case null = "#NULL!"
    /// Not a standard Excel error on disk; used for circular references.
    /// Serialized to XLSX as #REF! (Google Sheets does the same).
    case circular = "#CYCLE!"
    /// Formula parse error (Google Sheets' #ERROR!); the formula text is kept.
    case parse = "#ERROR!"

    /// The representation written to XLSX files (t="e" cells).
    public var xlsxRepresentation: String {
        switch self {
        case .circular: return CellError.ref.rawValue
        case .parse: return CellError.name.rawValue
        default: return rawValue
        }
    }

    /// ERROR.TYPE code (Sheets/Excel convention).
    public var errorTypeCode: Int {
        switch self {
        case .null: return 1
        case .div0: return 2
        case .value: return 3
        case .ref, .circular: return 4
        case .name: return 5
        case .num: return 6
        case .na: return 7
        case .parse: return 8
        }
    }

    /// Parse an error literal as it appears in a formula or file.
    public static func parse(_ text: String) -> CellError? {
        let upper = text.uppercased()
        return CellError.allCases.first { $0.rawValue == upper }
    }
}

/// The computed value of a cell.
public enum CellValue: Equatable, Hashable, Sendable {
    case empty
    case number(Double)
    case string(String)
    case bool(Bool)
    case error(CellError)

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var errorValue: CellError? {
        if case .error(let e) = self { return e }
        return nil
    }

    /// Raw textual form with no number-format applied (General rendering for numbers).
    public var rawDisplayString: String {
        switch self {
        case .empty: return ""
        case .number(let n): return NumberFormatEngine.generalString(for: n)
        case .string(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e.rawValue
        }
    }
}
