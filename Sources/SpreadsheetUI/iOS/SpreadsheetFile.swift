#if os(iOS)
import UIKit
import Combine
import SpreadsheetCore
import SpreadsheetFiles

/// A spreadsheet file on iPad. UIDocument coordinates access with iCloud
/// Drive and other apps, autosaves, and notices when the file changes
/// elsewhere; SimpleSpread's own reader and writer do the work, off the
/// main thread (UIDocument calls read and write on a background queue).
///
/// A file holding content SimpleSpread can't write back (charts, macros…)
/// isn't autosaved until the user has said what to do (see EditorScreen):
/// saving over it would quietly lose that content.
final class SpreadsheetFile: UIDocument {
    private let lock = NSLock()
    /// Read on the background queue, handed to the main thread once.
    private var loaded: LoadedFile?
    /// The `changeCount` of the snapshot being written.
    private var writtenChangeCount: Int?
    /// Mirrors the document's modified state for UIDocument, which asks
    /// from any thread.
    private var unsavedChanges = false
    private var failure: Error?
    let cancellation = TaskCancellation()
    /// Load progress (set before opening), called on the reading thread.
    var loadProgress: (@Sendable (Double?, LoadPhase) -> Void)?

    /// Main thread only.
    nonisolated(unsafe) private var openDocument: SpreadsheetDocument?
    nonisolated(unsafe) private var watch: AnyCancellable?
    /// Called on the main thread when the file was reloaded because it
    /// changed elsewhere: the new document replaces the old.
    nonisolated(unsafe) var onReload: ((SpreadsheetDocument) -> Void)?

    @MainActor var document: SpreadsheetDocument? { openDocument }

    /// The error that stopped the last open or save, if any.
    var lastError: Error? { lock.withLock { failure } }

    // MARK: Reading

    override func read(from url: URL) throws {
        let file = try SpreadsheetDocument.load(
            url: url, progress: loadProgress ?? { _, _ in },
            shouldContinue: { [cancellation] in !cancellation.isCancelled })
        lock.withLock { loaded = file }
    }

    /// The document for what was just read (main thread, after open).
    @MainActor func takeDocument() -> SpreadsheetDocument? {
        guard let file = lock.withLock({ () -> LoadedFile? in
            defer { loaded = nil }
            return loaded
        }) else { return openDocument }
        let doc = SpreadsheetDocument.make(from: file, url: fileURL)
        adopt(doc)
        return doc
    }

    /// Take on `doc` as this file's document (after reading it, or a demo
    /// document that was never read).
    @MainActor func adopt(_ doc: SpreadsheetDocument) {
        openDocument = doc
        undoManager = doc.undoManager
        watch = doc.$isModified.combineLatest(doc.$revision).sink { [weak self] _, _ in
            // Published values arrive before they're stored: look next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshSaveState() } }
        }
    }

    /// Tell UIDocument whether there is something to autosave.
    @MainActor func refreshSaveState() {
        guard let doc = openDocument else { return }
        let unsaved = doc.isModified && Self.maySave(doc)
        lock.withLock { unsavedChanges = unsaved }
        if unsaved { updateChangeCount(.done) }
    }

    /// Whether autosave may write over the file: not while it holds content
    /// SimpleSpread would drop and the user hasn't agreed to that.
    @MainActor static func maySave(_ doc: SpreadsheetDocument) -> Bool {
        doc.unsupportedContent.isEmpty || doc.unsupportedContentAccepted
    }

    /// The file changed elsewhere (another device, another app) and the
    /// document had nothing unsaved: UIDocument reads it again.
    override func revert(toContentsOf url: URL, completionHandler: ((Bool) -> Void)? = nil) {
        let me = Unchecked(self), done = Unchecked(completionHandler)
        super.revert(toContentsOf: url) { ok in
            onMain {
                if ok, let doc = me.value.takeDocument() { me.value.onReload?(doc) }
                done.value?(ok)
            }
        }
    }

    // MARK: Writing

    override var hasUnsavedChanges: Bool {
        lock.withLock { unsavedChanges }
    }

    /// The document as it is now: a copy-on-write snapshot, taken on the
    /// main thread (UIDocument asks on the queue that saves, the main one).
    override func contents(forType typeName: String) throws -> Any {
        let me = Unchecked(self)
        let take = { @Sendable in
            MainActor.assumeIsolated { Unchecked(me.value.openDocument?.makeSaveSnapshot(committingPendingEdit: false)) }
        }
        let box = Thread.isMainThread ? take() : DispatchQueue.main.sync(execute: take)
        guard let snapshot = box.value else { throw CocoaError(.fileWriteUnknown) }
        return SnapshotBox(snapshot)
    }

    /// Write the snapshot as .xlsx (background queue; UIDocument writes to
    /// a temporary file and swaps it in, coordinated).
    override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation,
                                originalContentsURL: URL?) throws {
        guard let box = contents as? SnapshotBox else {
            return try super.writeContents(contents, to: url, for: saveOperation, originalContentsURL: originalContentsURL)
        }
        try SpreadsheetDocument.write(box.snapshot, to: url)
        lock.withLock { writtenChangeCount = box.snapshot.changeCount }
    }

    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation,
                       completionHandler: ((Bool) -> Void)? = nil) {
        let me = Unchecked(self), done = Unchecked(completionHandler)
        super.save(to: url, for: saveOperation) { ok in
            onMain {
                let file = me.value
                if ok, let doc = file.openDocument,
                   let count = file.lock.withLock({ () -> Int? in
                       defer { file.writtenChangeCount = nil }
                       return file.writtenChangeCount
                   }) {
                    // Unmodified unless it changed while being written.
                    doc.didSave(changeCount: count, to: file.fileURL)
                }
                done.value?(ok)
            }
        }
    }

    // MARK: Errors

    /// Access granted to a file outside the app (security-scoped), given
    /// up once the file is closed.
    var scopedAccess = false

    override func close(completionHandler: ((Bool) -> Void)? = nil) {
        let me = Unchecked(self), done = Unchecked(completionHandler)
        super.close { ok in
            onMain {
                let file = me.value
                if file.scopedAccess {
                    file.fileURL.stopAccessingSecurityScopedResource()
                    file.scopedAccess = false
                }
                done.value?(ok)
            }
        }
    }

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        lock.withLock { failure = error }
        finishedHandlingError(error, recovered: false)
    }
}

/// Hands a value to another thread where UIDocument's rules (not the
/// compiler) say it is safe: the document object itself, and completion
/// handlers UIKit calls back on the main queue.
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Run `body` on the main thread: now if this is it, else next turn.
func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        let box = Unchecked(body)
        DispatchQueue.main.async { MainActor.assumeIsolated(box.value) }
    }
}

/// A save snapshot passed from contents(forType:) to writeContents.
private final class SnapshotBox: @unchecked Sendable {
    let snapshot: SaveSnapshot
    init(_ snapshot: SaveSnapshot) { self.snapshot = snapshot }
}

extension SpreadsheetDocument {
    /// The user has agreed to save without the content SimpleSpread can't
    /// write back (Save Anyway).
    func acceptUnsupportedContentLoss() {
        unsupportedContentAccepted = true
    }
}
#endif
