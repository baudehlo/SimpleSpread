import Foundation

/// Sheet state outside the cells that edits such as merging, filtering and
/// hiding rows change together; a value snapshot for undo.
public struct SheetLayoutState: Equatable, Sendable {
    public var mergedRanges: [CellRange]
    public var frozenRows: Int
    public var frozenColumns: Int
    public var hiddenRows: Set<Int>
    public var autoFilter: AutoFilter?
    public var rowHeights: [Int: CGFloat]
}

extension Sheet {
    public var layoutState: SheetLayoutState {
        get {
            SheetLayoutState(mergedRanges: mergedRanges, frozenRows: frozenRows,
                             frozenColumns: frozenColumns, hiddenRows: hiddenRows,
                             autoFilter: autoFilter, rowHeights: rowHeights)
        }
        set {
            mergedRanges = newValue.mergedRanges
            frozenRows = newValue.frozenRows
            frozenColumns = newValue.frozenColumns
            hiddenRows = newValue.hiddenRows
            autoFilter = newValue.autoFilter
            rowHeights = newValue.rowHeights
        }
    }

    // MARK: Merged cells

    /// The merged range covering `address`, if any.
    public func mergedRange(containing address: CellAddress) -> CellRange? {
        mergedRanges.first { $0.contains(address) }
    }

    /// Grow `range` until it cuts through no merged range (Excel never
    /// selects part of a merge).
    public func expandedForMerges(_ range: CellRange) -> CellRange {
        guard !mergedRanges.isEmpty else { return range }
        var result = range
        var changed = true
        while changed {
            changed = false
            for merge in mergedRanges where merge.intersects(result) {
                let grown = result.union(merge)
                if grown != result {
                    result = grown
                    changed = true
                }
            }
        }
        return result
    }

    /// True for the covered (non-top-left) cells of a merge, which never
    /// show content of their own.
    public func isHiddenByMerge(_ address: CellAddress) -> Bool {
        guard let merge = mergedRange(containing: address) else { return false }
        return merge.start != address
    }

    // MARK: Regions

    /// Excel's current region: the block around `address` bounded by empty
    /// rows and columns (diagonal neighbours count as connected).
    public func currentRegion(around address: CellAddress) -> CellRange {
        var region = CellRange(address)
        func hasData(_ row: Int, _ columns: ClosedRange<Int>) -> Bool {
            guard row >= 0 else { return false }
            return columns.contains { !value(at: CellAddress(row: row, column: $0)).isEmpty }
        }
        func hasData(column: Int, _ rows: ClosedRange<Int>) -> Bool {
            guard column >= 0 else { return false }
            return rows.contains { !value(at: CellAddress(row: $0, column: column)).isEmpty }
        }
        var changed = true
        while changed {
            changed = false
            let rows = max(0, region.start.row - 1)...(region.end.row + 1)
            let columns = max(0, region.start.column - 1)...(region.end.column + 1)
            if region.start.row > 0, hasData(region.start.row - 1, columns) {
                region.start.row -= 1; changed = true
            }
            if hasData(region.end.row + 1, columns) {
                region.end.row += 1; changed = true
            }
            if region.start.column > 0, hasData(column: region.start.column - 1, rows) {
                region.start.column -= 1; changed = true
            }
            if hasData(column: region.end.column + 1, rows) {
                region.end.column += 1; changed = true
            }
        }
        return region
    }
}
