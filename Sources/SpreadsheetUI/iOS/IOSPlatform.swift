#if os(iOS)
import UIKit
import SwiftUI

/// Alerts for things that went wrong, and the document's confirmations.
@MainActor
enum Alerts {
    /// An alert with an OK button, over whatever is in front.
    static func show(_ message: String, detail: String) {
        let alert = UIAlertController(title: message, message: detail.isEmpty ? nil : detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    /// Confirmations (e.g. a pivot growing over data). iPad alerts don't
    /// block, so the command is asked about and then run again if the user
    /// agrees (SpreadsheetDocument.confirmLater).
    static func installConfirmation(on document: SpreadsheetDocument) {
        document.confirmLater = { message, detail, button, proceed in
            let alert = UIAlertController(title: message, message: detail.isEmpty ? nil : detail,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: button, style: .destructive) { _ in proceed() })
            present(alert)
        }
    }

    static func present(_ controller: UIViewController) {
        topViewController()?.present(controller, animated: true)
    }

    /// The front-most view controller of the active window.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Keyboard focus for the grid.
@MainActor
enum GridFocus {
    /// Give the key window's grid keyboard focus. `unlessTyping`: leave
    /// focus alone if the user is typing in a text field.
    static func focusGrid(unlessTyping: Bool) {
        let grids = GridView.all.allObjects
        guard let grid = grids.first(where: { $0.window?.isKeyWindow == true }) ?? grids.first,
              !grid.isFirstResponder else { return }
        if unlessTyping, let responder = UIResponder.currentFirstResponder,
           responder is UITextField || responder is UITextView {
            return
        }
        _ = grid.becomeFirstResponder()
    }
}

extension UIResponder {
    private nonisolated(unsafe) static weak var found: UIResponder?

    /// The first responder of the key window, if any.
    @MainActor static var currentFirstResponder: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(recordFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func recordFirstResponder() {
        UIResponder.found = self
    }
}

/// Light or dark for every window, whatever the system uses.
@MainActor
enum AppearanceApplier {
    static func apply(_ choice: AppearanceChoice) {
        let style: UIUserInterfaceStyle
        switch choice {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

extension View {
    /// Refresh's F5 shortcut is the Mac's; iPad keyboards rarely have one.
    func refreshShortcut(_ modifiers: EventModifiers) -> some View {
        self
    }
}

/// The iPad needs no window hook: closing a document saves it (see
/// SpreadsheetFile), and windows aren't restored empty.
struct DocumentWindowHook: View {
    @ObservedObject var document: SpreadsheetDocument

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
    }
}

// MARK: - Progress

/// One background task's progress card: shown only once the task has taken
/// more than a moment (so quick ones never flash), removed when it is over.
@MainActor
final class ProgressSession: Identifiable {
    /// How long a task runs before its card appears.
    static let delay: TimeInterval = 0.25

    let progress: TaskProgress
    let panelTitle: String
    private var shown = false
    private(set) var finished = false

    init(progress: TaskProgress, panelTitle: String, window: HostWindow?) {
        self.progress = progress
        self.panelTitle = panelTitle
    }

    /// Show the card after `delay`, unless the task is over by then.
    func showAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) {
            MainActor.assumeIsolated { self.show() }
        }
    }

    /// Show the card now.
    func show() {
        guard !finished, !shown else { return }
        shown = true
        ProgressCenter.shared.sessions.append(self)
    }

    func finish() {
        finished = true
        ProgressCenter.shared.sessions.removeAll { $0 === self }
    }
}

/// The progress cards on screen, in every window.
@MainActor
final class ProgressCenter: ObservableObject {
    static let shared = ProgressCenter()
    @Published var sessions: [ProgressSession] = []
}

/// Shows the progress cards over a window's content.
struct ProgressOverlay: View {
    @ObservedObject private var center = ProgressCenter.shared

    var body: some View {
        VStack(spacing: 10) {
            ForEach(center.sessions) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.panelTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    TaskProgressView(progress: session.progress)
                }
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
            }
        }
        .padding(.top, 60)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.default, value: center.sessions.map(\.id))
        .allowsHitTesting(!center.sessions.isEmpty)
    }
}
#endif
