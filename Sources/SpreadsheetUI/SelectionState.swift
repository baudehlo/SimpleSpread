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
public struct GridLayout {
    public let sheet: Sheet
    /// Rows/columns the grid presents (grows beyond the used range).
    public let rowCount: Int
    public let columnCount: Int
    public static let headerWidth: CGFloat = 46
    public static let headerHeight: CGFloat = 24

    public init(sheet: Sheet, minRows: Int = 200, minColumns: Int = 26) {
        self.sheet = sheet
        let used = sheet.usedRange
        rowCount = max(minRows, (used?.end.row ?? 0) + 50)
        columnCount = max(minColumns, (used?.end.column ?? 0) + 10)
    }

    public func columnWidth(_ column: Int) -> CGFloat {
        sheet.columnWidth(column)
    }

    public func rowHeight(_ row: Int) -> CGFloat {
        sheet.rowHeight(row)
    }

    /// X origin of a column (grid content coordinates; excludes the header).
    public func xOffset(ofColumn column: Int) -> CGFloat {
        var x: CGFloat = 0
        for c in 0..<min(column, columnCount) {
            x += columnWidth(c)
        }
        return x
    }

    public func yOffset(ofRow row: Int) -> CGFloat {
        var y: CGFloat = 0
        for r in 0..<min(row, rowCount) {
            y += rowHeight(r)
        }
        return y
    }

    public var totalWidth: CGFloat { xOffset(ofColumn: columnCount) }
    public var totalHeight: CGFloat { yOffset(ofRow: rowCount) }

    /// Column containing x (content coordinates), clamped to bounds.
    public func column(atX x: CGFloat) -> Int {
        var pos: CGFloat = 0
        for c in 0..<columnCount {
            pos += columnWidth(c)
            if x < pos { return c }
        }
        return columnCount - 1
    }

    public func row(atY y: CGFloat) -> Int {
        var pos: CGFloat = 0
        for r in 0..<rowCount {
            pos += rowHeight(r)
            if y < pos { return r }
        }
        return rowCount - 1
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

    public func visibleColumns(in rect: CGRect) -> ClosedRange<Int> {
        let first = column(atX: max(0, rect.minX))
        let last = column(atX: max(0, rect.maxX))
        return first...max(first, last)
    }
}
