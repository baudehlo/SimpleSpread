import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Creating and editing pivots in SimpleSpread, through save and reopen.
@Suite("Pivot tables: create and edit", .serialized)
struct PivotCreationTests {
    /// Region | Product | Units | Price — 6 rows on "Sales" A1:D7.
    static let rows: [(String, String, Double, Double)] = [
        ("East", "Apples", 10, 1.5), ("West", "Apples", 5, 1.5), ("East", "Pears", 7, 2.0),
        ("West", "Pears", 3, 2.0), ("East", "Apples", 4, 1.5), ("North", "Figs", 2, 4.0),
    ]

    static func workbook() -> (Workbook, data: Sheet, report: Sheet) {
        let wb = Workbook()
        let data = wb.addSheet(named: "Sales")
        let report = wb.addSheet(named: "Report")
        for (c, h) in ["Region", "Product", "Units", "Price"].enumerated() {
            data.setCell(Cell(value: .string(h)), at: CellAddress(row: 0, column: c))
        }
        for (r, row) in rows.enumerated() {
            data.setCell(Cell(value: .string(row.0)), at: CellAddress(row: r + 1, column: 0))
            data.setCell(Cell(value: .string(row.1)), at: CellAddress(row: r + 1, column: 1))
            data.setCell(Cell(value: .number(row.2)), at: CellAddress(row: r + 1, column: 2))
            data.setCell(Cell(value: .number(row.3)), at: CellAddress(row: r + 1, column: 3))
        }
        return (wb, data, report)
    }

    /// Create a pivot on Report!A3 and edit it.
    static func make(_ edit: (inout PivotDefinition, PivotCacheData) -> Void) throws -> (Workbook, Int, PivotLayoutResult) {
        let (wb, data, report) = workbook()
        let t = try wb.createPivotTable(sourceSheetID: data.id, source: CellRange(a1: "A1:D7")!,
                                        destinationSheetID: report.id, at: CellAddress(a1: "A3")!)
        let cache = wb.pivotCache(withID: wb.pivotTables[t].cacheID)!.data!
        edit(&wb.pivotTables[t].definition!, cache)
        let result = try wb.computePivotTable(at: t)
        #expect(wb.pivotLayoutConflicts(for: t, result: result).cells.isEmpty)
        wb.applyPivotLayout(at: t, result: result)
        return (wb, t, result)
    }

    /// Cells of the report sheet as text, row by row, trimmed to the pivot.
    static func grid(_ wb: Workbook, _ t: Int) -> [[String]] {
        let table = wb.pivotTables[t]
        let sheet = wb.sheet(withID: table.sheetID)!
        let area = table.occupiedRange
        return (area.start.row...area.end.row).map { r in
            (area.start.column...area.end.column).map { c in
                let v = sheet.value(at: CellAddress(row: r, column: c))
                switch v {
                case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
                default: return v.rawDisplayString
                }
            }
        }
    }

    static func roundTrip(_ wb: Workbook) throws -> Workbook {
        var report = XLSXReadReport()
        let reread = try XLSXReader.read(data: XLSXWriter.data(for: wb), report: &report)
        #expect(report.droppedPivots.isEmpty, "\(report.droppedPivots)")
        return reread
    }

    @Test func newPivotIsExcelsEmptyPlaceholder() throws {
        let (wb, t, result) = try Self.make { _, _ in }
        #expect(result.isEmpty)
        #expect(wb.pivotTables[t].location.a1 == "A3:C20")
        let reread = try Self.roundTrip(wb)
        #expect(reread.pivotTables.count == 1)
        #expect(reread.pivotTables[0].definition?.dataFields.isEmpty == true)
    }

