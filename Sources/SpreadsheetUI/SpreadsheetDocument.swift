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
        /// The row offset in the source when it differs from `rowOffset`:
        /// a copy of a filtered range closes up the hidden rows, but formulas
        /// still translate from where each cell really was.
        public var sourceRowOffset: Int? = nil
    }
    public var rows: Int
    public var columns: Int
    public var entries: [Entry]
    /// True if the source was a cut (paste moves rather than copies).
    public var isCut: Bool
    /// The top-left cell of the copied range: a paste translates relative
    /// references by its distance from here. It travels with the payload so
    /// pastes into another window, or after a relaunch, translate correctly.
    /// Nil in payloads from older builds (references then stay as they were).
    public var sourceOrigin: CellAddress? = nil

    public static let pasteboardType = "com.kikiplan.simplespread.cells"
}

/// A message the window shows as an alert (e.g. an edit that was refused).
public struct DocumentNotice: Identifiable, Equatable {
    public let id = UUID()
    public var message: String
    public var detail: String
}

/// Something holding typing that is not in its cell yet: the grid's in-cell
/// editor or the formula bar. It remembers which sheet and cell the typing
/// is for, so a commit lands there even after the user has moved on.
@MainActor
protocol PendingEditor: AnyObject {
    /// True when there is typing to commit.
    var hasPendingEdit: Bool { get }
    /// Write the typing to its cell and close the editor.
    func commitPendingEdit()
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
    /// What the opened file holds that saving will not write back ("3
    /// charts", "comments", …), so a save over it asks first.
    public internal(set) var unsupportedContent: [String] = []
    /// The user has saved without it once (Save Anyway, or a copy).
    public internal(set) var unsupportedContentAccepted = false
    @Published public private(set) var isModified = false
    /// Incremented whenever cell content/layout changes; grid views observe it.
    @Published public private(set) var revision = 0
    /// Incremented by every change to the document's content (not by
    /// switching sheets), so a background save knows whether the user
    /// changed anything after its snapshot.
    public private(set) var changeCount = 0
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
    /// The editor holding typing not yet written to its cell (the grid's
    /// in-cell editor or the formula bar), if any. See `commitPendingEdit`.
    weak var pendingEditor: PendingEditor?

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

