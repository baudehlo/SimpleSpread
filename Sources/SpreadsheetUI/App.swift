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
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(for: Int.self) { $docID in
            DocumentWindowView(document: DocumentStore.shared.document(for: docID))
                .frame(minWidth: 640, minHeight: 400)
                // Finder double-click / `open <file>` / drag-onto-icon: route
                // each URL through the same open flow the File menu uses.
                .onReceive(NotificationCenter.default.publisher(for: .simpleSpreadOpenURL)) { note in
                    // Every open window gets this notification. Only the first
                    // one to claim the request opens the file; without this, N
                    // windows opened N copies.
                    guard let request = note.object as? OpenRequest, request.claim() else { return }
                    let url = request.url
                    // Loads in the background, with progress for big files.
                    FileLoader.open(url) { doc in
                        RecentFilesManager.shared.record(url)
                        openWindow(value: DocumentStore.shared.register(doc))
                    }
                }
        } defaultValue: {
            DocumentStore.shared.create()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            AppInfoCommands()
            FileCommands()
            EditCommands()
            ViewCommands()
            InsertCommands()
            DataCommands()
            FormatCommands()
        }
    }
}

extension Notification.Name {
    static let simpleSpreadOpenURL = Notification.Name("SimpleSpreadOpenURL")
}

/// One request to open a file. Posted to every window; the first window to
/// `claim()` it does the open, the rest ignore it.
@MainActor
final class OpenRequest {
    let url: URL
    private var claimed = false

    init(url: URL) {
        self.url = url
    }

