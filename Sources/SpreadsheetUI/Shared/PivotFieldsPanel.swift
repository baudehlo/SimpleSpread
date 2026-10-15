import SwiftUI
import SpreadsheetCore

/// The PivotTable Fields panel: Excel's field list for the pivot under the
/// active cell. Check a field to add it (text to Rows, numbers to Values),
/// drag fields between the four areas, and use each field's menu for
/// summaries, sorting, filtering and subtotals.
struct PivotFieldsPanel: View {
    @ObservedObject var document: SpreadsheetDocument
    let index: Int
    @State private var filterField: Int?
    @State private var renamingDataField: Int?
    @State private var renameText = ""
    @State private var rangesField: Int?

    private var table: PivotTable? {
        document.workbook.pivotTables.indices.contains(index) ? document.workbook.pivotTables[index] : nil
    }
    private var definition: PivotDefinition? { table?.definition }
    private var cache: PivotCacheData? { table.flatMap { document.workbook.pivotCache(withID: $0.cacheID)?.data } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let blocker = document.pivotEditBlocker(index) {
                Text("This pivot table came from Excel, and \(blocker). SimpleSpread keeps it intact but can’t change it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else if let definition, let cache {
                fieldList(definition, cache)
                Divider()
                areas(definition, cache)
                Divider()
                layoutOptions(definition)
            }
        }
        .frame(width: 290)
        .background(Color.windowBackground)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("PivotTable Fields").font(.headline)
                Text(table?.name ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                document.refreshPivot(index)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .tip("Refresh from the source data")
            .disabled(document.pivotEditBlocker(index) != nil)
            Button {
                document.isPivotPanelVisible = false
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .tip("Hide the PivotTable Fields panel")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    // MARK: Field list

    private func fieldList(_ d: PivotDefinition, _ cache: PivotCacheData) -> some View {
        List {
            ForEach(cache.fields.indices, id: \.self) { f in
                let used = d.axisArea(of: f) != nil || d.dataFields.contains { $0.field == f }
                Toggle(isOn: Binding(get: { used }, set: { toggleField(f, on: $0, cache: cache) })) {
                    Text(cache.fields[f].name)
                }
                .checkboxToggleStyle()
                .draggable(PivotDragItem.field(f).payload)
            }
        }
        .listStyle(.plain)
        .frame(minHeight: 120)
    }

    private func toggleField(_ f: Int, on: Bool, cache: PivotCacheData) {
        if on {
            // Excel's choice: numbers summarize, everything else goes on Rows.
            let numeric = cache.fields[f].formula != nil || cache.records.indices.allSatisfy { r in
                guard let c = cache.recordColumns[f] else { return false }
                switch cache.value(record: r, column: c, field: f) {
                case .number, .missing: return true
                default: return false
                }
            }
            document.editPivot(index, actionName: "Add Field") { d, c in
                d.place(field: f, in: numeric ? .values : .rows, cache: c)
            }
        } else {
            document.editPivot(index, actionName: "Remove Field") { d, _ in
                d.removeFromAxes(f)
                while let i = d.dataFields.firstIndex(where: { $0.field == f }) { d.removeDataField(at: i) }
            }
        }
    }

    // MARK: Areas

    private func areas(_ d: PivotDefinition, _ cache: PivotCacheData) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                area(.filters, "Filters", "line.3.horizontal.decrease", d, cache)
                area(.columns, "Columns", "rectangle.split.3x1", d, cache)
            }
            GridRow {
                area(.rows, "Rows", "rectangle.split.1x2", d, cache)
                area(.values, "Values", "sum", d, cache)
            }
        }
        .padding(10)
    }

