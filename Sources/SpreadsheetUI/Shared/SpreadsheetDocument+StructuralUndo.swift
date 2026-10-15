import Foundation
import SpreadsheetCore

/// Undo for inserting and deleting rows and columns, without a copy of the
/// sheet. A snapshot (WorkbookSnapshot) would keep the old cell table of
/// the edited sheet alive for as long as the step is on the undo stack:
/// ~1 GB for one insert on a full 1,048,576 x 10 sheet. Instead the step
/// keeps the edit's `StructuralEditResult`, which records only what the
/// opposite edit can't work out for itself (see `StructuralEditResult.undo`).
///
/// Neither the edit nor its undo rebuilds the calculation engine: it moves
/// its entries in place and recalculates only what the edit can change
/// (`CalculationEngine.apply`).
extension SpreadsheetDocument {
    /// One undo step: the edit, and the active sheet and selection to go
    /// back to. Unchecked Sendable: used only on the main actor, inside
    /// undo handlers.
    struct StructuralUndoRecord: @unchecked Sendable {
        let edit: StructuralEditResult
        let activeSheetID: Int
        let selection: SelectionState
    }

    /// Run a structural edit as one undo step.
    func performStructuralEdit(_ change: StructuralChange) {
        let activeBefore = activeSheetID
        let selectionBefore = selection
        guard let edit = WorkbookOperations.apply(change, to: workbook) else { return }
        engine.apply(edit)
        let record = StructuralUndoRecord(edit: edit, activeSheetID: activeBefore, selection: selectionBefore)
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated { doc.undoStructuralEdit(record) }
            }
            undoManager.setActionName(change.actionName)
        }
        markChanged()
    }

    private func undoStructuralEdit(_ record: StructuralUndoRecord) {
        // Selection and active sheet as the redo will want them.
        let activeAfter = activeSheetID
        let selectionAfter = selection
        let change = record.edit.change
        guard let undone = record.edit.undo(in: workbook) else { return }
        engine.apply(undone)
        activeSheetID = workbook.sheet(withID: record.activeSheetID)?.id ?? workbook.sheets[0].id
        selection = record.selection

        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    // Redo: the edit again (it records its own undo).
                    doc.performStructuralEdit(change)
                    doc.activeSheetID = doc.workbook.sheet(withID: activeAfter)?.id ?? doc.activeSheetID
                    doc.selection = selectionAfter
                }
            }
            undoManager.setActionName(change.actionName)
        }
        markChanged()
    }
}

extension StructuralChange {
    var actionName: String {
        "\(isInsert ? "Insert" : "Delete") \(axisIsRow ? "Rows" : "Columns")"
    }
}
