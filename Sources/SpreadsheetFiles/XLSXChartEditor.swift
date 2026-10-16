import Foundation
import SpreadsheetCore

// Making, placing, changing and removing charts. Charts live in the parts a
// workbook carries (CarriedParts): a sheet's drawing holds an anchor per
// chart, pointing at its chart part. A new chart gets Excel's default look
// (ChartXML); a change to one made elsewhere touches only what it changes,
// so the rest of its formatting stays as it was. Every operation replaces
// `workbook.carriedContent`, a value, which is what undo keeps.

public enum XLSXChartEditor {
    static let chartContentType = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
    static let drawingContentType = "application/vnd.openxmlformats-officedocument.drawing+xml"
    static let drawingRelationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing"
    static let chartRelationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart"

    // MARK: Insert

    /// Add a chart to a sheet, between two corners. Returns its id.
    @discardableResult
    public static func insert(_ settings: ChartSettings, onSheet sheetID: Int, from: SheetChart.Anchor,
                              to: SheetChart.Anchor, in workbook: Workbook) -> String? {
        guard workbook.sheet(withID: sheetID) != nil else { return nil }
        var carried = (workbook.carriedContent as? CarriedParts) ?? CarriedParts()
        let chartPath = unusedPath("xl/charts/chart", in: carried)
        let chart = ChartXML().chartSpace(settings, cache: ChartCache(workbook: workbook))
        carried.parts[chartPath] = CarriedPart(data: chart.document, contentType: chartContentType,
                                               hasOverride: true, relationships: [])

        var sheet = carried.sheets[sheetID] ?? CarriedSheet()
        // The sheet's drawing, or a new one.
        var drawingPath: String
        var drawing: XMLNode
        if let rel = sheet.relationships.first(where: { $0.type.hasSuffix("/drawing") }),
           case .part(let path) = rel.target, let part = carried.parts[path], let root = try? XMLNode.parse(part.data) {
            drawingPath = path
            drawing = root
        } else {
            drawingPath = unusedPath("xl/drawings/drawing", in: carried)
            drawing = XMLNode(name: "xdr:wsDr", attributes: ["xmlns:xdr": ChartNamespace.spreadsheetDrawing,
                                                             "xmlns:a": ChartNamespace.drawingML])
            carried.parts[drawingPath] = CarriedPart(data: Data(), contentType: drawingContentType,
                                                     hasOverride: true, relationships: [])
            let id = unusedID(sheet.relationships.map(\.id))
            sheet.relationships.append(CarriedRelationship(id: id, type: drawingRelationship, target: .part(drawingPath)))
            sheet.elements.removeAll { $0.name == "drawing" }
            sheet.elements.append(CarriedElement(name: "drawing", xml: "<drawing r:id=\"\(id)\"/>"))
        }
        guard var drawingPart = carried.parts[drawingPath] else { return nil }
        let relID = unusedID(drawingPart.relationships.map(\.id))
        drawingPart.relationships.append(CarriedRelationship(id: relID, type: chartRelationship, target: .part(chartPath)))
        drawing.children.append(.element(anchor(for: relID, from: from, to: to, in: drawing)))
        drawingPart.data = drawing.document
        carried.parts[drawingPath] = drawingPart
        carried.sheets[sheetID] = sheet
        workbook.carriedContent = carried
        return chartPath
    }

