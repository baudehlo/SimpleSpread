import Testing
@testable import SpreadsheetCore

/// Code review finding #23: criteria functions.
@Suite("Criteria functions: Excel parity")
struct CriteriaExcelTests {
    /// A column of VLOOKUP-style results with one #N/A in it.
    let withError: [String: String] = [
        "A1": "1", "A2": "=NA()", "A3": "3",
        "B1": "10", "B2": "20", "B3": "30",
    ]

    @Test func errorCellsInCriteriaRangesAreTestedNotThrown() {
        #expect(evalNumber("COUNTIF(A1:A3,\">0\")", cells: withError) == 2)
        #expect(evalNumber("COUNTIFS(A1:A3,\">0\")", cells: withError) == 2)
        #expect(evalNumber("SUMIF(A1:A3,\">0\",B1:B3)", cells: withError) == 40)
        #expect(evalNumber("SUMIFS(B1:B3,A1:A3,\">1\")", cells: withError) == 30)
        #expect(evalNumber("AVERAGEIF(A1:A3,\">0\",B1:B3)", cells: withError) == 20)
        #expect(evalNumber("AVERAGEIFS(B1:B3,A1:A3,\">0\")", cells: withError) == 20)
        #expect(evalNumber("MAXIFS(B1:B3,A1:A3,\">0\")", cells: withError) == 30)
        #expect(evalNumber("MINIFS(B1:B3,A1:A3,\"<>1\")", cells: withError) == 20)
        // "<>x" matches error cells too (they are not x).
        #expect(evalNumber("COUNTIF(A1:A3,\"<>1\")", cells: withError) == 2)
    }

    @Test func errorCriteriaMatchErrorCells() {
        #expect(evalNumber("COUNTIF(A1:A3,\"#N/A\")", cells: withError) == 1)
        #expect(evalNumber("COUNTIFS(A1:A3,\"#N/A\")", cells: withError) == 1)
        #expect(evalNumber("SUMIF(A1:A3,\"#N/A\",B1:B3)", cells: withError) == 20)
        #expect(evalNumber("COUNTIF(A1:A3,\"<>#N/A\")", cells: withError) == 2)
        #expect(evalNumber("COUNTIF(A1:A3,\"#DIV/0!\")", cells: withError) == 0)
    }

    @Test func errorsInTheSummedCellsStillPropagate() {
        let cells = ["A1": "x", "A2": "y", "B1": "=1/0", "B2": "5"]
        #expect(evalError("SUMIF(A1:A2,\"x\",B1:B2)", cells: cells) == .div0)
        #expect(evalNumber("SUMIF(A1:A2,\"y\",B1:B2)", cells: cells) == 5)
        #expect(evalError("SUMIFS(B1:B2,A1:A2,\"x\")", cells: cells) == .div0)
    }

    @Test func dateCriteriaParseLikeTypedInput() {
        let dates = ["A1": "12/15/2023", "A2": "1/1/2024", "A3": "2/1/2024", "B1": "1", "B2": "2", "B3": "4"]
        #expect(evalNumber("COUNTIF(A1:A3,\">=1/1/2024\")", cells: dates) == 2)
        #expect(evalNumber("COUNTIF(A1:A3,\"<1/1/2024\")", cells: dates) == 1)
        #expect(evalNumber("COUNTIF(A1:A3,\"1/1/2024\")", cells: dates) == 1)
        #expect(evalNumber("SUMIFS(B1:B3,A1:A3,\">=1/1/2024\",A1:A3,\"<2/1/2024\")", cells: dates) == 2)
        #expect(evalNumber("COUNTIF(A1:A3,\">=\"&DATE(2024,1,1))", cells: dates) == 2)
        // Existing operand forms still work.
        let nums = ["A1": "0.5", "A2": "5", "A3": "TRUE"]
        #expect(evalNumber("COUNTIF(A1:A3,\"50%\")", cells: nums) == 1)
        #expect(evalNumber("COUNTIF(A1:A3,\">$4\")", cells: nums) == 1)
        #expect(evalNumber("COUNTIF(A1:A3,\"true\")", cells: nums) == 1)
    }
}
