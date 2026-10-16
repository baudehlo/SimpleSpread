import SwiftUI
import SpreadsheetCore
import SpreadsheetFiles
import UniformTypeIdentifiers

/// App-level registry of open documents (window value -> document).
@MainActor
public final class DocumentStore: ObservableObject {
    public static let shared = DocumentStore()
    private var documents: [Int: SpreadsheetDocument] = [:]
    private var nextID = 1

    public func create(workbook: Workbook? = nil) -> Int {
        let id = nextID
        nextID += 1
        let document = SpreadsheetDocument(workbook: workbook)
        if workbook == nil, ProcessInfo.processInfo.environment["SIMPLESPREAD_DEMO"] != nil {
            DocumentStore.seedDemoContent(document)
        }
        documents[id] = document
        return id
    }

    /// Sample content for screenshots/smoke tests.
    static func seedDemoContent(_ doc: SpreadsheetDocument) {
        func put(_ a1: String, _ text: String) {
            doc.commitInput(text, at: CellAddress(a1: a1)!)
        }
        if ProcessInfo.processInfo.environment["SIMPLESPREAD_DEMO"] == "charts" {
            seedChartsDemo(doc)
            doc.undoManager.removeAllActions()
            return
        }
        put("A1", "Item"); put("B1", "Qty"); put("C1", "Unit Price"); put("D1", "Total")
        put("A2", "Widgets"); put("B2", "12"); put("C2", "$2.50"); put("D2", "=B2*C2")
        put("A3", "Gadgets"); put("B3", "3"); put("C3", "$14.99"); put("D3", "=B3*C3")
        put("A4", "Gizmos"); put("B4", "45"); put("C4", "$0.75"); put("D4", "=B4*C4")
        put("A6", "Subtotal"); put("D6", "=SUM(D2:D4)")
        put("A7", "Tax (8%)"); put("D7", "=D6*8%")
        put("A8", "Grand Total"); put("D8", "=D6+D7")
        put("F1", "Ordered"); put("G1", "1/15/2026")
        put("F2", "Status"); put("G2", "=IF(D8>50,\"review\",\"auto-approve\")")
        doc.selection.select(range: CellRange(a1: "A1:D1")!)
        doc.toggleBold()
        doc.selection.select(range: CellRange(a1: "D2:D8")!)
        doc.setNumberFormat(.currency)
        // Accounting-style rules: under the header, over the subtotal, and a
        // double line under the grand total; filter buttons on the header.
        doc.selection.select(range: CellRange(a1: "A1:D1")!)
        doc.applyBorders(.bottom)
        doc.selection.select(range: CellRange(a1: "D6")!)
        doc.applyBorders(.top)
        doc.selection.select(range: CellRange(a1: "D8")!)
        doc.applyBorders(.doubleBottom)
        doc.selection.select(CellAddress(a1: "A1")!)
        doc.toggleAutoFilter()
        if ProcessInfo.processInfo.environment["SIMPLESPREAD_DEMO"] == "layout" {
            seedLayoutDemo(doc)
        } else {
            doc.selection.select(CellAddress(a1: "D8")!)
        }
        if let z = ProcessInfo.processInfo.environment["SIMPLESPREAD_ZOOM"],
           let zoom = Double(z) {
            doc.setZoom(CGFloat(zoom))
        }
        if let q = ProcessInfo.processInfo.environment["SIMPLESPREAD_FIND"] {
            doc.presentFind()
            doc.setFindQuery(q)
        }
        doc.undoManager.removeAllActions()
    }

