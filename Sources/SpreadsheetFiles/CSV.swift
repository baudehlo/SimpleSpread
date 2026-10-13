import Foundation
import SpreadsheetCore

/// CSV parsing, sniffing, import, and export.
///
/// Parser: RFC 4180 plus real-world tolerance — CRLF/LF/CR records, ""
/// escaping, embedded newlines in quoted fields, stray quotes in unquoted
/// fields, ragged rows, unterminated final quote (fail-soft).
public enum CSV {
    // MARK: Decoding

    /// Decode CSV bytes: honor BOMs, then UTF-8, with any bytes that are not
    /// valid UTF-8 read as CP1252 (real-world "Latin-1" uses 0x80-0x9F for
    /// €/curly quotes). Only the bad bytes are: one stray CP1252 byte must
    /// not turn every correct "é" in the file into "Ã©".
    public static func decode(data: Data) -> String {
        if data.count >= 3, data[data.startIndex] == 0xEF, data[data.startIndex + 1] == 0xBB,
           data[data.startIndex + 2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? fallbackDecode(data.dropFirst(3))
        }
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if b0 == 0xFF, b1 == 0xFE {
                return String(data: data, encoding: .utf16LittleEndian).map {
                    $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0
                } ?? ""
            }
            if b0 == 0xFE, b1 == 0xFF {
                return String(data: data, encoding: .utf16BigEndian).map {
                    $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0
                } ?? ""
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return fallbackDecode(data)
    }

    private static func fallbackDecode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let repaired = bytes.withUnsafeBufferPointer { repairingUTF8($0) }
        return String(decoding: repaired, as: UTF8.self)
    }

