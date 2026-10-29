import CoreGraphics
import Foundation
import SpreadsheetCore
import SpreadsheetFiles
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The grid's colours. Dynamic: they resolve to light or dark when drawn.
@MainActor
enum GridColors {
    static let header = SystemColors.windowBackground
    static let gridLine = SystemColors.separator.withAlphaComponent(0.5)
    static let selectionFill = SystemColors.accent.withAlphaComponent(0.12)
    static let selectionBorder = SystemColors.accent
    /// Pivot header/grand-total shading (Excel's PivotStyleLight16 blue in
    /// light mode; a translucent system blue reads better on dark).
    static let pivotBandFill = SystemColors.dynamic(
        light: PlatformColor(rgba: RGBAColor(red: 0xDD, green: 0xEB, blue: 0xF7)),
        dark: PlatformColor.systemBlue.withAlphaComponent(0.22))
    /// The rules under a pivot's header rows and above its grand totals.
    static let pivotRule = SystemColors.dynamic(
        light: PlatformColor(rgba: RGBAColor(red: 0x7F, green: 0xA7, blue: 0xD9)),
        dark: PlatformColor.systemBlue.withAlphaComponent(0.65))
}

/// What a pane draws besides the sheet: selection decorations that depend
/// on the platform and on what the user is doing.
struct GridDecorations {
    /// The dashed outline of a fill-handle drag in progress.
    var pendingFillTarget: CellRange?
    /// The Mac's small square fill handle at the selection's corner.
    var fillHandle = true
    /// iPad's round grab handles at the selection's corners.
    var selectionGrips = false
    /// The selected chart's id: drawn with an outline and handles.
    var selectedChart: String?
    /// A chart being moved or resized, and where it is for now (view coordinates).
    var movingChart: (id: String, frame: CGRect)?
}

/// Draws the grid: cells, grid lines, borders, pivot and filter
/// decorations, the selection, and the pinned headers. Pure Core Graphics
/// (plus attributed-string drawing, which both platforms share), so the
/// Mac and iPad grids draw identically. The context must also be the
/// current graphics context (text draws into it), with view coordinates
/// as described in GridGeometry.
@MainActor
struct GridRenderer {
    let document: SpreadsheetDocument
    let geometry: GridGeometry
    /// Pivot banding for the active sheet (see GridController).
    let pivotBands: [PivotBands]
    /// The active sheet's charts, drawn by `chartLayer` above the cells.
    var charts: [SheetChart] = []
    var chartLayer: SheetChartLayer?
    var decorations = GridDecorations()
    /// Fonts made while drawing, reused cell to cell (making one, with bold
    /// or italic applied, is the slowest part of drawing a cell).
    private let fonts = FontCache()

    private var layout: GridLayout { geometry.layout }
    private var contentOrigin: CGPoint { geometry.contentOrigin }

    func draw(in ctx: CGContext, dirtyRect: CGRect) {
        let l = layout
        let visible = geometry.visible

        ctx.fill(dirtyRect, SystemColors.textBackground)

        for pane in geometry.panes() where pane.clip.width > 0 && pane.clip.height > 0 {
            ctx.saveGState()
            ctx.clip(to: pane.clip)
            ctx.translateBy(x: pane.shift.x, y: pane.shift.y)
            drawPane(pane, in: ctx)
            ctx.restoreGState()
        }

        // The lines where frozen panes meet the scrolling body.
        if l.frozenRows > 0 || l.frozenColumns > 0 {
            let divider = CGMutablePath()
            if l.frozenRows > 0 {
                let y = (visible.minY + contentOrigin.y + l.frozenHeight).rounded() + 0.5
                divider.move(to: CGPoint(x: visible.minX, y: y))
                divider.addLine(to: CGPoint(x: visible.maxX, y: y))
            }
            if l.frozenColumns > 0 {
                let x = (visible.minX + contentOrigin.x + l.frozenWidth).rounded() + 0.5
                divider.move(to: CGPoint(x: x, y: visible.minY))
                divider.addLine(to: CGPoint(x: x, y: visible.maxY))
            }
            ctx.stroke(divider, SystemColors.tertiaryLabel)
        }

        drawHeaders(in: ctx, selectionRange: document.activeSheet.expandedForMerges(document.selection.range))
    }

