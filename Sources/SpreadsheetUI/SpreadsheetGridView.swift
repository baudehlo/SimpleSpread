import AppKit
import SpreadsheetCore

/// The spreadsheet grid: draws cells/headers/selection, owns the
/// Ready/Enter/Edit editing state machine, mouse selection, header resizing,
/// and the fill handle. Lives inside an NSScrollView as the document view;
/// headers are drawn pinned to the visible rect.
@MainActor
final class SpreadsheetGridView: NSView, NSTextFieldDelegate {
    weak var document: SpreadsheetDocument?
    /// Called when the user changes selection (SwiftUI syncs the formula bar).
    var onStateChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Editing state machine (Excel's Ready / Enter / Edit modes)

    enum EditMode {
        case ready
        /// Typing replaced content: arrows COMMIT and move.
        case enter
        /// Double-click/F2: arrows move the caret inside the text.
        case edit
    }

    private(set) var editMode: EditMode = .ready
    private var editorField: NSTextField?
    /// The sheet and cell the editor was opened on. A commit writes there,
    /// even if the active sheet or selection has changed since.
    private var editingTarget: (sheetID: Int, address: CellAddress)?

    // Mouse drag state
    private enum DragMode {
        case none
        case selectCells
        case selectRows(anchor: Int)
        case selectColumns(anchor: Int)
        case resizeColumn(index: Int, startWidth: CGFloat, startX: CGFloat)
        case resizeRow(index: Int, startHeight: CGFloat, startY: CGFloat)
        case fillHandle(source: CellRange)
    }
    private var dragMode: DragMode = .none
    private var pendingFillTarget: CellRange?

    /// The layout for the current revision of the active sheet; rebuilt
    /// only after an edit (every layout change goes through markChanged).
    var layout: GridLayout {
        guard let document else { return GridLayout(sheet: Sheet(id: 0, name: "")) }
        let sheet = document.activeSheet
        if let cache = layoutCache, cache.revision == document.revision, cache.layout.sheet === sheet {
            return cache.layout
        }
        let fresh = GridLayout(sheet: sheet)
        layoutCache = (document.revision, fresh)
        return fresh
    }
    private var layoutCache: (revision: Int, layout: GridLayout)?

    static let headerColor = NSColor.windowBackgroundColor
    static let gridLineColor = NSColor.separatorColor.withAlphaComponent(0.5)
    static let selectionFill = NSColor.controlAccentColor.withAlphaComponent(0.12)
    static let selectionBorder = NSColor.controlAccentColor
    /// Pivot header/grand-total shading (Excel's PivotStyleLight16 blue in
    /// light mode; a translucent system blue reads better on dark).
    static let pivotBandFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.systemBlue.withAlphaComponent(0.22)
            : NSColor(srgbRed: 0xDD / 255, green: 0xEB / 255, blue: 0xF7 / 255, alpha: 1)
    }
    /// The rules under a pivot's header rows and above its grand totals.
    static let pivotRuleColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.systemBlue.withAlphaComponent(0.65)
            : NSColor(srgbRed: 0x7F / 255, green: 0xA7 / 255, blue: 0xD9 / 255, alpha: 1)
    }

    /// Pivot banding for the active sheet, rebuilt when the document changes.
    private var pivotBandsCache: (revision: Int, sheetID: Int, bands: [PivotBands])?

    // MARK: Layout size

    func refreshSize() {
        let l = layout
        let size = CGSize(width: l.totalWidth + GridLayout.headerWidth + 200,
                          height: l.totalHeight + GridLayout.headerHeight + 200)
        if frame.size != size {
            setFrameSize(size)
        }
        needsDisplay = true
    }

    private var contentOrigin: CGPoint {
        CGPoint(x: GridLayout.headerWidth, y: GridLayout.headerHeight)
    }

    /// Convert a view point to grid content coordinates. A point over a
    /// frozen pane maps to the frozen rows/columns drawn there.
    private func contentPoint(_ viewPoint: CGPoint) -> CGPoint {
        let l = layout
        let visible = visibleArea
        var point = CGPoint(x: viewPoint.x - contentOrigin.x, y: viewPoint.y - contentOrigin.y)
        if l.frozenColumns > 0, viewPoint.x < visible.minX + contentOrigin.x + l.frozenWidth {
            point.x -= visible.minX
        }
        if l.frozenRows > 0, viewPoint.y < visible.minY + contentOrigin.y + l.frozenHeight {
            point.y -= visible.minY
        }
        return point
    }

    private func cellRect(_ address: CellAddress, layout l: GridLayout) -> CGRect {
        l.rect(of: address).offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
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

    private var visibleArea: CGRect {
        enclosingScrollView?.documentVisibleRect ?? bounds
    }

    /// The horizontal bands (frozen columns, then scrolling columns), as
    /// (columns, x shift, view minX, view maxX); vertical bands likewise.
    private func columnBands(layout l: GridLayout, visible: CGRect) -> [(ClosedRange<Int>, CGFloat, CGFloat, CGFloat)] {
        var bands: [(ClosedRange<Int>, CGFloat, CGFloat, CGFloat)] = []
        let frozen = l.frozenColumns
        let bodyLeft = visible.minX + contentOrigin.x + l.frozenWidth
        if frozen > 0 {
            bands.append((0...(frozen - 1), visible.minX, visible.minX + contentOrigin.x, min(bodyLeft, visible.maxX)))
        }
        if bodyLeft < visible.maxX {
            let cols = l.visibleColumns(in: CGRect(x: bodyLeft - contentOrigin.x, y: 0,
                                                   width: visible.maxX - bodyLeft, height: 1))
            let lower = max(frozen, cols.lowerBound)
            bands.append((lower...max(lower, cols.upperBound), 0, bodyLeft, visible.maxX))
        }
        return bands
    }

    private func rowBands(layout l: GridLayout, visible: CGRect) -> [(ClosedRange<Int>, CGFloat, CGFloat, CGFloat)] {
        var bands: [(ClosedRange<Int>, CGFloat, CGFloat, CGFloat)] = []
        let frozen = l.frozenRows
        let bodyTop = visible.minY + contentOrigin.y + l.frozenHeight
        if frozen > 0 {
            bands.append((0...(frozen - 1), visible.minY, visible.minY + contentOrigin.y, min(bodyTop, visible.maxY)))
        }
        if bodyTop < visible.maxY {
            let rows = l.visibleRows(in: CGRect(x: 0, y: bodyTop - contentOrigin.y,
                                                width: 1, height: visible.maxY - bodyTop))
            let lower = max(frozen, rows.lowerBound)
            bands.append((lower...max(lower, rows.upperBound), 0, bodyTop, visible.maxY))
        }
        return bands
    }

    private func panes(layout l: GridLayout, visible: CGRect) -> [Pane] {
        var result: [Pane] = []
        for (rows, dy, minY, maxY) in rowBands(layout: l, visible: visible) {
            for (cols, dx, minX, maxX) in columnBands(layout: l, visible: visible) {
                result.append(Pane(rows: rows, cols: cols, shift: CGPoint(x: dx, y: dy),
                                   clip: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)))
            }
        }
        return result
    }

    /// Where a cell is drawn in the view, allowing for frozen panes.
    func viewRect(_ address: CellAddress, layout l: GridLayout) -> CGRect {
        var rect = cellRect(address, layout: l)
        let visible = visibleArea
        if address.row < l.frozenRows { rect.origin.y += visible.minY }
        if address.column < l.frozenColumns { rect.origin.x += visible.minX }
        return rect
    }

    /// A cell's view rect, covering its whole merged range.
    func viewRectIncludingMerge(_ address: CellAddress, layout l: GridLayout) -> CGRect {
        guard let merge = l.sheet.mergedRange(containing: address) else { return viewRect(address, layout: l) }
        return viewRect(merge.start, layout: l).union(viewRect(merge.end, layout: l))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        let l = layout
        let visible = visibleArea

        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        for pane in panes(layout: l, visible: visible) where pane.clip.width > 0 && pane.clip.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: pane.clip).addClip()
            let shift = NSAffineTransform()
            shift.translateX(by: pane.shift.x, yBy: pane.shift.y)
            shift.concat()
            drawPane(pane, document: document, layout: l)
            NSGraphicsContext.restoreGraphicsState()
        }

        // The lines where frozen panes meet the scrolling body.
        if l.frozenRows > 0 || l.frozenColumns > 0 {
            NSColor.tertiaryLabelColor.setStroke()
            let divider = NSBezierPath()
            divider.lineWidth = 1
            if l.frozenRows > 0 {
                let y = (visible.minY + contentOrigin.y + l.frozenHeight).rounded() + 0.5
                divider.move(to: CGPoint(x: visible.minX, y: y))
                divider.line(to: CGPoint(x: visible.maxX, y: y))
            }
            if l.frozenColumns > 0 {
                let x = (visible.minX + contentOrigin.x + l.frozenWidth).rounded() + 0.5
                divider.move(to: CGPoint(x: x, y: visible.minY))
                divider.line(to: CGPoint(x: x, y: visible.maxY))
            }
            divider.stroke()
        }

        // --- Headers (pinned to the visible rect) ---
        drawHeaders(layout: l, visible: visible,
                    selectionRange: document.activeSheet.expandedForMerges(document.selection.range))
    }

    /// Draw one pane's cells, in unshifted coordinates (the caller has set
    /// the clip and the translation).
    private func drawPane(_ pane: Pane, document: SpreadsheetDocument, layout l: GridLayout) {
        let visible = pane.visible
        let rows = pane.rows
        let cols = pane.cols
        let sheet = document.activeSheet
        let selection = document.selection
        // Drawn over whole merged cells, even before a click has grown the
        // selection to cover them (e.g. A1 inside a merge on open).
        let selectionRange = sheet.expandedForMerges(selection.range)

        // Pivot styling is drawn from cell roles, and only on sheets that
        // have pivots (role lookups are cached per revision, but skip them
        // entirely everywhere else).
        let bands = pivotBands(document)
        let role: (CellAddress) -> PivotCellRole? = { document.pivotRole(at: $0) }
        var pivotButtons: [CGRect] = []

        // Merged ranges showing in this pane, and the cells they cover.
        let paneRange = CellRange(start: CellAddress(row: rows.lowerBound, column: cols.lowerBound),
                                  end: CellAddress(row: rows.upperBound, column: cols.upperBound))
        let merges = sheet.mergedRanges.filter { $0.intersects(paneRange) }
        var mergeOf: [CellAddress: CellRange] = [:]
        for merge in merges {
            for row in max(merge.start.row, rows.lowerBound)...min(merge.end.row, rows.upperBound) {
                for col in max(merge.start.column, cols.lowerBound)...min(merge.end.column, cols.upperBound) {
                    mergeOf[CellAddress(row: row, column: col)] = merge
                }
            }
        }
        func mergeRect(_ merge: CellRange) -> CGRect {
            cellRect(merge.start, layout: l).union(cellRect(merge.end, layout: l))
        }

        // AutoFilter header buttons.
        let filter = sheet.autoFilter
        func hasFilterButton(_ address: CellAddress) -> Bool {
            guard let filter else { return false }
            return address.row == filter.headerRow
                && (filter.range.start.column...filter.range.end.column).contains(address.column)
        }

        // --- Cell backgrounds ---
        for merge in merges {
            let style = document.workbook.style(at: sheet.cell(at: merge.start).styleIndex)
            if let fill = style.fillColor {
                nsColor(fill).setFill()
                mergeRect(merge).fill()
            }
        }
        for row in rows where l.rowHeight(row) > 0 {
            for col in cols {
                let addr = CellAddress(row: row, column: col)
                let rect = cellRect(addr, layout: l)
                guard rect.intersects(visible) else { continue }
                if mergeOf[addr] == nil {
                    let cell = sheet.cell(at: addr)
                    let style = document.workbook.style(at: cell.styleIndex)
                    if let fill = style.fillColor {
                        nsColor(fill).setFill()
                        rect.fill()
                    } else if !bands.isEmpty, bands.contains(where: { $0.isShaded(addr, role: role) }) {
                        SpreadsheetGridView.pivotBandFill.setFill()
                        rect.fill()
                    }
                    if style.pivotButton { pivotButtons.append(rect) }
                }
                if selectionRange.contains(addr) {
                    SpreadsheetGridView.selectionFill.setFill()
                    rect.fill()
                }
            }
        }

        // --- Cell text ---
        // Drawn after every background so text that spills into an empty
        // neighbour (Excel-style overflow) is not painted over by that
        // neighbour's fill. A spilled run hides the grid lines inside it.
        var hiddenBoundaries: [Int: Set<Int>] = [:]
        for row in rows where l.rowHeight(row) > 0 {
            for col in textSourceColumns(row: row, visible: cols, layout: l) {
                let addr = CellAddress(row: row, column: col)
                if mergeOf[addr] != nil { continue }
                let cell = sheet.cell(at: addr)
                guard !cell.value.isEmpty else { continue }
                if !cols.contains(col), sheet.mergedRange(containing: addr) != nil { continue }
                var style = document.workbook.style(at: cell.styleIndex)
                if !bands.isEmpty, let r = role(addr), PivotBands.isBold(r) { style.bold = true }
                let span = drawCellText(cell: cell, style: style, at: addr, layout: l,
                                        reserveButton: hasFilterButton(addr))
                if span.count > 1 {
                    for boundary in (span.lowerBound + 1)...span.upperBound {
                        hiddenBoundaries[row, default: []].insert(boundary)
                    }
                }
            }
        }
        for merge in merges {
            let cell = sheet.cell(at: merge.start)
            guard !cell.value.isEmpty else { continue }
            let style = document.workbook.style(at: cell.styleIndex)
            drawCellText(cell: cell, style: style, at: merge.start, layout: l,
                         reserveButton: hasFilterButton(merge.start), in: mergeRect(merge))
        }

        // --- Grid lines ---
        // Lines inside a merged range are left out, as are the vertical
        // lines that overflowing text runs across.
        var hiddenRules: [Int: Set<Int>] = [:]   // row boundary -> columns
        for merge in merges {
            for row in merge.start.row...merge.end.row {
                for boundary in (merge.start.column + 1)..<(merge.end.column + 1) {
                    hiddenBoundaries[row, default: []].insert(boundary)
                }
            }
            for boundary in (merge.start.row + 1)..<(merge.end.row + 1) {
                for col in merge.start.column...merge.end.column {
                    hiddenRules[boundary, default: []].insert(col)
                }
            }
        }
        SpreadsheetGridView.gridLineColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let lineTop = max(visible.minY, contentOrigin.y)
        let lineBottom = min(visible.maxY, contentOrigin.y + l.totalHeight)
        let lineLeft = max(visible.minX, contentOrigin.x)
        let lineRight = min(visible.maxX, contentOrigin.x + l.totalWidth)
        // Row tops for the visible rows, so vertical lines can skip the rows
        // where overflowing text runs across a boundary.
        var rowTops: [CGFloat] = []
        var rowTop = contentOrigin.y + l.yOffset(ofRow: rows.lowerBound)
        for row in rows {
            rowTops.append(rowTop)
            rowTop += l.rowHeight(row)
        }
        var x = contentOrigin.x + l.xOffset(ofColumn: cols.lowerBound)
        for col in cols.lowerBound...(cols.upperBound + 1) {
            if hiddenBoundaries.isEmpty {
                path.move(to: CGPoint(x: x, y: lineTop))
                path.line(to: CGPoint(x: x, y: lineBottom))
            } else {
                var segmentStart: CGFloat? = lineTop
                for (index, row) in rows.enumerated() where hiddenBoundaries[row]?.contains(col) == true {
                    let top = max(lineTop, rowTops[index])
                    if let start = segmentStart, top > start {
                        path.move(to: CGPoint(x: x, y: start))
                        path.line(to: CGPoint(x: x, y: top))
                    }
                    segmentStart = rowTops[index] + l.rowHeight(row)
                }
                if let start = segmentStart, lineBottom > start {
                    path.move(to: CGPoint(x: x, y: start))
                    path.line(to: CGPoint(x: x, y: lineBottom))
                }
            }
            if col <= cols.upperBound { x += l.columnWidth(col) }
        }
        var colLefts: [CGFloat] = []
        var colLeft = contentOrigin.x + l.xOffset(ofColumn: cols.lowerBound)
        for col in cols {
            colLefts.append(colLeft)
            colLeft += l.columnWidth(col)
        }
        var y = contentOrigin.y + l.yOffset(ofRow: rows.lowerBound)
        for row in rows.lowerBound...(rows.upperBound + 1) {
            if let hidden = hiddenRules[row] {
                var segmentStart: CGFloat? = lineLeft
                for (index, col) in cols.enumerated() where hidden.contains(col) {
                    let left = max(lineLeft, colLefts[index])
                    if let start = segmentStart, left > start {
                        path.move(to: CGPoint(x: start, y: y))
                        path.line(to: CGPoint(x: left, y: y))
                    }
                    segmentStart = colLefts[index] + l.columnWidth(col)
                }
                if let start = segmentStart, lineRight > start {
                    path.move(to: CGPoint(x: start, y: y))
                    path.line(to: CGPoint(x: lineRight, y: y))
                }
            } else {
                path.move(to: CGPoint(x: lineLeft, y: y))
                path.line(to: CGPoint(x: lineRight, y: y))
            }
            if row <= rows.upperBound { y += l.rowHeight(row) }
        }
        path.stroke()

        if !bands.isEmpty {
            drawPivotRules(bands, role: role, layout: l, rows: rows)
        }
        for rect in pivotButtons { drawPivotButton(in: rect) }

        // --- Cell borders ---
        drawBorders(document: document, layout: l, rows: rows, cols: cols)

        // --- AutoFilter buttons ---
        if let filter, rows.contains(filter.headerRow) {
            let lo = max(cols.lowerBound, filter.range.start.column)
            let hi = min(cols.upperBound, filter.range.end.column)
            if lo <= hi {
                for col in lo...hi {
                    let addr = CellAddress(row: filter.headerRow, column: col)
                    let rect = mergeOf[addr].map(mergeRect) ?? cellRect(addr, layout: l)
                    let active = filter.columns[col - filter.range.start.column]?.isActive == true
                    drawFilterButton(in: rect, active: active)
                }
            }
        }

        // --- Selection border + fill handle ---
        let selStart = cellRect(selectionRange.start, layout: l)
        let selEnd = cellRect(selectionRange.end, layout: l)
        let selRect = selStart.union(selEnd)
        SpreadsheetGridView.selectionBorder.setStroke()
        let selPath = NSBezierPath(rect: selRect.insetBy(dx: -0.5, dy: -0.5))
        selPath.lineWidth = 2
        selPath.stroke()
        // Active cell gets a white inner keyline when part of a bigger range.
        let activeMerge = sheet.mergedRange(containing: selection.activeCell)
        if !selection.isSingleCell, activeMerge != selectionRange {
            let activeRect = activeMerge.map(mergeRect) ?? cellRect(selection.activeCell, layout: l)
            NSColor.textBackgroundColor.setStroke()
            let activePath = NSBezierPath(rect: activeRect.insetBy(dx: 1, dy: 1))
            activePath.lineWidth = 2
            activePath.stroke()
        }
        // Fill handle (bottom-right square).
        let handleRect = CGRect(x: selRect.maxX - 4, y: selRect.maxY - 4, width: 7, height: 7)
        SpreadsheetGridView.selectionBorder.setFill()
        handleRect.fill()
        NSColor.textBackgroundColor.setStroke()
        NSBezierPath(rect: handleRect).stroke()

        // Fill-drag preview.
        if let target = pendingFillTarget {
            let r = cellRect(target.start, layout: l).union(cellRect(target.end, layout: l))
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let dash = NSBezierPath(rect: r)
            dash.setLineDash([4, 3], count: 2, phase: 0)
            dash.lineWidth = 1.5
            dash.stroke()
        }
    }

    // MARK: Borders

    /// Each cell draws its own edges; an edge inside a merged range is left
    /// out. One row and column beyond the pane are included so an edge set
    /// on a cell just out of view still shows.
    private func drawBorders(document: SpreadsheetDocument, layout l: GridLayout,
                             rows: ClosedRange<Int>, cols: ClosedRange<Int>) {
        let sheet = document.activeSheet
        let rowRange = max(0, rows.lowerBound - 1)...(rows.upperBound + 1)
        let colRange = max(0, cols.lowerBound - 1)...(cols.upperBound + 1)
        for row in rowRange where l.rowHeight(row) > 0 {
            for column in colRange {
                let addr = CellAddress(row: row, column: column)
                let cell = sheet.cell(at: addr)
                guard cell.styleIndex != 0 else { continue }
                let borders = document.workbook.style(at: cell.styleIndex).borders
                guard !borders.isEmpty else { continue }
                let rect = cellRect(addr, layout: l)
                let merge = sheet.mergedRange(containing: addr)
                if let line = borders.top, merge.map({ $0.start.row == addr.row }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY))
                }
                if let line = borders.bottom, merge.map({ $0.end.row == addr.row }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.maxY))
                }
                if let line = borders.left, merge.map({ $0.start.column == addr.column }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX, y: rect.maxY))
                }
                if let line = borders.right, merge.map({ $0.end.column == addr.column }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
                }
            }
        }
    }

    /// Stroke one border edge in Excel's line styles. Automatic colour is
    /// the label colour, so borders stay visible in dark mode.
    private func strokeBorder(_ line: BorderLine, from a: CGPoint, to b: CGPoint) {
        (line.color.map(nsColor) ?? NSColor.labelColor).setStroke()
        let horizontal = a.y == b.y
        func stroke(offset: CGFloat, width: CGFloat, dash: [CGFloat]) {
            let path = NSBezierPath()
            let dx: CGFloat = horizontal ? 0 : offset, dy: CGFloat = horizontal ? offset : 0
            // Extend half a width at each end so corners meet squarely.
            let ext = width / 2
            let ex: CGFloat = horizontal ? ext : 0, ey: CGFloat = horizontal ? 0 : ext
            path.move(to: CGPoint(x: a.x + dx - ex, y: a.y + dy - ey))
            path.line(to: CGPoint(x: b.x + dx + ex, y: b.y + dy + ey))
            path.lineWidth = width
            if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
            path.stroke()
        }
        switch line.style {
        case .hair: stroke(offset: 0, width: 0.5, dash: [])
        case .thin: stroke(offset: 0, width: 1, dash: [])
        case .medium: stroke(offset: 0, width: 2, dash: [])
        case .thick: stroke(offset: 0, width: 3, dash: [])
        case .double:
            // Two hairline-gap lines, offset to land on whole pixels.
            stroke(offset: -1.5, width: 1, dash: [])
            stroke(offset: 1.5, width: 1, dash: [])
        case .dotted: stroke(offset: 0, width: 1, dash: [1, 1])
        case .dashed: stroke(offset: 0, width: 1, dash: [3, 2])
        case .dashDot: stroke(offset: 0, width: 1, dash: [4, 2, 1, 2])
        case .dashDotDot: stroke(offset: 0, width: 1, dash: [4, 2, 1, 2, 1, 2])
        case .slantDashDot: stroke(offset: 0, width: 2, dash: [5, 1, 2, 1])
        case .mediumDashed: stroke(offset: 0, width: 2, dash: [5, 2])
        case .mediumDashDot: stroke(offset: 0, width: 2, dash: [5, 2, 2, 2])
        case .mediumDashDotDot: stroke(offset: 0, width: 2, dash: [5, 2, 2, 2, 2, 2])
        }
    }

    private func pivotBands(_ document: SpreadsheetDocument) -> [PivotBands] {
        let sheetID = document.activeSheetID
        if let cache = pivotBandsCache, cache.revision == document.revision, cache.sheetID == sheetID {
            return cache.bands
        }
        let tables = document.workbook.pivotTables(onSheet: sheetID)
        let bands = tables.map { table in
            PivotBands(location: table.location, role: { document.pivotRole(at: $0) })
        }
        pivotBandsCache = (document.revision, sheetID, bands)
        return bands
    }

    /// The thin rules under each pivot's header rows and above its grand
    /// total rows, across the table body.
    private func drawPivotRules(_ bands: [PivotBands], role: (CellAddress) -> PivotCellRole?,
                                layout l: GridLayout, rows: ClosedRange<Int>) {
        let rules = NSBezierPath()
        rules.lineWidth = 1
        for band in bands {
            let minX = contentOrigin.x + l.xOffset(ofColumn: band.location.start.column)
            let maxX = contentOrigin.x + l.xOffset(ofColumn: band.location.end.column + 1)
            func rule(atTopOf row: Int) {
                // Centred on the grid line (half-pixel) so it covers it.
                let y = contentOrigin.y + l.yOffset(ofRow: row) + 0.5
                rules.move(to: CGPoint(x: minX, y: y))
                rules.line(to: CGPoint(x: maxX, y: y))
            }
            if let header = band.headerRows, rows.contains(header.upperBound + 1) || rows.contains(header.upperBound) {
                rule(atTopOf: header.upperBound + 1)
            }
            let lo = max(rows.lowerBound, band.location.start.row)
            let hi = min(rows.upperBound, band.location.end.row)
            if lo <= hi {
                for row in lo...hi where band.isGrandTotalRow(row, role: role) {
                    // Consecutive grand-total rows share one rule on top.
                    if !band.isGrandTotalRow(row - 1, role: role) { rule(atTopOf: row) }
                }
            }
        }
        SpreadsheetGridView.pivotRuleColor.setStroke()
        rules.stroke()
    }

    /// Width a pivot field button takes at a cell's right edge (box + gap).
    static let pivotButtonSize: CGFloat = 11
    static let pivotButtonReserve: CGFloat = pivotButtonSize + 4

    /// Excel's pivot field (filter) button: a small rounded box with a
    /// down chevron, at the cell's right edge, vertically centred.
    private func drawPivotButton(in cell: CGRect) {
        let size = min(SpreadsheetGridView.pivotButtonSize, cell.height - 4)
        guard size > 4 else { return }
        let box = CGRect(x: (cell.maxX - size - 3).rounded() + 0.5,
                         y: (cell.midY - size / 2).rounded() + 0.5,
                         width: size - 1, height: size - 1)
        let outline = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
        NSColor.controlBackgroundColor.setFill()
        outline.fill()
        NSColor.tertiaryLabelColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        let chevron = NSBezierPath()
        let w = box.width * 0.24, h = box.height * 0.13
        chevron.move(to: CGPoint(x: box.midX - w, y: box.midY - h))
        chevron.line(to: CGPoint(x: box.midX, y: box.midY + h + 0.5))
        chevron.line(to: CGPoint(x: box.midX + w, y: box.midY - h))
        chevron.lineWidth = 1.3
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        chevron.stroke()
    }

    /// The box an AutoFilter or pivot button occupies in a cell (view or
    /// content coordinates alike): at the right edge, vertically centred.
    static func dropdownButtonRect(in cell: CGRect) -> CGRect? {
        let size = min(pivotButtonSize, cell.height - 4)
        guard size > 4 else { return nil }
        return CGRect(x: (cell.maxX - size - 3).rounded() + 0.5,
                      y: (cell.midY - size / 2).rounded() + 0.5,
                      width: size - 1, height: size - 1)
    }

    /// An AutoFilter button: the pivot field button, or when the column is
    /// filtered, the box in the accent colour with a funnel in it.
    private func drawFilterButton(in cell: CGRect, active: Bool) {
        guard active else {
            drawPivotButton(in: cell)
            return
        }
        guard let box = SpreadsheetGridView.dropdownButtonRect(in: cell) else { return }
        let outline = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        outline.fill()
        NSColor.controlAccentColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        // A funnel: a triangle over a short stem.
        let funnel = NSBezierPath()
        let w = box.width * 0.32, top = box.midY - box.height * 0.22
        funnel.move(to: CGPoint(x: box.midX - w, y: top))
        funnel.line(to: CGPoint(x: box.midX + w, y: top))
        funnel.line(to: CGPoint(x: box.midX + 0.8, y: box.midY + 0.5))
        funnel.line(to: CGPoint(x: box.midX + 0.8, y: box.midY + box.height * 0.26))
        funnel.line(to: CGPoint(x: box.midX - 0.8, y: box.midY + box.height * 0.18))
        funnel.line(to: CGPoint(x: box.midX - 0.8, y: box.midY + 0.5))
        funnel.close()
        NSColor.controlAccentColor.setFill()
        funnel.fill()
    }

    /// The columns whose text can show in `row`: every visible column, plus
    /// the nearest non-empty cell on each side, whose text may spill into view.
    private func textSourceColumns(row: Int, visible cols: ClosedRange<Int>,
                                   layout l: GridLayout) -> ClosedRange<Int> {
        guard let sheet = document?.activeSheet else { return cols }
        let scanLimit = 256
        var first = cols.lowerBound
        var c = cols.lowerBound - 1
        while c >= max(0, cols.lowerBound - scanLimit) {
            if !sheet.cell(at: CellAddress(row: row, column: c)).value.isEmpty {
                first = c
                break
            }
            c -= 1
        }
        var last = cols.upperBound
        c = cols.upperBound + 1
        while c < min(l.columnCount, cols.upperBound + 1 + scanLimit) {
            if !sheet.cell(at: CellAddress(row: row, column: c)).value.isEmpty {
                last = c
                break
            }
            c += 1
        }
        return first...last
    }

    /// Draws a cell's text and returns the columns it covered (more than one
    /// when non-wrapped text spills into empty neighbours, as in Excel).
    /// `reserveButton` keeps text clear of a filter button; `rectOverride`
    /// draws a merged cell across its whole range (merged text never spills).
    @discardableResult
    private func drawCellText(cell: Cell, style: CellStyle, at address: CellAddress,
                              layout l: GridLayout, reserveButton: Bool = false,
                              in rectOverride: CGRect? = nil) -> ClosedRange<Int> {
        let own = address.column...address.column
        guard let document else { return own }
        let rect = rectOverride ?? cellRect(address, layout: l)
        let hasButton = style.pivotButton || reserveButton
        let text = NumberFormatEngine.displayString(for: cell.value, format: style.numberFormat)
        guard !text.isEmpty else { return own }

        let fontSize = style.fontSize ?? CellStyle.defaultFontSize
        var font = NSFont(name: style.fontName ?? CellStyle.defaultFontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor.map(nsColor) ?? NSColor.textColor,
        ]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = style.wrapText ? .byWordWrapping : .byClipping
        let alignment: NSTextAlignment
        switch style.horizontalAlignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        case .automatic:
            switch cell.value {
            case .number: alignment = .right
            case .bool, .error: alignment = .center
            default: alignment = .left
            }
        }
        paragraph.alignment = alignment
        attributes[.paragraphStyle] = paragraph

        let horizontalInset: CGFloat = 3
        var inset = rect.insetBy(dx: horizontalInset, dy: 2)
        // A pivot field button sits at the right edge; text stops short of it.
        if hasButton {
            inset.size.width = max(0, inset.width - SpreadsheetGridView.pivotButtonReserve + horizontalInset)
        }
        let indent = CellTextIndent.width(level: style.indent, fontSize: fontSize)
        inset = CellTextIndent.apply(indent, to: inset, rightAligned: alignment == .right,
                                     centered: alignment == .center)
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        var drawRect = inset
        if !style.wrapText {
            // Vertical alignment for single-line content.
            switch style.verticalAlignment {
            case .top: break
            case .middle: drawRect.origin.y += max(0, (inset.height - textSize.height) / 2)
            case .bottom: drawRect.origin.y += max(0, inset.height - textSize.height)
            }
            drawRect.size.height = min(inset.height, textSize.height)
        }

        // Only text overflows. Numbers, booleans and errors stay in their cell.
        var span = own
        if !style.wrapText, !hasButton, rectOverride == nil, case .string = cell.value {
            let needed = ceil(textSize.width) + 2 * horizontalInset + 1
                + (alignment == .center ? 0 : indent)
            let direction: TextOverflow.Direction
            switch alignment {
            case .right: direction = .left
            case .center: direction = .both
            default: direction = .right
            }
            let sheet = document.activeSheet
            span = TextOverflow.span(
                column: address.column, neededWidth: needed, direction: direction,
                columnCount: l.columnCount,
                columnWidth: { l.columnWidth($0) },
                isEmpty: {
                    let neighbour = CellAddress(row: address.row, column: $0)
                    return sheet.cell(at: neighbour).value.isEmpty && sheet.mergedRange(containing: neighbour) == nil
                })
        }

        if span == own {
            if hasButton || rectOverride != nil {
                // Keep long field names from running under the button.
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: drawRect).addClip()
                attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin])
                NSGraphicsContext.restoreGraphicsState()
                return own
            }
            // .usesLineFragmentOrigin is required for rect-based drawing;
            // without it the origin is interpreted as a text BASELINE.
            attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin])
            return own
        }

        // Spilled text: lay it out at its full width, anchored the way its
        // alignment says, and clip it to the run of cells it may use.
        let first = cellRect(CellAddress(row: address.row, column: span.lowerBound), layout: l)
        let last = cellRect(CellAddress(row: address.row, column: span.upperBound), layout: l)
        let spanRect = first.union(last)
        let fullWidth = ceil(textSize.width) + 1
        switch alignment {
        case .right: drawRect.origin.x = inset.maxX - fullWidth
        case .center: drawRect.origin.x = rect.midX - fullWidth / 2
        default: break
        }
        drawRect.size.width = fullWidth
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: spanRect.insetBy(dx: 1, dy: 0)).addClip()
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return span
    }

    private func drawHeaders(layout l: GridLayout, visible: CGRect, selectionRange: CellRange) {
        let headerFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

        // Column header strip.
        let colStrip = CGRect(x: visible.minX, y: visible.minY,
                              width: visible.width, height: GridLayout.headerHeight)
        SpreadsheetGridView.headerColor.setFill()
        colStrip.fill()
        // Row header strip.
        let rowStrip = CGRect(x: visible.minX, y: visible.minY,
                              width: GridLayout.headerWidth, height: visible.height)
        SpreadsheetGridView.headerColor.setFill()
        rowStrip.fill()

        // Column labels, per band: frozen columns stay put, the rest scroll.
        for (cols, shift, minX, maxX) in columnBands(layout: l, visible: visible) where maxX > minX {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: minX, y: visible.minY, width: maxX - minX,
                                      height: GridLayout.headerHeight)).addClip()
            for col in cols {
                let x = contentOrigin.x + l.xOffset(ofColumn: col) + shift
                let rect = CGRect(x: x, y: visible.minY, width: l.columnWidth(col),
                                  height: GridLayout.headerHeight)
                let isSelected = col >= selectionRange.start.column && col <= selectionRange.end.column
                if isSelected {
                    NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                    rect.fill()
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                ]
                let label = NSAttributedString(string: CellAddress.columnName(col), attributes: attrs)
                let size = label.size()
                label.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                       y: rect.midY - size.height / 2))
                SpreadsheetGridView.gridLineColor.setStroke()
                let tick = NSBezierPath()
                tick.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                tick.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
                tick.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Row labels. Hidden rows have no label; rows under an active filter
        // are numbered in blue, as in Excel.
        let filter = l.sheet.autoFilter
        let filteredRows = filter?.isFiltering == true ? filter?.dataRows : nil
        for (rows, shift, minY, maxY) in rowBands(layout: l, visible: visible) where maxY > minY {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: visible.minX, y: minY, width: GridLayout.headerWidth,
                                      height: maxY - minY)).addClip()
            for row in rows where l.rowHeight(row) > 0 {
                let y = contentOrigin.y + l.yOffset(ofRow: row) + shift
                let rect = CGRect(x: visible.minX, y: y, width: GridLayout.headerWidth,
                                  height: l.rowHeight(row))
                let isSelected = row >= selectionRange.start.row && row <= selectionRange.end.row
                if isSelected {
                    NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                    rect.fill()
                }
                let color: NSColor
                if isSelected {
                    color = .controlAccentColor
                } else if filteredRows?.contains(row) == true {
                    color = .systemBlue
                } else {
                    color = .secondaryLabelColor
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: color]
                let label = NSAttributedString(string: String(row + 1), attributes: attrs)
                let size = label.size()
                label.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                       y: rect.midY - size.height / 2))
                // A row after hidden rows gets a heavier rule above it, so the
                // gap in the numbering is easy to spot.
                if row > 0, l.sheet.hiddenRows.contains(row - 1) {
                    NSColor.secondaryLabelColor.setStroke()
                    let mark = NSBezierPath()
                    mark.lineWidth = 2
                    mark.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    mark.line(to: CGPoint(x: rect.maxX, y: rect.minY))
                    mark.stroke()
                }
                SpreadsheetGridView.gridLineColor.setStroke()
                let tick = NSBezierPath()
                tick.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                tick.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
                tick.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Header edges. When the sheet is scrolled, part of a column sits
        // right next to the row headers; without these lines that slice of
        // cells looked like part of the header (most visible when zoomed).
        SpreadsheetGridView.gridLineColor.setStroke()
        let edges = NSBezierPath()
        edges.move(to: CGPoint(x: rowStrip.maxX, y: visible.minY))
        edges.line(to: CGPoint(x: rowStrip.maxX, y: visible.maxY))
        edges.move(to: CGPoint(x: visible.minX, y: colStrip.maxY))
        edges.line(to: CGPoint(x: visible.maxX, y: colStrip.maxY))
        edges.stroke()

        // Corner (select-all) box.
        let corner = CGRect(x: visible.minX, y: visible.minY,
                            width: GridLayout.headerWidth, height: GridLayout.headerHeight)
        SpreadsheetGridView.headerColor.setFill()
        corner.fill()
        SpreadsheetGridView.gridLineColor.setStroke()
        NSBezierPath(rect: corner).stroke()
    }

    private func nsColor(_ c: RGBAColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255,
                blue: CGFloat(c.blue) / 255, alpha: CGFloat(c.alpha) / 255)
    }

    // MARK: Scrolling


    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func scrolled() {
        needsDisplay = true
    }

    /// Scroll so the active cell (or its merged range) shows clear of the
    /// headers and any frozen pane. Frozen cells are always in view.
    func scrollActiveCellToVisible() {
        guard let document, let scroll = enclosingScrollView else { return }
        let l = layout
        let active = document.selection.activeCell
        let target = l.sheet.mergedRange(containing: active) ?? CellRange(active)
        let rect = cellRect(target.start, layout: l).union(cellRect(target.end, layout: l))
        let visible = scroll.documentVisibleRect
        var origin = visible.origin
        let margin: CGFloat = 20
        if active.row >= l.frozenRows {
            let top = visible.minY + contentOrigin.y + l.frozenHeight
            if rect.minY < top {
                origin.y = rect.minY - contentOrigin.y - l.frozenHeight
            } else if rect.maxY + margin > visible.maxY {
                origin.y = min(rect.minY - contentOrigin.y - l.frozenHeight,
                               rect.maxY + margin - visible.height)
            }
        }
        if active.column >= l.frozenColumns {
            let left = visible.minX + contentOrigin.x + l.frozenWidth
            if rect.minX < left {
                origin.x = rect.minX - contentOrigin.x - l.frozenWidth
            } else if rect.maxX + margin > visible.maxX {
                origin.x = min(rect.minX - contentOrigin.x - l.frozenWidth,
                               rect.maxX + margin - visible.width)
            }
        }
        origin.x = max(0, min(origin.x, bounds.width - visible.width))
        origin.y = max(0, min(origin.y, bounds.height - visible.height))
        if origin != visible.origin {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            needsDisplay = true
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        // Control-click arrives as a plain mouseDown; route it to the context menu.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let l = layout

        document.commitPendingEdit() // the in-cell editor or the formula bar

        let inColumnHeader = point.y < visible.minY + GridLayout.headerHeight
        let inRowHeader = point.x < visible.minX + GridLayout.headerWidth

        if inColumnHeader && inRowHeader {
            // Select-all corner.
            let used = document.activeSheet.usedRange
                ?? CellRange(CellAddress(row: 0, column: 0))
            document.selection.select(range: CellRange(
                start: CellAddress(row: 0, column: 0), end: used.end))
            stateChanged()
            return
        }

        if inColumnHeader {
            let content = contentPoint(point)
            let col = l.column(atX: content.x)
            // Resize hot zone: within 4pt of a column boundary.
            if let resizeCol = columnBoundary(near: content.x, layout: l) {
                dragMode = .resizeColumn(index: resizeCol, startWidth: l.columnWidth(resizeCol),
                                         startX: point.x)
                if event.clickCount == 2 {
                    autofitColumn(resizeCol)
                    dragMode = .none
                }
                return
            }
            let range = CellRange(start: CellAddress(row: 0, column: col),
                                  end: CellAddress(row: l.rowCount - 1, column: col))
            if event.modifierFlags.contains(.shift) {
                let anchorCol = document.selection.anchor.column
                document.selection.select(range: CellRange(
                    start: CellAddress(row: 0, column: min(anchorCol, col)),
                    end: CellAddress(row: l.rowCount - 1, column: max(anchorCol, col))),
                    active: CellAddress(row: 0, column: anchorCol))
            } else {
                document.selection.select(range: range, active: CellAddress(row: 0, column: col))
            }
            dragMode = .selectColumns(anchor: col)
            stateChanged()
            return
        }

        if inRowHeader {
            let content = contentPoint(point)
            let row = l.row(atY: content.y)
            if let resizeRow = rowBoundary(near: content.y, layout: l) {
                dragMode = .resizeRow(index: resizeRow, startHeight: l.rowHeight(resizeRow),
                                      startY: point.y)
                return
            }
            let range = CellRange(start: CellAddress(row: row, column: 0),
                                  end: CellAddress(row: row, column: l.columnCount - 1))
            if event.modifierFlags.contains(.shift) {
                let anchorRow = document.selection.anchor.row
                document.selection.select(range: CellRange(
                    start: CellAddress(row: min(anchorRow, row), column: 0),
                    end: CellAddress(row: max(anchorRow, row), column: l.columnCount - 1)),
                    active: CellAddress(row: anchorRow, column: 0))
            } else {
                document.selection.select(range: range, active: CellAddress(row: row, column: 0))
            }
            dragMode = .selectRows(anchor: row)
            stateChanged()
            return
        }

        // Fill handle?
        let selRect = viewRect(document.selection.range.start, layout: l)
            .union(viewRect(document.selection.range.end, layout: l))
        let handle = CGRect(x: selRect.maxX - 6, y: selRect.maxY - 6, width: 12, height: 12)
        if handle.contains(point) {
            dragMode = .fillHandle(source: document.selection.range)
            return
        }

        let content = contentPoint(point)
        let addr = CellAddress(row: l.row(atY: content.y), column: l.column(atX: content.x))

        // AutoFilter button?
        if let filter = l.sheet.autoFilter, addr.row == filter.headerRow,
           filter.range.start.column...filter.range.end.column ~= addr.column,
           let button = SpreadsheetGridView.dropdownButtonRect(in: viewRectIncludingMerge(addr, layout: l)),
           button.insetBy(dx: -3, dy: -3).contains(point) {
            showFilterPopover(columnOffset: addr.column - filter.range.start.column,
                              from: viewRectIncludingMerge(addr, layout: l))
            return
        }

        if event.clickCount == 2 {
            beginEditing(mode: .edit, initialText: nil)
            return
        }
        if event.modifierFlags.contains(.shift) {
            document.selection.extend(to: addr)
            normalizeSelectionForMerges()
        } else if let merge = l.sheet.mergedRange(containing: addr) {
            document.selection.select(range: merge, active: merge.start)
        } else {
            document.selection.select(addr)
        }
        dragMode = .selectCells
        stateChanged()
    }

    /// Grow the selection so it never cuts through a merged range, keeping
    /// the anchor and focus on their sides of it.
    private func normalizeSelectionForMerges() {
        guard let document else { return }
        let sheet = document.activeSheet
        guard !sheet.mergedRanges.isEmpty else { return }
        var selection = document.selection
        let range = selection.range
        let grown = sheet.expandedForMerges(range)
        guard grown != range else { return }
        let anchorTop = selection.anchor.row <= selection.focus.row
        let anchorLeft = selection.anchor.column <= selection.focus.column
        selection.anchor = CellAddress(row: anchorTop ? grown.start.row : grown.end.row,
                                       column: anchorLeft ? grown.start.column : grown.end.column)
        selection.focus = CellAddress(row: anchorTop ? grown.end.row : grown.start.row,
                                      column: anchorLeft ? grown.end.column : grown.start.column)
        document.selection = selection
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document else { return }
        let point = convert(event.locationInWindow, from: nil)
        let l = layout
        let content = contentPoint(point)

        switch dragMode {
        case .selectCells:
            let addr = CellAddress(row: l.row(atY: max(0, content.y)),
                                   column: l.column(atX: max(0, content.x)))
            let anchor = document.selection.anchor
            document.selection.extend(to: addr)
            // Keep the anchor's merge whole when the drag started on one.
            if let merge = l.sheet.mergedRange(containing: anchor), merge.contains(addr) {
                document.selection.select(range: merge, active: merge.start)
            } else {
                normalizeSelectionForMerges()
            }
            autoscroll(with: event)
            stateChanged()
        case .selectColumns(let anchor):
            let col = l.column(atX: max(0, content.x))
            document.selection.select(range: CellRange(
                start: CellAddress(row: 0, column: min(anchor, col)),
                end: CellAddress(row: l.rowCount - 1, column: max(anchor, col))),
                active: CellAddress(row: 0, column: anchor))
            stateChanged()
        case .selectRows(let anchor):
            let row = l.row(atY: max(0, content.y))
            document.selection.select(range: CellRange(
                start: CellAddress(row: min(anchor, row), column: 0),
                end: CellAddress(row: max(anchor, row), column: l.columnCount - 1)),
                active: CellAddress(row: anchor, column: 0))
            stateChanged()
        case .resizeColumn(let index, let startWidth, let startX):
            let newWidth = max(16, startWidth + (point.x - startX))
            document.setColumnWidth(index, width: newWidth)
            refreshSize()
        case .resizeRow(let index, let startHeight, let startY):
            let newHeight = max(14, startHeight + (point.y - startY))
            document.setRowHeight(index, height: newHeight)
            refreshSize()
        case .fillHandle(let source):
            // Constrain fill to one axis (the dominant drag direction).
            let addr = CellAddress(row: l.row(atY: max(0, content.y)),
                                   column: l.column(atX: max(0, content.x)))
            var target = source
            if addr.row > source.end.row {
                target = CellRange(start: source.start,
                                   end: CellAddress(row: addr.row, column: source.end.column))
            } else if addr.column > source.end.column {
                target = CellRange(start: source.start,
                                   end: CellAddress(row: source.end.row, column: addr.column))
            } else if addr.row < source.start.row {
                target = CellRange(start: CellAddress(row: addr.row, column: source.start.column),
                                   end: source.end)
            } else if addr.column < source.start.column {
                target = CellRange(start: CellAddress(row: source.start.row, column: addr.column),
                                   end: source.end)
            }
            pendingFillTarget = target
            needsDisplay = true
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .fillHandle(let source) = dragMode, let target = pendingFillTarget,
           target != source {
            document?.fill(from: source, to: target)
            stateChanged()
        }
        switch dragMode {
        case .selectCells, .selectRows, .selectColumns:
            if document?.formatPainterStyles != nil {
                document?.applyFormatPainter()
                stateChanged()
            }
        default:
            break
        }
        pendingFillTarget = nil
        dragMode = .none
        needsDisplay = true
    }

    // MARK: Context menu

    /// Right-click on a row/column header: insert or delete rows/columns.
    /// Like Excel, clicking outside the current selection selects that
    /// row/column first; clicking inside it acts on the whole selection.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let document else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let l = layout
        let inColumnHeader = point.y < visible.minY + GridLayout.headerHeight
        let inRowHeader = point.x < visible.minX + GridLayout.headerWidth
        guard inColumnHeader != inRowHeader else { return nil }

        document.commitPendingEdit()
        let content = contentPoint(point)
        let menu = NSMenu()

        if inRowHeader {
            let row = l.row(atY: content.y)
            var range = document.selection.range
            if !(range.start.row...range.end.row).contains(row) {
                range = CellRange(start: CellAddress(row: row, column: 0),
                                  end: CellAddress(row: row, column: l.columnCount - 1))
                document.selection.select(range: range, active: CellAddress(row: row, column: 0))
                stateChanged()
            }
            let start = range.start.row, end = range.end.row, count = range.rowCount
            let noun = count == 1 ? "Row" : "\(count) Rows"
            menu.addItem(ActionMenuItem("Insert \(noun) Above") { [weak self] in
                self?.document?.insertRows(at: start, count: count)
                self?.stateChanged()
            })
            menu.addItem(ActionMenuItem("Insert \(noun) Below") { [weak self] in
                self?.document?.insertRows(at: end + 1, count: count)
                self?.stateChanged()
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete \(noun)") { [weak self] in
                self?.document?.deleteRows(at: start, count: count)
                self?.stateChanged()
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Hide \(noun)") { [weak self] in
                self?.document?.hideRows(start...end)
                self?.stateChanged()
            })
            // Unhide covers the rows around a gap: select rows 3–6 to show 4–5.
            if document.activeSheet.hiddenRows.contains(where: (start...end).contains) {
                menu.addItem(ActionMenuItem("Unhide Rows") { [weak self] in
                    self?.document?.unhideRows(start...end)
                    self?.stateChanged()
                })
            }
        } else {
            let col = l.column(atX: content.x)
            var range = document.selection.range
            if !(range.start.column...range.end.column).contains(col) {
                range = CellRange(start: CellAddress(row: 0, column: col),
                                  end: CellAddress(row: l.rowCount - 1, column: col))
                document.selection.select(range: range, active: CellAddress(row: 0, column: col))
                stateChanged()
            }
            let start = range.start.column, end = range.end.column, count = range.columnCount
            let noun = count == 1 ? "Column" : "\(count) Columns"
            menu.addItem(ActionMenuItem("Insert \(noun) Left") { [weak self] in
                self?.document?.insertColumns(at: start, count: count)
                self?.stateChanged()
            })
            menu.addItem(ActionMenuItem("Insert \(noun) Right") { [weak self] in
                self?.document?.insertColumns(at: end + 1, count: count)
                self?.stateChanged()
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete \(noun)") { [weak self] in
                self?.document?.deleteColumns(at: start, count: count)
                self?.stateChanged()
            })
        }
        return menu
    }

    override func resetCursorRects() {
        // Column/row resize cursors over header boundaries, per pane.
        guard let scroll = enclosingScrollView else { return }
        let visible = scroll.documentVisibleRect
        let l = layout
        for (cols, shift, minX, maxX) in columnBands(layout: l, visible: visible) {
            for col in cols {
                let x = contentOrigin.x + l.xOffset(ofColumn: col) + l.columnWidth(col) + shift
                guard x >= minX, x <= maxX else { continue }
                let rect = CGRect(x: x - 3, y: visible.minY, width: 6, height: GridLayout.headerHeight)
                addCursorRect(rect, cursor: .resizeLeftRight)
            }
        }
        for (rows, shift, minY, maxY) in rowBands(layout: l, visible: visible) {
            for row in rows where l.rowHeight(row) > 0 {
                let y = contentOrigin.y + l.yOffset(ofRow: row) + l.rowHeight(row) + shift
                guard y >= minY, y <= maxY else { continue }
                let rect = CGRect(x: visible.minX, y: y - 3, width: GridLayout.headerWidth, height: 6)
                addCursorRect(rect, cursor: .resizeUpDown)
            }
        }
    }

    /// The column whose right edge is within 4pt of x, if any.
    private func columnBoundary(near x: CGFloat, layout l: GridLayout) -> Int? {
        let col = l.column(atX: x)
        if col > 0, abs(x - l.xOffset(ofColumn: col)) <= 4 { return col - 1 }
        if abs(x - l.xOffset(ofColumn: col + 1)) <= 4 { return col }
        return nil
    }

    /// The row whose bottom edge is within 4pt of y. At a run of hidden
    /// rows, the visible row above them (they share that edge).
    private func rowBoundary(near y: CGFloat, layout l: GridLayout) -> Int? {
        let row = l.row(atY: y)
        if row > 0, abs(y - l.yOffset(ofRow: row)) <= 4 {
            var above = row - 1
            while above > 0, l.rowHeight(above) == 0 { above -= 1 }
            return above
        }
        if abs(y - l.yOffset(ofRow: row + 1)) <= 4 { return row }
        return nil
    }

    private func autofitColumn(_ column: Int) {
        guard let document else { return }
        var maxWidth: CGFloat = 30
        for (addr, cell) in document.activeSheet.cells where addr.column == column {
            let style = document.workbook.style(at: cell.styleIndex)
            let text = NumberFormatEngine.displayString(for: cell.value, format: style.numberFormat)
            let font = NSFont(name: style.fontName ?? CellStyle.defaultFontName,
                              size: style.fontSize ?? CellStyle.defaultFontSize)
                ?? NSFont.systemFont(ofSize: CellStyle.defaultFontSize)
            let width = (text as NSString).size(withAttributes: [.font: font]).width + 12
            maxWidth = max(maxWidth, width)
        }
        document.setColumnWidth(column, width: min(maxWidth, 500))
        refreshSize()
    }

    // MARK: Keyboard (Ready mode)

    override func keyDown(with event: NSEvent) {
        guard let document else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShift = flags.contains(.shift)
        let hasCommand = flags.contains(.command)
        let l = layout

        func direction(for keyCode: UInt16) -> SelectionState.Direction? {
            switch keyCode {
            case 123: return .left
            case 124: return .right
            case 125: return .down
            case 126: return .up
            default: return nil
            }
        }

        if event.keyCode == 53, document.formatPainterStyles != nil { // Esc
            document.cancelFormatPainter()
            return
        }

        if let dir = direction(for: event.keyCode) {
            if hasCommand {
                let edge = SelectionState.dataEdge(
                    from: hasShift ? document.selection.focus : document.selection.activeCell,
                    direction: dir, sheet: document.activeSheet,
                    rowLimit: l.rowCount, columnLimit: l.columnCount)
                if hasShift {
                    document.selection.extend(to: edge)
                } else {
                    document.selection.select(edge)
                }
            } else if hasShift {
                navigate(dir, extend: true)
            } else {
                navigate(dir)
            }
            afterNavigation()
            return
        }

        switch event.keyCode {
        case 36: // Return
            if hasShift {
                navigate(.up)
            } else {
                navigate(.down)
            }
            afterNavigation()
        case 48: // Tab
            if hasShift {
                navigate(.left)
            } else {
                navigate(.right)
            }
            afterNavigation()
        case 51, 117: // Delete / Forward delete
            document.clearSelectionContents()
            needsDisplay = true
        case 122: // F2
            beginEditing(mode: .edit, initialText: nil)
        case 115: // Home
            document.selection.select(CellAddress(row: document.selection.activeCell.row, column: 0))
            afterNavigation()
        case 116: // Page Up
            page(by: -1)
        case 121: // Page Down
            page(by: 1)
        case 53: // Escape
            break
        default:
            guard !hasCommand else {
                super.keyDown(with: event)
                return
            }
            if Self.startsTyping(event) {
                // Type-to-replace: open an empty Enter-mode editor and hand
                // it this key, so an input method (Japanese, Chinese, dead
                // keys) composes it rather than receiving it raw.
                beginEditing(mode: .enter, initialText: "")
                if let fieldEditor = editorField?.currentEditor() {
                    fieldEditor.keyDown(with: event)
                } else {
                    // No window, so no field editor (tests): type it in.
                    editorField?.stringValue = event.characters ?? ""
                }
                return
            }
            super.keyDown(with: event)
        }
    }

    /// Whether a key (without ⌘) starts type-to-replace editing: a printable
    /// character, or a dead key (no characters yet) for the input method to
    /// compose. Function keys (End, Help, F1–F35…, reported as private-use
    /// characters U+F700–U+F8FF) and control characters do not.
    static func startsTyping(_ event: NSEvent) -> Bool {
        if event.specialKey != nil { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.function) {
            return false
        }
        guard let characters = event.characters else { return false }
        guard let first = characters.unicodeScalars.first else {
            return true // a dead key: the editor's input method composes it
        }
        if (0xF700...0xF8FF).contains(first.value) { return false }
        return !CharacterSet.controlCharacters.contains(first)
    }

    /// Arrow/Return/Tab movement. Steps out of a merged range from its far
    /// edge, lands on a merged range as a whole, and skips hidden rows.
    private func navigate(_ direction: SelectionState.Direction, extend: Bool = false) {
        guard let document else { return }
        let l = layout
        let sheet = l.sheet
        func step(_ from: CellAddress) -> CellAddress {
            var next = SelectionState.step(from: from, direction: direction,
                                           rowLimit: l.rowCount, columnLimit: l.columnCount)
            // Skip rows a filter (or the user) hid, unless only hidden rows remain.
            var probe = next
            while sheet.hiddenRows.contains(probe.row) {
                let after = SelectionState.step(from: probe, direction: direction,
                                                rowLimit: l.rowCount, columnLimit: l.columnCount)
                if after == probe { break }
                probe = after
            }
            if !sheet.hiddenRows.contains(probe.row) { next = probe }
            return next
        }
        if extend {
            var selection = document.selection
            selection.focus = step(selection.focus)
            selection.activeCell = selection.anchor
            document.selection = selection
            normalizeSelectionForMerges()
            return
        }
        var from = document.selection.activeCell
        if let merge = sheet.mergedRange(containing: from) {
            switch direction {
            case .down: from.row = merge.end.row
            case .up: from.row = merge.start.row
            case .right: from.column = merge.end.column
            case .left: from.column = merge.start.column
            }
        }
        let next = step(from)
        if let merge = sheet.mergedRange(containing: next) {
            document.selection.select(range: merge, active: merge.start)
        } else {
            document.selection.select(next)
        }
    }

    private func page(by direction: Int) {
        guard let document, let scroll = enclosingScrollView else { return }
        let visibleRows = Int((scroll.documentVisibleRect.height - GridLayout.headerHeight)
            / max(1, document.activeSheet.defaultRowHeight))
        let delta = max(1, visibleRows - 2) * direction
        let l = layout
        let newRow = min(max(0, document.selection.activeCell.row + delta), l.rowCount - 1)
        document.selection.select(CellAddress(row: newRow, column: document.selection.activeCell.column))
        afterNavigation()
    }

    private func afterNavigation() {
        needsDisplay = true
        scrollActiveCellToVisible()
        stateChanged()
    }

    func selectAll2() {
        guard let document else { return }
        document.commitPendingEdit()
        let used = document.activeSheet.usedRange ?? CellRange(CellAddress(row: 0, column: 0))
        document.selection.select(range: CellRange(start: CellAddress(row: 0, column: 0),
                                                   end: used.end))
        needsDisplay = true
        stateChanged()
    }

    override func selectAll(_ sender: Any?) {
        selectAll2()
    }

    private func stateChanged() {
        needsDisplay = true
        onStateChange?()
    }

    // MARK: Edit menu (responder chain)

    // The standard Edit items send cut:/copy:/paste:/delete:/selectAll:/
    // undo:/redo: to the first responder. A focused text field (the cell
    // editor, formula bar, Find, name box, sheet rename) handles them first;
    // they reach the grid only when it is the first responder, or (undo and
    // redo) when the cell editor's field editor passes them up the chain.

    @objc func copy(_ sender: Any?) {
        document?.copySelectionToPasteboard()
    }

    @objc func cut(_ sender: Any?) {
        document?.copySelectionToPasteboard(cut: true)
        stateChanged()
    }

    @objc func paste(_ sender: Any?) {
        document?.pasteFromPasteboard()
        afterNavigation()
    }

    /// Edit ▸ Paste and Match Style, when the menu offers it.
    @objc func pasteAsPlainText(_ sender: Any?) {
        document?.pastePlainTextFromPasteboard()
        afterNavigation()
    }

    @objc func delete(_ sender: Any?) {
        document?.clearSelectionContents()
        stateChanged()
    }

    @objc func undo(_ sender: Any?) {
        if let typing = editorUndoManager {
            typing.undo()
            return
        }
        guard let document else { return }
        document.commitPendingEdit()
        document.undoManager.undo()
        stateChanged()
    }

    @objc func redo(_ sender: Any?) {
        if let typing = editorUndoManager {
            typing.redo()
            return
        }
        guard let document else { return }
        document.commitPendingEdit()
        document.undoManager.redo()
        stateChanged()
    }

    /// While the in-cell editor has focus, undo/redo arrive here from its
    /// field editor (the editor field is our subview) and belong to the
    /// typing, which the field editor records in its own undo manager.
    private var editorUndoManager: UndoManager? {
        guard isEditing, let text = window?.firstResponder as? NSTextView, text.isFieldEditor,
              text.delegate === editorField else { return nil }
        return text.undoManager
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let document else { return false }
        switch menuItem.action {
        case #selector(undo(_:)):
            let manager = editorUndoManager ?? document.undoManager
            menuItem.title = manager.undoMenuItemTitle
            return manager.canUndo
        case #selector(redo(_:)):
            let manager = editorUndoManager ?? document.undoManager
            menuItem.title = manager.redoMenuItemTitle
            return manager.canRedo
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return SpreadsheetDocument.pasteboardHasContent
        default:
            return true
        }
    }

    // MARK: Cell editor

    /// Begin in-place editing. `.enter` = typing replaced content (arrows
    /// commit); `.edit` = F2/double-click (arrows move the caret).
    func beginEditing(mode: EditMode, initialText: String?) {
        guard let document else { return }
        commitEditorIfNeeded()
        document.commitPendingEdit() // e.g. typing left in the formula bar
        let addr = document.selection.activeCell
        editingTarget = (document.activeSheetID, addr)
        editMode = mode

        // Scroll first: a frozen cell's position depends on the scroll offset.
        scrollActiveCellToVisible()
        let l = layout
        let rect = viewRectIncludingMerge(addr, layout: l).insetBy(dx: -1, dy: -1)
        let field = NSTextField(frame: rect)
        field.delegate = self
        field.isBordered = true
        field.focusRingType = .exterior
        field.font = NSFont(name: CellStyle.defaultFontName, size: CellStyle.defaultFontSize)
            ?? NSFont.systemFont(ofSize: CellStyle.defaultFontSize)
        field.stringValue = initialText ?? document.editString(at: addr)
        field.backgroundColor = .textBackgroundColor
        field.drawsBackground = true
        addSubview(field)
        editorField = field
        document.pendingEditor = self
        window?.makeFirstResponder(field)
        // Caret at end.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    /// Write the editor's text to the cell it was opened on and close it.
    /// `refocus`: give the grid keyboard focus back (not when the user has
    /// just clicked into another control).
    func commitEditorIfNeeded(refocus: Bool = true) {
        guard let field = editorField, let target = editingTarget else { return }
        let text = field.stringValue
        tearDownEditor(refocus: refocus)
        document?.commitInput(text, at: target.address, sheetID: target.sheetID)
        needsDisplay = true
        onStateChange?()
    }

    func cancelEditing() {
        tearDownEditor(refocus: true)
        needsDisplay = true
    }

    private func tearDownEditor(refocus: Bool) {
        guard let field = editorField else { return }
        // Clear the state first: taking focus away from the field ends its
        // editing, which calls back into controlTextDidEndEditing.
        editorField = nil
        editingTarget = nil
        editMode = .ready
        if let document, document.pendingEditor === self { document.pendingEditor = nil }
        if refocus, field.currentEditor() != nil { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
    }

    var isEditing: Bool { editorField != nil }
    /// Focus left the cell editor for another control (the formula bar,
    /// name box, Find field…): commit, as Numbers does, rather than leave
    /// an orphaned editor holding typing nobody can see being lost.
    nonisolated func controlTextDidEndEditing(_ notification: Notification) {
        let ended = notification.object as? NSTextField
        MainActor.assumeIsolated {
            guard let field = editorField, ended === field else { return }
            commitEditorIfNeeded(refocus: false)
        }
    }

    // NSTextFieldDelegate: intercept commit/cancel/arrow keys.
    nonisolated func control(_ control: NSControl, textView: NSTextView,
                             doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            guard let document else { return false }
            let l = layout
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                commitEditorIfNeeded()
                navigate(.down)
                afterNavigation()
                return true
            case #selector(NSResponder.insertTab(_:)):
                commitEditorIfNeeded()
                navigate(.right)
                afterNavigation()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                commitEditorIfNeeded()
                navigate(.left)
                afterNavigation()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancelEditing()
                return true
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                if editMode == .enter {
                    let dir: SelectionState.Direction =
                        commandSelector == #selector(NSResponder.moveUp(_:)) ? .up : .down
                    commitEditorIfNeeded()
                    navigate(dir)
                    afterNavigation()
                    return true
                }
                return false
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
                if editMode == .enter {
                    let dir: SelectionState.Direction =
                        commandSelector == #selector(NSResponder.moveLeft(_:)) ? .left : .right
                    commitEditorIfNeeded()
                    navigate(dir)
                    afterNavigation()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}

/// The in-cell editor is the document's pending edit while it is open.
extension SpreadsheetGridView: PendingEditor {
    var hasPendingEdit: Bool { isEditing }

    func commitPendingEdit() {
        commitEditorIfNeeded()
    }
}

extension SpreadsheetGridView: NSMenuItemValidation {}

/// A menu item that runs a closure (keeps context-menu code free of @objc selectors).
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
