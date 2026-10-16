import Foundation
import SpreadsheetCore

// Charts on a sheet, read from the drawings and chart parts an opened XLSX
// carries (CarriedParts), for display. Saving doesn't use any of this: the
// parts are written back as read.
//
// Covered: column and bar, line, area, pie and doughnut, scatter (3-D
// variants draw flat; bar-of-pie draws as a pie), clustered, stacked and
// 100% stacked, combinations of these on one plot, titles, axis titles,
// legends and explicit series colours. Series values come from the cells
// they point at, so a chart follows edits; a series whose formula can't be
// followed falls back to the values cached in the file. Anything else
// (radar, stock, surface, bubble, and the newer chartex types such as
// waterfall and treemap) is still placed, and drawn as a labelled box.

/// A chart on a sheet, ready to draw.
public struct SheetChart: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case column, bar, line, area, pie, doughnut, scatter
    }

    public enum Grouping: Hashable, Sendable {
        case standard, stacked, percentStacked
    }

    public enum LegendPosition: Hashable, Sendable {
        case top, bottom, left, right
    }

    public struct Series: Hashable, Sendable {
        public var name: String
        public var kind: Kind
        /// Category labels (x values as text for a scatter's tooltips).
        public var categories: [String]
        /// One per category; nil for a blank or non-numeric cell.
        public var values: [Double?]
        /// A scatter's x values (empty for other kinds).
        public var xValues: [Double?]
        public var color: RGBAColor
        /// Per-point colours (pie and doughnut slices), one per value.
        public var pointColors: [RGBAColor]
        public var showsMarkers: Bool
        public var showsLine: Bool
        /// Values shown beside the points.
        public var showsLabels = false
        /// Plotted against the secondary (right-hand) value axis.
        public var secondary = false
    }

    public init(id: String, name: String = "Chart", from: Anchor, to: Anchor? = nil, size: Size? = nil) {
        self.id = id
        self.name = name
        self.from = from
        self.to = to
        self.size = size
        grouping = .standard
        series = []
        showsDataLabels = false
    }

    /// Where the chart sits: a cell and an offset in pixels.
    public struct Anchor: Hashable, Sendable {
        public var column: Int
        public var columnOffset: Double
        public var row: Int
        public var rowOffset: Double

        public init(column: Int, columnOffset: Double = 0, row: Int, rowOffset: Double = 0) {
            self.column = column
            self.columnOffset = columnOffset
            self.row = row
            self.rowOffset = rowOffset
        }
    }

    /// A part of a frame, in fractions of its width and height.
    public struct UnitRect: Hashable, Sendable {
        public var x, y, width, height: Double
    }

    /// The chart part's path: which chart this is, for editing it.
    public var id: String
    public var name: String
    public var from: Anchor
    /// The bottom-right corner, when anchored to a cell.
    public var to: Anchor?
    /// The size in pixels (width, height), when the chart isn't anchored by
    /// its bottom-right corner.
    public var size: Size?
    /// For a chart in a group of shapes: where in the group's frame (which
    /// is what the anchor places). Such a chart moves with its group.
    public var groupFraction: UnitRect?

    public struct Size: Hashable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }
    public var title: String?
    public var grouping: Grouping
    public var series: [Series]
    public var legend: LegendPosition?
    public var categoryAxisTitle: String?
    public var valueAxisTitle: String?
    /// Any series shows its values.
    public var showsDataLabels: Bool
    /// Set when the chart's type isn't drawn: what it is ("Radar chart").
    public var unsupported: String?
    /// What the chart panel edits; nil when the chart can only be moved,
    /// resized or deleted (a type not drawn, or series not from cells).
    public var settings: ChartSettings?
    /// What the chart shows (not where): equal for charts that draw the same.
    public var fingerprint = 0

    /// The main kind: the first series'.
    public var kind: Kind? { series.first?.kind }
    public var isGrouped: Bool { groupFraction != nil }
    public var hasSecondaryAxis: Bool { series.contains { $0.secondary } }

    /// At most `maxPoints` points per series, keeping the shape: the
    /// lowest and highest value of each run of points (of the first
    /// series, so stacks and clusters stay aligned), every n-th point of a
    /// scatter, and the largest slices of a pie (the rest as "Other").
    public func reduced(toPoints maxPoints: Int) -> SheetChart {
        let limit = max(8, maxPoints)
        guard let longest = series.map({ $0.values.count }).max(), longest > limit else { return self }
        var chart = self
        switch kind {
        case .scatter?:
            chart.series = series.map { s in
                guard s.values.count > limit else { return s }
                let step = Double(s.values.count) / Double(limit)
                return Self.picking((0..<limit).map { Int(Double($0) * step) }, from: s)
            }
        case .pie?, .doughnut?:
            chart.series = series.map { s in
                guard s.values.count > limit else { return s }
                let order = s.values.indices.sorted { (s.values[$0] ?? 0) > (s.values[$1] ?? 0) }
                let kept = Array(order.prefix(limit - 1)).sorted()
                var picked = Self.picking(kept, from: s)
                let rest = order.dropFirst(limit - 1).reduce(0.0) { $0 + max(0, s.values[$1] ?? 0) }
                picked.values.append(rest)
                picked.categories.append("Other")
                picked.pointColors.append(RGBAColor(red: 0xA5, green: 0xA5, blue: 0xA5))
                return picked
            }
        default:
            let reference = series.first { !$0.values.isEmpty } ?? series[0]
            let buckets = (limit - 2) / 2 // two per run, plus the ends
            let size = Double(longest) / Double(buckets)
            var keep = Set<Int>([0, longest - 1])
            for b in 0..<buckets {
                let lo = Int(Double(b) * size), hi = min(longest, Int(Double(b + 1) * size))
                guard lo < hi else { continue }
                var minIndex = lo, maxIndex = lo
                for i in lo..<hi where i < reference.values.count {
                    guard let v = reference.values[i] else { continue }
                    if v < (reference.values[minIndex] ?? .infinity) { minIndex = i }
                    if v > (reference.values[maxIndex] ?? -.infinity) { maxIndex = i }
                }
                keep.insert(minIndex)
                keep.insert(maxIndex)
            }
            let indices = keep.sorted()
            chart.series = series.map { Self.picking(indices, from: $0) }
        }
        return chart
    }

    private static func picking(_ indices: [Int], from s: Series) -> Series {
        var out = s
        func pick<T>(_ array: [T]) -> [T] { array.isEmpty ? [] : indices.compactMap { $0 < array.count ? array[$0] : nil } }
        out.values = pick(s.values)
        out.categories = pick(s.categories)
        out.xValues = pick(s.xValues)
        out.pointColors = pick(s.pointColors)
        return out
    }
}

