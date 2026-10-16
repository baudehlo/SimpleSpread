import Foundation
import SpreadsheetCore

/// What a chart shows and how, as the chart panel edits it: read from a
/// chart part (SheetChart.settings) and written back (XLSXChartEditor).
public struct ChartSettings: Hashable, Sendable {
    public enum Title: Hashable, Sendable {
        /// Excel's own: the series name for one series, else "Chart Title".
        case automatic
        case none
        case text(String)
    }

    public var kind: SheetChart.Kind
    public var grouping: SheetChart.Grouping
    public var title: Title
    public var legend: SheetChart.LegendPosition?
    public var categoryAxisTitle: String?
    public var valueAxisTitle: String?
    /// Values shown beside the points: nil when some series show them and
    /// others don't.
    public var showsDataLabels: Bool?
    public var series: [ChartSeriesSource]

    public init(kind: SheetChart.Kind, grouping: SheetChart.Grouping = .standard, title: Title = .automatic,
                legend: SheetChart.LegendPosition? = .bottom, categoryAxisTitle: String? = nil,
                valueAxisTitle: String? = nil, showsDataLabels: Bool? = false, series: [ChartSeriesSource] = []) {
        self.kind = kind
        self.grouping = grouping
        self.title = title
        self.legend = legend
        self.categoryAxisTitle = categoryAxisTitle
        self.valueAxisTitle = valueAxisTitle
        self.showsDataLabels = showsDataLabels
        self.series = series
    }

    /// Whether `kind` has axes (pie and doughnut don't).
    public static func hasAxes(_ kind: SheetChart.Kind) -> Bool { kind != .pie && kind != .doughnut }

    /// Whether `kind` can be stacked.
    public static func stacks(_ kind: SheetChart.Kind) -> Bool {
        kind == .column || kind == .bar || kind == .line || kind == .area
    }

    /// Every series' kind: its own (a combination chart), or the chart's.
    func kind(of series: ChartSeriesSource) -> SheetChart.Kind {
        // Pie, doughnut and scatter don't combine with the others.
        guard let own = series.kind, Self.hasAxes(kind), kind != .scatter, own != .scatter,
              Self.hasAxes(own) else { return kind }
        return own
    }
}

/// Where a series' name, categories (a scatter's x values) and values come
/// from, and its colour.
public struct ChartSeriesSource: Hashable, Sendable {
    public enum Name: Hashable, Sendable {
        /// A cell: `Sheet1!$B$1`.
        case reference(String)
        case text(String)
    }

    public enum Color: Hashable, Sendable {
        /// accent1…accent6 of the theme (1-based).
        case accent(Int)
        case rgb(RGBAColor)
    }

    public var name: Name?
    /// A reference formula (`Sheet1!$A$2:$A$7`), without the `=`.
    public var categories: String?
    public var values: String
    /// nil: the theme's accent for the series' position.
    public var color: Color?
    /// In a combination chart, the series' own kind (nil: the chart's).
    public var kind: SheetChart.Kind?

    public init(name: Name? = nil, categories: String? = nil, values: String, color: Color? = nil,
                kind: SheetChart.Kind? = nil) {
        self.name = name
        self.categories = categories
        self.values = values
        self.color = color
        self.kind = kind
    }
}

// MARK: - Ranges

/// A reference to a block of cells on a named sheet, as chart formulas write it.
public struct ChartRange: Hashable, Sendable {
    public var sheetName: String
    public var range: CellRange

    public init(sheetName: String, range: CellRange) {
        self.sheetName = sheetName
        self.range = range
    }

    /// `Sheet1!$A$1:$B$4` (a leading `=` is allowed); nil for anything else.
    public init?(formula: String) {
        var text = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("=") { text.removeFirst() }
        guard case .reference(let ref)? = try? FormulaParser.parse(text), let sheet = ref.sheetName,
              let r1 = ref.start.row, let c1 = ref.start.column else { return nil }
        let end = ref.end ?? ref.start
        guard let r2 = end.row, let c2 = end.column else { return nil }
        self.init(sheetName: sheet, range: CellRange(start: CellAddress(row: min(r1, r2), column: min(c1, c2)),
                                                     end: CellAddress(row: max(r1, r2), column: max(c1, c2))))
    }

    /// Absolute, as Excel writes series references.
    public var formula: String {
        func absolute(_ a: CellAddress) -> String { "$" + CellAddress.columnName(a.column) + "$" + String(a.row + 1) }
        let cells = range.isSingleCell ? absolute(range.start) : absolute(range.start) + ":" + absolute(range.end)
        return ReferenceExpr.quoteSheetNameIfNeeded(sheetName) + "!" + cells
    }
}

extension ChartSettings {
    /// The block of cells the series come from (what the panel shows as
    /// the data range): all of their references, followed as the chart
    /// reads them (a defined name stands for its cells), when they're on
    /// one sheet. Nil when one can't be followed or they're spread about.
    public func dataRange(in workbook: Workbook) -> ChartRange? {
        var ranges: [ChartRange] = []
        func add(_ formula: String) -> Bool {
            guard let areas = ChartReference(formula, in: workbook).areas else { return false }
            ranges += areas
            return true
        }
        for s in series {
            if case .reference(let f)? = s.name { guard add(f) else { return nil } }
            if let f = s.categories { guard add(f) else { return nil } }
            guard add(s.values) else { return nil }
        }
        guard let first = ranges.first, ranges.allSatisfy({ $0.sheetName == first.sheetName }) else { return nil }
        return ChartRange(sheetName: first.sheetName, range: ranges.dropFirst().reduce(first.range) { $0.union($1.range) })
    }

