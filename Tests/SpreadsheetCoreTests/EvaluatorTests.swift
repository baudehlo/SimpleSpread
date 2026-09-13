import Testing
@testable import SpreadsheetCore

@Suite("Evaluator: operators & coercion")
struct EvaluatorOperatorTests {
    @Test func arithmetic() {
        #expect(evalNumber("1+2") == 3)
        #expect(evalNumber("10-4") == 6)
        #expect(evalNumber("6*7") == 42)
        #expect(evalNumber("15/4") == 3.75)
        #expect(evalNumber("2^10") == 1024)
        #expect(evalNumber("-2^2") == 4) // unary minus binds tighter than ^
        #expect(evalNumber("0-2^2") == -4)
        #expect(evalNumber("2^3^2") == 64) // left-assoc
        #expect(evalNumber("50%") == 0.5)
        #expect(evalNumber("50%%") == 0.005)
    }

    @Test func divisionByZero() {
        #expect(evalError("1/0") == .div0)
        #expect(evalError("1/A1") == .div0) // blank -> 0
    }

    @Test func stringCoercionInArithmetic() {
        #expect(evalNumber("\"3\"+1") == 4)
        #expect(evalNumber("\"1,234\"+0") == 1234)
        #expect(evalNumber("\"50%\"+0") == 0.5)
        #expect(evalError("\"abc\"+1") == .value)
    }

    @Test func booleanCoercionInArithmetic() {
        #expect(evalNumber("TRUE+TRUE") == 2)
        #expect(evalNumber("FALSE*10") == 0)
    }

    @Test func blankCoercion() {
        #expect(evalNumber("A1+5") == 5) // empty A1 -> 0
        #expect(evalString("A1&\"x\"") == "x")
    }

    @Test func concatenation() {
        #expect(evalString("\"a\"&\"b\"") == "ab")
        #expect(evalString("\"n=\"&1.5") == "n=1.5")
        #expect(evalString("\"v: \"&TRUE") == "v: TRUE")
        #expect(evalString("\"a\"&1+1") == "a2") // & below +
    }

    @Test func comparisons() {
        #expect(evalBool("1=1") == true)
        #expect(evalBool("1<>2") == true)
        #expect(evalBool("2>1") == true)
        #expect(evalBool("1>=1") == true)
        #expect(evalBool("1<2") == true)
        #expect(evalBool("2<=1") == false)
    }

    @Test func textComparisonCaseInsensitive() {
        #expect(evalBool("\"a\"=\"A\"") == true)
        #expect(evalBool("\"apple\"<\"BANANA\"") == true)
    }

    @Test func mixedTypeComparisonRanking() {
        // number < text < boolean; no cross-type coercion
        #expect(evalBool("99<\"1\"") == true)
        #expect(evalBool("\"3\"=3") == false)
        #expect(evalBool("TRUE>100") == true)
        #expect(evalBool("\"zzz\"<TRUE") == true)
    }

    @Test func blankComparisons() {
        #expect(evalBool("A1=0") == true)
        #expect(evalBool("A1=\"\"") == true)
        #expect(evalBool("A1=FALSE") == true)
    }

    @Test func errorPropagation() {
        #expect(evalError("1/0+5") == .div0)
        #expect(evalError("SUM(A1:A3)", cells: ["A2": "=1/0"]) == .div0)
        #expect(evalError("#REF!+1") == .ref)
        #expect(evalError("-(1/0)") == .div0)
    }

    @Test func powerEdgeCases() {
        #expect(evalError("0^0") == .num)
        #expect(evalError("(-2)^0.5") == .num)
        #expect(evalNumber("(-8)^(1/3)").map { $0.isNaN } != true) // errors, not NaN
    }
}

@Suite("Evaluator: references")
struct EvaluatorReferenceTests {
    @Test func cellReference() {
        #expect(evalNumber("A1*2", cells: ["A1": "21"]) == 42)
    }

    @Test func rangeInAggregate() {
        #expect(evalNumber("SUM(A1:A3)", cells: ["A1": "1", "A2": "2", "A3": "3"]) == 6)
    }

    @Test func multiCellRangeInScalarContextIsError() {
        #expect(evalError("A1:A3+1", cells: ["A1": "1"]) == .value)
    }

    @Test func wholeColumnReference() {
        #expect(evalNumber("SUM(A:A)", cells: ["A1": "5", "A100": "7"]) == 12)
        #expect(evalNumber("SUM(A:B)", cells: ["A1": "5", "B3": "2"]) == 7)
    }

    @Test func wholeRowReference() {
        #expect(evalNumber("SUM(1:1)", cells: ["A1": "5", "D1": "3", "A2": "99"]) == 8)
    }

    @Test func reversedRangeNormalizes() {
        #expect(evalNumber("SUM(B2:A1)", cells: ["A1": "1", "B2": "2"]) == 3)
    }

    @Test func crossSheetReference() {
        let h = Harness()
        h.workbook.addSheet(named: "Data")
        h.set(cells: ["A1": "10"], sheetIndex: 1)
        h.engine.rebuildAll()
        #expect(h.eval("Data!A1*2").numberValue == 20)
        #expect(h.eval("SUM(Data!A:A)").numberValue == 10)
    }

    @Test func missingSheetIsRefError() {
        #expect(evalError("Nowhere!A1") == .ref)
    }

    @Test func unknownNameIsNameError() {
        #expect(evalError("hello+1") == .name)
        #expect(evalError("NOSUCHFUNC(1)") == .name)
    }

    @Test func rangeInsideTextAggregation() {
        #expect(evalString("CONCATENATE(A1:B1)", cells: ["A1": "x", "B1": "y"]) == "xy")
    }
}
