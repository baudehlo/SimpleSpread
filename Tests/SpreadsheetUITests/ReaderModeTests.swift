import Foundation
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetUI

/// Reader mode, the App Store build after its trial (AppLicense): the
/// document refuses every edit and is never marked as needing a save, but
/// sorting, filtering, finding and copying still work.
@MainActor
@Suite("Reader mode")
struct ReaderModeTests {
    func a(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    /// A small table, saved (not modified), then put in reader mode.
    func readerDocument() -> SpreadsheetDocument {
        let doc = SpreadsheetDocument()
        for (row, values) in [["Fruit", "Qty"], ["Pear", "3"], ["Apple", "7"], ["Fig", "5"]].enumerated() {
            for (column, text) in values.enumerated() {
                doc.commitInput(text, at: CellAddress(row: row, column: column))
            }
        }
        doc.didSave(changeCount: doc.changeCount, to: URL(fileURLWithPath: "/tmp/reader.xlsx"))
        doc.isReadOnly = true
        return doc
    }

    @Test func editsAreRefused() {
        let doc = readerDocument()
        var revision = doc.revision
        func check(_ what: String) {
            #expect(doc.revision == revision, "\(what) changed the document")
            revision = doc.revision
        }
        doc.commitInput("changed", at: a("A2"))
        doc.selection.select(range: CellRange(a1: "A1:B4")!)
        doc.toggleBold()
        check("doc.toggleBold()")
        doc.setNumberFormat(.currency)
        check("doc.setNumberFormat(.currency)")
        doc.applyBorders(.all)
        check("doc.applyBorders(.all)")
        doc.mergeSelection(.merge)
        check("doc.mergeSelection(.merge)")
        doc.clearSelectionContents()
        check("doc.clearSelectionContents()")
        doc.insertRows(at: 1)
        check("doc.insertRows(at: 1)")
        doc.deleteColumns(at: 0)
        check("doc.deleteColumns(at: 0)")
        doc.setColumnWidth(0, width: 200)
        check("doc.setColumnWidth(0, width: 200)")
        doc.hideRows(1...2)
        check("doc.hideRows(1...2)")
        doc.paste(text: "x\ty")
        check("doc.paste(text: \"x\ty\")")
        doc.fill(from: CellRange(a1: "A2")!, to: CellRange(a1: "A2:A9")!)
        doc.addSheet()
        check("doc.addSheet()")
        doc.renameActiveSheet(to: "Renamed")
        check("doc.renameActiveSheet(to: \"Renamed\")")
        doc.autoSum()
        check("doc.autoSum()")
        #expect(doc.insertChart(.column) == false)
        #expect(doc.insertPivotTable(source: CellRange(a1: "A1:B4")!) == false)

        #expect(doc.revision == revision)
        #expect(doc.isModified == false)
        #expect(doc.workbook.sheets.count == 1)
        #expect(doc.activeSheet.name == "Sheet1")
        #expect(doc.displayString(at: a("A2")) == "Pear")
        #expect(doc.style(at: a("A1")).bold == false)
        #expect(doc.activeSheet.mergedRanges.isEmpty)
        #expect(doc.activeCharts.isEmpty)
        #expect(!doc.undoManager.canUndo)
    }

    @Test func sortAndFilterWorkWithoutNeedingASave() {
        let doc = readerDocument()
        doc.selection.select(a("A2"))
        doc.quickSort(ascending: true)
        #expect(doc.displayString(at: a("A2")) == "Apple")
        #expect(doc.displayString(at: a("A4")) == "Pear")

        doc.selection.select(a("A1"))
        doc.toggleAutoFilter()
        doc.setColumnFilter(0, ColumnFilter(values: ["Fig"]))
        #expect(doc.activeAutoFilter != nil)
        #expect(doc.activeSheet.hiddenRows == [1, 3])
        doc.freezePanes(rows: 1, columns: 0)
        #expect(doc.activeSheet.frozenRows == 1)

        #expect(doc.isModified == false)
        // The sort and the filter undo, as ever.
        doc.undoManager.undo()
        doc.undoManager.undo()
        doc.undoManager.undo()
        #expect(doc.displayString(at: a("A2")) == "Pear")
    }

    @Test func copyWorks() {
        let doc = readerDocument()
        doc.selection.select(range: CellRange(a1: "A1:B2")!)
        #expect(doc.selectionTSV() == "Fruit\tQty\nPear\t3")
    }

    @Test func goingReadOnlyDropsEarlierUndo() {
        let doc = SpreadsheetDocument()
        doc.commitInput("1", at: a("A1"))
        #expect(doc.undoManager.canUndo)
        doc.isReadOnly = true
        #expect(!doc.undoManager.canUndo)
    }

    @Test func menusKeepOnlyReaderCommands() {
        let doc = readerDocument()
        func enabled(_ id: String) -> Bool {
            DocumentCommand.all.first { $0.id == id }!.isEnabled(doc)
        }
        #expect(enabled("Data//Sort A to Z"))
        #expect(enabled("Data//Custom Sort…"))
        #expect(enabled("Data//Filter"))
        #expect(enabled("Edit//Find…"))
        #expect(enabled("View//Zoom In"))
        #expect(!enabled("Edit//Fill Down"))
        #expect(!enabled("Format//Bold"))
        #expect(!enabled("Insert//Row Above"))
        #expect(!enabled("Insert//New Sheet"))
        #expect(!enabled("Data//Refresh All"))
        doc.isReadOnly = false
        #expect(enabled("Format//Bold"))
    }

    @Test func saveIsRefused() async throws {
        let doc = readerDocument()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString).xlsx")
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<SaveOutcome, Never>) in
            BackgroundSaver.save(doc, to: url, in: nil) { done.resume(returning: $0) }
        }
        guard case .cancelled = outcome else {
            Issue.record("expected the save to be refused, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func paidAppCustomersAreRecognised() {
        let after = AppLicense.freeSince.addingTimeInterval(86_400)
        func paid(_ version: String, _ date: Date = after) -> Bool {
            AppLicense.boughtWhenPaid(originalAppVersion: version, originalPurchaseDate: date)
        }
        // Mac: CFBundleShortVersionString.
        #expect(paid("2.0.4"))
        #expect(paid("2.3.0"))
        #expect(paid("2.3"))
        #expect(!paid("2.4.0"))
        #expect(!paid("2.4"))
        #expect(!paid("2.10.0"))
        #expect(!paid("3.0"))
        // iPad: the build number.
        #expect(paid("1"))
        #expect(paid("4"))
        #expect(!paid("5"))
        #expect(!paid("12"))
        // Unreadable: not counted, unless the date says so.
        #expect(!paid(""))
        #expect(!paid("beta"))
        #expect(paid("beta", AppLicense.freeSince.addingTimeInterval(-60)))
    }

    @Test func trialDaysCountToday() {
        let now = Date()
        #expect(AppLicense.daysLeft(until: now.addingTimeInterval(14 * 86_400), now: now) == 14)
        #expect(AppLicense.daysLeft(until: now.addingTimeInterval(3600), now: now) == 1)
        #expect(AppLicense.daysLeft(until: now.addingTimeInterval(-60), now: now) == 0)
    }

    /// The Mac tests run the open source build; the iPad build always has
    /// the store code, which allows editing until the App Store says otherwise.
    @Test func editingIsAllowedByDefault() {
        #if os(macOS)
        #expect(AppLicense.shared.status == .openSource)
        #endif
        #expect(AppLicense.shared.allowsEditing)
        #expect(SpreadsheetDocument().isReadOnly == false)
    }
}