    /// Whether the series run along rows (each series' values one row).
    public func seriesInRows(in workbook: Workbook) -> Bool {
        guard let first = series.first, let r = ChartReference(first.values, in: workbook).areas?.first else { return false }
        return r.range.rowCount == 1 && r.range.columnCount > 1
    }

    /// Series made from a block of cells the way Excel's Insert Chart makes
    /// them: a first row of text is the series names, a first column of
    /// text (or both, when the corner is blank) the categories; series run
    /// down the columns unless there are more columns than rows (or
    /// `inRows` says otherwise). A scatter takes its x values from the
    /// first column. Pie and doughnut take the first series only.
    public static func series(from block: ChartRange, in workbook: Workbook, kind: SheetChart.Kind,
                              inRows: Bool? = nil) -> [ChartSeriesSource] {
        guard let sheet = workbook.sheet(named: block.sheetName) else { return [] }
        let r = block.range
        func value(_ row: Int, _ column: Int) -> CellValue { sheet.value(at: CellAddress(row: row, column: column)) }
        func isNumber(_ v: CellValue) -> Bool { if case .number = v { return true }; return false }
        func isText(_ v: CellValue) -> Bool { if case .string = v { return true }; return false }

        let corner = value(r.start.row, r.start.column)
        var headerRow = false, headerColumn = false
        if r.rowCount > 1 {
            let cells = (r.start.column...r.end.column).dropFirst().map { value(r.start.row, $0) }
            headerRow = !cells.contains(where: isNumber) && cells.contains(where: isText)
        }
        if r.columnCount > 1 {
            let cells = (r.start.row...r.end.row).dropFirst().map { value($0, r.start.column) }
            headerColumn = !cells.contains(where: isNumber) && cells.contains(where: isText)
        }
        if corner.isEmpty, r.rowCount > 1, r.columnCount > 1 { headerRow = true; headerColumn = true }
        // With a header row of text, a text corner labels the categories column.
        if headerRow, isText(corner), r.columnCount > 1, !headerColumn {
            let below = (r.start.row...r.end.row).dropFirst().map { value($0, r.start.column) }
            headerColumn = !below.contains(where: isNumber)
        }

        let dataRows = (r.start.row + (headerRow ? 1 : 0))...r.end.row
        let dataColumns = (r.start.column + (headerColumn ? 1 : 0))...r.end.column
        guard !dataRows.isEmpty, !dataColumns.isEmpty else { return [] }
        let rows = inRows ?? (dataColumns.count > dataRows.count)

        func ref(_ rows: ClosedRange<Int>, _ columns: ClosedRange<Int>) -> String {
            ChartRange(sheetName: block.sheetName, range: CellRange(
                start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
                end: CellAddress(row: rows.upperBound, column: columns.upperBound))).formula
        }
        var result: [ChartSeriesSource] = []
        if !rows {
            var columns = Array(dataColumns)
            var categories = headerColumn ? ref(dataRows, r.start.column...r.start.column) : nil
            // A scatter's x values: the first column, when nothing else gives them.
            if kind == .scatter, categories == nil, columns.count > 1 {
                categories = ref(dataRows, columns[0]...columns[0])
                columns.removeFirst()
            }
            for column in columns {
                let name: ChartSeriesSource.Name = headerRow
                    ? .reference(ref(r.start.row...r.start.row, column...column)) : .text("Series\(result.count + 1)")
                result.append(ChartSeriesSource(name: name, categories: categories, values: ref(dataRows, column...column)))
            }
        } else {
            var rowList = Array(dataRows)
            var categories = headerRow ? ref(r.start.row...r.start.row, dataColumns) : nil
            if kind == .scatter, categories == nil, rowList.count > 1 {
                categories = ref(rowList[0]...rowList[0], dataColumns)
                rowList.removeFirst()
            }
            for row in rowList {
                let name: ChartSeriesSource.Name = headerColumn
                    ? .reference(ref(row...row, r.start.column...r.start.column)) : .text("Series\(result.count + 1)")
                result.append(ChartSeriesSource(name: name, categories: categories, values: ref(row...row, dataColumns)))
            }
        }
        if kind == .pie || kind == .doughnut { result = Array(result.prefix(1)) }
        return result
    }

    /// Settings for a new chart of `kind` over `block`, as Excel's Insert
    /// makes it: an automatic title, a legend below (none for one series
    /// of columns, bars, lines or areas, where the title names it).
    public static func new(_ kind: SheetChart.Kind, grouping: SheetChart.Grouping = .standard, from block: ChartRange,
                           in workbook: Workbook) -> ChartSettings {
        let series = series(from: block, in: workbook, kind: kind)
        let oneSeriesWithAxes = series.count == 1 && hasAxes(kind)
        return ChartSettings(kind: kind, grouping: grouping, title: .automatic,
                             legend: oneSeriesWithAxes ? nil : .bottom, series: series)
    }
}