    /// A document around a workbook whose engine was built elsewhere (a
    /// background load).
    init(workbook wb: Workbook, engine: CalculationEngine) {
        self.workbook = wb
        self.engine = engine
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
    nonisolated public static let textImportExtensions: Set<String> = ["csv", "tsv", "txt", "tab"]

    // MARK: - Display / edit strings

    /// What the grid shows for a cell.
    public func displayString(at address: CellAddress) -> String {
        let cell = activeSheet.cell(at: address)
        let style = workbook.style(at: cell.styleIndex)
        return NumberFormatEngine.displayString(for: cell.value, format: style.numberFormat)
    }

    /// What the formula bar / in-place editor shows: the formula with '=',
    /// or text that commits back to exactly the same value.
    public func editString(at address: CellAddress, sheetID: Int? = nil) -> String {
        let sheet = sheetID.flatMap { workbook.sheet(withID: $0) } ?? activeSheet
        let cell = sheet.cell(at: address)
        if let formula = cell.formula {
            return "=" + formula
        }
        let style = workbook.style(at: cell.styleIndex)
        switch cell.value {
        case .empty:
            return ""
        case .number(let n):
            // Exact: dates, times and percents edit in their own form only
            // when that loses nothing (see ValueParser.editText).
            return ValueParser.editText(for: n, format: style.numberFormat)
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
        changeCount += 1
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

    /// True while an editor holds typing that is not in its cell yet. An
    /// open editor counts as unsaved work.
    public var hasPendingEdit: Bool { pendingEditor?.hasPendingEdit ?? false }

    /// The one choke point for typing that is still in an editor: write it
    /// to the cell it was typed for (which may be on another sheet by now)
    /// and close the editor. Called before anything that would otherwise
    /// lose it or put it in the wrong place: switching sheets, structural
    /// and range edits, menu commands, save and close. Excel does the same
    /// when you click away from a cell you are typing in.
    public func commitPendingEdit() {
        guard let editor = pendingEditor else { return }
        pendingEditor = nil
        editor.commitPendingEdit()
    }

    /// Commit raw typed input into a cell (the shared parsing pipeline).
    /// `sheetID` defaults to the active sheet; an editor passes the sheet it
    /// was opened on.
    public func commitInput(_ text: String, at address: CellAddress, sheetID: Int? = nil) {
        let sheetID = sheetID ?? activeSheetID
        guard let sheet = workbook.sheet(withID: sheetID) else { return }
        if sheetID == activeSheetID {
            guard !refuseIfPivot(CellRange(address)) else { return }
        } else if let table = workbook.pivotTables(intersecting: CellRange(address), onSheet: sheetID).first {
            refusePivotEdit(table)
            return
        }
        // Committing the editor's text unchanged is not an edit: no write,
        // no undo step, no "modified" (and nothing to re-parse lossily).
        guard text != editString(at: address, sheetID: sheetID) else { return }
        let currentStyle = workbook.style(at: sheet.cell(at: address).styleIndex)
        let parsed = ValueParser.parse(text, textFormat: currentStyle.numberFormat.isTextFormat)
        let snaps = snapshot([address], sheetID: sheetID)
        let abs = AbsoluteAddress(sheetID: sheetID, address: address)
        if let formula = parsed.formulaText {
            engine.setCellFormula(formula, at: abs)
        } else {
            engine.setCellValue(parsed.value, at: abs)
        }
        // Apply an inferred format only when the cell is still General.
        if let suggested = parsed.suggestedFormat, currentStyle.numberFormat.isGeneral {
            var newStyle = currentStyle
            newStyle.numberFormat = suggested
            var cell = sheet.cell(at: address)
            cell.styleIndex = workbook.styleIndex(for: newStyle)
            sheet.setCell(cell, at: address)
        }
        registerCellUndo(snaps, actionName: "Typing")
        markChanged()
    }

    /// Delete contents (not formatting) of the selected range.
    /// Delete: clear contents, keeping formatting. Like Excel, rows the
    /// filter hides are left alone (`skippingFiltered`); a cut clears all.
    public func clearSelectionContents(skippingFiltered: Bool = true) {
        commitPendingEdit()
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
        let skipped = rowsSkipped(by: skippingFiltered ? .clear : .cut, in: selection.range)
        // Only cells that hold something change (⌘A then Delete on a big
        // sheet must not list every address in the range).
        let addresses = occupiedAddresses(in: selection.range).filter { !skipped.contains($0.row) }
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

    /// Restyle the selection (see `forEachFormattingTarget` for which cells
    /// a big selection covers). One undo step.
    public func applyStyleToSelection(_ actionName: String, _ mutate: (inout CellStyle) -> Void) {
        applyStyle(to: selection.range, actionName: actionName, addressDependent: false) { _, style in
            mutate(&style)
        }
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
        commitPendingEdit()
        guard !refuseStructuralEdit(axisIsRow: true, index: index, count: count) else { return }
        registerWorkbookUndo(actionName: "Insert Rows")
        WorkbookOperations.insertRows(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        markChanged()
    }

    public func deleteRows(at index: Int, count: Int = 1) {
        commitPendingEdit()
        guard !refuseStructuralEdit(axisIsRow: true, index: index, count: -count) else { return }
        registerWorkbookUndo(actionName: "Delete Rows")
        WorkbookOperations.deleteRows(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        selection.select(CellAddress(row: min(index, max(0, GridLayout(sheet: activeSheet).rowCount - 1)),
                                     column: selection.activeCell.column))
        markChanged()
    }

    public func insertColumns(at index: Int, count: Int = 1) {
        commitPendingEdit()
        guard !refuseStructuralEdit(axisIsRow: false, index: index, count: count) else { return }
        registerWorkbookUndo(actionName: "Insert Columns")
        WorkbookOperations.insertColumns(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        markChanged()
    }

    public func deleteColumns(at index: Int, count: Int = 1) {
        commitPendingEdit()
        guard !refuseStructuralEdit(axisIsRow: false, index: index, count: -count) else { return }
        registerWorkbookUndo(actionName: "Delete Columns")
        WorkbookOperations.deleteColumns(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        selection.select(CellAddress(row: selection.activeCell.row, column: index))
        markChanged()
    }

    /// Resize a column (header drag, autofit). One undo step per drag.
    public func setColumnWidth(_ column: Int, width: CGFloat) {
        resize(isRow: false, index: column, to: max(12, width), actionName: "Column Width")
    }

    /// Resize a row (header drag). One undo step per drag.
    public func setRowHeight(_ row: Int, height: CGFloat) {
        resize(isRow: true, index: row, to: max(12, height), actionName: "Row Height")
    }

    /// The resize the newest undo step records, and the revision it left the
    /// document at. A drag calls setColumnWidth/setRowHeight for every mouse
    /// move; while nothing else has changed since, those updates extend the
    /// same undo step, which keeps the size from before the drag.
    private struct ResizeStep: Equatable {
        var sheetID: Int
        var isRow: Bool
        var index: Int
        var revision: Int
    }
    private var lastResizeStep: ResizeStep?

    private func resize(isRow: Bool, index: Int, to size: CGFloat, actionName: String) {
        let sheet = activeSheet
        let current = isRow ? sheet.rowHeight(index) : sheet.columnWidth(index)
        guard current != size else { return }
        let old = isRow ? sheet.rowHeights[index] : sheet.columnWidths[index]
        let continuing = lastResizeStep == ResizeStep(sheetID: sheet.id, isRow: isRow, index: index,
                                                      revision: revision)
            && undoManager.undoActionName == actionName
        if isRow { sheet.rowHeights[index] = size } else { sheet.columnWidths[index] = size }
        if !continuing {
            withUndoGroup {
                registerSizeUndo(isRow: isRow, index: index, size: old, sheetID: sheet.id, actionName: actionName)
            }
        }
        markChanged()
        lastResizeStep = ResizeStep(sheetID: sheet.id, isRow: isRow, index: index, revision: revision)
    }

    /// Undo sets one row's height (or column's width) back to `size`.
    private func registerSizeUndo(isRow: Bool, index: Int, size: CGFloat?, sheetID: Int, actionName: String) {
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let sheet = doc.workbook.sheet(withID: sheetID) else { return }
                let redo = isRow ? sheet.rowHeights[index] : sheet.columnWidths[index]
                if isRow { sheet.rowHeights[index] = size } else { sheet.columnWidths[index] = size }
                doc.registerSizeUndo(isRow: isRow, index: index, size: redo, sheetID: sheetID,
                                     actionName: actionName)
                doc.markChanged()
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Sheets

    public func addSheet() {
        commitPendingEdit()
        registerWorkbookUndo(actionName: "Add Sheet")
        let sheet = workbook.addSheet()
        engine.sheetsDidChange() // formulas that named it before it existed
        activeSheetID = sheet.id
        selection = SelectionState()
        markChanged()
    }

    public func deleteActiveSheet() {
        commitPendingEdit()
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
        commitPendingEdit()
        registerWorkbookUndo(actionName: "Rename Sheet")
        WorkbookOperations.renameSheet(in: workbook, sheetID: activeSheetID, to: name)
        engine.rebuildAll()
        markChanged()
    }

    public func selectSheet(withID id: Int) {
        commitPendingEdit()
        guard workbook.sheet(withID: id) != nil, id != activeSheetID else { return }
        activeSheetID = id
        selection = SelectionState()
        revision += 1
    }

    public func moveSheet(withID id: Int, to index: Int) {
        commitPendingEdit()
        registerWorkbookUndo(actionName: "Reorder Sheets")
        workbook.moveSheet(withID: id, to: index)
        markChanged()
    }

    // MARK: - Clipboard

    /// Range commands that treat filter-hidden rows differently.
    enum RangeCommand {
        case copy, cut, clear, fill
        /// One copied cell pasted across a larger selection.
        case pasteOneCell
        /// A copied block pasted at the active cell.
        case pasteBlock
    }

    /// The rows in `range` that `command` leaves alone. Excel's rules, kept
    /// in one place:
    /// - Copy, Delete (clear contents), Fill Down/Right and the fill handle,
    ///   and pasting one cell across a selection act only on the rows a
    ///   filter shows; the rows the AutoFilter hides are skipped.
    /// - Cut, and pasting a block of cells, act on every row: Excel pastes
    ///   a block contiguously, over filter-hidden rows too.
    /// - Rows hidden by hand (not by a filter) are never skipped; Excel
    ///   copies, clears and fills them like any other row.
    func rowsSkipped(by command: RangeCommand, in range: CellRange) -> Set<Int> {
        switch command {
        case .copy, .clear, .fill, .pasteOneCell: return filteredOutRows(in: range)
        case .cut, .pasteBlock: return []
        }
    }

    /// The cells in `range` that hold something, without listing every
    /// address of a huge range.
    func occupiedAddresses(in range: CellRange) -> [CellAddress] {
        let cells = activeSheet.cells
        if range.cellCount > cells.count {
            return cells.keys.filter(range.contains)
        }
        return range.addresses.filter { cells[$0] != nil }
    }

    /// The selection as tab-separated text (displayed values) for other
    /// apps. Like Excel, a copy leaves out rows the filter hides
    /// (`skippingFiltered`); a cut keeps them all.
    public func selectionTSV(skippingFiltered: Bool = true) -> String {
        let range = selection.range
        let skipped = rowsSkipped(by: skippingFiltered ? .copy : .cut, in: range)
        var lines: [String] = []
        for r in range.start.row...range.end.row where !skipped.contains(r) {
            var fields: [String] = []
            for c in range.start.column...range.end.column {
                fields.append(Self.tsvField(displayString(at: CellAddress(row: r, column: c))))
            }
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// The selection as an HTML table, the form Numbers and Excel take
    /// multi-line cells in. A line break inside a cell is a `<br>` marked
    /// (for Excel) as staying in the same cell.
    public func selectionHTML(skippingFiltered: Bool = true) -> String {
        let range = selection.range
        let skipped = rowsSkipped(by: skippingFiltered ? .copy : .cut, in: range)
        var html = "<html><head><meta charset=\"utf-8\"></head><body><table>"
        for r in range.start.row...range.end.row where !skipped.contains(r) {
            html += "<tr>"
            for c in range.start.column...range.end.column {
                html += "<td>" + Self.htmlCell(displayString(at: CellAddress(row: r, column: c))) + "</td>"
            }
            html += "</tr>"
        }
        return html + "</table></body></html>"
    }

    static func htmlCell(_ text: String) -> String {
        var out = ""
        var previousWasCR = false
        for ch in text.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\r", "\n":
                // CRLF is one break.
                if ch == "\n" && previousWasCR { break }
                out += "<br style=\"mso-data-placement:same-cell\">"
            default: out.unicodeScalars.append(ch)
            }
            previousWasCR = ch == "\r"
        }
        return out
    }

    /// Quote a field as Excel and Numbers do on the clipboard: a field with
    /// a tab or line break (or one that starts with a quote, which would
    /// otherwise read back as quoted) goes in double quotes, with its own
    /// quotes doubled. Other quotes are left alone (`5" screen`).
    static func tsvField(_ text: String) -> String {
        let needsQuotes = text.hasPrefix("\"") || text.contains { $0 == "\t" || $0.isNewline }
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Internal payload (formulas + styles) for lossless paste. A copy of a
    /// filtered range takes only the rows that show, closed up, as Excel
    /// does; a cut moves every row, hidden or not (it clears them all).
    public func selectionPayload(isCut: Bool = false) -> ClipboardPayload {
        let range = selection.range
        let skipped = rowsSkipped(by: isCut ? .cut : .copy, in: range)
        let rows = (range.start.row...range.end.row).filter { !skipped.contains($0) }
        var entries: [ClipboardPayload.Entry] = []
        for (packedRow, row) in rows.enumerated() {
            for column in range.start.column...range.end.column {
                let addr = CellAddress(row: row, column: column)
                let cell = activeSheet.cell(at: addr)
                guard !cell.isDefault else { continue }
                // A pivot field button belongs to its pivot table, not the value.
                var style = workbook.style(at: cell.styleIndex)
                style.pivotButton = false
                let sourceRow = row - range.start.row
                entries.append(ClipboardPayload.Entry(
                    rowOffset: packedRow,
                    columnOffset: column - range.start.column,
                    cell: cell,
                    style: style,
                    sourceRowOffset: sourceRow == packedRow ? nil : sourceRow))
            }
        }
        return ClipboardPayload(rows: max(1, rows.count), columns: range.columnCount,
                                entries: entries, isCut: isCut, sourceOrigin: range.start)
    }

    /// Paste an internal payload at the active cell. Copy adjusts relative
    /// references by the distance from the payload's origin; cut pastes
    /// formulas verbatim.
    public func paste(payload: ClipboardPayload) {
        commitPendingEdit()
        let target = selection.range.start
        // Single-cell source replicates across a multi-cell target selection.
        let replicate = payload.rows == 1 && payload.columns == 1 && !selection.isSingleCell
        let targetRange = replicate ? selection.range
            : CellRange(start: target,
                        end: CellAddress(row: target.row + payload.rows - 1,
                                         column: target.column + payload.columns - 1))
        guard targetRange.end.isValid else { return }
        guard !refuseIfPivot(targetRange) else { return }
        let skipped = rowsSkipped(by: replicate ? .pasteOneCell : .pasteBlock, in: targetRange)
        let origin = payload.sourceOrigin ?? targetRange.start

        // Keyed by destination, so a later entry replaces an earlier one
        // without a search (a linear search here made paste quadratic).
        var writes: [CellAddress: (value: CellValue, formula: String?, style: CellStyle)] = [:]
        for entry in payload.entries {
            let destinations = replicate
                ? targetRange.addresses
                : [CellAddress(row: target.row + entry.rowOffset,
                               column: target.column + entry.columnOffset)]
            for dest in destinations where !skipped.contains(dest.row) {
                var formula = entry.cell.formula
                if let f = formula, !payload.isCut {
                    let dr = dest.row - (origin.row + (entry.sourceRowOffset ?? entry.rowOffset))
                    let dc = dest.column - (origin.column + entry.columnOffset)
                    formula = WorkbookOperations.translatedFormula(f, byRows: dr, columns: dc)
                }
                writes[dest] = (entry.cell.value, formula, entry.style)
            }
        }
        // The paste overwrites the whole target rect: cells the payload
        // leaves empty are cleared (only cells that hold something need it).
        let cleared = occupiedAddresses(in: targetRange).filter {
            writes[$0] == nil && !skipped.contains($0.row)
        }
        let snaps = snapshot(Array(writes.keys) + cleared)
        let sheetID = activeSheetID
        var entries = writes.map { (AbsoluteAddress(sheetID: sheetID, address: $0.key), $0.value.value, $0.value.formula) }
        entries += cleared.map { (AbsoluteAddress(sheetID: sheetID, address: $0), CellValue.empty, nil) }
        engine.setCells(entries)
        for (addr, write) in writes {
            var cell = activeSheet.cell(at: addr)
            cell.styleIndex = workbook.styleIndex(for: write.style)
            activeSheet.setCell(cell, at: addr)
        }
        registerCellUndo(snaps, actionName: "Paste")
        selection.select(range: targetRange)
        markChanged()
    }

    /// Paste external plain text: tab-separated, with Excel-style quoting (a
    /// quoted field may hold tabs and line breaks, so `"line1⏎line2"` is one
    /// cell). Each field goes through input parsing (formulas allowed — user
    /// action).
    public func paste(text: String) {
        commitPendingEdit()
        let grid = CSV.parse(text, delimiter: "\t")
        guard !grid.isEmpty else { return }
        let target = selection.range.start
        let width = grid.map(\.count).max() ?? 1
        let pasteRange = CellRange(start: target, end: CellAddress(row: target.row + grid.count - 1,
                                                                    column: target.column + width - 1))
        guard pasteRange.end.isValid, !refuseIfPivot(pasteRange) else { return }
        var affected: [CellAddress] = []
        for (r, row) in grid.enumerated() {
            for c in row.indices {
                affected.append(CellAddress(row: target.row + r, column: target.column + c))
            }
        }
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
        selection.select(range: pasteRange)
        markChanged()
    }

    /// Fill the source range's pattern across the target (fill-handle drag,
    /// Fill Down/Right): values/styles copy, formulas adjust per destination
    /// offset. Rows the filter hides are left alone, as in Excel.
    public func fill(from source: CellRange, to targetRange: CellRange) {
        commitPendingEdit()
        guard targetRange.end.isValid else { return }
        // Only the cells being written matter (the source may sit in a pivot).
        if let table = pivotTables(touching: targetRange).first(where: { table in
            targetRange.addresses.contains { !source.contains($0) && table.occupiedRange.contains($0) }
        }) {
            refusePivotEdit(table)
            return
        }
        let skipped = rowsSkipped(by: .fill, in: targetRange)
        var writes: [(AbsoluteAddress, CellValue, String?)] = []
        var styleWrites: [(CellAddress, Int)] = []
        func flooredMod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
        for addr in targetRange.addresses where !source.contains(addr) && !skipped.contains(addr.row) {
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
        let snaps = snapshot(writes.map(\.0.address))
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
        // Only stored cells can carry formatting.
        let sheet = activeSheet
        var snaps: [StyleSnapshot] = []
        for addr in storedAddresses(in: selection.range, sheet: sheet) {
            var cell = sheet.cell(at: addr)
            // A pivot's field buttons belong to the pivot, not the formatting.
            let target = workbook.style(at: cell.styleIndex).pivotButton
                ? workbook.styleIndex(for: CellStyle(pivotButton: true)) : 0
            if cell.styleIndex != target {
                snaps.append(StyleSnapshot(address: addr, styleIndex: cell.styleIndex))
                cell.styleIndex = target
                sheet.setCell(cell, at: addr)
            }
        }
        guard !snaps.isEmpty else { return }
        registerStyleUndo(snaps, sheetID: sheet.id, actionName: "Clear Formatting")
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
        if isFindSearching { return "Searching…" }
        if findMatches.isEmpty { return "No results" }
        return "\(findCurrentIndex + 1) of \(findMatches.count)"
    }

    /// Sheets with up to this many cells to check are searched at once, on
    /// the main thread (a few milliseconds). Bigger searches run in the
    /// background once typing pauses.
    static let findSynchronousLimit = 20_000
    /// How long typing must pause before a background search starts.
    static let findDebounce: Duration = .milliseconds(150)

    /// True while a background search for `findQuery` is pending.
    @Published public private(set) var isFindSearching = false
    private var findTask: Task<Void, Never>?
    /// The last finished search, so a query that extends it (typing one
    /// more letter) only rechecks its matches.
    private var lastFind: FindResult?

    /// What one search found, and on what.
    struct FindResult: Sendable {
        var sheetID: Int
        var revision: Int
        var query: String
        var matches: [CellAddress]
    }

    /// A copy of what a search reads. The cells and the style table are
    /// values, so the copy costs nothing and is safe to read off the main
    /// thread while the document goes on changing.
    struct FindInput: Sendable {
        var sheetID: Int
        var revision: Int
        var query: String
        var cells: [CellAddress: Cell]
        var styles: StyleTable
        /// Only these addresses can match (the previous query's matches,
        /// when this query contains it); nil searches every cell.
        var candidates: [CellAddress]?
    }

    /// Recompute matches in the active sheet. Searches both the displayed value
    /// and the formula text, case-insensitively. Big sheets are searched in
    /// the background after a short pause (see `findSynchronousLimit`).
    public func recomputeFind(preferringSelection: Bool) {
        findTask?.cancel()
        findTask = nil
        let input = findInput()
        guard !input.query.isEmpty else {
            isFindSearching = false
            findMatches = []
            findCurrentIndex = 0
            return
        }
        let workload = input.candidates?.count ?? input.cells.count
        if workload <= Self.findSynchronousLimit {
            isFindSearching = false
            finishFind(Self.search(input), preferringSelection: preferringSelection)
            return
        }
        isFindSearching = true
        findTask = Task { [weak self] in
            try? await Task.sleep(for: Self.findDebounce)
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { SpreadsheetDocument.search(input) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, let result else { return }
            self.findTask = nil
            self.isFindSearching = false
            self.finishFind(result, preferringSelection: preferringSelection)
        }
    }

    /// Finish a pending background search now (Return in the find bar
    /// before it has finished).
    private func completePendingFind() {
        guard isFindSearching else { return }
        findTask?.cancel()
        findTask = nil
        isFindSearching = false
        finishFind(Self.search(findInput()), preferringSelection: true)
    }

    private func findInput() -> FindInput {
        let sheet = activeSheet
        let query = findQuery.lowercased()
        var candidates: [CellAddress]?
        if let last = lastFind, last.sheetID == sheet.id, last.revision == revision,
           !last.query.isEmpty, query.contains(last.query) {
            // Every cell whose text contains the new query contains the old.
            candidates = last.matches
        }
        return FindInput(sheetID: sheet.id, revision: revision, query: query, cells: sheet.cells,
                         styles: workbook.styles, candidates: candidates)
    }

    /// The matches for `input`, row-major; nil if the task was cancelled.
    nonisolated static func search(_ input: FindInput) -> FindResult? {
        var results: [CellAddress] = []
        var checked = 0
        func check(_ address: CellAddress, _ cell: Cell) -> Bool {
            checked += 1
            if checked % 4096 == 0, Task.isCancelled { return false }
            if cellMatchesFind(cell, query: input.query, styles: input.styles) { results.append(address) }
            return true
        }
        if let candidates = input.candidates {
            for address in candidates {
                guard let cell = input.cells[address] else { continue }
                if !check(address, cell) { return nil }
            }
        } else {
            for (address, cell) in input.cells {
                if !check(address, cell) { return nil }
            }
        }
        results.sort() // CellAddress is Comparable (row-major)
        return FindResult(sheetID: input.sheetID, revision: input.revision, query: input.query,
                          matches: results)
    }

    private func finishFind(_ result: FindResult?, preferringSelection: Bool) {
        guard let result else { return }
        // The user switched sheets while it ran: search the new one.
        guard result.sheetID == activeSheetID else {
            recomputeFind(preferringSelection: preferringSelection)
            return
        }
        lastFind = result
        let results = result.matches
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

    nonisolated private static func cellMatchesFind(_ cell: Cell, query: String, styles: StyleTable) -> Bool {
        let format = styles[cell.styleIndex].numberFormat
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
        completePendingFind()
        guard !findMatches.isEmpty else { return }
        findCurrentIndex = (findCurrentIndex + 1) % findMatches.count
        selectCurrentMatch()
    }

    public func findPrevious() {
        completePendingFind()
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
        let sheet = activeSheet
        let key = StatsKey(revision: revision, sheetID: sheet.id, range: selection.range)
        if let cached = statsCache, cached.key == key { return cached.stats }
        let stats = computeSelectionStatistics(sheet: sheet)
        statsCache = (key, stats)
        return stats
    }

    /// The status bar asks on every redraw; the answer only changes with
    /// the selection or an edit.
    private struct StatsKey: Equatable {
        var revision: Int
        var sheetID: Int
        var range: CellRange
    }
    private var statsCache: (key: StatsKey, stats: SelectionStats)?

    private func computeSelectionStatistics(sheet: Sheet) -> SelectionStats {
        var stats = SelectionStats(count: 0, numericCount: 0, sum: 0)
        // Only the used part of the selection can hold values (a whole
        // column is a million addresses, mostly past the data).
        guard let used = sheet.usedRange, let range = Self.intersection(selection.range, used) else {
            return stats
        }
        // Cap the work (lookups or stored cells scanned) for enormous sheets.
        guard min(range.cellCount, sheet.cells.count) <= 4_000_000 else { return stats }
        // Like Excel's status bar, rows a filter hides are left out.
        let hidden = sheet.hiddenRows
        func add(_ cell: Cell) {
            if cell.value.isEmpty { return }
            stats.count += 1
            if case .number(let n) = cell.value {
                stats.numericCount += 1
                stats.sum += n
            }
        }
        // Look up the selected cells, or scan the stored ones, whichever is fewer.
        if range.cellCount < sheet.cells.count {
            for row in range.start.row...range.end.row where !hidden.contains(row) {
                for column in range.start.column...range.end.column {
                    if let cell = sheet.cells[CellAddress(row: row, column: column)] { add(cell) }
                }
            }
        } else {
            for (addr, cell) in sheet.cells where range.contains(addr) && !hidden.contains(addr.row) {
                add(cell)
            }
        }
        return stats
    }

    // MARK: - File I/O

    /// Save now, on this thread (tests and small documents; the app saves in
    /// the background, see BackgroundSaver).
    public func save(to url: URL) throws {
        let snapshot = makeSaveSnapshot()
        try Self.write(snapshot, to: url)
        didSave(snapshot, to: url)
    }

    /// The document as it is now, for writing on another thread while the
    /// user carries on: the typing still in an editor is committed first,
    /// and the workbook is copied (copy-on-write, so this is quick even for
    /// a million cells; the first edit afterwards pays for copying the
    /// sheet it changes).
    public func makeSaveSnapshot() -> SaveSnapshot {
        commitPendingEdit()
        return SaveSnapshot(workbook: workbook.copy(), changeCount: changeCount)
    }

    /// Write a snapshot as .xlsx (any thread). `progress` gets the fraction
    /// done; once `shouldContinue` says no, this throws `CancellationError`
    /// and leaves any file at `url` as it was (the file is replaced
    /// atomically, only once it is complete).
    nonisolated public static func write(_ snapshot: SaveSnapshot, to url: URL,
                                         progress: @escaping (Double) -> Void = { _ in },
                                         shouldContinue: @escaping () -> Bool = { true }) throws {
        let data: Data
        do {
            data = try XLSXWriter.data(for: snapshot.workbook) { fraction in
                progress(fraction)
                return shouldContinue()
            }
        } catch XLSXError.cancelled {
            throw CancellationError()
        }
        guard shouldContinue() else { throw CancellationError() }
        try data.write(to: url, options: .atomic)
    }

    /// A snapshot is on disk at `url`: the document now saves there, and it
    /// is unmodified unless it changed after the snapshot was taken.
    public func didSave(_ snapshot: SaveSnapshot, to url: URL) {
        didSave(changeCount: snapshot.changeCount, to: url)
    }

    /// As above, for the snapshot's `changeCount` (so the snapshot itself,
    /// perhaps by now the only owner of a million cells, can be freed on
    /// the saving thread rather than here).
    func didSave(changeCount savedChangeCount: Int, to url: URL) {
        fileURL = url
        suggestedFileName = nil
        isModified = changeCount != savedChangeCount
        unsupportedContentAccepted = true
    }

    public static func open(url: URL) throws -> SpreadsheetDocument {
        try make(from: load(url: url), url: url)
    }

    /// Read a file and build its calculation engine: the slow part of
    /// opening, safe to run off the main thread. `progress(fraction, phase)`
    /// reports along the way (nil fraction: no estimate); `shouldContinue`
    /// is polled, and a false answer throws `CancellationError`.
    nonisolated static func load(url: URL,
                                 progress: @escaping @Sendable (Double?, LoadPhase) -> Void = { _, _ in },
                                 shouldContinue: @escaping @Sendable () -> Bool = { true }) throws -> LoadedFile {
        // Mapped: a 2 GB CSV is read only as far as the row limit.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent
        let isTextImport = textImportExtensions.contains(ext)
        let workbook: Workbook
        var truncated = false
        var unsupported: [String] = []
        progress(0, .reading)
        if isTextImport {
            var report = CSVImportReport()
            workbook = CSV.importWorkbook(data: data, sheetName: baseName, report: &report) { fraction in
                progress(fraction, .reading)
                return shouldContinue()
            }
            if report.cancelled { throw CancellationError() }
            truncated = report.truncated
        } else {
            do {
                workbook = try XLSXReader.read(data: data, unsupportedContent: &unsupported) { fraction in
                    progress(fraction, .reading)
                    return shouldContinue()
                }
            } catch XLSXError.cancelled {
                throw CancellationError()
            }
        }
        guard shouldContinue() else { throw CancellationError() }
        progress(nil, .calculating)
        let engine = CalculationEngine(workbook: workbook)
        return LoadedFile(workbook: workbook, engine: engine, isTextImport: isTextImport, truncatedRows: truncated,
                          unsupportedContent: unsupported)
    }

    /// The document for a loaded file (main thread).
    static func make(from loaded: LoadedFile, url: URL) -> SpreadsheetDocument {
        let doc = SpreadsheetDocument(workbook: loaded.workbook, engine: loaded.engine)
        if loaded.isTextImport {
            // Delimited-text opens as an unsaved XLSX-native document: never
            // write back over the source file. Save-As pre-fills <base>.xlsx.
            doc.suggestedFileName = url.deletingPathExtension().lastPathComponent + ".xlsx"
        } else {
            doc.fileURL = url
            doc.unsupportedContent = loaded.unsupportedContent
        }
        if loaded.truncatedRows {
            // Excel's "File not loaded completely", in our words.
            doc.notice = DocumentNotice(
                message: "This file has more rows than a sheet can hold.",
                detail: "Only the first 1,048,576 rows were opened, as in Excel. "
                    + "Saving writes those rows to a new file; the original is not changed.")
        }
        return doc
    }

    /// Import a CSV file as a new sheet in this document.
    public func importCSVSheet(from url: URL) throws {
        importCSVSheet(try Self.readCSVSheet(from: url))
    }

    /// Read and parse a CSV file for `importCSVSheet` (any thread; the
    /// slow part). `progress` gets the fraction read; once `shouldContinue`
    /// says no, this throws `CancellationError`.
    nonisolated static func readCSVSheet(from url: URL,
                                         progress: @escaping (Double) -> Void = { _ in },
                                         shouldContinue: @escaping () -> Bool = { true }) throws -> ImportedCSV {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var report = CSVImportReport()
        let imported = CSV.importWorkbook(data: data,
                                          sheetName: url.deletingPathExtension().lastPathComponent,
                                          report: &report) { fraction in
            progress(fraction)
            return shouldContinue()
        }
        if report.cancelled { throw CancellationError() }
        return ImportedCSV(workbook: imported, truncated: report.truncated)
    }

    /// Add a CSV file read by `readCSVSheet` as a new sheet (main thread).
    func importCSVSheet(_ read: ImportedCSV) {
        registerWorkbookUndo(actionName: "Import CSV")
        let imported = read.workbook
        if read.truncated {
            notice = DocumentNotice(
                message: "This file has more rows than a sheet can hold.",
                detail: "Only the first 1,048,576 rows were imported, as in Excel.")
        }
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
        try Self.writeCSV(of: makeCSVExportSnapshot(), to: url)
    }

    /// The active sheet as it is now, for exporting on another thread.
    func makeCSVExportSnapshot() -> CSVExportSnapshot {
        commitPendingEdit()
        let copy = workbook.copy()
        return CSVExportSnapshot(workbook: copy, sheet: copy.sheet(withID: activeSheetID) ?? copy.sheets[0])
    }

    /// Write a sheet as CSV (any thread). Throws `CancellationError`, leaving
    /// any file at `url` as it was, once `shouldContinue` says no.
    nonisolated static func writeCSV(of snapshot: CSVExportSnapshot, to url: URL,
                                     shouldContinue: () -> Bool = { true }) throws {
        let data = CSV.export(sheet: snapshot.sheet, workbook: snapshot.workbook)
        guard shouldContinue() else { throw CancellationError() }
        try data.write(to: url, options: .atomic)
    }
}
