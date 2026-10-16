import Charts
import CoreGraphics
import ImageIO
import SpreadsheetCore
import SpreadsheetFiles
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Charts drawn on the grid. Each chart is drawn with Swift Charts into an
// image, and the grid renderer draws that image where the chart is
// anchored, above the cells (so it scrolls, freezes and prints with them).
//
// Drawing a chart is never done inside the grid's draw: a chart without an
// image of its current look shows its last image (or a plain box) while one
// is made, one per run-loop turn, and the grid redraws when it's ready.
// Swift Charts only ever sees a bounded number of points (reduced to the
// plot's width), and images are kept to a pixel and memory budget, keyed by
// the chart's fingerprint (what it shows) rather than its data.

/// Draws a sheet's charts and keeps their images, for one grid.
@MainActor
final class SheetChartLayer {
    /// Make images while drawing (tests and offscreen renders). Otherwise
    /// they're made after the draw, and `onImageReady` asks for a redraw.
    var rendersSynchronously = false
    var onImageReady: (() -> Void)?

    private struct ImageKey: Hashable {
        var id: String
        var fingerprint: Int
        var width: Int
        var height: Int
        var scale: CGFloat
        var dark: Bool
    }

    /// One image per chart, the latest asked for.
    private var images: [String: (key: ImageKey, image: CGImage)] = [:]
    /// Charts by id, most recently drawn last (evicted first-first).
    private var recency: [String] = []
    private var queue: [(key: ImageKey, chart: SheetChart)] = []
    private var isScheduled = false

    /// The most pixels one chart's image has (beyond that it's drawn
    /// scaled up): 8 megapixels, 32 MB.
    static let maxPixels = 8_000_000.0
    /// What all the images may hold together.
    static let maxBytes = 256 * 1024 * 1024

    /// Where a chart sits, in unshifted view coordinates.
    static func frame(of chart: SheetChart, in geometry: GridGeometry) -> CGRect {
        SpreadsheetDocument.contentFrame(of: chart, in: geometry.layout)
            .offsetBy(dx: geometry.contentOrigin.x, dy: geometry.contentOrigin.y)
    }

