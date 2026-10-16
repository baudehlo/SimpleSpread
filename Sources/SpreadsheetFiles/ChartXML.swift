import Foundation
import SpreadsheetCore

// Chart XML (DrawingML charts) as Excel writes it for a new chart: its
// default style (grey axis lines and gridlines, 9 pt labels, a 14 pt title,
// a white chart area with a hairline border), so a chart made here looks
// like one made in Excel when Excel opens it. Elements are built as trees
// under the prefixes the target part uses, so they can go into charts
// written with `c:` (Excel) or a default namespace (openpyxl).

enum ChartNamespace {
    static let chart = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let drawingML = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let spreadsheetDrawing = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
}

/// Schema order of the children the editor touches, by parent (local names).
enum ChartSchema {
    static let chartSpace = ["date1904", "lang", "roundedCorners", "AlternateContent", "style", "clrMapOvr",
                             "pivotSource", "protection", "chart", "spPr", "txPr", "externalData", "printSettings",
                             "userShapes", "extLst"]
    static let chart = ["title", "autoTitleDeleted", "pivotFmts", "view3D", "floor", "sideWall", "backWall",
                        "plotArea", "legend", "plotVisOnly", "dispBlanksAs", "showDLblsOverMax", "extLst"]
    static let title = ["tx", "layout", "overlay", "spPr", "txPr", "extLst"]
    static let legend = ["legendPos", "legendEntry", "layout", "overlay", "spPr", "txPr", "extLst"]
    static let axis = ["axId", "scaling", "delete", "axPos", "majorGridlines", "minorGridlines", "title", "numFmt",
                       "majorTickMark", "minorTickMark", "tickLblPos", "spPr", "txPr", "crossAx", "crosses",
                       "crossesAt", "crossBetween", "auto", "lblAlgn", "lblOffset", "baseTimeUnit", "majorUnit",
                       "majorTimeUnit", "minorUnit", "minorTimeUnit", "tickLblSkip", "tickMarkSkip",
                       "noMultiLvlLbl", "dispUnits", "extLst"]
    static let series = ["idx", "order", "tx", "spPr", "invertIfNegative", "pictureOptions", "marker", "explosion",
                         "dPt", "dLbls", "trendline", "errBars", "cat", "val", "xVal", "yVal", "shape", "smooth",
                         "bubbleSize", "bubble3D", "extLst"]
    /// Group children (barChart, lineChart, …) after the series.
    static let group = ["barDir", "grouping", "scatterStyle", "varyColors", "ser", "dLbls", "dropLines",
                        "hiLowLines", "upDownBars", "gapWidth", "gapDepth", "overlap", "serLines", "marker",
                        "smooth", "firstSliceAng", "holeSize", "shape", "axId", "extLst"]
    static let dataLabels = ["dLbl", "delete", "numFmt", "spPr", "txPr", "dLblPos", "showLegendKey", "showVal",
                             "showCatName", "showSerName", "showPercent", "showBubbleSize", "separator",
                             "showLeaderLines", "leaderLines", "extLst"]
    static let plotArea = ["layout", "areaChart", "area3DChart", "lineChart", "line3DChart", "stockChart",
                           "radarChart", "scatterChart", "pieChart", "pie3DChart", "doughnutChart", "barChart",
                           "bar3DChart", "ofPieChart", "surfaceChart", "surface3DChart", "bubbleChart", "valAx",
                           "catAx", "dateAx", "serAx", "dTable", "spPr", "extLst"]
}

extension XMLNode {
    /// The child with local name `local`, replaced by `node` (or removed
    /// for nil), or `node` inserted where `order` puts it.
    func setChild(_ local: String, _ node: XMLNode?, order: [String]) {
        if let index = children.firstIndex(where: { if case .element(let e) = $0 { return e.localName == local }; return false }) {
            if let node { children[index] = .element(node) } else { children.remove(at: index) }
            return
        }
        guard let node else { return }
        insert(node, order: order)
    }

