#if os(macOS)
import AppKit
import SwiftUI

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
#endif