    /// The image to draw for a chart at `size` points: the current one, or
    /// the last one while the current one is made (nil: none yet).
    func image(of chart: SheetChart, size: CGSize, scale: CGFloat, dark: Bool) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width >= 8, height >= 8 else { return nil }
        // Within the pixel budget; Core Graphics scales it up beyond.
        let budget = (Self.maxPixels / Double(width * height)).squareRoot()
        let effective = max(0.25, min(scale, CGFloat(budget)))
        let key = ImageKey(id: chart.id, fingerprint: chart.fingerprint, width: width, height: height,
                           scale: (effective * 4).rounded(.down) / 4, dark: dark)
        touch(chart.id)
        if let current = images[chart.id], current.key == key { return current.image }
        if rendersSynchronously {
            render(chart, key)
            return images[chart.id]?.image
        }
        if !queue.contains(where: { $0.key == key }) {
            queue.removeAll { $0.key.id == chart.id }
            queue.append((key, chart))
            schedule()
        }
        return images[chart.id]?.image
    }

    /// Images waiting to be made.
    var isRendering: Bool { !queue.isEmpty }

    private func schedule() {
        guard !isScheduled, !queue.isEmpty else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScheduled = false
                guard !self.queue.isEmpty else { return }
                let next = self.queue.removeFirst()
                self.render(next.chart, next.key)
                self.onImageReady?()
                self.schedule()
            }
        }
    }

    private func render(_ chart: SheetChart, _ key: ImageKey) {
        let view = SheetChartView(chart: chart, width: CGFloat(key.width))
            .frame(width: CGFloat(key.width), height: CGFloat(key.height))
            .environment(\.colorScheme, key.dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = key.scale
        guard let image = renderer.cgImage else { return }
        images[chart.id] = (key, image)
        evict()
    }

    private func touch(_ id: String) {
        if recency.last != id {
            recency.removeAll { $0 == id }
            recency.append(id)
        }
    }

    /// Least recently drawn charts' images go once the budget is passed.
    private func evict() {
        func size(_ image: CGImage) -> Int { image.bytesPerRow * image.height }
        var total = images.values.reduce(0) { $0 + size($1.image) }
        while total > Self.maxBytes, images.count > 1, let oldest = recency.first(where: { images[$0] != nil }) {
            total -= images[oldest].map { size($0.image) } ?? 0
            images[oldest] = nil
            recency.removeAll { $0 == oldest }
        }
    }

    /// Draw the charts that cross `visible` (unshifted view coordinates).
    /// `moving`: a chart being dragged, and its frame for now (view
    /// coordinates). `selected`: the selected chart's id.
    func draw(_ charts: [SheetChart], geometry: GridGeometry, visible: CGRect, moving: (id: String, frame: CGRect)?,
              selected: String?, grips: Bool, in ctx: CGContext) {
        guard !charts.isEmpty else { return }
        let device = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, (abs(device.a) * 2).rounded() / 2)
        let dark = Self.isDarkAppearance
        for chart in charts {
            let placed = Self.frame(of: chart, in: geometry).integral
            let frame = moving?.id == chart.id ? moving!.frame.integral : placed
            guard frame.intersects(visible.insetBy(dx: -12, dy: -12)) else { continue }
            if let image = image(of: chart, size: placed.size, scale: scale, dark: dark) {
                // The context is flipped (y down); images draw y up.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: frame.maxY + frame.minY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: frame)
                ctx.restoreGState()
            } else {
                // Not drawn yet: its box, so the space reads as a chart.
                ctx.saveGState()
                ctx.setFillColor(dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 1, alpha: 1))
                ctx.fill(frame)
                ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.45))
                ctx.setLineWidth(0.5)
                ctx.stroke(frame.insetBy(dx: 0.25, dy: 0.25))
                ctx.restoreGState()
            }
            if chart.id == selected { drawSelection(frame, grips: grips, resizable: !chart.isGrouped, in: ctx) }
        }
    }

    /// The handles a selected chart is resized by, in view coordinates.
    static func handles(of frame: CGRect) -> [(ChartHandle, CGPoint)] {
        ChartHandle.allCases.map { handle in
            (handle, CGPoint(x: frame.minX + frame.width * handle.unit.x, y: frame.minY + frame.height * handle.unit.y))
        }
    }

    private func drawSelection(_ frame: CGRect, grips: Bool, resizable: Bool, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(SystemColors.accent.cgColor)
        ctx.setLineWidth(1.5)
        // A chart in a group moves with the group: an outline, no handles.
        if !resizable { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        ctx.stroke(frame.insetBy(dx: -0.75, dy: -0.75))
        if resizable {
            ctx.setLineDash(phase: 0, lengths: [])
            for (_, point) in Self.handles(of: frame) {
                let size: CGFloat = grips ? 12 : 7
                let box = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                ctx.setFillColor(PlatformColor.white.cgColor)
                ctx.setLineWidth(1)
                if grips {
                    ctx.fillEllipse(in: box)
                    ctx.strokeEllipse(in: box)
                } else {
                    ctx.fill(box)
                    ctx.stroke(box)
                }
            }
        }
        ctx.restoreGState()
    }

    private static var isDarkAppearance: Bool {
        #if os(macOS)
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        UITraitCollection.current.userInterfaceStyle == .dark
        #endif
    }
}

