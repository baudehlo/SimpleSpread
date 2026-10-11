import Foundation
import Testing
@testable import SpreadsheetCore

private struct NoPayload: PreservedPartPayload {}

/// A workbook with a "Data" source sheet and a "Report" sheet holding one
/// pivot table at `location` fed from Data!A1:C10.
private func makeWorkbook(location: String = "B5:D12", pageRows: Int = 0, pageColumns: Int = 0,
                          sourceRef: String = "A1:C10") -> (Workbook, data: Sheet, report: Sheet) {
    let wb = Workbook()
    let data = wb.addSheet(named: "Data")
    let report = wb.addSheet(named: "Report")
    wb.pivotCaches = [PivotCache(cacheID: 7, sourceRanges: [PivotSourceRange(target: .sheet(id: data.id), ref: sourceRef)],
                                 payload: NoPayload())]
    wb.pivotTables = [PivotTable(sheetID: report.id, name: "PivotTable1", cacheID: 7,
                                 location: CellRange(a1: location)!, pageFieldRows: pageRows,
                                 pageFieldColumns: pageColumns, payload: NoPayload())]
    wb.preservedStyles = PreservedStyles()
    return (wb, data, report)
}

@Suite("Pivot tables: occupied area")
struct PivotOccupiedAreaTests {
    @Test func bodyOnlyWithoutFilters() {
        let (wb, _, _) = makeWorkbook(location: "B5:D12")
        #expect(wb.pivotTables[0].occupiedRange.a1 == "B5:D12")
    }

    @Test func filtersSitAboveWithABlankRow() {
        // Two filters, one column of them: rows 2-3, blank row 4, body from 5.
        let (wb, _, _) = makeWorkbook(location: "B5:D12", pageRows: 2, pageColumns: 1)
        #expect(wb.pivotTables[0].occupiedRange.a1 == "B2:D12")
    }

    @Test func wrappedFilterColumnsWidenTheArea() {
        // Three filter columns: label+value each, blank column between = 8 wide.
        let (wb, _, _) = makeWorkbook(location: "B5:C12", pageRows: 1, pageColumns: 3)
        #expect(wb.pivotTables[0].occupiedRange.a1 == "B3:I12")
    }

    @Test func filtersNeverReachAboveRowOne() {
        let (wb, _, _) = makeWorkbook(location: "A2:B4", pageRows: 3, pageColumns: 1)
        #expect(wb.pivotTables[0].occupiedRange.a1 == "A1:B4")
        let (wb2, _, _) = makeWorkbook(location: "A1:B4", pageRows: 2, pageColumns: 1)
        #expect(wb2.pivotTables[0].occupiedRange.a1 == "A1:B4")
    }

    @Test func intersectionLookupIsPerSheet() {
        let (wb, data, report) = makeWorkbook(location: "B5:D12")
        #expect(wb.pivotTables(intersecting: CellRange(a1: "D12")!, onSheet: report.id).count == 1)
        #expect(wb.pivotTables(intersecting: CellRange(a1: "E12")!, onSheet: report.id).isEmpty)
        #expect(wb.pivotTables(intersecting: CellRange(a1: "D12")!, onSheet: data.id).isEmpty)
    }
}

@Suite("Pivot tables: structural edits")
struct PivotStructuralEditTests {
    // Rows 5-12 (indices 4...11) hold the body of B5:D12.