    /// The bytes as valid UTF-8: well-formed UTF-8 sequences are kept, and
    /// every other byte is read as CP1252 (bytes CP1252 leaves undefined as
    /// Latin-1).
    static func repairingUTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 2)
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b < 0x80 { out.append(b); i += 1; continue }
            let length = utf8SequenceLength(bytes, at: i)
            if length > 0 {
                out.append(contentsOf: bytes[i..<(i + length)])
                i += length
            } else {
                let scalar = Unicode.Scalar(cp1252HighHalf[Int(b - 0x80)])!
                out.append(contentsOf: String(scalar).utf8)
                i += 1
            }
        }
        return out
    }

    /// Length of the well-formed UTF-8 sequence starting at `i` (a non-ASCII
    /// lead byte), or 0 when there is none.
    static func utf8SequenceLength(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> Int {
        let length: Int
        var low: UInt8 = 0x80, high: UInt8 = 0xBF
        switch bytes[i] {
        case 0xC2...0xDF: length = 2
        case 0xE0: length = 3; low = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED: length = 3; high = 0x9F
        case 0xF0: length = 4; low = 0x90
        case 0xF1...0xF3: length = 4
        case 0xF4: length = 4; high = 0x8F
        default: return 0
        }
        guard i + length <= bytes.count, bytes[i + 1] >= low, bytes[i + 1] <= high else { return 0 }
        for k in 2..<max(2, length) where bytes[i + k] & 0xC0 != 0x80 { return 0 }
        return length
    }

    /// CP1252 for 0x80...0xFF (the five bytes it leaves undefined map to
    /// the same C1 code points, as Latin-1 does).
    private static let cp1252HighHalf: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ] + (0xA0...0xFF).map { UInt32($0) }

    // MARK: Parsing

    /// Parse CSV text into rows of fields. Quote-aware state machine; never
    /// line-split-then-delimiter-split.
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var atFieldStart = true

        let chars = Array(text)
        var i = 0

        func endField() {
            row.append(field)
            field = ""
            atFieldStart = true
            fieldWasQuoted = false
        }

        func endRecord() {
            endField()
            rows.append(row)
            row = []
        }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.append(c)
                i += 1
                continue
            }
            switch c {
            case "\"":
                if atFieldStart {
                    inQuotes = true
                    fieldWasQuoted = true
                    atFieldStart = false
                } else {
                    // Stray quote mid-field (RFC violation): literal.
                    field.append(c)
                }
                i += 1
            case delimiter:
                endField()
                i += 1
            case "\r\n": // Swift groups CRLF into ONE Character (grapheme cluster)
                endRecord()
                i += 1
            case "\r":
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 2 } else { i += 1 }
                endRecord()
            case "\n":
                endRecord()
                i += 1
            default:
                if atFieldStart && fieldWasQuoted {
                    // trailing junk after closing quote: tolerate whitespace
                    if c == " " || c == "\t" { i += 1; continue }
                }
                field.append(c)
                atFieldStart = false
                i += 1
            }
        }
        // Final record (no trailing newline) — but a file ending in newline
        // must not yield a trailing empty record.
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted {
            endRecord()
        }
        return rows
    }

    // MARK: Delimiter sniffing

    /// Detect the delimiter by parsing a prefix with each candidate and
    /// scoring column-count consistency (beats raw frequency counting).
    public static func sniffDelimiter(in text: String, candidates: [Character] = [",", ";", "\t", "|"]) -> Character {
        let sample = String(text.prefix(64 * 1024))
        var bestDelimiter: Character = ","
        var bestScore = -1.0
        for candidate in candidates {
            let rows = parse(sample, delimiter: candidate).prefix(100)
            guard rows.count > 0 else { continue }
            let counts = rows.map(\.count)
            let mean = Double(counts.reduce(0, +)) / Double(counts.count)
            guard mean > 1 else { continue }
            let variance = counts.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
                / Double(counts.count)
            // Consistent (low variance) multi-column parses win; more columns
            // break ties.
            let score = 1000.0 / (1.0 + variance) + mean
            if score > bestScore {
                bestScore = score
                bestDelimiter = candidate
            }
        }
        return bestDelimiter
    }

    // MARK: Import

    public struct ImportResult {
        public let sheet: Sheet
        public let rowCount: Int
        public let columnCount: Int
        public let delimiter: Character
    }

    /// Import CSV bytes into a new Sheet (values only; "=..." fields become
    /// literal text — CSV is data, never live formulas).
    public static func importCSV(
        data: Data, delimiter: Character? = nil, sheetName: String = "Sheet1",
        referenceDate: Date = Date()
    ) -> ImportResult {
        let text = decode(data: data)
        let d = delimiter ?? sniffDelimiter(in: text)
        let rows = parse(text, delimiter: d)
        let sheet = Sheet(id: 1, name: sheetName)
        var maxColumns = 0
        // Semicolon-delimited files usually pair with decimal commas.
        let decimalComma = (d == ";")
        for (r, row) in rows.enumerated() {
            maxColumns = max(maxColumns, row.count)
            for (c, rawField) in row.enumerated() {
                var fieldText = rawField
                if decimalComma, isDecimalCommaNumber(fieldText) {
                    fieldText = fieldText.replacingOccurrences(of: ",", with: ".")
                }
                let parsed = ValueParser.parse(fieldText, allowFormulas: false,
                                               referenceDate: referenceDate)
                guard !parsed.value.isEmpty else { continue }
                sheet.setCell(Cell(value: parsed.value), at: CellAddress(row: r, column: c))
            }
        }
        return ImportResult(sheet: sheet, rowCount: rows.count,
                            columnCount: maxColumns, delimiter: d)
    }

    /// Import into a Workbook, applying inferred formats (dates, percents).
    /// See the fast byte-level version in CSVFastImport.swift.
    public static func importWorkbook(
        data: Data, delimiter: Character? = nil, sheetName: String = "Sheet1",
        referenceDate: Date = Date()
    ) -> Workbook {
        var report = CSVImportReport()
        return importWorkbook(data: data, delimiter: delimiter, sheetName: sheetName,
                              referenceDate: referenceDate, report: &report)
    }

    /// The original String-based import, kept as the reference the fast
    /// importer is tested against.
    static func referenceImportWorkbook(
        data: Data, delimiter: Character? = nil, sheetName: String = "Sheet1",
        referenceDate: Date = Date()
    ) -> Workbook {
        let text = decode(data: data)
        let d = delimiter ?? sniffDelimiter(in: text)
        let rows = parse(text, delimiter: d)
        let workbook = Workbook()
        let sheet = workbook.addSheet(named: sheetName)
        let decimalComma = (d == ";")
        for (r, row) in rows.enumerated() {
            for (c, rawField) in row.enumerated() {
                var fieldText = rawField
                if decimalComma, isDecimalCommaNumber(fieldText) {
                    fieldText = fieldText.replacingOccurrences(of: ",", with: ".")
                }
                let parsed = ValueParser.parse(fieldText, allowFormulas: false,
                                               referenceDate: referenceDate)
                guard !parsed.value.isEmpty else { continue }
                var cell = Cell(value: parsed.value)
                if let format = parsed.suggestedFormat {
                    var style = CellStyle()
                    style.numberFormat = format
                    cell.styleIndex = workbook.styles.index(for: style)
                }
                sheet.setCell(cell, at: CellAddress(row: r, column: c))
            }
        }
        return workbook
    }

    static func isDecimalCommaNumber(_ s: String) -> Bool {
        // -1234,56 (exactly one comma, digits either side)
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        var intPart = parts[0]
        if intPart.hasPrefix("-") || intPart.hasPrefix("+") { intPart = intPart.dropFirst() }
        return !intPart.isEmpty && intPart.allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber)
    }

    // MARK: Export

    public struct ExportOptions: Sendable {
        public var delimiter: Character
        public var lineEnding: String
        public var includeBOM: Bool
        /// Numbers exported machine-canonical (full precision, '.' decimal);
        /// dates exported ISO 8601. When false, the cell's display string is
        /// exported instead.
        public var machineReadable: Bool

        public init(delimiter: Character = ",", lineEnding: String = "\r\n",
                    includeBOM: Bool = true, machineReadable: Bool = true) {
            self.delimiter = delimiter
            self.lineEnding = lineEnding
            self.includeBOM = includeBOM
            self.machineReadable = machineReadable
        }
    }

    /// Export a sheet's computed values as CSV bytes.
    public static func export(sheet: Sheet, workbook: Workbook,
                              options: ExportOptions = ExportOptions()) -> Data {
        var out = ""
        if let used = sheet.usedRange {
            let range = CellRange(start: CellAddress(row: 0, column: 0), end: used.end)
            for r in range.start.row...range.end.row {
                var fields: [String] = []
                for c in range.start.column...range.end.column {
                    let addr = CellAddress(row: r, column: c)
                    let cell = sheet.cell(at: addr)
                    let style = workbook.style(at: cell.styleIndex)
                    fields.append(exportField(value: cell.value, style: style, options: options))
                }
                out += fields.map { quoteField($0, delimiter: options.delimiter) }
                    .joined(separator: String(options.delimiter))
                out += options.lineEnding
            }
        }
        var data = Data()
        if options.includeBOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(Data(out.utf8))
        return data
    }

    static func exportField(value: CellValue, style: CellStyle, options: ExportOptions) -> String {
        switch value {
        case .empty:
            return ""
        case .string(let s):
            return s
        case .bool(let b):
            return b ? "TRUE" : "FALSE"
        case .error(let e):
            return e.rawValue
        case .number(let n):
            if options.machineReadable {
                if style.numberFormat.isDateTime {
                    return isoDateString(serial: n)
                }
                return XLSXWriter.serialNumberString(n)
            }
            return NumberFormatEngine.displayString(for: value, format: style.numberFormat)
        }
    }

    static func isoDateString(serial: Double) -> String {
        guard let comps = ExcelDate.components(fromSerial: serial) else {
            return XLSXWriter.serialNumberString(serial)
        }
        let hasTime = serial.truncatingRemainder(dividingBy: 1) != 0
        let datePart = String(format: "%04d-%02d-%02d", comps.year, comps.month, comps.day)
        if serial < 1 {
            // pure time value
            return String(format: "%02d:%02d:%02d", comps.hour, comps.minute, Int(comps.second.rounded()))
        }
        if hasTime {
            return datePart + String(format: "T%02d:%02d:%02d", comps.hour, comps.minute, Int(comps.second.rounded()))
        }
        return datePart
    }

    static func quoteField(_ field: String, delimiter: Character) -> String {
        let needsQuoting = field.contains(delimiter) || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
