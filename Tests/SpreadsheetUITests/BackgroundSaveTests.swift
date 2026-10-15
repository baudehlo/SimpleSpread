import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Saving from a snapshot on another thread: what is written, what the
/// modified flag says afterwards, Cancel, and one save at a time.
@MainActor
@Suite("Saving in the background")
struct BackgroundSaveTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simplespread-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Two sheets with values, a formula, a style and a layout change.
    func sampleDocument() -> SpreadsheetDocument {
        let doc = SpreadsheetDocument()
        doc.commitInput("Name", at: a("A1"))
        doc.commitInput("12.5", at: a("B1"))
        doc.commitInput("=B1*2", at: a("C1"))
        doc.addSheet()
        doc.commitInput("second", at: a("A1"))
        doc.commitInput("=Sheet1!C1+1", at: a("B2"))
        return doc
    }

    /// Run a background save and wait for it.
    func saveInBackground(_ doc: SpreadsheetDocument, to url: URL,
                          meanwhile: () -> Void = {}) async -> String {
        await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
            BackgroundSaver.save(doc, to: url, in: nil) { outcome in
                switch outcome {
                case .saved: done.resume(returning: "saved")
                case .cancelled: done.resume(returning: "cancelled")
                case .failed(let error): done.resume(returning: "failed: \(error)")
                }
            }
            meanwhile()
        }
    }

    // MARK: Snapshot

    @Test func editsAfterTheSnapshotAreNotWritten() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("book.xlsx")
        let doc = sampleDocument()
        let snapshot = doc.makeSaveSnapshot()
        // The user carries on while the snapshot is written.
        doc.commitInput("99", at: a("A1"))
        doc.addSheet()
        try SpreadsheetDocument.write(snapshot, to: url)
        let saved = try SpreadsheetDocument.open(url: url)
        #expect(saved.workbook.sheets.count == 2)
        #expect(saved.workbook.sheets[1].value(at: a("A1")) == .string("second"))
        // The document keeps the edit, and is still modified.
        #expect(doc.workbook.sheets[1].value(at: a("A1")) == .number(99))
        doc.didSave(snapshot, to: url)
        #expect(doc.isModified)
        #expect(doc.fileURL == url)
    }

    @Test func theSavedFileReadsBackEqual() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("book.xlsx")
        let doc = sampleDocument()
        let snapshot = doc.makeSaveSnapshot()
        try SpreadsheetDocument.write(snapshot, to: url)
        let saved = try SpreadsheetDocument.open(url: url)
        #expect(saved.workbook.sheets.map(\.name) == doc.workbook.sheets.map(\.name))
        for (original, reread) in zip(doc.workbook.sheets, saved.workbook.sheets) {
            #expect(original.cells.count == reread.cells.count)
            for (address, cell) in original.cells {
                let other = reread.cell(at: address)
                #expect(other.value == cell.value)
                #expect(other.formula == cell.formula)
                #expect(saved.workbook.style(at: other.styleIndex) == doc.workbook.style(at: cell.styleIndex))
            }
        }
        // The same bytes as writing the live workbook.
        #expect(try Data(contentsOf: url) == XLSXWriter.data(for: doc.workbook))
    }

    @Test func theSnapshotTakesThePendingEdit() throws {
        final class Editor: PendingEditor {
            weak var doc: SpreadsheetDocument?
            var hasPendingEdit: Bool { true }
            func commitPendingEdit() { doc?.commitInput("typed", at: CellAddress(row: 4, column: 0)) }
        }
        let doc = SpreadsheetDocument()
        let editor = Editor()
        editor.doc = doc
        doc.pendingEditor = editor
        let snapshot = doc.makeSaveSnapshot()
        #expect(snapshot.workbook.sheets[0].value(at: a("A5")) == .string("typed"))
        #expect(snapshot.changeCount == doc.changeCount)
    }

    // MARK: Modified flag

    @Test func savingMarksCleanOnlyTheChangeItWrote() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("book.xlsx")
        let doc = sampleDocument()
        #expect(doc.isModified)

        // Nothing changed meanwhile: clean.
        var snapshot = doc.makeSaveSnapshot()
        try SpreadsheetDocument.write(snapshot, to: url)
        doc.didSave(snapshot, to: url)
        #expect(!doc.isModified)

        // Switching sheets during a save is not a change.
        doc.commitInput("1", at: a("D4"))
        snapshot = doc.makeSaveSnapshot()
        doc.selectSheet(withID: doc.workbook.sheets[0].id)
        try SpreadsheetDocument.write(snapshot, to: url)
        doc.didSave(snapshot, to: url)
        #expect(!doc.isModified)

        // An edit during the save is: still modified, and the next save
        // makes it clean.
        doc.commitInput("2", at: a("D4"))
        snapshot = doc.makeSaveSnapshot()
        doc.commitInput("3", at: a("D4"))
        try SpreadsheetDocument.write(snapshot, to: url)
        doc.didSave(snapshot, to: url)
        #expect(doc.isModified)
        try doc.save(to: url)
        #expect(!doc.isModified)
        #expect(try SpreadsheetDocument.open(url: url).activeSheet.value(at: a("D4")) == .number(3))
    }

    // MARK: Cancel and progress

    @Test func cancelLeavesTheOldFile() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("book.xlsx")
        let doc = sampleDocument()
        try doc.save(to: url)
        let before = try Data(contentsOf: url)

        for _ in 0..<500 { doc.commitInput("x", at: a("A\(Int.random(in: 1...20_000))")) }
        // Cancelled before it starts, part-way, and just before the write.
        for stopAfter in [0, 2, Int.max] {
            var calls = 0
            var finished = false
            let snapshot = doc.makeSaveSnapshot()
            #expect(throws: CancellationError.self) {
                try SpreadsheetDocument.write(snapshot, to: url, progress: { finished = $0 == 1 }) {
                    calls += 1
                    return calls <= stopAfter && !finished
                }
            }
            #expect(try Data(contentsOf: url) == before)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["book.xlsx"])
        #expect(doc.isModified)
    }

    @Test func progressIsMonotonicAndReachesOne() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = SpreadsheetDocument()
        for row in 0..<70_000 {
            doc.workbook.sheets[0].setCell(Cell(value: .number(Double(row))), at: CellAddress(row: row, column: 0))
        }
        var reports: [Double] = []
        try SpreadsheetDocument.write(doc.makeSaveSnapshot(), to: dir.appendingPathComponent("p.xlsx"),
                                      progress: { reports.append($0) })
        #expect(reports.count > 3)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(reports.last == 1)
    }

    // MARK: BackgroundSaver

    @Test func backgroundSaveWritesTheSnapshotWhileTheUserEdits() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("book.xlsx")
        let doc = sampleDocument()
        let outcome = await saveInBackground(doc, to: url) {
            #expect(BackgroundSaver.isSaving(doc))
            doc.commitInput("later", at: a("A1"))
        }
        #expect(outcome == "saved")
        #expect(!BackgroundSaver.isSaving(doc))
        #expect(doc.isModified)
        #expect(doc.fileURL == url)
        #expect(try SpreadsheetDocument.open(url: url).workbook.sheets[1].value(at: a("A1")) == .string("second"))
    }

    @Test func aFailedSaveReportsTheError() async throws {
        let doc = sampleDocument()
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/book.xlsx")
        let outcome = await saveInBackground(doc, to: url)
        #expect(outcome.hasPrefix("failed"))
        #expect(doc.isModified)
        #expect(doc.fileURL == nil)
    }

    #if os(macOS) // DocumentSaving.save is the Mac's ⌘S (the iPad autosaves)
    @Test func repeatedSavesWaitTheirTurnAndFoldIntoOne() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("book.xlsx")
        let doc = sampleDocument()
        try doc.save(to: url)
        doc.commitInput("1", at: a("A1"))

        // ⌘S, an edit, then ⌘S twice more while the first save runs.
        var results: [Bool] = []
        var savesSeen = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DocumentSaving.save(doc, in: nil) { results.append($0) }
            #expect(BackgroundSaver.isSaving(doc))
            doc.commitInput("2", at: a("A1"))
            DocumentSaving.save(doc, in: nil) { ok in
                results.append(ok)
                // The follow-up save, from a fresh snapshot.
                savesSeen = BackgroundSaver.isSaving(doc) ? -1 : 2
            }
            DocumentSaving.save(doc, in: nil) { ok in
                results.append(ok)
                done.resume()
            }
        }
        #expect(results == [true, true, true])
        #expect(savesSeen == 2)
        #expect(!doc.isModified)
        #expect(!BackgroundSaver.isSaving(doc))
        #expect(try SpreadsheetDocument.open(url: url).workbook.sheets[1].value(at: a("A1")) == .number(2))
    }
    #endif

    // MARK: CSV

    @Test func csvImportReadsOffTheMainThreadAndAppliesOnIt() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = dir.appendingPathComponent("data.csv")
        try Data("a,b\n1,2\n".utf8).write(to: csv)
        let read = try SpreadsheetDocument.readCSVSheet(from: csv)
        let doc = SpreadsheetDocument()
        doc.importCSVSheet(read)
        #expect(doc.activeSheet.name == "data")
        #expect(doc.activeSheet.value(at: a("B2")) == .number(2))
        #expect(doc.undoManager.canUndo)

        #expect(throws: CancellationError.self) {
            _ = try SpreadsheetDocument.readCSVSheet(from: csv, shouldContinue: { false })
        }
    }

    @Test func csvExportWritesTheSnapshot() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.csv")
        let doc = SpreadsheetDocument()
        doc.commitInput("x", at: a("A1"))
        let snapshot = doc.makeCSVExportSnapshot()
        doc.commitInput("y", at: a("A1"))
        try SpreadsheetDocument.writeCSV(of: snapshot, to: out)
        #expect(CSV.decode(data: try Data(contentsOf: out)) == "x\r\n")

        try Data("old".utf8).write(to: out)
        #expect(throws: CancellationError.self) {
            try SpreadsheetDocument.writeCSV(of: snapshot, to: out, shouldContinue: { false })
        }
        #expect(try Data(contentsOf: out) == Data("old".utf8))
    }
}
