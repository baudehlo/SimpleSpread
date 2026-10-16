#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Making and shaping a pivot table the way a person does it.
@MainActor
@Suite(.enabled(if: UITests.enabled), .serialized)
struct PivotScenarioTests {
    /// Insert ▸ PivotTable… over the sales table, Create, tick fields in the
    /// panel, then go and look at the data: the panel stays.
    @Test func makeAPivotFromTheMenuAndPanel() async throws {
        let app = await AppWindow(Corpus.sales())
        defer { app.close() }
        let doc = app.document
        let dataSheet = doc.activeSheetID
        try await app.click("B3")
        try await app.menu("PivotTable…")
        check(try await app.waitFor("Create PivotTable", in: app.sheet), "the Create PivotTable dialog shows", app)
        app.note("dialog")
        try await app.click(text: "Create", exact: true)
        check(app.sheet == nil, "the dialog closes after Create", app)
        check(doc.workbook.pivotTables.count == 1, "a pivot table is made", app)
        check(try await app.waitFor("PivotTable Fields"), "the PivotTable Fields panel shows", app)
        app.note("panel")
        // Tick Month (to Rows) and North (to Values) in the field list.
        try await app.click(text: "Month", in: app.window)
        try await app.click(text: "North", in: app.window)
        let definition = try #require(doc.workbook.pivotTables.first?.definition)
        check(definition.rowFields.count == 1, "Month went to Rows", app)
        check(definition.dataFields.count == 1, "North went to Values", app)
        app.note("fields")
        // Over to the data, on its own sheet, by its tab: the panel stays.
        try await app.click(text: "Sheet1", in: app.window, exact: true)
        check(doc.activeSheetID == dataSheet, "the data sheet is showing", app)
        try await app.click("C4")
        check(try await app.waitFor("PivotTable Fields"), "the panel stays while the data is selected", app)
        app.note("data")
    }

    /// A workbook that already has pivots (the dialog used to close itself
    /// at once), from an empty cell and from inside the 20,000-row table
    /// (whose range used to take minutes to suggest).
    @Test func theDialogOpensOnABigWorkbookWithPivots() async throws {
        let app = await AppWindow(try Corpus.document(.complex))
        defer { app.close() }
        let doc = app.document
        let data = try #require(doc.workbook.sheet(named: "Data"))
        doc.activeSheetID = data.id
        await app.settle()
        for cell in ["K5", "C100"] {
            try await app.click(cell)
            let clock = ContinuousClock()
            let start = clock.now
            try await app.menu("PivotTable…")
            check(try await app.waitFor("Create PivotTable", in: app.sheet), "the dialog shows (from \(cell))", app)
            check(clock.now - start < .seconds(2), "and quickly (\(clock.now - start))", app)
            await app.settle(1)
            check(app.sheet != nil, "the dialog stays open (from \(cell))", app)
            if cell == "C100" {
                check(try app.shows("A1:H20001", in: app.sheet), "it suggests the whole table", app)
            }
            try await app.click(text: "Cancel", exact: true)
            check(app.sheet == nil, "Cancel closes it", app)
        }
    }
}
#endif
