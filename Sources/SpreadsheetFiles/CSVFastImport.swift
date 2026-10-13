import Foundation
import SpreadsheetCore

/// What a CSV import did: how much it read and whether it stopped early.
public struct CSVImportReport: Sendable, Equatable {
    /// Records read (one per sheet row).
    public var rows = 0
    public var columns = 0
    /// True when the file had more rows than a sheet holds (1,048,576, as in
    /// Excel), or more columns (16,384); the rest was not loaded.
    public var truncated = false
    /// True when `progress` asked to stop.
    public var cancelled = false
    public var delimiter: Character = ","

    public init() {}
}

extension CSV {
    /// Fast import: scans UTF-8 bytes directly (no `[Character]` copy of the
    /// file) and turns common fields (plain numbers, ISO dates, text with no
    /// digits, TRUE/FALSE) into values without the general parser. Results
    /// match `ValueParser` exactly; anything unusual goes through it.
    ///
    /// - Parameters:
    ///   - maxRows: rows to load before stopping (Excel's sheet limit).
    ///   - progress: called with the fraction read so far; return false to cancel.
    public static func importWorkbook(
        data: Data, delimiter: Character? = nil, sheetName: String = "Sheet1",
        referenceDate: Date = Date(), maxRows: Int = CellAddress.maxRows,
        report: inout CSVImportReport, progress: ((Double) -> Bool)? = nil
    ) -> Workbook {
        // UTF-8 is checked as the scan goes, so a huge file that stops at the
        // row limit is never read to the end. Bytes that aren't UTF-8 mean
        // the file is CP1252 (or similar): start again, transcoded.
        var invalidUTF8 = false
        let workbook = importWorkbook(data: data, delimiter: delimiter, sheetName: sheetName,
                                      referenceDate: referenceDate, maxRows: maxRows, report: &report,
                                      progress: progress, validating: true, invalidUTF8: &invalidUTF8)
        guard invalidUTF8 else { return workbook }
        report = CSVImportReport()
        let transcoded = Data(decode(data: data).utf8)
        var unused = false
        return importWorkbook(data: transcoded, delimiter: delimiter, sheetName: sheetName,
                              referenceDate: referenceDate, maxRows: maxRows, report: &report,
                              progress: progress, validating: false, invalidUTF8: &unused)
    }

    private static func importWorkbook(
        data: Data, delimiter: Character?, sheetName: String, referenceDate: Date, maxRows: Int,
        report: inout CSVImportReport, progress: ((Double) -> Bool)?,
        validating: Bool, invalidUTF8: inout Bool
    ) -> Workbook {
        let workbook = Workbook()
        let sheet = workbook.addSheet(named: sheetName)
        withUTF8Bytes(of: data) { bytes in
            let d = delimiter ?? sniffDelimiter(in: String(decoding: UnsafeBufferPointer(rebasing: bytes.prefix(64 * 1024)), as: UTF8.self))
            report.delimiter = d
            guard let delimiterByte = d.asciiValue else { return }
            var importer = FieldImporter(workbook: workbook, sheet: sheet,
                                         decimalComma: d == ";", referenceDate: referenceDate)
            let total = max(1, bytes.count)
            var reserved = false
            var validatedUpTo = 0
            /// Check the bytes up to `end` (backed off to a character start).
            func validate(upTo end: Int) -> Bool {
                guard validating, end > validatedUpTo else { return true }
                var stop = min(end, bytes.count)
                if stop < bytes.count {
                    var back = 0
                    while back < 3, stop > validatedUpTo, bytes[stop] & 0xC0 == 0x80 { stop -= 1; back += 1 }
                }
                let chunk = UnsafeBufferPointer(rebasing: bytes[validatedUpTo..<stop])
                guard isValidUTF8(chunk) else { invalidUTF8 = true; return false }
                validatedUpTo = stop
                return true
            }
            let result = scanRecords(bytes, delimiter: delimiterByte, maxRecords: maxRows,
                                     shouldContinue: { offset, records in
                // Validate a little ahead of the scan.
                guard validate(upTo: offset + 512 * 1024) else { return false }
                // Size the cell table once the first rows show how dense it is.
                // Rows are projected from the bytes read, capped at the limit.
                if !reserved, records >= 2000, offset > 0 {
                    reserved = true
                    let rows = min(Double(records) / Double(offset) * Double(total), Double(maxRows))
                    let cellsPerRow = Double(sheet.cells.count) / Double(records)
                    sheet.reserveCellCapacity(Int(rows * cellsPerRow * 1.05))
                }
                return progress?(Double(offset) / Double(total)) ?? true
            }) { row, column, field in
                importer.add(field, row: row, column: column)
            }
            // The rest of what was scanned (all of it when the scan finished).
            if !result.cancelled, !invalidUTF8 {
                _ = validate(upTo: result.stoppedAtLimit ? result.endOffset : bytes.count)
            }
            if invalidUTF8 { return }
            report.rows = result.records
            report.columns = result.maxColumns
            report.truncated = result.stoppedAtLimit || result.maxColumns > CellAddress.maxColumns
            report.cancelled = result.cancelled
        }
        return workbook
    }

