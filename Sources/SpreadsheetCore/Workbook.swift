import Foundation

/// One cell's stored state. `value` is the computed/stored value; `formula`
/// (when present) is the formula text without the leading '='.
public struct Cell: Equatable, Sendable, Codable {
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
    /// Sparse storage. Assigning it wholesale (structural remaps) drops the
    /// cached used bounds; `setCell` keeps them up to date.
    public internal(set) var cells: [CellAddress: Cell] {
        get { storage }
        set {
            storage = newValue
            cellsVersion &+= 1
            invalidateUsedBounds()
        }
    }
    private var storage: [CellAddress: Cell] = [:]
    /// Bumped whenever `storage` changes, so an undo snapshot can tell
    /// whether a command touched this sheet's cells (WorkbookSnapshot).
    private(set) var cellsVersion = 0
    /// Cached bounding box of `storage`; meaningful only when `boundsValid`.
    private var bounds: CellRange?
    private var boundsValid = true

    /// Explicit column widths in points, keyed by zero-based column index.
    public var columnWidths: [Int: CGFloat] = [:]
    /// Explicit row heights in points, keyed by zero-based row index.
    public var rowHeights: [Int: CGFloat] = [:]
    public var defaultColumnWidth: CGFloat = 100
    public var defaultRowHeight: CGFloat = 22
    public var frozenRows: Int = 0
    public var frozenColumns: Int = 0
    public var mergedRanges: [CellRange] = []
    /// Rows hidden by hand or by the AutoFilter (XLSX `row@hidden`).
    public var hiddenRows: Set<Int> = []
    public var autoFilter: AutoFilter?
    /// Hidden in Excel (XLSX `sheet@state` "hidden" or "veryHidden"); kept
    /// so a save writes it back.
    public var isHidden = false

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    public func cell(at address: CellAddress) -> Cell {
        storage[address] ?? Cell()
    }

    public func setCell(_ cell: Cell, at address: CellAddress) {
        if cell.isDefault {
            guard storage.removeValue(forKey: address) != nil else { return }
            cellsVersion &+= 1
            if storage.isEmpty {
                bounds = nil
                boundsValid = true
            } else if boundsValid, let b = bounds,
                      address.row == b.start.row || address.row == b.end.row
                      || address.column == b.start.column || address.column == b.end.column {
                // A cell on the edge went: the box may shrink. Rescan lazily.
                boundsValid = false
            }
        } else {
            storage[address] = cell
            cellsVersion &+= 1
            if boundsValid {
                if let b = bounds {
                    if !b.contains(address) {
                        bounds = CellRange(
                            start: CellAddress(row: min(b.start.row, address.row),
                                               column: min(b.start.column, address.column)),
                            end: CellAddress(row: max(b.end.row, address.row),
                                             column: max(b.end.column, address.column)))
                    }
                } else {
                    bounds = CellRange(address)
                }
            }
        }
    }

    /// Drop every cell (a reader starting a sheet over).
    public func removeAllCells() {
        cells = [:]
    }

    /// Make room for `count` cells up front (bulk imports).
    public func reserveCellCapacity(_ count: Int) {
        storage.reserveCapacity(count)
    }

    public func value(at address: CellAddress) -> CellValue {
        storage[address]?.value ?? .empty
    }

    /// Bounding range of all non-default cells, or nil for an empty sheet.
    /// Kept up to date by `setCell`; a rescan happens only after a cell on the
    /// edge is removed or the storage is replaced, and then once.
    public var usedRange: CellRange? {
        if !boundsValid {
            bounds = Self.scanBounds(storage)
            boundsValid = true
        }
        return bounds
    }

    private func invalidateUsedBounds() {
        if storage.isEmpty {
            bounds = nil
            boundsValid = true
        } else {
            boundsValid = false
        }
    }

    private static func scanBounds(_ cells: [CellAddress: Cell]) -> CellRange? {
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

    /// Copy all content and layout (but not id/name) from another sheet.
    public func adoptContents(of other: Sheet) {
        cells = other.cells
        columnWidths = other.columnWidths
        rowHeights = other.rowHeights
        defaultColumnWidth = other.defaultColumnWidth
        defaultRowHeight = other.defaultRowHeight
        frozenRows = other.frozenRows
        frozenColumns = other.frozenColumns
        mergedRanges = other.mergedRanges
        hiddenRows = other.hiddenRows
        autoFilter = other.autoFilter
        isHidden = other.isHidden
    }

    /// An independent copy with the same id and name. Cheap: the cell table
    /// and the other collections are copy-on-write, so nothing is duplicated
    /// until one of the two sheets changes. For undo snapshots and saving in
    /// the background.
    public func copy() -> Sheet {
        let sheet = Sheet(id: id, name: name)
        sheet.adoptContents(of: self)
        sheet.adoptCells(of: self)
        return sheet
    }

    /// Share another sheet's cell table (copy-on-write), keeping its
    /// used-range cache rather than rescanning, and its `cellsVersion`.
    func adoptCells(of other: Sheet) {
        storage = other.storage
        bounds = other.bounds
        boundsValid = other.boundsValid
        cellsVersion = other.cellsVersion
    }
}

/// A spreadsheet document model: ordered sheets plus a shared style table.
public final class Workbook {
    public private(set) var sheets: [Sheet] = []
    public var styles = StyleTable()
    /// Pivot caches and tables preserved from an opened file (see PivotTables.swift).
    public var pivotCaches: [PivotCache] = []
    public var pivotTables: [PivotTable] = []
    /// Stylesheet entries the preserved pivot parts refer to; nil without pivots.
    public var preservedStyles: PreservedStyles?
    /// Defined names (XLSX `<definedNames>`), including Excel's built-in
    /// `_xlnm.*` ones (print areas and titles), kept in file order.
    public var definedNames: [DefinedName] = [] {
        didSet { definedNameCache = nil }
    }
    /// What an opened file holds beyond the model (charts, comments, …),
    /// written back on save; nil for none (CarriedContent.swift).
    public var carriedContent: (any CarriedContent)?
    /// Lookup table and parsed formulas for `definedNames` (DefinedNames.swift).
    var definedNameCache: DefinedNameCache?
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

    /// An independent copy of the whole workbook (sheets keep their ids).
    /// Cheap, as `Sheet.copy()` is: the large tables are shared until changed.
    public func copy() -> Workbook {
        let wb = Workbook()
        wb.sheets = sheets.map { $0.copy() }
        wb.styles = styles
        wb.pivotCaches = pivotCaches
        wb.pivotTables = pivotTables
        wb.preservedStyles = preservedStyles
        wb.definedNames = definedNames
        wb.carriedContent = carriedContent
        wb.nextSheetID = nextSheetID
        return wb
    }

    /// Take over another workbook's sheets (keeping their ids), styles,
    /// pivot tables and carried content, in place: for restoring a snapshot under objects (the
    /// engine, undo records) that hold this instance and its sheet ids.
    public func replaceContents(with other: Workbook) {
        sheets = other.sheets
        nextSheetID = max(nextSheetID, (sheets.map(\.id).max() ?? 0) + 1)
        styles = other.styles
        pivotCaches = other.pivotCaches
        pivotTables = other.pivotTables
        preservedStyles = other.preservedStyles
        definedNames = other.definedNames
        carriedContent = other.carriedContent
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
        // Excel also forbids a leading or trailing apostrophe.
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'"))
        var result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: edges)
        if result.count > 31 { result = String(result.prefix(31)).trimmingCharacters(in: edges) }
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
