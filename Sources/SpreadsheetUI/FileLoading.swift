import AppKit
import SwiftUI
import SpreadsheetCore

/// A file read off the main thread, ready to become a document.
/// The workbook and engine are built on the loading thread and handed over
/// once, untouched by it afterwards.
public final class LoadedFile: @unchecked Sendable {
    let workbook: Workbook
    let engine: CalculationEngine
    let isTextImport: Bool
    /// More rows than a sheet holds; the rest were not loaded.
    let truncatedRows: Bool

    init(workbook: Workbook, engine: CalculationEngine, isTextImport: Bool, truncatedRows: Bool) {
        self.workbook = workbook
        self.engine = engine
        self.isTextImport = isTextImport
        self.truncatedRows = truncatedRows
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

/// What the progress panel shows.
@MainActor
final class LoadProgress: ObservableObject {
    let fileName: String
    /// Nil while there is no estimate (formula calculation).
    @Published var fraction: Double? = 0
    @Published var phase = LoadPhase.reading
    /// Cancel: stop the load and close the panel.
    var cancel: () -> Void = {}

    init(fileName: String) {
        self.fileName = fileName
    }
}

/// A flag the main thread sets and the loading thread polls.
final class LoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Opens files in the background, with a progress panel (and Cancel) for
/// any that take more than a moment, so a big file never beachballs the app.
@MainActor
enum FileLoader {
    /// Files being opened, so a second request for one isn't loaded twice.
    private static var inFlight: Set<URL> = []

    static var isIdle: Bool { inFlight.isEmpty }

    static func open(_ url: URL, completion: @escaping @MainActor (SpreadsheetDocument) -> Void) {
        let key = url.standardizedFileURL
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)

        let cancellation = LoadCancellation()
        let progress = LoadProgress(fileName: url.lastPathComponent)
        let session = LoadSession()
        // Formula calculation can't stop part-way, so Cancel closes the panel
        // at once and the finished load is thrown away.
        progress.cancel = {
            cancellation.cancel()
            session.finish()
            inFlight.remove(key)
        }

        // Small files open before the panel would appear: no flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !session.finished else { return }
            let panel = makePanel(progress)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            session.panel = panel
        }

        // Progress arrives often; pass it on when the whole percent changes.
        let throttle = ProgressThrottle()
        let report: (Double?, LoadPhase) -> Void = { fraction, phase in
            guard throttle.shouldReport(fraction, phase) else { return }
            DispatchQueue.main.async {
                progress.fraction = fraction
                progress.phase = phase
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try SpreadsheetDocument.load(url: url, progress: report,
                                             shouldContinue: { !cancellation.isCancelled })
            }
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else { return }
                session.finish()
                inFlight.remove(key)
                switch result {
                case .success(let loaded):
                    completion(SpreadsheetDocument.make(from: loaded, url: url))
                case .failure(let error):
                    if error is CancellationError { return }
                    let alert = NSAlert()
                    alert.messageText = "Could not open \(url.lastPathComponent)"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private static func makePanel(_ progress: LoadProgress) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Opening \(progress.fileName)"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: LoadingView(progress: progress))
        return panel
    }
}

/// One open in progress: its panel, once shown, and whether it is over.
@MainActor
private final class LoadSession {
    var panel: NSPanel?
    private(set) var finished = false

    func finish() {
        finished = true
        panel?.close()
        panel = nil
    }
}

/// Lets through progress reports that change the whole percent or phase.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private var lastPhase: LoadPhase?

    func shouldReport(_ fraction: Double?, _ phase: LoadPhase) -> Bool {
        lock.withLock {
            let percent = fraction.map { Int($0 * 100) } ?? -2
            guard percent != lastPercent || phase != lastPhase else { return false }
            lastPercent = percent
            lastPhase = phase
            return true
        }
    }
}

struct LoadingView: View {
    @ObservedObject var progress: LoadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.phase.title)
                .font(.headline)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack {
                Text(progress.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
