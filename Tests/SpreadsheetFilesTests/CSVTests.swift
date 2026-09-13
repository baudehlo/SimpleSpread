import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

@Suite("CSV parsing")
struct CSVParseTests {
    @Test func basicParsing() {
        #expect(CSV.parse("a,b,c") == [["a", "b", "c"]])
        #expect(CSV.parse("a,b\nc,d") == [["a", "b"], ["c", "d"]])
        #expect(CSV.parse("a,b\nc,d\n") == [["a", "b"], ["c", "d"]]) // no trailing empty record
    }

    @Test func quotedFields() {
        #expect(CSV.parse("\"a,b\",c") == [["a,b", "c"]])
        #expect(CSV.parse("\"say \"\"hi\"\"\",x") == [["say \"hi\"", "x"]])
        #expect(CSV.parse("\"line1\nline2\",x") == [["line1\nline2", "x"]])
        #expect(CSV.parse("\"crlf\r\ninside\",x") == [["crlf\r\ninside", "x"]])
    }

    @Test func lineEndings() {
        #expect(CSV.parse("a\r\nb") == [["a"], ["b"]])
        #expect(CSV.parse("a\rb") == [["a"], ["b"]]) // lone CR (classic Mac)
        #expect(CSV.parse("a\nb") == [["a"], ["b"]])
    }

    @Test func emptyFieldsAndRows() {
        #expect(CSV.parse("a,,c") == [["a", "", "c"]])
        #expect(CSV.parse(",,") == [["", "", ""]])
        #expect(CSV.parse("a\n\nb") == [["a"], [""], ["b"]]) // empty line kept
        #expect(CSV.parse("") == [])
    }

    @Test func raggedRows() {
        #expect(CSV.parse("a,b,c\nd\ne,f") == [["a", "b", "c"], ["d"], ["e", "f"]])
    }

    @Test func strayQuotesTolerance() {
        // Quote mid-field (unquoted field) is literal.
        #expect(CSV.parse("it\"s,fine") == [["it\"s", "fine"]])
    }

    @Test func unterminatedQuoteFailsSoft() {
        #expect(CSV.parse("\"never closed,a\nb") == [["never closed,a\nb"]])
    }

    @Test func quotedEmptyField() {
        #expect(CSV.parse("\"\",x") == [["", "x"]])
        #expect(CSV.parse("\"\"") == [[""]])
    }

    @Test func tabDelimiter() {
        #expect(CSV.parse("a\tb\tc", delimiter: "\t") == [["a", "b", "c"]])
    }
}

@Suite("CSV sniffing & decoding")
struct CSVSniffTests {
    @Test func sniffsComma() {
        #expect(CSV.sniffDelimiter(in: "a,b,c\nd,e,f\ng,h,i") == ",")
    }

    @Test func sniffsSemicolon() {
        #expect(CSV.sniffDelimiter(in: "a;b;c\nd;e;f") == ";")
    }

    @Test func sniffsTab() {
        #expect(CSV.sniffDelimiter(in: "a\tb\tc\nd\te\tf") == "\t")
    }

    @Test func sniffsSemicolonWithDecimalCommas() {
        // Commas appear as decimal separators but semicolon gives consistent columns.
        let text = "name;price\nwidget;1,50\ngadget;2,75"
        #expect(CSV.sniffDelimiter(in: text) == ";")
    }

    @Test func sniffPrefersConsistency() {
        // Commas inside quoted text mislead frequency counting.
        let text = "id;note\n1;\"a, b, c, d\"\n2;\"x, y, z, w\"\n3;\"p, q, r, s\""
        #expect(CSV.sniffDelimiter(in: text) == ";")
    }

    @Test func decodesUTF8BOM() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("héllo,1".utf8))
        #expect(CSV.decode(data: data) == "héllo,1") // BOM stripped
    }

    @Test func decodesUTF16LE() {
        let text = "a,ü\n1,2"
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        #expect(CSV.decode(data: data) == text)
    }

    @Test func fallsBackToCP1252() {
        // 0x93/0x94 are curly quotes in CP1252, invalid UTF-8.
        let data = Data([0x93, 0x68, 0x69, 0x94]) // “hi”
        #expect(CSV.decode(data: data) == "\u{201C}hi\u{201D}")
    }
}

