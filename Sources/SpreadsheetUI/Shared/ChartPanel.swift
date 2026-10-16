import SpreadsheetCore
import SpreadsheetFiles
import SwiftUI

/// The Chart panel, beside the grid while a chart is selected: its type
/// and stacking, data range, titles, legend, data labels and series
/// colours. Every change applies at once and is one undo step (a run of
/// colour changes is one).
struct ChartPanel: View {
    @ObservedObject var document: SpreadsheetDocument
    let chart: SheetChart
    @State private var dataRangeError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let settings = chart.settings {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        typeSection(settings)
                        dataSection(settings)
                        labelsSection(settings)
                        if !Self.isPie(settings.kind) { colorSection(settings) }
                    }
                    .padding(12)
                }
            } else {
                Text("SimpleSpread can’t change \(chart.unsupported.map { "a \($0.lowercased())" } ?? "this chart"). You can move, resize or delete it, and it’s saved as it was.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            }
            Divider()
            Button(role: .destructive) {
                document.deleteChart(chart.id)
            } label: {
                Label("Delete Chart", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 290)
        .background(Color.windowBackground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chart").font(.headline)
                Text(chart.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                document.isChartPanelVisible = false
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .tip("Hide the Chart panel")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    // MARK: Sections

    private func typeSection(_ settings: ChartSettings) -> some View {
        section("Type") {
            Picker("Type", selection: binding(\.kind, settings, action: "Change Chart Type")) {
                ForEach(Self.kinds, id: \.kind) { choice in
                    Label(choice.name, systemImage: choice.symbol).tag(choice.kind)
                }
            }
            .labelsHidden()
            if ChartSettings.stacks(settings.kind) {
                Picker("Stacking", selection: binding(\.grouping, settings, action: "Change Chart Stacking")) {
                    Text(settings.kind == .column || settings.kind == .bar ? "Clustered" : "Standard")
                        .tag(SheetChart.Grouping.standard)
                    Text("Stacked").tag(SheetChart.Grouping.stacked)
                    Text("100%").tag(SheetChart.Grouping.percentStacked)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func dataSection(_ settings: ChartSettings) -> some View {
        let range = settings.dataRange(in: document.workbook)
        let inRows = settings.seriesInRows(in: document.workbook)
        return section("Data") {
            CommitField(placeholder: "Sheet1!A1:D7", value: range.map { "=" + $0.formula } ?? "") { text in
                dataRangeError = !document.setChartData(chart.id, range: text)
            }
            if dataRangeError {
                Text("Type a range of cells, such as A1:D7 or Sheet1!A1:D7.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if settings.series.count > 1 || inRows || !Self.isPie(settings.kind) {
                Picker("Series in", selection: Binding(
                    get: { inRows },
                    set: { inRows in
                        if let range {
                            _ = document.setChartData(chart.id, range: range.formula, inRows: inRows)
                        }
                    })) {
                    Text("Columns").tag(false)
                    Text("Rows").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(range == nil)
            }
        }
    }

    private func labelsSection(_ settings: ChartSettings) -> some View {
        section("Labels") {
            LabeledContent("Title") { Picker("Title", selection: Binding(
                get: { TitleChoice(settings.title) },
                set: { choice in
                    var s = settings
                    switch choice {
                    case .automatic: s.title = .automatic
                    case .none: s.title = .none
                    case .custom: s.title = .text(chart.title ?? "Chart Title")
                    }
                    document.updateChart(chart.id, to: s, actionName: "Change Chart Title")
                })) {
                Text("Automatic").tag(TitleChoice.automatic)
                Text("None").tag(TitleChoice.none)
                Text("Custom").tag(TitleChoice.custom)
            }.labelsHidden() }
            if case .text(let text) = settings.title {
                CommitField(placeholder: "Chart Title", value: text) { newText in
                    var s = settings
                    s.title = newText.isEmpty ? .automatic : .text(newText)
                    document.updateChart(chart.id, to: s, actionName: "Change Chart Title")
                }
            }
            LabeledContent("Legend") { Picker("Legend", selection: binding(\.legend, settings, action: "Change Legend")) {
                Text("None").tag(SheetChart.LegendPosition?.none)
                Text("Right").tag(SheetChart.LegendPosition?.some(.right))
                Text("Bottom").tag(SheetChart.LegendPosition?.some(.bottom))
                Text("Top").tag(SheetChart.LegendPosition?.some(.top))
                Text("Left").tag(SheetChart.LegendPosition?.some(.left))
            }.labelsHidden() }
            if ChartSettings.hasAxes(settings.kind) {
                // Bars run across: their categories go up the side.
                let horizontal = settings.kind == .bar ? \ChartSettings.valueAxisTitle : \ChartSettings.categoryAxisTitle
                let vertical = settings.kind == .bar ? \ChartSettings.categoryAxisTitle : \ChartSettings.valueAxisTitle
                axisField("Horizontal axis title", horizontal, settings)
                axisField("Vertical axis title", vertical, settings)
            }
            Toggle(isOn: Binding(get: { settings.showsDataLabels == true }, set: { on in
                var s = settings
                s.showsDataLabels = on
                document.updateChart(chart.id, to: s, actionName: "Change Data Labels")
            })) {
                Text(settings.showsDataLabels == nil ? "Data labels (some series)" : "Data labels")
            }
        }
    }

    private func axisField(_ label: String, _ path: WritableKeyPath<ChartSettings, String?>,
                           _ settings: ChartSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            CommitField(placeholder: "None", value: settings[keyPath: path] ?? "") { text in
                var s = settings
                s[keyPath: path] = text.isEmpty ? nil : text
                document.updateChart(chart.id, to: s, actionName: "Change Axis Title")
            }
        }
    }

    private func colorSection(_ settings: ChartSettings) -> some View {
        section("Series") {
            ForEach(Array(settings.series.indices), id: \.self) { index in
                let shown = index < chart.series.count ? chart.series[index] : nil
                ColorPicker(selection: Binding(
                    get: { shown.map { Color(rgba: $0.color) } ?? .accentColor },
                    set: { color in
                        guard let rgba = RGBAColor(color) else { return }
                        var s = settings
                        s.series[index].color = .rgb(rgba)
                        document.updateChart(chart.id, to: s, actionName: "Change Series Color")
                    }), supportsOpacity: false) {
                    Text(shown?.name ?? "Series \(index + 1)").lineLimit(1)
                }
            }
        }
    }

    // MARK: Helpers

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    /// A binding to one setting; setting it updates the chart.
    private func binding<Value>(_ path: WritableKeyPath<ChartSettings, Value>, _ settings: ChartSettings,
                                action: String) -> Binding<Value> {
        Binding(get: { settings[keyPath: path] }, set: { value in
            var s = settings
            s[keyPath: path] = value
            // Pie and doughnut show one series, and don't stack.
            if path == \ChartSettings.kind {
                if Self.isPie(s.kind) { s.series = Array(s.series.prefix(1)); s.grouping = .standard }
                if !ChartSettings.stacks(s.kind) { s.grouping = .standard }
            }
            document.updateChart(chart.id, to: s, actionName: action)
        })
    }

    private static func isPie(_ kind: SheetChart.Kind) -> Bool { kind == .pie || kind == .doughnut }

    enum TitleChoice: Hashable {
        case automatic, none, custom
        init(_ title: ChartSettings.Title) {
            switch title {
            case .automatic: self = .automatic
            case .none: self = .none
            case .text: self = .custom
            }
        }
    }

    struct KindChoice {
        let kind: SheetChart.Kind
        let name: String
        let symbol: String
    }

    static let kinds = [
        KindChoice(kind: .column, name: "Column", symbol: "chart.bar"),
        KindChoice(kind: .bar, name: "Bar", symbol: "chart.bar.doc.horizontal"),
        KindChoice(kind: .line, name: "Line", symbol: "chart.xyaxis.line"),
        KindChoice(kind: .area, name: "Area", symbol: "chart.line.uptrend.xyaxis"),
        KindChoice(kind: .pie, name: "Pie", symbol: "chart.pie"),
        KindChoice(kind: .doughnut, name: "Doughnut", symbol: "circle.circle"),
        KindChoice(kind: .scatter, name: "Scatter", symbol: "chart.dots.scatter"),
    ]
}

/// A text field that applies its text when Return is pressed or it loses
/// focus, and follows the value it shows when that changes elsewhere.
struct CommitField: View {
    let placeholder: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onSubmit { apply() }
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private func apply() {
        guard text != value else { return }
        commit(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