    /// Insert `node` after every child that comes before it in `order`.
    func insert(_ node: XMLNode, order: [String]) {
        let rank = order.firstIndex(of: node.localName) ?? order.count
        var at = 0
        for (i, child) in children.enumerated() {
            guard case .element(let e) = child else { continue }
            let r = order.firstIndex(of: e.localName) ?? order.count
            if r <= rank { at = i + 1 }
        }
        children.insert(.element(node), at: at)
    }

    func children(_ local: String) -> [XMLNode] { elements.filter { $0.localName == local } }

    /// The prefix (with its colon) this element's name uses.
    var prefix: String {
        let p = XMLRewriter.prefix(of: name)
        return p.isEmpty ? "" : p + ":"
    }
}

/// Builds chart elements under given prefixes.
struct ChartXML {
    /// "c:" or "" (a default namespace).
    let c: String
    let a: String

    init(c: String = "c:", a: String = "a:") {
        self.c = c
        self.a = a
    }

    /// The builder for a chart part's root: its prefixes, declaring the
    /// DrawingML one on the root when the part has none.
    init(root: XMLNode) {
        c = root.prefix
        if let declared = root.attributes.first(where: { $0.key.hasPrefix("xmlns:") && $0.value == ChartNamespace.drawingML }) {
            a = String(declared.key.dropFirst(6)) + ":"
        } else {
            root.attributes["xmlns:a"] = ChartNamespace.drawingML
            a = "a:"
        }
    }

    func C(_ local: String, _ attributes: [String: String] = [:], _ children: [XMLNode] = []) -> XMLNode {
        XMLNode(name: c + local, attributes: attributes, children: children.map { .element($0) })
    }

    func A(_ local: String, _ attributes: [String: String] = [:], _ children: [XMLNode] = []) -> XMLNode {
        XMLNode(name: a + local, attributes: attributes, children: children.map { .element($0) })
    }

    func val(_ local: String, _ value: String) -> XMLNode { C(local, ["val": value]) }

    func text(_ name: String, _ text: String) -> XMLNode {
        XMLNode(name: name, children: [.text(text)])
    }

    // MARK: Shape and text properties

    /// Excel's grey for lines: tx1 at 15%.
    func lightLine(width: Int = 9525) -> XMLNode {
        A("ln", ["w": String(width), "cap": "flat", "cmpd": "sng", "algn": "ctr"], [
            A("solidFill", [:], [A("schemeClr", ["val": "tx1"], [A("lumMod", ["val": "15000"]), A("lumOff", ["val": "85000"])])]),
            A("round"),
        ])
    }

    func noFillShape() -> XMLNode {
        C("spPr", [:], [A("noFill"), A("ln", [:], [A("noFill")]), A("effectLst")])
    }

    /// Text at `size` (hundredths of a point) in Excel's dark grey.
    func textProperties(size: Int, rotation: String = "-60000000") -> XMLNode {
        C("txPr", [:], [
            A("bodyPr", ["rot": rotation, "spcFirstLastPara": "1", "vertOverflow": "ellipsis", "vert": "horz",
                         "wrap": "square", "anchor": "ctr", "anchorCtr": "1"]),
            A("lstStyle"),
            A("p", [:], [A("pPr", [:], [defaultRun(size: size)]), A("endParaRPr", ["lang": "en-US"])]),
        ])
    }

    func defaultRun(size: Int) -> XMLNode {
        A("defRPr", ["sz": String(size), "b": "0", "i": "0", "u": "none", "strike": "noStrike", "kern": "1200",
                     "baseline": "0"], [
            A("solidFill", [:], [A("schemeClr", ["val": "tx1"], [A("lumMod", ["val": "65000"]), A("lumOff", ["val": "35000"])])]),
            A("latin", ["typeface": "+mn-lt"]), A("ea", ["typeface": "+mn-ea"]), A("cs", ["typeface": "+mn-cs"]),
        ])
    }

