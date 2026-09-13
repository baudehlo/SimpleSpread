import Testing
@testable import SpreadsheetCore

@Suite("Math functions")
struct MathFunctionTests {
    @Test func sumSemantics() {
        // In ranges: text/booleans/blanks ignored.
        #expect(evalNumber("SUM(A1:A4)", cells: ["A1": "1", "A2": "abc", "A3": "TRUE", "A4": "2"]) == 3)
        // Direct literals coerce.
        #expect(evalNumber("SUM(1,\"3\",TRUE)") == 5)
        #expect(evalError("SUM(\"abc\")") == .value)
        #expect(evalNumber("SUM(1,2,3)") == 6)
    }

    @Test func product() {
        #expect(evalNumber("PRODUCT(2,3,4)") == 24)
        #expect(evalNumber("PRODUCT(A1:A3)", cells: ["A1": "2", "A2": "5"]) == 10)
    }

    @Test func absSignSqrt() {
        #expect(evalNumber("ABS(-3)") == 3)
        #expect(evalNumber("SIGN(-3)") == -1)
        #expect(evalNumber("SIGN(0)") == 0)
        #expect(evalNumber("SQRT(16)") == 4)
        #expect(evalError("SQRT(-1)") == .num)
    }

    @Test func logarithms() {
        #expect(approx(evalNumber("EXP(1)"), 2.718281828459045))
        #expect(approx(evalNumber("LN(EXP(2))"), 2))
        #expect(approx(evalNumber("LOG(100)"), 2))
        #expect(approx(evalNumber("LOG(8,2)"), 3))
        #expect(approx(evalNumber("LOG10(1000)"), 3))
        #expect(evalError("LN(0)") == .num)
        #expect(evalError("LN(-5)") == .num)
    }

    @Test func intAndTrunc() {
        #expect(evalNumber("INT(1.9)") == 1)
        #expect(evalNumber("INT(-1.5)") == -2) // floor
        #expect(evalNumber("TRUNC(-1.5)") == -1) // toward zero
        #expect(evalNumber("TRUNC(3.14159,2)") == 3.14)
    }

    @Test func rounding() {
        #expect(evalNumber("ROUND(2.5)") == 3) // half away from zero
        #expect(evalNumber("ROUND(-2.5)") == -3)
        #expect(evalNumber("ROUND(3.14159,2)") == 3.14)
        #expect(evalNumber("ROUND(123,-2)") == 100)
        #expect(evalNumber("ROUNDUP(1.001)") == 2)
        #expect(evalNumber("ROUNDUP(-1.001)") == -2)
        #expect(evalNumber("ROUNDDOWN(1.999)") == 1)
        #expect(evalNumber("ROUNDDOWN(-1.999)") == -1)
        #expect(evalNumber("ROUNDUP(3.2,0)") == 4)
        #expect(evalNumber("ROUNDDOWN(76.9,0)") == 76)
    }

    @Test func ceilingFloorMround() {
        #expect(evalNumber("CEILING(2.5,2)") == 4)
        #expect(evalNumber("CEILING(-2.5,2)") == -2)
        #expect(evalNumber("CEILING(-2.5,-2)") == -4)
        #expect(evalError("CEILING(2.5,-2)") == .num)
        #expect(evalNumber("FLOOR(2.5,2)") == 2)
        #expect(evalNumber("FLOOR(-2.5,2)") == -4)
        #expect(evalNumber("MROUND(10,3)") == 9)
        #expect(approx(evalNumber("MROUND(1.3,0.2)"), 1.4))
        #expect(evalError("MROUND(5,-2)") == .num)
    }

    @Test func modAndQuotient() {
        #expect(evalNumber("MOD(-3,2)") == 1) // sign of divisor
        #expect(evalNumber("MOD(3,-2)") == -1)
        #expect(evalNumber("MOD(10,3)") == 1)
        #expect(evalError("MOD(1,0)") == .div0)
        #expect(evalNumber("QUOTIENT(10,3)") == 3)
        #expect(evalNumber("QUOTIENT(-10,3)") == -3)
    }

    @Test func evenOddFact() {
        #expect(evalNumber("EVEN(1.5)") == 2)
        #expect(evalNumber("EVEN(-1)") == -2)
        #expect(evalNumber("EVEN(2)") == 2)
        #expect(evalNumber("ODD(1.5)") == 3)
        #expect(evalNumber("ODD(0)") == 1)
        #expect(evalNumber("ODD(-2.5)") == -3)
        #expect(evalNumber("FACT(5)") == 120)
        #expect(evalNumber("FACT(0)") == 1)
        #expect(evalError("FACT(-1)") == .num)
        #expect(evalNumber("COMBIN(5,2)") == 10)
    }

