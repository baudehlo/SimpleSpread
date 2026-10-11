import Foundation

// Pivot tables carried through from an opened XLSX file.
//
// SimpleSpread doesn't compute pivot tables. It keeps their definitions so a
// save hands them back to Excel intact: the XML parts ride along as opaque
// payloads (SpreadsheetFiles owns their format), while the few facts that
// edits elsewhere in the workbook can invalidate — where a table sits, which
// ranges feed its cache — live here as typed values that WorkbookOperations
// keeps current. The cells a pivot table renders are ordinary cells.

/// Format-specific data a preserved part carries. Core never looks inside.
public protocol PreservedPartPayload: Sendable {}

/// One range a pivot cache reads its data from.
public struct PivotSourceRange: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// A sheet in this workbook; follows renames, row/column edits.
        case sheet(id: Int)
        /// The source no longer exists here (its sheet was deleted, or its
        /// rows/columns were). Written back as last known so the pivot still
        /// loads from its cache; only a refresh in Excel would fail.
        case detached(sheetName: String)
        /// A range in another workbook; carried verbatim.
        case external
    }

    public var target: Target
    /// The A1 reference as stored in the file, without a sheet prefix
    /// ("A1:D20", "$A:$D").
    public var ref: String

    public init(target: Target, ref: String) {
        self.target = target
        self.ref = ref
    }
}

/// A pivot cache: the snapshot of source data one or more pivot tables share.
public struct PivotCache: Sendable {
    /// The workbook-wide cache id pivot tables refer to (kept as read).
    public let cacheID: Int
    /// Source ranges in document order (one for a worksheet source, one per
    /// range set for a consolidation).
    public var sourceRanges: [PivotSourceRange]
    public var payload: any PreservedPartPayload

    public init(cacheID: Int, sourceRanges: [PivotSourceRange], payload: any PreservedPartPayload) {
        self.cacheID = cacheID
        self.sourceRanges = sourceRanges
        self.payload = payload
    }

    /// True when any source range no longer points at live data.
    public var hasDetachedSource: Bool {
        sourceRanges.contains { if case .detached = $0.target { return true } else { return false } }
    }
}

/// A pivot table placed on a sheet.
public struct PivotTable: Sendable {
    public var sheetID: Int
    public let name: String
    public let cacheID: Int
    /// The table body (`<location ref>`), excluding the report filter area.
    public var location: CellRange
    /// Rows and columns the report filters occupy above the body.
    public var pageFieldRows: Int
    public var pageFieldColumns: Int
    public var payload: any PreservedPartPayload

    public init(sheetID: Int, name: String, cacheID: Int, location: CellRange,
                pageFieldRows: Int = 0, pageFieldColumns: Int = 0,
                payload: any PreservedPartPayload) {
        self.sheetID = sheetID
        self.name = name
        self.cacheID = cacheID
        self.location = location
        self.pageFieldRows = max(0, pageFieldRows)
        self.pageFieldColumns = max(0, pageFieldColumns)
        self.payload = payload
    }

    /// Every cell the pivot table draws into: the body plus, when it has
    /// report filters, the filter block Excel lays out above it (one row per
    /// filter, a blank row, then the body; each filter column is a label and
    /// a value cell, with a blank column between filter columns).
    public var occupiedRange: CellRange {
        guard pageFieldRows > 0, location.start.row > 0 else { return location }
        let top = max(0, location.start.row - pageFieldRows - 1)
        let columns = max(1, pageFieldColumns) * 3 - 1
        let right = min(CellAddress.maxColumns - 1, location.start.column + columns - 1)
        let filters = CellRange(start: CellAddress(row: top, column: location.start.column),
                                end: CellAddress(row: location.start.row - 1, column: right))
        return location.union(filters)
    }
}

/// Stylesheet entries preserved parts refer to by id or position. Kept so
/// those references stay valid without rewriting the parts.
public struct PreservedStyles: Equatable, Sendable {
    /// Custom number formats (id >= 164) by their original ids, which the
    /// writer keeps; its own custom formats are numbered above them.
    public var numberFormats: [Int: String]
    /// Raw `<dxf>` elements in original order (a dxfId is a position).
    public var differentialFormats: [String]
    /// Custom numFmt ids used inside those dxfs. Excel never reuses them for
    /// other formats, so the writer numbers its own above them too.
    public var reservedNumberFormatIDs: Set<Int>
    /// The raw `<tableStyles>` element (custom pivot styles live there).
    public var tableStyles: String?

    public init(numberFormats: [Int: String] = [:], differentialFormats: [String] = [],
                reservedNumberFormatIDs: Set<Int> = [], tableStyles: String? = nil) {
        self.numberFormats = numberFormats
        self.differentialFormats = differentialFormats
        self.reservedNumberFormatIDs = reservedNumberFormatIDs
        self.tableStyles = tableStyles
    }
}

extension Workbook {
    public func pivotTables(onSheet sheetID: Int) -> [PivotTable] {
        pivotTables.filter { $0.sheetID == sheetID }
    }

    /// Pivot tables on a sheet whose drawn area overlaps `range`.
    public func pivotTables(intersecting range: CellRange, onSheet sheetID: Int) -> [PivotTable] {
        pivotTables.filter { $0.sheetID == sheetID && $0.occupiedRange.intersects(range) }
    }

    public func pivotCache(withID id: Int) -> PivotCache? {
        pivotCaches.first { $0.cacheID == id }
    }

    /// Remove pivot tables, then any cache no table uses any more (Excel
    /// drops unused caches itself; an orphan isn't worth the risk).
    public func removePivotTables(where shouldRemove: (PivotTable) -> Bool) {
        pivotTables.removeAll(where: shouldRemove)
        pruneUnusedPivotCaches()
        clearStrayPivotButtons()
    }

    /// Clear the pivot field-button flag from cells outside every remaining
    /// pivot table (a button with no pivot behind it means nothing to Excel).
    public func clearStrayPivotButtons() {
        guard styles.styles.contains(where: \.pivotButton) else { return }
        for sheet in sheets {
            let areas = pivotTables(onSheet: sheet.id).map(\.occupiedRange)
            for (address, cell) in sheet.cells where styles[cell.styleIndex].pivotButton {
                guard !areas.contains(where: { $0.contains(address) }) else { continue }
                var style = styles[cell.styleIndex]
                style.pivotButton = false
                var updated = cell
                updated.styleIndex = styles.index(for: style)
                sheet.setCell(updated, at: address)
            }
        }
    }

    func pruneUnusedPivotCaches() {
        let used = Set(pivotTables.map(\.cacheID))
        pivotCaches.removeAll { !used.contains($0.cacheID) }
        if pivotCaches.isEmpty { preservedStyles = nil }
    }
}
