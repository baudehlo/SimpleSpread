import SpreadsheetCore
import SpreadsheetFiles
import SwiftUI

/// A menu item that acts on the focused document: its title, shortcut, when
/// it's enabled and what it does. The Edit, View, Insert, Data and Format
/// menus are built from these (DocumentCommandItems), so the UI tests run
/// exactly what a menu runs (`DocumentCommand.all`).
@MainActor
struct DocumentCommand: Identifiable {
    enum Shortcut {
        case key(KeyEquivalent, EventModifiers)
        /// F5 on the Mac (no key on iPad), with modifiers.
        case refresh(EventModifiers)
    }

    let menu: String
    /// A submenu within the menu ("Chart", "Borders"), if any.
    var submenu: String?
    /// Items in the same section sit between the same dividers.
    let section: Int
    /// The title for a document; most don't change.
    let title: (SpreadsheetDocument?) -> String
    var symbol: String?
    var shortcut: Shortcut?
    var isEnabled: (SpreadsheetDocument?) -> Bool = { $0 != nil }
    /// Run on the document. `perform` commits pending typing first.
    let run: (SpreadsheetDocument) -> Void

    /// The title as it reads with no document (stable, for ids and tests).
    let name: String
    nonisolated let id: String

    init(_ menu: String, _ section: Int, _ title: String, submenu: String? = nil, symbol: String? = nil,
         shortcut: Shortcut? = nil, enabled: @escaping (SpreadsheetDocument?) -> Bool = { $0 != nil },
         _ run: @escaping (SpreadsheetDocument) -> Void) {
        self.menu = menu
        self.section = section
        self.title = { _ in title }
        name = title
        id = [menu, submenu ?? "", title].joined(separator: "/")
        self.submenu = submenu
        self.symbol = symbol
        self.shortcut = shortcut
        isEnabled = enabled
        self.run = run
    }

    init(_ menu: String, _ section: Int, dynamicTitle: @escaping (SpreadsheetDocument?) -> String,
         shortcut: Shortcut? = nil, enabled: @escaping (SpreadsheetDocument?) -> Bool = { $0 != nil },
         _ run: @escaping (SpreadsheetDocument) -> Void) {
        self.menu = menu
        self.section = section
        title = dynamicTitle
        name = dynamicTitle(nil)
        id = [menu, "", name].joined(separator: "/")
        self.shortcut = shortcut
        isEnabled = enabled
        self.run = run
    }

    // MARK: The catalog

    static let all: [DocumentCommand] = edit + view + insert + data + format

    // Edit: after the standard pasteboard items (undo, cut, copy, paste and
    // select all stay the system's, sent to the first responder, so a text
    // field being typed in handles them itself).
    static let edit: [DocumentCommand] = [
        DocumentCommand("Edit", 0, "Fill Down", shortcut: .key("d", .command)) { $0.fillDown() },
        DocumentCommand("Edit", 0, "Fill Right", shortcut: .key("r", .command)) { $0.fillRight() },
        DocumentCommand("Edit", 1, "Find…", shortcut: .key("f", .command)) { $0.presentFind() },
        DocumentCommand("Edit", 1, "Find Next", shortcut: .key("g", .command),
                        enabled: { !($0?.findMatches.isEmpty ?? true) }) { $0.findNext() },
        DocumentCommand("Edit", 1, "Find Previous", shortcut: .key("g", [.command, .shift]),
                        enabled: { !($0?.findMatches.isEmpty ?? true) }) { $0.findPrevious() },
    ]

    static let view: [DocumentCommand] = [
        DocumentCommand("View", 0, "Zoom In", shortcut: .key("=", .command)) { $0.zoomIn() },
        DocumentCommand("View", 0, "Zoom Out", shortcut: .key("-", .command)) { $0.zoomOut() },
        DocumentCommand("View", 0, "Actual Size", shortcut: .key("0", .command)) { $0.resetZoom() },
        DocumentCommand("View", 1, "Freeze Panes",
                        enabled: { $0 != nil && $0?.selection.activeCell != CellAddress(row: 0, column: 0) }) {
            $0.freezePanesAtSelection()
        },
        DocumentCommand("View", 1, "Freeze Top Row") { $0.freezePanes(rows: 1, columns: 0) },
        DocumentCommand("View", 1, "Freeze First Column") { $0.freezePanes(rows: 0, columns: 1) },
        DocumentCommand("View", 1, "Unfreeze Panes", enabled: { $0?.hasFrozenPanes == true }) {
            $0.freezePanes(rows: 0, columns: 0)
        },
    ]

    static let insert: [DocumentCommand] = [
        DocumentCommand("Insert", 0, "Row Above") { d in
            d.insertRows(at: d.selection.range.start.row, count: d.selection.range.rowCount)
        },
        DocumentCommand("Insert", 0, "Row Below") { d in
            d.insertRows(at: d.selection.range.end.row + 1, count: d.selection.range.rowCount)
        },
        DocumentCommand("Insert", 0, "Column Left") { d in
            d.insertColumns(at: d.selection.range.start.column, count: d.selection.range.columnCount)
        },
        DocumentCommand("Insert", 0, "Column Right") { d in
            d.insertColumns(at: d.selection.range.end.column + 1, count: d.selection.range.columnCount)
        },
        DocumentCommand("Insert", 1, "Delete Selected Rows") { d in
            d.deleteRows(at: d.selection.range.start.row, count: d.selection.range.rowCount)
        },
        DocumentCommand("Insert", 1, "Delete Selected Columns") { d in
            d.deleteColumns(at: d.selection.range.start.column, count: d.selection.range.columnCount)
        },
        DocumentCommand("Insert", 2, "New Sheet", shortcut: .key("n", [.command, .shift])) { $0.addSheet() },
        DocumentCommand("Insert", 3, "PivotTable…") { $0.isInsertPivotPresented = true },
    ] + ChartPanel.kinds.map { choice in
        DocumentCommand("Insert", 3, choice.name, submenu: "Chart", symbol: choice.symbol) { $0.insertChart(choice.kind) }
    } + [
        // The keyboard's way to a chart (Tab then goes chart to chart).
        DocumentCommand("Insert", 3, "Select Next Chart", shortcut: .key("j", [.command, .option]),
                        enabled: { !($0?.activeCharts.isEmpty ?? true) }) { $0.selectNextChart() },
    ]