    /// `SIMPLESPREAD_DEMO=charts`: a small table with three charts, the
    /// first selected (so the Chart panel shows).
    static func seedChartsDemo(_ doc: SpreadsheetDocument) {
        let rows = [["Month", "North", "South", "West"], ["Jan", "120", "90", "60"], ["Feb", "135", "95", "72"],
                    ["Mar", "150", "110", "80"], ["Apr", "142", "125", "95"], ["May", "168", "130", "101"],
                    ["Jun", "181", "142", "118"]]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() { doc.commitInput(text, at: CellAddress(row: r, column: c)) }
        }
        doc.selection.select(range: CellRange(a1: "A1:D1")!)
        doc.toggleBold()
        let charts: [(SheetChart.Kind, CGRect)] = [
            (.line, CGRect(x: 0, y: 190, width: 400, height: 250)),
            (.pie, CGRect(x: 410, y: 300, width: 300, height: 250)),
            (.column, CGRect(x: 410, y: 20, width: 440, height: 270)),
        ]
        for (kind, frame) in charts {
            doc.selection.select(range: CellRange(a1: "A1:D7")!)
            guard doc.insertChart(kind), let id = doc.selectedChartID else { continue }
            doc.placeChart(id, frame: frame)
        }
        doc.selection.select(CellAddress(a1: "A1")!)
        if let column = doc.activeCharts.last, var settings = column.settings {
            doc.selectChart(column.id)
            settings.title = .text("Sales by region")
            settings.valueAxisTitle = "Units"
            doc.updateChart(column.id, to: settings)
        }
    }

    /// `SIMPLESPREAD_DEMO=layout`: merged cells, a frozen header row, an
    /// active filter and a scrolled view, for checking how they draw.
    static func seedLayoutDemo(_ doc: SpreadsheetDocument) {
        func put(_ a1: String, _ text: String) {
            doc.commitInput(text, at: CellAddress(a1: a1)!)
        }
        doc.confirm = { _, _, _ in true }
        put("F4", "Merged & centered")
        doc.selection.select(range: CellRange(a1: "F4:H5")!)
        doc.mergeSelection(.mergeAndCenter)
        doc.setVerticalAlignment(.middle)
        doc.applyBorders(.thickOutside)
        doc.applyStyleToSelection("Fill Color") { $0.fillColor = RGBAColor(red: 0xFF, green: 0xF4, blue: 0xCC) }
        let fruits = ["Apple", "Pear", "Fig", "Plum"]
        put("A12", "Fruit"); put("B12", "Qty")
        for row in 13...70 {
            put("A\(row)", fruits[row % fruits.count])
            put("B\(row)", String(row))
        }
        doc.selection.select(range: CellRange(a1: "A12:B12")!)
        doc.toggleBold()
        doc.selection.select(CellAddress(a1: "A1")!)
        doc.toggleAutoFilter() // move the filter from the first table to this one
        doc.selection.select(CellAddress(a1: "A12")!)
        doc.toggleAutoFilter()
        doc.setColumnFilter(0, ColumnFilter(values: ["Apple", "Fig"]))
        doc.freezePanes(rows: 1, columns: 1)
        doc.selection.select(CellAddress(a1: ProcessInfo.processInfo.environment["SIMPLESPREAD_CELL"] ?? "B40")!)
        // The grid has no size until its window is up; scroll once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            doc.requestScrollToActiveCell()
        }
    }

    public func register(_ document: SpreadsheetDocument) -> Int {
        let id = nextID
        nextID += 1
        documents[id] = document
        return id
    }

    public func document(for id: Int) -> SpreadsheetDocument {
        if let doc = documents[id] { return doc }
        let doc = SpreadsheetDocument()
        documents[id] = doc
        return doc
    }
}

// MARK: - Menu commands

let xlsxType = UTType(filenameExtension: "xlsx") ?? .data

/// Run a menu command on the focused document. Commands act on committed
/// cells, so any typing still in the cell editor or formula bar is written
/// to its cell first (menu items do not take keyboard focus).
@MainActor
func perform(_ document: SpreadsheetDocument?, _ command: (SpreadsheetDocument) -> Void) {
    guard let document else { return }
    document.commitPendingEdit()
    command(document)
}

struct EditCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        // Undo/Redo and Cut/Copy/Paste/Delete/Select All are the standard
        // items, which send undo:/copy:/paste:… to the first responder. A
        // focused text field (cell editor, formula bar, Find, name box, sheet
        // rename) handles them itself; SpreadsheetGridView handles them when
        // the grid has focus. Replacing them with buttons that called the
        // document made ⌘V/⌘Z/⌘A act on the grid while the user was typing.
        CommandGroup(after: .pasteboard) {
            Divider()
            DocumentCommandItems(commands: DocumentCommand.menu("Edit"), document: document)
        }
    }
}

struct ViewCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document
    @ObservedObject private var appearance = AppearanceSetting.shared

    var body: some Commands {
        // .toolbar placement lands these in the standard View menu.
        CommandGroup(before: .toolbar) {
            Picker("Appearance", selection: $appearance.choice) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }

            Divider()
            DocumentCommandItems(commands: DocumentCommand.menu("View"), document: document)
            Divider()
        }
    }
}

struct InsertCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandMenu("Insert") {
            DocumentCommandItems(commands: DocumentCommand.menu("Insert"), document: document)
        }
    }
}

struct DataCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandMenu("Data") {
            DocumentCommandItems(commands: DocumentCommand.menu("Data"), document: document)
        }
    }
}

struct FormatCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandMenu("Format") {
            DocumentCommandItems(commands: DocumentCommand.menu("Format"), document: document)
        }
    }
}

/// Focused-value plumbing so menu commands reach the active window's document.
struct DocumentFocusKey: FocusedValueKey {
    typealias Value = SpreadsheetDocument
}

// Menu commands reach a pending cell edit through the document
// (SpreadsheetDocument.commitPendingEdit), and the standard Edit items
// (cut/copy/paste/undo) reach the grid through the responder chain.

extension FocusedValues {
    var spreadsheetDocument: SpreadsheetDocument? {
        get { self[DocumentFocusKey.self] }
        set { self[DocumentFocusKey.self] = newValue }
    }
}
