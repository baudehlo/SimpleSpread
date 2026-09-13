import Testing
@testable import SpreadsheetCore

@Suite("Formula parsing")
struct FormulaParserTests {
    func parse(_ s: String) throws -> FormulaExpr {
        try FormulaParser.parse(s)
    }

    @Test func literals() throws {
        #expect(try parse("42") == .number(42))
        #expect(try parse("1.5e3") == .number(1500))
        #expect(try parse("\"hi\"") == .string("hi"))
        #expect(try parse("\"say \"\"hi\"\"\"") == .string("say \"hi\""))
        #expect(try parse("TRUE") == .boolean(true))
        #expect(try parse("false") == .boolean(false))
        #expect(try parse("#DIV/0!") == .errorLiteral(.div0))
        #expect(try parse("#N/A") == .errorLiteral(.na))
    }

    @Test func operatorPrecedence() throws {
        // * binds tighter than +
        #expect(try parse("1+2*3") ==
            .binary(.add, .number(1), .binary(.multiply, .number(2), .number(3))))
        // & below arithmetic
        #expect(try parse("\"a\"&1+1") ==
            .binary(.concat, .string("a"), .binary(.add, .number(1), .number(1))))
        // comparisons lowest
        #expect(try parse("1+1=2") ==
            .binary(.equal, .binary(.add, .number(1), .number(1)), .number(2)))
        // ^ left-associative: 2^3^2 = (2^3)^2
        #expect(try parse("2^3^2") ==
            .binary(.power, .binary(.power, .number(2), .number(3)), .number(2)))
    }

    @Test func unaryMinusBindsTighterThanPower() throws {
        // -2^2 must parse as (-2)^2
        #expect(try parse("-2^2") ==
            .binary(.power, .unary(.minus, .number(2)), .number(2)))
    }

    @Test func percentPostfix() throws {
        #expect(try parse("50%") == .percent(.number(50)))
        #expect(try parse("50%%") == .percent(.percent(.number(50))))
    }

    @Test func cellReferences() throws {
        guard case .reference(let ref) = try parse("B12") else {
            Issue.record("expected reference"); return
        }
        #expect(ref.start.column == 1)
        #expect(ref.start.row == 11)
        #expect(ref.end == nil)
        #expect(ref.sheetName == nil)

        guard case .reference(let abs) = try parse("$C$4") else {
            Issue.record("expected reference"); return
        }
        #expect(abs.start.columnAbsolute && abs.start.rowAbsolute)
    }

    @Test func rangeReferences() throws {
        guard case .reference(let ref) = try parse("A1:B3") else {
            Issue.record("expected range"); return
        }
        #expect(ref.start.column == 0 && ref.start.row == 0)
        #expect(ref.end?.column == 1 && ref.end?.row == 2)
    }

    @Test func wholeColumnAndRowReferences() throws {
        guard case .reference(let col) = try parse("A:C") else {
            Issue.record("expected column range"); return
        }
        #expect(col.start.column == 0 && col.start.row == nil)
        #expect(col.end?.column == 2 && col.end?.row == nil)

        guard case .reference(let row) = try parse("1:3") else {
            Issue.record("expected row range"); return
        }
        #expect(row.start.row == 0 && row.start.column == nil)
        #expect(row.end?.row == 2 && row.end?.column == nil)
    }

    @Test func sheetReferences() throws {
        guard case .reference(let ref) = try parse("Sheet2!A1") else {
            Issue.record("expected sheet ref"); return
        }
        #expect(ref.sheetName == "Sheet2")

        guard case .reference(let quoted) = try parse("'My Sheet'!B2:C3") else {
            Issue.record("expected quoted sheet ref"); return
        }
        #expect(quoted.sheetName == "My Sheet")
        #expect(quoted.end != nil)

        guard case .reference(let escaped) = try parse("'O''Brien'!A1") else {
            Issue.record("expected escaped sheet ref"); return
        }
        #expect(escaped.sheetName == "O'Brien")
    }

    @Test func functionCalls() throws {
        #expect(try parse("SUM(1,2,3)") ==
            .function("SUM", [.number(1), .number(2), .number(3)]))
        #expect(try parse("pi()") == .function("PI", []))
        #expect(try parse("TRUE()") == .function("TRUE", []))
        // Nested
        guard case .function("IF", let args) = try parse("IF(A1>0,SUM(B:B),0)") else {
            Issue.record("expected IF"); return
        }
        #expect(args.count == 3)
    }

    @Test func unknownNames() throws {
        #expect(try parse("hello") == .unknownName("hello"))
    }

    @Test func parseErrors() {
        #expect(throws: FormulaParseError.self) { try FormulaParser.parse("1+") }
        #expect(throws: FormulaParseError.self) { try FormulaParser.parse("(1") }
        #expect(throws: FormulaParseError.self) { try FormulaParser.parse("SUM(1,") }
        #expect(throws: FormulaParseError.self) { try FormulaParser.parse("\"unterminated") }
        #expect(throws: FormulaParseError.self) { try FormulaParser.parse("") }
        #expect(throws: FormulaParseError.self) { try FormulaParser.parse("1 2") }
    }

    @Test func serializationRoundTrip() throws {
        for formula in [
            "1+2*3", "-2^2", "50%", "\"a\"&\"b\"", "A1+B2", "$A$1:$B$2",
            "SUM(A1:A10,5)", "IF(A1>0,\"yes\",\"no\")", "Sheet2!A1",
            "'My Sheet'!A1:B2", "A:C", "1:3", "(1+2)*3", "TRUE", "#N/A",
        ] {
            let expr = try parse(formula)
            let text = expr.text
            let reparsed = try parse(text)
            #expect(reparsed == expr, "round trip failed for \(formula): got \(text)")
        }
    }

    @Test func parenthesesPreserved() throws {
        #expect(try parse("(1+2)*3").text == "(1+2)*3")
    }

    @Test func stringEscapingInSerialization() throws {
        let expr = FormulaExpr.string("say \"hi\"")
        #expect(expr.text == "\"say \"\"hi\"\"\"")
        #expect(try parse(expr.text) == expr)
    }

    @Test func whitespaceTolerance() throws {
        #expect(try parse(" 1 + 2 ") == .binary(.add, .number(1), .number(2)))
        #expect(try parse("SUM( A1 , B2 )") == .function("SUM", [
            .reference(ReferenceExpr(start: RefComponent(column: 0, row: 0))),
            .reference(ReferenceExpr(start: RefComponent(column: 1, row: 1))),
        ]))
    }

    @Test func volatileDetection() throws {
        #expect(try parse("NOW()").isVolatile)
        #expect(try parse("1+RAND()").isVolatile)
        #expect(try parse("IF(A1,TODAY(),1)").isVolatile)
        #expect(!(try parse("SUM(A1:A9)").isVolatile))
    }
}