    /// `<c:tx><c:rich>` holding `text`.
    func richText(_ text: String, size: Int, rotation: String? = nil) -> XMLNode {
        var body: [String: String] = ["spcFirstLastPara": "1", "vertOverflow": "ellipsis", "vert": "horz",
                                      "wrap": "square", "anchor": "ctr", "anchorCtr": "1"]
        body["rot"] = rotation ?? "0"
        let paragraphs = text.components(separatedBy: "\n").map { line in
            A("p", [:], [A("pPr", [:], [defaultRun(size: size)]),
                         A("r", [:], [A("rPr", ["lang": "en-US"]), self.text(a + "t", line)])])
        }
        return C("tx", [:], [C("rich", [:], [A("bodyPr", body), A("lstStyle")] + paragraphs)])
    }

    // MARK: Titles and legend

    /// A chart title: `text`, or Excel's automatic one for nil.
    func chartTitle(_ text: String?) -> XMLNode {
        var children: [XMLNode] = []
        if let text { children.append(richText(text, size: 1400)) }
        children += [val("overlay", "0"), noFillShape(), textProperties(size: 1400, rotation: "0")]
        return C("title", [:], children)
    }

    /// An axis title; a vertical axis's reads bottom to top.
    func axisTitle(_ text: String, vertical: Bool) -> XMLNode {
        let rotation = vertical ? "-5400000" : "0"
        return C("title", [:], [richText(text, size: 1000, rotation: rotation), val("overlay", "0"), noFillShape(),
                                textProperties(size: 1000, rotation: rotation)])
    }

    func legend(_ position: SheetChart.LegendPosition) -> XMLNode {
        C("legend", [:], [val("legendPos", Self.legendCode(position)), val("overlay", "0"), noFillShape(),
                          textProperties(size: 900, rotation: "0")])
    }

    static func legendCode(_ position: SheetChart.LegendPosition) -> String {
        switch position {
        case .top: "t"
        case .bottom: "b"
        case .left: "l"
        case .right: "r"
        }
    }

    // MARK: Series

    func fill(_ color: ChartSeriesSource.Color?, index: Int) -> XMLNode {
        A("solidFill", [:], [colorElement(color, index: index)])
    }

    func colorElement(_ color: ChartSeriesSource.Color?, index: Int) -> XMLNode {
        switch color {
        case .rgb(let rgb)?:
            return A("srgbClr", ["val": String(format: "%02X%02X%02X", rgb.red, rgb.green, rgb.blue)])
        case .accent(let n)?:
            return A("schemeClr", ["val": "accent\(min(max(n, 1), 6))"])
        case nil:
            // The theme's accents in turn, then darker shades of them.
            let accent = A("schemeClr", ["val": "accent\(index % 6 + 1)"])
            if index >= 6 { accent.children.append(.element(A("lumMod", ["val": "60000"]))) }
            return accent
        }
    }

    /// The shape properties Excel gives a series of `kind`.
    func seriesShape(_ kind: SheetChart.Kind, color: ChartSeriesSource.Color?, index: Int) -> XMLNode {
        switch kind {
        case .line:
            return C("spPr", [:], [A("ln", ["w": "28575", "cap": "rnd"], [fill(color, index: index), A("round")]),
                                   A("effectLst")])
        case .scatter:
            return C("spPr", [:], [A("ln", ["w": "25400", "cap": "rnd"], [A("noFill"), A("round")]), A("effectLst")])
        default:
            return C("spPr", [:], [fill(color, index: index), A("ln", [:], [A("noFill")]), A("effectLst")])
        }
    }

    func marker(color: ChartSeriesSource.Color?, index: Int) -> XMLNode {
        C("marker", [:], [val("symbol", "circle"), val("size", "5"), C("spPr", [:], [
            fill(color, index: index), A("ln", ["w": "9525"], [fill(color, index: index)]), A("effectLst"),
        ])])
    }

