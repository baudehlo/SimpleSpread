import AppKit
import SpreadsheetCore
import SpreadsheetFiles

/// A document's workbook as it was when a save began, written on another
/// thread while the user carries on. Unchecked Sendable: the workbook is a
/// private copy (`Workbook.copy()`), which only the saving thread touches
/// once it is handed over.
public struct SaveSnapshot: @unchecked Sendable {
    let workbook: Workbook
    /// The document's `changeCount` at the snapshot: the save leaves the
    /// document modified if it has changed since.
    let changeCount: Int
}

/// A CSV file read and parsed off the main thread, for `importCSVSheet`.
/// Unchecked Sendable: built on the reading thread and handed over once.
struct ImportedCSV: @unchecked Sendable {
    let workbook: Workbook
    /// More rows than a sheet holds; the rest were not read.
    let truncated: Bool
}

/// The sheet "Export Sheet as CSV" writes, copied for another thread (as
/// SaveSnapshot).
struct CSVExportSnapshot: @unchecked Sendable {
    let workbook: Workbook
    let sheet: Sheet
}

/// How a background save ended.
enum SaveOutcome {
    case saved
    /// The user pressed Cancel before the file was replaced: nothing written.
    case cancelled
    case failed(any Error)
}

/// Work on a file off the main thread, with the progress panel (and Cancel)
/// once it takes more than a moment, so a big file never beachballs the app.
@MainActor
enum BackgroundFileTask {
    /// One task in flight: its panel and its Cancel flag.
    @MainActor
    final class Handle {
        let session: ProgressSession
        let cancellation: TaskCancellation

        init(session: ProgressSession, cancellation: TaskCancellation) {
            self.session = session
            self.cancellation = cancellation
        }
    }

    /// Holds a main-actor completion while the work runs elsewhere (a
    /// main-actor class is Sendable; the closure itself is not).
    @MainActor
    private final class Completion<T> {
        let body: (Result<T, any Error>) -> Void
        init(_ body: @escaping (Result<T, any Error>) -> Void) { self.body = body }
    }

    /// Run `work` on a background queue. It gets a progress callback (a
    /// fraction, or nil for "no estimate") and a "should I go on?" check,
    /// and throws `CancellationError` to stop. `completion` runs on the main
    /// thread once the work is over: on Cancel, as soon as the work stops.
    /// Cancel closes the panel at once.
    @discardableResult
    static func run<T: Sendable>(title: String, panelTitle: String, fileName: String,
                                 window: NSWindow?, determinate: Bool = true,
                                 work: @escaping @Sendable (_ progress: @escaping @Sendable (Double?) -> Void,
                                                            _ shouldContinue: @escaping @Sendable () -> Bool) throws -> T,
                                 completion: @escaping (Result<T, any Error>) -> Void) -> Handle {
        let cancellation = TaskCancellation()
        let progress = TaskProgress(fileName: fileName, title: title)
        if !determinate { progress.fraction = nil }
        let session = ProgressSession(progress: progress, panelTitle: panelTitle, window: window)
        progress.cancel = {
            cancellation.cancel()
            session.finish()
        }
        session.showAfterDelay()
        let handle = Handle(session: session, cancellation: cancellation)
        running[ObjectIdentifier(handle)] = handle
        let report = progress.reporter()
        let done = Completion(completion)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(report, { !cancellation.isCancelled }) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    session.finish()
                    done.body(result)
                    running[ObjectIdentifier(handle)] = nil
                    if running.isEmpty {
                        let waiting = idleWaiters
                        idleWaiters = []
                        for waiter in waiting { waiter() }
                    }
                }
            }
        }
        return handle
    }

    /// Tasks in flight.
    private static var running: [ObjectIdentifier: Handle] = [:]
    /// Run once nothing is in flight (quitting waits here).
    private static var idleWaiters: [() -> Void] = []

    static var isIdle: Bool { running.isEmpty }

    /// Show every task's panel now (quitting is waiting for them).
    static func showAllProgress() {
        for handle in running.values { handle.session.show() }
    }

    /// Run `body` once no task is in flight (now, if none is), including
    /// any a completion starts.
    static func whenAllIdle(_ body: @escaping () -> Void) {
        guard !isIdle else { return body() }
        idleWaiters.append(body)
    }
}

