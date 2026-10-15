#if os(macOS)
import SwiftUI
import AppKit
import SpreadsheetCore
import UniformTypeIdentifiers

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
        MainActor.assumeIsolated { AppearanceSetting.shared.apply() }
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

/// App-menu items: "Check for Updates…" plus the automatic-check toggle,
/// placed just under "About SimpleSpread". Backed by Sparkle.
#if APP_STORE
/// The App Store build has no updater of its own.
struct AppInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {}
    }
}
#else
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

#endif

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
#endif
