#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Every menu command (the menus' own catalog), on every kind of document:
/// each one, when enabled, must do something you can see, promptly, and
/// a dialog or bar it opens must show and stay open. Each is undone after.
@MainActor
@Suite(.enabled(if: UITests.enabled), .serialized)
struct MenuSweepTests {
    /// What the document looks like from outside: anything a command could
    /// change that a person would notice.
    struct Observable: Equatable {
        var revision: Int
        var zoom: CGFloat
        var sheet: Int
        var selection: SelectionState
        var chart: String?
        var pivotPanel: Bool
        var find: Bool
        var sheetShowing: Bool
        var notice: String?

        @MainActor init(_ app: AppWindow) {
            let d = app.document
            revision = d.revision
            zoom = d.zoomLevel
            sheet = d.activeSheetID
            selection = d.selection
            chart = d.selectedChartID
            pivotPanel = d.isPivotPanelVisible
            find = d.isFindPresented
            sheetShowing = app.sheet != nil
            notice = d.notice?.message
        }
    }

    /// Commands that open something, and the text that shows it's open.
    static let opens: [String: (where: String, text: String)] = [
        "PivotTable…": ("sheet", "Create PivotTable"),
        "Custom Sort…": ("sheet", "Sort"),
        "Find…": ("window", "Find in sheet"),
    ]

    /// Where to stand in each document: a block inside its data (so fills,
    /// merges and inside borders have something to act on).
    static func standing(_ kind: Corpus.Kind) -> (String, String) {
        switch kind {
        case .blank: ("B2", "C3")
        case .sample: ("B3", "C4")
        case .sales: ("B3", "C4")
        case .complex: ("C5", "D6")
        case .excelCharts: ("B3", "C4")
        }
    }

    /// Commands that do nothing from a plain cell, and the state that
    /// gives them something to do.
    static let prepare: [String: (SpreadsheetDocument) -> Void] = [
        "Actual Size": { $0.zoomIn() },
        "Automatic": { $0.setNumberFormat(.percent) },
        "Decrease Indent": { $0.adjustIndent(by: 1) },
        "No Border": { $0.applyBorders(.all) },
        "Clear Formatting": { $0.toggleBold() },
        "Unmerge Cells": { $0.mergeSelection(.merge) },
        // Commands enabled only by some state: give them it.
        "Find Next": findSomething,
        "Find Previous": findSomething,
        "Reapply Filter": { if $0.activeAutoFilter == nil { $0.toggleAutoFilter() } },
        "Clear Filters": { d in
            if d.activeAutoFilter == nil { d.toggleAutoFilter() }
            if let filter = d.activeAutoFilter {
                let first = d.displayString(at: CellAddress(row: filter.headerRow + 1, column: filter.range.start.column))
                d.setColumnFilter(0, ColumnFilter(values: [first]))
            }
        },
        "Refresh": { d in
            if let pivot = d.workbook.pivotTables.first {
                d.activeSheetID = pivot.sheetID
                d.selection.select(pivot.location.start)
            }
        },
    ]

    /// Find something that shows up all over (so there's a next one).
    static let findSomething: (SpreadsheetDocument) -> Void = { d in
        d.presentFind()
        d.setFindQuery("1")
    }

    /// Commands that may rightly do nothing in a document (nothing to act on).
    static let mayDoNothing: [Corpus.Kind: Set<String>] = [
        .blank: ["Sort A to Z", "Sort Z to A", "Fill Down", "Fill Right"],
    ]

    @Test(arguments: Corpus.Kind.allCases)
    func everyMenuCommandDoesSomething(on kind: Corpus.Kind) async throws {
        let document = try Corpus.document(kind)
        if kind == .complex, let data = document.workbook.sheet(named: "Data") { document.activeSheetID = data.id }
        let app = await AppWindow(document, name: "menus-\(kind.rawValue)")
        defer { app.close() }
        document.confirm = { _, _, _ in true }
        let budget: Duration = kind == .complex ? .seconds(5) : .seconds(2)
        var ran: [String] = [], disabled: [String] = []

        let home = document.activeSheetID
        let hadFilter = document.activeAutoFilter != nil
        for command in DocumentCommand.all {
            // Start each one from the same place.
            if document.activeSheetID != home { document.activeSheetID = home }
            if (document.activeAutoFilter != nil) != hadFilter { document.toggleAutoFilter() }
            document.undoManager.removeAllActions()
            if document.isFindPresented { document.dismissFind() }
            if let sheet = app.sheet { app.window.endSheet(sheet) }
            document.notice = nil
            let (from, to) = Self.standing(kind)
            try await app.click(from)
            try await app.click(to, modifiers: .shift)
            if let setup = Self.prepare[command.name] {
                setup(document)
                document.undoManager.removeAllActions()
                await app.settle(0.1)
                // A big sheet is searched in the background.
                for _ in 0..<50 where document.isFindSearching { await app.settle(0.1) }
            }
            let label = "\(command.menu) ▸ \(command.submenu.map { "\($0) ▸ " } ?? "")\(command.name)"
            guard command.isEnabled(document) else {
                disabled.append(label)
                continue
            }
            ran.append(label)
            let before = Observable(app)
            let clock = ContinuousClock()
            let elapsed = try await clock.measure { try await app.menu(command.name, in: command.menu) }
            check(elapsed < budget, "\(label) took \(elapsed)", app)

            if let opens = Self.opens[command.name] {
                let target = opens.where == "sheet" ? app.sheet : app.window
                check(target != nil, "\(label) opens its dialog", app)
                if target != nil {
                    check(try await app.waitFor(opens.text, in: target), "\(label) shows \"\(opens.text)\"", app)
                    await app.settle(0.8)
                    check(opens.where == "sheet" ? app.sheet != nil : document.isFindPresented,
                          "\(label) stays open", app)
                }
                if let sheet = app.sheet, try app.find("Cancel", in: sheet, exact: true) != nil {
                    try await app.click(text: "Cancel", in: sheet, exact: true)
                    check(app.sheet == nil, "\(label): Cancel closes it", app)
                }
                if document.isFindPresented {
                    await app.press(.escape)
                    document.dismissFind()
                }
            } else if !(Self.mayDoNothing[kind]?.contains(command.name) ?? false) {
                check(Observable(app) != before, "\(label) did nothing you could see", app)
            }
            // Back as it was (what `prepare` did is cleared by hand).
            while document.undoManager.canUndo { document.undoManager.undo() }
            if Self.prepare[command.name] != nil, document.activeSheetID == home {
                if command.name == "Unmerge Cells" { document.unmergeSelection() }
                document.clearFormattingInSelection()
                document.undoManager.removeAllActions()
            }
            if document.zoomLevel != 1 { document.resetZoom() }
            document.selectChart(nil)
            await app.settle(0.1)
        }
        print("Menu sweep (\(kind.rawValue)): ran \(ran.count), disabled here: \(disabled.joined(separator: ", "))")
        #expect(ran.count > 20)
    }
}
#endif