    /// A pie slice's colour, with Excel's white edge.
    func dataPoint(_ index: Int, color: ChartSeriesSource.Color?) -> XMLNode {
        C("dPt", [:], [val("idx", String(index)), val("bubble3D", "0"), C("spPr", [:], [
            fill(color, index: index),
            A("ln", ["w": "19050"], [A("solidFill", [:], [A("schemeClr", ["val": "lt1"])])]),
            A("effectLst"),
        ])])
    }

    /// A series element for `kind`, its references with their current values.
    func series(_ kind: SheetChart.Kind, _ source: ChartSeriesSource, index: Int, cache: ChartCache) -> XMLNode {
        var children = [val("idx", String(index)), val("order", String(index))]
        switch source.name {
        case .reference(let f)?:
            children.append(C("tx", [:], [C("strRef", [:], [text(c + "f", f), cache.strings(f, self, single: true)])]))
        case .text(let t)?:
            children.append(C("tx", [:], [text(c + "v", t)]))
        case nil:
            break
        }
        children.append(seriesShape(kind, color: source.color, index: index))
        switch kind {
        case .column, .bar: children.append(val("invertIfNegative", "0"))
        case .line: children.append(C("marker", [:], [val("symbol", "none")]))
        case .scatter: children.append(marker(color: source.color, index: index))
        default: break
        }
        if kind == .pie || kind == .doughnut {
            let count = cache.count(source.values)
            for i in 0..<count { children.append(dataPoint(i, color: nil)) }
        }
        let (categoriesName, valuesName) = kind == .scatter ? ("xVal", "yVal") : ("cat", "val")
        if let categories = source.categories {
            children.append(C(categoriesName, [:], [cache.reference(categories, self)]))
        }
        children.append(C(valuesName, [:], [C("numRef", [:], [text(c + "f", source.values), cache.numbers(source.values, self)])]))
        if kind == .line || kind == .scatter { children.append(val("smooth", "0")) }
        return C("ser", [:], children)
    }

    // MARK: Groups and axes

    func dataLabels(_ shown: Bool, pie: Bool) -> XMLNode {
        var children = [val("showLegendKey", "0"), val("showVal", shown ? "1" : "0"), val("showCatName", "0"),
                        val("showSerName", "0"), val("showPercent", "0"), val("showBubbleSize", "0")]
        // Positions are left to Excel's default for the kind (the allowed
        // ones differ by kind and stacking).
        if shown { children.insert(contentsOf: [noFillShape(), textProperties(size: 900, rotation: "0")], at: 0) }
        if pie { children.append(val("showLeaderLines", "1")) }
        return C("dLbls", [:], children)
    }

    /// The group element (barChart, lineChart, …) for series of one kind.
    func group(_ kind: SheetChart.Kind, grouping: SheetChart.Grouping, series: [XMLNode], dataLabels shown: Bool,
               axisIDs: [String]) -> XMLNode {
        let groupingCode: String
        switch grouping {
        case .standard: groupingCode = kind == .column || kind == .bar ? "clustered" : "standard"
        case .stacked: groupingCode = "stacked"
        case .percentStacked: groupingCode = "percentStacked"
        }
        var children: [XMLNode]
        switch kind {
        case .column, .bar:
            children = [val("barDir", kind == .bar ? "bar" : "col"), val("grouping", groupingCode), val("varyColors", "0")]
                + series + [dataLabels(shown, pie: false), val("gapWidth", grouping == .standard ? "219" : "150")]
            if grouping != .standard { children.append(val("overlap", "100")) } else { children.append(val("overlap", "-27")) }
        case .line:
            children = [val("grouping", groupingCode), val("varyColors", "0")] + series
                + [dataLabels(shown, pie: false), val("marker", "1"), val("smooth", "0")]
        case .area:
            children = [val("grouping", groupingCode), val("varyColors", "0")] + series + [dataLabels(shown, pie: false)]
        case .scatter:
            children = [val("scatterStyle", "lineMarker"), val("varyColors", "0")] + series + [dataLabels(shown, pie: false)]
        case .pie:
            children = [val("varyColors", "1")] + series + [dataLabels(shown, pie: true), val("firstSliceAng", "0")]
        case .doughnut:
            children = [val("varyColors", "1")] + series + [dataLabels(shown, pie: true), val("firstSliceAng", "0"),
                                                            val("holeSize", "75")]
        }
        children += axisIDs.map { val("axId", $0) }
        return C(Self.groupName(kind), [:], children)
    }