    @Test func rowsAndValues() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
        }
        #expect(Self.grid(wb, t) == [
            ["Row Labels", "Sum of Units"],
            ["East", "21"],
            ["North", "2"],
            ["West", "8"],
            ["Grand Total", "31"],
        ])
        let reread = try Self.roundTrip(wb)
        #expect(Self.grid(reread, 0) == Self.grid(wb, t))
        // The saved pivot is computable and lays out the same again.
        #expect(try reread.computePivotTable(at: 0).rowLines == wb.pivotTables[t].definition!.rowLines)
    }

    @Test func rowsColumnsAndTwoValueFields() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 1, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
            d.place(field: 3, in: .values, cache: cache)
        }
        // Values on columns once there are two value fields.
        #expect(wb.pivotTables[t].definition!.columnFields == [pivotValuesFieldIndex])
        #expect(Self.grid(wb, t) == [
            ["Row Labels", "Sum of Units", "Sum of Price"],
            ["Apples", "19", "4.5"],
            ["Figs", "2", "4"],
            ["Pears", "10", "4"],
            ["Grand Total", "31", "12.5"],
        ])
        _ = try Self.roundTrip(wb)
    }

    @Test func crossTabWithColumnField() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 1, in: .columns, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
        }
        #expect(Self.grid(wb, t) == [
            ["Sum of Units", "Column Labels", "", "", ""],
            ["Row Labels", "Apples", "Figs", "Pears", "Grand Total"],
            ["East", "14", "", "7", "21"],
            ["North", "", "2", "", "2"],
            ["West", "5", "", "3", "8"],
            ["Grand Total", "19", "2", "10", "31"],
        ])
        _ = try Self.roundTrip(wb)
    }

    @Test func textFieldsCountAndNamesStayUnique() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 1, in: .values, cache: cache)
            d.place(field: 1, in: .values, cache: cache)
        }
        let names = wb.pivotTables[t].definition!.dataFields.map(\.name)
        #expect(names == ["Count of Product", "Count of Product2"])
        #expect(Self.grid(wb, t)[1] == ["East", "3", "3"])
    }

    @Test func nestedRowsWithSubtotalsAtTop() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 1, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
        }
        #expect(Self.grid(wb, t) == [
            ["Row Labels", "Sum of Units"],
            ["East", "21"], ["Apples", "14"], ["Pears", "7"],
            ["North", "2"], ["Figs", "2"],
            ["West", "8"], ["Apples", "5"], ["Pears", "3"],
            ["Grand Total", "31"],
        ])
        // Compact form indents the inner labels.
        let sheet = wb.sheet(withID: wb.pivotTables[t].sheetID)!
        #expect(wb.style(at: sheet.cell(at: CellAddress(a1: "A5")!).styleIndex).indent == 1)
    }

    @Test func tabularFormWithSubtotalsBelow() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 1, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
            d.setForm(.tabular)
        }
        #expect(Self.grid(wb, t) == [
            ["Region", "Product", "Sum of Units"],
            ["East", "Apples", "14"], ["", "Pears", "7"], ["East Total", "", "21"],
            ["North", "Figs", "2"], ["North Total", "", "2"],
            ["West", "Apples", "5"], ["", "Pears", "3"], ["West Total", "", "8"],
            ["Grand Total", "", "31"],
        ])
        _ = try Self.roundTrip(wb)
    }

    @Test func subtotalsAndGrandTotalsOff() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 1, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
            d.setSubtotals(false, field: 0)
            d.layout.rowGrandTotals = false
        }
        let g = Self.grid(wb, t)
        #expect(g.first == ["Row Labels", "Sum of Units"])
        #expect(g[1] == ["East", ""])          // no subtotal on the parent row
        #expect(!g.contains { $0.first == "Grand Total" })
    }

    @Test func filterSortAndCollapse() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 1, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
            // Hide North, sort regions descending, collapse West.
            let regions = d.fields[0].items
            let north = regions.firstIndex { $0.index.map { cache.fields[0].sharedItems[$0] } == .string("North") }!
            d.setVisibleItems(field: 0, positions: Set(regions.indices).subtracting([north]))
            d.setSort(.descending, field: 0, cache: cache)
            let west = d.fields[0].items.firstIndex { $0.index.map { cache.fields[0].sharedItems[$0] } == .string("West") }!
            d.setShowDetails(false, field: 0, item: west)
        }
        #expect(Self.grid(wb, t) == [
            ["Row Labels", "Sum of Units"],
            ["West", "8"],
            ["East", "21"], ["Apples", "14"], ["Pears", "7"],
            ["Grand Total", "29"],
        ])
        let reread = try Self.roundTrip(wb)
        #expect(Self.grid(reread, 0) == Self.grid(wb, t))
    }

    @Test func reportFilterSelection() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .filters, cache: cache)
            d.place(field: 1, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
            let east = d.fields[0].items.firstIndex { $0.index.map { cache.fields[0].sharedItems[$0] } == .string("East") }!
            d.selectPageItem(field: 0, item: east)
        }
        let g = Self.grid(wb, t)
        #expect(g[0] == ["Region", "East"])
        #expect(g.last == ["Grand Total", "21"])
        // The body moved down to make room for the filter (A1 filter, A3 body).
        #expect(wb.pivotTables[t].location.start.a1 == "A3")
        let reread = try Self.roundTrip(wb)
        #expect(Self.grid(reread, 0) == g)
    }

    @Test func showValuesAsPercentOfTotal() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
            d.setShowDataAs(.percentOfTotal, forDataField: 0)
        }
        let sheet = wb.sheet(withID: wb.pivotTables[t].sheetID)!
        guard case .number(let east) = sheet.value(at: CellAddress(a1: "B4")!) else { Issue.record("no value"); return }
        #expect(abs(east - 21.0 / 31.0) < 1e-12)
        #expect(sheet.value(at: CellAddress(a1: "B7")!) == .number(1))
    }

    @Test func changingTheSummaryRenamesDefaultNames() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
            d.setSubtotal(.average, forDataField: 0, cache: cache)
        }
        #expect(wb.pivotTables[t].definition!.dataFields[0].name == "Average of Units")
        #expect(Self.grid(wb, t)[1] == ["East", "7"])
    }

    @Test func movingAFieldBetweenAxes() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 0, in: .columns, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
        }
        let d = wb.pivotTables[t].definition!
        #expect(d.rowFields.isEmpty && d.columnFields == [0])
        #expect(d.fields[0].axis == .column)
    }

    @Test func refreshAfterEditingTheSource() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
        }
        let data = wb.sheet(named: "Sales")!
        data.setCell(Cell(value: .number(100)), at: CellAddress(a1: "C7")!) // North's Units 2 -> 100
        try wb.refreshPivotCache(withID: wb.pivotTables[t].cacheID)
        let result = try wb.computePivotTable(at: t)
        wb.applyPivotLayout(at: t, result: result)
        #expect(Self.grid(wb, t)[2] == ["North", "100"])
        #expect(Self.grid(wb, t).last == ["Grand Total", "129"])
    }

    @Test func biggerLayoutsReportWhatTheyWouldOverwrite() throws {
        let (wb, t, _) = try Self.make { d, cache in
            d.place(field: 0, in: .rows, cache: cache)
            d.place(field: 2, in: .values, cache: cache)
        }
        let report = wb.sheet(withID: wb.pivotTables[t].sheetID)!
        report.setCell(Cell(value: .string("keep me")), at: CellAddress(a1: "A10")!)
        wb.pivotTables[t].definition!.place(field: 1, in: .rows, cache: wb.pivotCaches[0].data!)
        let result = try wb.computePivotTable(at: t)
        #expect(wb.pivotLayoutConflicts(for: t, result: result).cells.map(\.a1) == ["A10"])
    }
}