@Suite("Formula reference transforms")
struct FormulaTransformTests {
    func parse(_ s: String) throws -> FormulaExpr {
        try FormulaParser.parse(s)
    }

    @Test func copyAdjustsRelativeRefs() throws {
        let expr = try parse("A1+$B$2+C$3+$D4")
        let moved = expr.adjustedForCopy(byRows: 1, columns: 2)
        #expect(moved.text == "C2+$B$2+E$3+$D5")
    }

    @Test func copyOffGridBecomesRef() throws {
        let expr = try parse("A1")
        let moved = expr.adjustedForCopy(byRows: -1, columns: 0)
        #expect(moved.text == "#REF!")
    }

    @Test func copyAdjustsRanges() throws {
        let expr = try parse("SUM(A1:B2)")
        #expect(expr.adjustedForCopy(byRows: 2, columns: 0).text == "SUM(A3:B4)")
    }

    @Test func insertRowsShiftsReferences() throws {
        let expr = try parse("A5+$A$6")
        let adjusted = expr.adjustedForStructuralChange(
            axisIsRow: true, index: 2, count: 2, editedSheet: "Sheet1", ownSheet: "Sheet1")
        // Insertion above row 5 shifts both relative AND absolute refs.
        #expect(adjusted.text == "A7+$A$8")
    }