    static func groupName(_ kind: SheetChart.Kind) -> String {
        switch kind {
        case .column, .bar: "barChart"
        case .line: "lineChart"
        case .area: "areaChart"
        case .pie: "pieChart"
        case .doughnut: "doughnutChart"
        case .scatter: "scatterChart"
        }
    }

    /// The two axes for `kind`: categories then values (a scatter's two
    /// value axes: x then y), with their titles.
    func axes(_ kind: SheetChart.Kind, ids: [String], categoryTitle: String?, valueTitle: String?) -> [XMLNode] {
        let horizontal = kind == .bar
        let categoryPosition = horizontal ? "l" : "b", valuePosition = horizontal ? "b" : "l"
        func common(_ id: String, _ position: String, gridlines: Bool, title: String?, vertical: Bool) -> [XMLNode] {
            var nodes = [val("axId", id), C("scaling", [:], [val("orientation", "minMax")]), val("delete", "0"),
                         val("axPos", position)]
            if gridlines { nodes.append(C("majorGridlines", [:], [C("spPr", [:], [lightLine(), A("effectLst")])])) }
            if let title { nodes.append(axisTitle(title, vertical: vertical)) }
            nodes.append(C("numFmt", ["formatCode": "General", "sourceLinked": "1"]))
            nodes += [val("majorTickMark", "none"), val("minorTickMark", "none"), val("tickLblPos", "nextTo")]
            return nodes
        }
        let lineShape = C("spPr", [:], [A("noFill"), lightLine(), A("effectLst")])
        if kind == .scatter {
            let x = C("valAx", [:], common(ids[0], "b", gridlines: true, title: categoryTitle, vertical: false)
                + [noFillShape(), textProperties(size: 900), val("crossAx", ids[1]), val("crosses", "autoZero"),
                   val("crossBetween", "midCat")])
            let y = C("valAx", [:], common(ids[1], "l", gridlines: true, title: valueTitle, vertical: true)
                + [noFillShape(), textProperties(size: 900), val("crossAx", ids[0]), val("crosses", "autoZero"),
                   val("crossBetween", "midCat")])
            return [x, y]
        }
        let category = C("catAx", [:], common(ids[0], categoryPosition, gridlines: false, title: categoryTitle,
                                              vertical: horizontal)
            + [lineShape, textProperties(size: 900), val("crossAx", ids[1]), val("crosses", "autoZero"),
               val("auto", "1"), val("lblAlgn", "ctr"), val("lblOffset", "100"), val("noMultiLvlLbl", "0")])
        let value = C("valAx", [:], common(ids[1], valuePosition, gridlines: true, title: valueTitle, vertical: !horizontal)
            + [noFillShape(), textProperties(size: 900), val("crossAx", ids[0]), val("crosses", "autoZero"),
               val("crossBetween", kind == .area ? "midCat" : "between")])
        return [category, value]
    }

