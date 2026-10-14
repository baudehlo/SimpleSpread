import AppKit
import SwiftUI

/// What a progress panel shows: opening, saving, importing or exporting a
/// file in the background.
@MainActor
final class TaskProgress: ObservableObject {
    let fileName: String
    /// Nil while there is no estimate.
    @Published var fraction: Double? = 0
    /// "Reading…", "Saving…", …
    @Published var title: String
    /// Cancel: stop the work and close the panel.
    var cancel: () -> Void = {}

    init(fileName: String, title: String) {
        self.fileName = fileName
        self.title = title
    }
}

/// A flag the main thread sets and the working thread polls.
final class TaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// One background task's panel: shown only once the task has taken more
/// than a moment (so quick ones never flash), closed when it is over.
@MainActor
final class ProgressSession {
    /// How long a task runs before its panel appears.
    static let delay: TimeInterval = 0.25

    let progress: TaskProgress
    private let panelTitle: String
    /// The document window the panel belongs to: it then sits over that
    /// window (a child window, so it moves with it) without blocking it.
    /// Nil: a free panel in the middle of the screen, made key.
    private weak var window: NSWindow?
    private var panel: NSPanel?
    private(set) var finished = false

    init(progress: TaskProgress, panelTitle: String, window: NSWindow?) {
        self.progress = progress
        self.panelTitle = panelTitle
        self.window = window
    }

    /// Show the panel after `delay`, unless the task is over by then.
    func showAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) {
            MainActor.assumeIsolated { self.show() }
        }
    }

    /// Show the panel now (closing or quitting is waiting for the task).
    func show() {
        guard !finished, panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = panelTitle
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: TaskProgressView(progress: progress))
        if let window, window.isVisible {
            // Over the top of the document, like a sheet, but the document
            // stays usable: the user can keep working while it saves.
            panel.becomesKeyOnlyIfNeeded = true
            let frame = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2,
                                               y: frame.maxY - 60))
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        self.panel = panel
    }

    func finish() {
        finished = true
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
        panel = nil
    }
}

/// Lets through progress reports that change the whole percent or phase,
/// and passes them to the main thread.
final class ProgressThrottle<Phase: Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private var lastPhase: Phase?

    func shouldReport(_ fraction: Double?, _ phase: Phase) -> Bool {
        lock.withLock {
            let percent = fraction.map { Int($0 * 100) } ?? -2
            guard percent != lastPercent || phase != lastPhase else { return false }
            lastPercent = percent
            lastPhase = phase
            return true
        }
    }
}

extension TaskProgress {
    /// A progress callback for the working thread: throttled to whole
    /// percents and delivered on the main queue. The callback is Sendable;
    /// `self` is touched only on the main queue.
    func reporter() -> @Sendable (Double?) -> Void {
        let throttle = ProgressThrottle<Int>()
        return { [self] fraction in
            guard throttle.shouldReport(fraction, 0) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.fraction = fraction }
            }
        }
    }
}

struct TaskProgressView: View {
    @ObservedObject var progress: TaskProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.title)
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
