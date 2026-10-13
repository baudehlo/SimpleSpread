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

/// What one command changed in a sheet's layout, for undo. Applying it (or
/// its inverse) touches only those parts: rows hidden or shown, heights
/// set, merges added or removed, and the filter or panes if they changed.
/// Restoring a whole `SheetLayoutState` instead would also revert changes
/// made after the command that have no undo step of their own.
public struct SheetLayoutChange: Sendable {
    public var mergesAdded: [CellRange] = []
    public var mergesRemoved: [CellRange] = []
    public var hiddenAdded: Set<Int> = []
    public var hiddenRemoved: Set<Int> = []
    /// Row -> (old, new) explicit height.
    public var rowHeights: [Int: (old: CGFloat?, new: CGFloat?)] = [:]
    public var frozen: (old: (rows: Int, columns: Int), new: (rows: Int, columns: Int))?
    public var autoFilter: (old: AutoFilter?, new: AutoFilter?)?

    public init(from old: SheetLayoutState, to new: SheetLayoutState) {
        mergesAdded = new.mergedRanges.filter { !old.mergedRanges.contains($0) }
        mergesRemoved = old.mergedRanges.filter { !new.mergedRanges.contains($0) }
        if old.hiddenRows != new.hiddenRows {
            hiddenAdded = new.hiddenRows.subtracting(old.hiddenRows)
            hiddenRemoved = old.hiddenRows.subtracting(new.hiddenRows)
        }
        if old.rowHeights != new.rowHeights {
            for row in Set(old.rowHeights.keys).union(new.rowHeights.keys)
            where old.rowHeights[row] != new.rowHeights[row] {
                rowHeights[row] = (old.rowHeights[row], new.rowHeights[row])
            }
        }
        if old.frozenRows != new.frozenRows || old.frozenColumns != new.frozenColumns {
            frozen = ((old.frozenRows, old.frozenColumns), (new.frozenRows, new.frozenColumns))
        }
        if old.autoFilter != new.autoFilter {
            autoFilter = (old.autoFilter, new.autoFilter)
        }
    }

    public var isEmpty: Bool {
        mergesAdded.isEmpty && mergesRemoved.isEmpty && hiddenAdded.isEmpty && hiddenRemoved.isEmpty
            && rowHeights.isEmpty && frozen == nil && autoFilter == nil
    }

    /// The change that undoes this one.
    public var inverse: SheetLayoutChange {
        var result = self
        result.mergesAdded = mergesRemoved
        result.mergesRemoved = mergesAdded
        result.hiddenAdded = hiddenRemoved
        result.hiddenRemoved = hiddenAdded
        result.rowHeights = rowHeights.mapValues { ($0.new, $0.old) }
        result.frozen = frozen.map { ($0.new, $0.old) }
        result.autoFilter = autoFilter.map { ($0.new, $0.old) }
        return result
    }

    public func apply(to sheet: Sheet) {
        if !mergesRemoved.isEmpty {
            sheet.mergedRanges.removeAll { mergesRemoved.contains($0) }
        }
        sheet.mergedRanges.append(contentsOf: mergesAdded.filter { !sheet.mergedRanges.contains($0) })
        sheet.hiddenRows.subtract(hiddenRemoved)
        sheet.hiddenRows.formUnion(hiddenAdded)
        for (row, height) in rowHeights {
            sheet.rowHeights[row] = height.new
        }
        if let frozen {
            sheet.frozenRows = frozen.new.rows
            sheet.frozenColumns = frozen.new.columns
        }
        if let autoFilter {
            sheet.autoFilter = autoFilter.new
        }
    }
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
    ///
    /// Each side grows as far as it can before the next side is tried, and
    /// a side is only rescanned over the rows (or columns) added since it
    /// last stopped, so the cost is about the region's border, not its
    /// height times its height.
    public func currentRegion(around address: CellAddress) -> CellRange {
        var region = CellRange(address)
        func filled(_ row: Int, _ column: Int) -> Bool {
            row >= 0 && column >= 0 && row < CellAddress.maxRows && column < CellAddress.maxColumns
                && !value(at: CellAddress(row: row, column: column)).isEmpty
        }
        func rowHasData(_ row: Int, _ columns: ClosedRange<Int>) -> Bool {
            columns.contains { filled(row, $0) }
        }
        func columnHasData(_ column: Int, _ rows: ClosedRange<Int>) -> Bool {
            rows.contains { filled($0, column) }
        }
        // The span along each side over which the line just outside it was
        // found empty. It stays valid while that side does not move (the
        // other sides only lengthen it); nil when the side has moved.
        var topChecked: ClosedRange<Int>?
        var bottomChecked: ClosedRange<Int>?
        var leftChecked: ClosedRange<Int>?
        var rightChecked: ClosedRange<Int>?
        /// The part of `span` outside `checked`: a side whose row or column
        /// was already empty only needs the new ends looked at.
        func unchecked(_ span: ClosedRange<Int>, _ checked: ClosedRange<Int>?) -> [ClosedRange<Int>] {
            guard let checked else { return [span] }
            var parts: [ClosedRange<Int>] = []
            if span.lowerBound < checked.lowerBound {
                parts.append(span.lowerBound...min(span.upperBound, checked.lowerBound - 1))
            }
            if span.upperBound > checked.upperBound {
                parts.append(max(span.lowerBound, checked.upperBound + 1)...span.upperBound)
            }
            return parts
        }
        var changed = true
        while changed {
            changed = false
            // Neighbouring columns (including the diagonal corners).
            var columns: ClosedRange<Int> { max(0, region.start.column - 1)...(region.end.column + 1) }
            var rows: ClosedRange<Int> { max(0, region.start.row - 1)...(region.end.row + 1) }

            while region.start.row > 0,
                  unchecked(columns, topChecked).contains(where: { rowHasData(region.start.row - 1, $0) }) {
                region.start.row -= 1
                topChecked = nil
                changed = true
            }
            topChecked = columns
            while region.end.row + 1 < CellAddress.maxRows,
                  unchecked(columns, bottomChecked).contains(where: { rowHasData(region.end.row + 1, $0) }) {
                region.end.row += 1
                bottomChecked = nil
                changed = true
            }
            bottomChecked = columns
            while region.start.column > 0,
                  unchecked(rows, leftChecked).contains(where: { columnHasData(region.start.column - 1, $0) }) {
                region.start.column -= 1
                leftChecked = nil
                changed = true
            }
            leftChecked = rows
            while region.end.column + 1 < CellAddress.maxColumns,
                  unchecked(rows, rightChecked).contains(where: { columnHasData(region.end.column + 1, $0) }) {
                region.end.column += 1
                rightChecked = nil
                changed = true
            }
            rightChecked = rows
        }
        return region
    }
}
