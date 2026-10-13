import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("Fast CSV import")
struct CSVFastImportTests {
    /// Scan with the byte scanner, collected like `CSV.parse`.
    func scanned(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var bytes = Array(text.utf8)
        bytes.withUnsafeMutableBufferPointer { buffer in
            _ = CSV.scanRecords(UnsafeBufferPointer(buffer), delimiter: delimiter.asciiValue!, maxRecords: .max,
                                shouldContinue: { _, _ in true }) { row, _, field in
                while rows.count <= row { rows.append([]) }
                rows[row].append(String(decoding: field, as: UTF8.self))
            }
        }
        return rows
    }

    let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)

    func cells(_ wb: Workbook) -> [CellAddress: (CellValue, NumberFormat)] {
        var out: [CellAddress: (CellValue, NumberFormat)] = [:]
        for (addr, cell) in wb.sheets[0].cells {
            out[addr] = (cell.value, wb.style(at: cell.styleIndex).numberFormat)
        }
        return out
    }

    func expectSameImport(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let data = Data(text.utf8)
        let fast = cells(CSV.importWorkbook(data: data, referenceDate: referenceDate))
        let slow = cells(CSV.referenceImportWorkbook(data: data, referenceDate: referenceDate))
        #expect(fast.count == slow.count, "cell count for \(text.debugDescription)", sourceLocation: sourceLocation)
        for (addr, (value, format)) in slow {
            let mine = fast[addr]
            #expect(mine?.0 == value && mine?.1 == format,
                    "\(addr.a1) in \(text.debugDescription): \(String(describing: mine)) vs \(value), \(format.code)",
                    sourceLocation: sourceLocation)
        }
    }

    @Test func scannerMatchesTheReferenceParserOnRandomInput() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["a", "b", ",", ",", "\"", "\"\"", "\n", "\r", "\r\n", " ", "1", "x y", "é", ";", "\t"]
        for _ in 0..<3000 {
            let length = Int.random(in: 0...14, using: &rng)
            let text = (0..<length).map { _ in pieces.randomElement(using: &rng)! }.joined()
            #expect(scanned(text) == CSV.parse(text), "\(text.debugDescription)")
        }
    }

    @Test func importMatchesTheReferenceOnTrickyFields() {
        let fields = ["12", "-3.5", "+4", "0", "00", "007", "-007", "00000123", "+007", "12345678901234567890", "0000000000000001", "0.50", "000.5", "1.", ".5", "1e5", "1E-3",
                      "1,234", "1,234.5", "12,34", "123456789012345", "1234567890123456", "3.14159265358979",
                      "TRUE", "false", "True", " TRUE", "TRUE ", "#N/A", "#DIV/0!", "'007", "50%", "5.5%", "abc%",
                      "$5", "-$5.25", "$", "-", "+", "2026-01-05", "2026-1-5", "2026-02-30", "1899-12-31",
                      "2026-001-05", "1/2/2026", "Jan 5", "Jan ²", "5 Jan 2026", "3:45", "3:45 PM",
                      "2026-01-05 10:30", "hello", "hello world", "  padded  ", "tab\there", "x²", "½",
                      "=SUM(A1)", "=1+1", "\u{00A0}5", "Ünïcode", "Order 12, batch 3", "-0", "0.0",
                      "999999999999999", "0.000000000000001", "12.345678901234"]
        for field in fields {
            let quoted = "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            expectSameImport("h\n\(quoted)\n")
        }
        expectSameImport("a;b\n1,5;2,25\n3.5;x\n")   // decimal commas with ';'
        expectSameImport("x\t1\t2026-03-04\n")       // tab-delimited
    }

    @Test func importMatchesTheReferenceOnRandomFields() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("0123456789-.,+ $%:/eETRUFALSabc#'")
        for _ in 0..<2000 {
            let fields = (0..<3).map { _ in
                String((0..<Int.random(in: 0...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            }
            let line = fields.map { "\"" + $0 + "\"" }.joined(separator: ",")
            expectSameImport("c1,c2,c3\n" + line + "\n")
        }
    }

    @Test func importMatchesTheReferenceOnRandomWords() {
        var rng = SystemRandomNumberGenerator()
        let tokens = ["Jan", "may", "March", "Sept", "Order", "x", "E", "PM", "a", "TRUE", "12", "5", "2026",
                      " ", ",", "-", "/", ":", ".", "%", "$", "#", "'", "é", "3:45", "1,5"]
        for _ in 0..<3000 {
            let field = (0..<Int.random(in: 1...5, using: &rng)).map { _ in tokens.randomElement(using: &rng)! }.joined()
            expectSameImport("h\n\"" + field + "\"\n")
        }
    }

    @Test func stopsAtTheRowLimitAndSaysSo() {
        let text = (1...10).map { "\($0),x" }.joined(separator: "\n") + "\n"
        var report = CSVImportReport()
        let wb = CSV.importWorkbook(data: Data(text.utf8), maxRows: 4, report: &report)
        #expect(report.truncated)
        #expect(report.rows == 4)
        #expect(wb.sheets[0].usedRange?.a1 == "A1:B4")

        var exact = CSVImportReport()
        _ = CSV.importWorkbook(data: Data(text.utf8), maxRows: 10, report: &exact)
        #expect(!exact.truncated)   // ten rows, then only the final newline
        #expect(exact.rows == 10)
    }

    @Test func progressCanCancel() {
        let text = String(repeating: "1,2,3\n", count: 200_000)
        var report = CSVImportReport()
        var calls = 0
        _ = CSV.importWorkbook(data: Data(text.utf8), report: &report) { _ in
            calls += 1
            return calls < 2
        }
        #expect(report.cancelled)
        #expect(report.rows < 200_000)
    }

    @Test func encodings() {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("name\ncafé\n".utf8)
        #expect(CSV.importWorkbook(data: bom).sheets[0].value(at: CellAddress(row: 1, column: 0)) == .string("café"))
        let cp1252 = Data([0x6E, 0x0A, 0x80, 0x35, 0x0A]) // "n\n€5\n" in CP1252
        #expect(CSV.importWorkbook(data: cp1252).sheets[0].value(at: CellAddress(row: 1, column: 0)) == .string("€5"))
        let utf16 = Data([0xFF, 0xFE]) + "a,b\n1,2\n".data(using: .utf16LittleEndian)!
        #expect(CSV.importWorkbook(data: utf16).sheets[0].value(at: CellAddress(row: 1, column: 1)) == .number(2))
    }

    @Test func utf8Validation() {
        func valid(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBufferPointer { CSV.isValidUTF8($0) } }
        #expect(valid(Array("plain ascii text, longer than eight bytes".utf8)))
        #expect(valid(Array("é€𝄞 mixed".utf8)))
        #expect(!valid([0xC0, 0x80]))            // overlong
        #expect(!valid([0xED, 0xA0, 0x80]))      // surrogate
        #expect(!valid([0xE2, 0x82]))            // truncated
        #expect(!valid([0x80]))
        #expect(!valid([0xF4, 0x90, 0x80, 0x80])) // above U+10FFFF
    }

    @Test func superscriptDigitsNoLongerCrashDateParsing() {
        #expect(ValueParser.parse("Jan ²").value == .string("Jan ²"))
        #expect(ValueParser.parse("²/3/2026").value == .string("²/3/2026"))
    }
}

extension CSVFastImportTests {
    @Test func invalidUTF8FarIntoTheFileFallsBackToCP1252() {
        // A megabyte of ASCII, then a CP1252 "é" (0xE9): read as CP1252
        // where the scan meets it, with no second pass over the file.
        var data = Data(String(repeating: "word,1\n", count: 150_000).utf8)
        data.append(contentsOf: [0x63, 0x61, 0x66, 0xE9, 0x2C, 0x32, 0x0A]) // "café,2\n"
        let sheet = CSV.importWorkbook(data: data).sheets[0]
        #expect(sheet.value(at: CellAddress(row: 150_000, column: 0)) == .string("café"))
        #expect(sheet.value(at: CellAddress(row: 0, column: 0)) == .string("word"))
    }

    @Test func oneStrayCP1252ByteLeavesTheUTF8Alone() {
        // UTF-8 "café" and "€5", then a CP1252 "é" (0xE9) on its own: only
        // that byte is read as CP1252 (#30).
        var data = Data("name,price\ncafé,€5\nZürich,1\n".utf8)
        data.append(contentsOf: [0x63, 0x61, 0x66, 0xE9, 0x2C, 0x80, 0x0A]) // "caf\xE9,\x80\n"
        for workbook in [CSV.importWorkbook(data: data), CSV.referenceImportWorkbook(data: data)] {
            let sheet = workbook.sheets[0]
            #expect(sheet.value(at: CellAddress(row: 1, column: 0)) == .string("café"))
            #expect(sheet.value(at: CellAddress(row: 1, column: 1)) == .string("€5"))
            #expect(sheet.value(at: CellAddress(row: 2, column: 0)) == .string("Zürich"))
            #expect(sheet.value(at: CellAddress(row: 3, column: 0)) == .string("café"))
            #expect(sheet.value(at: CellAddress(row: 3, column: 1)) == .string("€"))
        }
        #expect(CSV.decode(data: data) == "name,price\ncafé,€5\nZürich,1\ncafé,€\n")
    }

    @Test func mixedEncodingStillStopsAtTheRowLimit() {
        // The bad byte is in the first row: the import does not start over,
        // so it still stops at the limit without reading the rest.
        var data = Data([0xE9, 0x2C, 0x31, 0x0A])
        data.append(Data(String(repeating: "x,1\n", count: 50).utf8))
        var report = CSVImportReport()
        let sheet = CSV.importWorkbook(data: data, maxRows: 5, report: &report).sheets[0]
        #expect(report.truncated && report.rows == 5)
        #expect(sheet.value(at: CellAddress(row: 0, column: 0)) == .string("é"))
    }

    @Test func invalidSequencesMapByteByByte() {
        // A truncated 3-byte sequence, a lone continuation byte, an overlong
        // form, then valid text; numbers next to them still parse.
        let bytes: [UInt8] = [0xE2, 0x82, 0x2C, 0x9C, 0x2C, 0xC0, 0xAF, 0x2C, 0x31, 0x32, 0x0A]
        let sheet = CSV.importWorkbook(data: Data(bytes)).sheets[0]
        #expect(sheet.value(at: CellAddress(row: 0, column: 0)) == .string("â‚"))
        #expect(sheet.value(at: CellAddress(row: 0, column: 1)) == .string("œ"))
        #expect(sheet.value(at: CellAddress(row: 0, column: 2)) == .string("À¯"))
        #expect(sheet.value(at: CellAddress(row: 0, column: 3)) == .number(12))
    }

    @Test func multibyteCharactersAcrossValidationChunks() {
        // "é" (2 bytes) everywhere, so chunk edges land mid-character.
        let text = String(repeating: "é,1\n", count: 300_000)
        let sheet = CSV.importWorkbook(data: Data(text.utf8)).sheets[0]
        #expect(sheet.value(at: CellAddress(row: 299_999, column: 0)) == .string("é"))
        #expect(sheet.cells.count == 600_000)
    }
}