/// A selected chart's resize handles: corners and edge midpoints.
enum ChartHandle: CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Where on the frame, as fractions of its width and height.
    var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        }
    }

    /// `frame` with this handle dragged by `delta`, no smaller than a
    /// usable chart.
    func resize(_ frame: CGRect, by delta: CGSize) -> CGRect {
        let minimum = CGSize(width: 60, height: 40)
        var minX = frame.minX, minY = frame.minY, maxX = frame.maxX, maxY = frame.maxY
        if unit.x == 0 { minX = min(frame.minX + delta.width, maxX - minimum.width) }
        if unit.x == 1 { maxX = max(frame.maxX + delta.width, minX + minimum.width) }
        if unit.y == 0 { minY = min(frame.minY + delta.height, maxY - minimum.height) }
        if unit.y == 1 { maxY = max(frame.maxY + delta.height, minY + minimum.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension SpreadsheetDocument {
    /// Copy a chart as a picture (at up to twice its size, light, within
    /// the pixel budget), for pasting into other apps.
    public func copyChartToPasteboard(_ chart: SheetChart) {
        let frame = Self.contentFrame(of: chart, in: GridLayout(sheet: activeSheet))
        let width = min(max(60, frame.width), 4000), height = min(max(40, frame.height), 4000)
        let view = SheetChartView(chart: chart, width: width)
            .frame(width: width, height: height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = min(2, CGFloat((SheetChartLayer.maxPixels / Double(width * height)).squareRoot()))
        guard let image = renderer.cgImage, let png = Self.png(image) else { return }
        SystemPasteboard.write(png: png)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// One chart, drawn with Swift Charts. Categories are plotted by position
/// (labels looked up for the axis), and series are first reduced to what
/// the plot's width can show.
struct SheetChartView: View {
    let chart: SheetChart
    private let plotted: PlottedChart
    @Environment(\.colorScheme) private var colorScheme

    /// `width`: the chart's width in points, which bounds the points drawn.
    init(chart: SheetChart, width: CGFloat) {
        self.chart = chart
        plotted = PlottedChart(chart, width: width)
    }

    var body: some View {
        VStack(spacing: 4) {
            if let title = chart.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if let unsupported = chart.unsupported {
                Spacer(minLength: 0)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text("\(unsupported) — not shown in SimpleSpread")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                plot
                    .font(.system(size: 10))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(white: 0.13) : Color.white)
        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 0.5))
    }

    // MARK: Plot

    @ViewBuilder
    private var plot: some View {
        switch chart.kind {
        case .pie, .doughnut:
            pie
        default:
            let content = Chart {
                ForEach(plotted.series) { s in
                    marks(for: s)
                }
            }
            .chartForegroundStyleScale(domain: plotted.series.map(\.name), range: plotted.series.map { Color(rgba: $0.color) })
            .chartLegend(chart.legend == nil ? .hidden : .visible)
            .chartLegend(position: legendPosition, alignment: .center)
            axes(content)
        }
    }

    @ViewBuilder
    private func axes(_ content: some View) -> some View {
        let p = plotted
        switch chart.kind {
        case .bar:
            // Bars run across; Excel lists the first category at the bottom.
            content
                .chartYScale(domain: Array(p.categoryKeys.reversed()))
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading, values: p.labelKeys) { value in
                        AxisValueLabel(centered: true) { Text(p.label(forKey: value.as(String.self))) }
                    }
                }
                .chartXAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel() } }
                .chartXAxisLabel(position: .bottom, alignment: .center) { axisTitle(chart.valueAxisTitle) }
                .chartYAxisLabel(position: .leading, alignment: .center) { axisTitle(chart.categoryAxisTitle) }
        case .column:
            valueAxes(content
                .chartXScale(domain: p.categoryKeys)
                .chartXAxis {
                    AxisMarks(values: p.labelKeys) { value in
                        AxisValueLabel { Text(p.label(forKey: value.as(String.self))) }
                    }
                })
        case .scatter:
            valueAxes(content.chartXAxis { AxisMarks { _ in AxisTick(); AxisValueLabel() } })
        default:
            // Lines and areas: plotted by position, labelled with the categories.
            valueAxes(content
                .chartXScale(domain: 0...Double(max(1, p.count - 1)))
                .chartXAxis {
                    AxisMarks(values: p.labelPositions) { value in
                        AxisValueLabel { Text(p.label(at: value.as(Double.self))) }
                    }
                })
        }
    }

    /// The value axis on the left (with a secondary one on the right).
    @ViewBuilder
    private func valueAxes(_ content: some View) -> some View {
        let titled = content
            .chartXAxisLabel(position: .bottom, alignment: .center) { axisTitle(chart.categoryAxisTitle) }
            .chartYAxisLabel(position: .leading, alignment: .center) { axisTitle(chart.valueAxisTitle) }
        if let secondary = plotted.secondary {
            titled
                .chartYScale(domain: secondary.primaryDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: secondary.primaryTicks) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                    AxisMarks(position: .trailing, values: secondary.mappedTicks) { value in
                        AxisValueLabel { Text(secondary.label(atPrimary: value.as(Double.self))) }
                    }
                }
        } else {
            titled.chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel() } }
        }
    }

    @ViewBuilder
    private func axisTitle(_ text: String?) -> some View {
        if let text { Text(text) }
    }

    private var legendPosition: AnnotationPosition {
        switch chart.legend {
        case .top: .top
        case .left: .leading
        case .right: .trailing
        case .bottom, nil: .bottom
        }
    }

    private var stacking: MarkStackingMethod {
        switch chart.grouping {
        case .standard: chart.kind == .area ? .unstacked : .standard
        case .stacked: .standard
        case .percentStacked: .normalized
        }
    }

    @ChartContentBuilder
    private func marks(for s: PlottedChart.Series) -> some ChartContent {
        let clustered = chart.grouping == .standard
        ForEach(s.points) { p in
            switch s.kind {
            case .column, .pie, .doughnut:
                if clustered {
                    BarMark(x: .value("Category", p.key), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", s.name))
                        .position(by: .value("Series", s.name))
                        .annotation(position: .top) { dataLabel(p.shown, s.showsLabels) }
                } else {
                    BarMark(x: .value("Category", p.key), y: .value("Value", p.value), width: .ratio(0.6),
                            stacking: stacking)
                        .foregroundStyle(by: .value("Series", s.name))
                }
            case .bar:
                if clustered {
                    BarMark(x: .value("Value", p.value), y: .value("Category", p.key))
                        .foregroundStyle(by: .value("Series", s.name))
                        .position(by: .value("Series", s.name))
                        .annotation(position: .trailing) { dataLabel(p.shown, s.showsLabels) }
                } else {
                    BarMark(x: .value("Value", p.value), y: .value("Category", p.key), height: .ratio(0.6),
                            stacking: stacking)
                        .foregroundStyle(by: .value("Series", s.name))
                }
            case .line:
                LineMark(x: .value("Position", p.x), y: .value("Value", p.value))
                    .foregroundStyle(by: .value("Series", s.name))
                    .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                if s.showsMarkers || s.showsLabels {
                    PointMark(x: .value("Position", p.x), y: .value("Value", p.value))
                        .foregroundStyle(by: .value("Series", s.name))
                        .symbolSize(s.showsMarkers ? 24 : 0)
                        .annotation(position: .top) { dataLabel(p.shown, s.showsLabels) }
                }
            case .area:
                AreaMark(x: .value("Position", p.x), y: .value("Value", p.value), stacking: stacking)
                    .foregroundStyle(by: .value("Series", s.name))
                    .opacity(chart.grouping == .standard ? 0.75 : 1)
            case .scatter:
                if s.showsLine {
                    LineMark(x: .value("X", p.x), y: .value("Y", p.value))
                        .foregroundStyle(by: .value("Series", s.name))
                }
                if s.showsMarkers {
                    PointMark(x: .value("X", p.x), y: .value("Y", p.value))
                        .foregroundStyle(by: .value("Series", s.name))
                        .symbolSize(28)
                        .annotation(position: .top) { dataLabel(p.shown, s.showsLabels) }
                }
            }
        }
    }

    @ViewBuilder
    private func dataLabel(_ value: Double, _ shown: Bool) -> some View {
        if shown {
            Text(value.formatted(.number.precision(.fractionLength(0...2))))
                .font(.system(size: 9))
        }
    }

    @ViewBuilder
    private var pie: some View {
        if let s = plotted.series.first {
            let points = s.points.filter { $0.value > 0 }
            Chart(points) { p in
                SectorMark(angle: .value("Value", p.value),
                           innerRadius: chart.kind == .doughnut ? .ratio(0.5) : .ratio(0),
                           angularInset: 0.75)
                    .foregroundStyle(by: .value("Category", p.label))
                    .annotation(position: .overlay) {
                        if s.showsLabels { dataLabel(p.value, true).foregroundStyle(.white) }
                    }
            }
            .chartForegroundStyleScale(domain: points.map(\.label), range: points.map { Color(rgba: $0.color) })
            .chartLegend(chart.legend == nil ? .hidden : .visible)
            .chartLegend(position: legendPosition, alignment: .center)
        }
    }
}

