import CoreGraphics
import Foundation
import SpreadsheetCore
import SpreadsheetFiles

/// The active sheet's parsed charts, and the last chart edit (to fold a
/// run of the same edit, such as dragging through colours, into one undo
/// step).
struct ChartState {
    var source: SheetChartSource?
    var cache: (revision: Int, sheetID: Int, charts: [SheetChart])?
    var lastEdit: (id: String, field: String, revision: Int, time: Date)?
}

// Charts: inserting one from the selection, moving, resizing, changing and
// deleting them. Charts live in the workbook's carried parts
// (XLSXChartEditor); each change replaces that value, so undo puts the old
// value back.
extension SpreadsheetDocument {
    /// The charts on the active sheet as it is now.
    public var activeCharts: [SheetChart] {
        let sheetID = activeSheetID
        if let cache = chartState.cache, cache.revision == revision, cache.sheetID == sheetID {
            return cache.charts
        }
        // Parts are parsed again only when an edit changed them, and only
        // those; charts read the cells again only when they may have changed.
        if chartState.source?.sheetID != sheetID || chartState.source?.isCurrent(for: workbook) != true {
            chartState.source = SheetChartSource(workbook: workbook, sheetID: sheetID, reusing: chartState.source)
        }
        let charts = chartState.source?.charts(in: workbook, inputsRevision: chartInputsRevision) ?? []
        chartState.cache = (revision, sheetID, charts)
        return charts
    }

    /// The selected chart, if it's still on the active sheet.
    public var selectedChart: SheetChart? {
        guard let id = selectedChartID else { return nil }
        return activeCharts.first { $0.id == id }
    }

    public func selectChart(_ id: String?) {
        if selectedChartID != id { selectedChartID = id }
    }

    /// Select the next chart on the sheet after the selected one (or the
    /// previous), or from the cells the first (or last), and show it: Tab
    /// among charts, and the way to a chart without a pointer.
    public func selectNextChart(backward: Bool = false) {
        let charts = activeCharts
        guard !charts.isEmpty else { return }
        commitPendingEdit()
        let current = selectedChart.flatMap { c in charts.firstIndex { $0.id == c.id } }
        let next = current.map { ($0 + (backward ? charts.count - 1 : 1)) % charts.count } ?? (backward ? charts.count - 1 : 0)
        selectChart(charts[next].id)
        requestScrollToActiveCell() // the grid shows the selected chart
    }

    // MARK: Commands

    /// Insert ▸ Chart: a chart of `kind` over the selection (or the block
    /// of data around the active cell), placed to the right of it and
    /// selected. False, with a notice, when there's nothing to chart.
    @discardableResult
    public func insertChart(_ kind: SheetChart.Kind, grouping: SheetChart.Grouping = .standard) -> Bool {
        commitPendingEdit()
        let sheet = activeSheet
        var range = sheet.expandedForMerges(selection.range)
        if range.isSingleCell { range = sheet.currentRegion(around: range.start) }
        // Whole columns or rows (or more than the data): only as far as the data goes.
        if let used = sheet.usedRange {
            let trimmed = CellRange(start: CellAddress(row: max(range.start.row, used.start.row),
                                                       column: max(range.start.column, used.start.column)),
                                    end: CellAddress(row: min(range.end.row, used.end.row),
                                                     column: min(range.end.column, used.end.column)))
            if trimmed.start.row <= trimmed.end.row, trimmed.start.column <= trimmed.end.column { range = trimmed }
        }
        let block = ChartRange(sheetName: sheet.name, range: range)
        let settings = ChartSettings.new(kind, grouping: grouping, from: block, in: workbook)
        guard !settings.series.isEmpty, hasNumbers(in: range, sheet: sheet) else {
            notice = DocumentNotice(message: "Select the data for the chart",
                                    detail: "Select cells with numbers to chart, with their labels if you like, then insert the chart.")
            return false
        }
        // Excel's default size (5 × 3 inches), to the right of the data.
        let layout = GridLayout(sheet: sheet)
        let origin = CGPoint(x: layout.xOffset(ofColumn: range.end.column + 2), y: layout.yOffset(ofRow: range.start.row))
        let placement = Self.placement(for: CGRect(origin: origin, size: CGSize(width: 480, height: 288)), in: layout)
        var id: String?
        changeCharts(actionName: "Insert Chart") {
            id = XLSXChartEditor.insert(settings, onSheet: sheet.id, from: placement.from, to: placement.to,
                                        in: workbook)
            return id != nil
        }
        selectChart(id)
        isChartPanelVisible = true
        requestScrollToActiveCell() // the grid shows the selected chart
        return id != nil
    }