    @Test func insertingRowsAboveShiftsTheTable() {
        let (wb, _, report) = makeWorkbook()
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 4, count: 2) == nil)
        WorkbookOperations.insertRows(in: wb, sheetID: report.id, at: 4, count: 2) // at row 5 itself
        #expect(wb.pivotTables[0].location.a1 == "B7:D14")
    }

    @Test func insertingRowsBelowLeavesItAlone() {
        let (wb, _, report) = makeWorkbook()
        WorkbookOperations.insertRows(in: wb, sheetID: report.id, at: 12, count: 3)
        #expect(wb.pivotTables[0].location.a1 == "B5:D12")
    }

    @Test func insertingRowsThroughTheTableIsASplit() {
        let (wb, _, report) = makeWorkbook()
        for index in 5...11 {
            #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true,
                                                       index: index, count: 1)?.name == "PivotTable1")
        }
    }

    @Test func insertingBetweenFiltersAndBodyIsASplit() {
        let (wb, _, report) = makeWorkbook(pageRows: 1, pageColumns: 1) // filter row 3, blank 4
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 3, count: 1) != nil)
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 2, count: 1) == nil)
    }

    @Test func columnEditsFollowTheSameRules() {
        let (wb, _, report) = makeWorkbook() // columns B-D = 1...3
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: false, index: 2, count: 1) != nil)
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: false, index: 2, count: -1) != nil)
        WorkbookOperations.insertColumns(in: wb, sheetID: report.id, at: 0, count: 1)
        #expect(wb.pivotTables[0].location.a1 == "C5:E12")
        WorkbookOperations.deleteColumns(in: wb, sheetID: report.id, at: 0, count: 2) // A and B (empty)
        #expect(wb.pivotTables[0].location.a1 == "A5:C12")
        WorkbookOperations.insertColumns(in: wb, sheetID: report.id, at: 3, count: 1) // right of it
        #expect(wb.pivotTables[0].location.a1 == "A5:C12")
    }

    @Test func deletingRowsAboveShiftsUp() {
        let (wb, _, report) = makeWorkbook()
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 1, count: -3) == nil)
        WorkbookOperations.deleteRows(in: wb, sheetID: report.id, at: 1, count: 3) // rows 2-4
        #expect(wb.pivotTables[0].location.a1 == "B2:D9")
    }

    @Test func deletingPartOfTheTableIsASplit() {
        let (wb, _, report) = makeWorkbook()
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 3, count: -2) != nil)
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 11, count: -2) != nil)
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 6, count: -1) != nil)
    }

    @Test func deletingEveryRowOfTheTableRemovesItAndItsCache() {
        let (wb, _, report) = makeWorkbook()
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 2, count: -12) == nil)
        WorkbookOperations.deleteRows(in: wb, sheetID: report.id, at: 2, count: 12)
        #expect(wb.pivotTables.isEmpty)
        #expect(wb.pivotCaches.isEmpty)
        #expect(wb.preservedStyles == nil)
    }

    @Test func aSplitThatSlipsThroughRemovesTheTableRatherThanCorruptIt() {
        let (wb, _, report) = makeWorkbook()
        WorkbookOperations.insertRows(in: wb, sheetID: report.id, at: 6, count: 1)
        #expect(wb.pivotTables.isEmpty)
    }

    @Test func pushingATableOffTheSheetIsASplit() {
        let (wb, _, report) = makeWorkbook(location: "B1048570:C1048573")
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 0, count: 10) != nil)
        #expect(WorkbookOperations.pivotTableSplit(in: wb, sheetID: report.id, axisIsRow: true, index: 0, count: 3) == nil)
        let (wb2, _, report2) = makeWorkbook(location: "XFB1:XFC4")
        #expect(WorkbookOperations.pivotTableSplit(in: wb2, sheetID: report2.id, axisIsRow: false, index: 0, count: 2) != nil)
        #expect(WorkbookOperations.pivotTableSplit(in: wb2, sheetID: report2.id, axisIsRow: false, index: 0, count: 1) == nil)
    }

    @Test func removingATableClearsItsFieldButtons() {
        let (wb, _, report) = makeWorkbook()
        let button = wb.styleIndex(for: CellStyle(bold: true, pivotButton: true))
        report.setCell(Cell(value: .string("Row Labels"), styleIndex: button), at: CellAddress(a1: "B5")!)
        WorkbookOperations.deleteRows(in: wb, sheetID: report.id, at: 0, count: 20)
        #expect(wb.pivotTables.isEmpty)
        // Its cells are gone with the rows; a stray button elsewhere goes too.
        let (wb2, data2, _) = makeWorkbook()
        let button2 = wb2.styleIndex(for: CellStyle(pivotButton: true))
        data2.setCell(Cell(value: .string("x"), styleIndex: button2), at: CellAddress(a1: "A1")!)
        wb2.removePivotTables { _ in true }
        #expect(wb2.style(at: data2.cell(at: CellAddress(a1: "A1")!).styleIndex) == CellStyle())
    }

    @Test func editsOnOtherSheetsDontMoveTheTable() {
        let (wb, data, _) = makeWorkbook(sourceRef: "A1:C10")
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 0, count: 1)
        #expect(wb.pivotTables[0].location.a1 == "B5:D12")
    }
}

@Suite("Pivot tables: source ranges")
struct PivotSourceEditTests {
    private func source(_ wb: Workbook) -> PivotSourceRange { wb.pivotCaches[0].sourceRanges[0] }

