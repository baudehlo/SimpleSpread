#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Insert ▸ PivotTable…'s dialog, in a real window.
@MainActor @Suite struct InsertPivotDialogTests {
    /// The dialog presented over a window showing `doc`: whether it stays.
    func dialogStays(_ doc: SpreadsheetDocument) async throws -> Bool {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DocumentWindowView(document: doc))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        doc.isInsertPivotPresented = true
        try await Task.sleep(for: .milliseconds(1500))
        return window.attachedSheet != nil && doc.isInsertPivotPresented
    }

    /// It closed itself at once on a workbook that already had pivots (its
    /// count of pivots wasn't taken yet, so theirs looked new).
    @Test func theDialogStaysOpenOnAWorkbookWithPivots() async throws {
        let doc = SpreadsheetDocument()
        for (r, row) in [("Region", "Units"), ("East", "10"), ("West", "5")].enumerated() {
            doc.commitInput(row.0, at: CellAddress(row: r, column: 0))
            doc.commitInput(row.1, at: CellAddress(row: r, column: 1))
        }
        doc.selection.select(CellAddress(a1: "A1")!)
        #expect(doc.insertPivotTable(source: CellRange(a1: "A1:B3")!))
        #expect(doc.workbook.pivotTables.count == 1)
        doc.selection.select(CellAddress(a1: "Z100")!)
        #expect(try await dialogStays(doc))
    }
}
#endif