/// A chart as Swift Charts takes it: at most what its width can show,
/// categories keyed by position (equal labels don't merge, and nothing is
/// padded to tell them apart), names made distinct where they repeat, and
/// series on a secondary axis mapped onto the primary scale.
struct PlottedChart {
    struct Point: Identifiable {
        let id: Int
        /// Categorical key: the position as text.
        let key: String
        /// Position (lines, areas) or x value (scatter).
        let x: Double
        /// As plotted (mapped, for a secondary series).
        let value: Double
        /// As in the cells (data labels).
        let shown: Double
        let label: String
        let color: RGBAColor
    }

    struct Series: Identifiable {
        let id: Int
        let name: String
        let kind: SheetChart.Kind
        let color: RGBAColor
        let showsMarkers: Bool
        let showsLine: Bool
        let showsLabels: Bool
        let points: [Point]
    }

    /// A secondary value axis: its values are drawn on the primary scale.
    struct Secondary {
        let primaryDomain: ClosedRange<Double>
        let primaryTicks: [Double]
        let secondaryDomain: ClosedRange<Double>
        var mappedTicks: [Double] = []

        func map(_ v: Double) -> Double {
            let s = secondaryDomain, p = primaryDomain
            guard s.upperBound > s.lowerBound else { return p.lowerBound }
            return p.lowerBound + (v - s.lowerBound) / (s.upperBound - s.lowerBound) * (p.upperBound - p.lowerBound)
        }