    private func hasNumbers(in range: CellRange, sheet: Sheet) -> Bool {
        var found = false
        range.forEachAddress { if !found, case .number = sheet.value(at: $0) { found = true } }
        return found
    }

    /// Move or resize a chart to `frame` (sheet content coordinates: 0,0 is
    /// A1's top-left corner). `nudge`: a run of these on one chart is one
    /// undo step (arrow keys held down).
    public func placeChart(_ id: String, frame: CGRect, nudge: Bool = false) {
        let layout = GridLayout(sheet: activeSheet)
        let placement = Self.placement(for: frame, in: layout)
        let sheetID = activeSheetID
        let now = Date()
        let continuing = nudge && chartState.lastEdit.map {
            $0.id == id && $0.field == "nudge" && $0.revision == revision && now.timeIntervalSince($0.time) < 1.5
        } ?? false
        changeCharts(actionName: "Move Chart", registerUndo: !continuing) {
            XLSXChartEditor.place(id, onSheet: sheetID, from: placement.from, to: placement.to,
                                  size: placement.size, in: workbook)
        }
        chartState.lastEdit = nudge ? (id, "nudge", revision, now) : nil
    }

    /// Change a chart's settings. Steps changing the same thing one after
    /// another (dragging through colours) undo together.
    public func updateChart(_ id: String, to settings: ChartSettings, actionName: String = "Change Chart") {
        guard let chart = activeCharts.first(where: { $0.id == id }), let old = chart.settings, old != settings else { return }
        let field = Self.changedField(old, settings)
        let now = Date()
        let continuing = chartState.lastEdit.map {
            $0.id == id && $0.field == field && $0.revision == revision && now.timeIntervalSince($0.time) < 1.5
        } ?? false
        changeCharts(actionName: actionName, registerUndo: !continuing) {
            XLSXChartEditor.update(id, from: old, to: settings, in: workbook)
        }
        chartState.lastEdit = (id, field, revision, now)
    }

    public func deleteChart(_ id: String) {
        let sheetID = activeSheetID
        changeCharts(actionName: "Delete Chart") {
            XLSXChartEditor.delete(id, onSheet: sheetID, in: workbook)
        }
        if selectedChartID == id { selectChart(nil) }
    }

    /// The data range typed into the panel: `Sheet1!A1:D7` or `A1:D7` (on
    /// the chart's sheet), with or without `=` and `$`. Series are made
    /// from it the way Insert makes them; colours stay with their series.
    public func setChartData(_ id: String, range text: String, inRows: Bool? = nil) -> Bool {
        guard let chart = activeCharts.first(where: { $0.id == id }), var settings = chart.settings else { return false }
        var formula = text.trimmingCharacters(in: .whitespaces)
        if formula.hasPrefix("=") { formula.removeFirst() }
        if !formula.contains("!") {
            let sheetName = settings.dataRange(in: workbook)?.sheetName ?? activeSheet.name
            formula = ReferenceExpr.quoteSheetNameIfNeeded(sheetName) + "!" + formula
        }
        guard let block = ChartRange(formula: formula), workbook.sheet(named: block.sheetName) != nil else { return false }
        let series = ChartSettings.series(from: block, in: workbook, kind: settings.kind,
                                          inRows: inRows ?? (settings.series.count > 1 ? settings.seriesInRows(in: workbook) : nil))
        guard !series.isEmpty else { return false }
        let colors = settings.series.map(\.color)
        settings.series = series.enumerated().map { i, s in
            var s = s
            if i < colors.count { s.color = colors[i] }
            return s
        }
        updateChart(id, to: settings, actionName: "Change Chart Data")
        return true
    }

