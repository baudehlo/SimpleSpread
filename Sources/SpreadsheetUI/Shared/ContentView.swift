import SwiftUI
import SpreadsheetCore
import UniformTypeIdentifiers

/// One document window: toolbar, formula bar, grid, sheet tabs, status bar.
public struct DocumentWindowView: View {
    @ObservedObject var document: SpreadsheetDocument
    @StateObject private var formulaBarEditor = FormulaBarEditor()
    @State private var nameBoxText = "A1"
    @State private var renamingSheetID: Int?
    @State private var renameText = ""
    @State private var gridRevision = 0
    @FocusState private var findFieldFocused: Bool

    public init(document: SpreadsheetDocument) {
        self.document = document
    }

    public var body: some View {
        HStack(spacing: 0) {
            mainColumn
            if let chart = document.selectedChart, document.isChartPanelVisible {
                Divider()
                ChartPanel(document: document, chart: chart)
                    .id(chart.id)
            } else if document.isPivotPanelVisible, let pivot = document.activePivotIndex {
                Divider()
                PivotFieldsPanel(document: document, index: pivot)
                    .id(pivot)
            }
        }
        .sheet(isPresented: $document.isInsertPivotPresented) {
            InsertPivotSheet(document: document)
        }
        .sheet(isPresented: $document.isSortPresented) {
            SortSheet(document: document)
        }
        .onAppear { installConfirmation() }
    }

