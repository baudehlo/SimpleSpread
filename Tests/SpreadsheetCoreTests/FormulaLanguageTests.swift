import Foundation
import Testing
@testable import SpreadsheetCore

/// Number -> text: the round-trip form (formula text, the editor), Excel's
/// 15-digit coercion (`&`, text functions) and the grid's General form are
/// three different contracts (review #2).
@Suite("Number to text")
struct NumberTextTests {
    @Test func roundTripStringIsExactAndShort() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (1, "1"), (-42, "-42"), (3.14159265358979, "3.14159265358979"),
            (1234567890123.45, "1234567890123.45"), (0.1 + 0.2, "0.30000000000000004"),
            (1.23456789012, "1.23456789012"), (123456789012.5, "123456789012.5"),
            (1e15, "1E+15"), (1234567890123456, "1.234567890123456E+15"), (1e20, "1E+20"),
            (1e-9, "0.000000001"), (1.5e-10, "1.5E-10"), (0.0001, "0.0001"), (-2.5e-7, "-0.00000025"),
        ]
        for (n, text) in cases {
            #expect(NumberFormatEngine.roundTripString(for: n) == text, "\(n)")
        }
    }

    @Test func roundTripStringReadsBackExactly() throws {
        var rng = SystemRandomNumberGenerator()
        var values: [Double] = [.pi, -.pi, 1 / 3, 2 / 3, 1e300, -1e-300, .leastNormalMagnitude,
                                .greatestFiniteMagnitude, 9007199254740992, 45306.65636574074]
        for _ in 0..<2000 {
            let magnitude = Double.random(in: -30...30, using: &rng)
            values.append(Double.random(in: -1...1, using: &rng) * pow(10, magnitude))
        }
        for n in values {
            let text = NumberFormatEngine.roundTripString(for: n)
            #expect(Double(text) == n, "\(n) -> \(text)")
            // ...and through the formula language.
            #expect(try FormulaParser.parse(text).text == text || n < 0, "\(n)")
            #expect(ValueParser.parse(text).value == .number(n), "typed \(text)")
        }
    }

    @Test func textCoercionKeepsFifteenDigits() {
        let cases: [(Double, String)] = [
            (1234567.891234, "1234567.891234"), (1.0 / 3, "0.333333333333333"),
            (0.1 + 0.2, "0.3"), (123456789012345680, "1.23456789012346E+17"),
            (999999999999999, "999999999999999"), (1e15, "1E+15"), (1e-10, "1E-10"),
            (45306.123456789, "45306.123456789"), (-12.5, "-12.5"), (2, "2"),
        ]
        for (n, text) in cases {
            #expect(NumberFormatEngine.textCoercionString(for: n) == text, "\(n)")
        }
    }

    @Test func concatenationUsesFifteenDigits() {
        let h = Harness(cells: ["A1": "1234567.891234", "B1": "45306.123456789"])
        #expect(h.eval("\"x\"&A1") == .string("x1234567.891234"))
        #expect(h.eval("A1&\"\"") == .string("1234567.891234"))
        #expect(h.eval("CONCATENATE(B1)") == .string("45306.123456789"))
    }

    @Test func gridDisplayStillUsesGeneral() {
        #expect(NumberFormatEngine.displayString(for: .number(3.14159265358979), format: .general) == "3.141592654")
    }

    @Test func printedConstantsAreExact() throws {
        for text in ["A1*1.23456789012", "A1+123456789012.5", "0.30000000000000004*2", "1E+20+1.5E-10"] {
            let expr = try FormulaParser.parse(text)
            let reparsed = try FormulaParser.parse(expr.text)
            #expect(reparsed == expr, "\(text) printed as \(expr.text)")
        }
    }

    /// commitInput(editString(v)) == v, over values and formats.
    @Test func editTextReadsBackExactly() {
        let formats: [NumberFormat] = [
            .general, .integer, .decimal2, .thousands, .percent, .percentInteger, .currency,
            .date, .time, .dateTime, .scientific, NumberFormat(code: "mmm yyyy"),
            NumberFormat(code: "0.0%"), NumberFormat(code: "[h]:mm:ss"), NumberFormat(code: "yyyy-mm-dd"),
        ]
        var values: [Double] = [0, 1, -1, 3.14159265358979, 1234567890123.45, 0.1 + 0.2, 0.123456, 0.5,
                                45306, 45306.5, 45306.65636574074, 45306.25, 0.75, 1e20, 1e-12, -0.0001,
                                ExcelDate.serial(year: 2024, month: 1, day: 15, hour: 15, minute: 45, second: 10)]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 { values.append(Double.random(in: 0..<60000, using: &rng)) }
        for _ in 0..<300 { values.append(Double.random(in: -2...2, using: &rng)) }
        for format in formats {
            for n in values {
                let text = ValueParser.editText(for: n, format: format)
                #expect(ValueParser.parse(text).value == .number(n), "\(n) in \(format.code) -> \(text)")
            }
        }
    }

    @Test func editTextKeepsDatesAndPercentsReadable() {
        let dateTime = ExcelDate.serial(year: 2024, month: 1, day: 15, hour: 15, minute: 45, second: 10)
        // A date-time shown as m/d/yyyy keeps its time.
        #expect(ValueParser.editText(for: dateTime, format: .date) == "1/15/2024 3:45:10 PM")
        #expect(ValueParser.editText(for: 45306, format: NumberFormat(code: "mmm yyyy")) == "1/15/2024")
        #expect(ValueParser.editText(for: 0.75, format: .time) == "6:00:00 PM")
        // A percent keeps every digit.
        #expect(ValueParser.editText(for: 0.123456, format: .percent) == "12.3456%")
        #expect(ValueParser.editText(for: 0.05, format: .percentInteger) == "5%")
        #expect(ValueParser.editText(for: 1234567890123.45, format: .general) == "1234567890123.45")
    }
}

