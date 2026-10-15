import Foundation
import SpreadsheetCore

/// Borders, merged cells, frozen panes, hidden rows, sorting and the
/// AutoFilter: commands that change cells and sheet layout together.
extension SpreadsheetDocument {
    // MARK: - Layout undo

    /// Register an undo step that reverts `change` (what a command did to a
    /// sheet's merges, hidden rows, row heights, filter or panes) and
    /// nothing else, so later changes without undo steps of their own
    /// survive it.
    func registerLayoutUndo(_ change: SheetLayoutChange, sheetID: Int, actionName: String) {
        guard !change.isEmpty else { return }
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    guard let sheet = doc.workbook.sheet(withID: sheetID) else { return }
                    let undo = change.inverse
                    undo.apply(to: sheet)
                    doc.registerLayoutUndo(undo, sheetID: sheetID, actionName: actionName)
                    doc.markChanged()
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Run `body`, which may change cells in `cells` and the active sheet's
    /// layout, as one undo step.
    func changeCellsAndLayout(_ actionName: String, cells addresses: [CellAddress],
                              _ body: () -> Void) {
        let sheet = activeSheet
        let oldLayout = sheet.layoutState
        let snaps = snapshot(addresses)
        body()
        withUndoGroup {
            if !snaps.isEmpty { registerCellUndo(snaps, actionName: actionName) }
            registerLayoutUndo(SheetLayoutChange(from: oldLayout, to: sheet.layoutState),
                               sheetID: sheet.id, actionName: actionName)
        }
        markChanged()
    }

    // MARK: - Borders

    public enum BorderPreset: String, CaseIterable, Sendable {
        case bottom, top, left, right
        case none, all, outside, thickOutside, inside
        case topAndBottom, thickBottom, doubleBottom
    }

    /// Excel's border menu. Presets that draw an outline act on the
    /// selection's edges; `all` and `inside` also draw between cells.
    public func applyBorders(_ preset: BorderPreset, color: RGBAColor? = nil) {
        let range = selection.range
        let thin = BorderLine(.thin, color: color)
        let medium = BorderLine(.medium, color: color)
        applyStyleToSelectionAt("Borders") { address, style in
            let top = address.row == range.start.row
            let bottom = address.row == range.end.row
            let left = address.column == range.start.column
            let right = address.column == range.end.column
            var b = style.borders
            switch preset {
            case .bottom: if bottom { b.bottom = thin }
            case .top: if top { b.top = thin }
            case .left: if left { b.left = thin }
            case .right: if right { b.right = thin }
            case .none: b = CellBorders()
            case .all: b = CellBorders(top: thin, bottom: thin, left: thin, right: thin)
            case .outside, .thickOutside:
                let line = preset == .outside ? thin : medium
                if top { b.top = line }
                if bottom { b.bottom = line }
                if left { b.left = line }
                if right { b.right = line }
            case .inside:
                if !bottom { b.bottom = thin }
                if !top { b.top = thin }
                if !right { b.right = thin }
                if !left { b.left = thin }
            case .topAndBottom:
                if top { b.top = thin }
                if bottom { b.bottom = thin }
            case .thickBottom: if bottom { b.bottom = medium }
            case .doubleBottom: if bottom { b.bottom = BorderLine(.double, color: color) }
            }
            style.borders = b
        }
    }

    /// Like applyStyleToSelection, but the mutation sees each address.
    func applyStyleToSelectionAt(_ actionName: String, _ mutate: (CellAddress, inout CellStyle) -> Void) {
        let range = selection.range
        guard !refuseIfPivot(range) else { return }
        applyStyle(to: range, actionName: actionName, addressDependent: true, mutate)
    }

    // MARK: - Merged cells

    public enum MergeKind: Sendable {
        /// One merged cell, contents centred (Excel's default button).
        case mergeAndCenter
        /// One merged cell per selected row.
        case mergeAcross
        case merge
    }

    /// True when the selection touches a merged range.
    public var selectionHasMerge: Bool {
        activeSheet.mergedRanges.contains { $0.intersects(selection.range) }
    }

    /// Merge the selection. Like Excel, only the upper-left value of each
    /// merged range survives, after a confirmation when others would go.
    public func mergeSelection(_ kind: MergeKind) {
        let range = selection.range
        guard !range.isSingleCell, !refuseIfPivot(range) else { return }
        let sheet = activeSheet
        let targets: [CellRange]
        if kind == .mergeAcross {
            targets = (range.start.row...range.end.row).map {
                CellRange(start: CellAddress(row: $0, column: range.start.column),
                          end: CellAddress(row: $0, column: range.end.column))
            }.filter { !$0.isSingleCell }
        } else {
            targets = [range]
        }
        guard !targets.isEmpty else { return }
        // Values other than each merge's upper-left one go. Merge Across
        // keeps the first column of each row; the others keep range.start.
        let discarded = storedAddresses(in: range, sheet: sheet).filter { address in
            let keeps = kind == .mergeAcross ? address.column == range.start.column : address == range.start
            return !keeps && !sheet.value(at: address).isEmpty
        }.sorted()
        if !discarded.isEmpty {
            guard confirm?("Merging cells only keeps the upper-left value and discards other values.",
                           "", "Merge") == true else { return }
        }
        withUndoGroup {
            var centred: [StyleSnapshot] = []
            changeCellsAndLayout("Merge Cells", cells: discarded) {
                sheet.mergedRanges.removeAll { $0.intersects(range) }
                sheet.mergedRanges.append(contentsOf: targets)
                for address in discarded {
                    _ = engine.clearCell(at: AbsoluteAddress(sheetID: sheet.id, address: address))
                }
                if kind == .mergeAndCenter {
                    centred = restyle(range, addressDependent: false) { _, style in
                        style.horizontalAlignment = .center
                    }
                }
            }
            registerStyleUndo(centred, sheetID: sheet.id, actionName: "Merge Cells")
        }
        selection.select(range: range, active: range.start)
    }

    public func unmergeSelection() {
        let range = selection.range
        let sheet = activeSheet
        guard sheet.mergedRanges.contains(where: { $0.intersects(range) }) else { return }
        changeCellsAndLayout("Unmerge Cells", cells: []) {
            sheet.mergedRanges.removeAll { $0.intersects(range) }
        }
    }

    /// The toolbar's merge button: merge (and centre) or, on a merged
    /// selection, unmerge.
    public func toggleMergeAndCenter() {
        if selectionHasMerge {
            unmergeSelection()
        } else {
            mergeSelection(.mergeAndCenter)
        }
    }

    // MARK: - Frozen panes

    /// Freeze the rows above and the columns left of a cell. Like Excel,
    /// panes are a view setting and do not go on the undo stack.
    public func freezePanes(rows: Int, columns: Int) {
        let sheet = activeSheet
        guard sheet.frozenRows != rows || sheet.frozenColumns != columns else { return }
        sheet.frozenRows = max(0, rows)
        sheet.frozenColumns = max(0, columns)
        markChanged()
    }

    /// Freeze Panes at the active cell; from A1 there is nothing to freeze.
    public func freezePanesAtSelection() {
        let cell = selection.activeCell
        freezePanes(rows: cell.row, columns: cell.column)
    }

    public var hasFrozenPanes: Bool {
        activeSheet.frozenRows > 0 || activeSheet.frozenColumns > 0
    }

    // MARK: - Hidden rows

    public func hideRows(_ rows: ClosedRange<Int>) {
        changeCellsAndLayout(rows.count == 1 ? "Hide Row" : "Hide Rows", cells: []) {
            activeSheet.hiddenRows.formUnion(rows)
        }
    }

    public func unhideRows(_ rows: ClosedRange<Int>) {
        guard activeSheet.hiddenRows.contains(where: rows.contains) else { return }
        changeCellsAndLayout("Unhide Rows", cells: []) {
            activeSheet.hiddenRows.subtract(rows)
        }
    }

    // MARK: - Hidden columns

    public func hideColumns(_ columns: ClosedRange<Int>) {
        changeCellsAndLayout(columns.count == 1 ? "Hide Column" : "Hide Columns", cells: []) {
            activeSheet.hiddenColumns.formUnion(columns)
        }
    }

    public func unhideColumns(_ columns: ClosedRange<Int>) {
        guard activeSheet.hiddenColumns.contains(where: columns.contains) else { return }
        changeCellsAndLayout("Unhide Columns", cells: []) {
            activeSheet.hiddenColumns.subtract(columns)
        }
    }

    // MARK: - Sorting

    /// What a sort with no dialog acts on: the filter's rows when the cursor
    /// is in the filter, the selection when it is a range, otherwise the
    /// block of data around the cursor. Nil when there is nothing to sort.
    public func sortTarget() -> (range: CellRange, hasHeader: Bool)? {
        let sheet = activeSheet
        let active = selection.activeCell
        if let filter = sheet.autoFilter, filter.range.contains(active) {
            // Sorting a filter covers rows typed under it too.
            var range = filter.range
            range.end.row = Workbook.extendedFilterEnd(filter.range, in: sheet)
            return (range, true)
        }
        let range = selection.range.isSingleCell ? sheet.currentRegion(around: active) : selection.range
        guard range.rowCount > 1 || !sheet.value(at: range.start).isEmpty else { return nil }
        return (range, WorkbookOperations.guessHasHeader(range, in: sheet, workbook: workbook))
    }

    /// Sort A→Z / Z→A by the active cell's column (toolbar, Data menu).
    public func quickSort(ascending: Bool) {
        guard let target = sortTarget() else { return }
        sort(range: target.range, keys: [SortKey(column: selection.activeCell.column, ascending: ascending)],
             hasHeader: target.hasHeader)
    }

    /// Sort the rows of `range` (below its header row when `hasHeader`).
    public func sort(range: CellRange, keys: [SortKey], hasHeader: Bool) {
        var body = range
        if hasHeader { body.start.row += 1 }
        guard body.start.row <= body.end.row, !keys.isEmpty else { return }
        guard !refuseIfPivot(body) else { return }
        let sheet = activeSheet
        if sheet.mergedRanges.contains(where: { $0.intersects(body) }) {
            notice = DocumentNotice(message: "Merged cells can’t be sorted.",
                                    detail: "Unmerge the cells in the range, then sort again.")
            return
        }
        // Rows past the data are blank and blanks sort last, so a whole-column
        // sort only needs to order the rows down to the last stored one.
        var sorted = body
        sorted.end.row = min(body.end.row, max(body.start.row, sheet.usedRange?.end.row ?? body.start.row))
        let moves = WorkbookOperations.sortedCells(of: sorted, in: sheet, keys: keys)
        // Only the cells that move change, so only they need snapshots.
        changeCellsAndLayout("Sort", cells: moves.map(\.0)) {
            guard !moves.isEmpty else { return }
            let snaps = moves.map { CellSnapshot(sheetID: sheet.id, address: $0.0, cell: $0.1) }
            restore(snaps)
            if sheet.autoFilter.map({ $0.range.intersects(body) }) == true {
                workbook.applyAutoFilter(onSheetID: sheet.id)
            }
        }
        selection.select(range: body, active: CellAddress(row: body.start.row, column: selection.activeCell.column))
    }

    // MARK: - AutoFilter

    public var activeAutoFilter: AutoFilter? { activeSheet.autoFilter }

    /// Rows of `range` the AutoFilter hides. Copy and Delete skip these, as
    /// in Excel; rows hidden by hand are not filtered and still count.
    func filteredOutRows(in range: CellRange) -> Set<Int> {
        let sheet = activeSheet
        guard let rows = sheet.autoFilter?.dataRows, !sheet.hiddenRows.isEmpty else { return [] }
        return sheet.hiddenRows.filter { rows.contains($0) && range.start.row...range.end.row ~= $0 }
    }

    /// Data ▸ Filter: add filter buttons over the selection (or the data
    /// around the cursor), or remove the filter and show its rows again.
    public func toggleAutoFilter() {
        let sheet = activeSheet
        if let filter = sheet.autoFilter {
            changeCellsAndLayout("Remove Filter", cells: []) {
                if let rows = filter.dataRows { sheet.hiddenRows.subtract(rows) }
                sheet.autoFilter = nil
            }
            return
        }
        let range = selection.range.isSingleCell
            ? sheet.currentRegion(around: selection.activeCell) : selection.range
        guard !(range.isSingleCell && sheet.value(at: range.start).isEmpty) else {
            notice = DocumentNotice(message: "Select a cell in your data first.",
                                    detail: "The filter goes on the block of data around the selected cell.")
            return
        }
        guard !refuseIfPivot(range) else { return }
        changeCellsAndLayout("Filter", cells: []) {
            sheet.autoFilter = AutoFilter(range: range)
            workbook.applyAutoFilter(onSheetID: sheet.id)
        }
    }

    /// Set (or with nil, clear) one filter column's criteria and re-filter.
    public func setColumnFilter(_ columnOffset: Int, _ criteria: ColumnFilter?) {
        let sheet = activeSheet
        guard sheet.autoFilter != nil else { return }
        changeCellsAndLayout(criteria == nil ? "Clear Filter" : "Filter", cells: []) {
            sheet.autoFilter?.columns[columnOffset] = (criteria?.isActive == true) ? criteria : nil
            workbook.applyAutoFilter(onSheetID: sheet.id)
        }
    }

    public func clearAllFilters() {
        let sheet = activeSheet
        guard let filter = sheet.autoFilter, !filter.columns.isEmpty else { return }
        changeCellsAndLayout("Clear Filters", cells: []) {
            sheet.autoFilter?.columns = [:]
            workbook.applyAutoFilter(onSheetID: sheet.id)
        }
    }

    /// Data ▸ Reapply: run the filter again after the data changed.
    public func reapplyAutoFilter() {
        let sheet = activeSheet
        guard sheet.autoFilter != nil else { return }
        changeCellsAndLayout("Reapply Filter", cells: []) {
            workbook.applyAutoFilter(onSheetID: sheet.id)
        }
    }
}
