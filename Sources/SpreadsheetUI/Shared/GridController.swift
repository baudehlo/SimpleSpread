import CoreGraphics
import Foundation
import SpreadsheetCore
import SpreadsheetFiles

/// What a platform grid view does for its GridController: say what is on
/// screen, redraw, scroll, and host the in-cell text editor.
@MainActor
protocol GridHost: AnyObject {
    /// The part of the grid on screen, in view coordinates (GridGeometry).
    var visibleGridRect: CGRect { get }
    func gridNeedsDisplay()
    /// The sheet's size changed (a column resized, rows hidden…).
    func gridSizeChanged()
    /// Scroll so `origin` (view coordinates) is the visible rect's origin.
    func scrollGrid(to origin: CGPoint)
    /// Open the in-cell editor over `frame` (view coordinates) holding
    /// `text`, focused, with the caret at the end.
    func showEditor(text: String, frame: CGRect)
    /// The open editor's text.
    var editorText: String { get }
    /// Close the editor. `refocusGrid`: give the grid keyboard focus back
    /// (not when the user has just moved focus to another control).
    func removeEditor(refocusGrid: Bool)
    /// The selection moved (VoiceOver announces the new cell).
    func selectionDidChange()
}

/// The grid's behaviour, shared by the Mac and iPad grid views: the
/// Ready/Enter/Edit editing state machine (Excel's modes), selection by
/// pointer and keyboard, header resizing, the fill handle, header menus,
/// and the Edit actions. The views translate their events into these calls
/// and do the drawing (GridRenderer) and the platform's text editor.
@MainActor
final class GridController {
    weak var document: SpreadsheetDocument?
    weak var host: GridHost?
    /// Called when the user changes selection (SwiftUI syncs the formula bar).
    var onStateChange: (() -> Void)?
    /// How close (points) to a header edge a press resizes, and how big the
    /// fill handle's target is: a pointer is precise, a finger is not.
    var hitSlop: CGFloat = 4

    // MARK: Editing state machine (Excel's Ready / Enter / Edit modes)

    enum EditMode {
        case ready
        /// Typing replaced content: arrows COMMIT and move.
        case enter
        /// Double-click/F2: arrows move the caret inside the text.
        case edit
    }

    private(set) var editMode: EditMode = .ready
    private(set) var isEditing = false
    /// The sheet and cell the editor was opened on. A commit writes there,
    /// even if the active sheet or selection has changed since.
    private var editingTarget: (sheetID: Int, address: CellAddress)?

    // MARK: Drag state

    enum DragMode: Equatable {
        case none
        case selectCells
        case selectRows(anchor: Int)
        case selectColumns(anchor: Int)
        case resizeColumn(index: Int, startWidth: CGFloat, startX: CGFloat)
        case resizeRow(index: Int, startHeight: CGFloat, startY: CGFloat)
        case fillHandle(source: CellRange)
        /// Dragging a selection grip (iPad): `anchor` is the fixed corner.
        case grip(anchor: CellAddress)
        /// Moving a chart: where the press began (view coordinates, as the
        /// pointer reports them) and where the chart was (unshifted).
        case moveChart(id: String, start: CGPoint, original: CGRect)
        /// Resizing a chart by one of its handles.
        case resizeChart(id: String, handle: ChartHandle, start: CGPoint, original: CGRect)
    }

    private(set) var dragMode: DragMode = .none
    private(set) var pendingFillTarget: CellRange?

    // MARK: Layout

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

    /// Where everything is, for what is on screen now.
    var geometry: GridGeometry {
        let l = layout
        return GridGeometry(layout: l, visible: host?.visibleGridRect
                            ?? CGRect(origin: .zero, size: GridGeometry.gridSize(l)))
    }