    // MARK: Bytes

    /// Run `body` over the file's bytes: a UTF-8 BOM is skipped and UTF-16
    /// is transcoded. The caller validates the UTF-8 as it goes.
    static func withUTF8Bytes<R>(of data: Data, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        func transcoded(_ text: String) -> R {
            var utf8 = Array(text.utf8)
            return utf8.withUnsafeMutableBufferPointer { body(UnsafeBufferPointer($0)) }
        }
        let count = data.count
        if count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                return transcoded(decode(data: data))
            }
        }
        return data.withUnsafeBytes { raw in
            var bytes = raw.bindMemory(to: UInt8.self)
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
                bytes = UnsafeBufferPointer(rebasing: bytes[3...])
            }
            return body(bytes)
        }
    }

    /// UTF-8 validation (structure, overlongs, surrogates, range), with an
    /// ASCII fast path eight bytes at a time.
    static func isValidUTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        let n = bytes.count
        var i = 0
        while i < n {
            if i + 8 <= n {
                let word = UnsafeRawPointer(base + i).loadUnaligned(as: UInt64.self)
                if word & 0x8080_8080_8080_8080 == 0 { i += 8; continue }
            }
            let b = base[i]
            if b < 0x80 { i += 1; continue }
            let length: Int
            var low: UInt8 = 0x80, high: UInt8 = 0xBF
            switch b {
            case 0xC2...0xDF: length = 2
            case 0xE0: length = 3; low = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: length = 3
            case 0xED: length = 3; high = 0x9F
            case 0xF0: length = 4; low = 0x90
            case 0xF1...0xF3: length = 4
            case 0xF4: length = 4; high = 0x8F
            default: return false
            }
            guard i + length <= n else { return false }
            let second = base[i + 1]
            guard second >= low, second <= high else { return false }
            for k in 2..<max(2, length) where base[i + k] & 0xC0 != 0x80 { return false }
            i += length
        }
        return true
    }

    // MARK: Scanning

    struct ScanResult {
        var records = 0
        var maxColumns = 0
        var stoppedAtLimit = false
        var cancelled = false
        /// Where scanning stopped.
        var endOffset = 0
    }

    /// The byte-level twin of `parse(_:delimiter:)`, with identical rules
    /// (quotes, `""` escapes, CR/LF/CRLF, ragged rows, a quote mid-field is
    /// literal, text after a closing quote is kept). Calls `field` for every
    /// field, empty ones included. `shouldContinue(byteOffset, records)` is
    /// asked every ~256 KB.
    static func scanRecords(_ bytes: UnsafeBufferPointer<UInt8>, delimiter: UInt8, maxRecords: Int,
                            shouldContinue: (Int, Int) -> Bool,
                            field: (_ row: Int, _ column: Int, _ text: UnsafeBufferPointer<UInt8>) -> Void) -> ScanResult {
        var result = ScanResult()
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return result }
        let n = bytes.count
        let quote: UInt8 = 0x22, cr: UInt8 = 0x0D, lf: UInt8 = 0x0A
        var row = 0, column = 0
        var scratch: [UInt8] = []
        scratch.reserveCapacity(256)
        var i = 0
        var nextCheck = 0

        func emit(_ start: Int, _ end: Int) {
            field(row, column, UnsafeBufferPointer(start: base + start, count: end - start))
            column += 1
        }
        func emitScratch() {
            scratch.withUnsafeBufferPointer { field(row, column, $0) }
            column += 1
        }
        /// Ends a record; false when the row limit is reached.
        func endRecord() -> Bool {
            result.maxColumns = max(result.maxColumns, column)
            row += 1
            column = 0
            result.records = row
            if row >= maxRecords {
                // Only a cut when something follows the last row read.
                result.stoppedAtLimit = i < n
                result.endOffset = i
                return false
            }
            return true
        }

        scan: while i < n {
            if i >= nextCheck {
                nextCheck = i + 256 * 1024
                if !shouldContinue(i, row) { result.cancelled = true; return result }
            }
            if base[i] == quote {
                // Quoted field: content up to the closing quote (with ""
                // escapes), then any literal text until the delimiter.
                scratch.removeAll(keepingCapacity: true)
                i += 1
                var closed = false
                while i < n {
                    let c = base[i]
                    if c == quote {
                        if i + 1 < n, base[i + 1] == quote { scratch.append(quote); i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    scratch.append(c)
                    i += 1
                }
                if closed {
                    while i < n {
                        let c = base[i]
                        if c == delimiter || c == lf || c == cr { break }
                        scratch.append(c)
                        i += 1
                    }
                }
                emitScratch()
            } else {
                let start = i
                while i < n {
                    let c = base[i]
                    if c == delimiter || c == lf || c == cr { break }
                    i += 1
                }
                emit(start, i)
            }
            // After a field: a delimiter, a record end, or the end of input.
            guard i < n else { break scan }
            let c = base[i]
            if c == delimiter {
                i += 1
                if i == n {
                    // Trailing delimiter: one more (empty) field ends the input.
                    emit(i, i)
                }
                continue
            }
            i += (c == cr && i + 1 < n && base[i + 1] == lf) ? 2 : 1
            if !endRecord() { return result }
        }
        // The final record when the input does not end with a line break.
        if column > 0 {
            _ = endRecord()
        }
        return result
    }
}

