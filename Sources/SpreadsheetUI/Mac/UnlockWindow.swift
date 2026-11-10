#if os(macOS) && STORE_LICENSE
import AppKit
import Combine
import SwiftUI

/// The unlock window (UnlockView): one at a time, in front, closed once
/// SimpleSpread is unlocked.
@MainActor
enum UnlockPresenter {
    private static var window: NSWindow?
    private static var resizing: AnyCancellable?

    static func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: UnlockView(close: { dismiss() }))
        // The window is sized here, not by the hosting controller: with
        // .preferredContentSize, the wrapped text's height never settled on
        // some Macs and AppKit threw after too many constraint passes.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Unlock SimpleSpread"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("unlock")
        fit(window, hosting)
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                UnlockPresenter.window = nil
                UnlockPresenter.resizing = nil
            }
        }
        // A message or a new status can change the height: measure again
        // once the change has been drawn, outside any layout pass.
        let license = AppLicense.shared
        resizing = license.$message.map { _ in () }
            .merge(with: license.$status.map { _ in () }, license.$isBusy.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak window, weak hosting] in
                guard let window, let hosting else { return }
                MainActor.assumeIsolated { fit(window, hosting) }
            }
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Size the window to the content's height, keeping its top edge put.
    private static func fit(_ window: NSWindow, _ hosting: NSHostingController<UnlockView>) {
        let size = hosting.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    static func dismiss() {
        window?.close()
        window = nil
        resizing = nil
    }
}
#endif
