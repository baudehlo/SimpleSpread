import SwiftUI
import AppKit
import SpreadsheetCore
import UniformTypeIdentifiers

/// One document window: toolbar, formula bar, grid, sheet tabs, status bar.
public struct DocumentWindowView: View {
    @ObservedObject var document: SpreadsheetDocument
    @State private var formulaBarText = ""
    @State private var nameBoxText = "A1"
    @State private var formulaBarFocused = false
    @State private var renamingSheetID: Int?
    @State private var renameText = ""
    @State private var gridRevision = 0

    public init(document: SpreadsheetDocument) {
        self.document = document
    }

    public var body: some View {
        VStack(spacing: 0) {
            formatBar
            Divider()
            formulaBar
            Divider()
            GridContainer(document: document, revision: gridRevision) {
                syncFromDocument()
            }
            Divider()
            bottomBar
        }
        .onAppear { syncFromDocument() }
        .onReceive(document.$revision) { _ in syncFromDocument() }
        .onReceive(document.$selection) { _ in syncFromDocument() }
        .focusedSceneValue(\.spreadsheetDocument, document)
        .navigationTitle(document.displayName)
        .navigationSubtitle(document.isModified ? "— Edited" : "")
    }

    private func syncFromDocument() {
        if !formulaBarFocused {
            formulaBarText = document.editString(at: document.selection.activeCell)
        }
        let range = document.selection.range
        nameBoxText = range.isSingleCell ? document.selection.activeCell.a1 : range.a1
        gridRevision += 1
    }

    // MARK: Format toolbar

    private var activeStyle: CellStyle {
        document.style(at: document.selection.activeCell)
    }

    private var formatBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                styleToggle("bold", active: activeStyle.bold) { document.toggleBold() }
                    .keyboardShortcut("b", modifiers: .command)
                styleToggle("italic", active: activeStyle.italic) { document.toggleItalic() }
                    .keyboardShortcut("i", modifiers: .command)
                styleToggle("underline", active: activeStyle.underline) { document.toggleUnderline() }
                    .keyboardShortcut("u", modifiers: .command)
            }
            Divider().frame(height: 16)
            HStack(spacing: 2) {
                alignButton(.left, icon: "text.alignleft")
                alignButton(.center, icon: "text.aligncenter")
                alignButton(.right, icon: "text.alignright")
            }
            Divider().frame(height: 16)
            numberFormatMenu
            Divider().frame(height: 16)
            // NSColorWell has a fixed intrinsic size — never clamp its frame
            // (a narrower frame clips and the well overflows onto neighbors).
            HStack(spacing: 4) {
                Image(systemName: "character")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ColorPicker("", selection: textColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
            }
            .help("Text color")
            HStack(spacing: 4) {
                Image(systemName: "paintbrush.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ColorPicker("", selection: fillColorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .fixedSize()
            }
            .help("Fill color")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func styleToggle(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 22, height: 20)
                .background(active ? Color.accentColor.opacity(0.25) : .clear)
                .cornerRadius(4)
        }
        .buttonStyle(.borderless)
    }

    private func alignButton(_ alignment: TextAlignmentH, icon: String) -> some View {
        styleToggle(icon, active: activeStyle.horizontalAlignment == alignment) {
            document.setHorizontalAlignment(alignment)
        }
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Number format")
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
            colorFrom(activeStyle.textColor) ?? Color(NSColor.textColor)
        } set: { newColor in
            let rgba = rgbaFrom(newColor)
            document.applyStyleToSelection("Text Color") { $0.textColor = rgba }
        }
    }

    private var fillColorBinding: Binding<Color> {
        Binding {
            colorFrom(activeStyle.fillColor) ?? Color(NSColor.textBackgroundColor)
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
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return RGBAColor(red: UInt8(ns.redComponent * 255),
                         green: UInt8(ns.greenComponent * 255),
                         blue: UInt8(ns.blueComponent * 255),
                         alpha: UInt8(ns.alphaComponent * 255))
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
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
            Image(systemName: "function")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField("", text: $formulaBarText, onEditingChanged: { editing in
                formulaBarFocused = editing
            })
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .onSubmit {
                document.commitInput(formulaBarText, at: document.selection.activeCell)
                formulaBarFocused = false
                syncFromDocument()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func navigateToNameBox() {
        let text = nameBoxText.trimmingCharacters(in: .whitespaces)
        if let range = CellRange(a1: text) {
            document.selection.select(range: range)
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
            .help("Add sheet")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(document.workbook.sheets, id: \.id) { sheet in
                        sheetTab(sheet)
                    }
                }
            }
            Spacer()
            statusText
                .padding(.trailing, 12)
        }
        .frame(height: 28)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func sheetTab(_ sheet: Sheet) -> some View {
        let isActive = sheet.id == document.activeSheetID
        return Text(sheet.name)
            .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isActive ? Color(NSColor.textBackgroundColor) : .clear)
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
