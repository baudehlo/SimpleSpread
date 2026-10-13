import Testing
@testable import SpreadsheetCore

/// Code review findings #25 (blank lookup key), #35 (XLOOKUP with a 2-D
/// return range) and #36 (approximate lookups use binary search).
@Suite("Lookups: Excel parity")
struct LookupExcelTests {
    /// The table's first key cell is blank; its row holds data.
    let table: [String: String] = [
        "B1": "secret", "A2": "1", "B2": "one", "A3": "2", "B3": "two",
        "E2": "secret",
    ]

    @Test func blankKeyNeverMatchesBlankCells() {
        #expect(evalError("VLOOKUP(C1,A1:B3,2,FALSE)", cells: table) == .na)
        #expect(evalError("VLOOKUP(C1,A1:B3,2,TRUE)", cells: table) == .na)
        #expect(evalError("MATCH(C1,A1:A3,0)", cells: table) == .na)
        #expect(evalError("XLOOKUP(C1,A1:A3,B1:B3)", cells: table) == .na)
        #expect(evalString("XLOOKUP(C1,A1:A3,B1:B3,\"none\")", cells: table) == "none")
        #expect(evalError("LOOKUP(C1,A1:A3,B1:B3)", cells: table) == .na)
        let row = ["B1": "1", "C1": "2", "A2": "secret", "B2": "one", "C2": "two"]
        #expect(evalError("HLOOKUP(D5,A1:C2,2,FALSE)", cells: row) == .na)
        // Real keys still match.
        #expect(evalString("VLOOKUP(2,A1:B3,2,FALSE)", cells: table) == "two")
    }

    @Test func xlookupTwoDimensionalReturnRange() {
        let cells = [
            "A1": "a", "A2": "b", "A3": "c",
            "B1": "1", "C1": "2", "B2": "3", "C2": "4", "B3": "5", "C3": "6",
        ]
        // The matching ROW of B1:C3; one cell shows its first value.
        #expect(evalNumber("XLOOKUP(\"b\",A1:A3,B1:C3)", cells: cells) == 3)
        #expect(evalNumber("XLOOKUP(\"c\",A1:A3,B1:C3)", cells: cells) == 5)
        // Horizontal: the matching COLUMN.
        let across = [
            "A1": "a", "B1": "b", "C1": "c",
            "A2": "1", "B2": "2", "C2": "3", "A3": "4", "B3": "5", "C3": "6",
        ]
        #expect(evalNumber("XLOOKUP(\"b\",A1:C1,A2:C3)", cells: across) == 2)
        #expect(evalNumber("XLOOKUP(\"c\",A1:C1,A2:C3)", cells: across) == 3)
        // Shapes that do not line up are #VALUE!.
        #expect(evalError("XLOOKUP(\"b\",A1:A3,A1:C1)", cells: cells) == .value)
    }

    @Test func approximateMatchIsABinarySearch() {
        // Unsorted data: Excel's binary search, not "last value <= key".
        let unsorted = ["A1": "1", "A2": "3", "A3": "7", "A4": "2", "A5": "9",
                        "B1": "a", "B2": "b", "B3": "c", "B4": "d", "B5": "e"]
        #expect(evalString("VLOOKUP(5,A1:B5,2)", cells: unsorted) == "b")
        #expect(evalNumber("MATCH(5,A1:A5,1)", cells: unsorted) == 2)
        #expect(evalString("LOOKUP(5,A1:A5,B1:B5)", cells: unsorted) == "b")
        // Duplicates: the last of the equal run.
        let dup = ["A1": "1", "A2": "2", "A3": "2", "A4": "2", "A5": "3"]
        #expect(evalNumber("MATCH(2,A1:A5,1)", cells: dup) == 4)
        #expect(evalNumber("MATCH(2.5,A1:A5)", cells: dup) == 4)
        #expect(evalNumber("MATCH(99,A1:A5)", cells: dup) == 5)
        #expect(evalError("MATCH(0,A1:A5)", cells: dup) == .na)
        // Descending, match type -1: smallest value >= key.
        let desc = ["A1": "9", "A2": "7", "A3": "5", "A4": "3", "A5": "1"]
        #expect(evalNumber("MATCH(4,A1:A5,-1)", cells: desc) == 3)
        #expect(evalNumber("MATCH(9,A1:A5,-1)", cells: desc) == 1)
        #expect(evalNumber("MATCH(1,A1:A5,-1)", cells: desc) == 5)
        #expect(evalError("MATCH(10,A1:A5,-1)", cells: desc) == .na)
        // Text keys, case-insensitive.
        let words = ["A1": "apple", "A2": "Banana", "A3": "cherry"]
        #expect(evalNumber("MATCH(\"blueberry\",A1:A3)", cells: words) == 2)
        #expect(evalNumber("MATCH(\"BANANA\",A1:A3)", cells: words) == 2)
    }

    @Test func binarySearchSkipsOtherTypesAndBlanks() {
        // The LOOKUP(big, col) idiom: last number in a mixed column.
        let mixed = ["A1": "1", "A2": "a", "A3": "2", "A5": "b", "A6": "4", "A7": "c"]
        #expect(evalNumber("LOOKUP(9.99E+307,A1:A8)", cells: mixed) == 4)
        #expect(evalString("LOOKUP(REPT(\"z\",50),A1:A8)", cells: mixed) == "c")
        #expect(evalNumber("MATCH(9.99E+307,A1:A8)", cells: mixed) == 6)
        #expect(evalError("LOOKUP(0,A1:A8)", cells: mixed) == .na)
    }

    @Test func lookupArrayForm() {
        // More rows than columns: search the first column, return the last.
        let tall = ["A1": "1", "B1": "one", "A2": "2", "B2": "two", "A3": "3", "B3": "three"]
        #expect(evalString("LOOKUP(2,A1:B3)", cells: tall) == "two")
        // Square counts as tall.
        let square = ["A1": "1", "B1": "one", "A2": "2", "B2": "two"]
        #expect(evalString("LOOKUP(2,A1:B2)", cells: square) == "two")
        // More columns than rows: search the first row, return the last row.
        let wide = ["A1": "1", "B1": "2", "C1": "3", "A2": "one", "B2": "two", "C2": "three"]
        #expect(evalString("LOOKUP(2.5,A1:C2)", cells: wide) == "two")
    }
}
