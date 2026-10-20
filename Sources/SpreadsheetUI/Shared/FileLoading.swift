import Foundation
import SpreadsheetCore

/// A file read off the main thread, ready to become a document.
/// The workbook and engine are built on the loading thread and handed over
/// once, untouched by it afterwards.
public final class LoadedFile: @unchecked Sendable {
    let workbook: Workbook
    let engine: CalculationEngine
    let isTextImport: Bool
    /// BIFF8 imports must be saved as XLSX copies, never written back to the source.
    let isLegacyImport: Bool
    /// More rows than a sheet holds; the rest were not loaded.
    let truncatedRows: Bool
    /// What the file holds that saving will not write back ("3 charts", …).
    let unsupportedContent: [String]

    init(workbook: Workbook, engine: CalculationEngine, isTextImport: Bool, isLegacyImport: Bool = false,
         truncatedRows: Bool,
         unsupportedContent: [String] = []) {
        self.workbook = workbook
        self.engine = engine
        self.isTextImport = isTextImport
        self.isLegacyImport = isLegacyImport
        self.truncatedRows = truncatedRows
        self.unsupportedContent = unsupportedContent
    }
}

public enum LoadPhase: Sendable {
    case reading
    case calculating

    var title: String {
        switch self {
        case .reading: return "Reading…"
        case .calculating: return "Calculating formulas…"
        }
    }
}

/// Opens files in the background, with a progress panel (and Cancel) for
/// any that take more than a moment, so a big file never beachballs the app.
@MainActor
enum FileLoader {
    /// Files being opened, so a second request for one isn't loaded twice.
    private static var inFlight: Set<URL> = []

    static var isIdle: Bool { inFlight.isEmpty }

    static func open(_ url: URL, completion: @escaping @MainActor @Sendable (SpreadsheetDocument) -> Void) {
        let key = url.standardizedFileURL
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let cancellation = TaskCancellation()
        let progress = TaskProgress(fileName: url.lastPathComponent, title: LoadPhase.reading.title)
        let session = ProgressSession(progress: progress, panelTitle: "Opening \(url.lastPathComponent)",
                                      window: nil)
        // Formula calculation can't stop part-way, so Cancel closes the panel
        // at once and the finished load is thrown away.
        progress.cancel = {
            cancellation.cancel()
            session.finish()
            inFlight.remove(key)
        }
        // Small files open before the panel would appear: no flash.
        session.showAfterDelay()

        // Progress arrives often; pass it on when the whole percent changes.
        // Everything the loading thread touches is Sendable: the main-actor
        // objects (progress, session) only ever on the main queue.
        let throttle = ProgressThrottle<LoadPhase>()
        let report: @Sendable (Double?, LoadPhase) -> Void = { fraction, phase in
            guard throttle.shouldReport(fraction, phase) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    progress.fraction = fraction
                    progress.title = phase.title
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try SpreadsheetDocument.load(url: url, progress: report,
                                             shouldContinue: { !cancellation.isCancelled })
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    finish(result, url: url, key: key, session: session,
                           cancellation: cancellation, completion: completion)
                }
            }
        }
    }

    private static func finish(_ result: Result<LoadedFile, any Error>, url: URL, key: URL,
                               session: ProgressSession, cancellation: TaskCancellation,
                               completion: @MainActor (SpreadsheetDocument) -> Void) {
        guard !cancellation.isCancelled else { return }
        session.finish()
        inFlight.remove(key)
        switch result {
        case .success(let loaded):
            completion(SpreadsheetDocument.make(from: loaded, url: url))
        case .failure(let error):
            if error is CancellationError { return }
            Alerts.show("Could not open \(url.lastPathComponent)", detail: error.localizedDescription)
        }
    }
}
