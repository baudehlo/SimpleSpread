#if os(iOS)
import SwiftUI
import UIKit

/// The unlock sheet (UnlockView): one at a time, over whatever is in
/// front, dismissed once SimpleSpread is unlocked.
@MainActor
enum UnlockPresenter {
    private static weak var controller: UIViewController?

    static func present(attempt: Int = 0) {
        guard controller == nil else { return }
        guard let top = Alerts.topViewController() else {
            // At launch the window may not be up yet.
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { present(attempt: attempt + 1) }
            }
            return
        }
        let hosting = UIHostingController(rootView: UnlockView(close: { dismiss() }))
        hosting.modalPresentationStyle = .formSheet
        hosting.preferredContentSize = CGSize(width: 440, height: 500)
        hosting.sizingOptions = .preferredContentSize
        controller = hosting
        top.present(hosting, animated: true)
    }

    static func dismiss(then next: @escaping () -> Void = {}) {
        guard let controller, controller.presentingViewController != nil else {
            controller = nil
            return next()
        }
        self.controller = nil
        controller.dismiss(animated: true, completion: next)
    }
}
#endif