    /// Draw one pane's cells, in unshifted coordinates (the caller has set
    /// the clip and the translation).
    private func drawPane(_ pane: GridGeometry.Pane, in ctx: CGContext) {
        let l = layout
        let visible = pane.visible
        let rows = pane.rows
        let cols = pane.cols
        // The rows that show: on a filtered sheet, `rows` can span a million
        // hidden rows between the few on screen.
        let shownRows = l.shownRows(in: rows)
        let sheet = document.activeSheet
        let selection = document.selection
        // Drawn over whole merged cells, even before a click has grown the
        // selection to cover them (e.g. A1 inside a merge on open).
        let selectionRange = sheet.expandedForMerges(selection.range)

        // Pivot styling is drawn from cell roles, and only on sheets that
        // have pivots (role lookups are cached per revision, but skip them
        // entirely everywhere else).
        let bands = pivotBands
        let document = self.document
        let role: (CellAddress) -> PivotCellRole? = { document.pivotRole(at: $0) }
        var pivotButtons: [CGRect] = []

        // Merged ranges showing in this pane, and the cells they cover.
        let paneRange = CellRange(start: CellAddress(row: rows.lowerBound, column: cols.lowerBound),
                                  end: CellAddress(row: rows.upperBound, column: cols.upperBound))
        let merges = sheet.mergedRanges.filter { $0.intersects(paneRange) }
        var mergeOf: [CellAddress: CellRange] = [:]
        for merge in merges {
            for row in shownRows where merge.start.row <= row && row <= merge.end.row {
                for col in max(merge.start.column, cols.lowerBound)...min(merge.end.column, cols.upperBound) {
                    mergeOf[CellAddress(row: row, column: col)] = merge
                }
            }
        }
        let mergeRect = geometry.rangeRect

        // AutoFilter header buttons.
        let filter = sheet.autoFilter
        func hasFilterButton(_ address: CellAddress) -> Bool {
            guard let filter else { return false }
            return address.row == filter.headerRow
                && (filter.range.start.column...filter.range.end.column).contains(address.column)
        }

        // --- Cell backgrounds ---
        for merge in merges {
            let style = document.workbook.style(at: sheet.styleIndex(at: merge.start))
            if let fill = style.fillColor {
                ctx.fill(mergeRect(merge), PlatformColor(rgba: fill))
            }
        }
        for row in shownRows {
            for col in cols {
                let addr = CellAddress(row: row, column: col)
                let rect = geometry.cellRect(addr)
                guard rect.intersects(visible) else { continue }
                if mergeOf[addr] == nil {
                    let style = document.workbook.style(at: sheet.styleIndex(at: addr))
                    if let fill = style.fillColor {
                        ctx.fill(rect, PlatformColor(rgba: fill))
                    } else if !bands.isEmpty, bands.contains(where: { $0.isShaded(addr, role: role) }) {
                        ctx.fill(rect, GridColors.pivotBandFill)
                    }
                    if style.pivotButton { pivotButtons.append(rect) }
                }
                if selectionRange.contains(addr) {
                    ctx.fill(rect, GridColors.selectionFill)
                }
            }
        }

        // --- Cell text ---
        // Drawn after every background so text that spills into an empty
        // neighbour (Excel-style overflow) is not painted over by that
        // neighbour's fill. A spilled run hides the grid lines inside it.
        var hiddenBoundaries: [Int: Set<Int>] = [:]
        for row in shownRows {
            for col in textSourceColumns(row: row, visible: cols) {
                let addr = CellAddress(row: row, column: col)
                if mergeOf[addr] != nil { continue }
                let cell = sheet.cell(at: addr)
                guard !cell.value.isEmpty else { continue }
                if !cols.contains(col), sheet.mergedRange(containing: addr) != nil { continue }
                var style = document.workbook.style(at: sheet.styleIndex(at: addr))
                if !bands.isEmpty, let r = role(addr), PivotBands.isBold(r) { style.bold = true }
                let span = drawCellText(cell: cell, style: style, at: addr, in: ctx,
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
            let style = document.workbook.style(at: sheet.styleIndex(at: merge.start))
            drawCellText(cell: cell, style: style, at: merge.start, in: ctx,
                         reserveButton: hasFilterButton(merge.start), rect: mergeRect(merge))
        }

        // --- Grid lines ---
        // Lines inside a merged range are left out, as are the vertical
        // lines that overflowing text runs across.
        var hiddenRules: [Int: Set<Int>] = [:]   // row boundary -> columns
        // Row boundaries drawn: the top of each shown row, and the bottom of
        // the last. A hidden row's boundary would sit on the next one's.
        let ruleRows = shownRows + [rows.upperBound + 1]
        for merge in merges {
            for row in shownRows where merge.start.row <= row && row <= merge.end.row {
                for boundary in (merge.start.column + 1)..<(merge.end.column + 1) {
                    hiddenBoundaries[row, default: []].insert(boundary)
                }
            }
            for boundary in ruleRows where merge.start.row < boundary && boundary <= merge.end.row {
                for col in merge.start.column...merge.end.column {
                    hiddenRules[boundary, default: []].insert(col)
                }
            }
        }
        let path = CGMutablePath()
        func line(_ a: CGPoint, _ b: CGPoint) {
            path.move(to: a)
            path.addLine(to: b)
        }
        let lineTop = max(visible.minY, contentOrigin.y)
        let lineBottom = min(visible.maxY, contentOrigin.y + l.totalHeight)
        let lineLeft = max(visible.minX, contentOrigin.x)
        let lineRight = min(visible.maxX, contentOrigin.x + l.totalWidth)
        // Row tops for the visible rows, so vertical lines can skip the rows
        // where overflowing text runs across a boundary.
        let rowTops = shownRows.map { contentOrigin.y + l.yOffset(ofRow: $0) }
        var x = contentOrigin.x + l.xOffset(ofColumn: cols.lowerBound)
        for col in cols.lowerBound...(cols.upperBound + 1) {
            if hiddenBoundaries.isEmpty {
                line(CGPoint(x: x, y: lineTop), CGPoint(x: x, y: lineBottom))
            } else {
                var segmentStart: CGFloat? = lineTop
                for (index, row) in shownRows.enumerated() where hiddenBoundaries[row]?.contains(col) == true {
                    let top = max(lineTop, rowTops[index])
                    if let start = segmentStart, top > start {
                        line(CGPoint(x: x, y: start), CGPoint(x: x, y: top))
                    }
                    segmentStart = rowTops[index] + l.rowHeight(row)
                }
                if let start = segmentStart, lineBottom > start {
                    line(CGPoint(x: x, y: start), CGPoint(x: x, y: lineBottom))
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
        for row in ruleRows {
            let y = contentOrigin.y + l.yOffset(ofRow: row)
            if let hidden = hiddenRules[row] {
                var segmentStart: CGFloat? = lineLeft
                for (index, col) in cols.enumerated() where hidden.contains(col) {
                    let left = max(lineLeft, colLefts[index])
                    if let start = segmentStart, left > start {
                        line(CGPoint(x: start, y: y), CGPoint(x: left, y: y))
                    }
                    segmentStart = colLefts[index] + l.columnWidth(col)
                }
                if let start = segmentStart, lineRight > start {
                    line(CGPoint(x: start, y: y), CGPoint(x: lineRight, y: y))
                }
            } else {
                line(CGPoint(x: lineLeft, y: y), CGPoint(x: lineRight, y: y))
            }
        }
        ctx.stroke(path, GridColors.gridLine)

        if !bands.isEmpty {
            drawPivotRules(bands, role: role, rows: rows, in: ctx)
        }
        for rect in pivotButtons { drawPivotButton(in: rect, ctx: ctx) }

        // --- Cell borders ---
        drawBorders(rows: rows, cols: cols, in: ctx)

        // --- AutoFilter buttons ---
        if let filter, rows.contains(filter.headerRow) {
            let lo = max(cols.lowerBound, filter.range.start.column)
            let hi = min(cols.upperBound, filter.range.end.column)
            if lo <= hi {
                for col in lo...hi {
                    let addr = CellAddress(row: filter.headerRow, column: col)
                    let rect = mergeOf[addr].map(mergeRect) ?? geometry.cellRect(addr)
                    let active = filter.columns[col - filter.range.start.column]?.isActive == true
                    drawFilterButton(in: rect, active: active, ctx: ctx)
                }
            }
        }

        drawSelection(selectionRange, in: ctx)
        chartLayer?.draw(charts, geometry: geometry, visible: visible, moving: decorations.movingChart,
                         selected: decorations.selectedChart, grips: decorations.selectionGrips, in: ctx)
    }

    // MARK: Selection

    private func drawSelection(_ selectionRange: CellRange, in ctx: CGContext) {
        let sheet = document.activeSheet
        let selection = document.selection
        let selRect = geometry.rangeRect(selectionRange)
        ctx.stroke(CGPath(rect: selRect.insetBy(dx: -0.5, dy: -0.5), transform: nil),
                   GridColors.selectionBorder, width: 2)
        // Active cell gets a white inner keyline when part of a bigger range.
        let activeMerge = sheet.mergedRange(containing: selection.activeCell)
        if !selection.isSingleCell, activeMerge != selectionRange {
            let activeRect = activeMerge.map(geometry.rangeRect) ?? geometry.cellRect(selection.activeCell)
            ctx.stroke(CGPath(rect: activeRect.insetBy(dx: 1, dy: 1), transform: nil),
                       SystemColors.textBackground, width: 2)
        }
        if decorations.fillHandle {
            // Fill handle (bottom-right square).
            let handleRect = CGRect(x: selRect.maxX - 4, y: selRect.maxY - 4, width: 7, height: 7)
            ctx.fill(handleRect, GridColors.selectionBorder)
            ctx.stroke(CGPath(rect: handleRect, transform: nil), SystemColors.textBackground)
        }
        if decorations.selectionGrips {
            // Round grips at the top-left and bottom-right corners: drag
            // them to grow or shrink the selection.
            for centre in [CGPoint(x: selRect.minX, y: selRect.minY), CGPoint(x: selRect.maxX, y: selRect.maxY)] {
                let grip = CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10)
                ctx.setFillColor(GridColors.selectionBorder.cgColor)
                ctx.fillEllipse(in: grip)
                ctx.setStrokeColor(SystemColors.textBackground.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: grip)
            }
        }

        // Fill-drag preview.
        if let target = decorations.pendingFillTarget {
            ctx.stroke(CGPath(rect: geometry.rangeRect(target), transform: nil),
                       SystemColors.accent.withAlphaComponent(0.7), width: 1.5, dash: [4, 3])
        }
    }

    // MARK: Borders

    /// Each cell draws its own edges; an edge inside a merged range is left
    /// out. One row and column beyond the pane are included so an edge set
    /// on a cell just out of view still shows.
    private func drawBorders(rows: ClosedRange<Int>, cols: ClosedRange<Int>, in ctx: CGContext) {
        let sheet = document.activeSheet
        let rowRange = max(0, rows.lowerBound - 1)...(rows.upperBound + 1)
        let colRange = max(0, cols.lowerBound - 1)...(cols.upperBound + 1)
        for row in layout.shownRows(in: rowRange) {
            for column in colRange {
                let addr = CellAddress(row: row, column: column)
                let styleIndex = sheet.styleIndex(at: addr)
                guard styleIndex != 0 else { continue }
                let borders = document.workbook.style(at: styleIndex).borders
                guard !borders.isEmpty else { continue }
                let rect = geometry.cellRect(addr)
                let merge = sheet.mergedRange(containing: addr)
                if let line = borders.top, merge.map({ $0.start.row == addr.row }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), ctx)
                }
                if let line = borders.bottom, merge.map({ $0.end.row == addr.row }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.maxY), ctx)
                }
                if let line = borders.left, merge.map({ $0.start.column == addr.column }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX, y: rect.maxY), ctx)
                }
                if let line = borders.right, merge.map({ $0.end.column == addr.column }) ?? true {
                    strokeBorder(line, from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY), ctx)
                }
            }
        }
    }

    /// Stroke one border edge in Excel's line styles. Automatic colour is
    /// the label colour, so borders stay visible in dark mode.
    private func strokeBorder(_ line: BorderLine, from a: CGPoint, to b: CGPoint, _ ctx: CGContext) {
        let color = line.color.map { PlatformColor(rgba: $0) } ?? SystemColors.label
        let horizontal = a.y == b.y
        func stroke(offset: CGFloat, width: CGFloat, dash: [CGFloat]) {
            let path = CGMutablePath()
            let dx: CGFloat = horizontal ? 0 : offset, dy: CGFloat = horizontal ? offset : 0
            // Extend half a width at each end so corners meet squarely.
            let ext = width / 2
            let ex: CGFloat = horizontal ? ext : 0, ey: CGFloat = horizontal ? 0 : ext
            path.move(to: CGPoint(x: a.x + dx - ex, y: a.y + dy - ey))
            path.addLine(to: CGPoint(x: b.x + dx + ex, y: b.y + dy + ey))
            ctx.stroke(path, color, width: width, dash: dash)
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

    // MARK: Pivot and filter decorations

    /// The thin rules under each pivot's header rows and above its grand
    /// total rows, across the table body.
    private func drawPivotRules(_ bands: [PivotBands], role: (CellAddress) -> PivotCellRole?,
                                rows: ClosedRange<Int>, in ctx: CGContext) {
        let l = layout
        let rules = CGMutablePath()
        for band in bands {
            let minX = contentOrigin.x + l.xOffset(ofColumn: band.location.start.column)
            let maxX = contentOrigin.x + l.xOffset(ofColumn: band.location.end.column + 1)
            func rule(atTopOf row: Int) {
                // Centred on the grid line (half-pixel) so it covers it.
                let y = contentOrigin.y + l.yOffset(ofRow: row) + 0.5
                rules.move(to: CGPoint(x: minX, y: y))
                rules.addLine(to: CGPoint(x: maxX, y: y))
            }
            if let header = band.headerRows, rows.contains(header.upperBound + 1) || rows.contains(header.upperBound) {
                rule(atTopOf: header.upperBound + 1)
            }
            let lo = max(rows.lowerBound, band.location.start.row)
            let hi = min(rows.upperBound, band.location.end.row)
            if lo <= hi {
                for row in l.shownRows(in: lo...hi) where band.isGrandTotalRow(row, role: role) {
                    // Consecutive grand-total rows share one rule on top.
                    if !band.isGrandTotalRow(row - 1, role: role) { rule(atTopOf: row) }
                }
            }
        }
        ctx.stroke(rules, GridColors.pivotRule)
    }

    /// Excel's pivot field (filter) button: a small rounded box with a
    /// down chevron, at the cell's right edge, vertically centred.
    private func drawPivotButton(in cell: CGRect, ctx: CGContext) {
        guard let box = GridGeometry.dropdownButtonRect(in: cell) else { return }
        let outline = CGPath(roundedRect: box, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.addPath(outline)
        ctx.setFillColor(SystemColors.controlBackground.cgColor)
        ctx.fillPath()
        ctx.stroke(outline, SystemColors.tertiaryLabel)
        let chevron = CGMutablePath()
        let w = box.width * 0.24, h = box.height * 0.13
        chevron.move(to: CGPoint(x: box.midX - w, y: box.midY - h))
        chevron.addLine(to: CGPoint(x: box.midX, y: box.midY + h + 0.5))
        chevron.addLine(to: CGPoint(x: box.midX + w, y: box.midY - h))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.stroke(chevron, SystemColors.secondaryLabel, width: 1.3)
        ctx.restoreGState()
    }

    /// An AutoFilter button: the pivot field button, or when the column is
    /// filtered, the box in the accent colour with a funnel in it.
    private func drawFilterButton(in cell: CGRect, active: Bool, ctx: CGContext) {
        guard active else {
            drawPivotButton(in: cell, ctx: ctx)
            return
        }
        guard let box = GridGeometry.dropdownButtonRect(in: cell) else { return }
        let outline = CGPath(roundedRect: box, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.addPath(outline)
        ctx.setFillColor(SystemColors.accent.withAlphaComponent(0.18).cgColor)
        ctx.fillPath()
        ctx.stroke(outline, SystemColors.accent)
        // A funnel: a triangle over a short stem.
        let funnel = CGMutablePath()
        let w = box.width * 0.32, top = box.midY - box.height * 0.22
        funnel.move(to: CGPoint(x: box.midX - w, y: top))
        funnel.addLine(to: CGPoint(x: box.midX + w, y: top))
        funnel.addLine(to: CGPoint(x: box.midX + 0.8, y: box.midY + 0.5))
        funnel.addLine(to: CGPoint(x: box.midX + 0.8, y: box.midY + box.height * 0.26))
        funnel.addLine(to: CGPoint(x: box.midX - 0.8, y: box.midY + box.height * 0.18))
        funnel.addLine(to: CGPoint(x: box.midX - 0.8, y: box.midY + 0.5))
        funnel.closeSubpath()
        ctx.addPath(funnel)
        ctx.setFillColor(SystemColors.accent.cgColor)
        ctx.fillPath()
    }

    // MARK: Cell text

    /// The columns whose text can show in `row`: every visible column, plus
    /// the nearest non-empty cell on each side, whose text may spill into view.
    private func textSourceColumns(row: Int, visible cols: ClosedRange<Int>) -> ClosedRange<Int> {
        let sheet = document.activeSheet
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
        while c < min(layout.columnCount, cols.upperBound + 1 + scanLimit) {
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
    private func drawCellText(cell: Cell, style: CellStyle, at address: CellAddress, in ctx: CGContext,
                              reserveButton: Bool = false, rect rectOverride: CGRect? = nil) -> ClosedRange<Int> {
        let l = layout
        let own = address.column...address.column
        let rect = rectOverride ?? geometry.cellRect(address)
        let hasButton = style.pivotButton || reserveButton
        let text = NumberFormatEngine.displayString(for: cell.value, format: style.numberFormat)
        guard !text.isEmpty else { return own }

        let fontSize = style.fontSize ?? CellStyle.defaultFontSize
        let font = fonts.font(name: style.fontName, size: fontSize, bold: style.bold, italic: style.italic)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.textColor(for: style),
        ]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        // A HYPERLINK formula looks like a link unless the cell sets its own colour.
        if cell.formula != nil, cell.value.errorValue == nil,
           document.engine.isHyperlink(at: AbsoluteAddress(sheetID: document.activeSheetID, address: address)) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if style.textColor == nil { attributes[.foregroundColor] = SystemColors.link }
        }
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
            inset.size.width = max(0, inset.width - GridGeometry.pivotButtonReserve + horizontalInset)
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

        // .usesLineFragmentOrigin is required for rect-based drawing;
        // without it the origin is interpreted as a text BASELINE.
        if span == own {
            if hasButton || rectOverride != nil {
                // Keep long field names from running under the button.
                ctx.saveGState()
                ctx.clip(to: drawRect)
                attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
                ctx.restoreGState()
                return own
            }
            attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
            return own
        }

        // Spilled text: lay it out at its full width, anchored the way its
        // alignment says, and clip it to the run of cells it may use.
        let first = geometry.cellRect(CellAddress(row: address.row, column: span.lowerBound))
        let last = geometry.cellRect(CellAddress(row: address.row, column: span.upperBound))
        let spanRect = first.union(last)
        let fullWidth = ceil(textSize.width) + 1
        switch alignment {
        case .right: drawRect.origin.x = inset.maxX - fullWidth
        case .center: drawRect.origin.x = rect.midX - fullWidth / 2
        default: break
        }
        drawRect.size.width = fullWidth
        ctx.saveGState()
        ctx.clip(to: spanRect.insetBy(dx: 1, dy: 0))
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin], context: nil)
        ctx.restoreGState()
        return span
    }

    /// A cell's text colour. Automatic text on a filled cell contrasts
    /// with the fill (dark on a light fill even in dark mode, where the
    /// automatic colour is white); otherwise it's the system text colour.
    static func textColor(for style: CellStyle) -> PlatformColor {
        if let color = style.textColor { return PlatformColor(rgba: color) }
        guard let fill = style.fillColor, fill.alpha > 0 else { return SystemColors.text }
        return fill.isLight ? .black : .white
    }

    // MARK: Headers

    /// The column and row headers, pinned to the visible rect.
    private func drawHeaders(in ctx: CGContext, selectionRange: CellRange) {
        let l = layout
        let visible = geometry.visible
        let headerFont = PlatformFont.systemFont(ofSize: 10.5, weight: .medium)

        // Column header strip.
        let colStrip = CGRect(x: visible.minX, y: visible.minY,
                              width: visible.width, height: GridLayout.headerHeight)
        ctx.fill(colStrip, GridColors.header)
        // Row header strip.
        let rowStrip = CGRect(x: visible.minX, y: visible.minY,
                              width: GridLayout.headerWidth, height: visible.height)
        ctx.fill(rowStrip, GridColors.header)

        // Column labels, per band: frozen columns stay put, the rest scroll.
        for band in geometry.columnBands() where band.max > band.min {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: band.min, y: visible.minY, width: band.max - band.min,
                                height: GridLayout.headerHeight))
            // A hidden column has no width and no label.
            for col in band.range where l.columnWidth(col) > 0 {
                let x = contentOrigin.x + l.xOffset(ofColumn: col) + band.shift
                let rect = CGRect(x: x, y: visible.minY, width: l.columnWidth(col),
                                  height: GridLayout.headerHeight)
                let isSelected = col >= selectionRange.start.column && col <= selectionRange.end.column
                if isSelected {
                    ctx.fill(rect, SystemColors.accent.withAlphaComponent(0.2))
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: isSelected ? SystemColors.accent : SystemColors.secondaryLabel,
                ]
                let label = NSAttributedString(string: CellAddress.columnName(col), attributes: attrs)
                let size = label.size()
                label.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                       y: rect.midY - size.height / 2))
                let tick = CGMutablePath()
                tick.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                tick.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                ctx.stroke(tick, GridColors.gridLine)
            }
            ctx.restoreGState()
        }

        // Row labels. Hidden rows have no label; rows under an active filter
        // are numbered in blue, as in Excel.
        let filter = l.sheet.autoFilter
        let filteredRows = filter?.isFiltering == true ? filter?.dataRows : nil
        for band in geometry.rowBands() where band.max > band.min {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: visible.minX, y: band.min, width: GridLayout.headerWidth,
                                height: band.max - band.min))
            for row in l.shownRows(in: band.range) {
                let y = contentOrigin.y + l.yOffset(ofRow: row) + band.shift
                let rect = CGRect(x: visible.minX, y: y, width: GridLayout.headerWidth,
                                  height: l.rowHeight(row))
                let isSelected = row >= selectionRange.start.row && row <= selectionRange.end.row
                if isSelected {
                    ctx.fill(rect, SystemColors.accent.withAlphaComponent(0.2))
                }
                let color: PlatformColor
                if isSelected {
                    color = SystemColors.accent
                } else if filteredRows?.contains(row) == true {
                    color = .systemBlue
                } else {
                    color = SystemColors.secondaryLabel
                }
                let attrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: color]
                let label = NSAttributedString(string: String(row + 1), attributes: attrs)
                let size = label.size()
                label.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                       y: rect.midY - size.height / 2))
                // A row after hidden rows gets a heavier rule above it, so the
                // gap in the numbering is easy to spot.
                if row > 0, l.sheet.hiddenRows.contains(row - 1) {
                    let mark = CGMutablePath()
                    mark.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    mark.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    ctx.stroke(mark, SystemColors.secondaryLabel, width: 2)
                }
                let tick = CGMutablePath()
                tick.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                tick.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                ctx.stroke(tick, GridColors.gridLine)
            }
            ctx.restoreGState()
        }

        // Header edges. When the sheet is scrolled, part of a column sits
        // right next to the row headers; without these lines that slice of
        // cells looked like part of the header (most visible when zoomed).
        let edges = CGMutablePath()
        edges.move(to: CGPoint(x: rowStrip.maxX, y: visible.minY))
        edges.addLine(to: CGPoint(x: rowStrip.maxX, y: visible.maxY))
        edges.move(to: CGPoint(x: visible.minX, y: colStrip.maxY))
        edges.addLine(to: CGPoint(x: visible.maxX, y: colStrip.maxY))
        ctx.stroke(edges, GridColors.gridLine)

        // Corner (select-all) box.
        let corner = CGRect(x: visible.minX, y: visible.minY,
                            width: GridLayout.headerWidth, height: GridLayout.headerHeight)
        ctx.fill(corner, GridColors.header)
        ctx.stroke(CGPath(rect: corner, transform: nil), GridColors.gridLine)
    }
}

