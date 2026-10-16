import Foundation
import SpreadsheetCore

/// A chart's reference to cells (a `c:f`), followed once: the one place
/// that reads a chart's cells, so what is drawn, what is cached in the
/// file and what the Chart panel shows agree.
///
/// Followed: `Sheet1!$A$1:$A$9`, unions of those (`(A,B)`), and defined
/// names of this workbook that stand for one (`Book1.xlsx!Sales`,
/// `Sheet1!Sales`, `[0]!Sales`). Not followed: other workbooks (`[1]…`),
/// and names that compute their range (OFFSET, INDEX…); a chart falls
/// back to its cached values for those.
public struct ChartReference: Hashable, Sendable {
    /// As written, without a leading `=`.
    public let formula: String
    /// The blocks it covers, in order; nil when it can't be followed.
    public let areas: [ChartRange]?

    public init(_ formula: String, in workbook: Workbook) {
        var text = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("=") { text.removeFirst() }
        self.formula = text
        if text.hasPrefix("("), text.hasSuffix(")") { text = String(text.dropFirst().dropLast()) }
        var areas: [ChartRange] = []
        for piece in Self.splitTopLevel(text) {
            guard let area = Self.resolve(piece, in: workbook) else {
                self.areas = nil
                return
            }
            areas.append(area)
        }
        self.areas = areas.isEmpty ? nil : areas
    }

    public var isFollowed: Bool { areas != nil }