    // MARK: Plumbing

    /// Run a chart edit (it returns whether it changed anything) as one
    /// undo step that puts back the carried parts and the chart selection.
    @discardableResult
    func changeCharts(actionName: String, registerUndo: Bool = true, _ edit: () -> Bool) -> Bool {
        let before = workbook.carriedContent
        let selectedBefore = selectedChartID
        guard edit() else { return false }
        if registerUndo { registerChartUndo(before, selected: selectedBefore, actionName: actionName) }
        markChanged()
        return true
    }

    private func registerChartUndo(_ content: (any CarriedContent)?, selected: String?, actionName: String) {
        withUndoGroup {
            undoManager.registerUndo(withTarget: self) { doc in
                MainActor.assumeIsolated {
                    let current = doc.workbook.carriedContent
                    let currentSelection = doc.selectedChartID
                    doc.workbook.carriedContent = content
                    doc.registerChartUndo(current, selected: currentSelection, actionName: actionName)
                    doc.chartState.lastEdit = nil
                    doc.markChanged()
                    doc.selectChart(selected)
                }
            }
            undoManager.setActionName(actionName)
        }
    }

    /// Which setting changed (for folding repeats into one undo step).
    private static func changedField(_ a: ChartSettings, _ b: ChartSettings) -> String {
        if a.series.map(\.color) != b.series.map(\.color) {
            let index = zip(a.series, b.series).enumerated().first { $0.element.0.color != $0.element.1.color }?.offset ?? 0
            return "color\(index)"
        }
        if a.title != b.title { return "title" }
        return UUID().uuidString // anything else: its own step
    }

    /// Anchors for a frame in content coordinates: the cells its corners
    /// fall in, with offsets in pixels.
    static func placement(for frame: CGRect, in layout: GridLayout)
        -> (from: SheetChart.Anchor, to: SheetChart.Anchor, size: SheetChart.Size) {
        func anchor(_ point: CGPoint) -> SheetChart.Anchor {
            let column = layout.column(atX: max(0, point.x))
            let row = layout.row(atY: max(0, point.y))
            return SheetChart.Anchor(column: column, columnOffset: Double(max(0, point.x - layout.xOffset(ofColumn: column))),
                                     row: row, rowOffset: Double(max(0, point.y - layout.yOffset(ofRow: row))))
        }
        return (anchor(frame.origin), anchor(CGPoint(x: frame.maxX, y: frame.maxY)),
                SheetChart.Size(width: Double(frame.width), height: Double(frame.height)))
    }

    /// Where a chart's anchor sits, in content coordinates.
    static func anchorFrame(of chart: SheetChart, in layout: GridLayout) -> CGRect {
        func point(_ anchor: SheetChart.Anchor) -> CGPoint {
            // An offset stays inside its cell (a hidden row or column has none).
            CGPoint(x: layout.xOffset(ofColumn: anchor.column) + min(CGFloat(anchor.columnOffset), layout.columnWidth(anchor.column)),
                    y: layout.yOffset(ofRow: anchor.row) + min(CGFloat(anchor.rowOffset), layout.rowHeight(anchor.row)))
        }
        let origin = point(chart.from)
        if let to = chart.to {
            let corner = point(to)
            return CGRect(x: origin.x, y: origin.y, width: max(0, corner.x - origin.x), height: max(0, corner.y - origin.y))
        }
        let size = chart.size ?? SheetChart.Size(width: 480, height: 288)
        return CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// Where a chart shows, in content coordinates: its anchor's frame, or
    /// for a chart in a group, its part of the group's frame.
    static func contentFrame(of chart: SheetChart, in layout: GridLayout) -> CGRect {
        let frame = anchorFrame(of: chart, in: layout)
        guard let f = chart.groupFraction else { return frame }
        return CGRect(x: frame.minX + frame.width * f.x, y: frame.minY + frame.height * f.y,
                      width: frame.width * f.width, height: frame.height * f.height)
    }
}
