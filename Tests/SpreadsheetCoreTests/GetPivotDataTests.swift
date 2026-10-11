import Foundation
import Testing
@testable import SpreadsheetCore

private struct NoPayload: PreservedPartPayload {}

/// Sheet1 holds a hand-built pivot: Region on rows, Year as a report filter
/// set to 2025, Sum of Sales. Filter at A1:B1, body at A3:B6.
private func makeHarness(selectedYear: Int? = 1) -> Harness {
    let h = Harness(cells: [
        "A1": "Year", "B1": "2025",
        "A3": "Row Labels", "B3": "Sum of Sales",
        "A4": "East", "B4": "10",
        "A5": "West", "B5": "20",
        "A6": "Grand Total", "B6": "30",
    ])
    let wb = h.workbook
    let cache = PivotCacheData(fields: [
        PivotCacheField(name: "Region", sharedItems: [.string("East"), .string("West")]),
        PivotCacheField(name: "Year", sharedItems: [.number(2024), .number(2025)]),
        PivotCacheField(name: "Sales"),
    ], records: [])
    let regionItems = [PivotItem(index: 0), PivotItem(index: 1), PivotItem(kind: .default)]
    let yearItems = [PivotItem(index: 0), PivotItem(index: 1), PivotItem(kind: .default)]
    let definition = PivotDefinition(
        name: "PivotTable1",
        fields: [PivotFieldSettings(axis: .row, items: regionItems),
                 PivotFieldSettings(axis: .page, items: yearItems),
                 PivotFieldSettings(isDataField: true)],
        rowFields: [0], pageFields: [PivotPageField(field: 1, selectedItem: selectedYear)],
        dataFields: [PivotDataField(name: "Sum of Sales", field: 2)],
        rowLines: [PivotAxisLine(members: [0]), PivotAxisLine(members: [1]), PivotAxisLine(kind: .grand, members: [0])],
        columnLines: [PivotAxisLine()], firstHeaderRow: 1, firstDataRow: 1, firstDataCol: 1)
    wb.pivotCaches = [PivotCache(cacheID: 1, sourceRanges: [], payload: NoPayload(), data: cache)]
    wb.pivotTables = [PivotTable(sheetID: h.sheetID, name: "PivotTable1", cacheID: 1,
                                 location: CellRange(a1: "A3:B6")!, pageFieldRows: 1, pageFieldColumns: 1,
                                 payload: NoPayload(), definition: definition)]
    return h
}

@Suite("GETPIVOTDATA")
struct GetPivotDataTests {
    @Test func itemsAndGrandTotal() {
        let h = makeHarness()
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Region","West")"#) == .number(20))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",B5,"Region","East")"#) == .number(10))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3)"#) == .number(30))
    }

    @Test func namesIgnoreCaseAndTakeTheSourceFieldName() {
        let h = makeHarness()
        #expect(h.eval(#"GETPIVOTDATA("sum of sales",A3,"REGION","west")"#) == .number(20))
        #expect(h.eval(#"GETPIVOTDATA("Sales",A3,"Region","West")"#) == .number(20))
    }

    @Test func reportFilterMustMatchItsSelection() {
        let h = makeHarness()
        // The filter cell (A1) also identifies the pivot.
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A1,"Year",2025)"#) == .number(30))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Year","2025","Region","East")"#) == .number(10))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Year",2024)"#) == .error(.ref))
        // Filter showing (All): no single year's data is displayed.
        let all = makeHarness(selectedYear: nil)
        #expect(all.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Year",2025)"#) == .error(.ref))
        #expect(all.eval(#"GETPIVOTDATA("Sum of Sales",A3)"#) == .number(30))
    }

    @Test func unknownNamesAndNonPivotReferencesAreRefErrors() {
        let h = makeHarness()
        #expect(h.eval(#"GETPIVOTDATA("Sum of Cost",A3)"#) == .error(.ref))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Country","East")"#) == .error(.ref))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Region","North")"#) == .error(.ref))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Region")"#) == .error(.ref))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",C3)"#) == .error(.ref))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales","A3")"#) == .error(.ref))
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A2)"#) == .number(30)) // the blank row above the body
    }

    @Test func blankPivotCellReadsAsZero() {
        let h = makeHarness()
        h.workbook.sheets[0].setCell(Cell(), at: CellAddress(a1: "B4")!)
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3,"Region","East")"#) == .number(0))
    }

    @Test func recalculatesWhenThePivotsCellsChange() {
        let h = makeHarness()
        h.set("D1", #"=GETPIVOTDATA("Sum of Sales",A3,"Region","West")"#)
        #expect(h.value("D1") == .number(20))
        // The formula names only A3; a refresh rewriting B5 must still reach it.
        h.set("B5", "25")
        #expect(h.value("D1") == .number(25))
        #expect(FunctionRegistry.volatileFunctions.contains("GETPIVOTDATA"))
    }

    @Test func noDefinitionMeansRefError() {
        let h = makeHarness()
        h.workbook.pivotTables[0].definition = nil
        #expect(h.eval(#"GETPIVOTDATA("Sum of Sales",A3)"#) == .error(.ref))
    }
}