// MARK: - Field values

/// Turns scanned fields into cells, using fast paths for the common shapes
/// and `ValueParser` for the rest.
struct FieldImporter {
    let workbook: Workbook
    let sheet: Sheet
    let decimalComma: Bool
    let referenceDate: Date
    private var styleForFormat: [NumberFormat: Int] = [:]

    init(workbook: Workbook, sheet: Sheet, decimalComma: Bool, referenceDate: Date) {
        self.workbook = workbook
        self.sheet = sheet
        self.decimalComma = decimalComma
        self.referenceDate = referenceDate
    }

    mutating func add(_ field: UnsafeBufferPointer<UInt8>, row: Int, column: Int) {
        guard !field.isEmpty, column < CellAddress.maxColumns else { return }
        let address = CellAddress(row: row, column: column)
        if let fast = FastFieldValue.classify(field) {
            switch fast {
            case .number(let n):
                sheet.setCell(Cell(value: .number(n)), at: address)
            case .bool(let b):
                sheet.setCell(Cell(value: .bool(b)), at: address)
            case .text:
                sheet.setCell(Cell(value: .string(String(decoding: field, as: UTF8.self))), at: address)
            case .isoDate(let serial):
                sheet.setCell(Cell(value: .number(serial), styleIndex: styleIndex(for: .date)), at: address)
            }
            return
        }
        var text = String(decoding: field, as: UTF8.self)
        if decimalComma, CSV.isDecimalCommaNumber(text) {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        let parsed = ValueParser.parse(text, allowFormulas: false, referenceDate: referenceDate)
        guard !parsed.value.isEmpty else { return }
        var cell = Cell(value: parsed.value)
        if let format = parsed.suggestedFormat { cell.styleIndex = styleIndex(for: format) }
        sheet.setCell(cell, at: address)
    }

    private mutating func styleIndex(for format: NumberFormat) -> Int {
        if let index = styleForFormat[format] { return index }
        var style = CellStyle()
        style.numberFormat = format
        let index = workbook.styles.index(for: style)
        styleForFormat[format] = index
        return index
    }
}

/// The field shapes that skip `ValueParser`, each giving exactly the value
/// it would. Nil means "use ValueParser".
enum FastFieldValue: Equatable {
    case number(Double)
    case bool(Bool)
    /// Text, as ValueParser would keep it (see `classify`).
    case text
    /// yyyy-m-d (ValueParser's ISO date, shown with the Date format).
    case isoDate(Double)

    private static let powersOfTen: [Double] = (0...22).map { pow(10, Double($0)) }

