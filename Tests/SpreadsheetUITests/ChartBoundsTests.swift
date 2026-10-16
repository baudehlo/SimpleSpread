import CoreGraphics
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// A grid host scrolled to `visibleGridRect`, for tests.
@MainActor
final class ScrolledHost: GridHost {
    var visibleGridRect: CGRect
    var redraws = 0
    init(visible: CGRect) { visibleGridRect = visible }
    func gridNeedsDisplay() { redraws += 1 }
    func gridSizeChanged() {}
    func scrollGrid(to origin: CGPoint) { visibleGridRect.origin = origin }
    func showEditor(text: String, frame: CGRect) {}
    var editorText: String { "" }
    func removeEditor(refocusGrid: Bool) {}
    func selectionDidChange() {}
}

/// Charts stay bounded in work, time and memory, and behave when scrolled,
/// frozen and with hidden rows.
@MainActor
@Suite struct ChartBoundsTests {
    static func bigDocument(rows: Int) -> SpreadsheetDocument {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Data")
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        sheet.setCell(Cell(value: .string("Month")), at: CellAddress(row: 0, column: 0))
        sheet.setCell(Cell(value: .string("Load")), at: CellAddress(row: 0, column: 1))
        for r in 1...rows {
            sheet.setCell(Cell(value: .string(months[r % 12])), at: CellAddress(row: r, column: 0))
            sheet.setCell(Cell(value: .number(Double((r * 7919) % 1000))), at: CellAddress(row: r, column: 1))
        }
        return SpreadsheetDocument(workbook: wb)
    }

    // MARK: Time and memory (#1, #12)

