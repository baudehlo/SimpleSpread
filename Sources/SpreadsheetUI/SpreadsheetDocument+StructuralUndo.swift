import Foundation
import SpreadsheetCore

/// Undo for inserting and deleting rows and columns, without a copy of the
/// sheet. A snapshot (WorkbookSnapshot) would keep the old cell table of
/// the edited sheet alive for as long as the step is on the undo stack:
/// ~1 GB for one insert on a full 1,048,576 x 10 sheet. Instead the step
/// records only what the opposite edit can't work out for itself:
///
/// - the cells a delete removed;
/// - the original text of every formula the edit rewrote (the opposite
///   edit would get most of them back, but not their exact spelling, and
///   not references a delete turned into #REF!). A formula the edit left
///   alone, the opposite edit leaves alone too;
/// - the small per-sheet layout tables, defined names and pivot
///   definitions, which are shared copy-on-write until they change.
///
/// Undo runs the opposite edit, then puts those back; redo runs the edit
/// again. Either way the engine is rebuilt once.
extension SpreadsheetDocument {
    struct StructuralEdit: Sendable {
        let sheetID: Int
        let axisIsRow: Bool
        let index: Int
        let count: Int
        let isInsert: Bool

        var actionName: String {
            "\(isInsert ? "Insert" : "Delete") \(axisIsRow ? "Rows" : "Columns")"
        }

        func run(on workbook: Workbook) {
            switch (axisIsRow, isInsert) {
            case (true, true): WorkbookOperations.insertRows(in: workbook, sheetID: sheetID, at: index, count: count)
            case (true, false): WorkbookOperations.deleteRows(in: workbook, sheetID: sheetID, at: index, count: count)
            case (false, true): WorkbookOperations.insertColumns(in: workbook, sheetID: sheetID, at: index, count: count)
            case (false, false): WorkbookOperations.deleteColumns(in: workbook, sheetID: sheetID, at: index, count: count)
            }
        }

        /// The opposite edit (same rows or columns).
        var inverse: StructuralEdit {
            StructuralEdit(sheetID: sheetID, axisIsRow: axisIsRow, index: index, count: count, isInsert: !isInsert)
        }

        /// Where a cell now at `address` on the edited sheet was before the
        /// edit (nil for a cell in inserted rows or columns).
        func addressBefore(_ address: CellAddress) -> CellAddress? {
            let pos = axisIsRow ? address.row : address.column
            var old = pos
            if isInsert {
                if pos >= index + count { old = pos - count } else if pos >= index { return nil }
            } else if pos >= index {
                old = pos + count
            }
            return axisIsRow ? CellAddress(row: old, column: address.column)
                             : CellAddress(row: address.row, column: old)
        }

        func isRemoved(_ address: CellAddress) -> Bool {
            guard !isInsert else { return false }
            let pos = axisIsRow ? address.row : address.column
            return pos >= index && pos < index + count
        }
    }

    /// What undoing one structural edit needs (see the extension comment).
    /// Unchecked Sendable: used only on the main actor, inside undo handlers.
    struct StructuralUndoRecord: @unchecked Sendable {
        let edit: StructuralEdit
        /// Cells the edit removed, at their addresses before it.
        let removedCells: [CellAddress: Cell]
        /// Original text of the formulas the edit rewrote, by sheet id and
        /// address before the edit.
        let rewrittenFormulas: [AbsoluteAddress: String]
        let layout: SheetLayoutState
        let columnWidths: [Int: CGFloat]
        let definedNames: [DefinedName]
        let pivotCaches: [PivotCache]
        let pivotTables: [PivotTable]
        let activeSheetID: Int
        let selection: SelectionState
    }

    /// Run a structural edit on the active sheet as one undo step.
    func performStructuralEdit(_ edit: StructuralEdit) {
        guard let sheet = workbook.sheet(withID: edit.sheetID) else { return }
        // Before: formula texts everywhere (Strings are shared, not copied),
        // the cells a delete will remove, and the small tables.
        var formulasBefore: [AbsoluteAddress: String] = [:]
        for s in workbook.sheets {
            for (address, cell) in s.cells {
                if let formula = cell.formula { formulasBefore[AbsoluteAddress(sheetID: s.id, address: address)] = formula }
            }
        }
        var removed: [CellAddress: Cell] = [:]
        if !edit.isInsert {
            for (address, cell) in sheet.cells where edit.isRemoved(address) { removed[address] = cell }
        }
        let layout = sheet.layoutState
        let columnWidths = sheet.columnWidths
        let names = workbook.definedNames
        let caches = workbook.pivotCaches
        let tables = workbook.pivotTables
        let activeBefore = activeSheetID
        let selectionBefore = selection

        edit.run(on: workbook)
        engine.rebuildAll()

        // After: keep the original text of each formula the edit changed.
        var rewritten: [AbsoluteAddress: String] = [:]
        for s in workbook.sheets {
            for (address, cell) in s.cells {
                guard let formula = cell.formula else { continue }
                let before = s.id == edit.sheetID ? edit.addressBefore(address) : address
                guard let before else { continue }
                let key = AbsoluteAddress(sheetID: s.id, address: before)
                if let old = formulasBefore[key], old != formula { rewritten[key] = old }
            }
        }

        let record = StructuralUndoRecord(
            edit: edit, removedCells: removed, rewrittenFormulas: rewritten,
            layout: layout, columnWidths: columnWidths, definedNames: names,
            pivotCaches: caches, pivotTables: tables,
            activeSheetID: activeBefore, selection: selectionBefore)
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated { doc.undoStructuralEdit(record) }
            }
            undoManager.setActionName(edit.actionName)
        }
        markChanged()
    }

    private func undoStructuralEdit(_ record: StructuralUndoRecord) {
        let edit = record.edit
        guard let sheet = workbook.sheet(withID: edit.sheetID) else { return }
        // Selection and active sheet as the redo will want them.
        let activeAfter = activeSheetID
        let selectionAfter = selection

        edit.inverse.run(on: workbook)
        for (address, cell) in record.removedCells { sheet.setCell(cell, at: address) }
        for (key, text) in record.rewrittenFormulas {
            guard let s = workbook.sheet(withID: key.sheetID) else { continue }
            var cell = s.cell(at: key.address)
            cell.formula = text
            s.setCell(cell, at: key.address)
        }
        // Frozen panes are a view setting (not undone, as in Excel).
        var layout = record.layout
        layout.frozenRows = sheet.frozenRows
        layout.frozenColumns = sheet.frozenColumns
        sheet.layoutState = layout
        sheet.columnWidths = record.columnWidths
        workbook.definedNames = record.definedNames
        workbook.pivotCaches = record.pivotCaches
        workbook.pivotTables = record.pivotTables
        engine.rebuildAll()
        activeSheetID = workbook.sheet(withID: record.activeSheetID)?.id ?? workbook.sheets[0].id
        selection = record.selection

        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    // Redo: the edit again (it records its own undo).
                    doc.performStructuralEdit(edit)
                    doc.activeSheetID = doc.workbook.sheet(withID: activeAfter)?.id ?? doc.activeSheetID
                    doc.selection = selectionAfter
                }
            }
            undoManager.setActionName(edit.actionName)
        }
        markChanged()
    }
}