/// Reference adjustment works on tokens, so formulas the parser rejects
/// move too, and the rest of the text is kept exactly (review #3).
@Suite("Token-level reference rewriting")
struct FormulaTextRewriterTests {
    func insertRow(_ formula: String, at row: Int = 0) -> String {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .empty, formula: formula), at: CellAddress(a1: "Z1")!)
        WorkbookOperations.insertRows(in: wb, sheetID: sheet.id, at: row, count: 1)
        return sheet.cells.values.compactMap(\.formula).first ?? "(gone)"
    }

    @Test func unparseableFormulasMoveOnInsert() {
        #expect(insertRow("SUM(A2,{1,2})") == "SUM(A3,{1,2})")
        #expect(insertRow("SUM(A2:A5 B3:C3)") == "SUM(A3:A6 B4:C4)")       // intersection
        #expect(insertRow("SUM(Table1[Col],A2)") == "SUM(Table1[Col],A3)")  // table reference
        #expect(insertRow("Table1[[#This Row],[A1]]+B1") == "Table1[[#This Row],[A1]]+B2")
        #expect(insertRow("FOO(A1;B1") == "FOO(A2;B2")                       // garbage still moves
        #expect(insertRow("IF(A2,,1)") == "IF(A3,,1)")
    }

    @Test func constantsAndSpellingAreKept() {
        #expect(insertRow("A1*1.23456789012") == "A2*1.23456789012")
        #expect(insertRow("A1+123456789012.5") == "A2+123456789012.5")
        #expect(insertRow("sum( a1 , \"A1\" )") == "sum( A2 , \"A1\" )")
        #expect(insertRow("'Sheet1'!A1+Sheet1!$B$1") == "'Sheet1'!A2+Sheet1!$B$2")
    }

    @Test func otherReferenceShapes() {
        #expect(insertRow("SUM(1:3)") == "SUM(2:4)")
        #expect(insertRow("SUM($2:$3)", at: 2) == "SUM($2:$4)")
        #expect(insertRow("SUM(A:B)") == "SUM(A:B)")
        #expect(insertRow("[1]Sheet1!A1+A1") == "[1]Sheet1!A1+A2")  // another workbook: untouched
        #expect(insertRow("Other!A1+A1") == "Other!A1+A2")          // another sheet: untouched
        #expect(insertRow("LOG10(A1)+ISO.CEILING(A1)") == "LOG10(A2)+ISO.CEILING(A2)")
        // Column letters are A-Z only: an accented letter makes a name.
        #expect(insertRow("\u{E9}A1+A1") == "\u{E9}A1+A2")
        #expect(insertRow("e\u{301}A1+A1") == "e\u{301}A1+A2")
        #expect(insertRow("Gr\u{F6}\u{DF}e+'Donn\u{E9}es'!A1+Donn\u{E9}es!B1", at: 0)
            == "Gr\u{F6}\u{DF}e+'Donn\u{E9}es'!A1+Donn\u{E9}es!B1")
    }

    @Test func deletedReferencesBecomeRefErrors() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .empty, formula: "SUM(A5,{1,2})+A6"), at: CellAddress(a1: "B1")!)
        WorkbookOperations.deleteRows(in: wb, sheetID: sheet.id, at: 4, count: 1)
        #expect(sheet.cell(at: CellAddress(a1: "B1")!).formula == "SUM(#REF!,{1,2})+A5")
    }

    @Test func copyAndFillMoveUnparseableFormulas() {
        #expect(WorkbookOperations.translatedFormula("SUM(A1,{1,2})", byRows: 1, columns: 1) == "SUM(B2,{1,2})")
        #expect(WorkbookOperations.translatedFormula("SUM(Sheet1:Sheet3!A1)", byRows: 2, columns: 0)
            == "SUM(Sheet1:Sheet3!A3)")
        #expect(WorkbookOperations.translatedFormula("'Jan:Mar'!B$2*1.23456789012", byRows: 1, columns: 1)
            == "'Jan:Mar'!C$2*1.23456789012")
        #expect(WorkbookOperations.translatedFormula("Table1[Col]&A1", byRows: 1, columns: 0) == "Table1[Col]&A2")
    }

    @Test func sortMovesUnparseableFormulas() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.setCell(Cell(value: .number(2)), at: CellAddress(a1: "A1")!)
        sheet.setCell(Cell(value: .empty, formula: "SUM(A1,{1,2})"), at: CellAddress(a1: "B1")!)
        sheet.setCell(Cell(value: .number(1)), at: CellAddress(a1: "A2")!)
        let moved = WorkbookOperations.sortedCells(of: CellRange(a1: "A1:B2")!, in: sheet, keys: [SortKey(column: 0)])
        let b2 = moved.first { $0.0 == CellAddress(a1: "B2")! }?.1
        #expect(b2?.formula == "SUM(A2,{1,2})")
    }

    @Test func threeDReferences() {
        let wb = Workbook.newDocument()
        let s1 = wb.sheets[0]
        let s2 = wb.addSheet(named: "Sheet2")
        let s3 = wb.addSheet(named: "Sheet3")
        let summary = wb.addSheet(named: "Summary")
        let a1 = CellAddress(a1: "A1")!
        summary.setCell(Cell(value: .empty, formula: "SUM(Sheet1:Sheet3!B2)"), at: a1)
        // A one-sheet row insert leaves a 3-D reference alone, as in Excel.
        WorkbookOperations.insertRows(in: wb, sheetID: s2.id, at: 0, count: 1)
        #expect(summary.cell(at: a1).formula == "SUM(Sheet1:Sheet3!B2)")
        // Renaming an end sheet renames it in the reference.
        WorkbookOperations.renameSheet(in: wb, sheetID: s3.id, to: "Last Qtr")
        #expect(summary.cell(at: a1).formula == "SUM('Sheet1:Last Qtr'!B2)")
        // Deleting an end sheet pulls the reference in.
        WorkbookOperations.deleteSheet(in: wb, sheetID: s1.id)
        #expect(summary.cell(at: a1).formula == "SUM('Sheet2:Last Qtr'!B2)")
        WorkbookOperations.deleteSheet(in: wb, sheetID: s2.id)
        #expect(summary.cell(at: a1).formula == "SUM('Last Qtr'!B2)")
    }

    @Test func renameKeepsUnparseableFormulas() {
        let wb = Workbook.newDocument()
        let data = wb.addSheet(named: "Data")
        let sheet1 = wb.sheets[0]
        sheet1.setCell(Cell(value: .empty, formula: "SUM(Data!A1,{1,2})"), at: CellAddress(a1: "A1")!)
        WorkbookOperations.renameSheet(in: wb, sheetID: data.id, to: "My Data")
        #expect(sheet1.cell(at: CellAddress(a1: "A1")!).formula == "SUM('My Data'!A1,{1,2})")
    }

    @Test func findsReferences() {
        let refs = FormulaTextRewriter.references(in: "SUM(A1:B2,'My Sheet'!C3,Sheet1:Sheet2!$D$4,\"E5\",F:F)")
        #expect(refs.map(\.ref.text) == ["A1:B2", "'My Sheet'!C3", "Sheet1!$D$4", "F:F"])
        #expect(refs[2].lastSheetName == "Sheet2")
    }
}

