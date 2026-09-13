import Testing
@testable import SpreadsheetCore

@Suite("Cell addressing")
struct AddressTests {
    @Test func columnNames() {
        #expect(CellAddress.columnName(0) == "A")
        #expect(CellAddress.columnName(25) == "Z")
        #expect(CellAddress.columnName(26) == "AA")
        #expect(CellAddress.columnName(51) == "AZ")
        #expect(CellAddress.columnName(52) == "BA")
        #expect(CellAddress.columnName(701) == "ZZ")
        #expect(CellAddress.columnName(702) == "AAA")
        #expect(CellAddress.columnName(16383) == "XFD")
    }

    @Test func columnIndexRoundTrip() {
        for col in [0, 1, 25, 26, 27, 700, 701, 702, 16383] {
            #expect(CellAddress.columnIndex(CellAddress.columnName(col)) == col)
        }
        #expect(CellAddress.columnIndex("a") == 0)
        #expect(CellAddress.columnIndex("") == nil)
        #expect(CellAddress.columnIndex("A1") == nil)
    }

    @Test func a1Parsing() {
        #expect(CellAddress(a1: "A1") == CellAddress(row: 0, column: 0))
        #expect(CellAddress(a1: "B12") == CellAddress(row: 11, column: 1))
        #expect(CellAddress(a1: "aa100") == CellAddress(row: 99, column: 26))
        #expect(CellAddress(a1: "$C$5") == CellAddress(row: 4, column: 2))
        #expect(CellAddress(a1: "") == nil)
        #expect(CellAddress(a1: "12") == nil)
        #expect(CellAddress(a1: "ABCD1") == nil)
        #expect(CellAddress(a1: "A0") == nil)
        #expect(CellAddress(a1: "A-1") == nil)
        #expect(CellAddress(a1: "A1B") == nil)
    }

    @Test func absoluteFlags() {
        let (_, colAbs1, rowAbs1) = CellAddress.parseA1("$A$1")!
        #expect(colAbs1 && rowAbs1)
        let (_, colAbs2, rowAbs2) = CellAddress.parseA1("A$1")!
        #expect(!colAbs2 && rowAbs2)
        let (_, colAbs3, rowAbs3) = CellAddress.parseA1("$A1")!
        #expect(colAbs3 && !rowAbs3)
    }

    @Test func a1Rendering() {
        #expect(CellAddress(row: 0, column: 0).a1 == "A1")
        #expect(CellAddress(row: 11, column: 27).a1 == "AB12")
    }

    @Test func rangeNormalization() {
        let r = CellRange(start: CellAddress(a1: "C5")!, end: CellAddress(a1: "A2")!)
        #expect(r.start == CellAddress(a1: "A2"))
        #expect(r.end == CellAddress(a1: "C5"))
        #expect(r.rowCount == 4)
        #expect(r.columnCount == 3)
        #expect(r.cellCount == 12)
    }

    @Test func rangeParsing() {
        #expect(CellRange(a1: "A1:B2")?.a1 == "A1:B2")
        #expect(CellRange(a1: "B2:A1")?.a1 == "A1:B2")
        #expect(CellRange(a1: "C3")?.a1 == "C3")
        #expect(CellRange(a1: "C3")?.isSingleCell == true)
        #expect(CellRange(a1: "1:2") == nil)
    }

    @Test func rangeContainsAndIntersects() {
        let r = CellRange(a1: "B2:D4")!
        #expect(r.contains(CellAddress(a1: "B2")!))
        #expect(r.contains(CellAddress(a1: "C3")!))
        #expect(r.contains(CellAddress(a1: "D4")!))
        #expect(!r.contains(CellAddress(a1: "A1")!))
        #expect(!r.contains(CellAddress(a1: "E4")!))
        #expect(r.intersects(CellRange(a1: "D4:F6")!))
        #expect(!r.intersects(CellRange(a1: "E5:F6")!))
        #expect(r.union(CellRange(a1: "E5")!).a1 == "B2:E5")
    }

    @Test func rangeAddressIteration() {
        let r = CellRange(a1: "A1:B2")!
        #expect(r.addresses.map(\.a1) == ["A1", "B1", "A2", "B2"])
    }
}
