import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Making, placing, changing and removing charts, through a save and a
/// read back.
@Suite struct ChartEditingTests {
    /// A sales table in A1:D7 (months down column A, regions across row 1).
    static func salesWorkbook() -> Workbook {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Sales")
        let rows: [[CellValue]] = [
            [.string("Month"), .string("North"), .string("South"), .string("West")],
            [.string("Jan"), .number(120), .number(90), .number(60)],
            [.string("Feb"), .number(135), .number(95), .number(72)],
            [.string("Mar"), .number(150), .number(110), .number(80)],
            [.string("Apr"), .number(142), .number(125), .number(95)],
            [.string("May"), .number(168), .number(130), .number(101)],
            [.string("Jun"), .number(181), .number(142), .number(118)],
        ]
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() {
                sheet.setCell(Cell(value: value), at: CellAddress(row: r, column: c))
            }
        }
        return wb
    }

    static let block = ChartRange(sheetName: "Sales", range: CellRange(a1: "A1:D7")!)

    static func roundTrip(_ wb: Workbook) throws -> Workbook {
        try XLSXReader.read(data: XLSXWriter.data(for: wb))
    }

    // MARK: Series from a selection

    @Test func seriesFromATableWithHeaders() {
        let wb = Self.salesWorkbook()
        let series = ChartSettings.series(from: Self.block, in: wb, kind: .column)
        #expect(series.count == 3)
        #expect(series[0].name == .reference("Sales!$B$1"))
        #expect(series[0].categories == "Sales!$A$2:$A$7")
        #expect(series[0].values == "Sales!$B$2:$B$7")
        // Rows instead: six series of three regions.
        let rows = ChartSettings.series(from: Self.block, in: wb, kind: .column, inRows: true)
        #expect(rows.count == 6)
        #expect(rows[0].name == .reference("Sales!$A$2"))
        #expect(rows[0].categories == "Sales!$B$1:$D$1")
        #expect(rows[0].values == "Sales!$B$2:$D$2")
        // Pie: the first series only. Scatter without text categories: x from the first column.
        #expect(ChartSettings.series(from: Self.block, in: wb, kind: .pie).count == 1)
        let numbers = ChartRange(sheetName: "Sales", range: CellRange(a1: "B2:D7")!)
        let scatter = ChartSettings.series(from: numbers, in: wb, kind: .scatter)
        #expect(scatter.count == 2)
        #expect(scatter[0].categories == "Sales!$B$2:$B$7")
        #expect(scatter[0].name == .text("Series1"))
    }

    @Test func wideBlocksMakeSeriesOfRows() {
        let wb = Self.salesWorkbook()
        // Header row + one row of numbers across three columns: one series per... row.
        let wide = ChartRange(sheetName: "Sales", range: CellRange(a1: "A1:D2")!)
        let series = ChartSettings.series(from: wide, in: wb, kind: .column)
        #expect(series.count == 1)
        #expect(series[0].values == "Sales!$B$2:$D$2")
        #expect(series[0].categories == "Sales!$B$1:$D$1")
    }

    // MARK: Insert

    @Test(arguments: [SheetChart.Kind.column, .bar, .line, .area, .pie, .doughnut, .scatter])
    func insertedChartsReadBackAsMade(kind: SheetChart.Kind) throws {
        let wb = Self.salesWorkbook()
        let sheetID = wb.sheets[0].id
        var settings = ChartSettings.new(kind, from: Self.block, in: wb)
        settings.valueAxisTitle = ChartSettings.hasAxes(kind) ? "Units" : nil
        let id = try #require(XLSXChartEditor.insert(settings, onSheet: sheetID,
                                                      from: SheetChart.Anchor(column: 5, row: 1),
                                                      to: SheetChart.Anchor(column: 12, row: 16), in: wb))
        let reread = try Self.roundTrip(wb)
        let charts = XLSXCharts.charts(in: reread, sheetID: reread.sheets[0].id)
        #expect(charts.count == 1)
        let chart = try #require(charts.first)
        #expect(chart.id == id)
        #expect(chart.kind == kind)
        #expect(chart.from == SheetChart.Anchor(column: 5, row: 1))
        #expect(chart.to == SheetChart.Anchor(column: 12, row: 16))
        #expect(chart.settings == settings)
        if kind != .scatter {
            #expect(chart.series[0].values == [120, 135, 150, 142, 168, 181])
            #expect(chart.series[0].categories == ["Jan", "Feb", "Mar", "Apr", "May", "Jun"])
        }
    }

    @Test func secondChartJoinsTheSheetsDrawing() throws {
        let wb = Self.salesWorkbook()
        let sheetID = wb.sheets[0].id
        let a = XLSXChartEditor.insert(ChartSettings.new(.column, from: Self.block, in: wb), onSheet: sheetID,
                                       from: .init(column: 5, row: 1), to: .init(column: 10, row: 10), in: wb)
        let b = XLSXChartEditor.insert(ChartSettings.new(.line, from: Self.block, in: wb), onSheet: sheetID,
                                       from: .init(column: 5, row: 12), to: .init(column: 10, row: 22), in: wb)
        #expect(a != nil && b != nil && a != b)
        let carried = try #require(wb.carriedContent as? CarriedParts)
        #expect(carried.sheets[sheetID]?.relationships.filter { $0.type.hasSuffix("/drawing") }.count == 1)
        #expect(carried.sheets[sheetID]?.elements.filter { $0.name == "drawing" }.count == 1)
        let reread = try Self.roundTrip(wb)
        let charts = XLSXCharts.charts(in: reread, sheetID: reread.sheets[0].id)
        #expect(charts.map(\.kind) == [.column, .line])
        #expect(charts[1].name == "Chart 2")
    }

    // MARK: Place and delete

    @Test func moveAndResize() throws {
        let wb = Self.salesWorkbook()
        let sheetID = wb.sheets[0].id
        let id = try #require(XLSXChartEditor.insert(ChartSettings.new(.column, from: Self.block, in: wb),
                                                      onSheet: sheetID, from: .init(column: 5, row: 1),
                                                      to: .init(column: 10, row: 10), in: wb))
        #expect(XLSXChartEditor.place(id, onSheet: sheetID, from: .init(column: 1, columnOffset: 12, row: 9, rowOffset: 4),
                                      to: .init(column: 8, columnOffset: 30, row: 25),
                                      size: .init(width: 700, height: 352), in: wb))
        let chart = try #require(XLSXCharts.charts(in: try Self.roundTrip(wb), sheetID: sheetID).first)
        #expect(chart.from == SheetChart.Anchor(column: 1, columnOffset: 12, row: 9, rowOffset: 4))
        #expect(chart.to == SheetChart.Anchor(column: 8, columnOffset: 30, row: 25))
    }

    @Test func oneCellAnchorsKeepTheirKind() throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let sheetID = wb.sheets[0].id
        let first = XLSXCharts.charts(in: wb, sheetID: sheetID)[0] // openpyxl's one-cell anchor
        #expect(XLSXChartEditor.place(first.id, onSheet: sheetID, from: .init(column: 2, row: 20),
                                      to: .init(column: 6, row: 30), size: .init(width: 400, height: 250), in: wb))
        let moved = XLSXCharts.charts(in: wb, sheetID: sheetID)[0]
        #expect(moved.from == SheetChart.Anchor(column: 2, row: 20))
        #expect(moved.to == nil)
        #expect(moved.size == SheetChart.Size(width: 400, height: 250))
    }

    @Test func deletingTheLastChartRemovesTheDrawing() throws {
        let wb = Self.salesWorkbook()
        let sheetID = wb.sheets[0].id
        let a = try #require(XLSXChartEditor.insert(ChartSettings.new(.column, from: Self.block, in: wb),
                                                     onSheet: sheetID, from: .init(column: 5, row: 1),
                                                     to: .init(column: 10, row: 10), in: wb))
        let b = try #require(XLSXChartEditor.insert(ChartSettings.new(.pie, from: Self.block, in: wb),
                                                     onSheet: sheetID, from: .init(column: 5, row: 12),
                                                     to: .init(column: 10, row: 22), in: wb))
        #expect(XLSXChartEditor.delete(a, onSheet: sheetID, in: wb))
        #expect(XLSXCharts.charts(in: wb, sheetID: sheetID).map(\.id) == [b])
        #expect(XLSXChartEditor.delete(b, onSheet: sheetID, in: wb))
        let carried = try #require(wb.carriedContent as? CarriedParts)
        #expect(carried.sheets[sheetID]?.relationships.isEmpty == true)
        #expect(carried.sheets[sheetID]?.elements.contains { $0.name == "drawing" } == false)
        #expect(carried.parts.isEmpty)
        let reread = try Self.roundTrip(wb)
        #expect(XLSXCharts.charts(in: reread, sheetID: reread.sheets[0].id).isEmpty)
    }

    @Test func deletingAnExcelChartLeavesTheOthers() throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let sheetID = wb.sheets[0].id
        let before = XLSXCharts.charts(in: wb, sheetID: sheetID)
        #expect(XLSXChartEditor.delete(before[4].id, onSheet: sheetID, in: wb))
        let after = XLSXCharts.charts(in: try Self.roundTrip(wb), sheetID: sheetID)
        #expect(after.count == 15)
        #expect(after.map(\.name) == before.map(\.name).enumerated().filter { $0.offset != 4 }.map(\.element))
    }

    // MARK: Update

    @Test func settingsChangeInPlaceOnAnExcelChart() throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let sheetID = wb.sheets[0].id
        let chart = XLSXCharts.charts(in: wb, sheetID: sheetID)[4] // Excel's clustered column
        let old = try #require(chart.settings)
        var new = old
        new.kind = .bar
        new.grouping = .stacked
        new.title = .text("Regions")
        new.legend = .right
        new.categoryAxisTitle = "Month"
        new.valueAxisTitle = "Units"
        new.showsDataLabels = true
        new.series[1].color = .rgb(RGBAColor(red: 0x11, green: 0x22, blue: 0x33))
        #expect(XLSXChartEditor.update(chart.id, from: old, to: new, in: wb))
        let reread = XLSXCharts.charts(in: try Self.roundTrip(wb), sheetID: sheetID)[4]
        #expect(reread.settings == new)
        #expect(reread.title == "Regions")
        #expect(reread.series[1].color == RGBAColor(red: 0x11, green: 0x22, blue: 0x33))
        // Excel's formatting stayed: the style block and the series' unique ids.
        let carried = try #require(wb.carriedContent as? CarriedParts)
        let xml = String(decoding: try #require(carried.parts[chart.id]).data, as: UTF8.self)
        #expect(xml.contains("c14:style"))
        #expect(xml.contains("c16:uniqueId"))
    }

    @Test(arguments: [SheetChart.Kind.line, .pie, .scatter, .area, .column])
    func kindChangesRebuildThePlot(kind: SheetChart.Kind) throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let sheetID = wb.sheets[0].id
        let chart = XLSXCharts.charts(in: wb, sheetID: sheetID)[13] // Excel's stacked area
        let old = try #require(chart.settings)
        var new = old
        new.kind = kind
        if !ChartSettings.stacks(kind) { new.grouping = .standard }
        if kind == .pie { new.series = Array(new.series.prefix(1)) }
        #expect(XLSXChartEditor.update(chart.id, from: old, to: new, in: wb))
        let reread = XLSXCharts.charts(in: try Self.roundTrip(wb), sheetID: sheetID)[13]
        #expect(reread.kind == kind)
        #expect(reread.settings?.series.map(\.values) == new.series.map(\.values))
        #expect(reread.series[0].values == [120, 135, 150, 142, 168, 181])
    }

    @Test func newDataRangeRebuildsTheSeries() throws {
        let wb = Self.salesWorkbook()
        let sheetID = wb.sheets[0].id
        let old = ChartSettings.new(.column, from: Self.block, in: wb)
        let id = try #require(XLSXChartEditor.insert(old, onSheet: sheetID, from: .init(column: 5, row: 1),
                                                      to: .init(column: 10, row: 10), in: wb))
        var new = old
        new.series = ChartSettings.series(from: ChartRange(sheetName: "Sales", range: CellRange(a1: "A1:B4")!),
                                          in: wb, kind: .column)
        #expect(XLSXChartEditor.update(id, from: old, to: new, in: wb))
        let chart = try #require(XLSXCharts.charts(in: try Self.roundTrip(wb), sheetID: sheetID).first)
        #expect(chart.series.count == 1)
        #expect(chart.series[0].values == [120, 135, 150])
        #expect(chart.settings?.dataRange(in: wb) == ChartRange(sheetName: "Sales", range: CellRange(a1: "A1:B4")!))
    }

    @Test func defaultNamespaceChartsTakeEditsUnprefixed() throws {
        let wb = Self.salesWorkbook()
        let sheetID = wb.sheets[0].id
        let old = ChartSettings.new(.column, from: Self.block, in: wb)
        let id = try #require(XLSXChartEditor.insert(old, onSheet: sheetID, from: .init(column: 5, row: 1),
                                                      to: .init(column: 10, row: 10), in: wb))
        // Rewrite the part the way openpyxl writes charts: c: as the default namespace.
        var carried = try #require(wb.carriedContent as? CarriedParts)
        let xml = String(decoding: try #require(carried.parts[id]).data, as: UTF8.self)
            .replacingOccurrences(of: "<c:", with: "<").replacingOccurrences(of: "</c:", with: "</")
            .replacingOccurrences(of: "xmlns:c=", with: "xmlns=")
        carried.parts[id]?.data = Data(xml.utf8)
        wb.carriedContent = carried
        let read = try #require(XLSXCharts.charts(in: wb, sheetID: sheetID).first?.settings)
        #expect(read == old)
        var new = read
        new.kind = .line
        new.title = .text("Unprefixed")
        new.legend = .top
        new.valueAxisTitle = "Units"
        new.showsDataLabels = true
        #expect(XLSXChartEditor.update(id, from: read, to: new, in: wb))
        let edited = String(decoding: try #require((wb.carriedContent as? CarriedParts)?.parts[id]).data, as: UTF8.self)
        #expect(!edited.contains("<c:"))
        #expect(edited.contains("<lineChart>"))
        let chart = try #require(XLSXCharts.charts(in: try Self.roundTrip(wb), sheetID: sheetID).first)
        #expect(chart.settings == new)
    }

    @Test func openpyxlChartsTakeEditsInTheirOwnNamespace() throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let sheetID = wb.sheets[0].id
        // Charts 1–4 were openpyxl's (unprefixed), re-saved by Excel: check
        // a default-namespace part too by writing one.
        let chart = XLSXCharts.charts(in: wb, sheetID: sheetID)[2]
        let old = try #require(chart.settings)
        var new = old
        new.title = .none
        new.legend = nil
        new.kind = .doughnut
        #expect(XLSXChartEditor.update(chart.id, from: old, to: new, in: wb))
        let reread = XLSXCharts.charts(in: try Self.roundTrip(wb), sheetID: sheetID)[2]
        #expect(reread.kind == .doughnut)
        #expect(reread.title == nil)
        #expect(reread.legend == nil)
    }
}

