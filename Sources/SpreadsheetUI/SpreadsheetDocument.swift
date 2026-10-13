import Foundation
import SpreadsheetCore
import SpreadsheetFiles

/// Cells carried on the internal clipboard (with formulas + styles).
public struct ClipboardPayload: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var rowOffset: Int
        public var columnOffset: Int
        public var cell: Cell
        public var style: CellStyle
    }
    public var rows: Int
    public var columns: Int
    public var entries: [Entry]
    /// True if the source was a cut (paste moves rather than copies).
    public var isCut: Bool

    public static let pasteboardType = "com.kikiplan.simplespread.cells"
}

/// A message the window shows as an alert (e.g. an edit that was refused).
public struct DocumentNotice: Identifiable, Equatable {
    public let id = UUID()
    public var message: String
    public var detail: String
}

/// The document view-model: owns the workbook, the calculation engine,
/// selection, undo, dirty tracking, clipboard, and file I/O.
/// All operations route through here so they are undoable and recalculated.
@MainActor
public final class SpreadsheetDocument: ObservableObject {
    public private(set) var workbook: Workbook
    let engine: CalculationEngine
    public let undoManager = UndoManager()

    @Published public var selection = SelectionState()
    @Published public var activeSheetID: Int
    /// The XLSX file this document saves to. Nil until first saved — including
    /// for documents opened from CSV, which must Save-As to XLSX rather than
    /// overwrite the source.
    @Published public var fileURL: URL?
    /// Pre-filled name for the Save panel when there is no fileURL yet
    /// (e.g. "pricing.xlsx" after opening pricing.csv).
    @Published public var suggestedFileName: String?
    @Published public private(set) var isModified = false
    /// Incremented whenever cell content/layout changes; grid views observe it.
    @Published public private(set) var revision = 0
    /// View zoom (1.0 = 100%). Applied as NSScrollView magnification.
    @Published public var zoomLevel: CGFloat = 1.0
    /// An alert for the window to show; the window clears it on dismissal.
    @Published public var notice: DocumentNotice?
    /// Show the PivotTable Fields panel when the active cell is in a pivot.
    @Published public var isPivotPanelVisible = true
    /// Insert ▸ PivotTable… sheet.
    @Published public var isInsertPivotPresented = false
    /// Data ▸ Custom Sort… sheet.
    @Published public var isSortPresented = false
    /// Asks the user to confirm (message, detail, button title); nil
    /// refuses. The app installs an alert; tests install a closure.
    public var confirm: ((String, String, String) -> Bool)?
    /// Pivot cell roles of one sheet at one revision (for drawing).
    var pivotRoleCache: (revision: Int, sheetID: Int, roles: [CellAddress: PivotCellRole])?

    public static let zoomRange: ClosedRange<CGFloat> = 0.25...4.0
    public static let zoomPresets: [CGFloat] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

    public init(workbook: Workbook? = nil) {
        let wb = workbook ?? Workbook.newDocument()
        self.workbook = wb
        self.engine = CalculationEngine(workbook: wb)
        self.activeSheetID = wb.sheets[0].id
        // Each operation forms its own undo group (see withUndoGroup) rather
        // than one group per run-loop turn.
        undoManager.groupsByEvent = false
    }

    public var activeSheet: Sheet {
        workbook.sheet(withID: activeSheetID) ?? workbook.sheets[0]
    }

    public var displayName: String {
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        if let suggestedFileName {
            return (suggestedFileName as NSString).deletingPathExtension
        }
        return "Untitled"
    }

    /// The default filename to offer in a Save panel.
    public var saveFileName: String {
        if let fileURL { return fileURL.lastPathComponent }
        if let suggestedFileName { return suggestedFileName }
        return "Untitled.xlsx"
    }

    /// File extensions treated as delimited-text imports (sniffed on load).
    public static let textImportExtensions: Set<String> = ["csv", "tsv", "txt", "tab"]

    // MARK: - Display / edit strings

    /// What the grid shows for a cell.
    public func displayString(at address: CellAddress) -> String {
        let cell = activeSheet.cell(at: address)
        let style = workbook.style(at: cell.styleIndex)
        return NumberFormatEngine.displayString(for: cell.value, format: style.numberFormat)
    }

    /// What the formula bar / in-place editor shows: the formula with '=',
    /// or a re-parseable value representation.
    public func editString(at address: CellAddress) -> String {
        let cell = activeSheet.cell(at: address)
        if let formula = cell.formula {
            return "=" + formula
        }
        let style = workbook.style(at: cell.styleIndex)
        switch cell.value {
        case .empty:
            return ""
        case .number:
            // Dates/times/percents edit in their formatted form so the commit
            // round-trips through the same parser.
            let code = style.numberFormat
            if code.isDateTime || code.code.contains("%") {
                return NumberFormatEngine.displayString(for: cell.value, format: code)
            }
            return cell.value.rawDisplayString
        case .string(let s):
            // Escape strings that would re-parse as something else.
            let reparsed = ValueParser.parse(s)
            if reparsed.value != .string(s) || s.hasPrefix("'") || s.hasPrefix("=") {
                return "'" + s
            }
            return s
        default:
            return cell.value.rawDisplayString
        }
    }

