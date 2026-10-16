#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Typing, selecting and moving about the grid with the mouse and keys.
@MainActor
@Suite(.enabled(if: UITests.enabled), .serialized)
struct GridScenarioTests {
    @Test func typeNumbersAndAFormula() async throws {
        let app = await AppWindow(try Corpus.document(.blank))
        defer { app.close() }
        let doc = app.document
        try await app.click("B2")
        await app.type("42")
        await app.press(.returnKey)
        check(doc.displayString(at: CellAddress(a1: "B2")!) == "42", "B2 holds 42", app)
        check(doc.selection.activeCell == CellAddress(a1: "B3")!, "Return moves down", app)
        await app.type("=B2*2")
        await app.press(.tab)
        check(doc.displayString(at: CellAddress(a1: "B3")!) == "84", "B3 computes 84", app)
        check(doc.selection.activeCell == CellAddress(a1: "C3")!, "Tab moves right", app)
        // Double-click to edit, Escape to leave it as it was.
        try await app.click("B2", count: 2)
        await app.type("9")
        await app.press(.escape)
        check(doc.displayString(at: CellAddress(a1: "B2")!) == "42", "Escape leaves B2 as it was", app)
        // The grid shows what's in the cells.
        check(try app.shows("84"), "84 shows on screen", app)
        app.note("typed")
    }

    @Test func selectFillResizeAndUseHeaderMenus() async throws {
        let app = await AppWindow(Corpus.sales())
        defer { app.close() }
        let doc = app.document
        let grid = try #require(app.grid)

        // Drag to select B2:C4; the status bar sums it.
        try await app.drag("B2", to: "C4")
        check(doc.selection.range == CellRange(a1: "B2:C4")!, "a drag selects B2:C4 (\(doc.selection.range.a1))", app)
        check(try app.shows("Sum: 700"), "the status bar shows the sum", app)

        // Shift-arrow grows it; arrows move.
        await app.press(.down, modifiers: .shift)
        check(doc.selection.range == CellRange(a1: "B2:C5")!, "Shift-Down grows the selection", app)
        await app.press(.right)
        check(doc.selection.isSingleCell, "an arrow collapses it and moves", app)

        // The fill handle: B7's value dragged down two rows.
        try await app.click("B7")
        let cell = grid.controller.geometry.cellRect(CellAddress(a1: "B7")!)
        let handle = try app.windowPoint(grid: CGPoint(x: cell.maxX - 1, y: cell.maxY - 1))
        let target = try app.point("B9")
        await app.drag(from: handle, to: target)
        check(doc.displayString(at: CellAddress(a1: "B9")!) == "181", "the fill handle copies down (\(doc.displayString(at: CellAddress(a1: "B9")!)))", app)

        // Widen column B by dragging its header's right edge.
        let before = doc.activeSheet.columnWidth(1)
        let header = grid.controller.geometry.cellRect(CellAddress(a1: "B1")!)
        let edge = try app.windowPoint(grid: CGPoint(x: header.maxX, y: grid.visibleRect.minY + 10))
        await app.drag(from: edge, to: CGPoint(x: edge.x + 60, y: edge.y))
        check(abs(doc.activeSheet.columnWidth(1) - (before + 60)) < 3, "column B widens by the drag", app)

        // A row header's menu: insert a row above row 3.
        let rowHeader = try app.windowPoint(grid: CGPoint(x: grid.visibleRect.minX + 10,
                                                         y: grid.controller.geometry.cellRect(CellAddress(a1: "A3")!).midY))
        let items = try await app.rightClick(at: rowHeader, choose: "Insert Row Above")
        check(items.contains("Insert Row Above"), "the row header menu offers Insert Row Above (\(items))", app)
        check(doc.displayString(at: CellAddress(a1: "A4")!) == "Feb", "a row went in above Feb", app)

        // Delete clears; Edit ▸ Undo puts it back.
        try await app.click("B4")
        await app.press(.delete)
        check(doc.displayString(at: CellAddress(a1: "B4")!) == "", "Delete clears the cell", app)
        await app.edit("undo:")
        check(doc.displayString(at: CellAddress(a1: "B4")!) == "135", "Undo puts it back", app)
    }

    /// Typing into the formula bar (a SwiftUI text field) edits the cell.
    @Test func editInTheFormulaBar() async throws {
        let app = await AppWindow(Corpus.sales())
        defer { app.close() }
        let doc = app.document
        try await app.click("D2")
        try await app.click(text: "60", in: app.window, exact: true) // the formula bar shows D2's 60
        await app.settle(0.2)
        for _ in 0..<4 { await app.press(.delete) }
        await app.type("=B2+C2")
        await app.press(.returnKey)
        check(doc.activeSheet.cell(at: CellAddress(a1: "D2")!).formula == "B2+C2", "the formula bar wrote D2's formula", app)
        check(doc.displayString(at: CellAddress(a1: "D2")!) == "210", "D2 shows 210", app)
    }

    /// The 20,000-row table: scroll to its end, edit there, and insert a row
    /// above everything, all promptly.
    @Test func aBigSheetStaysResponsive() async throws {
        let clock = ContinuousClock()
        var doc: SpreadsheetDocument?
        let opened = try clock.measure { doc = try Corpus.document(.complex) }
        let app = await AppWindow(try #require(doc))
        defer { app.close() }
        check(opened < .seconds(10), "the workbook opens promptly (\(opened))", app)
        let document = app.document
        document.activeSheetID = try #require(document.workbook.sheet(named: "Data")).id
        await app.settle()
        let scroll = try await clock.measure { try await app.click("E20001") }
        check(scroll < .seconds(1), "scrolling to the last row and clicking is prompt (\(scroll))", app)
        let typing = await clock.measure {
            await app.type("7")
            await app.press(.returnKey)
        }
        check(document.displayString(at: CellAddress(a1: "E20001")!) == "7", "the edit lands", app)
        check(typing < .seconds(2), "typing there is prompt (\(typing))", app)
        try await app.click("A2")
        let insert = try await clock.measure { try await app.menu("Row Above") }
        check(insert < .seconds(3), "inserting a row above 20,000 (with pivots and a chart over them) is prompt (\(insert))", app)
        check(document.displayString(at: CellAddress(a1: "B3")!) != "", "the data moved down", app)
    }
}
#endif
