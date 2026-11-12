import Foundation
import Testing
import SpreadsheetCore
@testable import SpreadsheetUI

/// Opening a file closes the Untitled window the app opened on its own,
/// but only while nobody has used it.
@MainActor
@Suite("Placeholder Untitled window")
struct PlaceholderWindowTests {
    @Test func onlyAnUntouchedAutomaticUntitledIsReplaced() {
        let store = DocumentStore()
        let placeholder = store.document(for: store.createPlaceholder())
        let fromNew = store.document(for: store.create())

        #expect(store.isUntouchedPlaceholder(placeholder))
        // File ▸ New was asked for: it stays.
        #expect(!store.isUntouchedPlaceholder(fromNew))

        placeholder.isReadOnly = false
        placeholder.commitInput("5", at: CellAddress(a1: "A1")!)
        #expect(!store.isUntouchedPlaceholder(placeholder))
    }

    @Test func aPlaceholderSavedToAFileIsNoLongerOne() {
        let store = DocumentStore()
        let placeholder = store.document(for: store.createPlaceholder())
        placeholder.fileURL = URL(fileURLWithPath: "/tmp/Budget.xlsx")
        #expect(!store.isUntouchedPlaceholder(placeholder))
    }
}