    /// Pivot banding for the active sheet, rebuilt when the document changes.
    var pivotBands: [PivotBands] {
        guard let document else { return [] }
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
    private var pivotBandsCache: (revision: Int, sheetID: Int, bands: [PivotBands])?

    /// Draws the active sheet's charts and keeps their images.
    lazy var chartLayer: SheetChartLayer = {
        let layer = SheetChartLayer()
        layer.onImageReady = { [weak self] in self?.host?.gridNeedsDisplay() }
        return layer
    }()
    /// A chart being moved or resized, and its frame for now (unshifted
    /// view coordinates).
    private(set) var movingChart: (id: String, frame: CGRect)?

    /// A renderer for the grid as it is now.
    func renderer(decorations: GridDecorations = GridDecorations()) -> GridRenderer? {
        guard let document else { return nil }
        var decorations = decorations
        decorations.pendingFillTarget = pendingFillTarget
        decorations.selectedChart = document.selectedChart?.id
        decorations.movingChart = movingChart
        return GridRenderer(document: document, geometry: geometry, pivotBands: pivotBands,
                            charts: document.activeCharts, chartLayer: chartLayer, decorations: decorations)
    }

    // MARK: Pointer

    /// What a press asks the view to do beyond what the controller did.
    enum PressResult: Equatable {
        case none
        /// Open the AutoFilter popover for a column, from its header cell.
        case showFilter(columnOffset: Int, cell: CGRect)
    }

    /// A press (mouse down, or a tap or drag start) at a view point.
    @discardableResult
    func press(at point: CGPoint, extend: Bool = false, clickCount: Int = 1) -> PressResult {
        guard let document else { return .none }
        let geometry = self.geometry
        let l = geometry.layout

        document.commitPendingEdit() // the in-cell editor or the formula bar

        let region = geometry.region(at: point)
        if region != .cells, document.selectedChartID != nil { document.selectChart(nil) }
        switch region {
        case .corner:
            selectAll()
            return .none

        case .columnHeader:
            let content = geometry.contentPoint(point)
            let col = l.column(atX: content.x)
            if let resizeCol = geometry.columnBoundary(near: content.x, slop: hitSlop) {
                dragMode = .resizeColumn(index: resizeCol, startWidth: l.columnWidth(resizeCol),
                                         startX: point.x)
                if clickCount == 2 {
                    autofitColumn(resizeCol)
                    dragMode = .none
                }
                return .none
            }
            if extend {
                let anchorCol = document.selection.anchor.column
                document.selection.select(range: CellRange(
                    start: CellAddress(row: 0, column: min(anchorCol, col)),
                    end: CellAddress(row: l.rowCount - 1, column: max(anchorCol, col))),
                    active: CellAddress(row: 0, column: anchorCol))
            } else {
                document.selection.select(range: columnRange(col, layout: l), active: CellAddress(row: 0, column: col))
            }
            dragMode = .selectColumns(anchor: col)
            stateChanged()
            return .none

        case .rowHeader:
            let content = geometry.contentPoint(point)
            let row = l.row(atY: content.y)
            if let resizeRow = geometry.rowBoundary(near: content.y, slop: hitSlop) {
                dragMode = .resizeRow(index: resizeRow, startHeight: l.rowHeight(resizeRow),
                                      startY: point.y)
                return .none
            }
            if extend {
                let anchorRow = document.selection.anchor.row
                document.selection.select(range: CellRange(
                    start: CellAddress(row: min(anchorRow, row), column: 0),
                    end: CellAddress(row: max(anchorRow, row), column: l.columnCount - 1)),
                    active: CellAddress(row: anchorRow, column: 0))
            } else {
                document.selection.select(range: rowRange(row, layout: l), active: CellAddress(row: row, column: 0))
            }
            dragMode = .selectRows(anchor: row)
            stateChanged()
            return .none

        case .cells:
            // Charts sit above the cells: the selected one's handles, then any chart.
            if let hit = chartHandleHit(at: point) {
                dragMode = .resizeChart(id: hit.chart.id, handle: hit.handle, start: point, original: hit.frame)
                return .none
            }
            if let hit = chart(at: point) {
                document.selectChart(hit.chart.id)
                if clickCount == 2 { document.isChartPanelVisible = true }
                // A chart in a group moves only with the group.
                if !hit.chart.isGrouped {
                    dragMode = .moveChart(id: hit.chart.id, start: point, original: hit.frame)
                }
                stateChanged()
                return .none
            }
            if document.selectedChartID != nil { document.selectChart(nil) }
            if fillHandleHit(at: point, geometry: geometry) {
                dragMode = .fillHandle(source: document.selection.range)
                return .none
            }
            if let button = geometry.filterButton(at: point, slop: hitSlop - 1) {
                return .showFilter(columnOffset: button.columnOffset, cell: button.cell)
            }
            let addr = geometry.address(at: point)
            if clickCount == 2 {
                beginEditing(mode: .edit, initialText: nil)
                return .none
            }
            if extend {
                document.selection.extend(to: addr)
                normalizeSelectionForMerges()
            } else if let merge = l.sheet.mergedRange(containing: addr) {
                document.selection.select(range: merge, active: merge.start)
            } else {
                document.selection.select(addr)
            }
            dragMode = .selectCells
            stateChanged()
            return .none
        }
    }

    /// Whether a view point is on the fill handle (the selection's
    /// bottom-right corner).
    func fillHandleHit(at point: CGPoint, geometry: GridGeometry? = nil) -> Bool {
        guard let document else { return false }
        let geometry = geometry ?? self.geometry
        let selRect = geometry.viewRect(document.selection.range)
        let reach = hitSlop + 2
        let handle = CGRect(x: selRect.maxX - reach, y: selRect.maxY - reach, width: 2 * reach, height: 2 * reach)
        return handle.contains(point)
    }

    /// Which selection grip (iPad), if any, is under a view point: the
    /// corner it moves. Dragging it keeps the opposite corner fixed.
    func gripHit(at point: CGPoint) -> CellAddress? {
        guard let document else { return nil }
        let geometry = self.geometry
        let range = document.activeSheet.expandedForMerges(document.selection.range)
        let rect = geometry.viewRect(range)
        let reach = max(hitSlop, 14)
        func near(_ corner: CGPoint) -> Bool { hypot(point.x - corner.x, point.y - corner.y) <= reach }
        if near(CGPoint(x: rect.maxX, y: rect.maxY)) { return range.start }
        if near(CGPoint(x: rect.minX, y: rect.minY)) { return range.end }
        return nil
    }

    /// Start dragging a selection grip; `anchor` stays put.
    func beginGripDrag(anchor: CellAddress) {
        document?.commitPendingEdit()
        dragMode = .grip(anchor: anchor)
    }

    /// The pointer (or finger) moved to a view point during a press.
    func drag(to point: CGPoint) {
        guard let document else { return }
        let geometry = self.geometry
        let l = geometry.layout
        let content = geometry.contentPoint(point)

        switch dragMode {
        case .selectCells:
            let addr = geometry.address(at: point)
            let anchor = document.selection.anchor
            document.selection.extend(to: addr)
            // Keep the anchor's merge whole when the drag started on one.
            if let merge = l.sheet.mergedRange(containing: anchor), merge.contains(addr) {
                document.selection.select(range: merge, active: merge.start)
            } else {
                normalizeSelectionForMerges()
            }
            stateChanged()
        case .grip(let anchor):
            let addr = geometry.address(at: point)
            document.selection.select(range: CellRange(start: anchor, end: addr), active: anchor)
            normalizeSelectionForMerges()
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
            host?.gridSizeChanged()
        case .resizeRow(let index, let startHeight, let startY):
            let newHeight = max(14, startHeight + (point.y - startY))
            document.setRowHeight(index, height: newHeight)
            host?.gridSizeChanged()
        case .moveChart(let id, let start, let original):
            // By how far the pointer moved, not where it is: over a frozen
            // pane, a point maps to other cells.
            var frame = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            // Not past the top-left corner of the sheet.
            frame.origin.x = max(frame.origin.x, geometry.contentOrigin.x)
            frame.origin.y = max(frame.origin.y, geometry.contentOrigin.y)
            movingChart = (id, frame)
            host?.gridNeedsDisplay()
        case .resizeChart(let id, let handle, let start, let original):
            var frame = handle.resize(original, by: CGSize(width: point.x - start.x, height: point.y - start.y))
            frame = frame.intersection(CGRect(x: geometry.contentOrigin.x, y: geometry.contentOrigin.y,
                                              width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            movingChart = (id, frame)
            host?.gridNeedsDisplay()
        case .fillHandle(let source):
            // Constrain fill to one axis (the dominant drag direction).
            let addr = geometry.address(at: point)
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
            host?.gridNeedsDisplay()
        case .none:
            break
        }
    }

    /// The press ended.
    func release() {
        if case .fillHandle(let source) = dragMode, let target = pendingFillTarget,
           target != source {
            document?.fill(from: source, to: target)
            stateChanged()
        }
        if let moving = movingChart {
            let original: CGRect?
            switch dragMode {
            case .moveChart(_, _, let frame), .resizeChart(_, _, _, let frame): original = frame
            default: original = nil
            }
            movingChart = nil
            if let original, moving.frame.integral != original.integral {
                let origin = geometry.contentOrigin
                document?.placeChart(moving.id, frame: moving.frame.offsetBy(dx: -origin.x, dy: -origin.y))
                stateChanged()
            }
        }
        switch dragMode {
        case .selectCells, .selectRows, .selectColumns, .grip:
            if document?.formatPainterStyles != nil {
                document?.applyFormatPainter()
                stateChanged()
            }
        default:
            break
        }
        pendingFillTarget = nil
        dragMode = .none
        host?.gridNeedsDisplay()
    }

    /// Whether the press under way is selecting cells (the view scrolls as
    /// the pointer reaches its edge).
    var isSelectingByDrag: Bool {
        switch dragMode {
        case .selectCells, .grip, .fillHandle: return true
        default: return false
        }
    }

    private func columnRange(_ col: Int, layout l: GridLayout) -> CellRange {
        CellRange(start: CellAddress(row: 0, column: col), end: CellAddress(row: l.rowCount - 1, column: col))
    }

    private func rowRange(_ row: Int, layout l: GridLayout) -> CellRange {
        CellRange(start: CellAddress(row: row, column: 0), end: CellAddress(row: row, column: l.columnCount - 1))
    }

    /// Grow the selection so it never cuts through a merged range, keeping
    /// the anchor and focus on their sides of it.
    func normalizeSelectionForMerges() {
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

    func autofitColumn(_ column: Int) {
        guard let document else { return }
        document.setColumnWidth(column, width: ColumnAutofit.width(of: column, in: document))
        host?.gridSizeChanged()
    }

    // MARK: Header menus

    /// One item in a context menu.
    struct MenuItem {
        let title: String
        var destructive = false
        let action: () -> Void
    }

    /// The URL of the HYPERLINK formula in the cell at a view point (the
    /// top-left cell of a merge), or nil.
    func hyperlink(at point: CGPoint) -> URL? {
        guard document != nil else { return nil }
        let geometry = self.geometry
        guard geometry.region(at: point) == .cells, chart(at: point) == nil else { return nil }
        return hyperlink(in: geometry.address(at: point))
    }

    /// The URL of the HYPERLINK formula in a cell of the active sheet, or nil.
    func hyperlink(in address: CellAddress) -> URL? {
        guard let document else { return nil }
        let cell = document.activeSheet.mergedRange(containing: address)?.start ?? address
        return document.engine.hyperlinkURL(at: AbsoluteAddress(sheetID: document.activeSheetID, address: cell))
    }

    /// "Open Link" and "Copy Link" for a link cell's context menu.
    func linkMenuItems(for url: URL) -> [MenuItem] {
        [MenuItem(title: "Open Link") { LinkOpener.open(url) },
         MenuItem(title: "Copy Link") { SystemPasteboard.write(text: url.absoluteString) }]
    }

    /// The menu for a right-click (or long press) on a row or column
    /// header: insert, delete, hide or unhide, in sections. Like Excel,
    /// pressing outside the current selection selects that row/column
    /// first; inside it, the menu acts on the whole selection.
    func headerMenu(at point: CGPoint) -> [[MenuItem]]? {
        guard let document else { return nil }
        let geometry = self.geometry
        let l = geometry.layout
        let region = geometry.region(at: point)
        guard region == .rowHeader || region == .columnHeader else { return nil }

        document.commitPendingEdit()
        let content = geometry.contentPoint(point)

        if region == .rowHeader {
            let row = l.row(atY: content.y)
            var range = document.selection.range
            if !(range.start.row...range.end.row).contains(row) {
                range = rowRange(row, layout: l)
                document.selection.select(range: range, active: CellAddress(row: row, column: 0))
                stateChanged()
            }
            let start = range.start.row, end = range.end.row, count = range.rowCount
            let noun = count == 1 ? "Row" : "\(count) Rows"
            var hide = [act("Hide \(noun)") { $0.hideRows(start...end) }]
            // Unhide covers the rows around a gap: select rows 3–6 to show 4–5.
            if document.activeSheet.hiddenRows.contains(where: (start...end).contains) {
                hide.append(act("Unhide Rows") { $0.unhideRows(start...end) })
            }
            return [
                [act("Insert \(noun) Above") { $0.insertRows(at: start, count: count) },
                 act("Insert \(noun) Below") { $0.insertRows(at: end + 1, count: count) }],
                [act("Delete \(noun)", destructive: true) { $0.deleteRows(at: start, count: count) }],
                hide,
            ]
        }

        let col = l.column(atX: content.x)
        var range = document.selection.range
        if !(range.start.column...range.end.column).contains(col) {
            range = columnRange(col, layout: l)
            document.selection.select(range: range, active: CellAddress(row: 0, column: col))
            stateChanged()
        }
        let start = range.start.column, end = range.end.column, count = range.columnCount
        let noun = count == 1 ? "Column" : "\(count) Columns"
        var hide = [act("Hide \(noun)", resizes: true) { $0.hideColumns(start...end) }]
        // Unhide covers the columns around a gap: select B–E to show C–D.
        if document.activeSheet.hiddenColumns.contains(where: (start...end).contains) {
            hide.append(act("Unhide Columns", resizes: true) { $0.unhideColumns(start...end) })
        }
        return [
            [act("Insert \(noun) Left") { $0.insertColumns(at: start, count: count) },
             act("Insert \(noun) Right") { $0.insertColumns(at: end + 1, count: count) }],
            [act("Delete \(noun)", destructive: true) { $0.deleteColumns(at: start, count: count) }],
            hide,
        ]
    }

    /// The menu for a right-click (or long press) on a chart, which it selects.
    func chartMenu(at point: CGPoint) -> [[MenuItem]]? {
        guard let document, let hit = chart(at: point) else { return nil }
        document.commitPendingEdit()
        document.selectChart(hit.chart.id)
        stateChanged()
        let id = hit.chart.id
        return [
            [MenuItem(title: "Edit Chart…") { [weak self] in
                self?.document?.isChartPanelVisible = true
            }],
            [MenuItem(title: "Copy Chart") { [weak self] in self?.copy() },
             MenuItem(title: "Delete Chart", destructive: true) { [weak self] in
                 self?.document?.deleteChart(id)
                 self?.stateChanged()
             }],
        ]
    }

    /// A menu item that runs a document command and updates the grid.
    private func act(_ title: String, destructive: Bool = false, resizes: Bool = false,
                     _ command: @escaping (SpreadsheetDocument) -> Void) -> MenuItem {
        MenuItem(title: title, destructive: destructive) { [weak self] in
            guard let self, let document = self.document else { return }
            command(document)
            if resizes { self.host?.gridSizeChanged() }
            self.stateChanged()
        }
    }

    // MARK: Charts

    /// A view point in unshifted view coordinates (where charts are
    /// measured): over a frozen pane, the frozen rows or columns there.
    func unshifted(_ point: CGPoint) -> CGPoint {
        let geometry = self.geometry
        let content = geometry.contentPoint(point)
        return CGPoint(x: content.x + geometry.contentOrigin.x, y: content.y + geometry.contentOrigin.y)
    }

    /// The topmost chart under a view point, and its frame (unshifted).
    func chart(at point: CGPoint) -> (chart: SheetChart, frame: CGRect)? {
        guard let document, geometry.region(at: point) == .cells else { return nil }
        let p = unshifted(point)
        let geometry = self.geometry
        for chart in document.activeCharts.reversed() {
            let frame = SheetChartLayer.frame(of: chart, in: geometry)
            if frame.contains(p) { return (chart, frame) }
        }
        return nil
    }

    /// The selected chart's handle under a view point.
    func chartHandleHit(at point: CGPoint) -> (chart: SheetChart, handle: ChartHandle, frame: CGRect)? {
        guard let document, let chart = document.selectedChart, !chart.isGrouped else { return nil }
        let frame = SheetChartLayer.frame(of: chart, in: geometry)
        let p = unshifted(point)
        let reach = max(hitSlop + 2, 6)
        for (handle, center) in SheetChartLayer.handles(of: frame)
        where abs(center.x - p.x) <= reach && abs(center.y - p.y) <= reach {
            return (chart, handle, frame)
        }
        return nil
    }

    /// Whether a press here would move or resize the selected chart (the
    /// iPad lets a drag there do that rather than scroll).
    func selectedChartHit(at point: CGPoint) -> Bool {
        guard let selected = document?.selectedChart, !selected.isGrouped else { return false }
        return chartHandleHit(at: point) != nil || chart(at: point)?.chart.id == selected.id
    }

    private func nudgeChart(_ chart: SheetChart, _ direction: SelectionState.Direction, by step: CGFloat) {
        guard let document, !chart.isGrouped else { return }
        var frame = SpreadsheetDocument.contentFrame(of: chart, in: layout)
        switch direction {
        case .up: frame.origin.y = max(0, frame.origin.y - step)
        case .down: frame.origin.y += step
        case .left: frame.origin.x = max(0, frame.origin.x - step)
        case .right: frame.origin.x += step
        }
        document.placeChart(chart.id, frame: frame, nudge: true)
        stateChanged()
    }

    /// Tab among charts (see SpreadsheetDocument.selectNextChart).
    func selectNextChart(backward: Bool = false) {
        document?.selectNextChart(backward: backward)
        scrollActiveCellToVisible()
        stateChanged()
    }

    // MARK: Keyboard (Ready mode)

    /// A key the grid handles itself (the rest start typing or go to menus).
    enum Key {
        case arrow(SelectionState.Direction)
        case returnKey
        case tab
        case delete
        case f2
        case home
        case pageUp
        case pageDown
        case escape
    }

    /// Handle a key pressed while the grid has focus (no editor open).
    /// `toEdge`: ⌘ with an arrow jumps to the edge of the data.
    func handle(_ key: Key, shift: Bool = false, toEdge: Bool = false) {
        guard let document else { return }
        if let chart = document.selectedChart {
            switch key {
            case .delete:
                document.deleteChart(chart.id)
                stateChanged()
                return
            case .escape:
                document.selectChart(nil)
                stateChanged()
                return
            case .arrow(let direction):
                nudgeChart(chart, direction, by: shift ? 10 : 1)
                return
            case .tab:
                selectNextChart(backward: shift)
                return
            default:
                // Other keys go back to the cells.
                document.selectChart(nil)
                stateChanged()
            }
        }
        let l = layout
        switch key {
        case .arrow(let dir):
            if toEdge {
                let edge = SelectionState.dataEdge(
                    from: shift ? document.selection.focus : document.selection.activeCell,
                    direction: dir, sheet: document.activeSheet,
                    rowLimit: l.rowCount, columnLimit: l.columnCount)
                if shift {
                    document.selection.extend(to: edge)
                } else {
                    document.selection.select(edge)
                }
            } else {
                navigate(dir, extend: shift)
            }
            afterNavigation()
        case .returnKey:
            navigate(shift ? .up : .down)
            afterNavigation()
        case .tab:
            navigate(shift ? .left : .right)
            afterNavigation()
        case .delete:
            document.clearSelectionContents()
            host?.gridNeedsDisplay()
        case .f2:
            beginEditing(mode: .edit, initialText: nil)
        case .home:
            document.selection.select(CellAddress(row: document.selection.activeCell.row, column: 0))
            afterNavigation()
        case .pageUp:
            page(by: -1)
        case .pageDown:
            page(by: 1)
        case .escape:
            if document.formatPainterStyles != nil {
                document.cancelFormatPainter()
            }
        }
    }

    /// Arrow/Return/Tab movement. Steps out of a merged range from its far
    /// edge, lands on a merged range as a whole, and skips hidden rows.
    func navigate(_ direction: SelectionState.Direction, extend: Bool = false) {
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
        guard let document, let host else { return }
        let visibleRows = Int((host.visibleGridRect.height - GridLayout.headerHeight)
            / max(1, document.activeSheet.defaultRowHeight))
        let delta = max(1, visibleRows - 2) * direction
        let l = layout
        let newRow = min(max(0, document.selection.activeCell.row + delta), l.rowCount - 1)
        document.selection.select(CellAddress(row: newRow, column: document.selection.activeCell.column))
        afterNavigation()
    }

    func afterNavigation() {
        host?.gridNeedsDisplay()
        scrollActiveCellToVisible()
        stateChanged()
    }

    func stateChanged() {
        host?.gridNeedsDisplay()
        host?.selectionDidChange()
        onStateChange?()
    }

    /// Scroll so the active cell (or its merged range) shows clear of the
    /// headers and any frozen pane. Frozen cells are always in view.
    func scrollActiveCellToVisible() {
        guard let document, let host else { return }
        let l = layout
        let geometry = GridGeometry(layout: l, visible: host.visibleGridRect)
        // A selected chart (one just inserted): its top-left corner, with
        // as much of it as fits.
        if let chart = document.selectedChart {
            let frame = SheetChartLayer.frame(of: chart, in: geometry)
            let visible = geometry.visible
            let body = CGRect(x: visible.minX + geometry.contentOrigin.x + l.frozenWidth,
                              y: visible.minY + geometry.contentOrigin.y + l.frozenHeight,
                              width: visible.width - geometry.contentOrigin.x - l.frozenWidth,
                              height: visible.height - geometry.contentOrigin.y - l.frozenHeight)
            guard !body.contains(frame) else { return }
            var origin = visible.origin
            if frame.minX < body.minX || frame.maxX > body.maxX {
                origin.x = max(0, min(frame.minX - 20, frame.maxX + 20 - body.width) - geometry.contentOrigin.x - l.frozenWidth)
            }
            if frame.minY < body.minY || frame.maxY > body.maxY {
                origin.y = max(0, min(frame.minY - 20, frame.maxY + 20 - body.height) - geometry.contentOrigin.y - l.frozenHeight)
            }
            host.scrollGrid(to: origin)
            host.gridNeedsDisplay()
            return
        }
        if let origin = geometry.scrollOrigin(toShow: document.selection.activeCell,
                                              gridSize: GridGeometry.gridSize(l)) {
            host.scrollGrid(to: origin)
            host.gridNeedsDisplay()
        }
    }

    // MARK: Accessibility

    /// What VoiceOver says about the grid: the selection and what the
    /// active cell shows ("B3, 84", or "A1:C4, active cell A1, Item").
    var accessibilitySummary: String? {
        guard let document else { return nil }
        if let chart = document.selectedChart {
            return "Selected " + Self.accessibilityDescription(of: chart, in: document)
        }
        let range = document.selection.range
        let active = document.selection.activeCell
        let shown = document.displayString(at: active)
        let place = range.isSingleCell ? active.a1 : "\(range.a1), active cell \(active.a1)"
        return shown.isEmpty ? place : "\(place), \(shown)"
    }

    /// The charts on screen, for VoiceOver: what each is, and where (view
    /// coordinates). A chart is pixels in the grid, so this is how it's found.
    var visibleChartsForAccessibility: [(id: String, label: String, frame: CGRect)] {
        guard let document else { return [] }
        let geometry = self.geometry
        return document.activeCharts.compactMap { chart in
            let frame = SheetChartLayer.frame(of: chart, in: geometry)
            guard frame.intersects(geometry.visible) else { return nil }
            return (chart.id, Self.accessibilityDescription(of: chart, in: document), frame)
        }
    }

    /// "Chart: Sales by region, column chart, 3 series, data Sales!A1:D7."
    static func accessibilityDescription(of chart: SheetChart, in document: SpreadsheetDocument) -> String {
        var parts = ["Chart" + (chart.title.map { ": \($0)" } ?? "")]
        if let unsupported = chart.unsupported {
            parts.append(unsupported.lowercased())
        } else if let kind = chart.kind {
            parts.append("\(kind.rawValue) chart")
            parts.append(chart.series.count == 1 ? "1 series" : "\(chart.series.count) series")
        }
        if let range = chart.settings?.dataRange(in: document.workbook) {
            parts.append("data " + range.formula.replacingOccurrences(of: "$", with: ""))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Edit actions

    func selectAll() {
        guard let document else { return }
        document.commitPendingEdit()
        let used = document.activeSheet.usedRange ?? CellRange(CellAddress(row: 0, column: 0))
        document.selection.select(range: CellRange(start: CellAddress(row: 0, column: 0),
                                                   end: used.end))
        stateChanged()
    }

    func copy() {
        guard let document else { return }
        if let chart = document.selectedChart {
            document.copyChartToPasteboard(chart)
        } else {
            document.copySelectionToPasteboard()
        }
    }

    func cut() {
        guard let document else { return }
        if let chart = document.selectedChart {
            document.copyChartToPasteboard(chart)
            document.deleteChart(chart.id)
        } else {
            document.copySelectionToPasteboard(cut: true)
        }
        stateChanged()
    }

    func paste() {
        document?.pasteFromPasteboard()
        afterNavigation()
    }

    func pasteAsPlainText() {
        document?.pastePlainTextFromPasteboard()
        afterNavigation()
    }

    func delete() {
        guard let document else { return }
        if let chart = document.selectedChart {
            document.deleteChart(chart.id)
        } else {
            document.clearSelectionContents()
        }
        stateChanged()
    }

    func undo() {
        guard let document else { return }
        document.commitPendingEdit()
        document.undoManager.undo()
        stateChanged()
    }

    func redo() {
        guard let document else { return }
        document.commitPendingEdit()
        document.undoManager.redo()
        stateChanged()
    }

    // MARK: Cell editor

    /// Begin in-place editing. `.enter` = typing replaced content (arrows
    /// commit); `.edit` = F2/double-click (arrows move the caret).
    func beginEditing(mode: EditMode, initialText: String?) {
        guard let document else { return }
        if document.selectedChartID != nil {
            document.selectChart(nil)
            host?.gridNeedsDisplay()
        }
        commitEditorIfNeeded()
        document.commitPendingEdit() // e.g. typing left in the formula bar
        let addr = document.selection.activeCell
        editingTarget = (document.activeSheetID, addr)
        editMode = mode

        // Scroll first: a frozen cell's position depends on the scroll offset.
        scrollActiveCellToVisible()
        let rect = geometry.viewRectIncludingMerge(addr).insetBy(dx: -1, dy: -1)
        isEditing = true
        document.pendingEditor = self
        host?.showEditor(text: initialText ?? document.editString(at: addr), frame: rect)
    }

    /// Write the editor's text to the cell it was opened on and close it.
    /// `refocus`: give the grid keyboard focus back (not when the user has
    /// just clicked into another control).
    func commitEditorIfNeeded(refocus: Bool = true) {
        guard isEditing, let target = editingTarget else { return }
        let text = host?.editorText ?? ""
        tearDownEditor(refocus: refocus)
        document?.commitInput(text, at: target.address, sheetID: target.sheetID)
        host?.gridNeedsDisplay()
        onStateChange?()
    }

    func cancelEditing() {
        tearDownEditor(refocus: true)
        host?.gridNeedsDisplay()
    }

    private func tearDownEditor(refocus: Bool) {
        guard isEditing else { return }
        // Clear the state first: taking focus away from the editor ends its
        // editing, which calls back into editorDidEndEditing.
        isEditing = false
        editingTarget = nil
        editMode = .ready
        if let document, document.pendingEditor === self { document.pendingEditor = nil }
        host?.removeEditor(refocusGrid: refocus)
    }

    /// Focus left the cell editor for another control (the formula bar,
    /// name box, Find field…): commit, as Numbers does, rather than leave
    /// an orphaned editor holding typing nobody can see being lost.
    func editorDidEndEditing() {
        guard isEditing else { return }
        commitEditorIfNeeded(refocus: false)
    }

    /// Keys the open editor passes to the grid.
    enum EditorCommand {
        case newline
        case tab
        case backtab
        case cancel
        case arrow(SelectionState.Direction)
    }

    /// Handle an editor key; false lets the editor handle it (an arrow
    /// moving the caret in Edit mode).
    func editorCommand(_ command: EditorCommand) -> Bool {
        guard document != nil else { return false }
        switch command {
        case .newline:
            commitAndMove(.down)
        case .tab:
            commitAndMove(.right)
        case .backtab:
            commitAndMove(.left)
        case .cancel:
            cancelEditing()
        case .arrow(let direction):
            guard editMode == .enter else { return false }
            commitAndMove(direction)
        }
        return true
    }

    private func commitAndMove(_ direction: SelectionState.Direction) {
        commitEditorIfNeeded()
        navigate(direction)
        afterNavigation()
    }
}

/// The in-cell editor is the document's pending edit while it is open.
extension GridController: PendingEditor {
    var hasPendingEdit: Bool { isEditing }

    func commitPendingEdit() {
        commitEditorIfNeeded()
    }
}