    static func classify(_ f: UnsafeBufferPointer<UInt8>) -> FastFieldValue? {
        let n = f.count
        guard n > 0 else { return nil }
        let first = f[0]

        // Plain decimal number: [+-]digits[.digits], at most 15 digits.
        if let number = plainNumber(f) { return number }

        // yyyy-m-d
        if n >= 8, n <= 10, let serial = isoDate(f) { return .isoDate(serial) }

        // Text and booleans: nothing ValueParser trims or treats specially
        // at either end.
        guard first != 0x27, first != 0x23, first != 0x20, first != 0x09,
              f[n - 1] != 0x20, f[n - 1] != 0x09, f[n - 1] != 0x25 else { return nil }
        if n == 4, matchesUppercased(f, "TRUE") { return .bool(true) }
        if n == 5, matchesUppercased(f, "FALSE") { return .bool(false) }
        // ASCII with no digits can't be a number, date or time.
        if !f.contains(where: { $0 >= 0x80 || ($0 >= 0x30 && $0 <= 0x39) }) { return .text }
        // Nor can text that opens with a word that isn't a month name: dates
        // start with a digit or a month, numbers and times with a digit.
        if isLetter(first) {
            var end = 1
            while end < n, isLetter(f[end]) { end += 1 }
            let word = String(decoding: UnsafeBufferPointer(rebasing: f[0..<end]), as: UTF8.self).lowercased()
            if ValueParser.monthNamesLookup[word] == nil { return .text }
        }
        return nil
    }

    private static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func matchesUppercased(_ f: UnsafeBufferPointer<UInt8>, _ word: StaticString) -> Bool {
        let w = word.utf8Start
        for k in 0..<f.count {
            var b = f[k]
            if b >= 0x61 && b <= 0x7A { b -= 0x20 }
            if b != w[k] { return false }
        }
        return true
    }

    /// Exactly ValueParser's result for a plain number: the decimal value
    /// correctly rounded (an exact integer of up to 15 digits divided by an
    /// exact power of ten rounds once, as strtod does). Digit strings with a
    /// leading zero stay text there, so they are left to it.
    private static func plainNumber(_ f: UnsafeBufferPointer<UInt8>) -> FastFieldValue? {
        let n = f.count
        var i = 0
        var negative = false
        if f[0] == 0x2D { negative = true; i = 1 } else if f[0] == 0x2B { i = 1 }
        guard i < n, f[i] >= 0x30, f[i] <= 0x39 else { return nil }
        var mantissa: UInt64 = 0
        var digits = 0
        var fraction = 0
        var sawDot = false
        while i < n {
            let b = f[i]
            if b >= 0x30 && b <= 0x39 {
                mantissa = mantissa &* 10 &+ UInt64(b - 0x30)
                digits += 1
                if sawDot { fraction += 1 }
            } else if b == 0x2E, !sawDot, i + 1 < n {
                sawDot = true
            } else {
                return nil
            }
            i += 1
        }
        // ValueParser keeps unsigned digit strings with a leading zero
        // ("00501") or more than 15 digits (card numbers) as text.
        let unsignedInteger = !sawDot && f[0] != 0x2D && f[0] != 0x2B
        if unsignedInteger, (f[0] == 0x30 && n > 1) || digits > 15 { return .text }
        guard digits <= 15 else { return nil }
        var value = Double(mantissa)
        if fraction > 0 { value /= powersOfTen[fraction] }
        return .number(negative ? -value : value)
    }

    private static func isoDate(_ f: UnsafeBufferPointer<UInt8>) -> Double? {
        // dddd-d{1,2}-d{1,2}
        func digit(_ k: Int) -> Int? {
            let b = f[k]
            return (b >= 0x30 && b <= 0x39) ? Int(b - 0x30) : nil
        }
        guard f.count >= 8, let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3),
              f[4] == 0x2D else { return nil }
        var k = 5
        func number() -> Int? {
            guard k < f.count, let first = digit(k) else { return nil }
            var value = first
            k += 1
            if k < f.count, let second = digit(k) { value = value * 10 + second; k += 1 }
            return value
        }
        guard let month = number(), k < f.count, f[k] == 0x2D else { return nil }
        k += 1
        guard let day = number(), k == f.count else { return nil }
        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        guard year >= 1900, year <= 9999, month >= 1, month <= 12, day >= 1,
              day <= ExcelDate.daysInMonth(year: year, month: month) else { return nil }
        return ExcelDate.serial(year: year, month: month, day: day)
    }
}