    /// True for the first caller only.
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }

    /// Ask the open windows to open `url` (exactly once).
    static func post(_ url: URL) {
        NotificationCenter.default.post(name: .simpleSpreadOpenURL, object: OpenRequest(url: url))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// URLs delivered before a scene is listening (e.g. launch-to-open).
    private var queuedURLs: [URL] = []
    private var ready = false

    /// Finder double-click, `open <file>`, drag-onto-Dock-icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if ready {
                OpenRequest.post(url)
            } else {
                queuedURLs.append(url)
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restoration runs before didFinishLaunching, so opt out here.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontChoices.prepare()
        // Running as a bare SwiftPM binary (no bundle): become a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // A scene is now listening; flush any launch-time open requests.
        ready = true
        let pending = queuedURLs
        queuedURLs.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            for url in pending {
                OpenRequest.post(url)
            }
        }

        // Sparkle schedules its own automatic checks (per the Info.plist
        // SUEnableAutomaticChecks / SUScheduledCheckInterval settings); no
        // manual launch check is needed. Touching SparkleUpdater.shared here
        // would start it before a scene exists, so leave it to first menu use.

        // Headless open hook: drive the real open→window flow. With a
        // screenshot request the capture hook terminates; otherwise quit after
        // a moment so the hook never leaves an app running.
        if let openPath = ProcessInfo.processInfo.environment["SIMPLESPREAD_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                OpenRequest.post(URL(fileURLWithPath: openPath))
                if ProcessInfo.processInfo.environment["SIMPLESPREAD_SCREENSHOT"] == nil {
                    // Files load in the background: quit once it has opened.
                    Self.whenLoaderIdle {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }

        // Headless smoke-test hook: render the main window to a PNG and quit.
        if let path = ProcessInfo.processInfo.environment["SIMPLESPREAD_SCREENSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // A file opened by SIMPLESPREAD_OPEN may still be loading.
                Self.whenLoaderIdle {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        Self.captureMainWindow(to: path)
                        NSApp.terminate(nil)
                    }
                }
            }
        }

    }

    /// Run `body` once no file is loading (polled; for the headless hooks).
    @MainActor
    static func whenLoaderIdle(_ body: @escaping @MainActor () -> Void) {
        if FileLoader.isIdle {
            body()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenLoaderIdle(body) }
        }
    }

    @MainActor
    static func captureMainWindow(to path: String) {
        // Prefer the key/main window (the most recently opened one) so open
        // hooks screenshot the document they just loaded, not the launch window.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        guard let window,
              let contentView = window.contentView,
              let root = contentView.superview ?? window.contentView else { return }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Relinquish security-scoped resources opened via Open Recent.
        MainActor.assumeIsolated { RecentFilesManager.shared.releaseAllScopes() }
    }

    /// Quit with unsaved documents: ask before throwing edits away. The
    /// headless screenshot/open hooks quit on their own and must never block.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let env = ProcessInfo.processInfo.environment
        if env["SIMPLESPREAD_SCREENSHOT"] != nil || env["SIMPLESPREAD_OPEN"] != nil {
            return .terminateNow
        }
        return MainActor.assumeIsolated {
            // A save still being written counts as unsaved work.
            if DocumentSaving.modifiedDocumentWindows().isEmpty, BackgroundFileTask.isIdle { return .terminateNow }
            DocumentSaving.reviewBeforeQuit { ok in
                sender.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// No window restoration: files are not reopened at launch, so restored
    /// windows were empty sheets (and piled up after crashes or forced quits).
    func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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

/// App-menu items: "Check for Updates…" plus the automatic-check toggle,
/// placed just under "About SimpleSpread". Backed by Sparkle.
struct AppInfoCommands: Commands {
    @ObservedObject private var updater = SparkleUpdater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Toggle("Automatically Check for Updates",
                   isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
        }
    }
}

struct FileCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var recent = RecentFilesManager.shared

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

            Menu("Open Recent") {
                ForEach(recent.entries, id: \.path) { entry in
                    Button(entry.displayName) {
                        openRecent(entry)
                    }
                    .disabled(!entry.exists)
                }
                if !recent.entries.isEmpty {
                    Divider()
                    Button("Clear Menu") { recent.clear() }
                }
            }
            .disabled(recent.entries.isEmpty)

            Divider()

            // SwiftUI doesn't always supply a working Close item for a
            // WindowGroup with custom commands (⌘W was beeping); provide it.
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
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
        // Accept XLSX plus any delimited-text type. Some CSV/TSV files resolve
        // to public.plain-text on disk, so allowing plain text (and matching by
        // extension) keeps them selectable instead of greyed out.
        panel.allowedContentTypes = [xlsxType, .commaSeparatedText, .tabSeparatedText,
                                     .plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Route through the same notification the Finder-open path uses; its
        // handler lives in the scene's view hierarchy where openWindow is
        // reliably wired (openWindow from a Commands struct can no-op).
        OpenRequest.post(url)
    }

    @MainActor private func openRecent(_ entry: RecentEntry) {
        guard let url = RecentFilesManager.shared.urlForOpening(entry) else {
            let alert = NSAlert()
            alert.messageText = "Can’t open “\(entry.displayName)”"
            alert.informativeText = "The file may have been moved, renamed, or deleted."
            alert.runModal()
            return
        }
        OpenRequest.post(url)
    }

    @MainActor private func save(as forceAs: Bool) {
        guard let document else { return }
        document.commitPendingEdit()
        DocumentSaving.save(document, as: forceAs, in: NSApp.keyWindow)
    }

    @MainActor private func importCSV() {
        guard let document else { return }
        document.commitPendingEdit()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BackgroundCSV.importSheet(into: document, from: url, in: NSApp.keyWindow) { error in
            presentError(error, message: "Could not import CSV")
        }
    }

    @MainActor private func exportCSV() {
        guard let document else { return }
        document.commitPendingEdit()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = document.activeSheet.name + ".csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BackgroundCSV.exportActiveSheet(of: document, to: url, in: NSApp.keyWindow) { error in
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
        // Undo/Redo and Cut/Copy/Paste/Delete/Select All are the standard
        // items, which send undo:/copy:/paste:… to the first responder. A
        // focused text field (cell editor, formula bar, Find, name box, sheet
        // rename) handles them itself; SpreadsheetGridView handles them when
        // the grid has focus. Replacing them with buttons that called the
        // document made ⌘V/⌘Z/⌘A act on the grid while the user was typing.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Fill Down") {
                perform(document) { $0.fillDown() }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(document == nil)

            Button("Fill Right") {
                perform(document) { $0.fillRight() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(document == nil)

            Divider()
            Button("Find…") {
                perform(document) { $0.presentFind() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(document == nil)

            Button("Find Next") {
                perform(document) { $0.findNext() }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled((document?.findMatches.isEmpty ?? true))

            Button("Find Previous") {
                perform(document) { $0.findPrevious() }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled((document?.findMatches.isEmpty ?? true))
        }
    }
}

struct ViewCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        // .toolbar placement lands these in the standard View menu.
        CommandGroup(before: .toolbar) {
            Button("Zoom In") {
                perform(document) { $0.zoomIn() }
            }
            .keyboardShortcut("=", modifiers: .command) // acts as the conventional ⌘+
            .disabled(document == nil)

            Button("Zoom Out") {
                perform(document) { $0.zoomOut() }
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(document == nil)

            Button("Actual Size") {
                perform(document) { $0.resetZoom() }
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(document == nil)

            Divider()

            Button("Freeze Panes") { perform(document) { $0.freezePanesAtSelection() } }
                .disabled(document == nil || document?.selection.activeCell == CellAddress(row: 0, column: 0))
            Button("Freeze Top Row") { perform(document) { $0.freezePanes(rows: 1, columns: 0) } }
                .disabled(document == nil)
            Button("Freeze First Column") { perform(document) { $0.freezePanes(rows: 0, columns: 1) } }
                .disabled(document == nil)
            Button("Unfreeze Panes") { perform(document) { $0.freezePanes(rows: 0, columns: 0) } }
                .disabled(document?.hasFrozenPanes != true)

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
                document.commitPendingEdit()
                document.insertRows(at: document.selection.range.start.row,
                                    count: document.selection.range.rowCount)
            }
            Button("Row Below") {
                guard let document else { return }
                document.commitPendingEdit()
                document.insertRows(at: document.selection.range.end.row + 1,
                                    count: document.selection.range.rowCount)
            }
            Button("Column Left") {
                guard let document else { return }
                document.commitPendingEdit()
                document.insertColumns(at: document.selection.range.start.column,
                                       count: document.selection.range.columnCount)
            }
            Button("Column Right") {
                guard let document else { return }
                document.commitPendingEdit()
                document.insertColumns(at: document.selection.range.end.column + 1,
                                       count: document.selection.range.columnCount)
            }
            Divider()
            Button("Delete Selected Rows") {
                guard let document else { return }
                document.commitPendingEdit()
                document.deleteRows(at: document.selection.range.start.row,
                                    count: document.selection.range.rowCount)
            }
            Button("Delete Selected Columns") {
                guard let document else { return }
                document.commitPendingEdit()
                document.deleteColumns(at: document.selection.range.start.column,
                                       count: document.selection.range.columnCount)
            }
            Divider()
            Button("New Sheet") {
                perform(document) { $0.addSheet() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("PivotTable…") {
                perform(document) { $0.isInsertPivotPresented = true }
            }
            .disabled(document == nil)
        }
    }
}

struct DataCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandMenu("Data") {
            Button("Sort A to Z") { perform(document) { $0.quickSort(ascending: true) } }
                .disabled(document == nil)
            Button("Sort Z to A") { perform(document) { $0.quickSort(ascending: false) } }
                .disabled(document == nil)
            Button("Custom Sort…") { perform(document) { $0.isSortPresented = true } }
                .disabled(document == nil)
            Divider()
            Button(document?.activeAutoFilter == nil ? "Filter" : "Remove Filter") {
                perform(document) { $0.toggleAutoFilter() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(document == nil)
            Button("Clear Filters") { perform(document) { $0.clearAllFilters() } }
                .disabled(document?.activeAutoFilter?.columns.isEmpty ?? true)
            Button("Reapply Filter") { perform(document) { $0.reapplyAutoFilter() } }
                .disabled(document?.activeAutoFilter == nil)
            Divider()
            Button("Refresh") {
                guard let document, let pivot = document.activePivotIndex else { return }
                document.commitPendingEdit()
                document.refreshPivot(pivot)
            }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: .option)
            .disabled(document?.activePivotIndex == nil)
            Button("Refresh All") {
                perform(document) { $0.refreshAllPivots() }
            }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [.control, .option])
            .disabled(document?.workbook.pivotTables.isEmpty ?? true)
            Divider()
            Button(document?.isPivotPanelVisible == false ? "Show PivotTable Fields" : "Hide PivotTable Fields") {
                perform(document) { $0.isPivotPanelVisible.toggle() }
            }
            .disabled(document == nil)
        }
    }
}

struct FormatCommands: Commands {
    @FocusedValue(\.spreadsheetDocument) var document

    var body: some Commands {
        CommandMenu("Format") {
            Button("Bold") { perform(document) { $0.toggleBold() } }
                .disabled(document == nil)
            Button("Italic") { perform(document) { $0.toggleItalic() } }
                .disabled(document == nil)
            Button("Underline") { perform(document) { $0.toggleUnderline() } }
                .disabled(document == nil)
            Button("Strikethrough") { perform(document) { $0.toggleStrikethrough() } }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(document == nil)
            Divider()
            ForEach(DocumentWindowView.formatChoices, id: \.0) { name, format in
                Button(name) {
                    perform(document) { $0.setNumberFormat(format) }
                }
                .disabled(document == nil)
            }
            Divider()
            Button("Increase Indent") { perform(document) { $0.adjustIndent(by: 1) } }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(document == nil)
            Button("Decrease Indent") { perform(document) { $0.adjustIndent(by: -1) } }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(document == nil)
            Menu("Borders") {
                ForEach(DocumentWindowView.borderChoices, id: \.0) { name, preset in
                    Button(name) { perform(document) { $0.applyBorders(preset) } }
                }
            }
            .disabled(document == nil)
            Menu("Merge Cells") {
                Button("Merge & Center") { perform(document) { $0.mergeSelection(.mergeAndCenter) } }
                Button("Merge Across") { perform(document) { $0.mergeSelection(.mergeAcross) } }
                Button("Merge Cells") { perform(document) { $0.mergeSelection(.merge) } }
                Button("Unmerge Cells") { perform(document) { $0.unmergeSelection() } }
                    .disabled(document?.selectionHasMerge != true)
            }
            .disabled(document == nil)
            Divider()
            Button("Clear Formatting") { perform(document) { $0.clearFormattingInSelection() } }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(document == nil)
        }
    }
}
