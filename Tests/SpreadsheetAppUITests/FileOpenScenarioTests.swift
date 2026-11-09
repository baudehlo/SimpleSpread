#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// One file, one window: opening a file that's already open brings its
/// window forward, and Save As won't write over a file another window has open.
@MainActor
@Suite(.enabled(if: UITests.enabled), .serialized)
struct FileOpenScenarioTests {
    @Test func aFileInAWindowIsFoundByAnyOfItsNames() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOpenScenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Sales.xlsx")
        try SpreadsheetDocument.write(Corpus.sales().makeSaveSnapshot(), to: url)
        let alias = dir.appendingPathComponent("alias.xlsx")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)

        let doc = try SpreadsheetDocument.open(url: url)
        let app = await AppWindow(doc)
        defer { app.close() }
        let other = await AppWindow(Corpus.sales(), name: "other")
        defer { other.close() }

        check(DocumentWindowHook.window(showingFileAt: url) === app.window, "the window showing the file is found", app)
        check(DocumentWindowHook.window(showingFileAt: alias) === app.window, "found through a symlink too", app)
        check(DocumentWindowHook.window(showingFileAt: dir.appendingPathComponent("sales.XLSX")) === app.window,
              "and with the name in another case", app)
        check(DocumentWindowHook.window(showingFileAt: url, except: doc) == nil,
              "Save As onto a window's own file is not a clash", app)
        check(DocumentWindowHook.window(showingFileAt: dir.appendingPathComponent("New.xlsx")) == nil,
              "a file no window shows is not found", app)
        app.close()
        await app.settle()
        check(DocumentWindowHook.window(showingFileAt: url) == nil, "a closed window no longer counts", app)
    }
}
#endif