    @Test func gcdLcm() {
        #expect(evalNumber("GCD(12,18)") == 6)
        #expect(evalNumber("GCD(7,13)") == 1)
        #expect(evalNumber("LCM(4,6)") == 12)
        #expect(evalNumber("LCM(0,5)") == 0)
    }

    @Test func randomWithFixedClock() {
        #expect(evalNumber("RAND()") == 0.5)
        #expect(evalNumber("RANDBETWEEN(1,10)") == 6) // 1 + floor(10*0.5)
        #expect(evalError("RANDBETWEEN(10,1)") == .num)
    }

    @Test func sumif() {
        let cells = ["A1": "1", "A2": "5", "A3": "10", "B1": "100", "B2": "200", "B3": "300"]
        #expect(evalNumber("SUMIF(A1:A3,\">2\")", cells: cells) == 15)
        #expect(evalNumber("SUMIF(A1:A3,\">2\",B1:B3)", cells: cells) == 500)
        #expect(evalNumber("SUMIF(A1:A3,5,B1:B3)", cells: cells) == 200)
        #expect(evalNumber("SUMIF(A1:A3,\"<>5\")", cells: cells) == 11)
    }

    @Test func sumifWithTextCriteria() {
        let cells = ["A1": "apple", "A2": "banana", "A3": "apricot",
                     "B1": "1", "B2": "2", "B3": "4"]
        #expect(evalNumber("SUMIF(A1:A3,\"ap*\",B1:B3)", cells: cells) == 5)
        #expect(evalNumber("SUMIF(A1:A3,\"banana\",B1:B3)", cells: cells) == 2)
        #expect(evalNumber("SUMIF(A1:A3,\"BANANA\",B1:B3)", cells: cells) == 2) // case-insensitive
    }

    @Test func sumifs() {
        let cells = ["A1": "1", "A2": "2", "A3": "3",
                     "B1": "x", "B2": "y", "B3": "x",
                     "C1": "10", "C2": "20", "C3": "30"]
        #expect(evalNumber("SUMIFS(C1:C3,A1:A3,\">1\",B1:B3,\"x\")", cells: cells) == 30)
        #expect(evalError("SUMIFS(C1:C2,A1:A3,\">1\")", cells: cells) == .value) // dim mismatch
    }

    @Test func sumproduct() {
        let cells = ["A1": "1", "A2": "2", "B1": "3", "B2": "4"]
        #expect(evalNumber("SUMPRODUCT(A1:A2,B1:B2)", cells: cells) == 11)
        #expect(evalError("SUMPRODUCT(A1:A2,B1:B3)", cells: cells) == .value)
        // Text counts as 0.
        #expect(evalNumber("SUMPRODUCT(A1:A2)", cells: ["A1": "2", "A2": "abc"]) == 2)
    }
}

@Suite("Statistical functions")
struct StatFunctionTests {
    let data = ["A1": "4", "A2": "2", "A3": "8", "A4": "6"]

    @Test func averageFamily() {
        #expect(evalNumber("AVERAGE(A1:A4)", cells: data) == 5)
        #expect(evalError("AVERAGE(B1:B2)") == .div0)
        // Text in ranges ignored by AVERAGE, counted as 0 by AVERAGEA.
        let mixed = ["A1": "2", "A2": "abc", "A3": "4"]
        #expect(evalNumber("AVERAGE(A1:A3)", cells: mixed) == 3)
        #expect(evalNumber("AVERAGEA(A1:A3)", cells: mixed) == 2)
    }

    @Test func countFamily() {
        let mixed = ["A1": "1", "A2": "abc", "A3": "TRUE", "A5": "2.5"]
        #expect(evalNumber("COUNT(A1:A5)", cells: mixed) == 2)
        #expect(evalNumber("COUNTA(A1:A5)", cells: mixed) == 4)
        #expect(evalNumber("COUNTBLANK(A1:A5)", cells: mixed) == 1)
        #expect(evalNumber("COUNT(1,\"2\",TRUE)") == 3) // literals coerce
    }

    @Test func countif() {
        let cells = ["A1": "1", "A2": "5", "A3": "10", "A4": "apple", "A5": "APPLE"]
        #expect(evalNumber("COUNTIF(A1:A3,\">2\")", cells: cells) == 2)
        #expect(evalNumber("COUNTIF(A1:A5,\"apple\")", cells: cells) == 2)
        #expect(evalNumber("COUNTIF(A1:A5,\"app*\")", cells: cells) == 2)
        #expect(evalNumber("COUNTIF(A1:A5,\"a??le\")", cells: cells) == 2)
        #expect(evalNumber("COUNTIF(A1:A3,5)", cells: cells) == 1)
        #expect(evalNumber("COUNTIF(A1:A6,\"\")", cells: cells) == 1) // blank A6
        #expect(evalNumber("COUNTIF(A1:A6,\"<>\")", cells: cells) == 5)
    }

