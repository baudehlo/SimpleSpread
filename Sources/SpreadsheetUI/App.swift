import SwiftUI
import AppKit
import SpreadsheetCore
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
        doc.selection.select(CellAddress(a1: "D8")!)
        if let z = ProcessInfo.processInfo.environment["SIMPLESPREAD_ZOOM"],
           let zoom = Double(z) {
            doc.setZoom(CGFloat(zoom))
        }
        doc.undoManager.removeAllActions()
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

public enum SimpleSpreadApp {
    /// MainActor: App.main() is main-actor-isolated (older compilers don't
    /// infer this call site's isolation; main.swift top-level code is
    /// implicitly MainActor, so callers need no change).
    @MainActor
    public static func run() {
        SimpleSpreadAppMain.main()
    }
}

struct SimpleSpreadAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(for: Int.self) { $docID in
            DocumentWindowView(document: DocumentStore.shared.document(for: docID ?? 0))
                .frame(minWidth: 640, minHeight: 400)
        } defaultValue: {
            DocumentStore.shared.create()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            FileCommands()
            EditCommands()
            ViewCommands()
            InsertCommands()
            FormatCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SwiftPM binary (no bundle): become a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Headless smoke-test hook: render the main window to a PNG and quit.
        if let path = ProcessInfo.processInfo.environment["SIMPLESPREAD_SCREENSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Self.captureMainWindow(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    @MainActor
    static func captureMainWindow(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let contentView = window.contentView,
              let root = contentView.superview ?? window.contentView else { return }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Menu commands

let xlsxType = UTType(filenameExtension: "xlsx") ?? .data

struct FileCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                openWindow(value: DocumentStore.shared.create())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open…") {
                openDocument()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                save(as: false)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(document == nil)

            Button("Save As…") {
                save(as: true)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(document == nil)

            Divider()

            Button("Import CSV as Sheet…") {
                importCSV()
            }
            .disabled(document == nil)

            Button("Export Sheet as CSV…") {
                exportCSV()
            }
            .disabled(document == nil)
        }
    }

    @MainActor private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [xlsxType, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let doc = try SpreadsheetDocument.open(url: url)
            openWindow(value: DocumentStore.shared.register(doc))
        } catch {
            presentError(error, message: "Could not open \(url.lastPathComponent)")
        }
    }

    @MainActor private func save(as forceAs: Bool) {
        guard let document else { return }
        if let url = document.fileURL, !forceAs {
            do {
                try document.save(to: url)
            } catch {
                presentError(error, message: "Could not save")
            }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [xlsxType]
        panel.nameFieldStringValue = document.displayName + ".xlsx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.save(to: url)
        } catch {
            presentError(error, message: "Could not save")
        }
    }

    @MainActor private func importCSV() {
        guard let document else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.importCSVSheet(from: url)
        } catch {
            presentError(error, message: "Could not import CSV")
        }
    }

    @MainActor private func exportCSV() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = document.activeSheet.name + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.exportActiveSheetCSV(to: url)
        } catch {
            presentError(error, message: "Could not export CSV")
        }
    }

    @MainActor private func presentError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

struct EditCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                document?.undoManager.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(document?.undoManager.canUndo != true)

            Button("Redo") {
                document?.undoManager.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(document?.undoManager.canRedo != true)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                document?.copySelectionToPasteboard(cut: true)
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(document == nil)

            Button("Copy") {
                document?.copySelectionToPasteboard()
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(document == nil)

            Button("Paste") {
                document?.pasteFromPasteboard()
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(document == nil)

            Button("Delete") {
                document?.clearSelectionContents()
            }
            .disabled(document == nil)

            Divider()

            Button("Select All") {
                if let document {
                    let used = document.activeSheet.usedRange
                        ?? CellRange(CellAddress(row: 0, column: 0))
                    document.selection.select(range: CellRange(
                        start: CellAddress(row: 0, column: 0), end: used.end))
                }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(document == nil)
        }
    }
}

struct ViewCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        // .toolbar placement lands these in the standard View menu.
        CommandGroup(before: .toolbar) {
            Button("Zoom In") {
                document?.zoomIn()
            }
            .keyboardShortcut("=", modifiers: .command) // acts as the conventional ⌘+
            .disabled(document == nil)

            Button("Zoom Out") {
                document?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(document == nil)

            Button("Actual Size") {
                document?.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(document == nil)

            Divider()
        }
    }
}

struct InsertCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandMenu("Insert") {
            Button("Row Above") {
                guard let document else { return }
                document.insertRows(at: document.selection.range.start.row,
                                    count: document.selection.range.rowCount)
            }
            Button("Row Below") {
                guard let document else { return }
                document.insertRows(at: document.selection.range.end.row + 1,
                                    count: document.selection.range.rowCount)
            }
            Button("Column Left") {
                guard let document else { return }
                document.insertColumns(at: document.selection.range.start.column,
                                       count: document.selection.range.columnCount)
            }
            Button("Column Right") {
                guard let document else { return }
                document.insertColumns(at: document.selection.range.end.column + 1,
                                       count: document.selection.range.columnCount)
            }
            Divider()
            Button("Delete Selected Rows") {
                guard let document else { return }
                document.deleteRows(at: document.selection.range.start.row,
                                    count: document.selection.range.rowCount)
            }
            Button("Delete Selected Columns") {
                guard let document else { return }
                document.deleteColumns(at: document.selection.range.start.column,
                                       count: document.selection.range.columnCount)
            }
            Divider()
            Button("New Sheet") {
                document?.addSheet()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

struct FormatCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { document?.toggleBold() }
                .disabled(document == nil)
            Button("Italic") { document?.toggleItalic() }
                .disabled(document == nil)
            Button("Underline") { document?.toggleUnderline() }
                .disabled(document == nil)
            Divider()
            ForEach(DocumentWindowView.formatChoices, id: \.0) { name, format in
                Button(name) {
                    document?.setNumberFormat(format)
                }
                .disabled(document == nil)
            }
        }
    }
}
