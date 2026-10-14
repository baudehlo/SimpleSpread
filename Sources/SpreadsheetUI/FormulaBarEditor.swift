import Foundation
import SpreadsheetCore

/// The formula bar's text and its pending edit. Typing in the bar is for the
/// cell that was active at the first keystroke; it is committed there when
/// the user presses Return, clicks away (as Excel does), or when the
/// document commits pending edits before a command, a sheet switch or a save.
@MainActor
final class FormulaBarEditor: ObservableObject, PendingEditor {
    weak var document: SpreadsheetDocument?
    @Published private(set) var text = ""
    /// The sheet and cell the typing is for; nil until the user types.
    private var target: (sheetID: Int, address: CellAddress)?

    var hasPendingEdit: Bool { target != nil }

    /// Show the active cell's contents, unless the user is typing.
    func sync() {
        guard target == nil, let document else { return }
        let current = document.editString(at: document.selection.activeCell)
        if text != current { text = current }
    }

    /// A keystroke in the bar. The first one fixes the target cell.
    func userEdited(_ newText: String) {
        if target == nil, let document {
            document.commitPendingEdit() // e.g. an open in-cell editor
            target = (document.activeSheetID, document.selection.activeCell)
            document.pendingEditor = self
        }
        text = newText
    }

    /// Focus left the bar (the user clicked the grid or another control).
    func endEditing() {
        commitPendingEdit()
    }

    /// Escape: drop the typing and show the cell again.
    func cancel() {
        target = nil
        if document?.pendingEditor === self { document?.pendingEditor = nil }
        sync()
    }

    func commitPendingEdit() {
        guard let target else { return }
        self.target = nil
        guard let document else { return }
        if document.pendingEditor === self { document.pendingEditor = nil }
        document.commitInput(text, at: target.address, sheetID: target.sheetID)
        sync()
    }
}