    @Test func countifWildcardEscape() {
        // Apostrophe keeps "10%" as literal text (plain "10%" would parse to 0.1).
        let cells = ["A1": "'10%", "A2": "100"]
        #expect(evalNumber("COUNTIF(A1:A2,\"10~%\")", cells: cells) == 1)
    }

    @Test func countifs() {
        let cells = ["A1": "1", "A2": "2", "A3": "3", "B1": "x", "B2": "x", "B3": "y"]
        #expect(evalNumber("COUNTIFS(A1:A3,\">=2\",B1:B3,\"x\")", cells: cells) == 1)
    }

    @Test func countunique() {
        let cells = ["A1": "1", "A2": "1", "A3": "a", "A4": "A", "A5": "2"]
        #expect(evalNumber("COUNTUNIQUE(A1:A5)", cells: cells) == 3)
    }

    @Test func minMax() {
        #expect(evalNumber("MAX(A1:A4)", cells: data) == 8)
        #expect(evalNumber("MIN(A1:A4)", cells: data) == 2)
        #expect(evalNumber("MAX(B1:B3)") == 0) // empty -> 0
        #expect(evalNumber("MAX(1,\"5\",3)") == 5)
    }

    @Test func maxifsMinifs() {
        let cells = ["A1": "1", "A2": "5", "A3": "9", "B1": "x", "B2": "y", "B3": "x"]
        #expect(evalNumber("MAXIFS(A1:A3,B1:B3,\"x\")", cells: cells) == 9)
        #expect(evalNumber("MINIFS(A1:A3,B1:B3,\"x\")", cells: cells) == 1)
        #expect(evalNumber("MAXIFS(A1:A3,B1:B3,\"z\")", cells: cells) == 0)
    }

    @Test func medianModeLargeSmall() {
        #expect(evalNumber("MEDIAN(A1:A4)", cells: data) == 5)
        #expect(evalNumber("MEDIAN(1,2,3)") == 2)
        #expect(evalNumber("MODE(1,2,2,3)") == 2)
        #expect(evalError("MODE(1,2,3)") == .na)
        #expect(evalNumber("LARGE(A1:A4,2)", cells: data) == 6)
        #expect(evalNumber("SMALL(A1:A4,2)", cells: data) == 4)
        #expect(evalError("LARGE(A1:A4,5)", cells: data) == .num)
        #expect(evalError("SMALL(A1:A4,0)", cells: data) == .num)
    }

    @Test func rank() {
        #expect(evalNumber("RANK(6,A1:A4)", cells: data) == 2) // descending default
        #expect(evalNumber("RANK(6,A1:A4,TRUE)", cells: data) == 3)
        #expect(evalError("RANK(7,A1:A4)", cells: data) == .na)
    }

    @Test func percentileQuartile() {
        let cells = ["A1": "1", "A2": "2", "A3": "3", "A4": "4"]
        #expect(approx(evalNumber("PERCENTILE(A1:A4,0.5)", cells: cells), 2.5))
        #expect(approx(evalNumber("PERCENTILE(A1:A4,0)", cells: cells), 1))
        #expect(approx(evalNumber("PERCENTILE(A1:A4,1)", cells: cells), 4))
        #expect(approx(evalNumber("QUARTILE(A1:A4,1)", cells: cells), 1.75))
        #expect(evalError("PERCENTILE(A1:A4,1.5)", cells: cells) == .num)
    }

    @Test func varianceAndStdev() {
        let cells = ["A1": "2", "A2": "4", "A3": "4", "A4": "6"]
        #expect(approx(evalNumber("VARP(A1:A4)", cells: cells), 2))
        #expect(approx(evalNumber("VAR(A1:A4)", cells: cells), 8.0 / 3.0))
        #expect(approx(evalNumber("STDEVP(A1:A4)", cells: cells), 2.0.squareRoot()))
        #expect(approx(evalNumber("STDEV(A1:A4)", cells: cells), (8.0 / 3.0).squareRoot()))
        #expect(evalError("STDEV(A1:A1)", cells: cells) == .div0)
    }

    @Test func averageif() {
        let cells = ["A1": "1", "A2": "5", "A3": "9"]
        #expect(evalNumber("AVERAGEIF(A1:A3,\">1\")", cells: cells) == 7)
        #expect(evalError("AVERAGEIF(A1:A3,\">100\")", cells: cells) == .div0)
        let paired = ["A1": "x", "A2": "y", "A3": "x", "B1": "10", "B2": "20", "B3": "30"]
        #expect(evalNumber("AVERAGEIF(A1:A3,\"x\",B1:B3)", cells: paired) == 20)
        #expect(evalNumber("AVERAGEIFS(B1:B3,A1:A3,\"x\")", cells: paired) == 20)
    }
}
