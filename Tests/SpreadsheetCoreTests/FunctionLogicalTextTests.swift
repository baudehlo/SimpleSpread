import Testing
@testable import SpreadsheetCore

@Suite("Logical functions")
struct LogicalFunctionTests {
    @Test func ifBasics() {
        #expect(evalNumber("IF(TRUE,1,2)") == 1)
        #expect(evalNumber("IF(FALSE,1,2)") == 2)
        #expect(evalBool("IF(FALSE,1)") == false) // missing else -> FALSE
        #expect(evalNumber("IF(5,1,2)") == 1) // nonzero -> TRUE
        #expect(evalNumber("IF(0,1,2)") == 2)
        #expect(evalNumber("IF(A1,1,2)") == 2) // blank -> FALSE
        #expect(evalError("IF(\"abc\",1,2)") == .value)
    }

    @Test func ifIsLazy() {
        // The untaken branch must not be evaluated.
        #expect(evalNumber("IF(TRUE,1,1/0)") == 1)
        #expect(evalNumber("IF(FALSE,1/0,2)") == 2)
        // Condition errors propagate.
        #expect(evalError("IF(1/0,1,2)") == .div0)
    }

    @Test func ifs() {
        #expect(evalNumber("IFS(FALSE,1,TRUE,2)") == 2)
        #expect(evalError("IFS(FALSE,1,FALSE,2)") == .na)
        #expect(evalNumber("IFS(TRUE,1,TRUE,1/0)") == 1) // lazy
    }

    @Test func iferrorAndIfna() {
        #expect(evalNumber("IFERROR(1/0,42)") == 42)
        #expect(evalNumber("IFERROR(7,42)") == 7)
        #expect(evalFormula("IFERROR(1/0)") == .empty) // one-arg returns blank
        #expect(evalNumber("IFNA(NA(),9)") == 9)
        #expect(evalError("IFNA(1/0,9)") == .div0) // only catches #N/A
        #expect(evalString("IFERROR(VLOOKUP(\"x\",A1:B2,2,FALSE),\"missing\")") == "missing")
    }

    @Test func andOrNotXor() {
        #expect(evalBool("AND(TRUE,TRUE)") == true)
        #expect(evalBool("AND(TRUE,FALSE)") == false)
        #expect(evalBool("OR(FALSE,TRUE)") == true)
        #expect(evalBool("OR(FALSE,FALSE)") == false)
        #expect(evalBool("NOT(TRUE)") == false)
        #expect(evalBool("XOR(TRUE,TRUE)") == false)
        #expect(evalBool("XOR(TRUE,FALSE,FALSE)") == true)
        #expect(evalBool("AND(1,2)") == true)
        #expect(evalBool("AND(1,0)") == false)
        // Ranges: text/blank skipped.
        let cells = ["A1": "TRUE", "A2": "abc", "A3": "FALSE"]
        #expect(evalBool("AND(A1:A3)", cells: cells) == false)
        #expect(evalBool("OR(A1:A3)", cells: cells) == true)
        // Nothing logical at all -> #VALUE!.
        #expect(evalError("AND(B1:B2)", cells: ["B1": "x"]) == .value)
        #expect(evalError("AND(\"abc\")") == .value)
    }

    @Test func switchFunction() {
        #expect(evalString("SWITCH(2,1,\"one\",2,\"two\",3,\"three\")") == "two")
        #expect(evalString("SWITCH(9,1,\"one\",\"other\")") == "other")
        #expect(evalError("SWITCH(9,1,\"one\")") == .na)
        #expect(evalString("SWITCH(\"B\",\"a\",\"x\",\"b\",\"y\")") == "y") // case-insensitive
    }

    @Test func trueFalseFunctions() {
        #expect(evalBool("TRUE()") == true)
        #expect(evalBool("FALSE()") == false)
    }
}

@Suite("Text functions")
struct TextFunctionTests {
    @Test func concatenateAndJoin() {
        #expect(evalString("CONCATENATE(\"a\",\"b\",1)") == "ab1")
        #expect(evalString("CONCAT(\"x\",\"y\")") == "xy")
        let cells = ["A1": "a", "B1": "b", "A2": "c"]
        #expect(evalString("CONCATENATE(A1:B2)", cells: cells) == "abc")
        #expect(evalString("TEXTJOIN(\"-\",TRUE,\"a\",\"\",\"b\")") == "a-b")
        #expect(evalString("TEXTJOIN(\"-\",FALSE,\"a\",\"\",\"b\")") == "a--b")
        #expect(evalString("TEXTJOIN(\", \",TRUE,A1:B2)", cells: cells) == "a, b, c")
    }

    @Test func leftRightMid() {
        #expect(evalString("LEFT(\"hello\",2)") == "he")
        #expect(evalString("LEFT(\"hello\")") == "h")
        #expect(evalString("LEFT(\"hi\",10)") == "hi")
        #expect(evalError("LEFT(\"hi\",-1)") == .value)
        #expect(evalString("RIGHT(\"hello\",3)") == "llo")
        #expect(evalString("MID(\"hello\",2,3)") == "ell")
        #expect(evalString("MID(\"hello\",10,3)") == "")
        #expect(evalError("MID(\"hello\",0,3)") == .value)
    }