    @Test func insertingInsideTheSourceExpandsIt() {
        let (wb, data, _) = makeWorkbook(sourceRef: "A1:C10")
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 4, count: 2)
        #expect(source(wb).ref == "A1:C12")
        WorkbookOperations.insertColumns(in: wb, sheetID: data.id, at: 1, count: 1)
        #expect(source(wb).ref == "A1:D12")
    }

    @Test func insertingAboveMovesIt() {
        let (wb, data, _) = makeWorkbook(sourceRef: "A3:C10")
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 0, count: 2)
        #expect(source(wb).ref == "A5:C12")
    }

    @Test func insertingJustBelowDoesNotGrowIt() {
        // Formula semantics: a range doesn't absorb rows appended after it.
        let (wb, data, _) = makeWorkbook(sourceRef: "A1:C10")
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 10, count: 1)
        #expect(source(wb).ref == "A1:C10")
    }

    @Test func deletingPartOfTheSourceShrinksIt() {
        let (wb, data, _) = makeWorkbook(sourceRef: "A1:C10")
        WorkbookOperations.deleteRows(in: wb, sheetID: data.id, at: 8, count: 5) // rows 9-13
        #expect(source(wb).ref == "A1:C8")
        WorkbookOperations.deleteColumns(in: wb, sheetID: data.id, at: 0, count: 1)
        #expect(source(wb).ref == "A1:B8")
    }

    @Test func deletingTheWholeSourceDetachesIt() {
        let (wb, data, _) = makeWorkbook(sourceRef: "A1:C10")
        WorkbookOperations.deleteRows(in: wb, sheetID: data.id, at: 0, count: 10)
        #expect(source(wb) == PivotSourceRange(target: .detached(sheetName: "Data"), ref: "A1:C10"))
        #expect(wb.pivotCaches[0].hasDetachedSource)
        #expect(wb.pivotTables.count == 1) // the table still shows its cached data
    }

    @Test func absoluteAndWholeColumnReferencesAdjust() {
        let (wb, data, _) = makeWorkbook(sourceRef: "$A$1:$C$10")
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 0, count: 1)
        #expect(source(wb).ref == "$A$2:$C$11")
        let (wb2, data2, _) = makeWorkbook(sourceRef: "A:C")
        WorkbookOperations.insertRows(in: wb2, sheetID: data2.id, at: 0, count: 5)
        #expect(wb2.pivotCaches[0].sourceRanges[0].ref == "A:C")
        WorkbookOperations.insertColumns(in: wb2, sheetID: data2.id, at: 0, count: 1)
        #expect(wb2.pivotCaches[0].sourceRanges[0].ref == "B:D")
    }

    @Test func editsOnOtherSheetsLeaveTheSourceAlone() {
        let (wb, _, report) = makeWorkbook(location: "B20:C25", sourceRef: "A1:C10")
        WorkbookOperations.insertRows(in: wb, sheetID: report.id, at: 0, count: 3)
        #expect(source(wb).ref == "A1:C10")
    }

    @Test func sourcePushedOffTheSheetIsDetached() {
        let (wb, data, _) = makeWorkbook(sourceRef: "A1048570:C1048575")
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 0, count: 10)
        #expect(source(wb).target == .detached(sheetName: "Data"))
    }

    @Test func externalAndDetachedSourcesAreNeverAdjusted() {
        let (wb, data, _) = makeWorkbook()
        wb.pivotCaches[0].sourceRanges = [PivotSourceRange(target: .external, ref: "A1:B3"),
                                          PivotSourceRange(target: .detached(sheetName: "Gone"), ref: "A1:B3")]
        WorkbookOperations.insertRows(in: wb, sheetID: data.id, at: 0, count: 1)
        #expect(wb.pivotCaches[0].sourceRanges.map(\.ref) == ["A1:B3", "A1:B3"])
    }

    @Test func renamingTheSourceSheetNeedsNoRewrite() {
        // Sources track sheets by id; the writer uses the current name.
        let (wb, data, _) = makeWorkbook()
        WorkbookOperations.renameSheet(in: wb, sheetID: data.id, to: "Sales 2026")
        #expect(source(wb).target == .sheet(id: data.id))
    }

    @Test func deletingTheSourceSheetDetachesItsCaches() {
        let (wb, data, _) = makeWorkbook()
        WorkbookOperations.deleteSheet(in: wb, sheetID: data.id)
        #expect(source(wb) == PivotSourceRange(target: .detached(sheetName: "Data"), ref: "A1:C10"))
        #expect(wb.pivotTables.count == 1)
    }

    @Test func deletingTheHostSheetRemovesItsTablesAndUnusedCaches() {
        let (wb, data, report) = makeWorkbook()
        // A second table on Data shares the cache.
        wb.pivotTables.append(PivotTable(sheetID: data.id, name: "Other", cacheID: 7,
                                         location: CellRange(a1: "H1:I4")!, payload: NoPayload()))
        WorkbookOperations.deleteSheet(in: wb, sheetID: report.id)
        #expect(wb.pivotTables.map(\.name) == ["Other"])
        #expect(wb.pivotCaches.count == 1)
        WorkbookOperations.deleteSheet(in: wb, sheetID: data.id) // refused: last sheet
        let third = wb.addSheet(named: "Third")
        _ = third
        WorkbookOperations.deleteSheet(in: wb, sheetID: data.id)
        #expect(wb.pivotTables.isEmpty)
        #expect(wb.pivotCaches.isEmpty)
    }
}