    private func area(_ area: PivotArea, _ title: String, _ symbol: String,
                      _ d: PivotDefinition, _ cache: PivotCacheData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                let entries = Array(d.fields(in: area).enumerated())
                ForEach(entries, id: \.offset) { position, f in
                    chip(area: area, position: position, field: f, d, cache)
                        .dropDestination(for: String.self) { items, _ -> Bool in
                            drop(items, into: area, at: position, cache: cache)
                        }
                }
                if entries.isEmpty {
                    Text("Drag fields here").font(.caption2).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .top)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.controlBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.separator))
            .dropDestination(for: String.self) { items, _ -> Bool in
                drop(items, into: area, at: nil, cache: cache)
            }
        }
    }

    private func chipTitle(area: PivotArea, position: Int, field f: Int, _ d: PivotDefinition, _ cache: PivotCacheData) -> String {
        if area == .values { return d.dataFields[position].name }
        if f == pivotValuesFieldIndex { return "Σ " + d.layout.dataCaption }
        return d.fields[f].name ?? cache.fields[f].name
    }

    private func chip(area: PivotArea, position: Int, field f: Int,
                      _ d: PivotDefinition, _ cache: PivotCacheData) -> some View {
        let title = chipTitle(area: area, position: position, field: f, d, cache)
        let drag: PivotDragItem = area == .values ? .dataField(position) : .field(f)
        return HStack(spacing: 4) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if f >= 0, area != .values, d.fields[f].items.contains(where: \.hidden) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.secondary)
                    .tip("Some items are filtered out")
            }
            Menu {
                chipMenu(area: area, position: position, field: f, d, cache)
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .toolbarMenuStyle()
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
        .contentShape(Rectangle())
        .contextMenu { chipMenu(area: area, position: position, field: f, d, cache) }
        .draggable(drag.payload)
        .popover(isPresented: Binding(get: { filterField == f && area != .values && f >= 0 },
                                      set: { if !$0 { filterField = nil } })) {
            PivotItemFilter(document: document, index: index, field: f)
        }
        .popover(isPresented: Binding(get: { rangesField == f && area != .values && f >= 0 },
                                      set: { if !$0 { rangesField = nil } })) {
            PivotGroupRanges(document: document, index: index, field: f)
        }
        .popover(isPresented: Binding(get: { area == .values && renamingDataField == position },
                                      set: { if !$0 { renamingDataField = nil } })) {
            renamePopover(position)
        }
    }

    @ViewBuilder
    private func chipMenu(area: PivotArea, position: Int, field f: Int,
                          _ d: PivotDefinition, _ cache: PivotCacheData) -> some View {
        let count = area == .values ? d.dataFields.count : d.fields(in: area).count
        Button("Move Up") { move(area: area, from: position, to: position - 1, field: f, cache: cache) }
            .disabled(position == 0)
        Button("Move Down") { move(area: area, from: position, to: position + 1, field: f, cache: cache) }
            .disabled(position >= count - 1)
        if area != .values {
            Menu("Move To") {
                ForEach([PivotArea.filters, .columns, .rows].filter { $0 != area }, id: \.self) { target in
                    Button(target.rawValue.capitalized) {
                        document.editPivot(index, actionName: "Move Field") { d, c in d.place(field: f, in: target, cache: c) }
                    }
                    .disabled(f == pivotValuesFieldIndex && target == .filters)
                }
            }
        }
        Divider()
        if area == .values {
            Menu("Summarize Values By") {
                ForEach(PivotSubtotal.allCases, id: \.self) { fn in
                    Button(Self.functionName(fn)) {
                        document.editPivot(index, actionName: "Summarize Values") { d, c in
                            d.setSubtotal(fn, forDataField: position, cache: c)
                        }
                    }
                    .disabled(d.dataFields[position].subtotal == fn)
                }
            }
            Menu("Show Values As") {
                ForEach([PivotShowDataAs.normal, .percentOfTotal, .percentOfRow, .percentOfCol, .index], id: \.self) { mode in
                    Button(Self.showAsName(mode)) {
                        document.editPivot(index, actionName: "Show Values As") { d, _ in
                            d.setShowDataAs(mode, forDataField: position)
                        }
                    }
                    .disabled(d.dataFields[position].showDataAs == mode)
                }
                Divider()
                ForEach([PivotShowDataAs.difference, .percent, .percentDiff], id: \.self) { mode in
                    Menu(Self.showAsName(mode)) { baseItemMenu(mode, dataField: position, d, cache) }
                        .disabled(d.rowFields.filter { $0 >= 0 }.isEmpty && d.columnFields.filter { $0 >= 0 }.isEmpty)
                }
                Menu(Self.showAsName(.runTotal)) {
                    ForEach((d.rowFields + d.columnFields).filter { $0 >= 0 }, id: \.self) { base in
                        Button(d.fields[base].name ?? cache.fields[base].name) {
                            document.editPivot(index, actionName: "Show Values As") { d, _ in
                                d.setShowDataAs(.runTotal, forDataField: position, baseField: base, baseItem: 0)
                            }
                        }
                    }
                }
            }
            Button("Rename…") {
                renameText = d.dataFields[position].name
                renamingDataField = position
            }
        } else if f >= 0 {
            Button("Filter Items…") { filterField = f }
            Menu("Sort") {
                Button("Ascending") { document.editPivot(index, actionName: "Sort") { d, c in d.setSort(.ascending, field: f, cache: c) } }
                Button("Descending") { document.editPivot(index, actionName: "Sort") { d, c in d.setSort(.descending, field: f, cache: c) } }
                Button("Manual (keep order)") { document.editPivot(index, actionName: "Sort") { d, c in d.setSort(.manual, field: f, cache: c) } }
            }
            groupMenu(field: f, cache)
            Toggle("Show Items With No Data", isOn: Binding(
                get: { d.fields[f].showAll },
                set: { on in document.editPivot(index, actionName: "Show Items") { d, _ in d.fields[f].showAll = on } }))
            if area == .rows {
                Toggle("Blank Line After Each Item", isOn: Binding(
                    get: { d.fields[f].insertBlankRow },
                    set: { on in document.editPivot(index, actionName: "Blank Lines") { d, _ in d.fields[f].insertBlankRow = on } }))
            }
            if area != .filters {
                Toggle("Show Subtotals", isOn: Binding(
                    get: { !d.fields[f].subtotals.isEmpty },
                    set: { on in document.editPivot(index, actionName: "Subtotals") { d, _ in d.setSubtotals(on, field: f) } }))
            }
        }
        Divider()
        Button("Remove") {
            document.editPivot(index, actionName: "Remove Field") { d, _ in
                if area == .values { d.removeDataField(at: position) } else { d.removeFromAxes(f) }
            }
        }
        .disabled(f == pivotValuesFieldIndex)
    }

    /// Group by date parts or into ranges, or ungroup (Excel's Group…).
    @ViewBuilder
    private func groupMenu(field f: Int, _ cache: PivotCacheData) -> some View {
        let field = cache.fields[f]
        if let group = field.group {
            // A Years/Quarters level ungroups the date field it came from.
            let base = field.isDatabaseField ? f : (group.base ?? f)
            Button("Ungroup") {
                document.regroupPivot(index, actionName: "Ungroup") { try $0.ungroupPivotField(table: index, field: base) }
            }
            .disabled(!cache.fields.indices.contains(base) || !cache.fields[base].isDatabaseField)
        } else if field.isDatabaseField, let kind = Self.groupKind(field) {
            if kind == .dates {
                Menu("Group") {
                    ForEach(Self.dateGroupings, id: \.0) { title, levels in
                        Button(title) {
                            document.regroupPivot(index, actionName: "Group") {
                                try $0.groupPivotField(table: index, field: f, byDates: levels)
                            }
                        }
                    }
                }
            } else {
                Button("Group into Ranges…") { rangesField = f }
            }
        }
    }

    enum GroupKind { case dates, numbers }

    /// How a field can be grouped: dates by parts, plain numbers into ranges.
    static func groupKind(_ field: PivotCacheField) -> GroupKind? {
        var dates = false, numbers = false
        for item in field.sharedItems {
            switch item {
            case .date: dates = true
            case .number: numbers = true
            case .missing: break
            default: return nil
            }
        }
        if dates { return .dates }
        return numbers ? .numbers : nil
    }

    static let dateGroupings: [(String, Set<PivotDateGrouping>)] = [
        ("Years", [.years]), ("Quarters", [.quarters]), ("Months", [.months]), ("Days", [.days]),
        ("Years and Quarters", [.years, .quarters]), ("Years and Months", [.years, .months]),
        ("Years, Quarters and Months", [.years, .quarters, .months]),
    ]

    /// Base field ▸ base item choices for difference / % of / % difference.
    @ViewBuilder
    private func baseItemMenu(_ mode: PivotShowDataAs, dataField position: Int,
                              _ d: PivotDefinition, _ cache: PivotCacheData) -> some View {
        ForEach((d.rowFields + d.columnFields).filter { $0 >= 0 }, id: \.self) { base in
            Menu(d.fields[base].name ?? cache.fields[base].name) {
                Button("(previous)") { setBase(mode, position, base, 1048828) }
                Button("(next)") { setBase(mode, position, base, 1048829) }
                Divider()
                let values = cache.fields[base].axisItems
                ForEach(Array(d.fields[base].items.enumerated()).filter { $0.element.kind == .data }, id: \.offset) { p, item in
                    Button(item.name ?? item.index.map { $0 < values.count ? values[$0].cellValue.rawDisplayString : "" } ?? "") {
                        setBase(mode, position, base, p)
                    }
                }
            }
        }
    }

    private func setBase(_ mode: PivotShowDataAs, _ position: Int, _ base: Int, _ item: Int) {
        document.editPivot(index, actionName: "Show Values As") { d, _ in
            d.setShowDataAs(mode, forDataField: position, baseField: base, baseItem: item)
        }
    }

    private func renamePopover(_ position: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Value field name").font(.headline)
            TextField("Name", text: $renameText)
                .frame(width: 220)
                .onSubmit { commitRename(position) }
            HStack {
                Spacer()
                Button("Cancel") { renamingDataField = nil }
                Button("Rename") { commitRename(position) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func commitRename(_ position: Int) {
        let name = renameText
        var ok = true
        document.editPivot(index, actionName: "Rename Field") { d, _ in ok = d.renameDataField(at: position, to: name) }
        if !ok {
            document.notice = DocumentNotice(message: "That name is already used.",
                                             detail: "Each value field needs its own name.")
        }
        renamingDataField = nil
    }

    private func move(area: PivotArea, from: Int, to: Int, field f: Int, cache: PivotCacheData) {
        document.editPivot(index, actionName: "Move Field") { d, c in
            if area == .values { d.moveDataField(from: from, to: to) } else { d.place(field: f, in: area, at: to, cache: c) }
        }
    }

    private func drop(_ items: [String], into area: PivotArea, at position: Int?, cache: PivotCacheData) -> Bool {
        guard let item = items.first.flatMap(PivotDragItem.init(payload:)) else { return false }
        switch item {
        case .field(let f):
            guard !(f == pivotValuesFieldIndex && (area == .filters || area == .values)) else { return false }
            document.editPivot(index, actionName: "Move Field") { d, c in d.place(field: f, in: area, at: position, cache: c) }
        case .dataField(let i):
            guard area == .values else {
                // Dragging a value field out of Values removes it; onto an
                // axis, its source field goes there instead.
                guard let d = definition, d.dataFields.indices.contains(i) else { return false }
                let f = d.dataFields[i].field
                document.editPivot(index, actionName: "Move Field") { d, c in
                    d.removeDataField(at: i)
                    d.place(field: f, in: area, at: position, cache: c)
                }
                return true
            }
            document.editPivot(index, actionName: "Move Field") { d, _ in d.moveDataField(from: i, to: position ?? d.dataFields.count) }
        }
        return true
    }

    // MARK: Layout

    private func layoutOptions(_ d: PivotDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Layout", selection: Binding(
                get: { d.form ?? .compact },
                set: { form in document.editPivot(index, actionName: "Report Layout") { d, _ in d.setForm(form) } })) {
                Text("Compact").tag(PivotForm.compact)
                Text("Outline").tag(PivotForm.outline)
                Text("Tabular").tag(PivotForm.tabular)
            }
            .pickerStyle(.segmented)
            Toggle("Grand totals for rows", isOn: Binding(
                get: { d.layout.rowGrandTotals },
                set: { on in document.editPivot(index, actionName: "Grand Totals") { d, _ in d.layout.rowGrandTotals = on } }))
            Toggle("Grand totals for columns", isOn: Binding(
                get: { d.layout.colGrandTotals },
                set: { on in document.editPivot(index, actionName: "Grand Totals") { d, _ in d.layout.colGrandTotals = on } }))
        }
        .checkboxToggleStyle()
        .font(.callout)
        .padding(12)
    }

    static func functionName(_ fn: PivotSubtotal) -> String {
        switch fn {
        case .sum: return "Sum"
        case .count: return "Count"
        case .average: return "Average"
        case .max: return "Max"
        case .min: return "Min"
        case .product: return "Product"
        case .countNums: return "Count Numbers"
        case .stdDev: return "StdDev"
        case .stdDevp: return "StdDevp"
        case .var: return "Var"
        case .varp: return "Varp"
        }
    }

    static func showAsName(_ mode: PivotShowDataAs) -> String {
        switch mode {
        case .normal: return "No Calculation"
        case .percentOfTotal: return "% of Grand Total"
        case .percentOfRow: return "% of Row Total"
        case .percentOfCol: return "% of Column Total"
        case .index: return "Index"
        case .difference: return "Difference From"
        case .percent: return "% Of"
        case .percentDiff: return "% Difference From"
        case .runTotal: return "Running Total In"
        default: return mode.rawValue
        }
    }
}

