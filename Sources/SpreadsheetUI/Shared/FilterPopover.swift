import SwiftUI
import SpreadsheetCore

/// The conditions the filter popover offers, mapped onto Excel's stored
/// form (a comparison, with `*` wildcards for contains/begins/ends).
enum FilterConditionChoice: String, CaseIterable, Identifiable {
    case none = "None"
    case equals = "Equals"
    case notEquals = "Does not equal"
    case contains = "Contains"
    case notContains = "Does not contain"
    case beginsWith = "Begins with"
    case endsWith = "Ends with"
    case greaterThan = "Greater than"
    case greaterThanOrEqual = "Greater than or equal to"
    case lessThan = "Less than"
    case lessThanOrEqual = "Less than or equal to"

    var id: String { rawValue }

    func condition(_ text: String) -> FilterCondition? {
        switch self {
        case .none: return nil
        case .equals: return FilterCondition(.equal, text)
        case .notEquals: return FilterCondition(.notEqual, text)
        case .contains: return FilterCondition(.equal, "*\(text)*")
        case .notContains: return FilterCondition(.notEqual, "*\(text)*")
        case .beginsWith: return FilterCondition(.equal, "\(text)*")
        case .endsWith: return FilterCondition(.equal, "*\(text)")
        case .greaterThan: return FilterCondition(.greaterThan, text)
        case .greaterThanOrEqual: return FilterCondition(.greaterThanOrEqual, text)
        case .lessThan: return FilterCondition(.lessThan, text)
        case .lessThanOrEqual: return FilterCondition(.lessThanOrEqual, text)
        }
    }

    /// The choice and text that show a stored condition.
    static func from(_ condition: FilterCondition?) -> (FilterConditionChoice, String) {
        guard let condition else { return (.none, "") }
        let v = condition.value
        let starts = v.hasPrefix("*"), ends = v.hasSuffix("*") && !v.hasSuffix("~*")
        func inner() -> String { String(v.dropFirst(starts ? 1 : 0).dropLast(ends ? 1 : 0)) }
        switch condition.op {
        case .equal:
            if starts && ends && v.count >= 2 { return (.contains, inner()) }
            if ends { return (.beginsWith, inner()) }
            if starts { return (.endsWith, inner()) }
            return (.equals, v)
        case .notEqual:
            if starts && ends && v.count >= 2 { return (.notContains, inner()) }
            return (.notEquals, v)
        case .greaterThan: return (.greaterThan, v)
        case .greaterThanOrEqual: return (.greaterThanOrEqual, v)
        case .lessThan: return (.lessThan, v)
        case .lessThanOrEqual: return (.lessThanOrEqual, v)
        }
    }
}

/// One AutoFilter column's popover: sort, a condition, and a checklist of
/// the column's values (Excel's and Numbers' filter menus, in one).
struct FilterPopoverView: View {
    @ObservedObject var document: SpreadsheetDocument
    let columnOffset: Int
    let close: () -> Void

    @State private var allValues: [String] = []
    @State private var hasBlanks = false
    @State private var checked: Set<String> = []
    @State private var blanksChecked = true
    @State private var search = ""
    @State private var choice = FilterConditionChoice.none
    @State private var conditionText = ""
    @State private var preserved = false

    static let blanksLabel = "(Blanks)"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { sort(ascending: true) } label: {
                    Label("Sort A to Z", systemImage: "arrow.up")
                }
                Button { sort(ascending: false) } label: {
                    Label("Sort Z to A", systemImage: "arrow.down")
                }
            }

            Divider()

            if preserved {
                Text("This column has a filter SimpleSpread can’t edit, such as Top 10 or a colour filter. Clear it to filter here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Filter by condition").font(.headline)
            HStack {
                Picker("", selection: $choice) {
                    ForEach(FilterConditionChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                TextField("Value", text: $conditionText)
                    .disabled(choice == .none)
            }

            Text("Filter by values").font(.headline)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Select All") {
                    checked = Set(allValues)
                    blanksChecked = true
                }
                Button("Clear") {
                    checked = []
                    blanksChecked = false
                }
                Spacer()
                Text("\(checked.count + (hasBlanks && blanksChecked ? 1 : 0)) of \(allValues.count + (hasBlanks ? 1 : 0))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .linkButtonStyle()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shownValues, id: \.self) { value in
                        Toggle(value, isOn: Binding(
                            get: { checked.contains(value) },
                            set: { if $0 { checked.insert(value) } else { checked.remove(value) } }
                        ))
                        .checkboxToggleStyle()
                        .lineLimit(1)
                    }
                    if hasBlanks, search.isEmpty || Self.blanksLabel.localizedCaseInsensitiveContains(search) {
                        Toggle(Self.blanksLabel, isOn: $blanksChecked)
                            .checkboxToggleStyle()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 180)
            .background(Color.textBackground)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.separator))

            HStack {
                Button("Clear Filter") {
                    document.setColumnFilter(columnOffset, nil)
                    close()
                }
                .disabled(currentFilter == nil)
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear(perform: load)
    }

    private var currentFilter: ColumnFilter? {
        document.activeAutoFilter?.columns[columnOffset]
    }

    private var shownValues: [String] {
        search.isEmpty ? allValues : allValues.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private func load() {
        let result = document.workbook.filterValues(onSheetID: document.activeSheetID, columnOffset: columnOffset)
        allValues = result.values
        hasBlanks = result.hasBlanks
        let current = currentFilter
        if let values = current?.values {
            let shown = Set(values.map(ColumnFilter.folded))
            checked = Set(allValues.filter { shown.contains(ColumnFilter.folded($0)) })
            blanksChecked = current?.includeBlanks ?? true
        } else {
            checked = Set(allValues)
            blanksChecked = true
        }
        (choice, conditionText) = FilterConditionChoice.from(current?.conditions.first)
        preserved = current?.preservedXML != nil
    }

    private func apply() {
        var filter = ColumnFilter()
        let everything = checked.count == allValues.count && (!hasBlanks || blanksChecked)
        if !everything {
            filter.values = checked
            filter.includeBlanks = blanksChecked
        }
        if let condition = choice.condition(conditionText) {
            filter.conditions = [condition]
        }
        document.setColumnFilter(columnOffset, filter.isActive ? filter : nil)
        close()
    }

    private func sort(ascending: Bool) {
        guard let filter = document.activeAutoFilter else { return }
        var range = filter.range
        range.end.row = Workbook.extendedFilterEnd(range, in: document.activeSheet)
        document.sort(range: range,
                      keys: [SortKey(column: filter.range.start.column + columnOffset, ascending: ascending)],
                      hasHeader: true)
        close()
    }
}