    /// Confirmations (e.g. a pivot growing over data) as alerts.
    private func installConfirmation() {
        Alerts.installConfirmation(on: document)
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            formatBar
            Divider()
            formulaBar
            Divider()
            GridContainer(document: document, revision: gridRevision) {
                syncFromDocument()
            }
            .overlay(alignment: .topTrailing) {
                if document.isFindPresented {
                    findBar
                        .padding(10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            Divider()
            bottomBar
        }
        .onAppear { syncFromDocument() }
        .onReceive(document.$revision) { _ in syncFromDocument() }
        .onReceive(document.$selection) { _ in syncFromDocument() }
        .onChange(of: document.isFindPresented) { _, presented in
            if presented {
                DispatchQueue.main.async { findFieldFocused = true }
            } else {
                refocusGrid()
            }
        }
        .alert(document.notice?.message ?? "", isPresented: Binding(
            get: { document.notice != nil },
            set: { if !$0 { document.notice = nil } }
        ), presenting: document.notice) { _ in
            Button("OK") { refocusGrid() }
        } message: { notice in
            Text(notice.detail)
        }
        .background(DocumentWindowHook(document: document))
        .focusedSceneValue(\.spreadsheetDocument, document)
        .navigationTitle(document.displayName)
        .windowSubtitle(document.isModified ? "— Edited" : "")
    }

    // MARK: Find bar

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("Find in sheet", text: Binding(
                get: { document.findQuery },
                set: { document.setFindQuery($0) }
            ))
            .textFieldStyle(.plain)
            .frame(width: 170)
            .focused($findFieldFocused)
            .onSubmit { document.findNext() }
            Text(document.findStatus)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 58, alignment: .trailing)
            Divider().frame(height: 16)
            Button { document.findPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(document.findMatches.isEmpty)
            .tip("Previous match (⇧⌘G)")
            Button { document.findNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(document.findMatches.isEmpty)
            .tip("Next match (⌘G)")
            Button { closeFind() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .tip("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.separator))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .onEscape { closeFind() }
    }

    private func closeFind() {
        document.dismissFind()
        findFieldFocused = false
        refocusGrid()
    }

    /// Return keyboard focus to the AppKit grid after the find bar closes.
    /// SwiftUI moves focus to the next focusable control (the Bold button)
    /// while it removes the find field, AFTER this call returns, so a
    /// synchronous makeFirstResponder is undone. Try now, on the next turn of
    /// the run loop, and once more after the bar's removal transition.
    private func refocusGrid() {
        focusGridNow(unlessTyping: false)
        DispatchQueue.main.async { focusGridNow(unlessTyping: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focusGridNow(unlessTyping: true) }
    }

    /// `unlessTyping`: leave focus alone if the user has since clicked into a
    /// text field (the formula bar or name box).
    private func focusGridNow(unlessTyping: Bool) {
        GridFocus.focusGrid(unlessTyping: unlessTyping)
    }

    private func syncFromDocument() {
        formulaBarEditor.document = document
        formulaBarEditor.sync()
        let range = document.selection.range
        nameBoxText = range.isSingleCell ? document.selection.activeCell.a1 : range.a1
        gridRevision += 1
    }

    // MARK: Format toolbar

    private var activeStyle: CellStyle {
        document.style(at: document.selection.activeCell)
    }

    /// Groups follow the order shared by Excel's Home tab and the Google
    /// Sheets toolbar: history, number, font, alignment, then functions.
    /// Scrolls sideways when the window is too narrow to show it all.
    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                historyGroup
                toolbarDivider
                numberGroup
                toolbarDivider
                fontGroup
                toolbarDivider
                colorGroup
                toolbarDivider
                alignmentGroup
                toolbarDivider
                dataGroup
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 16)
    }

    private var historyGroup: some View {
        let undo = document.undoManager
        return HStack(spacing: 2) {
            toolButton("arrow.uturn.backward", help: undo.canUndo ? "Undo \(undo.undoActionName) (⌘Z)" : "Undo (⌘Z)") {
                undo.undo()
            }
            .disabled(!undo.canUndo)
            toolButton("arrow.uturn.forward", help: undo.canRedo ? "Redo \(undo.redoActionName) (⇧⌘Z)" : "Redo (⇧⌘Z)") {
                undo.redo()
            }
            .disabled(!undo.canRedo)
            styleToggle("paintbrush.pointed", active: document.formatPainterStyles != nil) {
                if document.formatPainterStyles == nil {
                    document.beginFormatPainter()
                } else {
                    document.cancelFormatPainter()
                }
                refocusGrid()
            }
            .tip("Format painter: copy this formatting, then select cells to apply it (Esc cancels)")
            toolButton("eraser", help: "Clear formatting (⌘\\)") {
                document.clearFormattingInSelection()
            }
        }
    }

    private var numberGroup: some View {
        HStack(spacing: 2) {
            styleToggle("dollarsign", active: activeStyle.numberFormat == .currency) {
                document.setNumberFormat(activeStyle.numberFormat == .currency ? .general : .currency)
            }
            .tip("Format as currency")
            styleToggle("percent", active: activeStyle.numberFormat == .percent) {
                document.setNumberFormat(activeStyle.numberFormat == .percent ? .general : .percent)
            }
            .tip("Format as percent")
            textButton(".0", arrow: "arrow.left", help: "Decrease decimal places") {
                document.adjustDecimals(by: -1)
            }
            textButton(".00", arrow: "arrow.right", help: "Increase decimal places") {
                document.adjustDecimals(by: 1)
            }
            numberFormatMenu
                .padding(.leading, 4)
        }
    }

    private var fontGroup: some View {
        HStack(spacing: 6) {
            fontNameMenu
            fontSizeMenu
            HStack(spacing: 2) {
                styleToggle("bold", active: activeStyle.bold) { document.toggleBold() }
                    .keyboardShortcut("b", modifiers: .command)
                    .tip("Bold (⌘B)")
                styleToggle("italic", active: activeStyle.italic) { document.toggleItalic() }
                    .keyboardShortcut("i", modifiers: .command)
                    .tip("Italic (⌘I)")
                styleToggle("underline", active: activeStyle.underline) { document.toggleUnderline() }
                    .keyboardShortcut("u", modifiers: .command)
                    .tip("Underline (⌘U)")
                styleToggle("strikethrough", active: activeStyle.strikethrough) { document.toggleStrikethrough() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                    .tip("Strikethrough (⇧⌘X)")
            }
        }
    }

    private var colorGroup: some View {
        // NSColorWell has a fixed intrinsic size — never clamp its frame
        // (a narrower frame clips and the well overflows onto neighbors).
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: "character")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ColorPicker("", selection: textColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
            }
            .tip("Text color")
            HStack(spacing: 3) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ColorPicker("", selection: fillColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
            }
            .tip("Fill color")
            bordersMenu
        }
    }

    static let borderChoices: [(String, SpreadsheetDocument.BorderPreset)] = [
        ("Bottom Border", .bottom), ("Top Border", .top), ("Left Border", .left), ("Right Border", .right),
        ("No Border", .none), ("All Borders", .all), ("Outside Borders", .outside),
        ("Thick Outside Borders", .thickOutside), ("Inside Borders", .inside),
        ("Top and Bottom Border", .topAndBottom), ("Thick Bottom Border", .thickBottom),
        ("Double Bottom Border", .doubleBottom),
    ]

    private var bordersMenu: some View {
        Menu {
            ForEach(DocumentWindowView.borderChoices, id: \.0) { name, preset in
                Button(name) { document.applyBorders(preset) }
                if preset == .right || preset == .inside { Divider() }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
        } primaryAction: {
            document.applyBorders(.bottom)
        }
        .toolbarMenuStyle()
        .fixedSize()
        .tip("Borders: click for a bottom border, or choose from the menu")
    }

    private var alignmentGroup: some View {
        HStack(spacing: 2) {
            alignButton(.left, icon: "text.alignleft", help: "Align left")
            alignButton(.center, icon: "text.aligncenter", help: "Align center")
            alignButton(.right, icon: "text.alignright", help: "Align right")
            verticalAlignMenu
            styleToggle("arrow.turn.down.left", active: activeStyle.wrapText) { document.toggleWrapText() }
                .tip("Wrap text")
            mergeMenu
        }
    }

    static let verticalChoices: [(String, TextAlignmentV, String)] = [
        ("Top", .top, "align.vertical.top"),
        ("Middle", .middle, "align.vertical.center"),
        ("Bottom", .bottom, "align.vertical.bottom"),
    ]

    /// Vertical alignment as one menu showing the current choice (as in
    /// Google Sheets), to keep the toolbar to one row.
    private var verticalAlignMenu: some View {
        let current = activeStyle.verticalAlignment
        let icon = DocumentWindowView.verticalChoices.first { $0.1 == current }?.2 ?? "align.vertical.bottom"
        return Menu {
            ForEach(DocumentWindowView.verticalChoices, id: \.0) { name, alignment, symbol in
                Button {
                    document.setVerticalAlignment(alignment)
                } label: {
                    Label(name, systemImage: alignment == current ? "checkmark" : symbol)
                }
            }
        } label: {
            Image(systemName: icon)
        }
        .toolbarMenuStyle()
        .fixedSize()
        .tip("Vertical alignment")
    }

    private var mergeMenu: some View {
        Menu {
            Button("Merge & Center") { document.mergeSelection(.mergeAndCenter) }
            Button("Merge Across") { document.mergeSelection(.mergeAcross) }
            Button("Merge Cells") { document.mergeSelection(.merge) }
            Button("Unmerge Cells") { document.unmergeSelection() }
                .disabled(!document.selectionHasMerge)
        } label: {
            Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
        } primaryAction: {
            document.toggleMergeAndCenter()
        }
        .toolbarMenuStyle()
        .fixedSize()
        .tip("Merge & Center (click again to unmerge)")
    }

    /// Excel's Home-tab "Sort & Filter" button: one menu, its icon filled
    /// while the sheet has a filter.
    private var dataGroup: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Sort A to Z", action: command { document.quickSort(ascending: true) })
                Button("Sort Z to A", action: command { document.quickSort(ascending: false) })
                Button("Custom Sort…", action: command { document.isSortPresented = true })
                Divider()
                Button(document.activeAutoFilter == nil ? "Filter" : "Remove Filter",
                       action: command { document.toggleAutoFilter() })
                Button("Clear Filters", action: command { document.clearAllFilters() })
                    .disabled(document.activeAutoFilter?.columns.isEmpty ?? true)
                Button("Reapply Filter", action: command { document.reapplyAutoFilter() })
                    .disabled(document.activeAutoFilter == nil)
            } label: {
                // Menu labels drop backgrounds, so a filled icon marks a filter.
                Image(systemName: document.activeAutoFilter != nil
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
            }
            .toolbarMenuStyle()
            .fixedSize()
            .tip("Sort & Filter")
            autoSumMenu
        }
    }

    static let autoSumFunctions = [
        ("Sum", "SUM"), ("Average", "AVERAGE"), ("Count Numbers", "COUNT"), ("Max", "MAX"), ("Min", "MIN"),
    ]

    private var autoSumMenu: some View {
        Menu {
            ForEach(DocumentWindowView.autoSumFunctions, id: \.1) { name, function in
                Button(name, action: command { document.autoSum(function) })
            }
        } label: {
            Image(systemName: "sum")
        } primaryAction: {
            document.commitPendingEdit()
            document.autoSum()
        }
        .toolbarMenuStyle()
        .fixedSize()
        .tip("AutoSum: total the numbers above or to the left (click the arrow for Average, Count, Max, Min)")
    }

    /// Toolbar commands act on committed cells: write any pending typing
    /// first (toolbar buttons do not take focus, so the editor stays open).
    private func command(_ action: @escaping () -> Void) -> () -> Void {
        { [document] in
            document.commitPendingEdit()
            action()
        }
    }

    private func styleToggle(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: command(action)) {
            Image(systemName: icon)
                .frame(width: 22, height: 20)
                .background(active ? Color.accentColor.opacity(0.25) : .clear)
                .cornerRadius(4)
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func toolButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: command(action)) {
            Image(systemName: icon)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .tip(help)
    }

    /// The ".0 ←" / ".00 →" decimal buttons, drawn as text like Sheets.
    private func textButton(_ text: String, arrow: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: command(action)) {
            HStack(spacing: 1) {
                if arrow == "arrow.left" { Image(systemName: arrow).font(.system(size: 8, weight: .semibold)) }
                Text(text).font(.system(size: 12, weight: .semibold))
                if arrow == "arrow.right" { Image(systemName: arrow).font(.system(size: 8, weight: .semibold)) }
            }
            .frame(minWidth: 30, minHeight: 20)
        }
        .buttonStyle(.borderless)
        .tip(help)
    }

