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
    private var editingAddress: CellAddress?

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

    var layout: GridLayout {
        GridLayout(sheet: document?.activeSheet ?? Sheet(id: 0, name: ""))
    }

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

    /// Convert a view point to grid content coordinates.
    private func contentPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x - contentOrigin.x, y: viewPoint.y - contentOrigin.y)
    }

    private func cellRect(_ address: CellAddress, layout l: GridLayout) -> CGRect {
        l.rect(of: address).offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        let l = layout
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds

        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let contentVisible = CGRect(
            x: max(0, visible.minX - contentOrigin.x),
            y: max(0, visible.minY - contentOrigin.y),
            width: visible.width,
            height: visible.height)
        let rows = l.visibleRows(in: contentVisible)
        let cols = l.visibleColumns(in: contentVisible)
        let selection = document.selection
        let selectionRange = selection.range

        // Pivot styling is drawn from cell roles, and only on sheets that
        // have pivots (role lookups are cached per revision, but skip them
        // entirely everywhere else).
        let bands = pivotBands(document)
        let role: (CellAddress) -> PivotCellRole? = { document.pivotRole(at: $0) }
        var pivotButtons: [CGRect] = []

        // --- Cell backgrounds ---
        for row in rows {
            for col in cols {
                let addr = CellAddress(row: row, column: col)
                let rect = cellRect(addr, layout: l)
                guard rect.intersects(dirtyRect) || rect.intersects(visible) else { continue }
                let cell = document.activeSheet.cell(at: addr)
                let style = document.workbook.style(at: cell.styleIndex)

                if let fill = style.fillColor {
                    nsColor(fill).setFill()
                    rect.fill()
                } else if !bands.isEmpty, bands.contains(where: { $0.isShaded(addr, role: role) }) {
                    SpreadsheetGridView.pivotBandFill.setFill()
                    rect.fill()
                }
                if style.pivotButton { pivotButtons.append(rect) }
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
        for row in rows {
            for col in textSourceColumns(row: row, visible: cols, layout: l) {
                let addr = CellAddress(row: row, column: col)
                let cell = document.activeSheet.cell(at: addr)
                guard !cell.value.isEmpty else { continue }
                var style = document.workbook.style(at: cell.styleIndex)
                if !bands.isEmpty, let r = role(addr), PivotBands.isBold(r) { style.bold = true }
                let span = drawCellText(cell: cell, style: style, at: addr, layout: l)
                if span.count > 1 {
                    for boundary in (span.lowerBound + 1)...span.upperBound {
                        hiddenBoundaries[row, default: []].insert(boundary)
                    }
                }
            }
        }

        // --- Grid lines ---
        SpreadsheetGridView.gridLineColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let lineTop = max(visible.minY, contentOrigin.y)
        let lineBottom = min(visible.maxY, contentOrigin.y + l.totalHeight)
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
        var y = contentOrigin.y + l.yOffset(ofRow: rows.lowerBound)
        for row in rows.lowerBound...(rows.upperBound + 1) {
            path.move(to: CGPoint(x: max(visible.minX, contentOrigin.x), y: y))
            path.line(to: CGPoint(x: min(visible.maxX, contentOrigin.x + l.totalWidth), y: y))
            if row <= rows.upperBound { y += l.rowHeight(row) }
        }
        path.stroke()

        if !bands.isEmpty {
            drawPivotRules(bands, role: role, layout: l, rows: rows)
        }
        for rect in pivotButtons { drawPivotButton(in: rect) }

        // --- Selection border + fill handle ---
        let selStart = cellRect(selectionRange.start, layout: l)
        let selEnd = cellRect(selectionRange.end, layout: l)
        let selRect = selStart.union(selEnd)
        SpreadsheetGridView.selectionBorder.setStroke()
        let selPath = NSBezierPath(rect: selRect.insetBy(dx: -0.5, dy: -0.5))
        selPath.lineWidth = 2
        selPath.stroke()
        // Active cell gets a white inner keyline when part of a bigger range.
        if !selection.isSingleCell {
            let activeRect = cellRect(selection.activeCell, layout: l)
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

        // --- Headers (pinned to the visible rect) ---
        drawHeaders(layout: l, visible: visible, rows: rows, cols: cols,
                    selectionRange: selectionRange)
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
    @discardableResult
    private func drawCellText(cell: Cell, style: CellStyle, at address: CellAddress,
                              layout l: GridLayout) -> ClosedRange<Int> {
        let own = address.column...address.column
        guard let document else { return own }
        let rect = cellRect(address, layout: l)
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
        if style.pivotButton {
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
        if !style.wrapText, !style.pivotButton, case .string = cell.value {
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
                isEmpty: { sheet.cell(at: CellAddress(row: address.row, column: $0)).value.isEmpty })
        }

        if span == own {
            if style.pivotButton {
                // Keep long field names from running under the button.
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: drawRect).setClip()
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
        NSBezierPath(rect: spanRect.insetBy(dx: 1, dy: 0)).setClip()
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return span
    }

    private func drawHeaders(layout l: GridLayout, visible: CGRect,
                             rows: ClosedRange<Int>, cols: ClosedRange<Int>,
                             selectionRange: CellRange) {
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

        // Column labels.
        for col in cols {
            let x = contentOrigin.x + l.xOffset(ofColumn: col)
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

        // Row labels.
        for row in rows {
            let y = contentOrigin.y + l.yOffset(ofRow: row)
            let rect = CGRect(x: visible.minX, y: y, width: GridLayout.headerWidth,
                              height: l.rowHeight(row))
            let isSelected = row >= selectionRange.start.row && row <= selectionRange.end.row
            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                rect.fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ]
            let label = NSAttributedString(string: String(row + 1), attributes: attrs)
            let size = label.size()
            label.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                   y: rect.midY - size.height / 2))
            SpreadsheetGridView.gridLineColor.setStroke()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            tick.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
            tick.stroke()
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

    func scrollActiveCellToVisible() {
        guard let document else { return }
        let rect = cellRect(document.selection.activeCell, layout: layout)
            .insetBy(dx: -20, dy: -20)
        scrollToVisible(rect)
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

        commitEditorIfNeeded()

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
        let selRect = cellRect(document.selection.range.start, layout: l)
            .union(cellRect(document.selection.range.end, layout: l))
        let handle = CGRect(x: selRect.maxX - 6, y: selRect.maxY - 6, width: 12, height: 12)
        if handle.contains(point) {
            dragMode = .fillHandle(source: document.selection.range)
            return
        }

        let content = contentPoint(point)
        let addr = CellAddress(row: l.row(atY: content.y), column: l.column(atX: content.x))
        if event.clickCount == 2 {
            beginEditing(mode: .edit, initialText: nil)
            return
        }
        if event.modifierFlags.contains(.shift) {
            document.selection.extend(to: addr)
        } else {
            document.selection.select(addr)
        }
        dragMode = .selectCells
        stateChanged()
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
            document.selection.extend(to: addr)
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

        commitEditorIfNeeded()
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
        // Column/row resize cursors over header boundaries.
        guard let scroll = enclosingScrollView else { return }
        let visible = scroll.documentVisibleRect
        let l = layout
        let cols = l.visibleColumns(in: CGRect(x: max(0, visible.minX - contentOrigin.x),
                                               y: 0, width: visible.width, height: 1))
        for col in cols {
            let x = contentOrigin.x + l.xOffset(ofColumn: col) + l.columnWidth(col)
            let rect = CGRect(x: x - 3, y: visible.minY, width: 6, height: GridLayout.headerHeight)
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
        let rows = l.visibleRows(in: CGRect(x: 0, y: max(0, visible.minY - contentOrigin.y),
                                            width: 1, height: visible.height))
        for row in rows {
            let y = contentOrigin.y + l.yOffset(ofRow: row) + l.rowHeight(row)
            let rect = CGRect(x: visible.minX, y: y - 3, width: GridLayout.headerWidth, height: 6)
            addCursorRect(rect, cursor: .resizeUpDown)
        }
    }

    private func columnBoundary(near x: CGFloat, layout l: GridLayout) -> Int? {
        var pos: CGFloat = 0
        for col in 0..<l.columnCount {
            pos += l.columnWidth(col)
            if abs(x - pos) <= 4 { return col }
            if pos > x + 4 { break }
        }
        return nil
    }

    private func rowBoundary(near y: CGFloat, layout l: GridLayout) -> Int? {
        var pos: CGFloat = 0
        for row in 0..<l.rowCount {
            pos += l.rowHeight(row)
            if abs(y - pos) <= 4 { return row }
            if pos > y + 4 { break }
        }
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
                document.selection.extendMove(dir, rowLimit: l.rowCount, columnLimit: l.columnCount)
            } else {
                document.selection.move(dir, rowLimit: l.rowCount, columnLimit: l.columnCount)
            }
            afterNavigation()
            return
        }

        switch event.keyCode {
        case 36: // Return
            if hasShift {
                document.selection.move(.up, rowLimit: l.rowCount, columnLimit: l.columnCount)
            } else {
                document.selection.move(.down, rowLimit: l.rowCount, columnLimit: l.columnCount)
            }
            afterNavigation()
        case 48: // Tab
            if hasShift {
                document.selection.move(.left, rowLimit: l.rowCount, columnLimit: l.columnCount)
            } else {
                document.selection.move(.right, rowLimit: l.rowCount, columnLimit: l.columnCount)
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
            if let chars = event.characters, !chars.isEmpty,
               let first = chars.unicodeScalars.first,
               !CharacterSet.controlCharacters.contains(first) {
                // Type-to-replace: begin Enter-mode editing with this character.
                beginEditing(mode: .enter, initialText: chars)
                return
            }
            super.keyDown(with: event)
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

    // MARK: Cell editor

    /// Begin in-place editing. `.enter` = typing replaced content (arrows
    /// commit); `.edit` = F2/double-click (arrows move the caret).
    func beginEditing(mode: EditMode, initialText: String?) {
        guard let document else { return }
        commitEditorIfNeeded()
        let addr = document.selection.activeCell
        editingAddress = addr
        editMode = mode

        let l = layout
        let rect = cellRect(addr, layout: l).insetBy(dx: -1, dy: -1)
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
        window?.makeFirstResponder(field)
        // Caret at end.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
        editorField = field
        scrollToVisible(rect.insetBy(dx: -10, dy: -10))
    }

    func commitEditorIfNeeded() {
        guard let field = editorField, let addr = editingAddress else { return }
        let text = field.stringValue
        tearDownEditor()
        document?.commitInput(text, at: addr)
        needsDisplay = true
        onStateChange?()
    }

    func cancelEditing() {
        tearDownEditor()
        needsDisplay = true
    }

    private func tearDownEditor() {
        editorField?.removeFromSuperview()
        editorField = nil
        editingAddress = nil
        editMode = .ready
        window?.makeFirstResponder(self)
    }

    var isEditing: Bool { editorField != nil }

    // NSTextFieldDelegate: intercept commit/cancel/arrow keys.
    nonisolated func control(_ control: NSControl, textView: NSTextView,
                             doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            guard let document else { return false }
            let l = layout
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                commitEditorIfNeeded()
                document.selection.move(.down, rowLimit: l.rowCount, columnLimit: l.columnCount)
                afterNavigation()
                return true
            case #selector(NSResponder.insertTab(_:)):
                commitEditorIfNeeded()
                document.selection.move(.right, rowLimit: l.rowCount, columnLimit: l.columnCount)
                afterNavigation()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                commitEditorIfNeeded()
                document.selection.move(.left, rowLimit: l.rowCount, columnLimit: l.columnCount)
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
                    document.selection.move(dir, rowLimit: l.rowCount, columnLimit: l.columnCount)
                    afterNavigation()
                    return true
                }
                return false
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
                if editMode == .enter {
                    let dir: SelectionState.Direction =
                        commandSelector == #selector(NSResponder.moveLeft(_:)) ? .left : .right
                    commitEditorIfNeeded()
                    document.selection.move(dir, rowLimit: l.rowCount, columnLimit: l.columnCount)
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
