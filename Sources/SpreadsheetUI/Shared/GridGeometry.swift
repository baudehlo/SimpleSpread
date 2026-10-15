import CoreGraphics
import SpreadsheetCore

/// Where things are in the grid. Both platforms' grid views use one
/// coordinate space ("view coordinates"): the whole sheet at 100%, with the
/// column headers along the top and the row headers down the left, as if it
/// were one huge view. `visible` is the part of it on screen. Headers and
/// frozen rows and columns are drawn pinned to the visible rect.
struct GridGeometry {
    let layout: GridLayout
    /// The part of the grid on screen, in view coordinates.
    let visible: CGRect

    static let contentOrigin = CGPoint(x: GridLayout.headerWidth, y: GridLayout.headerHeight)
    var contentOrigin: CGPoint { Self.contentOrigin }

    /// The size of the whole grid: the used sheet plus a margin to scroll
    /// into.
    static func gridSize(_ layout: GridLayout) -> CGSize {
        CGSize(width: layout.totalWidth + GridLayout.headerWidth + 200,
               height: layout.totalHeight + GridLayout.headerHeight + 200)
    }

    /// Convert a view point to grid content coordinates. A point over a
    /// frozen pane maps to the frozen rows/columns drawn there.
    func contentPoint(_ viewPoint: CGPoint) -> CGPoint {
        let l = layout
        var point = CGPoint(x: viewPoint.x - contentOrigin.x, y: viewPoint.y - contentOrigin.y)
        if l.frozenColumns > 0, viewPoint.x < visible.minX + contentOrigin.x + l.frozenWidth {
            point.x -= visible.minX
        }
        if l.frozenRows > 0, viewPoint.y < visible.minY + contentOrigin.y + l.frozenHeight {
            point.y -= visible.minY
        }
        return point
    }

    /// The cell under a view point (clamped to the sheet).
    func address(at viewPoint: CGPoint) -> CellAddress {
        let content = contentPoint(viewPoint)
        return CellAddress(row: layout.row(atY: max(0, content.y)), column: layout.column(atX: max(0, content.x)))
    }

    /// A cell's rect in unshifted view coordinates (where it sits when the
    /// sheet isn't scrolled past it).
    func cellRect(_ address: CellAddress) -> CGRect {
        layout.rect(of: address).offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
    }

    /// A range's rect in unshifted view coordinates.
    func rangeRect(_ range: CellRange) -> CGRect {
        cellRect(range.start).union(cellRect(range.end))
    }

    // MARK: Panes (frozen rows and columns)

    /// One region of the grid. Frozen rows and columns are drawn pinned to
    /// the visible rect, like the headers: their content is shifted by the
    /// scroll offset (`shift`) and clipped to `clip`. The scrolling body has
    /// no shift. View position = content position + contentOrigin + shift.
    struct Pane {
        var rows: ClosedRange<Int>
        var cols: ClosedRange<Int>
        var shift: CGPoint
        /// View coordinates.
        var clip: CGRect
        /// The clip in unshifted view coordinates: the part of the sheet shown.
        var visible: CGRect { clip.offsetBy(dx: -shift.x, dy: -shift.y) }
    }

    /// One band of columns (or rows): frozen, or scrolling.
    struct Band {
        var range: ClosedRange<Int>
        var shift: CGFloat
        /// Its extent across the view, in view coordinates.
        var min: CGFloat
        var max: CGFloat
    }

    /// The horizontal bands: frozen columns, then scrolling columns.
    func columnBands() -> [Band] {
        let l = layout
        var bands: [Band] = []
        let frozen = l.frozenColumns
        let bodyLeft = visible.minX + contentOrigin.x + l.frozenWidth
        if frozen > 0 {
            bands.append(Band(range: 0...(frozen - 1), shift: visible.minX,
                              min: visible.minX + contentOrigin.x, max: Swift.min(bodyLeft, visible.maxX)))
        }
        if bodyLeft < visible.maxX {
            let cols = l.visibleColumns(in: CGRect(x: bodyLeft - contentOrigin.x, y: 0,
                                                   width: visible.maxX - bodyLeft, height: 1))
            let lower = Swift.max(frozen, cols.lowerBound)
            bands.append(Band(range: lower...Swift.max(lower, cols.upperBound), shift: 0,
                              min: bodyLeft, max: visible.maxX))
        }
        return bands
    }