/// The width a column needs for its widest cell (double-click a column
/// edge), capped at 500.
@MainActor
enum ColumnAutofit {
    static func width(of column: Int, in document: SpreadsheetDocument) -> CGFloat {
        var maxWidth: CGFloat = 30
        for (addr, cell) in document.activeSheet.cells where addr.column == column {
            let style = document.workbook.style(at: document.activeSheet.styleIndex(at: addr))
            let text = NumberFormatEngine.displayString(for: cell.value, format: style.numberFormat)
            let font = PlatformFont.cellFont(name: style.fontName,
                                             size: style.fontSize ?? CellStyle.defaultFontSize)
            let width = (text as NSString).size(withAttributes: [.font: font]).width + 12
            maxWidth = max(maxWidth, width)
        }
        return min(maxWidth, 500)
    }
}

private extension CGContext {
    func fill(_ rect: CGRect, _ color: PlatformColor) {
        setFillColor(color.cgColor)
        fill(rect)
    }

    func stroke(_ path: CGPath, _ color: PlatformColor, width: CGFloat = 1, dash: [CGFloat] = []) {
        saveGState()
        addPath(path)
        setStrokeColor(color.cgColor)
        setLineWidth(width)
        if !dash.isEmpty { setLineDash(phase: 0, lengths: dash) }
        strokePath()
        restoreGState()
    }
}

extension RGBAColor {
    /// Whether dark text reads better on this colour (relative luminance,
    /// as WCAG measures it, above the point where black and white contrast
    /// equally).
    var isLight: Bool {
        func linear(_ byte: UInt8) -> Double {
            let c = Double(byte) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > 0.179
    }
}

/// Cell fonts by face, size and style, for one renderer.
@MainActor
private final class FontCache {
    private struct Key: Hashable {
        var name: String?
        var size: CGFloat
        var bold: Bool
        var italic: Bool
    }

    private var fonts: [Key: PlatformFont] = [:]

    func font(name: String?, size: CGFloat, bold: Bool, italic: Bool) -> PlatformFont {
        let key = Key(name: name, size: size, bold: bold, italic: italic)
        if let font = fonts[key] { return font }
        let font = PlatformFont.cellFont(name: name, size: size, bold: bold, italic: italic)
        fonts[key] = font
        return font
    }
}