/// A sheet's charts as parsed from their parts. Parsing is the slow part,
/// so it is kept per part while the part's bytes stay the same (moving a
/// chart reparses only the drawing), and what each chart read from the
/// cells is kept until something that could change it does.
public final class SheetChartSource {
    public let sheetID: Int
    /// Bytes of the drawings and theme this was parsed from, by path.
    private let sources: [String: Data]
    private let entries: [Entry]
    /// Chart parts by path: their bytes and parsed tree.
    private let parsed: [String: (data: Data, root: XMLNode?)]
    private let palette: [RGBAColor]
    /// What each chart read last (placement aside), when, and from what.
    private var resolved: [String: (inputs: Int, chart: SheetChart, uses: Uses)] = [:]

    /// What a chart's reading depended on: the blocks of cells it read,
    /// and the state of their sheets and of the defined names then.
    struct Uses {
        struct SheetState: Equatable {
            var stamp: Int
            var hiddenRows: Set<Int>
            var hiddenColumns: Set<Int>
            var rowStyles: [Int: Int]
            var columnStyles: [Int: Int]

            init(_ sheet: Sheet) {
                stamp = sheet.changeStamp
                hiddenRows = sheet.hiddenRows
                hiddenColumns = sheet.hiddenColumns
                rowStyles = sheet.rowStyles
                columnStyles = sheet.columnStyles
            }
        }

        var areas: [ChartRange]
        var sheets: [String: SheetState]
        var names: [DefinedName]

        init(areas: [ChartRange], workbook: Workbook) {
            self.areas = areas
            var sheets: [String: SheetState] = [:]
            for area in areas where sheets[area.sheetName] == nil {
                if let sheet = workbook.sheet(named: area.sheetName) { sheets[area.sheetName] = SheetState(sheet) }
            }
            self.sheets = sheets
            names = workbook.definedNames
        }

        /// Still what the workbook holds (with the stamps brought up to
        /// date), or nil: a cell it read has changed, or something that
        /// changes how cells read (hidden rows, formats, names).
        func current(in workbook: Workbook) -> Uses? {
            guard workbook.definedNames == names else { return nil }
            var updated = self
            for (name, state) in sheets {
                guard let sheet = workbook.sheet(named: name) else { return nil }
                if sheet.changeStamp != state.stamp {
                    guard let changed = sheet.changedCells(since: state.stamp) else { return nil }
                    let mine = areas.filter { $0.sheetName == name }.map(\.range)
                    if changed.contains(where: { address in mine.contains { $0.contains(address) } }) { return nil }
                }
                let now = SheetState(sheet)
                guard now.hiddenRows == state.hiddenRows, now.hiddenColumns == state.hiddenColumns,
                      now.rowStyles == state.rowStyles, now.columnStyles == state.columnStyles else { return nil }
                updated.sheets[name] = now
            }
            return updated
        }
    }

    private struct Entry {
        var path: String
        var name: String
        var placement: XLSXCharts.Placement
        var fraction: SheetChart.UnitRect?
    }

    /// Parse the charts on a sheet of `workbook`, reusing what `previous`
    /// parsed from parts that haven't changed.
    public init(workbook: Workbook, sheetID: Int, reusing previous: SheetChartSource? = nil) {
        self.sheetID = sheetID
        let old = previous?.sheetID == sheetID ? previous : nil
        (sources, entries, parsed, palette) = Self.parse(workbook, sheetID, old)
        // What was read stays good for charts whose part and theme are as they were.
        if let old, old.palette == palette {
            resolved = old.resolved.filter { path, _ in
                guard let now = parsed[path]?.data, let before = old.parsed[path]?.data else { return false }
                return now == before
            }
        }
    }

