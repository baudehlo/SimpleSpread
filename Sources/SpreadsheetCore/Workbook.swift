import Foundation

/// One cell's stored state. `value` is the computed/stored value; `formula`
/// (when present) is the formula text without the leading '='.
public struct Cell: Equatable, Sendable {
    public var value: CellValue
    public var formula: String?
    public var styleIndex: Int

    public init(value: CellValue = .empty, formula: String? = nil, styleIndex: Int = 0) {
        self.value = value
        self.formula = formula
        self.styleIndex = styleIndex
    }

    /// True when the cell carries no information and can be dropped from storage.
    public var isDefault: Bool { value.isEmpty && formula == nil && styleIndex == 0 }
}

/// A single worksheet: sparse cell storage plus layout metadata.
public final class Sheet {
    /// Stable identity that survives renames and reordering.
    public let id: Int
    public var name: String
    public internal(set) var cells: [CellAddress: Cell] = [:]

    /// Explicit column widths in points, keyed by zero-based column index.
    public var columnWidths: [Int: CGFloat] = [:]
    /// Explicit row heights in points, keyed by zero-based row index.
    public var rowHeights: [Int: CGFloat] = [:]
    public var defaultColumnWidth: CGFloat = 100
    public var defaultRowHeight: CGFloat = 22
    public var frozenRows: Int = 0
    public var frozenColumns: Int = 0
    public var mergedRanges: [CellRange] = []

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    public func cell(at address: CellAddress) -> Cell {
        cells[address] ?? Cell()
    }

    public func setCell(_ cell: Cell, at address: CellAddress) {
        if cell.isDefault {
            cells.removeValue(forKey: address)
        } else {
            cells[address] = cell
        }
    }

    public func value(at address: CellAddress) -> CellValue {
        cells[address]?.value ?? .empty
    }

    /// Bounding range of all non-default cells, or nil for an empty sheet.
    public var usedRange: CellRange? {
        guard !cells.isEmpty else { return nil }
        var minR = Int.max, maxR = Int.min, minC = Int.max, maxC = Int.min
        for addr in cells.keys {
            minR = min(minR, addr.row); maxR = max(maxR, addr.row)
            minC = min(minC, addr.column); maxC = max(maxC, addr.column)
        }
        return CellRange(start: CellAddress(row: minR, column: minC),
                         end: CellAddress(row: maxR, column: maxC))
    }

    public func columnWidth(_ column: Int) -> CGFloat {
        columnWidths[column] ?? defaultColumnWidth
    }

    public func rowHeight(_ row: Int) -> CGFloat {
        rowHeights[row] ?? defaultRowHeight
    }
}

/// A spreadsheet document model: ordered sheets plus a shared style table.
public final class Workbook {
    public private(set) var sheets: [Sheet] = []
    public var styles = StyleTable()
    private var nextSheetID = 1

    public init() {}

    /// A new workbook with one empty sheet.
    public static func newDocument() -> Workbook {
        let wb = Workbook()
        wb.addSheet()
        return wb
    }

    public func sheet(withID id: Int) -> Sheet? {
        sheets.first { $0.id == id }
    }

    public func sheet(named name: String) -> Sheet? {
        sheets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func indexOfSheet(withID id: Int) -> Int? {
        sheets.firstIndex { $0.id == id }
    }

    @discardableResult
    public func addSheet(named name: String? = nil) -> Sheet {
        let sheetName = name.map(uniqueSheetName(from:)) ?? nextDefaultSheetName()
        let sheet = Sheet(id: nextSheetID, name: sheetName)
        nextSheetID += 1
        sheets.append(sheet)
        return sheet
    }

    @discardableResult
    public func insertSheet(_ sheet: Sheet, at index: Int) -> Sheet {
        nextSheetID = max(nextSheetID, sheet.id + 1)
        sheets.insert(sheet, at: min(max(0, index), sheets.count))
        return sheet
    }

    /// Remove a sheet; refuses to remove the last one.
    @discardableResult
    public func removeSheet(withID id: Int) -> Sheet? {
        guard sheets.count > 1, let idx = indexOfSheet(withID: id) else { return nil }
        return sheets.remove(at: idx)
    }

    public func moveSheet(withID id: Int, to newIndex: Int) {
        guard let idx = indexOfSheet(withID: id) else { return }
        let sheet = sheets.remove(at: idx)
        sheets.insert(sheet, at: min(max(0, newIndex), sheets.count))
    }

    /// Rename a sheet, enforcing uniqueness and XLSX name constraints.
    /// Returns the actual name applied, or nil if the sheet wasn't found.
    @discardableResult
    public func renameSheet(withID id: Int, to newName: String) -> String? {
        guard let sheet = sheet(withID: id) else { return nil }
        let sanitized = Workbook.sanitizeSheetName(newName)
        guard !sanitized.isEmpty else { return sheet.name }
        if sanitized.caseInsensitiveCompare(sheet.name) == .orderedSame {
            sheet.name = sanitized
            return sanitized
        }
        let unique = uniqueSheetName(from: sanitized)
        sheet.name = unique
        return unique
    }

    /// Strip characters XLSX forbids in sheet names and clamp to 31 chars.
    public static func sanitizeSheetName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: ":\\/?*[]")
        let cleaned = name.unicodeScalars.filter { !forbidden.contains($0) }
        var result = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > 31 { result = String(result.prefix(31)) }
        return result
    }

    private func nextDefaultSheetName() -> String {
        var n = sheets.count + 1
        while sheet(named: "Sheet\(n)") != nil { n += 1 }
        return "Sheet\(n)"
    }

    private func uniqueSheetName(from base: String) -> String {
        let sanitized = Workbook.sanitizeSheetName(base)
        let effective = sanitized.isEmpty ? "Sheet" : sanitized
        if sheet(named: effective) == nil { return effective }
        var n = 2
        while true {
            let suffix = " \(n)"
            let trimmed = String(effective.prefix(31 - suffix.count))
            let candidate = trimmed + suffix
            if sheet(named: candidate) == nil { return candidate }
            n += 1
        }
    }

    // MARK: Style helpers

    public func style(at index: Int) -> CellStyle {
        styles[index]
    }

    public func styleIndex(for style: CellStyle) -> Int {
        styles.index(for: style)
    }

    /// Apply a mutation to the style of every cell in a range (creating cells
    /// as needed so formatting sticks on empty cells).
    public func modifyStyle(in range: CellRange, ofSheetID sheetID: Int, _ mutate: (inout CellStyle) -> Void) {
        guard let sheet = sheet(withID: sheetID) else { return }
        range.forEachAddress { addr in
            var cell = sheet.cell(at: addr)
            var style = styles[cell.styleIndex]
            mutate(&style)
            cell.styleIndex = styles.index(for: style)
            sheet.setCell(cell, at: addr)
        }
    }
}