    /// A two-cell anchor holding a graphic frame for the chart at `relID`.
    private static func anchor(for relID: String, from: SheetChart.Anchor, to: SheetChart.Anchor,
                               in drawing: XMLNode) -> XMLNode {
        let xdr = drawing.prefix
        let a = prefix(boundTo: ChartNamespace.drawingML, in: drawing) ?? "a:"
        var ids: [Int] = [1]
        var names: [Int] = [0]
        drawing.forEach { node in
            guard node.localName == "cNvPr" else { return }
            if let id = Int(node.attributes["id"] ?? "") { ids.append(id) }
            if let name = node.attributes["name"], name.hasPrefix("Chart "), let n = Int(name.dropFirst(6)) { names.append(n) }
        }
        func el(_ name: String, _ attributes: [String: String] = [:], _ children: [XMLNode] = []) -> XMLNode {
            XMLNode(name: name, attributes: attributes, children: children.map { .element($0) })
        }
        let chart = el("c:chart", ["xmlns:c": ChartNamespace.chart, "xmlns:r": ChartNamespace.relationships, "r:id": relID])
        let graphicFrame = el(xdr + "graphicFrame", ["macro": ""], [
            el(xdr + "nvGraphicFramePr", [:], [
                el(xdr + "cNvPr", ["id": String(ids.max()! + 1), "name": "Chart \(names.max()! + 1)"]),
                el(xdr + "cNvGraphicFramePr"),
            ]),
            el(xdr + "xfrm", [:], [el(a + "off", ["x": "0", "y": "0"]), el(a + "ext", ["cx": "0", "cy": "0"])]),
            el(a + "graphic", [:], [el(a + "graphicData", ["uri": ChartNamespace.chart], [chart])]),
        ])
        if prefix(boundTo: ChartNamespace.drawingML, in: drawing) == nil {
            graphicFrame.attributes["xmlns:a"] = ChartNamespace.drawingML
        }
        return el(xdr + "twoCellAnchor", [:], [corner("from", from, xdr), corner("to", to, xdr), graphicFrame,
                                              el(xdr + "clientData")])
    }

    private static func corner(_ local: String, _ anchor: SheetChart.Anchor, _ xdr: String) -> XMLNode {
        func text(_ name: String, _ value: String) -> XMLNode { XMLNode(name: xdr + name, children: [.text(value)]) }
        return XMLNode(name: xdr + local, children: [
            .element(text("col", String(anchor.column))),
            .element(text("colOff", String(Int((anchor.columnOffset * XLSXCharts.emuPerPixel).rounded())))),
            .element(text("row", String(anchor.row))),
            .element(text("rowOff", String(Int((anchor.rowOffset * XLSXCharts.emuPerPixel).rounded())))),
        ])
    }

    // MARK: Place and delete

    /// Move or resize a chart: its corners, and its size for an anchor that
    /// keeps one (a one-cell anchor). An absolute anchor becomes a two-cell
    /// one. A chart in a group of shapes moves only with its group: false.
    @discardableResult
    public static func place(_ id: String, onSheet sheetID: Int, from: SheetChart.Anchor, to: SheetChart.Anchor,
                             size: SheetChart.Size, in workbook: Workbook) -> Bool {
        guard var carried = workbook.carriedContent as? CarriedParts,
              let found = locate(id, onSheet: sheetID, in: carried), !found.inGroup else { return false }
        let anchor = found.anchor
        let xdr = anchor.prefix
        switch anchor.localName {
        case "oneCellAnchor":
            anchor.setChild("from", corner("from", from, xdr), order: ["from", "ext"])
            anchor.setChild("ext", XMLNode(name: xdr + "ext", attributes: [
                "cx": String(Int((size.width * XLSXCharts.emuPerPixel).rounded())),
                "cy": String(Int((size.height * XLSXCharts.emuPerPixel).rounded())),
            ]), order: ["from", "ext"])
        default:
            anchor.name = xdr + "twoCellAnchor"
            anchor.removeElements { $0.localName == "pos" || $0.localName == "ext" }
            anchor.setChild("from", corner("from", from, xdr), order: ["from", "to"])
            anchor.setChild("to", corner("to", to, xdr), order: ["from", "to"])
        }
        carried.parts[found.drawingPath]?.data = found.drawing.document
        workbook.carriedContent = carried
        return true
    }