    private static func parse(_ workbook: Workbook, _ sheetID: Int, _ old: SheetChartSource?)
        -> ([String: Data], [Entry], [String: (data: Data, root: XMLNode?)], [RGBAColor]) {
        var sources: [String: Data] = [:]
        var entries: [Entry] = []
        var parsed: [String: (data: Data, root: XMLNode?)] = [:]
        var palette = XLSXCharts.defaultAccents
        guard let carried = workbook.carriedContent as? CarriedParts, let sheet = carried.sheets[sheetID],
              sheet.relationships.contains(where: { $0.type.hasSuffix("/drawing") }) else {
            return (sources, entries, parsed, palette)
        }
        if let (path, accents) = XLSXCharts.themeAccents(carried) {
            sources[path] = carried.parts[path]?.data
            palette = accents
        }
        for rel in sheet.relationships where rel.type.hasSuffix("/drawing") {
            guard case .part(let path) = rel.target, let part = carried.parts[path] else { continue }
            sources[path] = part.data
            guard let root = try? XMLNode.parse(part.data) else { continue }
            let chartPaths = Dictionary(part.relationships.compactMap { rel -> (String, String)? in
                guard case .part(let target) = rel.target else { return nil }
                return (rel.id, target)
            }, uniquingKeysWith: { a, _ in a })
            for anchor in root.elements {
                guard let placement = XLSXCharts.placement(of: anchor) else { continue }
                for found in XLSXCharts.chartFrames(in: anchor) {
                    guard let chartPath = chartPaths[found.relationshipID], let chartPart = carried.parts[chartPath]
                    else { continue }
                    if parsed[chartPath] == nil {
                        if let previous = old?.parsed[chartPath], previous.data == chartPart.data {
                            parsed[chartPath] = previous
                        } else {
                            parsed[chartPath] = (chartPart.data, try? XMLNode.parse(chartPart.data))
                        }
                    }
                    entries.append(Entry(path: chartPath, name: found.name, placement: placement,
                                         fraction: found.fraction))
                }
            }
        }
        return (sources, entries, parsed, palette)
    }

    /// Whether `workbook`'s parts still say what this was parsed from (an
    /// edit that moves cells or renames a sheet rewrites them).
    public func isCurrent(for workbook: Workbook) -> Bool {
        guard let carried = workbook.carriedContent as? CarriedParts else { return sources.isEmpty && parsed.isEmpty }
        let drawings = (carried.sheets[sheetID]?.relationships ?? []).compactMap { rel -> String? in
            guard rel.type.hasSuffix("/drawing"), case .part(let path) = rel.target else { return nil }
            return path
        }
        return drawings.allSatisfy { sources[$0] != nil }
            && sources.allSatisfy { path, data in carried.parts[path]?.data == data }
            && parsed.allSatisfy { path, entry in carried.parts[path]?.data == entry.data }
    }

    /// The charts, with the values their series point at in `workbook`.
    /// `inputsRevision` says when the document last changed in a way that
    /// could matter: a chart read at the same one isn't checked again, and
    /// otherwise is read again only if a cell it reads has changed (pass
    /// nil to always read).
    public func charts(in workbook: Workbook, inputsRevision: Int? = nil) -> [SheetChart] {
        entries.map { entry in
            var chart: SheetChart
            if let inputsRevision, let cached = resolved[entry.path],
               cached.inputs == inputsRevision || {
                   guard let uses = cached.uses.current(in: workbook) else { return false }
                   resolved[entry.path] = (inputsRevision, cached.chart, uses)
                   return true
               }() {
                chart = cached.chart
            } else {
                chart = SheetChart(id: entry.path, from: entry.placement.from)
                var areas: [ChartRange] = []
                if let root = parsed[entry.path]?.root {
                    areas = XLSXCharts.read(root, into: &chart, workbook: workbook, palette: palette)
                } else {
                    chart.unsupported = "Chart"
                }
                chart = chart.reduced(toPoints: XLSXCharts.maxPointsRead)
                chart.fingerprint = chart.hashValue
                if let inputsRevision {
                    resolved[entry.path] = (inputsRevision, chart, Uses(areas: areas, workbook: workbook))
                }
            }
            chart.name = entry.name
            chart.from = entry.placement.from
            chart.to = entry.placement.to
            chart.size = entry.placement.size
            chart.groupFraction = entry.fraction
            return chart
        }
    }
}

public enum XLSXCharts {
    /// The charts on a sheet of `workbook`, in drawing order.
    public static func charts(in workbook: Workbook, sheetID: Int) -> [SheetChart] {
        SheetChartSource(workbook: workbook, sheetID: sheetID).charts(in: workbook)
    }

    /// Points kept per series when a chart is read (see SheetChart.reduced):
    /// more than any plot has pixels for.
    public static let maxPointsRead = 4096

    // MARK: Placement

    /// EMUs per pixel (at 96 dpi). Offsets and sizes come out in pixels,
    /// the grid's unit both ways.
    static let emuPerPixel = 9525.0

    typealias Placement = (from: SheetChart.Anchor, to: SheetChart.Anchor?, size: SheetChart.Size?)

