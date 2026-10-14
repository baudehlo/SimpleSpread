import Foundation
import SpreadsheetCore

/// Selection model: an anchor plus a focus define the selected rectangle;
/// the active cell is where typing goes.
public struct SelectionState: Equatable, Sendable {
    /// The cell where the selection began (stays put on shift-extension).
    public var anchor: CellAddress
    /// The moving end of the selection (follows shift+arrows / drag).
    public var focus: CellAddress
    /// The cell that receives typing; normally == anchor.
    public var activeCell: CellAddress

    public init(activeCell: CellAddress = CellAddress(row: 0, column: 0)) {
        self.anchor = activeCell
        self.focus = activeCell
        self.activeCell = activeCell
    }

    public var range: CellRange {
        CellRange(start: anchor, end: focus)
    }

    public var isSingleCell: Bool { anchor == focus }

    /// Collapse the selection to one cell.
    public mutating func select(_ cell: CellAddress) {
        anchor = cell
        focus = cell
        activeCell = cell
    }

    /// Extend from the current anchor to `cell` (shift-click / shift-arrow).
    public mutating func extend(to cell: CellAddress) {
        focus = cell
        activeCell = anchor
    }

    /// Select an explicit range (e.g. whole row/column).
    public mutating func select(range: CellRange, active: CellAddress? = nil) {
        anchor = range.start
        focus = range.end
        activeCell = active ?? range.start
    }

    public enum Direction {
        case up, down, left, right
    }

    /// Arrow-key move: collapse to a single cell offset from the active cell.
    public mutating func move(_ direction: Direction, rowLimit: Int = CellAddress.maxRows,
                              columnLimit: Int = CellAddress.maxColumns) {
        let next = SelectionState.step(from: activeCell, direction: direction,
                                       rowLimit: rowLimit, columnLimit: columnLimit)
        select(next)
    }

    /// Shift+arrow: move the focus, keeping the anchor.
    public mutating func extendMove(_ direction: Direction, rowLimit: Int = CellAddress.maxRows,
                                    columnLimit: Int = CellAddress.maxColumns) {
        focus = SelectionState.step(from: focus, direction: direction,
                                    rowLimit: rowLimit, columnLimit: columnLimit)
        activeCell = anchor
    }

    static func step(from cell: CellAddress, direction: Direction,
                     rowLimit: Int, columnLimit: Int) -> CellAddress {
        switch direction {
        case .up: return CellAddress(row: max(0, cell.row - 1), column: cell.column)
        case .down: return CellAddress(row: min(rowLimit - 1, cell.row + 1), column: cell.column)
        case .left: return CellAddress(row: cell.row, column: max(0, cell.column - 1))
        case .right: return CellAddress(row: cell.row, column: min(columnLimit - 1, cell.column + 1))
        }
    }

    /// Cmd+arrow: jump to the edge of the data region (Excel semantics).
    /// If the adjacent cell in `direction` has data, jump to the last
    /// contiguous non-empty cell; otherwise jump to the next non-empty cell;
    /// if none, jump to the sheet boundary.
    public static func dataEdge(from cell: CellAddress, direction: Direction, sheet: Sheet,
                                rowLimit: Int, columnLimit: Int) -> CellAddress {
        func isEmpty(_ addr: CellAddress) -> Bool {
            sheet.value(at: addr).isEmpty
        }
        func boundary() -> CellAddress {
            switch direction {
            case .up: return CellAddress(row: 0, column: cell.column)
            case .down: return CellAddress(row: rowLimit - 1, column: cell.column)
            case .left: return CellAddress(row: cell.row, column: 0)
            case .right: return CellAddress(row: cell.row, column: columnLimit - 1)
            }
        }
        func stepOnce(_ addr: CellAddress) -> CellAddress? {
            let next = step(from: addr, direction: direction, rowLimit: rowLimit, columnLimit: columnLimit)
            return next == addr ? nil : next
        }
        guard let first = stepOnce(cell) else { return cell }
        if !isEmpty(cell) && !isEmpty(first) {
            // Run to the end of the contiguous data block.
            var current = first
            while let next = stepOnce(current), !isEmpty(next) {
                current = next
            }
            return current
        }
        // Seek the next non-empty cell.
        var current: CellAddress? = isEmpty(cell) ? cell : first
        while let c = current {
            if !isEmpty(c) && c != cell { return c }
            current = stepOnce(c)
        }
        return boundary()
    }
}

/// Grid geometry: maps rows/columns to pixel offsets and back.
/// Row/column sizes come from the sheet; results are in points.
///
/// Offsets cost O(log k), where k is the number of rows (or columns) whose
/// size differs from the default (custom heights, hidden rows), so a
/// million-row sheet scrolls as smoothly as a small one.
public struct GridLayout {
    public let sheet: Sheet
    /// Rows/columns the grid presents (grows beyond the used range).
    public let rowCount: Int
    public let columnCount: Int
    public static let headerWidth: CGFloat = 46
    public static let headerHeight: CGFloat = 24

    private let rows: AxisSizes
    private let columns: AxisSizes

    public init(sheet: Sheet, minRows: Int = 200, minColumns: Int = 26) {
        self.sheet = sheet
        let used = sheet.usedRange
        rowCount = max(minRows, (used?.end.row ?? 0) + 50)
        columnCount = max(minColumns, (used?.end.column ?? 0) + 10)
        var rowSizes = sheet.rowHeights.filter { $0.key >= 0 && !sheet.hiddenRows.contains($0.key) }
        for row in sheet.hiddenRows where row >= 0 { rowSizes[row] = 0 }
        rows = AxisSizes(defaultSize: sheet.defaultRowHeight, sizes: rowSizes)
        columns = AxisSizes(defaultSize: sheet.defaultColumnWidth,
                            sizes: sheet.columnWidths.filter { $0.key >= 0 })
    }

