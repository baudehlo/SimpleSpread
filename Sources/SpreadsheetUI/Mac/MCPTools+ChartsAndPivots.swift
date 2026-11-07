#if os(macOS)
import CoreGraphics
import Foundation
import SpreadsheetCore
import SpreadsheetFiles

// Charts and pivot tables for agents: the same commands the Chart panel
// and the PivotTable Fields panel use, so each call is one undo step and
// the window redraws as it lands. Nothing here asks the user anything: an
// edit that would overwrite cells fails unless the agent passes `replace`.
extension MCPTools {
    // MARK: - Tool list

    static let chartKinds: [JSONValue] = ["column", "bar", "line", "area", "pie", "doughnut", "scatter"]

    static let chartOptions: [(String, JSONValue)] = [
        ("grouping", ["type": "string", "enum": ["standard", "stacked", "percent_stacked"],
                      "description": "Column, bar, line and area charts: side by side (standard), stacked, or stacked to 100%."]),
        ("title", ["type": "string", "description": "The chart's title; \"\" for none, \"auto\" for Excel's own."]),
        ("legend", ["type": "string", "enum": ["top", "bottom", "left", "right", "none"]]),
        ("category_axis_title", ["type": "string", "description": "\"\" for none."]),
        ("value_axis_title", ["type": "string", "description": "\"\" for none."]),
        ("data_labels", ["type": "boolean", "description": "Show each point's value."]),
        ("series_in", ["type": "string", "enum": ["columns", "rows"],
                       "description": "Whether each series is a column of the data (the default when it is taller than wide) or a row."]),
        ("colors", ["type": "array", "items": ["type": ["string", "null"]],
                    "description": "Series colours in order, \"#RRGGBB\"; null keeps one."]),
        ("position", ["type": "string", "description": "The cell the chart's top-left corner sits on, e.g. \"F2\"."]),
        ("width", ["type": "number", "description": "Width in points (default 480)."]),
        ("height", ["type": "number", "description": "Height in points (default 288)."]),
    ]

    static let chartProperty: (String, JSONValue) = ("chart", [
        "type": "string",
        "description": "The chart's id or name from list_charts. Default: the only chart on the sheet.",
    ])

    static let chartTools: [Tool] = [
        Tool(name: "list_charts",
             description: "List the charts on a sheet (default: the one showing): id, name, type, title, legend, the "
                + "data range and each series' cells and colour, and where it sits.",
             properties: properties([]),
             required: [], run: { tools, args in .json(try tools.listCharts(args)) }),
        Tool(name: "insert_chart",
             description: "Insert a chart of a block of cells, on the same sheet. A first row or column of text "
                + "names the series and categories, as in Excel; a scatter takes its x values from the first column. "
                + "Placed two columns to the right of the data unless `position` says where.",
             properties: properties([
                ("range", ["type": "string", "description": "The data, with its labels, e.g. \"A1:D7\"."]),
                ("type", ["type": "string", "enum": .array(chartKinds)]),
             ] + chartOptions),
             required: ["range", "type"], run: { tools, args in .json(try tools.insertChart(args)) }),
        Tool(name: "update_chart",
             description: "Change a chart: its type, data range, titles, legend, colours, place or size. "
                + "Pass only what should change.",
             properties: properties([
                chartProperty,
                ("type", ["type": "string", "enum": .array(chartKinds)]),
                ("range", ["type": "string", "description": "New data for the chart, e.g. \"A1:E7\"."]),
             ] + chartOptions),
             required: [], run: { tools, args in .json(try tools.updateChart(args)) }),
        Tool(name: "delete_chart",
             description: "Delete a chart.",
             properties: properties([chartProperty]),
             required: ["chart"], run: { tools, args in .json(try tools.deleteChart(args)) }),
    ]

    static let pivotProperty: (String, JSONValue) = ("pivot", [
        "type": "string",
        "description": "The pivot table's name from list_pivot_tables. Default: the only one (on `sheet`, if given).",
    ])

    static let pivotLayoutProperties: [(String, JSONValue)] = [
        ("rows", ["type": "array", "items": ["type": "string"], "description": "Fields (source column headings) down the side."]),
        ("columns", ["type": "array", "items": ["type": "string"], "description": "Fields across the top."]),
        ("filters", ["type": "array", "items": ["type": "string"], "description": "Report filters above the table."]),
        ("values", ["type": "array", "description": .string(
            "What to summarize: a field name (numbers are summed, anything else counted), or {\"field\": …, "
            + "\"summary\": sum|count|average|max|min|product|count_numbers|stddev|stddevp|var|varp, "
            + "\"show_as\": normal|percent_of_total|percent_of_row|percent_of_column, \"name\": …}."),
            "items": ["type": ["string", "object"]]]),
        ("show_items", ["type": "object", "description": .string(
            "Which items of a row, column or filter field to show, as {field: [item, …]} using the item text "
            + "list_pivot_tables gives; null or [] shows them all.")]),
        ("layout", ["type": "string", "enum": ["compact", "outline", "tabular"]]),
        ("row_grand_totals", ["type": "boolean", "description": "A Grand Total row at the bottom."]),
        ("column_grand_totals", ["type": "boolean", "description": "A Grand Total column at the right."]),
        ("replace", ["type": "boolean", "description": "Overwrite cells in the way (default false: refuse)."]),
    ]