    static func placement(of anchor: XMLNode) -> Placement? {
        // Positions in a file can say anything: keep them on the sheet.
        func corner(_ node: XMLNode?) -> SheetChart.Anchor? {
            guard let node, let col = int(node.firstChild("col")), let row = int(node.firstChild("row")) else { return nil }
            return SheetChart.Anchor(column: min(max(0, col), CellAddress.maxColumns - 1),
                                     columnOffset: pixels(int(node.firstChild("colOff")) ?? 0),
                                     row: min(max(0, row), CellAddress.maxRows - 1),
                                     rowOffset: pixels(int(node.firstChild("rowOff")) ?? 0))
        }
        func extent(_ node: XMLNode?) -> SheetChart.Size? {
            guard let node, let cx = Double(node.attributes["cx"] ?? ""), let cy = Double(node.attributes["cy"] ?? "")
            else { return nil }
            return SheetChart.Size(width: pixels(cx), height: pixels(cy))
        }
        switch anchor.localName {
        case "twoCellAnchor":
            guard let from = corner(anchor.firstChild("from")), let to = corner(anchor.firstChild("to")) else { return nil }
            return (from, to, nil)
        case "oneCellAnchor":
            guard let from = corner(anchor.firstChild("from")), let size = extent(anchor.firstChild("ext")) else { return nil }
            return (from, nil, size)
        case "absoluteAnchor":
            // Placed in EMUs from the sheet's corner: as an offset from A1.
            guard let pos = anchor.firstChild("pos"), let size = extent(anchor.firstChild("ext")) else { return nil }
            let x = pixels(Double(pos.attributes["x"] ?? "") ?? 0), y = pixels(Double(pos.attributes["y"] ?? "") ?? 0)
            return (SheetChart.Anchor(column: 0, columnOffset: x, row: 0, rowOffset: y), nil, size)
        default:
            return nil
        }
    }

    /// EMUs as pixels, within reason (0 to 100,000).
    private static func pixels<T: BinaryInteger>(_ emu: T) -> Double { pixels(Double(emu)) }
    private static func pixels(_ emu: Double) -> Double {
        guard emu.isFinite else { return 0 }
        return min(max(0, emu / emuPerPixel), 100_000)
    }

    /// The charts an anchor shows: its graphic frame, or the frames in its
    /// group of shapes (each placed within the group's frame), by their
    /// relationship ids.
    static func chartFrames(in anchor: XMLNode) -> [(relationshipID: String, name: String, fraction: SheetChart.UnitRect?)] {
        typealias Rect = (x: Double, y: Double, w: Double, h: Double)
        func xfrm(_ node: XMLNode?) -> (off: Rect, child: Rect?)? {
            guard let node, let off = node.firstChild("off"), let ext = node.firstChild("ext") else { return nil }
            func d(_ n: XMLNode?, _ key: String) -> Double { Double(n?.attributes[key] ?? "") ?? 0 }
            let rect = (d(off, "x"), d(off, "y"), d(ext, "cx"), d(ext, "cy"))
            let chOff = node.firstChild("chOff"), chExt = node.firstChild("chExt")
            let child = chOff.flatMap { o in chExt.map { e in (d(o, "x"), d(o, "y"), d(e, "cx"), d(e, "cy")) } }
            return (rect, child)
        }
        var found: [(String, String, SheetChart.UnitRect?)] = []
        var outer: Rect?
        // `map` takes a rect in the current group's child space to the outermost group's space.
        func visit(_ node: XMLNode, _ map: ((Rect) -> Rect)?) {
            switch node.localName {
            case "AlternateContent":
                // The first branch that shows a chart, not both.
                let before = found.count
                for branch in node.elements where branch.localName == "Choice" { visit(branch, map); if found.count > before { return } }
                for branch in node.elements where branch.localName == "Fallback" { visit(branch, map) }
            case "grpSp":
                guard let frame = xfrm(node.firstChild("grpSpPr")?.firstChild("xfrm")) else {
                    node.elements.forEach { visit($0, map) }
                    return
                }
                if map == nil { outer = frame.off }
                let child = frame.child ?? frame.off
                let toParent: (Rect) -> Rect = { r in
                    let sx = child.w > 0 ? frame.off.w / child.w : 1, sy = child.h > 0 ? frame.off.h / child.h : 1
                    return (frame.off.x + (r.x - child.x) * sx, frame.off.y + (r.y - child.y) * sy, r.w * sx, r.h * sy)
                }
                let composed: (Rect) -> Rect = { r in map.map { $0(toParent(r)) } ?? toParent(r) }
                node.elements.forEach { visit($0, composed) }
            case "graphicFrame":
                var relID: String?
                node.forEach { if relID == nil, $0.localName == "chart" || $0.localName == "chartex" {
                    relID = CarriedParts.relationshipID(of: $0)
                } }
                guard let relID else { return }
                var name = "Chart"
                if let n = node.firstChild("nvGraphicFramePr")?.firstChild("cNvPr")?.attributes["name"], !n.isEmpty { name = n }
                var fraction: SheetChart.UnitRect?
                if let map, let outer, outer.w > 0, outer.h > 0, let own = xfrm(node.firstChild("xfrm")) {
                    let r = map(own.off)
                    func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
                    fraction = SheetChart.UnitRect(x: unit((r.x - outer.x) / outer.w), y: unit((r.y - outer.y) / outer.h),
                                                   width: unit(r.w / outer.w), height: unit(r.h / outer.h))
                } else if map != nil {
                    fraction = SheetChart.UnitRect(x: 0, y: 0, width: 1, height: 1)
                }
                found.append((relID, name, fraction))
            default:
                node.elements.forEach { visit($0, map) }
            }
        }
        visit(anchor, nil)
        return found
    }

    // MARK: Chart parts