/// Saves documents in the background. The workbook is snapshotted on the
/// main thread (microseconds), then written and compressed elsewhere while
/// the user keeps working; the document is marked saved only for the
/// change it wrote.
///
/// One save per document at a time: a save asked for while one is running
/// waits for it, then starts from a fresh snapshot (see `DocumentSaving`
/// for how a repeated ⌘S is folded into one).
@MainActor
enum BackgroundSaver {
    @MainActor
    private final class Job {
        var handle: BackgroundFileTask.Handle?
        /// Run, in order, once the save is over.
        var waiters: [() -> Void] = []
    }

    private static var jobs: [ObjectIdentifier: Job] = [:]

    static func isSaving(_ document: SpreadsheetDocument) -> Bool {
        jobs[ObjectIdentifier(document)] != nil
    }

    /// Write `document` to `url` in the background; `completion` gets the
    /// outcome on the main thread. If the document is already saving, this
    /// save starts once that one is over.
    static func save(_ document: SpreadsheetDocument, to url: URL, in window: NSWindow?,
                     completion: @escaping (SaveOutcome) -> Void) {
        let key = ObjectIdentifier(document)
        if jobs[key] != nil {
            whenIdle(document) { save(document, to: url, in: window, completion: completion) }
            return
        }
        let job = Job()
        jobs[key] = job
        let snapshot = document.makeSaveSnapshot()
        // Only the work holds the snapshot, so it is freed on the saving
        // thread: once the user has edited, it may be the only owner of a
        // sheet's cells, and freeing those is not free.
        let changeCount = snapshot.changeCount
        job.handle = BackgroundFileTask.run(
            title: "Saving…", panelTitle: "Saving “\(document.displayName)”", fileName: url.lastPathComponent,
            window: window,
            work: { progress, shouldContinue in
                try SpreadsheetDocument.write(snapshot, to: url, progress: { progress($0) },
                                              shouldContinue: shouldContinue)
            },
            completion: { result in
                jobs[key] = nil
                switch result {
                case .success:
                    // Even after a late Cancel: the file was written.
                    document.didSave(changeCount: changeCount, to: url)
                    completion(.saved)
                case .failure(let error) where error is CancellationError:
                    completion(.cancelled)
                case .failure(let error):
                    completion(.failed(error))
                }
                for waiter in job.waiters { waiter() }
            })
    }

    /// Run `body` once `document` is not saving (now, if it isn't).
    static func whenIdle(_ document: SpreadsheetDocument, _ body: @escaping () -> Void) {
        guard let job = jobs[ObjectIdentifier(document)] else { return body() }
        job.waiters.append(body)
    }

    /// Show the progress panel of `document`'s save now (closing is
    /// waiting for it).
    static func showProgress(for document: SpreadsheetDocument) {
        jobs[ObjectIdentifier(document)]?.handle?.session.show()
    }
}

/// Import and export of CSV in the background (File ▸ Import CSV as
/// Sheet…, Export Sheet as CSV…), behind the same progress panel.
@MainActor
enum BackgroundCSV {
    /// Read and parse `url` off the main thread, then add it to `document`
    /// as a new sheet (on the main thread, as one undoable step). Errors
    /// go to `failed`; Cancel adds nothing.
    static func importSheet(into document: SpreadsheetDocument, from url: URL, in window: NSWindow?,
                            failed: @escaping (any Error) -> Void) {
        let fileName = url.lastPathComponent
        BackgroundFileTask.run(
            title: "Reading…", panelTitle: "Importing “\(fileName)”", fileName: fileName, window: window,
            work: { progress, shouldContinue in
                try SpreadsheetDocument.readCSVSheet(from: url, progress: { progress($0) },
                                                     shouldContinue: shouldContinue)
            },
            completion: { [weak document] result in
                switch result {
                case .success(let read):
                    document?.importCSVSheet(read)
                case .failure(let error) where error is CancellationError:
                    break
                case .failure(let error):
                    failed(error)
                }
            })
    }

    /// Write `document`'s active sheet, as it is now, to `url` off the main
    /// thread. Errors go to `failed`; Cancel leaves any file at `url` as it
    /// was.
    static func exportActiveSheet(of document: SpreadsheetDocument, to url: URL, in window: NSWindow?,
                                  failed: @escaping (any Error) -> Void) {
        let snapshot = document.makeCSVExportSnapshot()
        BackgroundFileTask.run(
            title: "Exporting…", panelTitle: "Exporting “\(url.lastPathComponent)”",
            fileName: url.lastPathComponent, window: window, determinate: false,
            work: { _, shouldContinue in
                try SpreadsheetDocument.writeCSV(of: snapshot, to: url, shouldContinue: shouldContinue)
            },
            completion: { result in
                if case .failure(let error) = result, !(error is CancellationError) { failed(error) }
            })
    }
}