    /// The vertical bands: frozen rows, then scrolling rows.
    func rowBands() -> [Band] {
        let l = layout
        var bands: [Band] = []
        let frozen = l.frozenRows
        let bodyTop = visible.minY + contentOrigin.y + l.frozenHeight
        if frozen > 0 {
            bands.append(Band(range: 0...(frozen - 1), shift: visible.minY,
                              min: visible.minY + contentOrigin.y, max: Swift.min(bodyTop, visible.maxY)))
        }
        if bodyTop < visible.maxY {
            let rows = l.visibleRows(in: CGRect(x: 0, y: bodyTop - contentOrigin.y,
                                                width: 1, height: visible.maxY - bodyTop))
            let lower = Swift.max(frozen, rows.lowerBound)
            bands.append(Band(range: lower...Swift.max(lower, rows.upperBound), shift: 0,
                              min: bodyTop, max: visible.maxY))
        }
        return bands
    }

    func panes() -> [Pane] {
        var result: [Pane] = []
        for rowBand in rowBands() {
            for colBand in columnBands() {
                result.append(Pane(rows: rowBand.range, cols: colBand.range,
                                   shift: CGPoint(x: colBand.shift, y: rowBand.shift),
                                   clip: CGRect(x: colBand.min, y: rowBand.min,
                                                width: colBand.max - colBand.min,
                                                height: rowBand.max - rowBand.min)))
            }
        }
        return result
    }

    /// Where a cell is drawn in the view, allowing for frozen panes.
    func viewRect(_ address: CellAddress) -> CGRect {
        var rect = cellRect(address)
        if address.row < layout.frozenRows { rect.origin.y += visible.minY }
        if address.column < layout.frozenColumns { rect.origin.x += visible.minX }
        return rect
    }

    /// A cell's view rect, covering its whole merged range.
    func viewRectIncludingMerge(_ address: CellAddress) -> CGRect {
        guard let merge = layout.sheet.mergedRange(containing: address) else { return viewRect(address) }
        return viewRect(merge.start).union(viewRect(merge.end))
    }

    /// A range's view rect, allowing for frozen panes.
    func viewRect(_ range: CellRange) -> CGRect {
        viewRect(range.start).union(viewRect(range.end))
    }

    // MARK: Hit testing

    enum Region {
        /// The select-all box where the headers meet.
        case corner
        case columnHeader
        case rowHeader
        case cells
    }

    func region(at point: CGPoint) -> Region {
        let inColumnHeader = point.y < visible.minY + GridLayout.headerHeight
        let inRowHeader = point.x < visible.minX + GridLayout.headerWidth
        switch (inColumnHeader, inRowHeader) {
        case (true, true): return .corner
        case (true, false): return .columnHeader
        case (false, true): return .rowHeader
        case (false, false): return .cells
        }
    }

    /// The column whose right edge is within `slop` of content x, if any.
    func columnBoundary(near x: CGFloat, slop: CGFloat = 4) -> Int? {
        let l = layout
        let col = l.column(atX: x)
        if col > 0, abs(x - l.xOffset(ofColumn: col)) <= slop { return col - 1 }
        if abs(x - l.xOffset(ofColumn: col + 1)) <= slop { return col }
        return nil
    }

    /// The row whose bottom edge is within `slop` of content y. At a run of
    /// hidden rows, the visible row above them (they share that edge).
    func rowBoundary(near y: CGFloat, slop: CGFloat = 4) -> Int? {
        let l = layout
        let row = l.row(atY: y)
        if row > 0, abs(y - l.yOffset(ofRow: row)) <= slop {
            var above = row - 1
            while above > 0, l.rowHeight(above) == 0 { above -= 1 }
            return above
        }
        if abs(y - l.yOffset(ofRow: row + 1)) <= slop { return row }
        return nil
    }

