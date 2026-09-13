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
    @Published public var fileURL: URL?
    @Published public private(set) var isModified = false
    /// Incremented whenever cell content/layout changes; grid views observe it.
    @Published public private(set) var revision = 0

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
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

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

    private func markChanged() {
        isModified = true
        revision += 1
    }

    private struct CellSnapshot {
        let sheetID: Int
        let address: CellAddress
        let cell: Cell
    }

    private func snapshot(_ addresses: [CellAddress], sheetID: Int? = nil) -> [CellSnapshot] {
        let id = sheetID ?? activeSheetID
        guard let sheet = workbook.sheet(withID: id) else { return [] }
        return addresses.map { CellSnapshot(sheetID: id, address: $0, cell: sheet.cell(at: $0)) }
    }

    /// Wrap a registration in its own undo group so each operation is one
    /// undo step even when several happen in one run-loop turn (tests, macros).
    private func withUndoGroup(_ body: () -> Void) {
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        body()
        if grouping { undoManager.endUndoGrouping() }
    }

    private func registerCellUndo(_ snapshots: [CellSnapshot], actionName: String) {
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

    private func restore(_ snapshots: [CellSnapshot]) {
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
    private func registerWorkbookUndo(actionName: String) {
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

    /// Move sheets/styles from another workbook instance into ours in place.
    /// Sheets get fresh ids (avoiding collisions with the placeholder).
    private func replaceWorkbookContents(with other: Workbook) {
        while workbook.sheets.count > 1 {
            workbook.removeSheet(withID: workbook.sheets[workbook.sheets.count - 1].id)
        }
        let placeholder = workbook.sheets[0]
        placeholder.name = "\u{1}__restore_placeholder__"
        for source in other.sheets {
            let fresh = workbook.addSheet(named: source.name)
            fresh.adoptContents(of: source)
        }
        workbook.removeSheet(withID: placeholder.id)
        workbook.styles = other.styles
        engine.rebuildAll()
    }

    // MARK: - Editing

    /// Commit raw typed input into a cell (the shared parsing pipeline).
    public func commitInput(_ text: String, at address: CellAddress) {
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

    public func setNumberFormat(_ format: NumberFormat) {
        applyStyleToSelection("Number Format") { $0.numberFormat = format }
    }

    public func setHorizontalAlignment(_ alignment: TextAlignmentH) {
        applyStyleToSelection("Alignment") { $0.horizontalAlignment = alignment }
    }

    // MARK: - Structure

    public func insertRows(at index: Int, count: Int = 1) {
        registerWorkbookUndo(actionName: "Insert Rows")
        WorkbookOperations.insertRows(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        markChanged()
    }

    public func deleteRows(at index: Int, count: Int = 1) {
        registerWorkbookUndo(actionName: "Delete Rows")
        WorkbookOperations.deleteRows(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        selection.select(CellAddress(row: min(index, max(0, GridLayout(sheet: activeSheet).rowCount - 1)),
                                     column: selection.activeCell.column))
        markChanged()
    }

    public func insertColumns(at index: Int, count: Int = 1) {
        registerWorkbookUndo(actionName: "Insert Columns")
        WorkbookOperations.insertColumns(in: workbook, sheetID: activeSheetID, at: index, count: count)
        engine.rebuildAll()
        markChanged()
    }

    public func deleteColumns(at index: Int, count: Int = 1) {
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
            entries.append(ClipboardPayload.Entry(
                rowOffset: addr.row - range.start.row,
                columnOffset: addr.column - range.start.column,
                cell: cell,
                style: workbook.style(at: cell.styleIndex)))
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
            styleWrites.append((addr, srcCell.styleIndex))
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
        for (addr, cell) in activeSheet.cells where range.contains(addr) {
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
        isModified = false
    }

    public static func open(url: URL) throws -> SpreadsheetDocument {
        let data = try Data(contentsOf: url)
        let workbook: Workbook
        if url.pathExtension.lowercased() == "csv" {
            workbook = CSV.importWorkbook(data: data,
                                          sheetName: url.deletingPathExtension().lastPathComponent)
        } else {
            workbook = try XLSXReader.read(data: data)
        }
        let doc = SpreadsheetDocument(workbook: workbook)
        // CSV opens as an unsaved xlsx-native document.
        if url.pathExtension.lowercased() != "csv" {
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