    /// Read a chart part into `chart`. Returns the blocks of cells it read.
    @discardableResult
    static func read(_ root: XMLNode, into chart: inout SheetChart, workbook: Workbook, palette: [RGBAColor]) -> [ChartRange] {
        // The newer chart types (waterfall, treemap, …) are cx:chartSpace, in their own namespace.
        guard root.localName == "chartSpace", !root.namespaceURI(of: root).contains("chartex"),
              let body = root.firstChild("chart"), let plot = body.firstChild("plotArea") else {
            chart.unsupported = "Chart"
            // cx:title/cx:tx/cx:txData/cx:v; the series says what kind (layoutId="waterfall").
            if let tx = root.firstChild("chart")?.firstChild("title")?.firstChild("tx") {
                var text = ""
                tx.forEach { if $0.localName == "v" || $0.localName == "t" { text += $0.text } }
                chart.title = text.isEmpty ? nil : text
            }
            var layout: String?
            root.forEach { if layout == nil, $0.localName == "series" { layout = $0.attributes["layoutId"] } }
            if let layout, let name = chartexNames[layout] { chart.unsupported = name }
            return []
        }
        let plotVisibleOnly = body.firstChild("plotVisOnly").map { !isFalse(val($0)) } ?? true
        let reader = SeriesReader(workbook: workbook, visibleOnly: plotVisibleOnly)

        var unsupported: String?
        var colorIndex = 0
        var sources: [ChartSeriesSource] = []
        var editable = true
        // The primary value axis: the first group's second axis.
        var primaryValueAxis: String?
        var labelsSeen = Set<Bool>()
        for group in plot.elements {
            let local = group.localName
            guard local.hasSuffix("Chart") else { continue }
            let kind: SheetChart.Kind
            switch local {
            case "barChart", "bar3DChart":
                kind = group.firstChild("barDir").map(val) == "bar" ? .bar : .column
            case "lineChart", "line3DChart": kind = .line
            case "areaChart", "area3DChart": kind = .area
            case "pieChart", "pie3DChart", "ofPieChart": kind = .pie
            case "doughnutChart": kind = .doughnut
            case "scatterChart": kind = .scatter
            case "radarChart": unsupported = unsupported ?? "Radar chart"; continue
            case "stockChart": unsupported = unsupported ?? "Stock chart"; continue
            case "bubbleChart": unsupported = unsupported ?? "Bubble chart"; continue
            case "surfaceChart", "surface3DChart": unsupported = unsupported ?? "Surface chart"; continue
            default: continue
            }
            if chart.series.isEmpty {
                switch group.firstChild("grouping").map(val) {
                case "stacked": chart.grouping = .stacked
                case "percentStacked": chart.grouping = .percentStacked
                default: chart.grouping = .standard
                }
            }
            let axisIDs = group.children("axId").map(val)
            if primaryValueAxis == nil, axisIDs.count >= 2 { primaryValueAxis = axisIDs[1] }
            let secondary = axisIDs.count >= 2 && primaryValueAxis != nil && axisIDs[1] != primaryValueAxis
            let varyColors = kind == .pie || kind == .doughnut
                ? group.firstChild("varyColors").map { !isFalse(val($0)) } ?? true : false
            let groupLabels = showsValues(group.firstChild("dLbls")) ?? false
            let scatterStyle = group.firstChild("scatterStyle").map(val) ?? "marker"
            let groupHasMarkers = group.firstChild("marker").map { !isFalse(val($0)) } ?? (kind == .line)
            for ser in group.elements where ser.localName == "ser" {
                let index = int(ser.firstChild("idx")).map { min(max(0, $0), 1_000) } ?? colorIndex
                colorIndex += 1
                let fallback = accent(index, palette)
                let color = fillColor(of: ser.firstChild("spPr"), line: kind == .line || kind == .scatter, palette) ?? fallback
                var series = SheetChart.Series(name: "", kind: kind, categories: [], values: [], xValues: [],
                                               color: color, pointColors: [], showsMarkers: false, showsLine: true)
                series.name = reader.text(of: ser.firstChild("tx")) ?? "Series \(index + 1)"
                series.secondary = secondary
                // A series' own labels say more than its group's.
                series.showsLabels = showsValues(ser.firstChild("dLbls")) ?? groupLabels
                labelsSeen.insert(series.showsLabels)
                if kind == .scatter {
                    series.values = reader.numbers(of: ser.firstChild("yVal"))
                    series.xValues = reader.numbers(of: ser.firstChild("xVal"))
                    // x values that aren't all numbers: Excel plots 1, 2, 3, …
                    if series.xValues.count < series.values.count || series.xValues.contains(where: { $0 == nil }) {
                        series.xValues = series.values.indices.map { Double($0 + 1) }
                    }
                    series.categories = series.xValues.map { $0.map { formatNumber($0) } ?? "" }
                } else {
                    series.values = reader.numbers(of: ser.firstChild("val"))
                    series.categories = reader.labels(of: ser.firstChild("cat"))
                }
                // Categories default to 1, 2, 3, …
                if series.categories.count < series.values.count {
                    series.categories += (series.categories.count..<series.values.count).map { String($0 + 1) }
                }
                let markerSymbol = ser.firstChild("marker")?.firstChild("symbol").map(val)
                switch kind {
                case .line:
                    series.showsMarkers = markerSymbol.map { $0 != "none" } ?? groupHasMarkers
                case .scatter:
                    let lineHidden = ser.firstChild("spPr")?.firstChild("ln")?.firstChild("noFill") != nil
                    series.showsLine = !lineHidden && !["marker", "none"].contains(scatterStyle)
                    series.showsMarkers = markerSymbol.map { $0 != "none" } ?? (scatterStyle.contains("arker"))
                    if !series.showsLine && !series.showsMarkers { series.showsMarkers = true }
                default: break
                }
                if varyColors || kind == .pie || kind == .doughnut {
                    var points = series.values.indices.map { varyColors ? accent($0, palette) : color }
                    for dPt in ser.elements where dPt.localName == "dPt" {
                        if let i = int(dPt.firstChild("idx")), points.indices.contains(i),
                           let c = fillColor(of: dPt.firstChild("spPr"), line: false, palette) {
                            points[i] = c
                        }
                    }
                    series.pointColors = points
                }
                chart.series.append(series)

                // Where it comes from, for editing.
                let tx = ser.firstChild("tx")
                let name: ChartSeriesSource.Name? = formula(tx).map { .reference($0) }
                    ?? tx?.firstChild("v").map { .text($0.text) }
                let (categoriesNode, valuesNode) = kind == .scatter
                    ? (ser.firstChild("xVal"), ser.firstChild("yVal")) : (ser.firstChild("cat"), ser.firstChild("val"))
                if let values = formula(valuesNode) {
                    sources.append(ChartSeriesSource(name: name, categories: formula(categoriesNode), values: values,
                                                     color: seriesColor(ser.firstChild("spPr"), line: kind == .line),
                                                     kind: kind))
                } else {
                    editable = false
                }
            }
        }
        if chart.series.isEmpty {
            chart.unsupported = unsupported ?? chart.unsupported ?? "Chart"
        }
        chart.showsDataLabels = labelsSeen.contains(true)

        // Titles and legend.
        let autoTitleDeleted = body.firstChild("autoTitleDeleted").map { !isFalse(val($0)) } ?? false
        if let title = body.firstChild("title") {
            // A title without text is Excel's automatic one.
            chart.title = reader.text(of: title.firstChild("tx"))
                ?? (chart.series.count == 1 ? chart.series[0].name : "Chart Title")
        } else if !autoTitleDeleted, chart.series.count == 1 {
            // Excel titles a one-series chart with the series' name.
            chart.title = chart.series[0].name
        }
        for axis in plot.elements where ["catAx", "dateAx", "valAx", "serAx"].contains(axis.localName) {
            guard let title = axis.firstChild("title"), let text = reader.text(of: title.firstChild("tx")) else { continue }
            // Secondary axes' titles aren't shown.
            let id = axis.firstChild("axId").map(val)
            if axis.localName == "valAx", chart.kind != .scatter, let primaryValueAxis, id != primaryValueAxis { continue }
            // A scatter's axes are both valAx: x is the one along the bottom.
            let position = axis.firstChild("axPos").map(val)
            let isCategory = axis.localName != "valAx" || (chart.kind == .scatter && (position == "b" || position == "t"))
            if isCategory {
                chart.categoryAxisTitle = chart.categoryAxisTitle ?? text
            } else {
                chart.valueAxisTitle = chart.valueAxisTitle ?? text
            }
        }
        if let legend = body.firstChild("legend") {
            switch legend.firstChild("legendPos").map(val) ?? "r" {
            case "t": chart.legend = .top
            case "b": chart.legend = .bottom
            case "l": chart.legend = .left
            default: chart.legend = .right
            }
        }

        guard editable, unsupported == nil, chart.unsupported == nil, let kind = chart.kind, !sources.isEmpty else {
            return reader.areasRead
        }
        let titleSetting: ChartSettings.Title
        if let title = body.firstChild("title") {
            titleSetting = title.firstChild("tx").flatMap { reader.text(of: $0) }.map { .text($0) } ?? .automatic
        } else {
            titleSetting = !autoTitleDeleted && sources.count == 1 ? .automatic : .none
        }
        // Series of the chart's kind say nothing more.
        let main = kind
        chart.settings = ChartSettings(
            kind: main, grouping: chart.grouping, title: titleSetting, legend: chart.legend,
            categoryAxisTitle: chart.categoryAxisTitle, valueAxisTitle: chart.valueAxisTitle,
            showsDataLabels: labelsSeen.count > 1 ? nil : chart.showsDataLabels,
            series: sources.enumerated().map { index, source in
                var s = source
                if s.kind == main { s.kind = nil }
                // The accent a series gets by its position anyway is no choice.
                if index < 6, s.color == .accent(index + 1) { s.color = nil }
                return s
            })
        return reader.areasRead
    }