    /// The column and row edges in the headers that resize when dragged, in
    /// view coordinates (for resize cursors).
    func resizeZones() -> (columns: [CGRect], rows: [CGRect]) {
        let l = layout
        var columns: [CGRect] = []
        var rows: [CGRect] = []
        for band in columnBands() {
            for col in band.range {
                let x = contentOrigin.x + l.xOffset(ofColumn: col) + l.columnWidth(col) + band.shift
                guard x >= band.min, x <= band.max else { continue }
                columns.append(CGRect(x: x - 3, y: visible.minY, width: 6, height: GridLayout.headerHeight))
            }
        }
        for band in rowBands() {
            for row in l.shownRows(in: band.range) {
                let y = contentOrigin.y + l.yOffset(ofRow: row) + l.rowHeight(row) + band.shift
                guard y >= band.min, y <= band.max else { continue }
                rows.append(CGRect(x: visible.minX, y: y - 3, width: GridLayout.headerWidth, height: 6))
            }
        }
        return (columns, rows)
    }

    /// Width a pivot field button takes at a cell's right edge (box + gap).
    static let pivotButtonSize: CGFloat = 11
    static let pivotButtonReserve: CGFloat = pivotButtonSize + 4

    /// The box an AutoFilter or pivot button occupies in a cell (view or
    /// content coordinates alike): at the right edge, vertically centred.
    static func dropdownButtonRect(in cell: CGRect) -> CGRect? {
        let size = min(pivotButtonSize, cell.height - 4)
        guard size > 4 else { return nil }
        return CGRect(x: (cell.maxX - size - 3).rounded() + 0.5,
                      y: (cell.midY - size / 2).rounded() + 0.5,
                      width: size - 1, height: size - 1)
    }

    /// The AutoFilter button under a view point: its column (counted from
    /// the filter's first) and the header cell's view rect. `slop` widens
    /// the button for a finger.
    func filterButton(at point: CGPoint, slop: CGFloat = 3) -> (columnOffset: Int, cell: CGRect)? {
        let addr = address(at: point)
        guard let filter = layout.sheet.autoFilter, addr.row == filter.headerRow,
              filter.range.start.column...filter.range.end.column ~= addr.column else { return nil }
        let cell = viewRectIncludingMerge(addr)
        guard let button = Self.dropdownButtonRect(in: cell),
              button.insetBy(dx: -slop, dy: -slop).contains(point) else { return nil }
        return (addr.column - filter.range.start.column, cell)
    }

    // MARK: Scrolling

    /// The scroll origin that brings `address` (or its merged range) into
    /// view clear of the headers and any frozen pane, or nil if it already
    /// shows. Frozen cells are always in view. `gridSize` bounds the result.
    func scrollOrigin(toShow address: CellAddress, gridSize: CGSize) -> CGPoint? {
        let l = layout
        let target = l.sheet.mergedRange(containing: address) ?? CellRange(address)
        let rect = rangeRect(target)
        var origin = visible.origin
        let margin: CGFloat = 20
        if address.row >= l.frozenRows {
            let top = visible.minY + contentOrigin.y + l.frozenHeight
            if rect.minY < top {
                origin.y = rect.minY - contentOrigin.y - l.frozenHeight
            } else if rect.maxY + margin > visible.maxY {
                origin.y = min(rect.minY - contentOrigin.y - l.frozenHeight,
                               rect.maxY + margin - visible.height)
            }
        }
        if address.column >= l.frozenColumns {
            let left = visible.minX + contentOrigin.x + l.frozenWidth
            if rect.minX < left {
                origin.x = rect.minX - contentOrigin.x - l.frozenWidth
            } else if rect.maxX + margin > visible.maxX {
                origin.x = min(rect.minX - contentOrigin.x - l.frozenWidth,
                               rect.maxX + margin - visible.width)
            }
        }
        origin.x = max(0, min(origin.x, gridSize.width - visible.width))
        origin.y = max(0, min(origin.y, gridSize.height - visible.height))
        return origin == visible.origin ? nil : origin
    }
}
