#if os(macOS) && STORE_LICENSE
import AppKit
import SwiftUI

/// The unlock window (UnlockView): one at a time, in front, closed once
/// SimpleSpread is unlocked.
@MainActor
enum UnlockPresenter {
    private static var window: NSWindow?

    static func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: UnlockView(close: { dismiss() }))
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.title = "Unlock SimpleSpread"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("unlock")
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { UnlockPresenter.window = nil }
        }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func dismiss() {
        window?.close()
        window = nil
    }
}
#endif