    /// Whether data labels show values: nil when they don't say.
    private static func showsValues(_ labels: XMLNode?) -> Bool? {
        guard let labels else { return nil }
        if let delete = labels.firstChild("delete"), !isFalse(val(delete)) { return false }
        return labels.firstChild("showVal").map { !isFalse(val($0)) }
    }

    /// A reference's formula (`c:f`), without `=`.
    static func formula(_ node: XMLNode?) -> String? {
        guard let node else { return nil }
        for ref in node.elements where ["numRef", "strRef", "multiLvlStrRef"].contains(ref.localName) {
            if let f = ref.firstChild("f")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
                return f.hasPrefix("=") ? String(f.dropFirst()) : f
            }
        }
        return nil
    }

    /// A series' colour as set in its shape properties (a line's from its
    /// outline), if it's a plain theme accent or RGB colour.
    private static func seriesColor(_ spPr: XMLNode?, line: Bool) -> ChartSeriesSource.Color? {
        guard let spPr else { return nil }
        let fill = line ? spPr.firstChild("ln")?.firstChild("solidFill") : spPr.firstChild("solidFill")
        guard let color = fill?.elements.first else { return nil }
        switch color.localName {
        case "srgbClr": return RGBAColor(argbHex: color.attributes["val"] ?? "").map { .rgb($0) }
        case "schemeClr":
            let name = color.attributes["val"] ?? ""
            guard color.elements.isEmpty, name.hasPrefix("accent"), let n = Int(name.dropFirst(6)) else { return nil }
            return .accent(n)
        default: return nil
        }
    }

    /// Reads series through ChartReference, falling back to the values
    /// cached beside a reference it can't follow. One per chart read, so a
    /// reference several series share (their categories) is read once.
    private final class SeriesReader {
        let workbook: Workbook
        let visibleOnly: Bool
        private var numbersRead: [String: [Double?]?] = [:]
        private var labelsRead: [String: [String]?] = [:]
        /// Every block of cells read.
        private(set) var areasRead: [ChartRange] = []

        private func reference(_ formula: String) -> ChartReference {
            let ref = ChartReference(formula, in: workbook)
            areasRead += ref.areas ?? []
            return ref
        }

        init(workbook: Workbook, visibleOnly: Bool) {
            self.workbook = workbook
            self.visibleOnly = visibleOnly
        }

        private func followedNumbers(_ formula: String) -> [Double?]? {
            if let known = numbersRead[formula] { return known }
            let read = reference(formula).numbers(in: workbook, visibleOnly: visibleOnly)
            numbersRead[formula] = .some(read)
            return read
        }

        private func followedLabels(_ formula: String) -> [String]? {
            if let known = labelsRead[formula] { return known }
            let read = reference(formula).labels(in: workbook, visibleOnly: visibleOnly)
            labelsRead[formula] = .some(read)
            return read
        }

        func numbers(of node: XMLNode?) -> [Double?] {
            guard let node else { return [] }
            for ref in node.elements where ref.localName == "numRef" || ref.localName == "strRef" {
                if let f = XLSXCharts.formula(node), let values = followedNumbers(f) { return values }
                if let cache = ref.firstChild("numCache") ?? ref.firstChild("strCache") {
                    return XLSXCharts.cached(cache).map { $0.flatMap(Double.init) }
                }
            }
            if let literal = node.firstChild("numLit") { return XLSXCharts.cached(literal).map { $0.flatMap(Double.init) } }
            return []
        }

        func labels(of node: XMLNode?) -> [String] {
            guard let node else { return [] }
            for ref in node.elements where ["numRef", "strRef", "multiLvlStrRef"].contains(ref.localName) {
                if let f = XLSXCharts.formula(node), let values = followedLabels(f) { return values }
                if let cache = ref.firstChild("numCache") ?? ref.firstChild("strCache") {
                    let format = cache.firstChild("formatCode")?.text
                    return XLSXCharts.cached(cache).map { text in
                        guard let text else { return "" }
                        if let format, let n = Double(text) {
                            return NumberFormatEngine.displayString(for: .number(n), format: NumberFormat(code: format))
                        }
                        return text
                    }
                }
                if let cache = ref.firstChild("multiLvlStrCache"), let level = cache.elements.first(where: { $0.localName == "lvl" }) {
                    return XLSXCharts.cached(level).map { $0 ?? "" }
                }
            }
            for literal in node.elements where literal.localName == "strLit" || literal.localName == "numLit" {
                return XLSXCharts.cached(literal).map { $0 ?? "" }
            }
            return []
        }

        /// A series name or a title: a reference, or rich text.
        func text(of tx: XMLNode?) -> String? {
            guard let tx else { return nil }
            if let ref = tx.firstChild("strRef") {
                if let f = XLSXCharts.formula(tx), let text = reference(f).text(in: workbook) {
                    return text
                }
                if let cache = ref.firstChild("strCache") { return XLSXCharts.cached(cache).compactMap { $0 }.joined(separator: " ") }
            }
            if let v = tx.firstChild("v") { return v.text }
            if let rich = tx.firstChild("rich") {
                let paragraphs = rich.elements.filter { $0.localName == "p" }.map { p in
                    var text = ""
                    p.forEach { if $0.localName == "t" { text += $0.text } }
                    return text
                }
                let joined = paragraphs.joined(separator: "\n")
                return joined.isEmpty ? nil : joined
            }
            return nil
        }
    }

    /// `<c:pt idx="…"><c:v>…</c:v></c:pt>` points, by index. The count and
    /// indexes are only believed within reason: at most a sheet's rows,
    /// points past `ptCount` (when it's given) are left out, and a count
    /// far past the last point is cut back.
    static func cached(_ cache: XMLNode) -> [String?] {
        let limit = CellAddress.maxRows
        let declared = int(cache.firstChild("ptCount")).map { min(max(0, $0), limit) }
        var points: [(Int, String?)] = []
        var highest = -1
        for pt in cache.elements where pt.localName == "pt" {
            guard let i = Int(pt.attributes["idx"] ?? ""), i >= 0, i < (declared ?? limit) else { continue }
            points.append((i, pt.firstChild("v")?.text))
            highest = max(highest, i)
        }
        // A count far past the last point given only adds blanks: a few are
        // kept (trailing empty categories), not millions.
        let count = min(declared ?? (highest + 1), highest + 1 + 1024)
        var values = [String?](repeating: nil, count: max(0, count))
        for (i, v) in points where i < values.count { values[i] = v }
        return values
    }

    private static func isFalse(_ value: String) -> Bool { value == "0" || value == "false" }

    /// The chartex layouts, by `layoutId`.
    static let chartexNames: [String: String] = [
        "waterfall": "Waterfall chart", "treemap": "Treemap chart", "sunburst": "Sunburst chart",
        "funnel": "Funnel chart", "boxWhisker": "Box and whisker chart", "clusteredColumn": "Histogram",
        "paretoLine": "Pareto chart", "regionMap": "Map chart",
    ]

    // MARK: Colours

    /// Office's default accent colours (2013 and later).
    static let defaultAccents: [RGBAColor] = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47"]
        .compactMap { RGBAColor(argbHex: $0) }

    /// accent1…accent6 from the workbook's theme, with the theme's path.
    static func themeAccents(_ carried: CarriedParts) -> (String, [RGBAColor])? {
        for rel in carried.workbookRelationships where rel.type.hasSuffix("/theme") {
            guard case .part(let path) = rel.target, let data = carried.parts[path]?.data,
                  let root = try? XMLNode.parse(data) else { continue }
            var scheme: XMLNode?
            root.forEach { if scheme == nil, $0.localName == "clrScheme" { scheme = $0 } }
            guard let scheme else { continue }
            let accents = (1...6).compactMap { i in scheme.firstChild("accent\(i)").flatMap { color(in: $0, []) } }
            if accents.count == 6 { return (path, accents) }
        }
        return nil
    }

    /// The colour Excel gives series `index` by default: the accents, then
    /// darker and lighter shades of them.
    static func accent(_ index: Int, _ palette: [RGBAColor]) -> RGBAColor {
        guard !palette.isEmpty else { return RGBAColor(red: 0x44, green: 0x72, blue: 0xC4) }
        let index = max(0, index)
        let base = palette[index % palette.count]
        let round = index / palette.count
        guard round > 0 else { return base }
        // Rounds alternate darker (60%) and lighter (80% tint).
        return round % 2 == 1 ? scaled(base, by: 0.6) : tinted(base, by: 0.4)
    }

    private static func fillColor(of spPr: XMLNode?, line: Bool, _ palette: [RGBAColor]) -> RGBAColor? {
        guard let spPr else { return nil }
        let first = line ? spPr.firstChild("ln")?.firstChild("solidFill") ?? spPr.firstChild("solidFill")
            : spPr.firstChild("solidFill") ?? spPr.firstChild("ln")?.firstChild("solidFill")
        return first.flatMap { color(in: $0, palette) }
    }

    /// The first colour element in `node` (srgbClr, schemeClr, sysClr), with
    /// its luminance modifiers applied.
    private static func color(in node: XMLNode, _ palette: [RGBAColor]) -> RGBAColor? {
        for child in node.elements {
            var base: RGBAColor?
            switch child.localName {
            case "srgbClr": base = RGBAColor(argbHex: child.attributes["val"] ?? "")
            case "sysClr": base = RGBAColor(argbHex: child.attributes["lastClr"] ?? "")
            case "schemeClr":
                let name = child.attributes["val"] ?? ""
                if name.hasPrefix("accent"), let i = Int(name.dropFirst(6)), (1...6).contains(i), !palette.isEmpty {
                    base = palette[(i - 1) % palette.count]
                } else if name == "tx1" || name == "dk1" {
                    base = RGBAColor(red: 0, green: 0, blue: 0)
                } else if name == "bg1" || name == "lt1" {
                    base = RGBAColor(red: 255, green: 255, blue: 255)
                }
            default: continue
            }
            guard var color = base else { continue }
            let mod = child.firstChild("lumMod").flatMap { Double($0.attributes["val"] ?? "") }.map { $0 / 100_000 }
            let off = child.firstChild("lumOff").flatMap { Double($0.attributes["val"] ?? "") }.map { $0 / 100_000 }
            if let mod { color = scaled(color, by: mod) }
            if let off { color = tinted(color, by: off) }
            if let shade = child.firstChild("shade").flatMap({ Double($0.attributes["val"] ?? "") }) {
                color = scaled(color, by: shade / 100_000)
            }
            if let tint = child.firstChild("tint").flatMap({ Double($0.attributes["val"] ?? "") }) {
                color = tinted(color, by: 1 - tint / 100_000)
            }
            return color
        }
        return nil
    }

    private static func scaled(_ c: RGBAColor, by factor: Double) -> RGBAColor {
        func s(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * factor).rounded()))) }
        return RGBAColor(red: s(c.red), green: s(c.green), blue: s(c.blue), alpha: c.alpha)
    }

    /// Towards white by `amount` (0…1).
    private static func tinted(_ c: RGBAColor, by amount: Double) -> RGBAColor {
        func t(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) + (255 - Double(v)) * amount).rounded()))) }
        return RGBAColor(red: t(c.red), green: t(c.green), blue: t(c.blue), alpha: c.alpha)
    }

    // MARK: Helpers

    private static func val(_ node: XMLNode) -> String { node.attributes["val"] ?? "" }

    static func int(_ node: XMLNode?) -> Int? {
        guard let node else { return nil }
        return Int(node.attributes["val"] ?? node.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func formatNumber(_ n: Double) -> String {
        NumberFormatEngine.displayString(for: .number(n), format: NumberFormat.general)
    }
}

private extension XMLNode {
    /// The namespace a node's prefix is declared with on `self` (the root).
    func namespaceURI(of node: XMLNode) -> String {
        let prefix = XMLRewriter.prefix(of: node.name)
        return attributes[prefix.isEmpty ? "xmlns" : "xmlns:" + prefix] ?? ""
    }
}