        func label(atPrimary value: Double?) -> String {
            guard let value else { return "" }
            let s = secondaryDomain, p = primaryDomain
            guard p.upperBound > p.lowerBound else { return "" }
            let v = s.lowerBound + (value - p.lowerBound) / (p.upperBound - p.lowerBound) * (s.upperBound - s.lowerBound)
            return v.formatted(.number.precision(.significantDigits(1...4)))
        }
    }

    let series: [Series]
    /// Category labels by position.
    let labels: [String]
    var count: Int { labels.count }
    let categoryKeys: [String]
    /// The categories labelled on the axis (as many as fit).
    let labelKeys: [String]
    let labelPositions: [Double]
    let secondary: Secondary?

    init(_ source: SheetChart, width: CGFloat) {
        // As many points as the plot has room for.
        let budget: Int
        switch source.kind {
        case .column?, .bar?: budget = max(8, Int(width / 3))
        case .pie?, .doughnut?: budget = 60
        default: budget = max(16, Int(width * 2))
        }
        let chart = source.reduced(toPoints: budget)
        let longest = chart.series.max { $0.categories.count < $1.categories.count }?.categories ?? []
        let count = max(longest.count, chart.series.map(\.values.count).max() ?? 0)
        labels = longest + (longest.count..<count).map { String($0 + 1) }
        categoryKeys = (0..<count).map(String.init)
        let shownLabels = max(2, Int(width / 55))
        let step = max(1, Int((Double(count) / Double(shownLabels)).rounded(.up)))
        let positions = Array(stride(from: 0, to: count, by: step))
        labelKeys = positions.map(String.init)
        labelPositions = positions.map(Double.init)

        // A secondary axis (columns, lines, areas: not bars across, pies or scatters).
        var secondary: Secondary?
        if chart.hasSecondaryAxis, [.column, .line, .area].contains(chart.kind), chart.grouping != .percentStacked {
            func extent(_ list: [SheetChart.Series], stacked: Bool) -> (Double, Double) {
                var lo = 0.0, hi = 0.0
                if stacked {
                    for i in 0..<count {
                        var up = 0.0, down = 0.0
                        for s in list { let v = (i < s.values.count ? s.values[i] : nil) ?? 0; if v > 0 { up += v } else { down += v } }
                        hi = max(hi, up)
                        lo = min(lo, down)
                    }
                } else {
                    for s in list { for v in s.values.compactMap({ $0 }) { hi = max(hi, v); lo = min(lo, v) } }
                }
                return (lo, hi)
            }
            let primary = Self.nice(extent(chart.series.filter { !$0.secondary }, stacked: chart.grouping == .stacked))
            let other = Self.nice(extent(chart.series.filter { $0.secondary }, stacked: false))
            var made = Secondary(primaryDomain: primary.domain, primaryTicks: primary.ticks, secondaryDomain: other.domain)
            made.mappedTicks = other.ticks.map { made.map($0) }
            secondary = made
        }
        self.secondary = secondary

        var names: [String: Int] = [:]
        series = chart.series.enumerated().map { index, s in
            var name = s.name.isEmpty ? "Series \(index + 1)" : s.name
            let seen = names[name, default: 0]
            names[name] = seen + 1
            if seen > 0 { name += " (\(seen + 1))" }
            let points = s.values.enumerated().compactMap { i, value -> Point? in
                guard let value, value.isFinite else { return nil }
                let x = s.kind == .scatter ? (i < s.xValues.count ? s.xValues[i] : nil) : Double(i)
                guard let x, x.isFinite else { return nil }
                let plottedValue = s.secondary ? (secondary?.map(value) ?? value) : value
                let label = i < s.categories.count ? s.categories[i] : String(i + 1)
                let color = i < s.pointColors.count ? s.pointColors[i] : s.color
                return Point(id: i, key: String(i), x: x, value: plottedValue, shown: value, label: label, color: color)
            }
            return Series(id: index, name: name, kind: s.kind, color: s.color, showsMarkers: s.showsMarkers,
                          showsLine: s.showsLine, showsLabels: s.showsLabels, points: Self.distinctLabels(points))
        }
    }