    /// The plot area's groups and axes for `settings` (series grouped by kind).
    func plotContents(_ settings: ChartSettings, cache: ChartCache, axisIDs: [String]) -> (groups: [XMLNode], axes: [XMLNode]) {
        var order: [SheetChart.Kind] = []
        var byKind: [SheetChart.Kind: [XMLNode]] = [:]
        for (index, source) in settings.series.enumerated() {
            let kind = settings.kind(of: source)
            if byKind[kind] == nil { order.append(kind) }
            byKind[kind, default: []].append(series(kind, source, index: index, cache: cache))
        }
        if order.isEmpty { order = [settings.kind] }
        let hasAxes = ChartSettings.hasAxes(settings.kind)
        // Bars across and columns can't share axes: the chart's kind decides.
        let groups = order.map { kind in
            group(kind, grouping: ChartSettings.stacks(kind) ? settings.grouping : .standard,
                  series: byKind[kind] ?? [], dataLabels: settings.showsDataLabels ?? false, axisIDs: hasAxes ? axisIDs : [])
        }
        let axes = hasAxes ? self.axes(settings.kind == .bar || order.contains(.bar) ? .bar : settings.kind,
                                       ids: axisIDs, categoryTitle: settings.categoryAxisTitle,
                                       valueTitle: settings.valueAxisTitle) : []
        return (groups, axes)
    }

    // MARK: A whole chart part

    func chartSpace(_ settings: ChartSettings, cache: ChartCache) -> XMLNode {
        let axisIDs = ["500000001", "500000002"]
        let (groups, axes) = plotContents(settings, cache: cache, axisIDs: axisIDs)
        var chartChildren: [XMLNode] = []
        switch settings.title {
        case .automatic: chartChildren.append(chartTitle(nil))
        case .text(let t): chartChildren.append(chartTitle(t))
        case .none: break
        }
        chartChildren.append(val("autoTitleDeleted", settings.title == .none ? "1" : "0"))
        chartChildren.append(C("plotArea", [:], [C("layout")] + groups + axes + [noFillShape()]))
        if let position = settings.legend { chartChildren.append(legend(position)) }
        chartChildren += [val("plotVisOnly", "1"), val("dispBlanksAs", "gap")]
        let space = C("chartSpace", [:], [
            val("date1904", "0"), val("lang", "en-US"), val("roundedCorners", "0"),
            C("chart", [:], chartChildren),
            C("spPr", [:], [A("solidFill", [:], [A("schemeClr", ["val": "bg1"])]), lightLine(), A("effectLst")]),
            C("txPr", [:], [A("bodyPr"), A("lstStyle"), A("p", [:], [A("pPr", [:], [A("defRPr")]),
                                                                      A("endParaRPr", ["lang": "en-US"])])]),
            C("printSettings", [:], [C("headerFooter"), C("pageMargins", ["b": "0.75", "l": "0.7", "r": "0.7",
                                                                          "t": "0.75", "header": "0.3", "footer": "0.3"]),
                                     C("pageSetup")]),
        ])
        space.attributes["xmlns:c"] = ChartNamespace.chart
        space.attributes["xmlns:a"] = ChartNamespace.drawingML
        space.attributes["xmlns:r"] = ChartNamespace.relationships
        return space
    }
}

/// The cached values written beside a series' references (what a reader
/// that doesn't recalculate shows), from the workbook as it is: read
/// through ChartReference, as the chart draws them.
struct ChartCache {
    let workbook: Workbook
    /// The chart's "plot visible cells only".
    var visibleOnly = true

    func reference(_ formula: String) -> ChartReference { ChartReference(formula, in: workbook) }

    func count(_ formula: String) -> Int {
        reference(formula).values(in: workbook, visibleOnly: visibleOnly)?.count ?? 0
    }

    /// A strRef's or numRef's reference with its cache, by what the cells hold.
    func reference(_ formula: String, _ x: ChartXML) -> XMLNode {
        reference(formula).isNumeric(in: workbook, visibleOnly: visibleOnly)
            ? x.C("numRef", [:], [x.text(x.c + "f", formula), numbers(formula, x)])
            : x.C("strRef", [:], [x.text(x.c + "f", formula), strings(formula, x, single: false)])
    }