    @Test func aTwentyThousandPointChartDrawsQuickly() throws {
        let doc = Self.bigDocument(rows: 20_000)
        doc.selection.select(CellAddress(a1: "A1")!)
        #expect(doc.insertChart(.line))
        let chart = try #require(doc.selectedChart)
        let plotted = PlottedChart(chart, width: 480)
        #expect((plotted.series.first?.points.count ?? 0) <= 960)
        let layer = SheetChartLayer()
        layer.rendersSynchronously = true
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = layer.image(of: chart, size: CGSize(width: 480, height: 288), scale: 2, dark: false) }
        #expect(elapsed < .seconds(2), "\(elapsed)")
        // A column chart of them too: bars are bounded by the width.
        var settings = try #require(chart.settings)
        settings.kind = .column
        doc.updateChart(chart.id, to: settings)
        let columns = try #require(doc.selectedChart)
        #expect((PlottedChart(columns, width: 480).series.first?.points.count ?? 0) <= 170)
        let columnsTime = clock.measure { _ = layer.image(of: columns, size: CGSize(width: 480, height: 288), scale: 2, dark: false) }
        #expect(columnsTime < .seconds(2), "\(columnsTime)")
    }

    @Test func imagesStayWithinThePixelBudget() throws {
        let (doc, _, chart) = try ChartInteractionTests.withChart()
        _ = doc
        let layer = SheetChartLayer()
        layer.rendersSynchronously = true
        let image = try #require(layer.image(of: chart, size: CGSize(width: 1600, height: 1300), scale: 8, dark: false))
        #expect(Double(image.width * image.height) <= SheetChartLayer.maxPixels * 1.01)
    }

    @Test func imagesAreMadeAfterTheDraw() async throws {
        let (_, _, chart) = try ChartInteractionTests.withChart()
        let layer = SheetChartLayer()
        var ready = 0
        layer.onImageReady = { ready += 1 }
        #expect(layer.image(of: chart, size: CGSize(width: 400, height: 250), scale: 1, dark: false) == nil)
        #expect(layer.isRendering)
        for _ in 0..<50 where layer.isRendering { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ready == 1)
        #expect(layer.image(of: chart, size: CGSize(width: 400, height: 250), scale: 1, dark: false) != nil)
        // A new size draws the old image until the new one is made.
        #expect(layer.image(of: chart, size: CGSize(width: 500, height: 250), scale: 1, dark: false) != nil)
    }

    // MARK: Work per edit (#5)

    @Test func resizingColumnsDoesNotReadChartsAgain() throws {
        let (doc, _, _) = try ChartInteractionTests.withChart()
        let before = doc.chartInputsRevision
        doc.setColumnWidth(2, width: 140)
        doc.setRowHeight(3, height: 40)
        #expect(doc.chartInputsRevision == before)
        doc.commitInput("7", at: CellAddress(a1: "B2")!)
        #expect(doc.chartInputsRevision != before)
    }

    @Test func editsElsewhereDoNotReadChartsAgain() throws {
        let wb = Workbook()
        let sheet = wb.addSheet(named: "Data")
        for r in 0..<5000 { for c in 0..<4 {
            sheet.setCell(Cell(value: c == 0 ? .string("L\(r % 12)") : .number(Double(r * c % 997))),
                          at: CellAddress(row: r, column: c))
        } }
        let doc = SpreadsheetDocument(workbook: wb)
        for i in 0..<10 {
            doc.selection.select(range: CellRange(a1: "A1:D5000")!)
            #expect(doc.insertChart(.line))
            if let id = doc.selectedChartID { doc.placeChart(id, frame: CGRect(x: 400, y: Double(i) * 300, width: 400, height: 280)) }
        }
        _ = doc.activeCharts
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<5 {
                doc.commitInput("\(i)", at: CellAddress(a1: "H1")!) // outside every chart's cells
                _ = doc.activeCharts
            }
        }
        #expect(elapsed / 5 < .milliseconds(40), "\(elapsed / 5) per edit")
        // An edit inside the data does reach the charts.
        doc.commitInput("12345", at: CellAddress(a1: "B2")!)
        #expect(doc.activeCharts.allSatisfy { $0.series[0].values.contains(12345) })
    }

    @Test func formulasInsideAChartFollowCellsOutsideIt() throws {
        let (doc, _, chart) = try ChartInteractionTests.withChart()
        doc.commitInput("10", at: CellAddress(a1: "H1")!)
        doc.commitInput("=H1*2", at: CellAddress(a1: "B3")!)
        #expect(doc.activeCharts.first { $0.id == chart.id }?.series[0].values[1] == 20)
        doc.commitInput("50", at: CellAddress(a1: "H1")!) // recalculates B3
        #expect(doc.activeCharts.first { $0.id == chart.id }?.series[0].values[1] == 100)
        // Hiding a row it plots reads it again too.
        doc.hideRows(2...2)
        #expect(doc.activeCharts.first { $0.id == chart.id }?.series[0].values.count == 3)
    }

    @Test func heldArrowKeysAreOneUndoStep() throws {
        let (doc, controller, chart) = try ChartInteractionTests.withChart()
        let start = SpreadsheetDocument.contentFrame(of: chart, in: controller.layout)
        for _ in 0..<5 { controller.handle(.arrow(.down)) }
        let moved = SpreadsheetDocument.contentFrame(of: try #require(doc.selectedChart), in: controller.layout)
        #expect(abs(moved.minY - (start.minY + 5)) < 1)
        doc.undoManager.undo()
        let back = SpreadsheetDocument.contentFrame(of: try #require(doc.selectedChart), in: controller.layout)
        #expect(abs(back.minY - start.minY) < 1)
    }

    // MARK: Interaction when scrolled, frozen, hidden (#13)

    @Test func draggingAcrossAFrozenLineDoesNotJump() throws {
        let doc = ChartInteractionTests.salesDocument()
        doc.selection.select(range: CellRange(a1: "A1:D5")!)
        #expect(doc.insertChart(.column))
        let id = try #require(doc.selectedChartID)
        // The chart well down the sheet; the header row frozen; scrolled to it.
        doc.placeChart(id, frame: CGRect(x: 300, y: 2000, width: 400, height: 250))
        doc.freezePanes(rows: 1, columns: 0)
        let controller = GridController()
        controller.document = doc
        let host = ScrolledHost(visible: CGRect(x: 0, y: 1900, width: 1000, height: 700))
        controller.host = host
        let frame = SheetChartLayer.frame(of: try #require(doc.selectedChart), in: controller.geometry)
        let start = CGPoint(x: frame.midX, y: frame.minY + 20)
        controller.press(at: start)
        // Up past the frozen row's line (into the frozen pane, in view terms).
        let end = CGPoint(x: start.x, y: host.visibleGridRect.minY + 30)
        controller.drag(to: end)
        let moving = try #require(controller.movingChart)
        #expect(abs(moving.frame.minY - (frame.minY + (end.y - start.y))) < 0.5)
        controller.release()
        let placed = SheetChartLayer.frame(of: try #require(doc.selectedChart), in: controller.geometry)
        #expect(abs(placed.minY - moving.frame.minY) < 1)
    }

    @Test func chartsOverHiddenRowsStillSelect() throws {
        let (doc, controller, chart) = try ChartInteractionTests.withChart()
        doc.hideRows(2...4)
        let frame = SheetChartLayer.frame(of: try #require(doc.activeCharts.first), in: controller.geometry)
        #expect(frame.height > 0)
        doc.selectChart(nil)
        controller.press(at: CGPoint(x: frame.midX, y: frame.midY))
        controller.release()
        #expect(doc.selectedChartID == chart.id)
    }

    // MARK: Insert (#7)

    @Test func insertFromWholeColumnsTakesOnlyTheData() throws {
        let doc = ChartInteractionTests.salesDocument()
        let controller = GridController()
        controller.document = doc
        // Column headers A to D, as a click and drag on them selects.
        doc.selection.select(range: CellRange(start: CellAddress(row: 0, column: 0),
                                              end: CellAddress(row: controller.layout.rowCount - 1, column: 3)))
        #expect(doc.insertChart(.column))
        let settings = try #require(doc.selectedChart?.settings)
        #expect(settings.dataRange(in: doc.workbook)?.range == CellRange(a1: "A1:D5")!)
        #expect(settings.series[0].values == "Sheet1!$B$2:$B$5")
    }

    // MARK: Structural edits and undo stay in step

    @Test func structuralEditAndUndoKeepChartInStep() throws {
        let (doc, _, chart) = try ChartInteractionTests.withChart()
        doc.insertRows(at: 0, count: 2)
        var settings = try #require(doc.activeCharts.first?.settings)
        #expect(doc.activeCharts.first?.from.row == 2)
        #expect(settings.series[0].values == "Sheet1!$B$4:$B$7")
        settings.title = .text("After rows")
        doc.updateChart(chart.id, to: settings)
        doc.undoManager.undo() // the title
        doc.undoManager.undo() // the rows
        #expect(doc.activeCharts.first?.from.row == 0)
        #expect(doc.activeCharts.first?.settings?.series[0].values == "Sheet1!$B$2:$B$5")
        #expect(doc.activeCharts.first?.settings?.title == .automatic)
        doc.undoManager.redo()
        doc.undoManager.redo()
        #expect(doc.activeCharts.first?.from.row == 2)
        #expect(doc.activeCharts.first?.title == "After rows")
    }

    // MARK: Keyboard and VoiceOver (#14)

    @Test func tabAndTheMenuReachEveryChart() throws {
        let doc = ChartInteractionTests.salesDocument()
        for kind in [SheetChart.Kind.column, .line] {
            doc.selection.select(range: CellRange(a1: "A1:D5")!)
            #expect(doc.insertChart(kind))
        }
        let controller = GridController()
        controller.document = doc
        doc.selection.select(CellAddress(a1: "A1")!)
        #expect(doc.selectedChartID == nil)
        doc.selectNextChart() // Insert ▸ Select Next Chart
        let first = try #require(doc.selectedChartID)
        controller.handle(.tab)
        let second = try #require(doc.selectedChartID)
        #expect(second != first)
        controller.handle(.tab, shift: true)
        #expect(doc.selectedChartID == first)
        // VoiceOver finds them, and hears what they are.
        let items = controller.visibleChartsForAccessibility
        #expect(items.count == 2)
        #expect(items[0].label.contains("column chart"))
        #expect(items[0].label.contains("3 series"))
        #expect(items[0].label.contains("Sheet1!A1:D5"))
        #expect(controller.accessibilitySummary?.hasPrefix("Selected Chart") == true)
    }
}
