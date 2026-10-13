import Foundation
import Testing
@testable import SpreadsheetCore

@Suite("Sorting, filtering and sheet layout")
struct SortFilterLayoutTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    func r(_ a1: String) -> CellRange { CellRange(a1: a1)! }

    // MARK: Sort order

    @Test func excelAscendingOrder() {
        let values: [CellValue] = [.bool(true), .string("b"), .error(.na), .number(10),
                                   .string("A"), .bool(false), .number(-1)]
        let sorted = values.sorted { SortComparison.compare($0, $1) == .orderedAscending }
        #expect(sorted == [.number(-1), .number(10), .string("A"), .string("b"),
                           .bool(false), .bool(true), .error(.na)])
    }

    @Test func sortMovesWholeRowsAndKeepsBlanksLast() {
        let h = Harness(cells: ["A1": "3", "B1": "c", "A2": "", "B2": "blank", "A3": "1", "B3": "a",
                                "A4": "2", "B4": "b"])
        let sheet = h.workbook.sheets[0]
        for descending in [false, true] {
            let order = WorkbookOperations.sortedRowOrder(of: 0...3, in: sheet,
                                                          keys: [SortKey(column: 0, ascending: !descending)])
            // Row 1 (blank key) is last either way.
            #expect(order == (descending ? [0, 3, 2, 1] : [2, 3, 0, 1]))
        }
    }

    @Test func sortIsStableAndMultiLevel() {
        let h = Harness(cells: ["A1": "x", "B1": "2", "A2": "y", "B2": "1", "A3": "x", "B3": "1",
                                "A4": "x", "B4": "1"])
        let sheet = h.workbook.sheets[0]
        let order = WorkbookOperations.sortedRowOrder(
            of: 0...3, in: sheet, keys: [SortKey(column: 0), SortKey(column: 1)])
        #expect(order == [2, 3, 0, 1]) // x/1 rows keep their order, then x/2, then y
    }

    @Test func sortTranslatesFormulasByTheRowsMoved() {
        let h = Harness(cells: ["A1": "2", "B1": "=A1*10", "A2": "1", "B2": "=A2*10"])
        let moves = WorkbookOperations.sortedCells(of: r("A1:B2"), in: h.workbook.sheets[0],
                                                   keys: [SortKey(column: 0)])
        let formulas = Dictionary(uniqueKeysWithValues: moves.map { ($0.0, $0.1.formula) })
        #expect(formulas[a("B1")] == "A1*10")
        #expect(formulas[a("B2")] == "A2*10")
    }

    @Test func headerGuess() {
        let h = Harness(cells: ["A1": "Name", "B1": "Qty", "A2": "x", "B2": "3"])
        let wb = h.workbook
        #expect(WorkbookOperations.guessHasHeader(r("A1:B2"), in: wb.sheets[0], workbook: wb))
        let plain = Harness(cells: ["A1": "b", "A2": "a"])
        #expect(!WorkbookOperations.guessHasHeader(r("A1:A2"), in: plain.workbook.sheets[0], workbook: plain.workbook))
    }

    // MARK: Filters

    @Test func wildcards() {
        #expect(FilterCondition.wildcardMatch("Apple pie", pattern: "*PIE"))
        #expect(FilterCondition.wildcardMatch("cat", pattern: "c?t"))
        #expect(!FilterCondition.wildcardMatch("cart", pattern: "c?t"))
        #expect(FilterCondition.wildcardMatch("a*b", pattern: "a~*b"))
        #expect(!FilterCondition.wildcardMatch("axb", pattern: "a~*b"))
        #expect(FilterCondition.wildcardMatch("", pattern: "*"))
        #expect(FilterCondition.wildcardMatch("abcabc", pattern: "*c*c"))
    }

    @Test func conditionsCompareNumbersNumerically() {
        let gt = FilterCondition(.greaterThan, "9")
        #expect(gt.matches(.number(10), displayText: "10"))
        #expect(!gt.matches(.number(2), displayText: "2"))
        #expect(gt.matches(.string("Z"), displayText: "Z")) // text vs text: "Z" sorts after "9"
        let contains = FilterCondition(.equal, "*an*")
        #expect(contains.matches(.string("Banana"), displayText: "Banana"))
    }

    @Test func applyHidesFailingRowsAndGrowsOverNewRows() {
        let h = Harness(cells: ["A1": "Fruit", "B1": "Qty",
                                "A2": "Apple", "B2": "5", "A3": "Pear", "B3": "1",
                                "A4": "", "B4": "7", "A5": "apple", "B5": "2"])
        let wb = h.workbook
        let sheet = wb.sheets[0]
        sheet.autoFilter = AutoFilter(range: r("A1:B3"),
                                      columns: [0: ColumnFilter(values: ["APPLE"], includeBlanks: false)])
        wb.applyAutoFilter(onSheetID: sheet.id)
        #expect(sheet.autoFilter?.range == r("A1:B5"))   // grew over rows 4-5
        #expect(sheet.hiddenRows == [2, 3])              // Pear, blank
        sheet.autoFilter?.columns = [1: ColumnFilter(conditions: [FilterCondition(.greaterThanOrEqual, "5")])]
        wb.applyAutoFilter(onSheetID: sheet.id)
        #expect(sheet.hiddenRows == [2, 4])
        let values = wb.filterValues(onSheetID: sheet.id, columnOffset: 0)
        #expect(values.values == ["Apple", "Pear"])
        #expect(values.hasBlanks)
    }

    @Test func formattedValuesFilterByDisplayText() {
        let h = Harness(cells: ["A1": "Price", "A2": "1.5", "A3": "2"])
        let wb = h.workbook
        let sheet = wb.sheets[0]
        wb.modifyStyle(in: r("A2:A3"), ofSheetID: sheet.id) { $0.numberFormat = .currency }
        sheet.autoFilter = AutoFilter(range: r("A1:A3"), columns: [0: ColumnFilter(values: ["$2.00"])])
        wb.applyAutoFilter(onSheetID: sheet.id)
        #expect(sheet.hiddenRows == [1])
    }

    // MARK: Layout helpers

    @Test func currentRegionStopsAtEmptyRowsAndColumns() {
        let h = Harness(cells: ["B2": "1", "C2": "2", "B3": "3", "D4": "diagonal", "F2": "far"])
        let sheet = h.workbook.sheets[0]
        #expect(sheet.currentRegion(around: a("B2")) == r("B2:D4"))
        #expect(sheet.currentRegion(around: a("F2")) == r("F2"))
    }

    @Test func selectionsGrowOverMerges() {
        let sheet = Sheet(id: 1, name: "S")
        sheet.mergedRanges = [r("B2:C3"), r("C4:D4")]
        #expect(sheet.expandedForMerges(r("A1:B2")) == r("A1:C3"))
        #expect(sheet.expandedForMerges(r("C3")) == r("B2:C3"))
        #expect(sheet.expandedForMerges(r("C3:C4")) == r("B2:D4"))
        #expect(sheet.isHiddenByMerge(a("C3")))
        #expect(!sheet.isHiddenByMerge(a("B2")))
    }

    @Test func insertAndDeleteShiftHiddenRowsAndFilters() {
        let wb = Workbook.newDocument()
        let sheet = wb.sheets[0]
        sheet.hiddenRows = [3, 8]
        sheet.autoFilter = AutoFilter(range: r("B2:D10"), columns: [2: ColumnFilter(values: ["x"])])
        WorkbookOperations.insertRows(in: wb, sheetID: sheet.id, at: 5, count: 2)
        #expect(sheet.hiddenRows == [3, 10])
        #expect(sheet.autoFilter?.range == r("B2:D12"))
        WorkbookOperations.deleteRows(in: wb, sheetID: sheet.id, at: 3, count: 1)
        #expect(sheet.hiddenRows == [9])
        // Deleting column C moves the D criteria to offset 1.
        WorkbookOperations.deleteColumns(in: wb, sheetID: sheet.id, at: 2, count: 1)
        #expect(sheet.autoFilter?.range == r("B2:C11"))
        #expect(sheet.autoFilter?.columns.keys.sorted() == [1])
        // Deleting the header row removes the filter.
        WorkbookOperations.deleteRows(in: wb, sheetID: sheet.id, at: 1, count: 1)
        #expect(sheet.autoFilter == nil)
    }

    @Test func bordersDecodeFromOlderClipboardPayloads() throws {
        let json = #"{"bold":false,"italic":false,"underline":false,"strikethrough":false,"horizontalAlignment":"automatic","verticalAlignment":"bottom","wrapText":false,"numberFormat":{"code":""}}"#
        let style = try JSONDecoder().decode(CellStyle.self, from: Data(json.utf8))
        #expect(style.borders.isEmpty)
        let bordered = CellStyle(borders: CellBorders(bottom: BorderLine(.double, color: .black)))
        let round = try JSONDecoder().decode(CellStyle.self, from: JSONEncoder().encode(bordered))
        #expect(round == bordered)
    }
}
