#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Sort, Find and Filter, used through their dialogs, bars and popovers.
@MainActor
@Suite(.enabled(if: UITests.enabled), .serialized)
struct DialogScenarioTests {
    @Test func customSortDescending() async throws {
        let app = await AppWindow(Corpus.sales())
        defer { app.close() }
        let doc = app.document
        try await app.click("B3")
        try await app.menu("Custom Sort…")
        check(try await app.waitFor("Range A1:D7", in: app.sheet), "the Sort dialog shows the table's range", app)
        try await app.choose("Z to A", inPopUpShowing: "A to Z")
        try await app.click(text: "Sort", exact: true)
        check(app.sheet == nil, "Sort closes the dialog", app)
        check(doc.displayString(at: CellAddress(a1: "A2")!) == "Jun", "sorted Z to A by Month: Jun first", app)
        check(doc.displayString(at: CellAddress(a1: "A1")!) == "Month", "the header row stays put", app)
    }

    @Test func findTypedInTheFindBar() async throws {
        let app = await AppWindow(Corpus.sales())
        defer { app.close() }
        let doc = app.document
        try await app.menu("Find…")
        check(try await app.waitFor("Find in sheet"), "the Find bar shows", app)
        await app.settle(0.3)
        await app.type("14")
        await app.settle(0.3)
        check(doc.findQuery == "14", "typing goes into the Find bar (\(doc.findQuery))", app)
        check(doc.findMatches.count == 2, "both 142s are found (\(doc.findMatches.count))", app)
        check(try app.shows("1 of 2"), "the bar says where it is", app)
        await app.press(.returnKey)
        check(try app.shows("2 of 2"), "Return goes to the next", app)
        await app.press(.escape)
        check(!doc.isFindPresented, "Escape closes it", app)
    }

    @Test func filterFromTheHeaderButton() async throws {
        let app = await AppWindow(Corpus.sales())
        defer { app.close() }
        let doc = app.document
        try await app.click("A1")
        try await app.menu("Filter")
        check(doc.activeAutoFilter != nil, "Data ▸ Filter puts buttons on the header", app)
        try await app.click(at: try app.filterButton("A1"))
        let popover = try #require(app.popovers.first, "the filter popover opens")
        check(try await app.waitFor("Filter by values", in: popover), "it lists the values", app)
        // Only January. (By condition: the value checkboxes are SwiftUI
        // toggles that synthesized clicks can't reach in the test host.)
        try await app.choose("Equals", inPopUpShowing: "None", in: popover)
        try await app.click(text: "Value", in: popover, exact: true)
        await app.type("Jan", in: popover)
        try await app.click(text: "Apply", in: popover, exact: true)
        check(app.popovers.isEmpty, "Apply closes it", app)
        let shown = (1...6).filter { !doc.activeSheet.hiddenRows.contains($0) }
        check(shown == [1], "only Jan's row shows (\(shown))", app)
    }
}
#endif