/// Files for checking in Excel: `SIMPLESPREAD_CHART_ORACLE_OUT=<dir> swift
/// test --filter ChartOracleFiles` writes charts-made.xlsx (every kind and
/// setting made here) and charts-edited.xlsx (Excel's charts changed here).
@Suite struct ChartOracleFiles {
    @Test func write() throws {
        guard let dir = ProcessInfo.processInfo.environment["SIMPLESPREAD_CHART_ORACLE_OUT"] else { return }
        let made = ChartEditingTests.salesWorkbook()
        let sheetID = made.sheets[0].id
        let block = ChartEditingTests.block
        func add(_ settings: ChartSettings, _ index: Int) {
            let perRow = Int(ProcessInfo.processInfo.environment["SIMPLESPREAD_CHART_ORACLE_PER_ROW"] ?? "3") ?? 3
            let column = 5 + (index % perRow) * 7, row = 1 + (index / perRow) * 16
            XLSXChartEditor.insert(settings, onSheet: sheetID, from: .init(column: column, row: row),
                                   to: .init(column: column + 6, row: row + 15), in: made)
        }
        var all: [ChartSettings] = [
            .new(.column, from: block, in: made), .new(.bar, grouping: .stacked, from: block, in: made),
            .new(.line, from: block, in: made), .new(.area, grouping: .stacked, from: block, in: made),
            .new(.pie, from: block, in: made), .new(.doughnut, from: block, in: made),
            .new(.scatter, from: ChartRange(sheetName: "Sales", range: CellRange(a1: "B1:D7")!), in: made),
            .new(.column, grouping: .percentStacked, from: block, in: made),
        ]
        var dressed = ChartSettings.new(.column, from: block, in: made)
        dressed.title = .text("Sales by region")
        dressed.legend = .right
        dressed.categoryAxisTitle = "Month"
        dressed.valueAxisTitle = "Units"
        dressed.showsDataLabels = true
        dressed.series[2].color = .rgb(RGBAColor(red: 0x2E, green: 0x8B, blue: 0x57))
        all.append(dressed)
        var combo = ChartSettings.new(.column, from: block, in: made)
        combo.series[2].kind = .line
        all.append(combo)
        for (i, s) in all.enumerated() { add(s, i) }
        try XLSXWriter.data(for: made).write(to: URL(fileURLWithPath: dir).appendingPathComponent("charts-made.xlsx"))

        let edited = try ChartReadingTests.excelWorkbook()
        let id = edited.sheets[0].id
        let charts = XLSXCharts.charts(in: edited, sheetID: id)
        func change(_ index: Int, _ body: (inout ChartSettings) -> Void) {
            guard let old = charts[index].settings else { return }
            var new = old
            body(&new)
            XLSXChartEditor.update(charts[index].id, from: old, to: new, in: edited)
        }
        change(4) { $0.kind = .bar; $0.grouping = .stacked; $0.title = .text("Edited in place"); $0.legend = .right
            $0.categoryAxisTitle = "Month"; $0.valueAxisTitle = "Units"; $0.showsDataLabels = true
            $0.series[1].color = .rgb(RGBAColor(red: 0x11, green: 0x22, blue: 0x33)) }
        change(5) { $0.kind = .area; $0.title = .text("Line to area") }
        change(6) { $0.kind = .column; $0.title = .text("Pie to column") }
        change(9) { $0.kind = .area; $0.title = .text("Combo to area, secondary kept")
            $0.series = $0.series.map { var s = $0; s.kind = nil; return s } }
        change(12) { $0.kind = .pie; $0.title = .none }
        change(13) { $0.kind = .scatter; $0.title = .text("Area to scatter") }
        change(1) { $0.title = .text("openpyxl line, retitled"); $0.legend = .bottom; $0.showsDataLabels = true }
        // A trendline, a red point and labels on the clustered bar's first
        // series, which then becomes a line chart: they should all survive.
        let trendlineChart = charts[7].id
        if var carried = edited.carriedContent as? CarriedParts, var xml = carried.parts[trendlineChart].map({ String(decoding: $0.data, as: UTF8.self) }),
           let range = xml.range(of: "<c:cat>") {
            xml.replaceSubrange(range, with: "<c:dPt><c:idx val=\"2\"/><c:invertIfNegative val=\"0\"/><c:bubble3D val=\"0\"/><c:spPr><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></c:spPr></c:dPt>"
                + "<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"1\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/><c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls>"
                + "<c:trendline><c:trendlineType val=\"linear\"/><c:dispRSqr val=\"0\"/><c:dispEq val=\"0\"/></c:trendline><c:cat>")
            carried.parts[trendlineChart]?.data = Data(xml.utf8)
            edited.carriedContent = carried
        }
        let trendlineNow = XLSXCharts.charts(in: edited, sheetID: id)[7]
        if let old = trendlineNow.settings {
            var new = old
            new.kind = .line
            new.title = .text("Bar with trendline to line")
            XLSXChartEditor.update(trendlineChart, from: old, to: new, in: edited)
        }
        // Spread the stacked ones out, and drop the radar.
        for (n, chart) in charts.enumerated() where n >= 4 && n < 15 {
            let k = n - 4, column = 5 + (k % 2) * 7, row = 33 + (k / 2) * 16
            XLSXChartEditor.place(chart.id, onSheet: id, from: .init(column: column, row: row),
                                  to: .init(column: column + 6, row: row + 15), size: .init(width: 400, height: 300),
                                  in: edited)
        }
        XLSXChartEditor.delete(charts[15].id, onSheet: id, in: edited)
        try XLSXWriter.data(for: edited).write(to: URL(fileURLWithPath: dir).appendingPathComponent("charts-edited.xlsx"))
    }
}