    func label(forKey key: String?) -> String {
        guard let key, let i = Int(key), labels.indices.contains(i) else { return "" }
        return labels[i]
    }

    func label(at position: Double?) -> String {
        guard let position, position.isFinite else { return "" }
        let i = Int(position.rounded())
        return labels.indices.contains(i) ? labels[i] : ""
    }

    /// A pie's slices need distinct labels (they key its colours and legend):
    /// a repeat gets its number.
    private static func distinctLabels(_ points: [Point]) -> [Point] {
        var seen: [String: Int] = [:]
        return points.map { p in
            let n = seen[p.label, default: 0]
            seen[p.label] = n + 1
            guard n > 0 else { return p }
            return Point(id: p.id, key: p.key, x: p.x, value: p.value, shown: p.shown, label: "\(p.label) (\(n + 1))",
                         color: p.color)
        }
    }

    /// A scale that takes in `lo…hi` (and zero), with about five round steps.
    static func nice(_ extent: (Double, Double)) -> (domain: ClosedRange<Double>, ticks: [Double]) {
        var lo = min(0, extent.0), hi = max(0, extent.1)
        if hi <= lo { hi = lo + 1 }
        let raw = (hi - lo) / 5
        let magnitude = pow(10, log10(raw).rounded(.down))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        lo = (lo / step).rounded(.down) * step
        hi = (hi / step).rounded(.up) * step
        return (lo...hi, Array(stride(from: lo, through: hi + step / 2, by: step)))
    }
}

extension Color {
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: Double(rgba.red) / 255, green: Double(rgba.green) / 255, blue: Double(rgba.blue) / 255,
                  opacity: Double(rgba.alpha) / 255)
    }
}