/// Empty arguments and `_xlfn.` prefixes (review #9, #10).
@Suite("Formula language gaps")
struct FormulaLanguageGapTests {
    @Test func emptyArgumentsParse() throws {
        #expect(try FormulaParser.parse("IF(A1,,1)") == .function("IF", [
            .reference(ReferenceExpr(start: RefComponent(column: 0, row: 0))), .missing, .number(1)]))
        #expect(try FormulaParser.parse("F(,)") == .function("F", [.missing, .missing]))
        #expect(try FormulaParser.parse("F()") == .function("F", []))
        #expect(try FormulaParser.parse("VLOOKUP(1,A1:B2,2,)").text == "VLOOKUP(1,A1:B2,2,)")
    }

    @Test func emptyArgumentsTakeExcelDefaults() {
        let h = Harness(cells: ["A1": "apple", "B1": "1", "A2": "banana", "B2": "2", "A3": "c", "B3": "3"])
        #expect(h.eval("IF(TRUE,,1)") == .number(0))
        #expect(h.eval("IF(FALSE,1,)") == .number(0))
        #expect(h.eval("IF(FALSE,1)") == .bool(false))
        // VLOOKUP's empty 4th argument is FALSE: exact match.
        #expect(h.eval("VLOOKUP(\"b\",A1:B3,2,)") == .error(.na))
        #expect(h.eval("VLOOKUP(\"b\",A1:B3,2)") == .number(1))
        #expect(h.eval("VLOOKUP(\"banana\",A1:B3,2,)") == .number(2))
        #expect(h.eval("SUBSTITUTE(\"abc\",\"b\",)") == .string("ac"))
        #expect(h.eval("ROUND(1.5,)") == .number(2))
        #expect(h.eval("IFERROR(1/0,)") == .number(0))
        #expect(h.eval("CHOOSE(2,5,)") == .number(0))
        #expect(h.eval("SUM(1,,2)") == .number(3))
    }

    @Test func functionPrefixesAreStripped() throws {
        let h = Harness()
        #expect(h.eval("_xlfn.IFNA(NA(),2)") == .number(2))
        #expect(h.eval("_xlfn.CONCAT(\"a\",\"b\")") == .string("ab"))
        #expect(h.eval("_XLFN._XLWS.IFNA(1,2)") == .number(1))
        #expect(try FormulaParser.parse("_xlfn.STDEV.S(A1:A3)") == FormulaParser.parse("STDEV.S(A1:A3)"))
    }

    @Test func prefixesForFiles() {
        #expect(FormulaFunctionPrefixes.adding("IFNA(A1,0)+ifs(A1,1)") == "_xlfn.IFNA(A1,0)+_xlfn.ifs(A1,1)")
        #expect(FormulaFunctionPrefixes.adding("SORT(A1:A3)") == "_xlfn._xlws.SORT(A1:A3)")
        #expect(FormulaFunctionPrefixes.adding("SUM(A1)&\"IFNA(\"") == "SUM(A1)&\"IFNA(\"")
        #expect(FormulaFunctionPrefixes.adding("_xlfn.IFNA(1,2)") == "_xlfn.IFNA(1,2)")
        #expect(FormulaFunctionPrefixes.adding("Table1[IFNA(x)]+'IFNA('!A1") == "Table1[IFNA(x)]+'IFNA('!A1")
        #expect(FormulaFunctionPrefixes.stripped("_xlfn.IFNA(1,_xlfn._xlws.SORT(A1:A2))+\"_xlfn.X(\"")
            == "IFNA(1,SORT(A1:A2))+\"_xlfn.X(\"")
        #expect(FormulaFunctionPrefixes.stripped("SUM(A1)") == "SUM(A1)")
    }
}