@Suite("CSV import")
struct CSVImportTests {
    func importText(_ text: String, delimiter: Character? = nil) -> Workbook {
        let refDate = DateComponents(calendar: .current, year: 2026, month: 9, day: 13).date!
        return CSV.importWorkbook(data: Data(text.utf8), delimiter: delimiter, referenceDate: refDate)
    }

    @Test func typeInference() {
        let wb = importText("name,count,ratio,flag\nwidget,42,0.5,TRUE")
        let s = wb.sheets[0]
        #expect(s.value(at: CellAddress(a1: "A1")!) == .string("name"))
        #expect(s.value(at: CellAddress(a1: "B2")!) == .number(42))
        #expect(s.value(at: CellAddress(a1: "C2")!) == .number(0.5))
        #expect(s.value(at: CellAddress(a1: "D2")!) == .bool(true))
    }

    @Test func formulaInjectionNeutralized() {
        let wb = importText("=1+1,+ok,-5,@cmd")
        let s = wb.sheets[0]
        #expect(s.value(at: CellAddress(a1: "A1")!) == .string("=1+1"))
        #expect(s.cell(at: CellAddress(a1: "A1")!).formula == nil)
        #expect(s.value(at: CellAddress(a1: "B1")!) == .string("+ok"))
        #expect(s.value(at: CellAddress(a1: "C1")!) == .number(-5)) // real number stays a number
        #expect(s.value(at: CellAddress(a1: "D1")!) == .string("@cmd"))
    }

    @Test func leadingZerosPreserved() {
        let wb = importText("zip\n00501")
        #expect(wb.sheets[0].value(at: CellAddress(a1: "A2")!) == .string("00501"))
    }

    @Test func datesGetDateFormat() {
        let wb = importText("when\n2026-01-15")
        let s = wb.sheets[0]
        let cell = s.cell(at: CellAddress(a1: "A2")!)
        #expect(cell.value == .number(ExcelDate.serial(year: 2026, month: 1, day: 15)))
        #expect(wb.style(at: cell.styleIndex).numberFormat.isDateTime)
    }

    @Test func semicolonDecimalCommaImport() {
        let wb = importText("price\n1,50\n2,75", delimiter: ";")
        let s = wb.sheets[0]
        #expect(s.value(at: CellAddress(a1: "A2")!) == .number(1.5))
        #expect(s.value(at: CellAddress(a1: "A3")!) == .number(2.75))
    }

    @Test func emptyCellsSkipped() {
        let wb = importText("a,,c")
        #expect(wb.sheets[0].cells.count == 2)
    }
}

@Suite("CSV export")
struct CSVExportTests {
    func exportString(_ build: (Workbook, Sheet) -> Void,
                      options: CSV.ExportOptions = CSV.ExportOptions(includeBOM: false)) -> String {
        let wb = Workbook.newDocument()
        build(wb, wb.sheets[0])
        let data = CSV.export(sheet: wb.sheets[0], workbook: wb, options: options)
        return String(data: data, encoding: .utf8)!
    }

    @Test func basicExport() {
        let out = exportString { _, s in
            s.setCell(Cell(value: .string("a")), at: CellAddress(a1: "A1")!)
            s.setCell(Cell(value: .number(1.5)), at: CellAddress(a1: "B1")!)
            s.setCell(Cell(value: .bool(true)), at: CellAddress(a1: "A2")!)
            s.setCell(Cell(value: .error(.div0)), at: CellAddress(a1: "B2")!)
        }
        #expect(out == "a,1.5\r\nTRUE,#DIV/0!\r\n")
    }