    @Test func insertRowsExpandsSpanningRanges() throws {
        let expr = try parse("SUM(A1:A5)")
        let adjusted = expr.adjustedForStructuralChange(
            axisIsRow: true, index: 2, count: 1, editedSheet: "Sheet1", ownSheet: "Sheet1")
        #expect(adjusted.text == "SUM(A1:A6)")
    }

    @Test func deleteRowsContractsRanges() throws {
        let expr = try parse("SUM(A1:A10)")
        let adjusted = expr.adjustedForStructuralChange(
            axisIsRow: true, index: 2, count: -3, editedSheet: "Sheet1", ownSheet: "Sheet1")
        #expect(adjusted.text == "SUM(A1:A7)")
    }

    @Test func deleteReferencedCellBecomesRef() throws {
        let expr = try parse("A5*2")
        let adjusted = expr.adjustedForStructuralChange(
            axisIsRow: true, index: 4, count: -1, editedSheet: "Sheet1", ownSheet: "Sheet1")
        #expect(adjusted.text == "#REF!*2")
    }

    @Test func deleteRangeEndpointContracts() throws {
        // Delete rows 8-12 (0-based 7..11): A1:A10 -> A1:A7
        let expr = try parse("SUM(A1:A10)")
        let adjusted = expr.adjustedForStructuralChange(
            axisIsRow: true, index: 7, count: -5, editedSheet: "Sheet1", ownSheet: "Sheet1")
        #expect(adjusted.text == "SUM(A1:A7)")
        // Delete rows spanning the whole range -> #REF!
        let gone = try parse("SUM(A3:A5)").adjustedForStructuralChange(
            axisIsRow: true, index: 1, count: -10, editedSheet: "Sheet1", ownSheet: "Sheet1")
        #expect(gone.text == "SUM(#REF!)")
    }

    @Test func columnInsertAndDelete() throws {
        let expr = try parse("SUM(B1:D1)")
        let inserted = expr.adjustedForStructuralChange(
            axisIsRow: false, index: 2, count: 1, editedSheet: "Sheet1", ownSheet: "Sheet1")
        #expect(inserted.text == "SUM(B1:E1)")
        let deleted = expr.adjustedForStructuralChange(
            axisIsRow: false, index: 2, count: -1, editedSheet: "Sheet1", ownSheet: "Sheet1")
        #expect(deleted.text == "SUM(B1:C1)")
    }

    @Test func structuralChangeOnlyAffectsTargetSheet() throws {
        let expr = try parse("Sheet2!A5+A5")
        let adjusted = expr.adjustedForStructuralChange(
            axisIsRow: true, index: 0, count: 1, editedSheet: "Sheet2", ownSheet: "Sheet1")
        #expect(adjusted.text == "Sheet2!A6+A5")
    }

    @Test func sheetRename() throws {
        let expr = try parse("Sheet2!A1+'Old Name'!B2+A1")
        let renamed = expr.renamingSheet(from: "old name", to: "New Name")
        #expect(renamed.text == "Sheet2!A1+'New Name'!B2+A1")
    }

    @Test func sheetNameQuotingRules() {
        #expect(ReferenceExpr.quoteSheetNameIfNeeded("Sheet1") == "Sheet1")
        #expect(ReferenceExpr.quoteSheetNameIfNeeded("My Sheet") == "'My Sheet'")
        #expect(ReferenceExpr.quoteSheetNameIfNeeded("O'Brien") == "'O''Brien'")
        #expect(ReferenceExpr.quoteSheetNameIfNeeded("2024") == "'2024'")
        // A sheet literally named like a cell ref must be quoted.
        #expect(ReferenceExpr.quoteSheetNameIfNeeded("A1") == "'A1'")
    }
}
