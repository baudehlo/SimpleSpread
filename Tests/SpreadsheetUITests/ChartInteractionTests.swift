import CoreGraphics
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Charts in a document: Insert ▸ Chart, selecting, moving and resizing
/// with the pointer, keys, the panel's edits, and undo.
@MainActor
@Suite struct ChartInteractionTests {
    static func salesDocument() -> SpreadsheetDocument {
        let doc = SpreadsheetDocument()
        let rows = [["Month", "North", "South", "West"], ["Jan", "120", "90", "60"], ["Feb", "135", "95", "72"],
                    ["Mar", "150", "110", "80"], ["Apr", "142", "125", "95"]]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() { doc.commitInput(text, at: CellAddress(row: r, column: c)) }
        }
        doc.undoManager.removeAllActions()
        return doc
    }

    /// A document with a column chart over A1:D5, and a controller on it.
    static func withChart() throws -> (SpreadsheetDocument, GridController, SheetChart) {
        let doc = salesDocument()
        doc.selection.select(range: CellRange(a1: "A1:D5")!)
        #expect(doc.insertChart(.column))
        let controller = GridController()
        controller.document = doc
        return (doc, controller, try #require(doc.selectedChart))
    }

    static func viewFrame(_ chart: SheetChart, _ controller: GridController) -> CGRect {
        SheetChartLayer.frame(of: chart, in: controller.geometry)
    }

    @Test func insertMakesASelectedChartBesideTheData() throws {
        let (doc, _, chart) = try Self.withChart()
        #expect(doc.activeCharts.count == 1)
        #expect(chart.kind == .column)
        #expect(chart.settings?.series.count == 3)
        #expect(chart.from.column == 5) // two columns right of D
        #expect(chart.from.row == 0)
        #expect(doc.isModified)
        doc.undoManager.undo()
        #expect(doc.activeCharts.isEmpty)
        #expect(doc.selectedChart == nil)
        doc.undoManager.redo()
        #expect(doc.activeCharts.count == 1)
    }

    @Test func insertFromOneCellTakesTheTableAroundIt() throws {
        let doc = Self.salesDocument()
        doc.selection.select(CellAddress(a1: "B3")!)
        #expect(doc.insertChart(.line))
        #expect(doc.selectedChart?.settings?.dataRange(in: doc.workbook)?.range == CellRange(a1: "A1:D5")!)
    }

    @Test func nothingToChartSaysSo() {
        let doc = SpreadsheetDocument()
        #expect(!doc.insertChart(.pie))
        #expect(doc.notice != nil)
        #expect(doc.activeCharts.isEmpty)
    }

    @Test func pressAndDragMoves() throws {
        let (doc, controller, chart) = try Self.withChart()
        doc.selectChart(nil)
        let frame = Self.viewFrame(chart, controller)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        controller.press(at: start)
        #expect(doc.selectedChartID == chart.id)
        controller.drag(to: CGPoint(x: start.x + 100, y: start.y + 44))
        #expect(controller.movingChart?.frame.origin == CGPoint(x: frame.minX + 100, y: frame.minY + 44))
        controller.release()
        let moved = try #require(doc.selectedChart)
        let movedFrame = Self.viewFrame(moved, controller)
        #expect(abs(movedFrame.minX - (frame.minX + 100)) < 1)
        #expect(abs(movedFrame.minY - (frame.minY + 44)) < 1)
        #expect(abs(movedFrame.width - frame.width) < 1)
        // One undo step puts it back.
        doc.undoManager.undo()
        #expect(Self.viewFrame(try #require(doc.selectedChart), controller).origin == frame.origin)
    }

    @Test func aClickWithoutMovingChangesNothing() throws {
        let (doc, controller, chart) = try Self.withChart()
        let frame = Self.viewFrame(chart, controller)
        let revision = doc.revision
        controller.press(at: CGPoint(x: frame.midX, y: frame.midY))
        controller.release()
        #expect(doc.revision == revision)
    }

    @Test func dragAHandleToResize() throws {
        let (doc, controller, chart) = try Self.withChart()
        let frame = Self.viewFrame(chart, controller)
        controller.press(at: CGPoint(x: frame.maxX, y: frame.maxY)) // bottom-right handle
        controller.drag(to: CGPoint(x: frame.maxX + 60, y: frame.maxY - 30))
        controller.release()
        let resized = Self.viewFrame(try #require(doc.selectedChart), controller)
        #expect(resized.origin == frame.origin)
        #expect(abs(resized.width - (frame.width + 60)) < 1)
        #expect(abs(resized.height - (frame.height - 30)) < 1)
    }

    @Test func handlesKeepAUsableSize() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let squashed = ChartHandle.topLeft.resize(frame, by: CGSize(width: 1000, height: 1000))
        #expect(squashed.width == 60 && squashed.height == 40)
        #expect(squashed.maxX == 300 && squashed.maxY == 200)
    }

    @Test func keysActOnTheSelectedChart() throws {
        let (doc, controller, chart) = try Self.withChart()
        let before = SpreadsheetDocument.contentFrame(of: chart, in: controller.layout)
        controller.handle(.arrow(.right), shift: true)
        let nudged = SpreadsheetDocument.contentFrame(of: try #require(doc.selectedChart), in: controller.layout)
        #expect(abs(nudged.minX - (before.minX + 10)) < 1)
        controller.handle(.escape)
        #expect(doc.selectedChart == nil)
        doc.selectChart(chart.id)
        controller.handle(.delete)
        #expect(doc.activeCharts.isEmpty)
        // The cells weren't cleared.
        #expect(doc.displayString(at: CellAddress(a1: "B2")!) == "120")
        doc.undoManager.undo()
        #expect(doc.activeCharts.count == 1)
    }

    @Test func clickingACellDeselects() throws {
        let (doc, controller, _) = try Self.withChart()
        let cell = controller.geometry.cellRect(CellAddress(a1: "A10")!)
        controller.press(at: CGPoint(x: cell.midX, y: cell.midY))
        controller.release()
        #expect(doc.selectedChartID == nil)
        #expect(doc.selection.activeCell == CellAddress(a1: "A10")!)
    }

    @Test func typingGoesToTheCellNotTheChart() throws {
        let (doc, controller, _) = try Self.withChart()
        controller.beginEditing(mode: .enter, initialText: "")
        #expect(doc.selectedChartID == nil)
    }

    @Test func colourChangesInARowAreOneUndoStep() throws {
        let (doc, _, chart) = try Self.withChart()
        var settings = try #require(chart.settings)
        for red in [10, 60, 120] as [UInt8] {
            settings.series[0].color = .rgb(RGBAColor(red: red, green: 0, blue: 0))
            doc.updateChart(chart.id, to: settings)
        }
        #expect(doc.selectedChart?.series[0].color == RGBAColor(red: 120, green: 0, blue: 0))
        doc.undoManager.undo()
        #expect(doc.selectedChart?.settings?.series[0].color == nil)
        // A different setting is its own step.
        settings = try #require(doc.selectedChart?.settings)
        settings.legend = .right
        doc.updateChart(chart.id, to: settings)
        settings.title = .text("Sales")
        doc.updateChart(chart.id, to: settings)
        doc.undoManager.undo()
        #expect(doc.selectedChart?.settings?.legend == .right)
        #expect(doc.selectedChart?.settings?.title == .automatic)
    }

    @Test func typedDataRange() throws {
        let (doc, _, chart) = try Self.withChart()
        #expect(doc.setChartData(chart.id, range: "A1:B5"))
        #expect(doc.selectedChart?.series.count == 1)
        #expect(doc.selectedChart?.series[0].values == [120, 135, 150, 142])
        #expect(doc.setChartData(chart.id, range: "=Sheet1!$A$1:$D$3", inRows: true))
        #expect(doc.selectedChart?.series.count == 2)
        #expect(!doc.setChartData(chart.id, range: "not a range"))
        #expect(!doc.setChartData(chart.id, range: "Nowhere!A1:B2"))
    }

    @Test func changingSheetsDeselects() throws {
        let (doc, _, _) = try Self.withChart()
        doc.addSheet()
        #expect(doc.selectedChartID == nil)
    }

    @Test func chartsFollowTheirCells() throws {
        let (doc, _, chart) = try Self.withChart()
        doc.commitInput("500", at: CellAddress(a1: "B2")!)
        #expect(doc.activeCharts.first { $0.id == chart.id }?.series[0].values.first == 500)
    }

    @Test func savedChartsComeBack() throws {
        let (doc, _, chart) = try Self.withChart()
        var settings = try #require(chart.settings)
        settings.kind = .bar
        settings.title = .text("Regions")
        doc.updateChart(chart.id, to: settings)
        let reread = SpreadsheetDocument(workbook: try XLSXReader.read(data: XLSXWriter.data(for: doc.workbook)))
        let saved = try #require(reread.activeCharts.first)
        #expect(saved.kind == .bar)
        #expect(saved.title == "Regions")
    }

    @Test func chartMenuSelectsAndOffersDelete() throws {
        let (doc, controller, chart) = try Self.withChart()
        doc.selectChart(nil)
        let frame = Self.viewFrame(chart, controller)
        let menu = try #require(controller.chartMenu(at: CGPoint(x: frame.midX, y: frame.midY)))
        #expect(doc.selectedChartID == chart.id)
        let delete = try #require(menu.flatMap { $0 }.first { $0.title == "Delete Chart" })
        delete.action()
        #expect(doc.activeCharts.isEmpty)
        #expect(controller.chartMenu(at: CGPoint(x: frame.midX, y: frame.midY)) == nil)
    }
}