    @Test func quotingRules() {
        let out = exportString { _, s in
            s.setCell(Cell(value: .string("has,comma")), at: CellAddress(a1: "A1")!)
            s.setCell(Cell(value: .string("has \"quote\"")), at: CellAddress(a1: "B1")!)
            s.setCell(Cell(value: .string("multi\nline")), at: CellAddress(a1: "C1")!)
            s.setCell(Cell(value: .string("plain")), at: CellAddress(a1: "D1")!)
        }
        #expect(out == "\"has,comma\",\"has \"\"quote\"\"\",\"multi\nline\",plain\r\n")
    }

    @Test func formulasExportComputedValues() {
        let wb = Workbook.newDocument()
        let engine = CalculationEngine(workbook: wb)
        let id = wb.sheets[0].id
        engine.setCellValue(.number(2), at: AbsoluteAddress(sheetID: id, address: CellAddress(a1: "A1")!))
        engine.setCellFormula("A1*10", at: AbsoluteAddress(sheetID: id, address: CellAddress(a1: "B1")!))
        let data = CSV.export(sheet: wb.sheets[0], workbook: wb,
                              options: CSV.ExportOptions(includeBOM: false))
        #expect(String(data: data, encoding: .utf8) == "2,20\r\n")
    }

    @Test func datesExportISO() {
        let out = exportString { wb, s in
            var style = CellStyle()
            style.numberFormat = .date
            let serial = ExcelDate.serial(year: 2026, month: 9, day: 13)
            s.setCell(Cell(value: .number(serial), styleIndex: wb.styles.index(for: style)),
                      at: CellAddress(a1: "A1")!)
            var dt = CellStyle()
            dt.numberFormat = .dateTime
            let serial2 = ExcelDate.serial(year: 2026, month: 9, day: 13, hour: 14, minute: 30, second: 0)
            s.setCell(Cell(value: .number(serial2), styleIndex: wb.styles.index(for: dt)),
                      at: CellAddress(a1: "B1")!)
        }
        #expect(out == "2026-09-13,2026-09-13T14:30:00\r\n")
    }

    @Test func numbersExportFullPrecision() {
        let out = exportString { wb, s in
            var pct = CellStyle()
            pct.numberFormat = .percent
            s.setCell(Cell(value: .number(0.05), styleIndex: wb.styles.index(for: pct)),
                      at: CellAddress(a1: "A1")!)
            s.setCell(Cell(value: .number(1.0 / 3.0)), at: CellAddress(a1: "B1")!)
        }
        // Underlying value, not "5%"; full round-trip precision.
        #expect(out == "0.05,\(1.0 / 3.0)\r\n")
    }

    @Test func displayModeExportsFormatted() {
        let out = exportString({ wb, s in
            var pct = CellStyle()
            pct.numberFormat = .percentInteger
            s.setCell(Cell(value: .number(0.05), styleIndex: wb.styles.index(for: pct)),
                      at: CellAddress(a1: "A1")!)
        }, options: CSV.ExportOptions(includeBOM: false, machineReadable: false))
        #expect(out == "5%\r\n")
    }

    @Test func bomWrittenByDefault() {
        let wb = Workbook.newDocument()
        wb.sheets[0].setCell(Cell(value: .string("x")), at: CellAddress(a1: "A1")!)
        let data = CSV.export(sheet: wb.sheets[0], workbook: wb)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
    }

    @Test func rectangularPadding() {
        let out = exportString { _, s in
            s.setCell(Cell(value: .number(1)), at: CellAddress(a1: "C2")!)
        }
        // Rows padded to the used width from A1.
        #expect(out == ",,\r\n,,1\r\n")
    }

    @Test func importExportRoundTrip() {
        let original = "name,qty,price\nwidget,4,2.5\n\"has,comma\",1,0.99\n"
        let wb = CSV.importWorkbook(data: Data(original.utf8))
        let exported = CSV.export(sheet: wb.sheets[0], workbook: wb,
                                  options: CSV.ExportOptions(includeBOM: false))
        let reimported = CSV.importWorkbook(data: exported)
        let s1 = wb.sheets[0]
        let s2 = reimported.sheets[0]
        for (addr, cell) in s1.cells {
            #expect(s2.value(at: addr) == cell.value, "mismatch at \(addr)")
        }
    }
}