    private func alignButton(_ alignment: TextAlignmentH, icon: String, help: String) -> some View {
        styleToggle(icon, active: activeStyle.horizontalAlignment == alignment) {
            document.setHorizontalAlignment(alignment)
        }
        .tip(help)
    }

    static var fontChoices: [String] { FontChoices.current }

    static let fontSizeChoices: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 30, 36, 48]

    private var fontNameMenu: some View {
        let current = activeStyle.fontName ?? CellStyle.defaultFontName
        return Menu {
            ForEach(DocumentWindowView.fontChoices, id: \.self) { name in
                Button {
                    document.setFontName(name)
                } label: {
                    if name == current {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Text(current)
                .lineLimit(1)
                .frame(width: 90, alignment: .leading)
        }
        .toolbarMenuStyle()
        .fixedSize()
        .tip("Font")
        .accessibilityValue(current)
    }

    private var fontSizeMenu: some View {
        let current = activeStyle.fontSize ?? CellStyle.defaultFontSize
        return Menu {
            ForEach(DocumentWindowView.fontSizeChoices, id: \.self) { size in
                Button {
                    document.setFontSize(size)
                } label: {
                    if size == current {
                        Label(NumberFormatEngine.generalString(for: size), systemImage: "checkmark")
                    } else {
                        Text(NumberFormatEngine.generalString(for: size))
                    }
                }
            }
        } label: {
            Text(NumberFormatEngine.generalString(for: current))
                .monospacedDigit()
                .frame(minWidth: 20)
        }
        .toolbarMenuStyle()
        .fixedSize()
        .tip("Font size")
        .accessibilityValue(NumberFormatEngine.generalString(for: current))
    }

    static let formatChoices: [(String, NumberFormat)] = [
        ("Automatic", .general),
        ("Number", NumberFormat(code: "#,##0.00")),
        ("Percent", .percent),
        ("Currency", .currency),
        ("Date", .date),
        ("Time", .time),
        ("Date & Time", .dateTime),
        ("Scientific", .scientific),
        ("Plain Text", .text),
    ]

    private var numberFormatMenu: some View {
        Menu {
            ForEach(DocumentWindowView.formatChoices, id: \.0) { name, format in
                Button {
                    document.setNumberFormat(format)
                } label: {
                    if activeStyle.numberFormat == format {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Text(currentFormatName)
                .frame(minWidth: 70)
        }
        .toolbarMenuStyle()
        .fixedSize()
        .tip("Number format")
        .accessibilityValue(currentFormatName)
    }

    private var currentFormatName: String {
        let current = activeStyle.numberFormat
        if let match = DocumentWindowView.formatChoices.first(where: { $0.1 == current }) {
            return match.0
        }
        if current.isDateTime { return "Date" }
        return "Custom"
    }

    private var textColorBinding: Binding<Color> {
        Binding {
            colorFrom(activeStyle.textColor) ?? Color.text
        } set: { newColor in
            let rgba = rgbaFrom(newColor)
            document.applyStyleToSelection("Text Color") { $0.textColor = rgba }
        }
    }

    private var fillColorBinding: Binding<Color> {
        Binding {
            colorFrom(activeStyle.fillColor) ?? Color.textBackground
        } set: { newColor in
            let rgba = rgbaFrom(newColor)
            document.applyStyleToSelection("Fill Color") { $0.fillColor = rgba }
        }
    }

    private func colorFrom(_ rgba: RGBAColor?) -> Color? {
        guard let c = rgba else { return nil }
        return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255,
                     blue: Double(c.blue) / 255, opacity: Double(c.alpha) / 255)
    }

    private func rgbaFrom(_ color: Color) -> RGBAColor? {
        RGBAColor(color)
    }

    // MARK: Formula bar

    private var formulaBar: some View {
        HStack(spacing: 6) {
            TextField("", text: $nameBoxText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 76)
                .multilineTextAlignment(.center)
                .onSubmit { navigateToNameBox() }
                .accessibilityIdentifier("nameBox")
                .accessibilityLabel("Cell reference")
                .padding(.vertical, 3)
                .background(Color.controlBackground)
                .cornerRadius(4)
            Image(systemName: "function")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            // Typing is for the cell active at the first keystroke, and is
            // committed there on Return or when focus leaves the bar.
            TextField("", text: Binding(
                get: { formulaBarEditor.text },
                set: { formulaBarEditor.userEdited($0) }
            ), onEditingChanged: { editing in
                if !editing { formulaBarEditor.endEditing() }
            })
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .accessibilityIdentifier("formulaBar")
            .accessibilityLabel("Formula")
            .onSubmit {
                formulaBarEditor.commitPendingEdit()
                syncFromDocument()
            }
            .onEscape {
                formulaBarEditor.cancel()
                refocusGrid()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func navigateToNameBox() {
        let text = nameBoxText.trimmingCharacters(in: .whitespaces)
        if let range = CellRange(a1: text) {
            document.selection.select(range: range)
            document.requestScrollToActiveCell()
        }
        syncFromDocument()
    }

    // MARK: Sheet tabs + status

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button {
                document.addSheet()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .tip("Add sheet")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(document.workbook.sheets, id: \.id) { sheet in
                        sheetTab(sheet)
                    }
                }
            }
            Spacer()
            statusText
            zoomControl
                .padding(.leading, 14)
                .padding(.trailing, 10)
        }
        .frame(height: 28)
        .background(Color.windowBackground)
    }

    private var zoomControl: some View {
        HStack(spacing: 2) {
            Button {
                document.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .tip("Zoom out (⌘-)")

            Menu {
                ForEach(SpreadsheetDocument.zoomPresets, id: \.self) { preset in
                    Button("\(Int(preset * 100))%") {
                        document.setZoom(preset)
                    }
                }
            } label: {
                Text("\(Int((document.zoomLevel * 100).rounded()))%")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(minWidth: 38)
            }
            .toolbarMenuStyle()
            .fixedSize()
            .tip("Zoom level")
        .accessibilityValue("\(Int((document.zoomLevel * 100).rounded()))%")

            Button {
                document.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .tip("Zoom in (⌘+)")
        }
    }

    private func sheetTab(_ sheet: Sheet) -> some View {
        let isActive = sheet.id == document.activeSheetID
        return Text(sheet.name)
            .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isActive ? Color.textBackground : .clear)
            .contentShape(Rectangle())
            .onTapGesture {
                document.selectSheet(withID: sheet.id)
            }
            .contextMenu {
                Button("Rename…") {
                    renameText = sheet.name
                    renamingSheetID = sheet.id
                }
                Button("Delete", role: .destructive) {
                    document.selectSheet(withID: sheet.id)
                    document.deleteActiveSheet()
                }
                .disabled(document.workbook.sheets.count <= 1)
            }
            .popover(isPresented: Binding(
                get: { renamingSheetID == sheet.id },
                set: { if !$0 { renamingSheetID = nil } }
            )) {
                VStack {
                    TextField("Sheet name", text: $renameText)
                        .frame(width: 180)
                        .onSubmit {
                            document.selectSheet(withID: sheet.id)
                            document.renameActiveSheet(to: renameText)
                            renamingSheetID = nil
                        }
                }
                .padding(12)
            }
    }

    private var statusText: some View {
        let stats = document.selectionStatistics()
        let text: String
        if stats.numericCount > 1 {
            let sum = NumberFormatEngine.generalString(for: stats.sum)
            let avg = stats.average.map { NumberFormatEngine.generalString(for: ($0 * 1e9).rounded() / 1e9) } ?? ""
            text = "Sum: \(sum)   Avg: \(avg)   Count: \(stats.count)"
        } else if stats.count > 1 {
            text = "Count: \(stats.count)"
        } else {
            text = ""
        }
        return Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

/// The toolbar's font list: common Mac fonts plus the usual Office ones,
/// keeping only those installed (Office fonts appear once Microsoft Office
/// is). Asking the font server about each takes 10-40 ms, so it's done in
/// the background at launch; until it finishes the menu lists them all.
enum FontChoices {
    static let candidates: [String] = [
        CellStyle.defaultFontName, "Helvetica", "Arial", "Avenir Next", "Calibri", "Cambria",
        "Courier New", "Georgia", "Gill Sans", "Menlo", "Palatino", "Times New Roman",
        "Trebuchet MS", "Verdana",
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: [String]?

    static var current: [String] {
        lock.withLock { installed } ?? candidates
    }

    static func prepare() {
        DispatchQueue.global(qos: .utility).async {
            let found = candidates.filter { PlatformFont(name: $0, size: 12) != nil }
            lock.withLock { installed = found }
        }
    }
}
