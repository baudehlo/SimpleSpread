#if os(macOS)
import SwiftUI
import AppKit
import SpreadsheetCore

/// Saving plus the standard macOS "Do you want to save the changes…?" flow
/// for closing a window or quitting with unsaved edits. Prompts are sheets on
/// the document's window when there is one, app-modal otherwise.
extension DocumentSaving {
    /// Save in place, or ask for a location when the document has no file
    /// yet (or `forceAs`). `completion(true)` only once the file is written
    /// (in the background: see BackgroundSaver).
    ///
    /// While the document is already saving, the request waits for that
    /// save and then runs from a fresh snapshot, so two saves of one file
    /// never run at once and nothing typed meanwhile is missed. A ⌘S that
    /// finds nothing changed by then is done: pressing ⌘S three times
    /// during a long save writes once more, not three times.
    static func save(_ document: SpreadsheetDocument, as forceAs: Bool = false,
                     in window: NSWindow?, completion: @escaping (Bool) -> Void = { _ in }) {
        if BackgroundSaver.isSaving(document) {
            BackgroundSaver.whenIdle(document) {
                if !forceAs, !document.isModified, !document.hasPendingEdit,
                   case .write = plan(for: document) {
                    return completion(true)
                }
                save(document, as: forceAs, in: window, completion: completion)
            }
            return
        }
        switch plan(for: document, as: forceAs) {
        case .write(let url):
            write(document, to: url, in: window, completion: completion)
        case .choose(let note):
            choose(document, note: note, in: window, completion: completion)
        case .confirmLoss(let url, let items):
            confirmLoss(document, items: items, in: window) { choice in
                switch choice {
                case .alertFirstButtonReturn: // Save a Copy…
                    choose(document, note: lossNote(document, items), copy: true, in: window, completion: completion)
                case .alertSecondButtonReturn: // Save Anyway
                    write(document, to: url, in: window, completion: completion)
                default:
                    completion(false)
                }
            }
        }
    }