/// Defined names: resolved by the evaluator, kept up to date by structural
/// edits (review #8), and unsupported formulas keep their file values on
/// open.
@Suite("Defined names")
struct DefinedNameTests {
    func workbook() -> (Workbook, Sheet, Sheet) {
        let wb = Workbook.newDocument()
        let report = wb.sheets[0]
        let data = wb.addSheet(named: "Data")
        for r in 1...3 { data.setCell(Cell(value: .number(Double(r * 10))), at: CellAddress(row: r - 1, column: 1)) }
        wb.definedNames = [
            DefinedName(name: "Sales", formula: "Data!$B$1:$B$3"),
            DefinedName(name: "Rate", formula: "0.5"),
            DefinedName(name: "Twice", formula: "Rate*2"),
            DefinedName(name: "Rate", scopeSheetID: data.id, formula: "0.25"),
            DefinedName(name: "Loop", formula: "Loop+1"),
        ]
        return (wb, report, data)
    }

    @Test func namesEvaluate() {
        let (wb, report, data) = workbook()
        report.setCell(Cell(value: .empty, formula: "SUM(Sales)"), at: CellAddress(a1: "A1")!)
        report.setCell(Cell(value: .empty, formula: "Rate*Twice"), at: CellAddress(a1: "A2")!)
        data.setCell(Cell(value: .empty, formula: "Rate"), at: CellAddress(a1: "D1")!)
        report.setCell(Cell(value: .empty, formula: "Nope+1"), at: CellAddress(a1: "A3")!)
        report.setCell(Cell(value: .empty, formula: "Loop"), at: CellAddress(a1: "A4")!)
        let engine = CalculationEngine(workbook: wb, clock: testClock)
        #expect(report.value(at: CellAddress(a1: "A1")!) == .number(60))
        #expect(report.value(at: CellAddress(a1: "A2")!) == .number(0.5))
        #expect(data.value(at: CellAddress(a1: "D1")!) == .number(0.25)) // sheet scope wins
        #expect(report.value(at: CellAddress(a1: "A3")!) == .error(.name))
        #expect(report.value(at: CellAddress(a1: "A4")!) == .error(.name))
        // The name's cells are dependencies.
        engine.setCellValue(.number(100), at: AbsoluteAddress(sheetID: data.id, address: CellAddress(a1: "B2")!))
        #expect(report.value(at: CellAddress(a1: "A1")!) == .number(140))
        // And names work outside the engine too.
        let context = EvalContext(workbook: wb, sheetID: report.id, address: CellAddress(a1: "Z9")!)
        #expect(FormulaEvaluator.evaluate(try! FormulaParser.parse("SUM(Sales)*Rate"), context: context) == .number(70))
    }