    static let pivotTools: [Tool] = [
        Tool(name: "list_pivot_tables",
             description: "List the pivot tables in a document: name, sheet, the cells they cover, source data, the "
                + "fields available and which are on rows, columns, filters and values, and each field's items. "
                + "A pivot table that came from Excel with features SimpleSpread can't recompute is marked not editable.",
             properties: properties([("include_items", ["type": "boolean",
                                                         "description": "List each axis field's items (default true)."])]),
             required: [], run: { tools, args in .json(try tools.listPivotTables(args)) }),
        Tool(name: "create_pivot_table",
             description: "Create a pivot table summarizing a table of data (a heading row, then records), with its "
                + "fields set up in one step. It goes on a new sheet unless `destination` names a cell. The window "
                + "shows it, and selects its first cell.",
             properties: properties([
                ("source", ["type": "string", "description": "The data with its heading row, e.g. \"A1:E200\" or \"Data!A:E\"."]),
                ("destination", ["type": "string", "description": "Top-left cell for the table, e.g. \"Report!B3\". Default: a new sheet."]),
             ] + pivotLayoutProperties),
             required: ["source"], run: { tools, args in .json(try tools.createPivotTable(args)) }),
        Tool(name: "update_pivot_table",
             description: "Change a pivot table's fields, summaries, filters or layout. A list given for rows, "
                + "columns, filters or values replaces what is there; areas not given are kept.",
             properties: properties([pivotProperty] + pivotLayoutProperties),
             required: [], run: { tools, args in .json(try tools.updatePivotTable(args)) }),
        Tool(name: "group_pivot_field",
             description: "Group a field's items, as Excel's Group does: dates by years, quarters, months or days "
                + "(years and quarters become fields of their own, which update_pivot_table can place), or numbers "
                + "into ranges of `interval`. `ungroup` undoes it. Groups apply to every pivot table sharing the data.",
             properties: properties([
                pivotProperty,
                ("field", ["type": "string", "description": "The field to group."]),
                ("dates", ["type": "array", "items": ["type": "string", "enum": ["years", "quarters", "months", "days"]]]),
                ("interval", ["type": "number", "description": "Numbers: the size of each range."]),
                ("start", ["type": "number", "description": "Numbers: where the first range starts (default: the smallest)."]),
                ("end", ["type": "number", "description": "Numbers: where the last range ends (default: the largest)."]),
                ("ungroup", ["type": "boolean"]),
                ("replace", ["type": "boolean", "description": "Overwrite cells in the way (default false: refuse)."]),
             ]),
             required: ["field"], run: { tools, args in .json(try tools.groupPivotField(args)) }),
        Tool(name: "refresh_pivot_tables",
             description: "Recompute pivot tables from their source data, after it changed (they don't follow "
                + "edits by themselves). Default: every pivot table in the document.",
             properties: properties([pivotProperty,
                                     ("replace", ["type": "boolean", "description": "Overwrite cells in the way (default false: refuse)."])]),
             required: [], run: { tools, args in .json(try tools.refreshPivotTables(args)) }),
        Tool(name: "delete_pivot_table",
             description: "Delete a pivot table and clear its cells. Its source data is left alone.",
             properties: properties([pivotProperty]),
             required: ["pivot"], run: { tools, args in .json(try tools.deletePivotTable(args)) }),
    ]

    // MARK: - Charts

    /// The charts on a sheet as they are now.
    func charts(on sheet: Sheet, in doc: SpreadsheetDocument) -> [SheetChart] {
        sheet.id == doc.activeSheetID ? doc.activeCharts : XLSXCharts.charts(in: doc.workbook, sheetID: sheet.id)
    }