    /// The first ⌘S of a file holding content SimpleSpread can't write
    /// back: Save a Copy… (default), Save Anyway, or Cancel.
    private static func confirmLoss(_ document: SpreadsheetDocument, items: [String], in window: NSWindow?,
                                    completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(document.displayName)” has content SimpleSpread can’t save"
        alert.informativeText = "Saving over the original file will remove its \(list(items)). "
            + "Save a copy to keep the original as it is."
        alert.addButton(withTitle: "Save a Copy…")
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel") // Escape
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            // Take the alert sheet down before a save panel sheet goes up.
            alert.window.orderOut(nil)
            completion(response)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// The Save panel. `copy`: offer "<name> copy.xlsx" beside the original.
    private static func choose(_ document: SpreadsheetDocument, note: String?, copy: Bool = false,
                               in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [xlsxType]
        // Pre-fill the source name (e.g. pricing.xlsx after opening pricing.csv).
        panel.nameFieldStringValue = copy ? copyName(for: document.saveFileName) : document.saveFileName
        if let directory = document.fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
        if let note { panel.message = note }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return completion(false) }
            write(document, to: url, in: window, completion: completion)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Write in the background. Cancel in the progress panel is not an
    /// error: nothing is written and `completion(false)`.
    private static func write(_ document: SpreadsheetDocument, to url: URL, in window: NSWindow?,
                              completion: @escaping (Bool) -> Void) {
        BackgroundSaver.save(document, to: url, in: window) { outcome in
            switch outcome {
            case .saved:
                RecentFilesManager.shared.record(url)
                completion(true)
            case .cancelled:
                completion(false)
            case .failed(let error):
                let alert = NSAlert()
                alert.messageText = "Could not save"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                completion(false)
            }
        }
    }

    /// Ask whether to save unsaved changes. `completion(true)` means the
    /// document may now go away (saved, or the user chose Don't Save);
    /// false means Cancel (or a failed/cancelled save).
    static func confirmDiscard(_ document: SpreadsheetDocument, in window: NSWindow?,
                               completion: @escaping (Bool) -> Void) {
        // Typing still in an editor is part of the document's changes.
        document.commitPendingEdit()
        guard document.isModified else { return completion(true) }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to the document “\(document.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                // Take the alert sheet down before the save panel sheet goes up.
                alert.window.orderOut(nil)
                // Saving runs in the background and the window stays
                // usable: anything changed meanwhile isn't saved, so the
                // window stays open rather than lose it.
                save(document, in: window) { ok in completion(ok && !document.isModified) }
            case .alertThirdButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Windows whose documents have unsaved changes, front-most first.
    static func modifiedDocumentWindows() -> [(NSWindow, SpreadsheetDocument)] {
        NSApp.orderedWindows.compactMap { window in
            guard window.isVisible || window.isMiniaturized,
                  let proxy = window.delegate as? DocumentWindowDelegate,
                  let document = proxy.document,
                  document.isModified || document.hasPendingEdit else { return nil }
            return (window, document)
        }
    }

    /// Quit-time review (applicationShouldTerminate). One modified document
    /// gets the usual save prompt; several get Finder-style "Review Changes…
    /// / Cancel / Discard Changes" first, then a prompt per document.
    static func reviewBeforeQuit(completion: @escaping (Bool) -> Void) {
        // Saves (imports, exports) still running finish first, their panels
        // showing why the app hasn't quit yet; then whatever is still
        // unsaved is reviewed.
        guard BackgroundFileTask.isIdle else {
            BackgroundFileTask.showAllProgress()
            BackgroundFileTask.whenAllIdle { reviewBeforeQuit(completion: completion) }
            return
        }
        let pending = modifiedDocumentWindows()
        guard !pending.isEmpty else { return completion(true) }
        if pending.count > 1 {
            let alert = NSAlert()
            alert.messageText = "You have \(pending.count) SimpleSpread documents with unsaved changes. Do you want to review these changes before quitting?"
            alert.informativeText = "If you don’t review your documents, all your changes will be lost."
            alert.addButton(withTitle: "Review Changes…")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes")
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertThirdButtonReturn: return completion(true)
            default: return completion(false)
            }
        }
        func next(_ remaining: ArraySlice<(NSWindow, SpreadsheetDocument)>) {
            guard let (window, document) = remaining.first else { return completion(true) }
            confirmDiscard(document, in: window) { ok in
                ok ? next(remaining.dropFirst()) : completion(false)
            }
        }
        next(pending[...])
    }
}

/// Sits in front of SwiftUI's own window delegate to intercept
/// windowShouldClose; every other delegate message is forwarded untouched.
@MainActor
final class DocumentWindowDelegate: NSObject, NSWindowDelegate {
    weak var document: SpreadsheetDocument?
    /// nonisolated: read from the NSObject forwarding overrides; only ever
    /// touched on the main thread (AppKit delegate traffic).
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    /// Set once the user has answered the prompt, so the re-issued close goes through.
    private var closeConfirmed = false
    /// A close is waiting for the document's save to finish.
    private var closeWaitsForSave = false

    init(document: SpreadsheetDocument, original: NSWindowDelegate?) {
        self.document = document
        self.original = original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let originalAllows = original?.windowShouldClose?(sender) ?? true
        // A save in flight would be lost with the window: show its progress
        // and close once it is over (asking first if something is still
        // unsaved, e.g. after Cancel or typing during the save).
        if originalAllows, let document, BackgroundSaver.isSaving(document) {
            BackgroundSaver.showProgress(for: document)
            if !closeWaitsForSave {
                closeWaitsForSave = true
                BackgroundSaver.whenIdle(document) { [weak self] in
                    self?.closeWaitsForSave = false
                    sender.performClose(nil)
                }
            }
            return false
        }
        // An open cell editor counts as unsaved work: commit it so the
        // prompt below covers it.
        if originalAllows, !closeConfirmed { document?.commitPendingEdit() }
        guard originalAllows, !closeConfirmed, let document, document.isModified else {
            return originalAllows
        }
        DocumentSaving.confirmDiscard(document, in: sender) { [weak self] ok in
            guard ok else { return }
            self?.closeConfirmed = true
            // The sheet is still attached while its completion runs, and a
            // window with a sheet refuses to close; retry on the next turn.
            DispatchQueue.main.async { sender.performClose(nil) }
        }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Invisible view that finds its NSWindow, installs DocumentWindowDelegate,
/// and mirrors isModified into the close button's "edited" dot.
struct DocumentWindowHook: NSViewRepresentable {
    @ObservedObject var document: SpreadsheetDocument

    final class HookView: NSView {
        var document: SpreadsheetDocument?
        private var proxy: DocumentWindowDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            guard let window, let document else { return }
            // SwiftUI may swap its delegate; re-wrap whenever we're not in front.
            if let proxy, window.delegate === proxy {
                proxy.document = document
            } else {
                proxy = DocumentWindowDelegate(document: document, original: window.delegate)
                window.delegate = proxy
            }
            window.isDocumentEdited = document.isModified
            // Documents are not reopened at launch, so a restored window would
            // only be an empty sheet. After a crash or a forced quit macOS
            // restored every window (once 255 of them); never restore.
            window.isRestorable = false
        }
    }

    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.document = document
        return view
    }

    func updateNSView(_ view: HookView, context: Context) {
        view.document = document
        view.install()
    }
}
#endif
