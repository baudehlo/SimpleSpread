import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Charts read for display from a file Excel wrote (Fixtures/ExcelOracle/
/// charts-by-excel.xlsx; see the README there).
@Suite struct ChartReadingTests {
    static func excelWorkbook() throws -> Workbook {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/ExcelOracle/charts-by-excel.xlsx")
        return try XLSXReader.read(data: Data(contentsOf: url))
    }

    static let north: [Double?] = [120, 135, 150, 142, 168, 181]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]

    @Test func excelChartsReadAsExcelDrewThem() throws {
        let wb = try Self.excelWorkbook()
        let charts = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)
        #expect(charts.count == 16)
        #expect(charts.map(\.kind) == [
            .column, .line, .pie, .bar, // written by openpyxl, saved again by Excel
            .column, .line, .pie, .bar, .scatter, .column, .column, .line, .doughnut, .area, nil, nil,
        ])
        #expect(charts.map(\.unsupported) == Array(repeating: nil, count: 14) + ["Waterfall chart", "Radar chart"])

        // Titles: given, or Excel's automatic one.
        #expect(charts[0].title == "Sales by region")
        #expect(charts[0].valueAxisTitle == "Units")
        #expect(charts[4].title == "Chart Title")
        #expect(charts[14].title == "Chart Title")

        // Series from A1:D7: names from the header row, categories from column A.
        let column = charts[4]
        #expect(column.series.map(\.name) == ["North", "South", "West"])
        #expect(column.series[0].categories == Self.months)
        #expect(column.series[0].values == Self.north)
        #expect(column.legend == .bottom)

        // The pie made from row 7 across: one label per column.
        #expect(charts[2].series[0].categories == ["North", "South", "West"])
        #expect(charts[2].series[0].values == [181, 142, 118])
        #expect(charts[2].series[0].pointColors.count == 3)

        // Stacking, and the combo's line on its own.
        #expect(charts[3].grouping == .stacked)
        #expect(charts[10].grouping == .percentStacked)
        #expect(charts[13].grouping == .stacked)
        #expect(charts[9].series.map(\.kind) == [.column, .column, .line])

        // Scatter with text x values: Excel plots 1, 2, 3, …
        #expect(charts[8].series[0].xValues == [1, 2, 3, 4, 5, 6])
        #expect(charts[8].series[0].values == Self.north)

        // Placement: Excel's two-cell anchor, offsets in pixels.
        #expect(column.from == SheetChart.Anchor(column: 5, columnOffset: 19, row: 33, rowOffset: 1))
        #expect(column.to?.column == 12)
        #expect(charts[0].to == nil && charts[0].size?.width == 5040000 / 9525)
    }

    @Test func seriesFollowTheirCells() throws {
        let wb = try Self.excelWorkbook()
        let sheet = wb.sheets[0]
        let source = SheetChartSource(workbook: wb, sheetID: sheet.id)
        sheet.setCell(Cell(value: .number(999)), at: CellAddress(a1: "B2")!)
        sheet.setCell(Cell(value: .string("January")), at: CellAddress(a1: "A2")!)
        // A cell edit leaves the parts alone: no parsing again.
        #expect(source.isCurrent(for: wb))
        let column = source.charts(in: wb)[4]
        #expect(column.series[0].values.first == 999)
        #expect(column.series[0].categories.first == "January")
    }

    @Test func hiddenRowsAreLeftOut() throws {
        let wb = try Self.excelWorkbook()
        let sheet = wb.sheets[0]
        sheet.hiddenRows = [2] // Feb
        let column = XLSXCharts.charts(in: wb, sheetID: sheet.id)[4]
        #expect(column.series[0].categories == ["Jan", "Mar", "Apr", "May", "Jun"])
        #expect(column.series[0].values == [120, 150, 142, 168, 181])
    }

    @Test func insertedRowsMoveChartsAndTheirRanges() throws {
        let wb = try Self.excelWorkbook()
        let sheet = wb.sheets[0]
        let source = SheetChartSource(workbook: wb, sheetID: sheet.id)
        WorkbookOperations.insertRows(in: wb, sheetID: sheet.id, at: 3, count: 2) // above row 4 (Mar)
        // The parts were rewritten: parse again.
        #expect(!source.isCurrent(for: wb))
        let column = XLSXCharts.charts(in: wb, sheetID: sheet.id)[4]
        #expect(column.from.row == 35)
        // The series range grew around the new blank rows, as in Excel.
        #expect(column.series[0].values == [120, 135, nil, nil, 150, 142, 168, 181])
    }

    @Test func noChartsWithoutCarriedParts() {
        let wb = Workbook()
        _ = wb.addSheet()
        #expect(XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id).isEmpty)
    }
}