    @Test func namesFollowStructuralEdits() {
        let (wb, _, data) = workbook()
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 0, count: 2)
        #expect(wb.definedNames[0].formula == "Data!$B$3:$B$5")
        WorkbookOperations.renameSheet(in: wb, sheetID: data.id, to: "Raw Data")
        #expect(wb.definedNames[0].formula == "'Raw Data'!$B$3:$B$5")
        WorkbookOperations.deleteSheet(in: wb, sheetID: data.id)
        #expect(wb.definedNames[0].formula == "#REF!")
        #expect(!wb.definedNames.contains { $0.scopeSheetID == data.id }) // its own names go with it
    }

    @Test func openKeepsCachedValuesOfUnsupportedFormulas() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        func put(_ a1: String, _ value: CellValue, _ formula: String) {
            sheet.setCell(Cell(value: value, formula: formula), at: CellAddress(a1: a1)!)
        }
        put("A1", .number(7), "NOTAFUNCTION(1)")
        put("A2", .number(8), "UndefinedName*2")
        put("A3", .number(9), "SUM(A1,{1,2})")   // doesn't parse
        put("A4", .empty, "NOTAFUNCTION(1)")     // nothing cached: error as before
        put("A5", .number(0), "A1+A2")           // uses the kept values
        let engine = CalculationEngine(workbook: wb, clock: testClock)
        #expect(sheet.value(at: CellAddress(a1: "A1")!) == .number(7))
        #expect(sheet.value(at: CellAddress(a1: "A2")!) == .number(8))
        #expect(sheet.value(at: CellAddress(a1: "A3")!) == .number(9))
        #expect(sheet.value(at: CellAddress(a1: "A4")!) == .error(.name))
        #expect(sheet.value(at: CellAddress(a1: "A5")!) == .number(15))
        // Typing such a formula afterwards still shows the error.
        engine.setCellFormula("NOTAFUNCTION(2)", at: AbsoluteAddress(sheetID: sheet.id, address: CellAddress(a1: "B1")!))
        #expect(sheet.value(at: CellAddress(a1: "B1")!) == .error(.name))
    }
}