    /// Remove a chart; a group or drawing left empty goes with it. In a
    /// group of shapes, only the chart goes: the rest of the group stays.
    @discardableResult
    public static func delete(_ id: String, onSheet sheetID: Int, in workbook: Workbook) -> Bool {
        guard var carried = workbook.carriedContent as? CarriedParts,
              let found = locate(id, onSheet: sheetID, in: carried) else { return false }
        // Take the chart's frame out, then every container it leaves without shapes.
        let shapes: Set<String> = ["sp", "grpSp", "graphicFrame", "cxnSp", "pic", "contentPart", "AlternateContent"]
        func hasShapes(_ node: XMLNode) -> Bool { node.elements.contains { shapes.contains($0.localName) } }
        var path = found.path // anchor … frame
        var removed = path.removeLast()
        while let parent = path.last {
            parent.removeElements { $0 === removed }
            if parent === found.anchor || hasShapes(parent) { break }
            removed = path.removeLast()
        }
        if !hasShapes(found.anchor) { found.drawing.removeElements { $0 === found.anchor } }

        var stillUsed = false
        found.drawing.forEach { if CarriedParts.relationshipID(of: $0) == found.relationshipID { stillUsed = true } }
        if !stillUsed {
            carried.parts[found.drawingPath]?.relationships.removeAll { $0.id == found.relationshipID }
            carried.parts[id] = nil
        }
        if found.drawing.elements.isEmpty, var sheet = carried.sheets[sheetID] {
            carried.parts[found.drawingPath] = nil
            let gone = sheet.relationships.filter {
                if case .part(let path) = $0.target { return path == found.drawingPath }
                return false
            }.map(\.id)
            sheet.relationships.removeAll { gone.contains($0.id) }
            sheet.elements.removeAll { $0.name == "drawing" }
            carried.sheets[sheetID] = sheet
        } else {
            carried.parts[found.drawingPath]?.data = found.drawing.document
        }
        workbook.carriedContent = carried
        return true
    }

    struct Located {
        var drawingPath: String
        var drawing: XMLNode
        var anchor: XMLNode
        /// From the anchor down to the chart's graphic frame.
        var path: [XMLNode]
        var relationshipID: String
        /// In a group of shapes (it moves with the group).
        var inGroup: Bool { path.contains { $0.localName == "grpSp" } }
    }

    /// The drawing anchor and graphic frame showing chart `id` on a sheet.
    static func locate(_ id: String, onSheet sheetID: Int, in carried: CarriedParts) -> Located? {
        for rel in carried.sheets[sheetID]?.relationships ?? [] where rel.type.hasSuffix("/drawing") {
            guard case .part(let path) = rel.target, let part = carried.parts[path],
                  let relID = part.relationships.first(where: { $0.target == .part(id) })?.id,
                  let drawing = try? XMLNode.parse(part.data) else { continue }
            func find(_ node: XMLNode, _ trail: [XMLNode]) -> [XMLNode]? {
                let trail = trail + [node]
                if node.localName == "graphicFrame" {
                    var match = false
                    node.forEach { if ($0.localName == "chart" || $0.localName == "chartex"),
                                      CarriedParts.relationshipID(of: $0) == relID { match = true } }
                    return match ? trail : nil
                }
                for child in node.elements { if let hit = find(child, trail) { return hit } }
                return nil
            }
            for anchor in drawing.elements {
                if let trail = find(anchor, []) {
                    return Located(drawingPath: path, drawing: drawing, anchor: anchor, path: trail, relationshipID: relID)
                }
            }
        }
        return nil
    }

    // MARK: Update

    /// Change a chart from `old` settings (as read) to `new`. Settings
    /// changes are made in place; a different data range or a change
    /// between kinds that draw differently (columns to lines, anything to
    /// pie) rebuilds the plot, keeping the axes and their formatting where
    /// both kinds have them.
    @discardableResult
    public static func update(_ id: String, from old: ChartSettings, to new: ChartSettings,
                              in workbook: Workbook) -> Bool {
        guard var carried = workbook.carriedContent as? CarriedParts, let part = carried.parts[id],
              let root = try? XMLNode.parse(part.data), root.localName == "chartSpace",
              let chart = root.firstChild("chart"), let plot = chart.firstChild("plotArea") else { return false }
        let x = ChartXML(root: root)
        let visibleOnly = chart.firstChild("plotVisOnly").map { ($0.attributes["val"] ?? "1") != "0" && $0.attributes["val"] != "false" } ?? true
        let cache = ChartCache(workbook: workbook, visibleOnly: visibleOnly)

        if needsRebuild(old, new) {
            rebuildPlot(plot, old, new, x, cache)
        } else {
            changeInPlace(plot, old, new, x)
        }
        if old.title != new.title { setTitle(new.title, chart, x) }
        if old.legend != new.legend { setLegend(new.legend, chart, x) }
        let axes = axisNodes(plot, kind: new.kind)
        if let category = axes.category, old.categoryAxisTitle != new.categoryAxisTitle || needsRebuild(old, new) {
            setAxisTitle(new.categoryAxisTitle, on: category, x)
        }
        if let value = axes.value, old.valueAxisTitle != new.valueAxisTitle || needsRebuild(old, new) {
            setAxisTitle(new.valueAxisTitle, on: value, x)
        }
        if old.showsDataLabels != new.showsDataLabels, let shown = new.showsDataLabels { setDataLabels(shown, plot, x) }

        carried.parts[id]?.data = root.document
        workbook.carriedContent = carried
        return true
    }

