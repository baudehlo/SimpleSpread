import Foundation
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