    public func style(at address: CellAddress) -> CellStyle {
        workbook.style(at: activeSheet.cell(at: address).styleIndex)
    }

    // MARK: - Change plumbing

    func markChanged() {
        isModified = true
        revision += 1
    }

    struct CellSnapshot {
        let sheetID: Int
        let address: CellAddress
        let cell: Cell
    }

    func snapshot(_ addresses: [CellAddress], sheetID: Int? = nil) -> [CellSnapshot] {
        let id = sheetID ?? activeSheetID
        guard let sheet = workbook.sheet(withID: id) else { return [] }
        return addresses.map { CellSnapshot(sheetID: id, address: $0, cell: sheet.cell(at: $0)) }
    }

    /// Wrap a registration in its own undo group so each operation is one
    /// undo step even when several happen in one run-loop turn (tests, macros).
    func withUndoGroup(_ body: () -> Void) {
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        body()
        if grouping { undoManager.endUndoGrouping() }
    }

    func registerCellUndo(_ snapshots: [CellSnapshot], actionName: String) {
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    let redoSnapshots = snapshots.map {
                        CellSnapshot(sheetID: $0.sheetID, address: $0.address,
                                     cell: doc.workbook.sheet(withID: $0.sheetID)?.cell(at: $0.address) ?? Cell())
                    }
                    doc.registerCellUndo(redoSnapshots, actionName: actionName)
                    doc.restore(snapshots)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    func restore(_ snapshots: [CellSnapshot]) {
        var entries: [(AbsoluteAddress, CellValue, String?)] = []
        for snap in snapshots {
            guard let sheet = workbook.sheet(withID: snap.sheetID) else { continue }
            var cell = snap.cell
            // engine.setCells handles value/formula; style set directly.
            var existing = sheet.cell(at: snap.address)
            existing.styleIndex = cell.styleIndex
            sheet.setCell(existing, at: snap.address)
            cell.styleIndex = snap.cell.styleIndex
            entries.append((AbsoluteAddress(sheetID: snap.sheetID, address: snap.address),
                            snap.cell.value, snap.cell.formula))
        }
        engine.setCells(entries)
        // Re-apply styles (setCells writes value/formula only).
        for snap in snapshots {
            guard let sheet = workbook.sheet(withID: snap.sheetID) else { continue }
            var cell = sheet.cell(at: snap.address)
            cell.styleIndex = snap.cell.styleIndex
            sheet.setCell(cell, at: snap.address)
        }
        markChanged()
    }

    /// Whole-workbook snapshot for structural ops (uses the XLSX round-trip,
    /// which is fully covered by tests).
    func registerWorkbookUndo(actionName: String) {
        guard let data = try? XLSXWriter.data(for: workbook) else { return }
        let sheetIndex = workbook.indexOfSheet(withID: activeSheetID) ?? 0
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    doc.registerWorkbookUndo(actionName: actionName)
                    doc.restoreWorkbook(from: data, activeSheetIndex: sheetIndex)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    private func restoreWorkbook(from data: Data, activeSheetIndex: Int) {
        guard let restored = try? XLSXReader.read(data: data) else { return }
        replaceWorkbookContents(with: restored)
        let idx = min(activeSheetIndex, workbook.sheets.count - 1)
        activeSheetID = workbook.sheets[idx].id
        selection = SelectionState()
        markChanged()
    }

    /// Move sheets/styles/pivots from another workbook instance into ours in
    /// place. Sheet ids are kept (the writer stores them as sheetId), so cell
    /// undo records registered before the snapshot still find their sheets.
    private func replaceWorkbookContents(with other: Workbook) {
        workbook.replaceContents(with: other)
        engine.rebuildAll()
    }

    // MARK: - Pivot table protection

    /// Pivot tables on the active sheet that `range` touches.
    private func pivotTables(touching range: CellRange) -> [PivotTable] {
        workbook.pivotTables(intersecting: range, onSheet: activeSheetID)
    }

    /// Refuse an edit that would change part of a pivot table, as Excel
    /// does: the definition would no longer match its cells. Returns true
    /// (and tells the user) when the edit must not go ahead.
    func refuseIfPivot(_ range: CellRange) -> Bool {
        guard let table = pivotTables(touching: range).first else { return false }
        refusePivotEdit(table)
        return true
    }

    private func refusePivotEdit(_ table: PivotTable) {
        let index = workbook.pivotTables.firstIndex { $0.sheetID == table.sheetID && $0.name == table.name }
        let editable = index.map { pivotEditBlocker($0) == nil } ?? false
        notice = DocumentNotice(
            message: "You can’t change part of a pivot table.",
            detail: editable
                ? "Use the PivotTable Fields panel to change “\(table.name)”, or select all of it and press Delete to remove it."
                : "“\(table.name)” came from Excel with features SimpleSpread keeps but can’t edit. "
                    + "To remove it, select the whole pivot table and press Delete.")
    }

    private func refuseStructuralEdit(axisIsRow: Bool, index: Int, count: Int) -> Bool {
        guard let table = WorkbookOperations.pivotTableSplit(
            in: workbook, sheetID: activeSheetID, axisIsRow: axisIsRow, index: index, count: count) else {
            return false
        }
        notice = DocumentNotice(
            message: "You can’t insert or delete \(axisIsRow ? "rows" : "columns") through a pivot table.",
            detail: "This would split “\(table.name)”. Select rows or columns entirely above, "
                + "below or beside it, or all of the pivot table’s \(axisIsRow ? "rows" : "columns") to delete it.")
        return true
    }

    // MARK: - Editing

    /// Commit raw typed input into a cell (the shared parsing pipeline).
    public func commitInput(_ text: String, at address: CellAddress) {
        guard !refuseIfPivot(CellRange(address)) else { return }
        let currentStyle = style(at: address)
        let parsed = ValueParser.parse(text, textFormat: currentStyle.numberFormat.isTextFormat)
        let snaps = snapshot([address])
        let abs = AbsoluteAddress(sheetID: activeSheetID, address: address)
        if let formula = parsed.formulaText {
            engine.setCellFormula(formula, at: abs)
        } else {
            engine.setCellValue(parsed.value, at: abs)
        }
        // Apply an inferred format only when the cell is still General.
        if let suggested = parsed.suggestedFormat, currentStyle.numberFormat.isGeneral {
            var newStyle = currentStyle
            newStyle.numberFormat = suggested
            var cell = activeSheet.cell(at: address)
            cell.styleIndex = workbook.styleIndex(for: newStyle)
            activeSheet.setCell(cell, at: address)
        }
        registerCellUndo(snaps, actionName: "Typing")
        markChanged()
    }

    /// Delete contents (not formatting) of the selected range.
    public func clearSelectionContents() {
        let touched = pivotTables(touching: selection.range)
        if !touched.isEmpty {
            // Deleting a whole pivot table removes it (as in Excel); clearing
            // part of one would leave its definition describing other cells.
            if let partial = touched.first(where: { selection.range.union($0.occupiedRange) != selection.range }) {
                refusePivotEdit(partial)
                return
            }
            removePivotTablesAndClear(touched)
            return
        }
        let addresses = selection.range.addresses
        let snaps = snapshot(addresses)
        for address in addresses {
            let abs = AbsoluteAddress(sheetID: activeSheetID, address: address)
            if !activeSheet.cell(at: address).isDefault {
                engine.clearCell(at: abs)
            }
        }
        registerCellUndo(snaps, actionName: "Delete")
        markChanged()
    }

    /// Remove pivot tables and clear the selection, as one undoable step.
    private func removePivotTablesAndClear(_ tables: [PivotTable]) {
        registerWorkbookUndo(actionName: "Delete")
        let sheetID = activeSheetID
        let names = Set(tables.map(\.name))
        workbook.removePivotTables { $0.sheetID == sheetID && names.contains($0.name)
            && selection.range.union($0.occupiedRange) == selection.range }
        for address in selection.range.addresses where !activeSheet.cell(at: address).isDefault {
            engine.clearCell(at: AbsoluteAddress(sheetID: sheetID, address: address))
        }
        markChanged()
    }

    // MARK: - Formatting

    public func applyStyleToSelection(_ actionName: String, _ mutate: (inout CellStyle) -> Void) {
        let addresses = selection.range.addresses
        let snaps = snapshot(addresses)
        workbook.modifyStyle(in: selection.range, ofSheetID: activeSheetID, mutate)
        registerCellUndo(snaps, actionName: actionName)
        markChanged()
    }

    public func toggleBold() {
        let target = !style(at: selection.activeCell).bold
        applyStyleToSelection("Bold") { $0.bold = target }
    }

    public func toggleItalic() {
        let target = !style(at: selection.activeCell).italic
        applyStyleToSelection("Italic") { $0.italic = target }
    }

    public func toggleUnderline() {
        let target = !style(at: selection.activeCell).underline
        applyStyleToSelection("Underline") { $0.underline = target }
    }

    public func toggleStrikethrough() {
        let target = !style(at: selection.activeCell).strikethrough
        applyStyleToSelection("Strikethrough") { $0.strikethrough = target }
    }

    public func setNumberFormat(_ format: NumberFormat) {
        applyStyleToSelection("Number Format") { $0.numberFormat = format }
    }

    public func setHorizontalAlignment(_ alignment: TextAlignmentH) {
        applyStyleToSelection("Alignment") { $0.horizontalAlignment = alignment }
    }

    public func setVerticalAlignment(_ alignment: TextAlignmentV) {
        applyStyleToSelection("Alignment") { $0.verticalAlignment = alignment }
    }

    public func toggleWrapText() {
        let target = !style(at: selection.activeCell).wrapText
        applyStyleToSelection("Wrap Text") { $0.wrapText = target }
    }

    /// Increase/Decrease Indent, clamped to Excel's 0...15 levels. Indenting
    /// type-aligned (automatic) cells left-aligns them, as Excel does.
    public func adjustIndent(by delta: Int) {
        let target = max(0, min(15, style(at: selection.activeCell).indent + delta))
        applyStyleToSelection(delta > 0 ? "Increase Indent" : "Decrease Indent") {
            $0.indent = target
            if target > 0, $0.horizontalAlignment == .automatic || $0.horizontalAlignment == .center {
                $0.horizontalAlignment = .left
            }
        }
    }

    /// nil resets to the default font.
    public func setFontName(_ name: String?) {
        let stored = name == CellStyle.defaultFontName ? nil : name
        applyStyleToSelection("Font") { $0.fontName = stored }
    }

    /// Set the font size and, like Excel's auto-height rows, grow any selected
    /// row too short for the new size (rows never shrink). One undo step.
    public func setFontSize(_ size: Double) {
        let stored = size == CellStyle.defaultFontSize ? nil : size
        let needed = Self.rowHeight(forFontSize: size)
        let sheet = activeSheet
        let range = selection.range
        var oldHeights: [Int: CGFloat?] = [:]
        // Cap at the used rows so a whole-column selection stays cheap.
        let lastRow = min(range.end.row, max(range.start.row, sheet.usedRange?.end.row ?? 0))
        for row in range.start.row...lastRow where sheet.rowHeight(row) < needed {
            oldHeights[row] = sheet.rowHeights[row]
        }
        withUndoGroup {
            applyStyleToSelection("Font Size") { $0.fontSize = stored }
            guard !oldHeights.isEmpty else { return }
            for row in oldHeights.keys { sheet.rowHeights[row] = needed }
            registerRowHeightUndo(oldHeights, sheetID: sheet.id, actionName: "Font Size")
            markChanged()
        }
    }

    /// Default 12pt text sits in the default 22pt row; scale from there.
    static func rowHeight(forFontSize size: Double) -> CGFloat {
        CGFloat((size * 1.25 + 7).rounded(.up))
    }

    private func registerRowHeightUndo(_ heights: [Int: CGFloat?], sheetID: Int, actionName: String) {
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let sheet = doc.workbook.sheet(withID: sheetID) else { return }
                var redo: [Int: CGFloat?] = [:]
                for (row, height) in heights {
                    redo[row] = sheet.rowHeights[row]
                    sheet.rowHeights[row] = height
                }
                doc.registerRowHeightUndo(redo, sheetID: sheetID, actionName: actionName)
                doc.markChanged()
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Increase/Decrease Decimal. A General cell starts from the decimals it
    /// currently shows, as in Excel.
    public func adjustDecimals(by delta: Int) {
        let current = style(at: selection.activeCell).numberFormat
        var base = current
        if current.isGeneral {
            var decimals = 0
            if case .number(let n) = activeSheet.value(at: selection.activeCell) {
                let shown = NumberFormatEngine.generalString(for: n)
                if !shown.contains("E"), let dot = shown.firstIndex(of: ".") {
                    decimals = shown.distance(from: dot, to: shown.endIndex) - 1
                }
            }
            base = NumberFormat(code: decimals == 0 ? "0" : "0." + String(repeating: "0", count: decimals))
        }
        guard let target = base.adjustingDecimals(by: delta) ?? (current.isGeneral ? base : nil) else { return }
        applyStyleToSelection(delta > 0 ? "Increase Decimal" : "Decrease Decimal") {
            $0.numberFormat = target
        }
    }

    // MARK: - AutoSum

    /// AutoSum (Σ). With one cell selected, wrap the numbers directly above it
    /// (else to its left) in `function`. With a range, total each column in
    /// the range's empty bottom row, or in the row below it. One undo step.
    public func autoSum(_ function: String = "SUM") {
        let range = selection.range
        let sheet = activeSheet
        func isNumber(_ addr: CellAddress) -> Bool {
            if case .number = sheet.value(at: addr) { return true }
            return false
        }
        func isEmpty(_ addr: CellAddress) -> Bool { sheet.cell(at: addr).value.isEmpty && sheet.cell(at: addr).formula == nil }

        var writes: [(CellAddress, String)] = []
        if range.isSingleCell {
            let target = range.start
            var top = target.row
            while top > 0, isNumber(CellAddress(row: top - 1, column: target.column)) { top -= 1 }
            var left = target.column
            while left > 0, isNumber(CellAddress(row: target.row, column: left - 1)) { left -= 1 }
            let source: CellRange?
            if top < target.row {
                source = CellRange(start: CellAddress(row: top, column: target.column),
                                   end: CellAddress(row: target.row - 1, column: target.column))
            } else if left < target.column {
                source = CellRange(start: CellAddress(row: target.row, column: left),
                                   end: CellAddress(row: target.row, column: target.column - 1))
            } else {
                source = nil
            }
            writes.append((target, "=\(function)(\(source?.a1 ?? ""))"))
        } else {
            let bottomEmpty = range.end.row > range.start.row
                && (range.start.column...range.end.column).allSatisfy {
                    isEmpty(CellAddress(row: range.end.row, column: $0))
                }
            let targetRow = bottomEmpty ? range.end.row : range.end.row + 1
            let lastSourceRow = targetRow - 1
            for column in range.start.column...range.end.column {
                let source = CellRange(start: CellAddress(row: range.start.row, column: column),
                                       end: CellAddress(row: lastSourceRow, column: column))
                writes.append((CellAddress(row: targetRow, column: column), "=\(function)(\(source.a1))"))
            }
        }
        guard let first = writes.first, !refuseIfPivot(CellRange(start: first.0, end: writes.last!.0)) else { return }
        withUndoGroup {
            for (address, formula) in writes { commitInput(formula, at: address) }
        }
        if writes.count == 1, range.isSingleCell {
            selection.select(first.0)
        } else {
            selection.select(range: CellRange(start: first.0, end: writes.last!.0))
        }
        requestScrollToActiveCell()
    }

    // MARK: - Format painter

    /// Styles copied by the format painter, row-major over the source range;
    /// the next selection made with the mouse receives them (tiled).
    @Published public private(set) var formatPainterStyles: [[CellStyle]]?

    public func beginFormatPainter() {
        let range = selection.range
        // Bound the copy: a whole-column selection copies its used part.
        let lastRow = min(range.end.row, range.start.row + 999)
        let lastColumn = min(range.end.column, range.start.column + 255)
        formatPainterStyles = (range.start.row...lastRow).map { row in
            (range.start.column...lastColumn).map { style(at: CellAddress(row: row, column: $0)) }
        }
    }

    public func cancelFormatPainter() {
        formatPainterStyles = nil
    }

    /// Called when a mouse selection ends while the painter is armed.
    public func applyFormatPainter() {
        guard let styles = formatPainterStyles, let firstRow = styles.first, !firstRow.isEmpty else { return }
        formatPainterStyles = nil
        var range = selection.range
        // One cell clicked: paint the source's shape from there.
        if range.isSingleCell {
            range = CellRange(start: range.start,
                              end: CellAddress(row: range.start.row + styles.count - 1,
                                               column: range.start.column + firstRow.count - 1))
            selection.select(range: range)
        }
        guard !refuseIfPivot(range) else { return }
        let addresses = range.addresses
        let snaps = snapshot(addresses)
        for address in addresses {
            let row = styles[(address.row - range.start.row) % styles.count]
            let painted = row[(address.column - range.start.column) % row.count]
            var cell = activeSheet.cell(at: address)
            var target = painted
            target.pivotButton = workbook.style(at: cell.styleIndex).pivotButton
            cell.styleIndex = workbook.styleIndex(for: target)
            activeSheet.setCell(cell, at: address)
        }
        registerCellUndo(snaps, actionName: "Paste Formatting")
        markChanged()
    }

    // MARK: - Structure

    public func insertRows(at index: Int, count: Int = 1) {
        guard !refuseStructuralEdit(axisIsRow: true, index: index, count: count) else { return }
        registerWorkbookUndo(actionName: "Insert Rows")
        WorkbookOperations.insertRows(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        markChanged()
    }

    public func deleteRows(at index: Int, count: Int = 1) {
        guard !refuseStructuralEdit(axisIsRow: true, index: index, count: -count) else { return }
        registerWorkbookUndo(actionName: "Delete Rows")
        WorkbookOperations.deleteRows(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        selection.select(CellAddress(row: min(index, max(0, GridLayout(sheet: activeSheet).rowCount - 1)),
                                     column: selection.activeCell.column))
        markChanged()
    }

    public func insertColumns(at index: Int, count: Int = 1) {
        guard !refuseStructuralEdit(axisIsRow: false, index: index, count: count) else { return }
        registerWorkbookUndo(actionName: "Insert Columns")
        WorkbookOperations.insertColumns(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        markChanged()
    }

    public func deleteColumns(at index: Int, count: Int = 1) {
        guard !refuseStructuralEdit(axisIsRow: false, index: index, count: -count) else { return }
        registerWorkbookUndo(actionName: "Delete Columns")
        WorkbookOperations.deleteColumns(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        selection.select(CellAddress(row: selection.activeCell.row, column: index))
        markChanged()
    }

    public func setColumnWidth(_ column: Int, width: CGFloat) {
        activeSheet.columnWidths[column] = max(12, width)
        markChanged()
    }

    public func setRowHeight(_ row: Int, height: CGFloat) {
        activeSheet.rowHeights[row] = max(12, height)
        markChanged()
    }

    // MARK: - Sheets

    public func addSheet() {
        registerWorkbookUndo(actionName: "Add Sheet")
        let sheet = workbook.addSheet()
        activeSheetID = sheet.id
        selection = SelectionState()
        markChanged()
    }

    public func deleteActiveSheet() {
        guard workbook.sheets.count > 1 else { return }
        registerWorkbookUndo(actionName: "Delete Sheet")
        let deletedIndex = workbook.indexOfSheet(withID: activeSheetID) ?? 0
        WorkbookOperations.deleteSheet(in: workbook, sheetID: activeSheetID)
        engine.rebuildAll()
        let idx = min(deletedIndex, workbook.sheets.count - 1)
        activeSheetID = workbook.sheets[idx].id
        selection = SelectionState()
        markChanged()
    }

    public func renameActiveSheet(to name: String) {
        registerWorkbookUndo(actionName: "Rename Sheet")
        WorkbookOperations.renameSheet(in: workbook, sheetID: activeSheetID, to: name)
        engine.rebuildAll()
        markChanged()
    }

    public func selectSheet(withID id: Int) {
        guard workbook.sheet(withID: id) != nil, id != activeSheetID else { return }
        activeSheetID = id
        selection = SelectionState()
        revision += 1
    }

    public func moveSheet(withID id: Int, to index: Int) {
        registerWorkbookUndo(actionName: "Reorder Sheets")
        workbook.moveSheet(withID: id, to: index)
        markChanged()
    }

    // MARK: - Clipboard

    /// TSV of the selection's displayed values (external interchange).
    public func selectionTSV() -> String {
        let range = selection.range
        var lines: [String] = []
        for r in range.start.row...range.end.row {
            var fields: [String] = []
            for c in range.start.column...range.end.column {
                fields.append(displayString(at: CellAddress(row: r, column: c)))
            }
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// Internal payload (formulas + styles) for lossless paste.
    public func selectionPayload(isCut: Bool = false) -> ClipboardPayload {
        let range = selection.range
        var entries: [ClipboardPayload.Entry] = []
        range.forEachAddress { addr in
            let cell = activeSheet.cell(at: addr)
            guard !cell.isDefault else { return }
            // A pivot field button belongs to its pivot table, not the value.
            var style = workbook.style(at: cell.styleIndex)
            style.pivotButton = false
            entries.append(ClipboardPayload.Entry(
                rowOffset: addr.row - range.start.row,
                columnOffset: addr.column - range.start.column,
                cell: cell,
                style: style))
        }
        return ClipboardPayload(rows: range.rowCount, columns: range.columnCount,
                                entries: entries, isCut: isCut)
    }

    /// Paste an internal payload at the active cell. Copy adjusts relative
    /// references by the displacement; cut pastes formulas verbatim.
    public func paste(payload: ClipboardPayload, sourceOrigin: CellAddress?) {
        let target = selection.range.start
        var addresses: [CellAddress] = []
        var writes: [(AbsoluteAddress, CellValue, String?)] = []
        var styleWrites: [(CellAddress, CellStyle)] = []

        // Single-cell source replicates across a multi-cell target selection.
        let replicate = payload.rows == 1 && payload.columns == 1 && !selection.isSingleCell
        let targetRange = replicate ? selection.range
            : CellRange(start: target,
                        end: CellAddress(row: target.row + payload.rows - 1,
                                         column: target.column + payload.columns - 1))
        guard targetRange.end.isValid else { return }
        guard !refuseIfPivot(targetRange) else { return }

        func destinations(for entry: ClipboardPayload.Entry) -> [CellAddress] {
            if replicate {
                return targetRange.addresses
            }
            return [CellAddress(row: target.row + entry.rowOffset,
                                column: target.column + entry.columnOffset)]
        }

        // Overwrite the whole target rect (paste clears cells the payload
        // leaves empty).
        let snaps = snapshot(targetRange.addresses)
        for addr in targetRange.addresses {
            addresses.append(addr)
            writes.append((AbsoluteAddress(sheetID: activeSheetID, address: addr), .empty, nil))
        }
        for entry in payload.entries {
            for dest in destinations(for: entry) {
                var formula = entry.cell.formula
                if let f = formula, !payload.isCut {
                    let origin = sourceOrigin ?? targetRange.start
                    let dr = dest.row - (origin.row + entry.rowOffset)
                    let dc = dest.column - (origin.column + entry.columnOffset)
                    formula = WorkbookOperations.translatedFormula(f, byRows: dr, columns: dc)
                }
                if let idx = writes.firstIndex(where: { $0.0.address == dest }) {
                    writes[idx] = (AbsoluteAddress(sheetID: activeSheetID, address: dest),
                                   entry.cell.value, formula)
                }
                styleWrites.append((dest, entry.style))
            }
        }
        engine.setCells(writes)
        for (addr, style) in styleWrites {
            var cell = activeSheet.cell(at: addr)
            cell.styleIndex = workbook.styleIndex(for: style)
            activeSheet.setCell(cell, at: addr)
        }
        registerCellUndo(snaps, actionName: "Paste")
        selection.select(range: targetRange)
        markChanged()
    }

    /// Paste external plain text: tabs split columns, newlines split rows,
    /// each field goes through input parsing (formulas allowed — user action).
    public func paste(text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return }
        let grid = lines.map { $0.components(separatedBy: "\t") }
        let target = selection.range.start

        var affected: [CellAddress] = []
        for (r, row) in grid.enumerated() {
            for (c, _) in row.enumerated() {
                affected.append(CellAddress(row: target.row + r, column: target.column + c))
            }
        }
        guard affected.allSatisfy(\.isValid) else { return }
        let width = grid.map(\.count).max() ?? 1
        guard !refuseIfPivot(CellRange(start: target, end: CellAddress(row: target.row + grid.count - 1,
                                                                        column: target.column + width - 1)))
        else { return }
        let snaps = snapshot(affected)
        for (r, row) in grid.enumerated() {
            for (c, field) in row.enumerated() {
                let addr = CellAddress(row: target.row + r, column: target.column + c)
                let currentStyle = style(at: addr)
                let parsed = ValueParser.parse(field, textFormat: currentStyle.numberFormat.isTextFormat)
                let abs = AbsoluteAddress(sheetID: activeSheetID, address: addr)
                if let formula = parsed.formulaText {
                    engine.setCellFormula(formula, at: abs)
                } else {
                    engine.setCellValue(parsed.value, at: abs)
                }
                if let suggested = parsed.suggestedFormat, currentStyle.numberFormat.isGeneral {
                    var newStyle = currentStyle
                    newStyle.numberFormat = suggested
                    var cell = activeSheet.cell(at: addr)
                    cell.styleIndex = workbook.styleIndex(for: newStyle)
                    activeSheet.setCell(cell, at: addr)
                }
            }
        }
        registerCellUndo(snaps, actionName: "Paste")
        let endRow = target.row + grid.count - 1
        let endCol = target.column + (grid.map(\.count).max() ?? 1) - 1
        selection.select(range: CellRange(start: target,
                                          end: CellAddress(row: endRow, column: endCol)))
        markChanged()
    }

    /// Fill the source range's pattern across the target (fill-handle drag):
    /// values/styles copy, formulas adjust per destination offset.
    public func fill(from source: CellRange, to targetRange: CellRange) {
        guard targetRange.end.isValid else { return }
        // Only the cells being written matter (the source may sit in a pivot).
        if let table = pivotTables(touching: targetRange).first(where: { table in
            targetRange.addresses.contains { !source.contains($0) && table.occupiedRange.contains($0) }
        }) {
            refusePivotEdit(table)
            return
        }
        let snaps = snapshot(targetRange.addresses)
        var writes: [(AbsoluteAddress, CellValue, String?)] = []
        var styleWrites: [(CellAddress, Int)] = []
        for addr in targetRange.addresses {
            if source.contains(addr) { continue }
            func flooredMod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
            let srcRow = source.start.row + flooredMod(addr.row - targetRange.start.row, source.rowCount)
            let srcCol = source.start.column + flooredMod(addr.column - targetRange.start.column, source.columnCount)
            let srcAddr = CellAddress(row: srcRow, column: srcCol)
            let srcCell = activeSheet.cell(at: srcAddr)
            var formula = srcCell.formula
            if let f = formula {
                formula = WorkbookOperations.translatedFormula(
                    f, byRows: addr.row - srcAddr.row, columns: addr.column - srcAddr.column)
            }
            writes.append((AbsoluteAddress(sheetID: activeSheetID, address: addr),
                           srcCell.value, formula))
            // Destinations are outside pivots (refused above): no field button.
            var styleIndex = srcCell.styleIndex
            if workbook.style(at: styleIndex).pivotButton {
                var style = workbook.style(at: styleIndex)
                style.pivotButton = false
                styleIndex = workbook.styleIndex(for: style)
            }
            styleWrites.append((addr, styleIndex))
        }
        engine.setCells(writes)
        for (addr, styleIndex) in styleWrites {
            var cell = activeSheet.cell(at: addr)
            cell.styleIndex = styleIndex
            activeSheet.setCell(cell, at: addr)
        }
        registerCellUndo(snaps, actionName: "Fill")
        selection.select(range: source.union(targetRange))
        markChanged()
    }

    /// Fill Down (⌘D): copy the selection's top row into the rows below it,
    /// adjusting relative formula references. No-op on a single-row selection.
    public func fillDown() {
        let r = selection.range
        guard r.rowCount > 1 else { return }
        let topRow = CellRange(start: r.start,
                               end: CellAddress(row: r.start.row, column: r.end.column))
        fill(from: topRow, to: r)
    }

    /// Fill Right (⌘R): copy the selection's left column into the columns to
    /// its right. No-op on a single-column selection.
    public func fillRight() {
        let r = selection.range
        guard r.columnCount > 1 else { return }
        let leftColumn = CellRange(start: r.start,
                                   end: CellAddress(row: r.end.row, column: r.start.column))
        fill(from: leftColumn, to: r)
    }

    /// Clear Formatting (⌘\): reset every selected cell to the default style,
    /// leaving values and formulas intact.
    public func clearFormattingInSelection() {
        let addresses = selection.range.addresses
        let snaps = snapshot(addresses)
        var changed = false
        for addr in addresses {
            var cell = activeSheet.cell(at: addr)
            // A pivot's field buttons belong to the pivot, not the formatting.
            let target = workbook.style(at: cell.styleIndex).pivotButton
                ? workbook.styleIndex(for: CellStyle(pivotButton: true)) : 0
            if cell.styleIndex != target {
                cell.styleIndex = target
                activeSheet.setCell(cell, at: addr)
                changed = true
            }
        }
        guard changed else { return }
        registerCellUndo(snaps, actionName: "Clear Formatting")
        markChanged()
    }

    // MARK: - Zoom

    public func setZoom(_ zoom: CGFloat) {
        let clamped = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if abs(clamped - zoomLevel) > 0.0001 {
            zoomLevel = clamped
        }
    }

    public func zoomIn() {
        setZoom(zoomLevel * 1.25)
    }

    public func zoomOut() {
        setZoom(zoomLevel / 1.25)
    }

    public func resetZoom() {
        setZoom(1.0)
    }

    // MARK: - Find

    @Published public var isFindPresented = false
    @Published public var findQuery = ""
    @Published public private(set) var findMatches: [CellAddress] = []
    @Published public private(set) var findCurrentIndex = 0
    /// Bumped when the grid should scroll the active cell into view (find /
    /// name-box navigation, which change selection without a key event).
    @Published public private(set) var scrollTick = 0

    public func requestScrollToActiveCell() {
        scrollTick += 1
    }

    public func presentFind() {
        isFindPresented = true
        recomputeFind(preferringSelection: true)
    }

    public func dismissFind() {
        isFindPresented = false
    }

    public func setFindQuery(_ query: String) {
        findQuery = query
        recomputeFind(preferringSelection: true)
    }

    /// "3 of 12" / "No results" / "" — for the find bar.
    public var findStatus: String {
        if findQuery.isEmpty { return "" }
        if findMatches.isEmpty { return "No results" }
        return "\(findCurrentIndex + 1) of \(findMatches.count)"
    }

    /// Recompute matches in the active sheet. Searches both the displayed value
    /// and the formula text, case-insensitively.
    public func recomputeFind(preferringSelection: Bool) {
        let query = findQuery.lowercased()
        guard !query.isEmpty else {
            findMatches = []
            findCurrentIndex = 0
            return
        }
        var results: [CellAddress] = []
        for (addr, cell) in activeSheet.cells where cellMatchesFind(cell, query: query) {
            results.append(addr)
        }
        results.sort() // CellAddress is Comparable (row-major)
        findMatches = results
        guard !results.isEmpty else {
            findCurrentIndex = 0
            return
        }
        if preferringSelection {
            // Start at the first match at or after the current selection.
            let anchor = selection.activeCell
            findCurrentIndex = results.firstIndex { $0 >= anchor } ?? 0
        } else {
            findCurrentIndex = min(findCurrentIndex, results.count - 1)
        }
        selectCurrentMatch()
    }

    private func cellMatchesFind(_ cell: Cell, query: String) -> Bool {
        let format = workbook.style(at: cell.styleIndex).numberFormat
        if NumberFormatEngine.displayString(for: cell.value, format: format)
            .lowercased().contains(query) {
            return true
        }
        if let formula = cell.formula, formula.lowercased().contains(query) {
            return true
        }
        return false
    }

    public func findNext() {
        guard !findMatches.isEmpty else { return }
        findCurrentIndex = (findCurrentIndex + 1) % findMatches.count
        selectCurrentMatch()
    }

    public func findPrevious() {
        guard !findMatches.isEmpty else { return }
        findCurrentIndex = (findCurrentIndex - 1 + findMatches.count) % findMatches.count
        selectCurrentMatch()
    }

    private func selectCurrentMatch() {
        guard findCurrentIndex < findMatches.count else { return }
        selection.select(findMatches[findCurrentIndex])
        requestScrollToActiveCell()
    }

    // MARK: - Selection statistics (status bar)

    public struct SelectionStats {
        public var count: Int
        public var numericCount: Int
        public var sum: Double
        public var average: Double? { numericCount > 0 ? sum / Double(numericCount) : nil }
    }

    public func selectionStatistics() -> SelectionStats {
        var stats = SelectionStats(count: 0, numericCount: 0, sum: 0)
        // Cap the scan for enormous selections.
        let range = selection.range
        guard range.cellCount <= 1_000_000 else { return stats }
        // Like Excel's status bar, rows a filter hides are left out.
        let hidden = activeSheet.hiddenRows
        for (addr, cell) in activeSheet.cells where range.contains(addr) && !hidden.contains(addr.row) {
            if cell.value.isEmpty { continue }
            stats.count += 1
            if case .number(let n) = cell.value {
                stats.numericCount += 1
                stats.sum += n
            }
        }
        return stats
    }

    // MARK: - File I/O

    public func save(to url: URL) throws {
        let data = try XLSXWriter.data(for: workbook)
        try data.write(to: url, options: .atomic)
        fileURL = url
        suggestedFileName = nil
        isModified = false
    }

    public static func open(url: URL) throws -> SpreadsheetDocument {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent
        let workbook: Workbook
        let isTextImport = textImportExtensions.contains(ext)
        if isTextImport {
            workbook = CSV.importWorkbook(data: data, sheetName: baseName)
        } else {
            workbook = try XLSXReader.read(data: data)
        }
        let doc = SpreadsheetDocument(workbook: workbook)
        if isTextImport {
            // Delimited-text opens as an unsaved XLSX-native document: never
            // write back over the source file. Save-As pre-fills <base>.xlsx.
            doc.suggestedFileName = baseName + ".xlsx"
        } else {
            doc.fileURL = url
        }
        return doc
    }

    /// Import a CSV file as a new sheet in this document.
    public func importCSVSheet(from url: URL) throws {
        registerWorkbookUndo(actionName: "Import CSV")
        let data = try Data(contentsOf: url)
        let imported = CSV.importWorkbook(data: data,
                                          sheetName: url.deletingPathExtension().lastPathComponent)
        guard let source = imported.sheets.first else { return }
        let sheet = workbook.addSheet(named: source.name)
        for (addr, cell) in source.cells {
            var copied = cell
            let style = imported.style(at: cell.styleIndex)
            copied.styleIndex = workbook.styleIndex(for: style)
            sheet.setCell(copied, at: addr)
        }
        engine.rebuildAll()
        activeSheetID = sheet.id
        selection = SelectionState()
        markChanged()
    }

    public func exportActiveSheetCSV(to url: URL) throws {
        let data = CSV.export(sheet: activeSheet, workbook: workbook)
        try data.write(to: url, options: .atomic)
    }
}
