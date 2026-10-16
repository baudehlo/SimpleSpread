#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Making, arranging and changing charts the way a person does.
@MainActor
@Suite(.enabled(if: UITests.enabled), .serialized)
struct ChartScenarioTests {
    @Test func insertMoveRestyleAndDeleteAChart() async throws {
        let app = await AppWindow(Corpus.sales())
        defer { app.close() }
        let doc = app.document
        try await app.click("B3")
        try await app.menu("Column", in: "Insert")
        let chart = try #require(doc.selectedChart, "Insert ▸ Chart ▸ Column makes and selects a chart")
        check(try await app.waitFor("Chart Title"), "the chart shows (its title reads off the screen)", app)
        check(try app.shows("Series in"), "the Chart panel shows", app)
        check(try app.shows("Clustered"), "with its stacking choice", app)
        app.note("inserted")

        // Stacked, from the panel.
        try await app.click(text: "Stacked", in: app.window, exact: true)
        check(doc.selectedChart?.settings?.grouping == .stacked, "Stacked in the panel stacks it", app)

        // Drag it by its middle, 200 points right.
        let frame = try app.chartFrame(try #require(doc.selectedChart))
        await app.drag(from: CGPoint(x: frame.midX, y: frame.midY), to: CGPoint(x: frame.midX + 200, y: frame.midY))
        let moved = try app.chartFrame(try #require(doc.activeCharts.first))
        check(abs(moved.minX - (frame.minX + 200)) < 2, "the chart moves with the drag (\(frame.minX) → \(moved.minX))", app)

        // A click on a cell deselects; a click on the chart selects it again.
        try await app.click("A12")
        check(doc.selectedChart == nil, "a cell click deselects the chart", app)
        check(!(try app.shows("Series in")), "and the Chart panel goes", app)
        try await app.click(at: CGPoint(x: moved.midX, y: moved.midY))
        check(doc.selectedChartID == chart.id, "a click on the chart selects it", app)

        // Delete, then Edit ▸ Undo.
        await app.press(.delete)
        check(doc.activeCharts.isEmpty, "Delete removes it", app)
        await app.edit("undo:")
        check(doc.activeCharts.count == 1, "Undo brings it back", app)
        app.note("done")
    }

    /// Excel's own charts: each can be selected and named in the panel, and
    /// Tab walks through them.
    @Test func excelsChartsSelectAndTab() async throws {
        let app = await AppWindow(try Corpus.document(.excelCharts), size: CGSize(width: 1600, height: 1000))
        defer { app.close() }
        let doc = app.document
        let first = try #require(doc.activeCharts.first)
        let frame = try app.chartFrame(first)
        try await app.click(at: CGPoint(x: frame.midX, y: frame.midY))
        check(doc.selectedChartID == first.id, "a click selects Excel's chart", app)
        check(try app.shows(first.name), "the panel names it (\(first.name))", app)
        await app.press(.tab)
        check(doc.selectedChartID == doc.activeCharts[1].id, "Tab goes to the next chart", app)
        await app.press(.escape)
        check(doc.selectedChart == nil, "Escape goes back to the cells", app)
    }
}
#endif