    func strings(_ formula: String, _ x: ChartXML, single: Bool) -> XMLNode {
        let ref = reference(formula)
        if single {
            let text = ref.text(in: workbook) ?? ""
            return x.C("strCache", [:], [x.val("ptCount", "1"), x.C("pt", ["idx": "0"], [x.text(x.c + "v", text)])])
        }
        let labels = ref.labels(in: workbook, visibleOnly: visibleOnly) ?? []
        var points: [XMLNode] = [x.val("ptCount", String(labels.count))]
        for (i, text) in labels.enumerated() where !text.isEmpty {
            points.append(x.C("pt", ["idx": String(i)], [x.text(x.c + "v", text)]))
        }
        return x.C("strCache", [:], points)
    }

    func numbers(_ formula: String, _ x: ChartXML) -> XMLNode {
        let ref = reference(formula)
        let values = ref.numbers(in: workbook, visibleOnly: visibleOnly) ?? []
        var points: [XMLNode] = [x.text(x.c + "formatCode", ref.formatCode(in: workbook)),
                                 x.val("ptCount", String(values.count))]
        for (i, value) in values.enumerated() {
            guard let n = value else { continue }
            points.append(x.C("pt", ["idx": String(i)], [x.text(x.c + "v", NumberFormatEngine.roundTripString(for: n))]))
        }
        return x.C("numCache", [:], points)
    }

    /// Bring every cache in a chart part up to date with the cells, for
    /// the references that can be followed (the rest keep theirs), when
    /// its values differ. True when something changed. Used at save.
    static func refresh(_ root: XMLNode, workbook: Workbook) -> Bool {
        guard root.localName == "chartSpace", let body = root.firstChild("chart") else { return false }
        let visibleOnly = body.firstChild("plotVisOnly").map { ($0.attributes["val"] ?? "1") != "0" && $0.attributes["val"] != "false" } ?? true
        let cache = ChartCache(workbook: workbook, visibleOnly: visibleOnly)
        let x = ChartXML(c: root.prefix, a: "a:")
        var changed = false
        root.forEach { node in
            guard node.localName == "numRef" || node.localName == "strRef",
                  let f = node.firstChild("f")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty else { return }
            let formula = f.hasPrefix("=") ? String(f.dropFirst()) : f
            // Caches that are there are kept current; a file written
            // without them stays so.
            guard node.firstChild("numCache") != nil || node.firstChild("strCache") != nil,
                  cache.reference(formula).isFollowed else { return }
            // A series name (one cell or a few) caches as one piece of text.
            let isName = node.localName == "strRef" && (node.firstChild("strCache")?.firstChild("ptCount")?.attributes["val"] == "1")
            let fresh = node.localName == "numRef" ? cache.numbers(formula, x) : cache.strings(formula, x, single: isName)
            let cacheName = node.localName == "numRef" ? "numCache" : "strCache"
            // Only when the values differ: a cache that says the same is left
            // as written (a save without edits keeps the part's bytes).
            if let old = node.firstChild(cacheName), Self.sameValues(old, fresh, numeric: cacheName == "numCache") { return }
            // Keep a numCache's own format code when the cell has none.
            if cacheName == "numCache", let oldFormat = node.firstChild("numCache")?.firstChild("formatCode"),
               fresh.firstChild("formatCode")?.text == "General" {
                fresh.setChild("formatCode", oldFormat, order: ["formatCode", "ptCount", "pt", "extLst"])
            }
            node.setChild(cacheName, fresh, order: ["f", "numCache", "strCache", "extLst"])
            changed = true
        }
        return changed
    }

    /// Whether two caches hold the same points (numbers compared as numbers).
    static func sameValues(_ a: XMLNode, _ b: XMLNode, numeric: Bool) -> Bool {
        let pa = XLSXCharts.cached(a), pb = XLSXCharts.cached(b)
        guard pa.count == pb.count else { return false }
        return zip(pa, pb).allSatisfy { x, y in
            if numeric, let x, let y, let dx = Double(x), let dy = Double(y) { return dx == dy }
            return (x ?? "") == (y ?? "")
        }
    }
}