    public func columnWidth(_ column: Int) -> CGFloat {
        sheet.columnWidth(column)
    }

    /// Hidden rows (by hand or by the AutoFilter) take no space.
    public func rowHeight(_ row: Int) -> CGFloat {
        sheet.hiddenRows.contains(row) ? 0 : sheet.rowHeight(row)
    }

    /// Frozen rows/columns, clamped to the grid.
    public var frozenRows: Int { min(max(0, sheet.frozenRows), rowCount - 1) }
    public var frozenColumns: Int { min(max(0, sheet.frozenColumns), columnCount - 1) }
    public var frozenHeight: CGFloat { yOffset(ofRow: frozenRows) }
    public var frozenWidth: CGFloat { xOffset(ofColumn: frozenColumns) }

    /// X origin of a column (grid content coordinates; excludes the header).
    public func xOffset(ofColumn column: Int) -> CGFloat {
        columns.offset(of: min(max(0, column), columnCount))
    }

    public func yOffset(ofRow row: Int) -> CGFloat {
        rows.offset(of: min(max(0, row), rowCount))
    }

    public var totalWidth: CGFloat { xOffset(ofColumn: columnCount) }
    public var totalHeight: CGFloat { yOffset(ofRow: rowCount) }

    /// Column containing x (content coordinates), clamped to bounds.
    public func column(atX x: CGFloat) -> Int {
        columns.index(at: x, count: columnCount)
    }

    /// Row containing y; with hidden rows, the visible row the point is in.
    public func row(atY y: CGFloat) -> Int {
        rows.index(at: y, count: rowCount)
    }

    public func rect(of address: CellAddress) -> CGRect {
        CGRect(x: xOffset(ofColumn: address.column), y: yOffset(ofRow: address.row),
               width: columnWidth(address.column), height: rowHeight(address.row))
    }

    /// The rows visible in a content-coordinate rect.
    public func visibleRows(in rect: CGRect) -> ClosedRange<Int> {
        let first = row(atY: max(0, rect.minY))
        let last = row(atY: max(0, rect.maxY))
        return first...max(first, last)
    }

    /// The rows of `range` that take up space, ascending: hidden rows are
    /// skipped a run at a time, so a filtered sheet showing a few rows far
    /// apart costs the rows shown, not the rows between them.
    public func shownRows(in range: ClosedRange<Int>) -> [Int] {
        rows.nonZeroIndices(in: range)
    }

    public func visibleColumns(in rect: CGRect) -> ClosedRange<Int> {
        let first = column(atX: max(0, rect.minX))
        let last = column(atX: max(0, rect.maxX))
        return first...max(first, last)
    }
}

/// Positions along one axis: every index is `defaultSize` except a sorted
/// few, whose differences from the default are kept as running totals.
struct AxisSizes {
    let defaultSize: CGFloat
    /// Indices whose size differs from the default, ascending.
    private let indices: [Int]
    /// `deltaBefore[k]`: total (size - default) over `indices[0..<k]`.
    private let deltaBefore: [CGFloat]
    /// Runs of consecutive zero-size indices (hidden rows), ascending.
    private let zeroRuns: [ClosedRange<Int>]

    init(defaultSize: CGFloat, sizes: [Int: CGFloat]) {
        self.defaultSize = defaultSize
        let changed = sizes.filter { $0.value != defaultSize }.sorted { $0.key < $1.key }
        indices = changed.map(\.key)
        var running: CGFloat = 0
        var totals: [CGFloat] = [0]
        totals.reserveCapacity(changed.count + 1)
        var runs: [ClosedRange<Int>] = []
        for (index, size) in changed {
            running += size - defaultSize
            totals.append(running)
            if size <= 0 {
                if let last = runs.last, last.upperBound == index - 1 {
                    runs[runs.count - 1] = last.lowerBound...index
                } else {
                    runs.append(index...index)
                }
            }
        }
        deltaBefore = totals
        zeroRuns = runs
    }

    /// The indices of `range` whose size is not zero (for a positive
    /// default size), ascending, skipping each run of zero-size indices in
    /// one step.
    func nonZeroIndices(in range: ClosedRange<Int>) -> [Int] {
        // First run that ends at or after the range's start.
        var lo = 0, hi = zeroRuns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if zeroRuns[mid].upperBound < range.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        var result: [Int] = []
        var index = range.lowerBound
        var run = lo
        while index <= range.upperBound {
            if run < zeroRuns.count, zeroRuns[run].lowerBound <= index {
                index = zeroRuns[run].upperBound + 1
                run += 1
                continue
            }
            let stop = run < zeroRuns.count ? min(range.upperBound, zeroRuns[run].lowerBound - 1) : range.upperBound
            result.append(contentsOf: index...stop)
            index = stop + 1
        }
        return result
    }

    /// Number of changed indices below `index`.
    private func changedBelow(_ index: Int) -> Int {
        var lo = 0, hi = indices.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if indices[mid] < index { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Start of `index` (the sum of all sizes before it).
    func offset(of index: Int) -> CGFloat {
        CGFloat(index) * defaultSize + deltaBefore[changedBelow(index)]
    }

    /// The last index in 0..<count starting at or before `position`: the
    /// one the position falls in (zero-size indices start where the next one
    /// does, so they are passed over). Clamped to the ends.
    func index(at position: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var lo = 0, hi = count - 1
        guard offset(of: 0) <= position else { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if offset(of: mid) <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