    @Test func lenAndCase() {
        #expect(evalNumber("LEN(\"hello\")") == 5)
        #expect(evalNumber("LEN(\"\")") == 0)
        #expect(evalNumber("LEN(123)") == 3)
        #expect(evalString("UPPER(\"aBc\")") == "ABC")
        #expect(evalString("LOWER(\"aBc\")") == "abc")
        #expect(evalString("PROPER(\"hello world-foo\")") == "Hello World-Foo")
    }

    @Test func findAndSearch() {
        #expect(evalNumber("FIND(\"l\",\"hello\")") == 3)
        #expect(evalNumber("FIND(\"l\",\"hello\",4)") == 4)
        #expect(evalError("FIND(\"L\",\"hello\")") == .value) // case-sensitive
        #expect(evalError("FIND(\"z\",\"hello\")") == .value)
        #expect(evalNumber("SEARCH(\"L\",\"hello\")") == 3) // case-insensitive
        #expect(evalNumber("SEARCH(\"l?o\",\"hello\")") == 3) // wildcards
        #expect(evalNumber("SEARCH(\"o*d\",\"o world\")") == 1)
        #expect(evalError("SEARCH(\"z\",\"hello\")") == .value)
    }

    @Test func substituteAndReplace() {
        #expect(evalString("SUBSTITUTE(\"a-b-c\",\"-\",\"+\")") == "a+b+c")
        #expect(evalString("SUBSTITUTE(\"a-b-c\",\"-\",\"+\",2)") == "a-b+c")
        #expect(evalString("SUBSTITUTE(\"aaa\",\"a\",\"b\",5)") == "aaa")
        #expect(evalString("REPLACE(\"hello\",2,3,\"XYZ\")") == "hXYZo")
        #expect(evalString("REPLACE(\"hello\",6,0,\"!\")") == "hello!")
    }

    @Test func trimCleanRept() {
        #expect(evalString("TRIM(\"  a   b  \")") == "a b") // collapses runs
        #expect(evalString("CLEAN(\"a\"&CHAR(7)&\"b\")") == "ab")
        #expect(evalString("REPT(\"ab\",3)") == "ababab")
        #expect(evalString("REPT(\"x\",0)") == "")
        #expect(evalError("REPT(\"x\",-1)") == .value)
    }

    @Test func exactVsEquals() {
        #expect(evalBool("EXACT(\"a\",\"a\")") == true)
        #expect(evalBool("EXACT(\"a\",\"A\")") == false)
        #expect(evalBool("\"a\"=\"A\"") == true)
    }

    @Test func textFunction() {
        #expect(evalString("TEXT(12.345,\"0.00\")") == "12.35")
        #expect(evalString("TEXT(0.85,\"0%\")") == "85%")
        #expect(evalString("TEXT(1234.5,\"#,##0\")") == "1,235")
        #expect(evalString("TEXT(DATE(2026,9,13),\"yyyy-mm-dd\")") == "2026-09-13")
        #expect(evalString("TEXT(12.3,\"000.00\")") == "012.30")
        #expect(evalString("\"x\"&DATE(2020,1,1)") == "x43831") // serial when concatenated
    }

    @Test func valueFunction() {
        #expect(evalNumber("VALUE(\"1,234.5\")") == 1234.5)
        #expect(evalNumber("VALUE(\"50%\")") == 0.5)
        #expect(evalNumber("VALUE(\"$12\")") == 12)
        #expect(evalNumber("VALUE(\"2026-09-13\")") == 46278)
        #expect(evalError("VALUE(\"abc\")") == .value)
    }

    @Test func charCodeT() {
        #expect(evalString("CHAR(65)") == "A")
        #expect(evalNumber("CODE(\"A\")") == 65)
        #expect(evalError("CHAR(0)") == .value)
        #expect(evalString("T(\"abc\")") == "abc")
        #expect(evalString("T(123)") == "")
    }

    @Test func regexFunctions() {
        #expect(evalBool("REGEXMATCH(\"hello123\",\"[0-9]+\")") == true)
        #expect(evalBool("REGEXMATCH(\"hello\",\"^[0-9]+$\")") == false)
        #expect(evalString("REGEXEXTRACT(\"item-42-x\",\"[0-9]+\")") == "42")
        #expect(evalString("REGEXEXTRACT(\"a1b2\",\"([a-z])([0-9])\")") == "a") // first group
        #expect(evalError("REGEXEXTRACT(\"abc\",\"[0-9]+\")") == .na)
        #expect(evalString("REGEXREPLACE(\"a1b2\",\"[0-9]\",\"_\")") == "a_b_")
        #expect(evalError("REGEXMATCH(\"x\",\"[\")") == .value) // bad pattern
    }
}