    /// Kinds that are one element (columns and bars are a barChart).
    private static func family(_ kind: SheetChart.Kind) -> String { ChartXML.groupName(kind) }

    static func needsRebuild(_ old: ChartSettings, _ new: ChartSettings) -> Bool {
        func shape(_ s: ChartSettings) -> [String] {
            s.series.map { "\($0.name.map { "\($0)" } ?? "")|\($0.categories ?? "")|\($0.values)|\(family(s.kind(of: $0)))" }
        }
        return family(old.kind) != family(new.kind) || shape(old) != shape(new)
    }

    private static func groups(_ plot: XMLNode) -> [XMLNode] { plot.elements.filter { $0.localName.hasSuffix("Chart") } }

    private static func changeInPlace(_ plot: XMLNode, _ old: ChartSettings, _ new: ChartSettings, _ x: ChartXML) {
        for group in groups(plot) {
            switch group.localName {
            case "barChart", "bar3DChart":
                if old.kind != new.kind, new.kind == .bar || new.kind == .column {
                    group.setChild("barDir", x.val("barDir", new.kind == .bar ? "bar" : "col"), order: ChartSchema.group)
                    // The category axis runs down the left of bars, along the bottom of columns.
                    for axis in plot.elements where axis.localName == "catAx" || axis.localName == "valAx" {
                        let category = axis.localName == "catAx"
                        let position = (new.kind == .bar) == category ? "l" : "b"
                        axis.setChild("axPos", x.val("axPos", position), order: ChartSchema.axis)
                    }
                }
                if old.grouping != new.grouping {
                    let code = new.grouping == .standard ? "clustered"
                        : new.grouping == .stacked ? "stacked" : "percentStacked"
                    group.setChild("grouping", x.val("grouping", code), order: ChartSchema.group)
                    // Stacked bars sit on each other; clustered ones side by side.
                    group.setChild("overlap", x.val("overlap", new.grouping == .standard ? "-27" : "100"),
                                   order: ChartSchema.group)
                }
            case "lineChart", "line3DChart", "areaChart", "area3DChart":
                if old.grouping != new.grouping {
                    let code = new.grouping == .standard ? "standard"
                        : new.grouping == .stacked ? "stacked" : "percentStacked"
                    group.setChild("grouping", x.val("grouping", code), order: ChartSchema.group)
                }
            default:
                break
            }
        }
        // Colours, series by series in file order (as they were read).
        let serNodes = groups(plot).flatMap { group in group.children("ser").map { (group, $0) } }
        for (index, (oldSeries, newSeries)) in zip(old.series, new.series).enumerated()
        where oldSeries.color != newSeries.color && index < serNodes.count {
            let (group, ser) = serNodes[index]
            setColor(newSeries.color, on: ser, line: group.localName.hasPrefix("line"), index: index, x)
        }
    }