/// What a drag in the field panel carries.
enum PivotDragItem: Equatable {
    case field(Int)
    case dataField(Int)

    var payload: String {
        switch self {
        case .field(let f): return "simplespread.pivot.field:\(f)"
        case .dataField(let i): return "simplespread.pivot.data:\(i)"
        }
    }

    init?(payload: String) {
        let parts = payload.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "simplespread.pivot.field": self = .field(n)
        case "simplespread.pivot.data": self = .dataField(n)
        default: return nil
        }
    }
}

/// Excel's item checklist for a field (and a single choice for a filter).
struct PivotItemFilter: View {
    @ObservedObject var document: SpreadsheetDocument
    let index: Int
    let field: Int
    @State private var visible: Set<Int> = []
    @State private var loaded = false

    private var items: [(position: Int, label: String)] {
        guard document.workbook.pivotTables.indices.contains(index),
              let d = document.workbook.pivotTables[index].definition,
              let cache = document.workbook.pivotCache(withID: document.workbook.pivotTables[index].cacheID)?.data
        else { return [] }
        let values = cache.fields[field].axisItems
        return d.fields[field].items.enumerated().compactMap { p, item in
            guard item.kind == .data, let x = item.index, x < values.count else { return nil }
            if let name = item.name { return (p, name) }
            let text: String
            switch values[x] {
            case .missing: text = "(blank)"
            case .date(let n): text = NumberFormatEngine.displayString(for: .number(n), format: cache.fields[field].numberFormat)
            default: text = values[x].cellValue.rawDisplayString
            }
            return (p, text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Select All") { visible = Set(items.map(\.position)) }
                Button("Clear") { visible = [] }
            }
            .linkButtonStyle()
            List(items, id: \.position) { item in
                Toggle(item.label, isOn: Binding(
                    get: { visible.contains(item.position) },
                    set: { on in if on { visible.insert(item.position) } else { visible.remove(item.position) } }))
                .checkboxToggleStyle()
            }
            .frame(width: 240, height: min(300, CGFloat(items.count) * 24 + 12))
            HStack {
                Spacer()
                Button("Apply") {
                    let chosen = visible
                    document.editPivot(index, actionName: "Filter") { d, _ in d.setVisibleItems(field: field, positions: chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(visible.isEmpty)
            }
        }
        .padding(12)
        .onAppear {
            guard !loaded, let d = document.workbook.pivotTables[safe: index]?.definition else { return }
            visible = Set(d.fields[field].items.indices.filter { d.fields[field].items[$0].kind == .data && !d.fields[field].items[$0].hidden })
            loaded = true
        }
    }
}

/// Insert ▸ PivotTable…: choose the data and where the pivot goes.
struct InsertPivotSheet: View {
    @ObservedObject var document: SpreadsheetDocument
    @Environment(\.dismiss) private var dismiss
    @State private var rangeText = ""
    @State private var newSheet = true
    @State private var cellText = ""
    @State private var error: String?
    /// Pivot tables when the sheet opened: one more means it was made, even
    /// after `create` returned (an iPad confirmation answered later).
    @State private var pivotCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create PivotTable").font(.title3.weight(.semibold))
            Form {
                TextField("Data range:", text: $rangeText, prompt: Text("A1:D100"))
                Picker("Place it on:", selection: $newSheet) {
                    Text("A new sheet").tag(true)
                    Text("This sheet").tag(false)
                }
                .radioGroupPickerStyle()
                if !newSheet {
                    TextField("At cell:", text: $cellText, prompt: Text("F3"))
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onReceive(document.$revision) { _ in
            if document.workbook.pivotTables.count > pivotCount { created() }
        }
        .onAppear {
            pivotCount = document.workbook.pivotTables.count
            rangeText = document.suggestedPivotSource()?.a1 ?? ""
            cellText = CellAddress(row: document.selection.range.start.row,
                                   column: document.selection.range.end.column + 2).a1
        }
    }

    private func create() {
        guard let range = CellRange(a1: rangeText.replacingOccurrences(of: "$", with: "").uppercased()
            .trimmingCharacters(in: .whitespaces)), range.rowCount >= 2 else {
            error = "Enter a range with a heading row and at least one row of data, like A1:D100."
            return
        }
        var destination = PivotDestination.newSheet
        if !newSheet {
            guard let cell = CellAddress(a1: cellText.trimmingCharacters(in: .whitespaces).uppercased()) else {
                error = "Enter a cell such as F3."
                return
            }
            destination = .existing(sheetID: document.activeSheetID, at: cell)
        }
        if document.insertPivotTable(source: range, destination: destination) {
            created()
        } else if let notice = document.notice {
            error = notice.message + " " + notice.detail
            document.notice = nil
        }
    }

    private func created() {
        document.isPivotPanelVisible = true
        dismiss()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Group a numeric field into equal ranges: start, end and interval,
/// starting at the data's minimum and maximum.
struct PivotGroupRanges: View {
    @ObservedObject var document: SpreadsheetDocument
    let index: Int
    let field: Int
    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""
    @State private var interval = "10"
    @State private var loaded = false

    private var bounds: (Double, Double)? {
        guard document.workbook.pivotTables.indices.contains(index),
              let data = document.workbook.pivotCache(withID: document.workbook.pivotTables[index].cacheID)?.data,
              data.fields.indices.contains(field) else { return nil }
        let values = data.fields[field].sharedItems.compactMap { v -> Double? in
            if case .number(let n) = v { return n }
            return nil
        }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return (lo, hi)
    }

    static func text(_ x: Double) -> String { x == x.rounded() ? String(Int64(x)) : String(x) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Group into Ranges").font(.headline)
            Form {
                TextField("Starting at:", text: $start)
                TextField("Ending at:", text: $end)
                TextField("By:", text: $interval)
            }
            .frame(width: 220)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Group") { group() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(14)
        .onAppear {
            guard !loaded, let (lo, hi) = bounds else { return }
            loaded = true
            start = Self.text(lo)
            end = Self.text(hi)
            interval = Self.text(Self.suggestedInterval(lo, hi))
        }
    }

    /// Start, end and interval, when they make sense.
    private var parsed: (Double, Double, Double)? {
        guard let s = Double(start), let e = Double(end), let by = Double(interval), by > 0, e >= s else { return nil }
        return (s, e, by)
    }

    /// A round interval giving about ten ranges.
    static func suggestedInterval(_ lo: Double, _ hi: Double) -> Double {
        let raw = max((hi - lo) / 10, 1e-9)
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        return [1, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
    }

    private func group() {
        guard let (s, e, by) = parsed else { return }
        let (lo, hi) = bounds ?? (s, e)
        document.regroupPivot(index, actionName: "Group") {
            try $0.groupPivotField(table: index, field: field, interval: by,
                                   start: s == lo ? nil : s, end: e == hi ? nil : e)
        }
        dismiss()
    }
}
