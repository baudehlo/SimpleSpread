import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles

/// Charts at scale, from odd files, and through edits that must keep what
/// the panel doesn't model.
@Suite struct ChartRobustnessTests {
    // MARK: Helpers

    /// The chart part's XML, changed by `edit`.
    static func editPart(_ id: String, in wb: Workbook, _ edit: (String) -> String) throws {
        var carried = try #require(wb.carriedContent as? CarriedParts)
        let xml = String(decoding: try #require(carried.parts[id]).data, as: UTF8.self)
        carried.parts[id]?.data = Data(edit(xml).utf8)
        wb.carriedContent = carried
    }

    static func partXML(_ id: String, in wb: Workbook) throws -> String {
        let carried = try #require(wb.carriedContent as? CarriedParts)
        return String(decoding: try #require(carried.parts[id]).data, as: UTF8.self)
    }

    /// A sheet with `rows` numbers in B (and `labels` in A), and a chart over them.
    static func bigWorkbook(rows: Int, kind: SheetChart.Kind = .line, labels: (Int) -> String?) throws
        -> (Workbook, String) {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Data")
        for r in 0..<rows {
            if let label = labels(r) { sheet.setCell(Cell(value: .string(label)), at: CellAddress(row: r, column: 0)) }
            sheet.setCell(Cell(value: .number(Double((r * 7919) % 1000))), at: CellAddress(row: r, column: 1))
        }
        let settings = ChartSettings(kind: kind, series: [ChartSeriesSource(
            name: .text("Load"), categories: "Data!$A$1:$A$\(rows)", values: "Data!$B$1:$B$\(rows)")])
        let id = try #require(XLSXChartEditor.insert(settings, onSheet: sheet.id, from: .init(column: 3, row: 0),
                                                      to: .init(column: 10, row: 15), in: wb))
        return (wb, id)
    }

    // MARK: Scale (#1, #2, #5)