    private static func setColor(_ color: ChartSeriesSource.Color?, on ser: XMLNode, line: Bool, index: Int, _ x: ChartXML) {
        let spPr = ser.firstChild("spPr") ?? {
            let node = x.C("spPr")
            ser.insert(node, order: ChartSchema.series)
            return node
        }()
        if line {
            let ln = spPr.firstChild("ln") ?? {
                let node = x.A("ln", ["w": "28575", "cap": "rnd"])
                spPr.insert(node, order: shapeOrder)
                return node
            }()
            ln.removeElements { ["noFill", "solidFill", "gradFill", "pattFill"].contains($0.localName) }
            ln.children.insert(.element(x.fill(color, index: index)), at: 0)
            // Markers in the same colour.
            if let markerShape = ser.firstChild("marker")?.firstChild("spPr") {
                markerShape.removeElements { ["noFill", "solidFill", "gradFill", "pattFill"].contains($0.localName) }
                markerShape.children.insert(.element(x.fill(color, index: index)), at: 0)
            }
        } else {
            spPr.removeElements { ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"].contains($0.localName) }
            spPr.insert(x.fill(color, index: index), order: shapeOrder)
            if let markerShape = ser.firstChild("marker")?.firstChild("spPr") {
                markerShape.removeElements { ["noFill", "solidFill", "gradFill", "pattFill"].contains($0.localName) }
                markerShape.children.insert(.element(x.fill(color, index: index)), at: 0)
            }
        }
    }

    /// The plot for new kinds or new series, series by series: each
    /// existing `<c:ser>` is kept (its formatting, trendlines, labels and
    /// extensions) and moved into a group of its new kind, losing only
    /// what that kind can't have; only references that changed are
    /// rewritten (so one that can't be followed keeps its cache). Groups of
    /// the same kind on the same axes are kept, and so are the axes, when
    /// both kinds have category and value axes (a secondary axis included).
    private static func rebuildPlot(_ plot: XMLNode, _ old: ChartSettings, _ new: ChartSettings, _ x: ChartXML,
                                    _ cache: ChartCache) {
        let oldGroups = groups(plot)
        var oldSeries: [(node: XMLNode, axes: [String])] = []
        for group in oldGroups {
            let axes = group.children("axId").map { $0.attributes["val"] ?? "" }
            for ser in group.children("ser") { oldSeries.append((ser, axes)) }
        }
        let oldScatter = oldGroups.contains { $0.localName == "scatterChart" }
        let primary = oldGroups.first { $0.children("axId").count >= 2 }?.children("axId").map { $0.attributes["val"] ?? "" } ?? []
        let hasCategoryAxis = plot.elements.contains { $0.localName == "catAx" || $0.localName == "dateAx" }
        let keepAxes = ChartSettings.hasAxes(new.kind) && primary.count >= 2
            && ((new.kind != .scatter && !oldScatter && hasCategoryAxis) || (new.kind == .scatter && oldScatter))
        let newAxisIDs = ["500000001", "500000002"]
        let validAxisIDs = Set(plot.elements.compactMap { $0.firstChild("axId")?.attributes["val"] })

        // The series, kept or made, with the axes they go on.
        var nextIndex = (oldSeries.compactMap { Int($0.node.firstChild("idx")?.attributes["val"] ?? "") }.max() ?? -1) + 1
        var placed: [(kind: SheetChart.Kind, axes: [String], node: XMLNode)] = []
        for (i, source) in new.series.enumerated() {
            let kind = new.kind(of: source)
            let axes: [String]
            let node: XMLNode
            if i < oldSeries.count, i < old.series.count {
                node = oldSeries[i].node
                convert(node, to: kind, x)
                updateReferences(node, from: old.series[i], to: source, kind: kind, x, cache)
                if old.series[i].color != source.color || ChartXML.groupName(old.kind(of: old.series[i])) != ChartXML.groupName(kind) {
                    if let color = source.color {
                        setColor(color, on: node, line: kind == .line || kind == .scatter, index: i, x)
                    }
                }
                let own = oldSeries[i].axes
                axes = keepAxes ? (own.count >= 2 && own.allSatisfy(validAxisIDs.contains) ? own : primary) : newAxisIDs
            } else {
                node = x.series(kind, source, index: nextIndex, cache: cache)
                nextIndex += 1
                axes = keepAxes ? primary : newAxisIDs
            }
            node.setChild("order", x.val("order", String(i)), order: ChartSchema.series)
            placed.append((kind, axes, node))
        }

        // Groups: one per kind and pair of axes, in order of first use.
        var keys: [String] = []
        var members: [String: [(SheetChart.Kind, [String], XMLNode)]] = [:]
        for item in placed {
            let key = ChartXML.groupName(item.kind) + (item.kind == .bar ? "/bar" : "") + "|" + item.axes.joined(separator: ",")
            if members[key] == nil { keys.append(key) }
            members[key, default: []].append(item)
        }
        if keys.isEmpty { keys = ["empty"]; members["empty"] = [] }
        var reused = Set<ObjectIdentifier>()
        var newGroups: [XMLNode] = []
        for key in keys {
            let items = members[key] ?? []
            let kind = items.first?.0 ?? new.kind
            let axes = ChartSettings.hasAxes(kind) ? (items.first?.1 ?? (keepAxes ? primary : newAxisIDs)) : []
            let grouping = ChartSettings.stacks(kind) ? new.grouping : .standard
            // An old group of the same kind on the same axes keeps its own settings.
            let group: XMLNode
            if let match = oldGroups.first(where: { g in
                !reused.contains(ObjectIdentifier(g)) && g.localName == ChartXML.groupName(kind)
                    && g.children("axId").map { $0.attributes["val"] ?? "" } == axes
                    && (g.localName != "barChart" || (g.firstChild("barDir")?.attributes["val"] == "bar") == (kind == .bar))
            }) {
                group = match
                reused.insert(ObjectIdentifier(match))
                group.removeElements { $0.localName == "ser" }
                setGrouping(group, kind: kind, grouping: grouping, x)
            } else {
                group = x.group(kind, grouping: grouping, series: [], dataLabels: new.showsDataLabels ?? false, axisIDs: axes)
                // Keep the old labels' formatting when the setting is the same.
                if old.showsDataLabels == new.showsDataLabels, let labels = oldGroups.first?.firstChild("dLbls") {
                    group.setChild("dLbls", labels, order: ChartSchema.group)
                }
            }
            for item in items { group.insert(item.2, order: ChartSchema.group) }
            newGroups.append(group)
        }
        plot.removeElements { $0.localName.hasSuffix("Chart") }
        for group in newGroups { plot.insert(group, order: ChartSchema.plotArea) }

        // Axes.
        let used = Set(newGroups.flatMap { $0.children("axId").map { $0.attributes["val"] ?? "" } })
        if keepAxes {
            plot.removeElements { ["catAx", "valAx", "dateAx", "serAx"].contains($0.localName)
                && !used.contains($0.firstChild("axId")?.attributes["val"] ?? "") }
            if new.kind != .scatter {
                // Bars and columns put their category axis on different sides.
                for axis in plot.elements where axis.localName == "catAx" || axis.localName == "valAx" {
                    let id = axis.firstChild("axId")?.attributes["val"] ?? ""
                    guard id == primary[0] || id == primary[1] else { continue }
                    let category = axis.localName == "catAx"
                    axis.setChild("axPos", x.val("axPos", (new.kind == .bar) == category ? "l" : "b"), order: ChartSchema.axis)
                }
            }
        } else {
            plot.removeElements { ["catAx", "valAx", "dateAx", "serAx"].contains($0.localName) }
            if ChartSettings.hasAxes(new.kind) {
                for axis in x.axes(new.kind, ids: newAxisIDs, categoryTitle: nil, valueTitle: nil) {
                    plot.insert(axis, order: ChartSchema.plotArea)
                }
            }
        }
    }

    /// Series children each kind can have (CT_BarSer, CT_LineSer, …).
    private static func allowedSeriesChildren(_ kind: SheetChart.Kind) -> Set<String> {
        let common: Set<String> = ["idx", "order", "tx", "spPr", "dPt", "dLbls", "extLst"]
        switch kind {
        case .column, .bar: return common.union(["invertIfNegative", "pictureOptions", "trendline", "errBars", "cat", "val", "shape"])
        case .line: return common.union(["marker", "trendline", "errBars", "cat", "val", "smooth"])
        case .area: return common.union(["pictureOptions", "trendline", "errBars", "cat", "val"])
        case .pie, .doughnut: return common.union(["explosion", "cat", "val"])
        case .scatter: return common.union(["marker", "trendline", "errBars", "xVal", "yVal", "smooth"])
        }
    }

    /// A kept series made fit for `kind`: categories and values renamed
    /// for or from a scatter, children the kind can't have dropped, its
    /// colour carried between fill and line.
    private static func convert(_ ser: XMLNode, to kind: SheetChart.Kind, _ x: ChartXML) {
        let renames = kind == .scatter ? ["cat": "xVal", "val": "yVal"] : ["xVal": "cat", "yVal": "val"]
        for child in ser.elements {
            if let to = renames[child.localName] { child.name = child.prefix + to }
        }
        let allowed = allowedSeriesChildren(kind)
        ser.removeElements { !allowed.contains($0.localName) }
        if let spPr = ser.firstChild("spPr") {
            let fill = spPr.firstChild("solidFill")
            let lineFill = spPr.firstChild("ln")?.firstChild("solidFill")
            switch kind {
            case .line:
                if lineFill == nil, let fill {
                    let ln = spPr.firstChild("ln") ?? {
                        let node = x.A("ln", ["w": "28575", "cap": "rnd"])
                        spPr.insert(node, order: shapeOrder)
                        return node
                    }()
                    ln.removeElements { $0.localName == "noFill" }
                    ln.children.insert(.element(XMLNode(name: fill.name, attributes: fill.attributes, children: fill.children)), at: 0)
                }
            case .column, .bar, .area, .pie, .doughnut:
                if fill == nil, let lineFill {
                    spPr.removeElements { $0.localName == "noFill" }
                    spPr.insert(XMLNode(name: lineFill.name, attributes: lineFill.attributes, children: lineFill.children),
                                order: shapeOrder)
                }
            case .scatter:
                break
            }
        }
        // Excel's line series has no markers unless asked; a scatter's has them.
        if kind == .line, ser.firstChild("marker") == nil {
            ser.insert(x.C("marker", [:], [x.val("symbol", "none")]), order: ChartSchema.series)
        }
        if kind == .scatter, ser.firstChild("marker") == nil {
            ser.insert(x.C("marker", [:], [x.val("symbol", "circle"), x.val("size", "5")]), order: ChartSchema.series)
        }
        // Back in schema order (renamed children may sit out of it).
        let rank = { (node: XMLNode) in ChartSchema.series.firstIndex(of: node.localName) ?? ChartSchema.series.count }
        let elements = ser.elements.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        ser.children = elements.map { .element($0.element) }
    }

    /// Rewrite the references that changed (with fresh caches); the rest,
    /// and their caches, stay as they are.
    private static func updateReferences(_ ser: XMLNode, from old: ChartSeriesSource, to new: ChartSeriesSource,
                                         kind: SheetChart.Kind, _ x: ChartXML, _ cache: ChartCache) {
        if old.name != new.name {
            switch new.name {
            case .reference(let f)?:
                ser.setChild("tx", x.C("tx", [:], [x.C("strRef", [:], [x.text(x.c + "f", f), cache.strings(f, x, single: true)])]),
                             order: ChartSchema.series)
            case .text(let t)?:
                ser.setChild("tx", x.C("tx", [:], [x.text(x.c + "v", t)]), order: ChartSchema.series)
            case nil:
                ser.setChild("tx", nil, order: ChartSchema.series)
            }
        }
        let (categoriesName, valuesName) = kind == .scatter ? ("xVal", "yVal") : ("cat", "val")
        if old.categories != new.categories {
            ser.setChild(categoriesName, new.categories.map { x.C(categoriesName, [:], [cache.reference($0, x)]) },
                         order: ChartSchema.series)
        }
        if old.values != new.values {
            ser.setChild(valuesName, x.C(valuesName, [:], [x.C("numRef", [:], [x.text(x.c + "f", new.values),
                                                                              cache.numbers(new.values, x)])]),
                         order: ChartSchema.series)
        }
    }

    /// A group's stacking (and a bar group's direction).
    private static func setGrouping(_ group: XMLNode, kind: SheetChart.Kind, grouping: SheetChart.Grouping, _ x: ChartXML) {
        switch group.localName {
        case "barChart", "bar3DChart":
            group.setChild("barDir", x.val("barDir", kind == .bar ? "bar" : "col"), order: ChartSchema.group)
            let code = grouping == .standard ? "clustered" : grouping == .stacked ? "stacked" : "percentStacked"
            if group.firstChild("grouping")?.attributes["val"] != code {
                group.setChild("grouping", x.val("grouping", code), order: ChartSchema.group)
                group.setChild("overlap", x.val("overlap", grouping == .standard ? "-27" : "100"), order: ChartSchema.group)
            }
        case "lineChart", "line3DChart", "areaChart", "area3DChart":
            let code = grouping == .standard ? "standard" : grouping == .stacked ? "stacked" : "percentStacked"
            group.setChild("grouping", x.val("grouping", code), order: ChartSchema.group)
        default:
            break
        }
    }

    private static let shapeOrder = ["xfrm", "custGeom", "prstGeom", "noFill", "solidFill", "gradFill", "blipFill",
                                     "pattFill", "grpFill", "ln", "effectLst", "effectDag", "scene3d", "sp3d", "extLst"]

    private static func setTitle(_ title: ChartSettings.Title, _ chart: XMLNode, _ x: ChartXML) {
        switch title {
        case .none:
            chart.setChild("title", nil, order: ChartSchema.chart)
        case .automatic:
            if let existing = chart.firstChild("title") {
                existing.setChild("tx", nil, order: ChartSchema.title)
            } else {
                chart.insert(x.chartTitle(nil), order: ChartSchema.chart)
            }
        case .text(let text):
            if let existing = chart.firstChild("title") {
                existing.setChild("tx", x.richText(text, size: 1400), order: ChartSchema.title)
            } else {
                chart.insert(x.chartTitle(text), order: ChartSchema.chart)
            }
        }
        chart.setChild("autoTitleDeleted", x.val("autoTitleDeleted", title == .none ? "1" : "0"), order: ChartSchema.chart)
    }

    private static func setLegend(_ position: SheetChart.LegendPosition?, _ chart: XMLNode, _ x: ChartXML) {
        guard let position else {
            chart.setChild("legend", nil, order: ChartSchema.chart)
            return
        }
        if let legend = chart.firstChild("legend") {
            legend.setChild("legendPos", x.val("legendPos", ChartXML.legendCode(position)), order: ChartSchema.legend)
        } else {
            chart.insert(x.legend(position), order: ChartSchema.chart)
        }
    }

    /// The category (a scatter's x) and value axes.
    private static func axisNodes(_ plot: XMLNode, kind: SheetChart.Kind) -> (category: XMLNode?, value: XMLNode?) {
        let axes = plot.elements.filter { ["catAx", "valAx", "dateAx"].contains($0.localName) }
        if kind == .scatter {
            func position(_ a: XMLNode) -> String { a.firstChild("axPos")?.attributes["val"] ?? "" }
            let xAxis = axes.first { ["b", "t"].contains(position($0)) }
            return (xAxis, axes.first { $0 !== xAxis })
        }
        return (axes.first { $0.localName != "valAx" }, axes.first { $0.localName == "valAx" })
    }

    private static func setAxisTitle(_ text: String?, on axis: XMLNode, _ x: ChartXML) {
        guard let text, !text.isEmpty else {
            axis.setChild("title", nil, order: ChartSchema.axis)
            return
        }
        let position = axis.firstChild("axPos")?.attributes["val"] ?? "b"
        let vertical = position == "l" || position == "r"
        if let existing = axis.firstChild("title") {
            existing.setChild("tx", x.richText(text, size: 1000, rotation: vertical ? "-5400000" : "0"),
                              order: ChartSchema.title)
        } else {
            axis.insert(x.axisTitle(text, vertical: vertical), order: ChartSchema.axis)
        }
    }

    private static func setDataLabels(_ shown: Bool, _ plot: XMLNode, _ x: ChartXML) {
        for group in groups(plot) {
            let pie = group.localName.contains("ie") || group.localName == "doughnutChart"
            if let labels = group.firstChild("dLbls"), labels.firstChild("delete") == nil {
                labels.setChild("showVal", x.val("showVal", shown ? "1" : "0"), order: ChartSchema.dataLabels)
            } else {
                group.setChild("dLbls", x.dataLabels(shown, pie: pie), order: ChartSchema.group)
            }
            // Series' own labels override the group's.
            for ser in group.children("ser") {
                guard let labels = ser.firstChild("dLbls") else { continue }
                if labels.firstChild("delete") != nil {
                    if shown { ser.setChild("dLbls", nil, order: ChartSchema.series) }
                } else {
                    labels.setChild("showVal", x.val("showVal", shown ? "1" : "0"), order: ChartSchema.dataLabels)
                }
            }
        }
    }

    // MARK: Helpers

    /// `base` + the first number not in use + ".xml".
    private static func unusedPath(_ base: String, in carried: CarriedParts) -> String {
        var n = 1
        while carried.parts["\(base)\(n).xml"] != nil { n += 1 }
        return "\(base)\(n).xml"
    }

    private static func unusedID(_ ids: [String]) -> String {
        var n = 1
        while ids.contains("rId\(n)") { n += 1 }
        return "rId\(n)"
    }

    private static func prefix(boundTo namespace: String, in root: XMLNode) -> String? {
        root.attributes.first { $0.key.hasPrefix("xmlns:") && $0.value == namespace }.map { String($0.key.dropFirst(6)) + ":" }
    }
}