    /// The chart `chart` names: on `sheet` when given, else the sheet
    /// showing, then any sheet. Without a name, the only chart there.
    func chart(_ args: Arguments, in doc: SpreadsheetDocument) throws -> (Sheet, SheetChart) {
        let wanted = try args.string("chart")
        let sheets: [Sheet]
        if let name = try args.string("sheet") {
            sheets = [try sheet(named: name, in: doc)]
        } else {
            sheets = [doc.activeSheet] + doc.workbook.sheets.filter { $0.id != doc.activeSheetID }
        }
        guard let wanted else {
            let sheet = sheets[0]
            let all = charts(on: sheet, in: doc)
            guard all.count == 1 else {
                throw ToolError(all.isEmpty ? "\"\(sheet.name)\" has no charts."
                                : "\"\(sheet.name)\" has \(all.count) charts; pass `chart` (see list_charts).")
            }
            return (sheet, all[0])
        }
        for sheet in sheets {
            let all = charts(on: sheet, in: doc)
            if let match = all.first(where: { $0.id == wanted })
                ?? all.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
                return (sheet, match)
            }
        }
        throw ToolError("No chart \"\(wanted)\". list_charts gives the charts on each sheet.")
    }

    static func hex(_ color: RGBAColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }

    static func a1(_ formula: String) -> String { formula.replacingOccurrences(of: "$", with: "") }

    func chartJSON(_ chart: SheetChart, on sheet: Sheet, in doc: SpreadsheetDocument) -> JSONValue {
        let layout = GridLayout(sheet: sheet)
        let frame = SpreadsheetDocument.contentFrame(of: chart, in: layout)
        let corner = CellAddress(row: layout.row(atY: frame.minY), column: layout.column(atX: frame.minX))
        var info: [String: JSONValue] = [
            "id": .string(chart.id), "name": .string(chart.name), "sheet": .string(sheet.name),
            "position": ["cell": .string(corner.a1), "width": .number(Double(frame.width).rounded()),
                         "height": .number(Double(frame.height).rounded())],
            "title": chart.title.map { .string($0) } ?? .null,
        ]
        guard let settings = chart.settings else {
            info["type"] = chart.kind.map { .string($0.rawValue) } ?? .null
            info["editable"] = false
            info["note"] = .string(chart.unsupported.map { "\($0)s aren't drawn here; it can be moved, resized or deleted." }
                ?? "Its series don't all come from cells, so it can only be moved, resized or deleted.")
            return .object(info)
        }
        info["editable"] = true
        info["type"] = .string(settings.kind.rawValue)
        if ChartSettings.stacks(settings.kind) {
            info["grouping"] = switch settings.grouping {
            case .standard: "standard"
            case .stacked: "stacked"
            case .percentStacked: "percent_stacked"
            }
        }
        info["legend"] = settings.legend.map { position in
            switch position {
            case .top: "top"
            case .bottom: "bottom"
            case .left: "left"
            case .right: "right"
            }
        } ?? "none"
        if ChartSettings.hasAxes(settings.kind) {
            info["category_axis_title"] = settings.categoryAxisTitle.map { .string($0) } ?? .null
            info["value_axis_title"] = settings.valueAxisTitle.map { .string($0) } ?? .null
        }
        info["data_labels"] = settings.showsDataLabels.map { .bool($0) } ?? "some series"
        info["data_range"] = settings.dataRange(in: doc.workbook).map { .string(Self.a1($0.formula)) } ?? .null
        info["series"] = .array(settings.series.enumerated().map { i, s in
            var entry: [String: JSONValue] = ["values": .string(Self.a1(s.values))]
            if i < chart.series.count {
                entry["name"] = .string(chart.series[i].name)
                entry["color"] = .string(Self.hex(chart.series[i].color))
            }
            if let categories = s.categories { entry[settings.kind == .scatter ? "x_values" : "categories"] = .string(Self.a1(categories)) }
            return .object(entry)
        })
        return .object(info)
    }

    func listCharts(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let sheet = try self.sheet(named: try args.string("sheet"), in: doc)
        return ["sheet": .string(sheet.name),
                "charts": .array(charts(on: sheet, in: doc).map { chartJSON($0, on: sheet, in: doc) })]
    }

    static func chartKind(_ text: String) throws -> SheetChart.Kind {
        guard let kind = SheetChart.Kind(rawValue: text.lowercased()) else {
            throw ToolError("`type` must be one of column, bar, line, area, pie, doughnut or scatter.")
        }
        return kind
    }

    /// The block of cells `text` names, as Insert ▸ Chart takes it: one cell
    /// stands for the table around it, and whole columns or rows for the
    /// part that holds data.
    func chartBlock(_ text: String, sheetName: String?, in doc: SpreadsheetDocument) throws -> (Sheet, CellRange) {
        let (sheet, requested) = try range(text, sheetName: sheetName, in: doc)
        var block = sheet.expandedForMerges(requested)
        if block.isSingleCell { block = sheet.currentRegion(around: block.start) }
        if let used = sheet.usedRange, let trimmed = SpreadsheetDocument.intersection(block, used) { block = trimmed }
        var numbers = false
        block.forEachAddress { if !numbers, case .number = sheet.value(at: $0) { numbers = true } }
        guard numbers else {
            throw ToolError("\(block.a1) on \"\(sheet.name)\" has no numbers to chart. Pass the table, labels and all.")
        }
        return (sheet, block)
    }

    /// The options every chart edit shares, applied to `settings`.
    func applyChartOptions(_ args: Arguments, to settings: inout ChartSettings) throws {
        if let text = try args.string("grouping") {
            let grouping: SheetChart.Grouping
            switch text {
            case "standard": grouping = .standard
            case "stacked": grouping = .stacked
            case "percent_stacked": grouping = .percentStacked
            default: throw ToolError("`grouping` must be standard, stacked or percent_stacked.")
            }
            guard grouping == .standard || ChartSettings.stacks(settings.kind) else {
                throw ToolError("Only column, bar, line and area charts stack.")
            }
            settings.grouping = grouping
        }
        if let text = try args.string("title") {
            settings.title = text.isEmpty ? .none : text.lowercased() == "auto" ? .automatic : .text(text)
        }
        if let text = try args.string("legend") {
            switch text {
            case "top": settings.legend = .top
            case "bottom": settings.legend = .bottom
            case "left": settings.legend = .left
            case "right": settings.legend = .right
            case "none": settings.legend = nil
            default: throw ToolError("`legend` must be top, bottom, left, right or none.")
            }
        }
        if let text = try args.string("category_axis_title") { settings.categoryAxisTitle = text.isEmpty ? nil : text }
        if let text = try args.string("value_axis_title") { settings.valueAxisTitle = text.isEmpty ? nil : text }
        if let on = try args.bool("data_labels") { settings.showsDataLabels = on }
        if let colors = args.raw("colors") {
            guard let list = colors.arrayValue else { throw ToolError("`colors` must be an array of \"#RRGGBB\".") }
            guard list.count <= settings.series.count else {
                throw ToolError("`colors` has \(list.count) colours for \(settings.series.count) series.")
            }
            for (i, value) in list.enumerated() where !value.isNull {
                guard let text = value.stringValue, let color = try Self.color(text, key: "colors") else {
                    throw ToolError("`colors` must be \"#RRGGBB\" (or null to keep one).")
                }
                settings.series[i].color = .rgb(color)
            }
        }
    }

    func seriesInRows(_ args: Arguments) throws -> Bool? {
        guard let text = try args.string("series_in") else { return nil }
        guard text == "rows" || text == "columns" else { throw ToolError("`series_in` must be columns or rows.") }
        return text == "rows"
    }

    /// The frame `position`, `width` and `height` ask for, from `frame`.
    func chartFrame(_ args: Arguments, from frame: CGRect, layout: GridLayout) throws -> CGRect {
        var frame = frame
        if let text = try args.string("position") {
            guard let cell = CellAddress(a1: text.replacingOccurrences(of: "$", with: "")), cell.isValid else {
                throw ToolError("`position` must be a cell, e.g. \"F2\".")
            }
            frame.origin = CGPoint(x: layout.xOffset(ofColumn: cell.column), y: layout.yOffset(ofRow: cell.row))
        }
        for (key, keyPath) in [("width", \CGSize.width), ("height", \CGSize.height)] {
            guard let n = try args.number(key) else { continue }
            guard (40...4000).contains(n) else { throw ToolError("`\(key)` must be 40 to 4000 points.") }
            frame.size[keyPath: keyPath] = CGFloat(n)
        }
        return frame
    }

    func insertChart(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let kind = try Self.chartKind(try args.requiredString("type"))
        let (sheet, block) = try chartBlock(try args.requiredString("range"), sheetName: try args.string("sheet"), in: doc)
        let data = ChartRange(sheetName: sheet.name, range: block)
        var settings = ChartSettings.new(kind, from: data, in: doc.workbook)
        if let inRows = try seriesInRows(args) {
            settings.series = ChartSettings.series(from: data, in: doc.workbook, kind: kind, inRows: inRows)
        }
        guard !settings.series.isEmpty else { throw ToolError("\(block.a1) has no series to chart.") }
        try applyChartOptions(args, to: &settings)
        // Excel's default size, to the right of the data (as Insert ▸ Chart).
        let layout = GridLayout(sheet: sheet)
        let fallback = CGRect(x: layout.xOffset(ofColumn: block.end.column + 2), y: layout.yOffset(ofRow: block.start.row),
                              width: 480, height: 288)
        let placement = SpreadsheetDocument.placement(for: try chartFrame(args, from: fallback, layout: layout), in: layout)
        activate(sheet, in: doc)
        var id: String?
        try edit(doc) {
            doc.changeCharts(actionName: "Agent Insert Chart") {
                id = XLSXChartEditor.insert(settings, onSheet: sheet.id, from: placement.from, to: placement.to,
                                            in: doc.workbook)
                return id != nil
            }
        }
        guard let id, let chart = doc.activeCharts.first(where: { $0.id == id }) else {
            throw ToolError("Couldn't insert the chart.")
        }
        return chartJSON(chart, on: sheet, in: doc)
    }

    func updateChart(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let (sheet, chart) = try self.chart(args, in: doc)
        var settings = chart.settings
        let changesSettings = ["type", "range", "series_in", "grouping", "title", "legend", "category_axis_title",
                                   "value_axis_title", "data_labels", "colors"].contains { key in
            args.raw(key) != nil
        }
        if changesSettings {
            guard var s = settings else {
                throw ToolError("“\(chart.name)” can only be moved, resized or deleted: "
                    + (chart.unsupported.map { "\($0)s aren't drawn here." } ?? "its series don't all come from cells."))
            }
            if let text = try args.string("type") {
                // As the Chart panel changes type.
                s.kind = try Self.chartKind(text)
                if s.kind == .pie || s.kind == .doughnut { s.series = Array(s.series.prefix(1)) }
                if !ChartSettings.stacks(s.kind) { s.grouping = .standard }
            }
            let inRows = try seriesInRows(args)
            if args.raw("range") != nil || inRows != nil {
                let block: ChartRange
                if let text = try args.string("range") {
                    let (dataSheet, cells) = try chartBlock(text, sheetName: sheet.name, in: doc)
                    block = ChartRange(sheetName: dataSheet.name, range: cells)
                } else {
                    guard let current = s.dataRange(in: doc.workbook) else {
                        throw ToolError("“\(chart.name)” has no single data range to turn; pass `range` as well.")
                    }
                    block = current
                }
                let series = ChartSettings.series(from: block, in: doc.workbook, kind: s.kind,
                                                  inRows: inRows ?? (s.series.count > 1 ? s.seriesInRows(in: doc.workbook) : nil))
                guard !series.isEmpty else { throw ToolError("\(Self.a1(block.formula)) has no series to chart.") }
                // Colours stay with their series' positions, as in the panel.
                let colors = s.series.map(\.color)
                s.series = series.enumerated().map { i, new in
                    var new = new
                    if i < colors.count { new.color = colors[i] }
                    return new
                }
            }
            try applyChartOptions(args, to: &s)
            settings = s
        }
        let layout = GridLayout(sheet: sheet)
        let frame = SpreadsheetDocument.anchorFrame(of: chart, in: layout)
        let newFrame = try chartFrame(args, from: frame, layout: layout)
        let moves = newFrame != frame
        let changes = settings != chart.settings
        guard moves || changes else { return chartJSON(chart, on: sheet, in: doc) }
        activate(sheet, in: doc)
        // Not folded into the user's last chart edit (the panel joins a run of them).
        doc.chartState.lastEdit = nil
        try edit(doc, "Agent Change Chart") {
            if changes, let settings { doc.updateChart(chart.id, to: settings) }
            if moves { doc.placeChart(chart.id, frame: newFrame) }
        }
        doc.chartState.lastEdit = nil
        guard let updated = doc.activeCharts.first(where: { $0.id == chart.id }) else {
            throw ToolError("Couldn't change “\(chart.name)”.")
        }
        return chartJSON(updated, on: sheet, in: doc)
    }

    func deleteChart(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let (sheet, chart) = try self.chart(args, in: doc)
        activate(sheet, in: doc)
        try edit(doc) {
            doc.changeCharts(actionName: "Agent Delete Chart") {
                XLSXChartEditor.delete(chart.id, onSheet: sheet.id, in: doc.workbook)
            }
        }
        if doc.selectedChartID == chart.id { doc.selectChart(nil) }
        return ["deleted": .string(chart.name), "sheet": .string(sheet.name)]
    }

    // MARK: - Pivot tables

    /// The pivot table `pivot` names (on `sheet`, when given); without a
    /// name, the only one.
    func pivot(_ args: Arguments, in doc: SpreadsheetDocument) throws -> Int {
        let tables = doc.workbook.pivotTables
        var candidates = Array(tables.indices)
        if let name = try args.string("sheet") {
            let sheet = try self.sheet(named: name, in: doc)
            candidates = candidates.filter { tables[$0].sheetID == sheet.id }
        }
        guard let wanted = try args.string("pivot") else {
            guard candidates.count == 1 else {
                throw ToolError(candidates.isEmpty ? "There are no pivot tables here."
                                : "There are \(candidates.count) pivot tables; pass `pivot` (see list_pivot_tables).")
            }
            return candidates[0]
        }
        let matches = candidates.filter { tables[$0].name.caseInsensitiveCompare(wanted) == .orderedSame }
        guard let first = matches.first else {
            let names = candidates.map { "“\(tables[$0].name)”" }.joined(separator: ", ")
            throw ToolError("No pivot table \"\(wanted)\"." + (names.isEmpty ? "" : " Pivot tables: \(names)."))
        }
        guard matches.count == 1 else { throw ToolError("More than one pivot table is named \"\(wanted)\"; pass `sheet` too.") }
        return first
    }

    static let summaries: [(String, PivotSubtotal)] = [
        ("sum", .sum), ("count", .count), ("average", .average), ("max", .max), ("min", .min), ("product", .product),
        ("count_numbers", .countNums), ("stddev", .stdDev), ("stddevp", .stdDevp), ("var", .var), ("varp", .varp),
    ]
    static let showAs: [(String, PivotShowDataAs)] = [
        ("normal", .normal), ("percent_of_total", .percentOfTotal), ("percent_of_row", .percentOfRow),
        ("percent_of_column", .percentOfCol),
    ]

    /// An item's text as the filter checklist shows it.
    static func itemLabel(_ item: PivotItem, field f: Int, cache: PivotCacheData) -> String? {
        let values = cache.fields[f].axisItems
        guard item.kind == .data, let x = item.index, x < values.count else { return nil }
        if let name = item.name { return name }
        switch values[x] {
        case .missing: return "(blank)"
        case .date(let n): return NumberFormatEngine.displayString(for: .number(n), format: cache.fields[f].numberFormat)
        default: return values[x].cellValue.rawDisplayString
        }
    }

    func pivotJSON(_ index: Int, in doc: SpreadsheetDocument, items: Bool) -> JSONValue {
        let workbook = doc.workbook
        let table = workbook.pivotTables[index]
        var info: [String: JSONValue] = [
            "name": .string(table.name),
            "sheet": .string(workbook.sheet(withID: table.sheetID)?.name ?? ""),
            "range": .string(table.occupiedRange.a1),
        ]
        let cache = workbook.pivotCache(withID: table.cacheID)
        if let source = cache?.sourceRanges.first {
            switch source.target {
            case .sheet(let id):
                let name = workbook.sheet(withID: id).map { ReferenceExpr.quoteSheetNameIfNeeded($0.name) + "!" } ?? ""
                info["source"] = .string(name + Self.a1(source.ref))
            case .detached(let sheetName):
                info["source"] = .string("\(sheetName)!\(Self.a1(source.ref)) (no longer in this workbook)")
            case .external:
                info["source"] = "another workbook"
            }
        }
        if let blocker = doc.pivotEditBlocker(index) {
            info["editable"] = false
            info["note"] = .string("It came from Excel, and \(blocker); SimpleSpread keeps it intact but can't change it.")
            return .object(info)
        }
        guard let d = table.definition, let data = cache?.data else { return .object(info) }
        info["editable"] = true
        func name(_ f: Int) -> JSONValue { .string(data.fields[f].name) }
        info["fields"] = .array(data.fields.indices.map(name))
        info["rows"] = .array(d.rowFields.filter { $0 >= 0 }.map(name))
        info["columns"] = .array(d.columnFields.filter { $0 >= 0 }.map(name))
        info["filters"] = .array(d.pageFields.map { page in
            var entry: [String: JSONValue] = ["field": name(page.field)]
            if let s = page.selectedItem, d.fields[page.field].items.indices.contains(s),
               let label = Self.itemLabel(d.fields[page.field].items[s], field: page.field, cache: data) {
                entry["selected"] = .string(label)
            }
            return .object(entry)
        })
        info["values"] = .array(d.dataFields.map { v in
            ["name": .string(v.name), "field": name(v.field),
             "summary": .string(Self.summaries.first { $0.1 == v.subtotal }?.0 ?? v.subtotal.rawValue),
             "show_as": .string(Self.showAs.first { $0.1 == v.showDataAs }?.0 ?? v.showDataAs.rawValue)]
        })
        info["layout"] = d.form.map { .string($0.rawValue) } ?? "mixed"
        info["row_grand_totals"] = .bool(d.layout.rowGrandTotals)
        info["column_grand_totals"] = .bool(d.layout.colGrandTotals)
        if items {
            var list: [String: JSONValue] = [:]
            for f in d.rowFields + d.columnFields + d.pageFields.map(\.field) where f >= 0 {
                let entries = d.fields[f].items.compactMap { item -> JSONValue? in
                    guard let label = Self.itemLabel(item, field: f, cache: data) else { return nil }
                    return item.hidden ? ["item": .string(label), "hidden": true] : .string(label)
                }
                list[data.fields[f].name] = .array(Array(entries.prefix(200)))
            }
            info["items"] = .object(list)
        }
        return .object(info)
    }

    func listPivotTables(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        var indices = Array(doc.workbook.pivotTables.indices)
        if let name = try args.string("sheet") {
            let sheet = try self.sheet(named: name, in: doc)
            indices = indices.filter { doc.workbook.pivotTables[$0].sheetID == sheet.id }
        }
        let items = try args.bool("include_items") ?? true
        return ["pivot_tables": .array(indices.map { pivotJSON($0, in: doc, items: items) })]
    }

    /// Lay out `d` as the arguments say: each area given replaces what is
    /// there, then items, layout and totals. Throws before changing `d` when
    /// a field or option isn't right.
    func arrangePivot(_ args: Arguments, _ d: inout PivotDefinition, cache: PivotCacheData) throws {
        func field(_ name: String) throws -> Int {
            if let f = cache.fields.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return f }
            let names = cache.fields.map { "\"\($0.name)\"" }.joined(separator: ", ")
            throw ToolError("No field \"\(name)\". Fields: \(names).")
        }
        func names(_ key: String) throws -> [Int]? {
            guard let value = args.raw(key) else { return nil }
            guard let list = value.arrayValue else { throw ToolError("`\(key)` must be an array of field names.") }
            return try list.map {
                guard let s = $0.stringValue else { throw ToolError("`\(key)` must be an array of field names.") }
                return try field(s)
            }
        }
        struct Value { var field: Int; var summary: PivotSubtotal?; var showAs: PivotShowDataAs?; var name: String? }
        var values: [Value]?
        if let raw = args.raw("values") {
            guard let list = raw.arrayValue else { throw ToolError("`values` must be an array.") }
            values = try list.map { entry in
                if let s = entry.stringValue { return Value(field: try field(s)) }
                guard let s = entry["field"]?.stringValue else {
                    throw ToolError("Each of `values` is a field name or {\"field\": …, \"summary\": …}.")
                }
                var v = Value(field: try field(s))
                if let text = entry["summary"]?.stringValue {
                    guard let match = Self.summaries.first(where: { $0.0 == text.lowercased() }) else {
                        throw ToolError("`summary` must be one of " + Self.summaries.map(\.0).joined(separator: ", ") + ".")
                    }
                    v.summary = match.1
                }
                if let text = entry["show_as"]?.stringValue {
                    guard let match = Self.showAs.first(where: { $0.0 == text.lowercased() }) else {
                        throw ToolError("`show_as` must be one of " + Self.showAs.map(\.0).joined(separator: ", ") + ".")
                    }
                    v.showAs = match.1
                }
                v.name = entry["name"]?.stringValue
                return v
            }
        }
        let rows = try names("rows"), columns = try names("columns"), filters = try names("filters")
        let placed = (rows ?? []) + (columns ?? []) + (filters ?? [])
        if let repeated = placed.first(where: { f in placed.filter { $0 == f }.count > 1 }) {
            throw ToolError("\"\(cache.fields[repeated].name)\" can go in only one of rows, columns and filters.")
        }
        var form: PivotForm?
        if let text = try args.string("layout") {
            guard let f = PivotForm(rawValue: text) else { throw ToolError("`layout` must be compact, outline or tabular.") }
            form = f
        }

        var new = d
        for (list, area) in [(rows, PivotArea.rows), (columns, .columns), (filters, .filters)] where list != nil {
            for f in new.fields(in: area) where f >= 0 { new.removeFromAxes(f) }
        }
        for (list, area) in [(rows, PivotArea.rows), (columns, .columns), (filters, .filters)] {
            for f in list ?? [] { new.place(field: f, in: area, cache: cache) }
        }
        if let values {
            while !new.dataFields.isEmpty { new.removeDataField(at: new.dataFields.count - 1) }
            for v in values {
                new.addDataField(field: v.field, cache: cache)
                let i = new.dataFields.count - 1
                if let summary = v.summary { new.setSubtotal(summary, forDataField: i, cache: cache) }
                if let showAs = v.showAs { new.setShowDataAs(showAs, forDataField: i) }
                if let name = v.name, !new.renameDataField(at: i, to: name) {
                    throw ToolError("Value names must be unique and not blank: \"\(name)\".")
                }
            }
        }
        if let raw = args.raw("show_items") {
            guard case .object(let fields) = raw else { throw ToolError("`show_items` must be {field: [item, …]}.") }
            for (key, wanted) in fields.sorted(by: { $0.key < $1.key }) {
                let f = try field(key)
                guard new.axisArea(of: f) != nil else {
                    throw ToolError("\"\(cache.fields[f].name)\" isn't on rows, columns or filters, so it has no items to show.")
                }
                let labels = new.fields[f].items.enumerated().compactMap { p, item in
                    Self.itemLabel(item, field: f, cache: cache).map { (p, $0) }
                }
                guard let list = wanted.arrayValue, !list.isEmpty else {
                    new.setVisibleItems(field: f, positions: Set(labels.map(\.0)))
                    continue
                }
                var visible = Set<Int>()
                for value in list {
                    let text = value.stringValue ?? value.numberValue.map { NumberFormatEngine.roundTripString(for: $0) } ?? ""
                    let matches = labels.filter { $0.1.caseInsensitiveCompare(text) == .orderedSame }.map(\.0)
                    guard !matches.isEmpty else {
                        let known = labels.prefix(30).map { "\"\($0.1)\"" }.joined(separator: ", ")
                        throw ToolError("\"\(cache.fields[f].name)\" has no item \"\(text)\". Items: \(known)\(labels.count > 30 ? "…" : "").")
                    }
                    visible.formUnion(matches)
                }
                new.setVisibleItems(field: f, positions: visible)
            }
        }
        if let form { new.setForm(form) }
        if let on = try args.bool("row_grand_totals") { new.layout.rowGrandTotals = on }
        if let on = try args.bool("column_grand_totals") { new.layout.colGrandTotals = on }
        d = new
    }

    func createPivotTable(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let (sourceSheet, requested) = try range(try args.requiredString("source"), sheetName: try args.string("sheet"), in: doc)
        // Whole columns: down to the last row with data.
        var source = requested
        if let used = sourceSheet.usedRange, let trimmed = SpreadsheetDocument.intersection(requested, used) { source = trimmed }
        guard source.rowCount >= 2 else {
            throw ToolError("\(source.a1) needs a heading row and at least one row of data.")
        }
        var destination = PivotDestination.newSheet
        if let text = try args.string("destination") {
            let (sheet, cells) = try range(text, sheetName: nil, in: doc)
            destination = .existing(sheetID: sheet.id, at: cells.start)
        }
        let replace = try args.bool("replace") ?? false
        // Check the arguments before anything changes (the real run lays out
        // the table the document builds).
        if let data = try? PivotCacheBuilder.build(sheet: sourceSheet, range: source, workbook: doc.workbook) {
            var probe = PivotDefinition.new(name: "probe", cache: data)
            try arrangePivot(args, &probe, cache: data)
        }
        let before = doc.workbook.pivotTables.count
        activate(sourceSheet, in: doc)
        try edit(doc, replace: replace) {
            doc.insertPivotTable(source: source, destination: destination, actionName: "Agent Insert PivotTable") { d, data in
                try self.arrangePivot(args, &d, cache: data)
            }
        }
        guard doc.workbook.pivotTables.count > before else { throw ToolError("Couldn't create the pivot table.") }
        return pivotJSON(doc.workbook.pivotTables.count - 1, in: doc, items: false)
    }

    func updatePivotTable(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let index = try pivot(args, in: doc)
        let table = doc.workbook.pivotTables[index]
        if let blocker = doc.pivotEditBlocker(index) {
            throw ToolError("“\(table.name)” came from Excel, and \(blocker); SimpleSpread keeps it intact but can't change it.")
        }
        guard var definition = table.definition, let data = doc.workbook.pivotCache(withID: table.cacheID)?.data else {
            throw ToolError("SimpleSpread couldn't read “\(table.name)”.")
        }
        try arrangePivot(args, &definition, cache: data)
        if definition != table.definition, let sheet = doc.workbook.sheet(withID: table.sheetID) {
            activate(sheet, in: doc)
            let arranged = definition
            try edit(doc, replace: try args.bool("replace") ?? false) {
                doc.editPivot(index, actionName: "Agent Change PivotTable") { d, _ in d = arranged }
            }
        }
        return pivotJSON(index, in: doc, items: false)
    }

    func groupPivotField(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let index = try pivot(args, in: doc)
        let table = doc.workbook.pivotTables[index]
        guard let data = doc.workbook.pivotCache(withID: table.cacheID)?.data else {
            throw ToolError("SimpleSpread couldn't read “\(table.name)”.")
        }
        let name = try args.requiredString("field")
        guard let f = data.fields.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ToolError("No field \"\(name)\". Fields: " + data.fields.map { "\"\($0.name)\"" }.joined(separator: ", ") + ".")
        }
        let change: (Workbook) throws -> Void
        if try args.bool("ungroup") == true {
            // A Years or Quarters field ungroups the date field it came from.
            let base = data.fields[f].isDatabaseField ? f : (data.fields[f].group?.base ?? f)
            guard data.fields[base].group != nil || data.fields.contains(where: { $0.group?.base == base }) else {
                throw ToolError("\"\(name)\" isn't grouped.")
            }
            change = { try $0.ungroupPivotField(table: index, field: base) }
        } else if let list = args.raw("dates") {
            let levels = try (list.arrayValue ?? []).map { value -> PivotDateGrouping in
                guard let level = value.stringValue.flatMap(PivotDateGrouping.init(rawValue:)) else {
                    throw ToolError("`dates` must list years, quarters, months or days.")
                }
                return level
            }
            guard !levels.isEmpty else { throw ToolError("`dates` must list years, quarters, months or days.") }
            change = { try $0.groupPivotField(table: index, field: f, byDates: Set(levels)) }
        } else if let interval = try args.number("interval") {
            guard interval > 0 else { throw ToolError("`interval` must be more than 0.") }
            let start = try args.number("start"), end = try args.number("end")
            change = { try $0.groupPivotField(table: index, field: f, interval: interval, start: start, end: end) }
        } else {
            throw ToolError("Pass `dates`, `interval` or `ungroup`.")
        }
        if let sheet = doc.workbook.sheet(withID: table.sheetID) { activate(sheet, in: doc) }
        try edit(doc, replace: try args.bool("replace") ?? false) {
            doc.regroupPivot(index, actionName: "Agent Group", change)
        }
        return pivotJSON(index, in: doc, items: true)
    }

    func refreshPivotTables(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let replace = try args.bool("replace") ?? false
        if args.raw("pivot") != nil || args.raw("sheet") != nil || doc.workbook.pivotTables.count == 1 {
            let index = try pivot(args, in: doc)
            try edit(doc, replace: replace) { doc.refreshPivot(index) }
            return ["refreshed": [.string(doc.workbook.pivotTables[index].name)]]
        }
        guard !doc.workbook.pivotTables.isEmpty else { throw ToolError("This document has no pivot tables.") }
        try edit(doc, replace: replace) { doc.refreshAllPivots() }
        let names = doc.workbook.pivotTables.indices.filter { doc.pivotEditBlocker($0) == nil }
            .map { JSONValue.string(doc.workbook.pivotTables[$0].name) }
        return ["refreshed": .array(names)]
    }

    func deletePivotTable(_ args: Arguments) throws -> JSONValue {
        let doc = try document(args).document
        let index = try pivot(args, in: doc)
        let table = doc.workbook.pivotTables[index]
        let sheet = doc.workbook.sheet(withID: table.sheetID)
        if let sheet { activate(sheet, in: doc) }
        try edit(doc) { doc.deletePivotTable(index, actionName: "Agent Delete PivotTable") }
        return ["deleted": .string(table.name), "sheet": .string(sheet?.name ?? ""), "cleared": .string(table.occupiedRange.a1)]
    }
}
#endif