    @Test func twentyThousandPointsReadQuicklyAndBounded() throws {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let (wb, _) = try Self.bigWorkbook(rows: 20_000) { months[$0 % 12] }
        let clock = ContinuousClock()
        var chart: SheetChart?
        let elapsed = clock.measure { chart = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id).first }
        let series = try #require(chart?.series.first)
        #expect(series.values.count <= XLSXCharts.maxPointsRead)
        #expect(series.categories.count == series.values.count)
        // The peaks survive the reduction.
        #expect(series.values.compactMap { $0 }.max() == 999)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test func blankCategoriesAndWholeColumnReferencesStayCheap() throws {
        let (wb, id) = try Self.bigWorkbook(rows: 5_000) { _ in nil }
        // Point the series at whole columns, as some programs write them.
        try Self.editPart(id, in: wb) {
            $0.replacingOccurrences(of: "Data!$A$1:$A$5000", with: "Data!$A$1:$A$1048576")
                .replacingOccurrences(of: "Data!$B$1:$B$5000", with: "Data!$B$1:$B$1048576")
        }
        let clock = ContinuousClock()
        var chart: SheetChart?
        let elapsed = clock.measure { chart = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id).first }
        // Read only as far as the data goes.
        #expect((chart?.series.first?.values.count ?? 0) <= XLSXCharts.maxPointsRead)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test func reductionKeepsSeriesAlignedAndPiesSummed() {
        var chart = SheetChart(id: "c", from: .init(column: 0, row: 0))
        func series(_ kind: SheetChart.Kind, _ values: [Double?]) -> SheetChart.Series {
            SheetChart.Series(name: "s", kind: kind, categories: values.indices.map(String.init), values: values,
                              xValues: [], color: RGBAColor(red: 0, green: 0, blue: 0), pointColors: [],
                              showsMarkers: false, showsLine: true)
        }
        chart.series = [series(.column, (0..<1000).map { Double($0) }), series(.column, (0..<1000).map { Double(-$0) })]
        let reduced = chart.reduced(toPoints: 100)
        #expect(reduced.series[0].values.count <= 101)
        #expect(reduced.series[0].categories == reduced.series[1].categories)
        chart.series = [series(.pie, (0..<500).map { _ in 1 })]
        let pie = chart.reduced(toPoints: 50)
        #expect(pie.series[0].values.count == 50)
        #expect(pie.series[0].categories.last == "Other")
        #expect(pie.series[0].values.compactMap { $0 }.reduce(0, +) == 500)
    }

    // MARK: Odd XML (#3)

    @Test(arguments: [
        ("<c:ptCount val=\"6\"/>", "<c:ptCount val=\"-1\"/>"),
        ("<c:ptCount val=\"6\"/>", "<c:ptCount val=\"2000000000\"/>"),
        ("<c:pt idx=\"0\">", "<c:pt idx=\"30000000\">"),
        ("<c:pt idx=\"0\">", "<c:pt idx=\"-5\">"),
        ("<c:idx val=\"0\"/>", "<c:idx val=\"-1\"/>"),
        ("<c:idx val=\"0\"/>", "<c:idx val=\"9223372036854775807\"/>"),
    ])
    func oddCountsAndIndexesDoNotCrash(find: String, replace: String) throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let charts = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)
        // Formulas off, so the caches are what's read.
        for chart in charts where chart.unsupported == nil {
            try Self.editPart(chart.id, in: wb) {
                $0.replacingOccurrences(of: find, with: replace).replacingOccurrences(of: "<c:f>", with: "<c:f>[9]")
            }
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id) }
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test func oddAnchorsStayOnTheSheet() throws {
        let wb = ChartEditingTests.salesWorkbook()
        let sheetID = wb.sheets[0].id
        XLSXChartEditor.insert(.new(.column, from: ChartEditingTests.block, in: wb), onSheet: sheetID,
                               from: .init(column: 1, row: 1), to: .init(column: 5, row: 9), in: wb)
        var carried = try #require(wb.carriedContent as? CarriedParts)
        let drawingPath = try #require(carried.parts.keys.first { $0.contains("drawings/") })
        let xml = String(decoding: try #require(carried.parts[drawingPath]).data, as: UTF8.self)
            .replacingOccurrences(of: "<xdr:col>1</xdr:col>", with: "<xdr:col>-7</xdr:col>")
            .replacingOccurrences(of: "<xdr:row>9</xdr:row>", with: "<xdr:row>99999999999</xdr:row>")
            .replacingOccurrences(of: "<xdr:colOff>0</xdr:colOff>", with: "<xdr:colOff>-123456789012</xdr:colOff>")
        carried.parts[drawingPath]?.data = Data(xml.utf8)
        wb.carriedContent = carried
        let chart = try #require(XLSXCharts.charts(in: wb, sheetID: sheetID).first)
        #expect(chart.from.column == 0)
        #expect(chart.from.columnOffset == 0)
        #expect((chart.to?.row ?? 0) < CellAddress.maxRows)
    }

    /// Every number in Excel's chart parts swapped for something odd, part
    /// by part: reading never crashes or stalls.
    @Test func fuzzedChartPartsRead() throws {
        let odd = ["-1", "0", "2147483647", "-2147483648", "99999999999999999999", "x", "1e308", ""]
        var seed: UInt64 = 0x5EED
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        let base = try ChartReadingTests.excelWorkbook()
        let ids = XLSXCharts.charts(in: base, sheetID: base.sheets[0].id).map(\.id)
        let pattern = try NSRegularExpression(pattern: "(val|idx|cx|cy)=\"(-?[0-9]+)\"")
        for round in 0..<40 {
            let wb = base.copy()
            for id in ids {
                try Self.editPart(id, in: wb) { xml in
                    let ns = xml as NSString
                    let matches = pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length))
                    var out = xml
                    for match in matches.reversed() where next() % 3 == 0 {
                        let value = odd[(next() + round) % odd.count]
                        let r = Range(match.range(at: 2), in: out)!
                        out.replaceSubrange(r, with: value)
                    }
                    return out
                }
            }
            let clock = ContinuousClock()
            let elapsed = clock.measure { _ = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id) }
            #expect(elapsed < .seconds(2), "round \(round): \(elapsed)")
        }
    }

    // MARK: Rebuilds keep what the panel doesn't model (#4)

    /// Excel's clustered column with a trendline, a coloured point and
    /// labels on its first series.
    static func dressedColumn() throws -> (Workbook, SheetChart) {
        let wb = try ChartReadingTests.excelWorkbook()
        let chart = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)[4]
        try editPart(chart.id, in: wb) { xml in
            let extras = "<c:dPt><c:idx val=\"2\"/><c:invertIfNegative val=\"0\"/><c:bubble3D val=\"0\"/><c:spPr><a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill></c:spPr></c:dPt>"
                + "<c:dLbls><c:showLegendKey val=\"0\"/><c:showVal val=\"1\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/><c:showPercent val=\"0\"/><c:showBubbleSize val=\"0\"/></c:dLbls>"
                + "<c:trendline><c:trendlineType val=\"linear\"/><c:dispRSqr val=\"0\"/><c:dispEq val=\"0\"/></c:trendline>"
            guard let range = xml.range(of: "<c:cat>") else { return xml }
            return xml.replacingCharacters(in: range, with: extras + "<c:cat>")
        }
        return (wb, XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)[4])
    }

    @Test func aTypeChangeKeepsTrendlinesPointColoursLabelsAndIDs() throws {
        let (wb, chart) = try Self.dressedColumn()
        #expect(chart.series[0].showsLabels)
        #expect(chart.series[1].showsLabels == false)
        #expect(chart.settings?.showsDataLabels == nil) // some series
        let old = try #require(chart.settings)
        var new = old
        new.kind = .line
        #expect(XLSXChartEditor.update(chart.id, from: old, to: new, in: wb))
        let xml = try Self.partXML(chart.id, in: wb)
        #expect(xml.contains("<c:trendline>"))
        #expect(xml.contains("FF0000"))
        #expect(xml.contains("c16:uniqueId"))
        #expect(xml.contains("<c:lineChart>"))
        #expect(!xml.contains("<c:barChart>"))
        #expect(!xml.contains("invertIfNegative val=\"0\"/><c:cat")) // bar-only children gone from series
        let reread = XLSXCharts.charts(in: try ChartEditingTests.roundTrip(wb), sheetID: wb.sheets[0].id)[4]
        #expect(reread.kind == .line)
        #expect(reread.series[0].showsLabels)
        #expect(reread.series[0].values == ChartReadingTests.north)
    }

    @Test func toPieKeepsWhatAPieCanHave() throws {
        let (wb, chart) = try Self.dressedColumn()
        let old = try #require(chart.settings)
        var new = old
        new.kind = .pie
        new.series = Array(new.series.prefix(1))
        #expect(XLSXChartEditor.update(chart.id, from: old, to: new, in: wb))
        let xml = try Self.partXML(chart.id, in: wb)
        #expect(xml.contains("FF0000"))      // the point's colour
        #expect(!xml.contains("<c:trendline>")) // a pie can't have one (nor can Excel's)
        #expect(!xml.contains("<c:catAx>"))
        let reread = XLSXCharts.charts(in: try ChartEditingTests.roundTrip(wb), sheetID: wb.sheets[0].id)[4]
        #expect(reread.kind == .pie)
        #expect(reread.series[0].pointColors[2] == RGBAColor(red: 0xFF, green: 0, blue: 0))
    }

    @Test func theSecondaryAxisSurvivesATypeChange() throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let combo = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)[9] // column + line on a secondary axis
        #expect(combo.series.map(\.secondary) == [false, false, true])
        let old = try #require(combo.settings)
        var new = old
        new.kind = .area
        new.series = new.series.map { var s = $0; s.kind = nil; return s }
        #expect(XLSXChartEditor.update(combo.id, from: old, to: new, in: wb))
        let reread = XLSXCharts.charts(in: try ChartEditingTests.roundTrip(wb), sheetID: wb.sheets[0].id)[9]
        #expect(reread.series.map(\.kind) == [.area, .area, .area])
        #expect(reread.series.map(\.secondary) == [false, false, true])
        let xml = try Self.partXML(combo.id, in: wb)
        #expect(xml.components(separatedBy: "<c:valAx>").count - 1 == 2)
    }

    @Test func newDataKeepsTheFirstSeriesFormatting() throws {
        let (wb, chart) = try Self.dressedColumn()
        let old = try #require(chart.settings)
        var new = old
        new.series = ChartSettings.series(from: ChartRange(sheetName: "Sales", range: CellRange(a1: "A1:C7")!),
                                          in: wb, kind: .column)
        #expect(XLSXChartEditor.update(chart.id, from: old, to: new, in: wb))
        let xml = try Self.partXML(chart.id, in: wb)
        #expect(xml.contains("<c:trendline>"))
        let reread = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)[4]
        #expect(reread.series.count == 2)
    }

    // MARK: References (#6)

    @Test func definedNamesAreFollowedAndSurviveATypeChange() throws {
        let wb = ChartEditingTests.salesWorkbook()
        let sheetID = wb.sheets[0].id
        wb.definedNames.append(DefinedName(name: "SalesNorth", formula: "Sales!$B$2:$B$7"))
        let settings = ChartSettings(kind: .column, series: [ChartSeriesSource(
            name: .text("North"), categories: "Sales!$A$2:$A$7", values: "Book1.xlsx!SalesNorth")])
        let id = try #require(XLSXChartEditor.insert(settings, onSheet: sheetID, from: .init(column: 5, row: 1),
                                                      to: .init(column: 10, row: 10), in: wb))
        let chart = try #require(XLSXCharts.charts(in: wb, sheetID: sheetID).first)
        #expect(chart.series[0].values == ChartReadingTests.north)
        #expect(chart.settings?.dataRange(in: wb)?.range == CellRange(a1: "A2:B7")!)
        var line = settings
        line.kind = .line
        #expect(XLSXChartEditor.update(id, from: try #require(chart.settings), to: line, in: wb))
        let after = try #require(XLSXCharts.charts(in: wb, sheetID: sheetID).first)
        #expect(after.series[0].values == ChartReadingTests.north)
        #expect(try Self.partXML(id, in: wb).contains("<c:v>181</c:v>"))
    }

    @Test func externalReferencesKeepTheirCacheThroughATypeChange() throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let chart = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)[4]
        try Self.editPart(chart.id, in: wb) { $0.replacingOccurrences(of: "<c:f>Sales!$B$2:$B$7</c:f>", with: "<c:f>[1]Sales!$B$2:$B$7</c:f>") }
        let external = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)[4]
        #expect(external.series[0].values == ChartReadingTests.north) // from the cache
        let old = try #require(external.settings)
        var new = old
        new.kind = .line
        #expect(XLSXChartEditor.update(external.id, from: old, to: new, in: wb))
        let after = XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id)[4]
        #expect(after.series[0].values == ChartReadingTests.north)
    }

    @Test func unionsAreFollowed() {
        let wb = ChartEditingTests.salesWorkbook()
        let ref = ChartReference("(Sales!$B$2:$B$3,Sales!$B$5:$B$7)", in: wb)
        #expect(ref.numbers(in: wb) == [120, 135, 142, 168, 181])
        #expect(!ChartReference("[2]Other!$A$1", in: wb).isFollowed)
        #expect(!ChartReference("NoSuchName", in: wb).isFollowed)
    }

    @Test func hiddenRowsAreLeftOutOfCachesToo() throws {
        let wb = ChartEditingTests.salesWorkbook()
        let sheet = wb.sheets[0]
        sheet.hiddenRows = [2]
        let id = try #require(XLSXChartEditor.insert(.new(.column, from: ChartEditingTests.block, in: wb), onSheet: sheet.id,
                                                      from: .init(column: 5, row: 1), to: .init(column: 10, row: 10), in: wb))
        let xml = try Self.partXML(id, in: wb)
        #expect(!xml.contains("<c:v>135</c:v>")) // Feb, hidden
        #expect(XLSXCharts.charts(in: wb, sheetID: sheet.id).first?.series[0].values.count == 5)
    }

    // MARK: Caches at save (#11)

    @Test func savingRefreshesCaches() throws {
        let wb = ChartEditingTests.salesWorkbook()
        let sheet = wb.sheets[0]
        let id = try #require(XLSXChartEditor.insert(.new(.column, from: ChartEditingTests.block, in: wb), onSheet: sheet.id,
                                                      from: .init(column: 5, row: 1), to: .init(column: 10, row: 10), in: wb))
        sheet.setCell(Cell(value: .number(999)), at: CellAddress(a1: "B2")!)
        let saved = try XLSXReader.read(data: XLSXWriter.data(for: wb))
        let xml = try Self.partXML(id, in: saved)
        #expect(xml.contains("<c:v>999</c:v>"))
        #expect(!xml.contains("<c:v>120</c:v>"))
    }

    // MARK: Groups (#8)

    /// A chart grouped with a text box.
    static func groupedChart() throws -> (Workbook, String) {
        let wb = ChartEditingTests.salesWorkbook()
        let sheetID = wb.sheets[0].id
        let id = try #require(XLSXChartEditor.insert(.new(.column, from: ChartEditingTests.block, in: wb), onSheet: sheetID,
                                                      from: .init(column: 5, row: 1), to: .init(column: 15, row: 21), in: wb))
        var carried = try #require(wb.carriedContent as? CarriedParts)
        let drawingPath = try #require(carried.parts.keys.first { $0.contains("drawings/") })
        var xml = String(decoding: try #require(carried.parts[drawingPath]).data, as: UTF8.self)
        let start = try #require(xml.range(of: "<xdr:graphicFrame"))
        let end = try #require(xml.range(of: "</xdr:graphicFrame>"))
        // The chart in the group's left half; a text box in the right half.
        let frame = String(xml[start.lowerBound..<end.upperBound])
            .replacingOccurrences(of: "<a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/>",
                                  with: "<a:off x=\"0\" y=\"0\"/><a:ext cx=\"500\" cy=\"1000\"/>")
        let group = "<xdr:grpSp><xdr:nvGrpSpPr><xdr:cNvPr id=\"10\" name=\"Group 1\"/><xdr:cNvGrpSpPr/></xdr:nvGrpSpPr>"
            + "<xdr:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"1000\" cy=\"1000\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"1000\" cy=\"1000\"/></a:xfrm></xdr:grpSpPr>"
            + frame
            + "<xdr:sp macro=\"\" textlink=\"\"><xdr:nvSpPr><xdr:cNvPr id=\"11\" name=\"Note kept by user\"/><xdr:cNvSpPr txBox=\"1\"/></xdr:nvSpPr><xdr:spPr><a:xfrm><a:off x=\"500\" y=\"0\"/><a:ext cx=\"500\" cy=\"1000\"/></a:xfrm></xdr:spPr></xdr:sp>"
            + "</xdr:grpSp>"
        xml.replaceSubrange(start.lowerBound..<end.upperBound, with: group)
        carried.parts[drawingPath]?.data = Data(xml.utf8)
        wb.carriedContent = carried
        return (wb, id)
    }

    @Test func aGroupedChartIsPlacedInItsGroup() throws {
        let (wb, id) = try Self.groupedChart()
        let chart = try #require(XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id).first)
        #expect(chart.id == id)
        #expect(chart.isGrouped)
        #expect(chart.groupFraction == SheetChart.UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        // It moves only with its group.
        #expect(!XLSXChartEditor.place(id, onSheet: wb.sheets[0].id, from: .init(column: 0, row: 0),
                                       to: .init(column: 3, row: 3), size: .init(width: 100, height: 100), in: wb))
    }

    @Test func deletingAGroupedChartKeepsTheRestOfTheGroup() throws {
        let (wb, id) = try Self.groupedChart()
        #expect(XLSXChartEditor.delete(id, onSheet: wb.sheets[0].id, in: wb))
        let carried = try #require(wb.carriedContent as? CarriedParts)
        let drawingPath = try #require(carried.parts.keys.first { $0.contains("drawings/") })
        let xml = String(decoding: try #require(carried.parts[drawingPath]).data, as: UTF8.self)
        #expect(xml.contains("Note kept by user"))
        #expect(!xml.contains("graphicFrame"))
        #expect(carried.parts[id] == nil)
        #expect(XLSXCharts.charts(in: wb, sheetID: wb.sheets[0].id).isEmpty)
    }

    // MARK: Parsing is kept per part (#5)

    @Test func movingAChartReparsesOnlyTheDrawing() throws {
        let wb = try ChartReadingTests.excelWorkbook()
        let sheetID = wb.sheets[0].id
        let source = SheetChartSource(workbook: wb, sheetID: sheetID)
        let before = source.charts(in: wb, inputsRevision: 1)
        XLSXChartEditor.place(before[4].id, onSheet: sheetID, from: .init(column: 1, row: 40),
                              to: .init(column: 6, row: 55), size: .init(width: 1, height: 1), in: wb)
        #expect(!source.isCurrent(for: wb))
        let next = SheetChartSource(workbook: wb, sheetID: sheetID, reusing: source)
        let clock = ContinuousClock()
        var after: [SheetChart] = []
        let elapsed = clock.measure { after = next.charts(in: wb, inputsRevision: 1) }
        // The charts' contents come from what was read before.
        #expect(after.map(\.fingerprint) == before.map(\.fingerprint))
        #expect(after[4].from == SheetChart.Anchor(column: 1, row: 40))
        #expect(elapsed < .milliseconds(20), "\(elapsed)")
    }
}