    private static func resolve(_ piece: String, in workbook: Workbook) -> ChartRange? {
        var text = piece.trimmingCharacters(in: .whitespaces)
        // [0] is this workbook; any other book is another file.
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]"), text[text.index(after: text.startIndex)..<close] == "0" else {
                return nil
            }
            text = String(text[text.index(after: close)...])
            if text.hasPrefix("!") { text.removeFirst() }
        }
        if let range = ChartRange(formula: text), let sheet = workbook.sheet(named: range.sheetName) {
            return ChartRange(sheetName: sheet.name, range: clamped(range.range))
        }
        // A defined name, perhaps after the workbook's or a sheet's name.
        var name = text
        var scope: Sheet?
        if let bang = text.lastIndex(of: "!") {
            var qualifier = String(text[..<bang])
            if qualifier.hasPrefix("'"), qualifier.hasSuffix("'"), qualifier.count >= 2 {
                qualifier = String(qualifier.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            scope = workbook.sheet(named: qualifier)
            name = String(text[text.index(after: bang)...])
        }
        guard !name.isEmpty, case .reference(let ref)? = workbook.definedNameFormula(name, sheetID: scope?.id),
              let sheetName = ref.sheetName ?? scope?.name, let sheet = workbook.sheet(named: sheetName),
              let r1 = ref.start.row, let c1 = ref.start.column else { return nil }
        let end = ref.end ?? ref.start
        guard let r2 = end.row, let c2 = end.column else { return nil }
        return ChartRange(sheetName: sheet.name, range: clamped(CellRange(
            start: CellAddress(row: min(r1, r2), column: min(c1, c2)),
            end: CellAddress(row: max(r1, r2), column: max(c1, c2)))))
    }

    private static func clamped(_ range: CellRange) -> CellRange {
        func clamp(_ a: CellAddress) -> CellAddress {
            CellAddress(row: min(max(0, a.row), CellAddress.maxRows - 1),
                        column: min(max(0, a.column), CellAddress.maxColumns - 1))
        }
        return CellRange(start: clamp(range.start), end: clamp(range.end))
    }

    /// Split at commas outside quotes.
    static func splitTopLevel(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        for ch in text {
            if ch == "'" { quoted.toggle() }
            if ch == ",", !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        pieces.append(current)
        return pieces.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Reading the cells

    /// One block's cells, clipped to the data on its sheet (nothing past
    /// the last used row or column: a whole-column reference reads only
    /// as far as the data goes), and without hidden rows and columns when
    /// `visibleOnly` (Excel's "plot visible cells only").
    struct Block {
        let sheet: Sheet
        let rows: [Int]
        let columns: [Int]
    }

    func blocks(in workbook: Workbook, visibleOnly: Bool) -> [Block]? {
        guard let areas else { return nil }
        return areas.compactMap { area in
            guard let sheet = workbook.sheet(named: area.sheetName) else { return nil }
            guard let used = sheet.usedRange else { return Block(sheet: sheet, rows: [], columns: []) }
            let r = area.range
            let lastRow = min(r.end.row, used.end.row), lastColumn = min(r.end.column, used.end.column)
            let rows = r.start.row <= lastRow
                ? (r.start.row...lastRow).filter { !(visibleOnly && sheet.hiddenRows.contains($0)) } : []
            let columns = r.start.column <= lastColumn
                ? (r.start.column...lastColumn).filter { !(visibleOnly && sheet.hiddenColumns.contains($0)) } : []
            return Block(sheet: sheet, rows: rows, columns: columns)
        }
    }

    /// The cells' values, rows then columns; nil when it can't be followed.
    public func values(in workbook: Workbook, visibleOnly: Bool = true) -> [CellValue]? {
        guard let blocks = blocks(in: workbook, visibleOnly: visibleOnly) else { return nil }
        var result: [CellValue] = []
        for block in blocks {
            result.reserveCapacity(result.count + block.rows.count * block.columns.count)
            for row in block.rows {
                for column in block.columns { result.append(block.sheet.value(at: CellAddress(row: row, column: column))) }
            }
        }
        return result
    }

    /// The cells as numbers (nil for a blank or text cell; TRUE is 1).
    public func numbers(in workbook: Workbook, visibleOnly: Bool = true) -> [Double?]? {
        values(in: workbook, visibleOnly: visibleOnly)?.map { value in
            switch value {
            case .number(let n): n.isFinite ? n : nil
            case .bool(let b): b ? 1 : 0
            default: nil
            }
        }
    }

    /// The cells as labels, shown with their number formats: one per
    /// column of a block one row high, else one per row (a block several
    /// columns wide joins them, as Excel's multi-level labels read).
    public func labels(in workbook: Workbook, visibleOnly: Bool = true) -> [String]? {
        guard let blocks = blocks(in: workbook, visibleOnly: visibleOnly) else { return nil }
        var result: [String] = []
        for block in blocks {
            func display(_ row: Int, _ column: Int) -> String {
                let address = CellAddress(row: row, column: column)
                let value = block.sheet.value(at: address)
                switch value {
                case .empty: return ""
                case .string(let s): return s
                default:
                    let format = workbook.style(at: block.sheet.styleIndex(at: address)).numberFormat
                    return NumberFormatEngine.displayString(for: value, format: format)
                }
            }
            if block.rows.count == 1, let row = block.rows.first {
                result += block.columns.map { display(row, $0) }
            } else {
                for row in block.rows {
                    if block.columns.count == 1 {
                        result.append(display(row, block.columns[0]))
                    } else {
                        result.append(block.columns.map { display(row, $0) }.filter { !$0.isEmpty }.joined(separator: " "))
                    }
                }
            }
        }
        return result
    }

    /// The cells as one piece of text (a series name or a title).
    public func text(in workbook: Workbook) -> String? {
        labels(in: workbook, visibleOnly: false)?.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The number format of the first cell (for a numCache's formatCode).
    func formatCode(in workbook: Workbook) -> String {
        guard let area = areas?.first, let sheet = workbook.sheet(named: area.sheetName) else { return "General" }
        let code = workbook.style(at: sheet.styleIndex(at: area.range.start)).numberFormat.code
        return code.isEmpty ? "General" : code
    }

    /// Whether every cell it reads is a number (categories cached as numbers).
    func isNumeric(in workbook: Workbook, visibleOnly: Bool) -> Bool {
        guard let values = values(in: workbook, visibleOnly: visibleOnly), !values.isEmpty else { return false }
        return values.allSatisfy { if case .number = $0 { return true }; return false }
    }
}