    static let data: [DocumentCommand] = [
        DocumentCommand("Data", 0, "Sort A to Z") { $0.quickSort(ascending: true) },
        DocumentCommand("Data", 0, "Sort Z to A") { $0.quickSort(ascending: false) },
        DocumentCommand("Data", 0, "Custom Sort…") { $0.isSortPresented = true },
        DocumentCommand("Data", 1, dynamicTitle: { $0?.activeAutoFilter == nil ? "Filter" : "Remove Filter" },
                        shortcut: .key("l", [.command, .shift])) { $0.toggleAutoFilter() },
        DocumentCommand("Data", 1, "Clear Filters", enabled: { !($0?.activeAutoFilter?.columns.isEmpty ?? true) }) {
            $0.clearAllFilters()
        },
        DocumentCommand("Data", 1, "Reapply Filter", enabled: { $0?.activeAutoFilter != nil }) { $0.reapplyAutoFilter() },
        DocumentCommand("Data", 2, "Refresh", shortcut: .refresh(.option), enabled: { $0?.activePivotIndex != nil }) { d in
            if let pivot = d.activePivotIndex { d.refreshPivot(pivot) }
        },
        DocumentCommand("Data", 2, "Refresh All", shortcut: .refresh([.control, .option]),
                        enabled: { !($0?.workbook.pivotTables.isEmpty ?? true) }) { $0.refreshAllPivots() },
        DocumentCommand("Data", 3, dynamicTitle: {
            $0?.isPivotPanelVisible == false ? "Show PivotTable Fields" : "Hide PivotTable Fields"
        }) { $0.isPivotPanelVisible.toggle() },
    ]

    static let format: [DocumentCommand] = [
        DocumentCommand("Format", 0, "Bold") { $0.toggleBold() },
        DocumentCommand("Format", 0, "Italic") { $0.toggleItalic() },
        DocumentCommand("Format", 0, "Underline") { $0.toggleUnderline() },
        DocumentCommand("Format", 0, "Strikethrough", shortcut: .key("x", [.command, .shift])) { $0.toggleStrikethrough() },
    ] + DocumentWindowView.formatChoices.map { name, format in
        DocumentCommand("Format", 1, name) { $0.setNumberFormat(format) }
    } + [
        DocumentCommand("Format", 2, "Increase Indent", shortcut: .key("]", [.command, .option])) { $0.adjustIndent(by: 1) },
        DocumentCommand("Format", 2, "Decrease Indent", shortcut: .key("[", [.command, .option])) { $0.adjustIndent(by: -1) },
    ] + DocumentWindowView.borderChoices.map { name, preset in
        DocumentCommand("Format", 2, name, submenu: "Borders") { $0.applyBorders(preset) }
    } + [
        DocumentCommand("Format", 2, "Merge & Center", submenu: "Merge Cells") { $0.mergeSelection(.mergeAndCenter) },
        DocumentCommand("Format", 2, "Merge Across", submenu: "Merge Cells") { $0.mergeSelection(.mergeAcross) },
        DocumentCommand("Format", 2, "Merge Cells", submenu: "Merge Cells") { $0.mergeSelection(.merge) },
        DocumentCommand("Format", 2, "Unmerge Cells", submenu: "Merge Cells", enabled: { $0?.selectionHasMerge == true }) {
            $0.unmergeSelection()
        },
        DocumentCommand("Format", 3, "Clear Formatting", shortcut: .key("\\", .command)) { $0.clearFormattingInSelection() },
    ]

    /// The commands of one menu.
    static func menu(_ name: String) -> [DocumentCommand] { all.filter { $0.menu == name } }
}

/// A menu's document commands as menu items: sections between dividers,
/// submenus where they're grouped.
struct DocumentCommandItems: View {
    let commands: [DocumentCommand]
    let document: SpreadsheetDocument?

    var body: some View {
        let sections = Array(Set(commands.map(\.section))).sorted()
        ForEach(sections, id: \.self) { section in
            if section != sections.first { Divider() }
            let items = commands.filter { $0.section == section }
            // Items in order, a submenu where its first item comes.
            ForEach(Array(items.enumerated()), id: \.element.id) { index, command in
                if let submenu = command.submenu {
                    if items.firstIndex(where: { $0.submenu == submenu }) == index {
                        Menu(submenu) {
                            ForEach(items.filter { $0.submenu == submenu }) { item in button(item) }
                        }
                        .disabled(document == nil)
                    }
                } else {
                    button(command)
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ command: DocumentCommand) -> some View {
        let item = Button {
            perform(document) { command.run($0) }
        } label: {
            if let symbol = command.symbol {
                Label(command.title(document), systemImage: symbol)
            } else {
                Text(command.title(document))
            }
        }
        .disabled(!command.isEnabled(document))
        switch command.shortcut {
        case .key(let key, let modifiers)?: item.keyboardShortcut(key, modifiers: modifiers)
        case .refresh(let modifiers)?: item.refreshShortcut(modifiers)
        case nil: item
        }
    }
}
