#if os(macOS)
import AppKit
import SwiftUI

/// Alerts for things that went wrong, and the document's confirmations.
@MainActor
enum Alerts {
    /// An app-modal alert with an OK button.
    static func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// Confirmations (e.g. a pivot growing over data) as modal alerts,
    /// answered before the command goes on.
    static func installConfirmation(on document: SpreadsheetDocument) {
        document.confirm = { message, detail, button in
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}

/// Keyboard focus for the grid.
@MainActor
enum GridFocus {
    /// Give the key window's grid keyboard focus. `unlessTyping`: leave
    /// focus alone if the user is typing in a text field.
    static func focusGrid(unlessTyping: Bool) {
        guard let window = NSApp.keyWindow else { return }
        if window.firstResponder is SpreadsheetGridView { return }
        if unlessTyping, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            return
        }
        func findGrid(_ view: NSView) -> SpreadsheetGridView? {
            if let grid = view as? SpreadsheetGridView { return grid }
            for sub in view.subviews {
                if let g = findGrid(sub) { return g }
            }
            return nil
        }
        if let content = window.contentView, let grid = findGrid(content) {
            window.makeFirstResponder(grid)
        }
    }
}

/// Light or dark for the whole app, whatever the system uses.
@MainActor
enum AppearanceApplier {
    static func apply(_ choice: AppearanceChoice) {
        // No NSApp in unit tests: nothing to apply to.
        guard let app = NSApp else { return }
        switch choice {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension View {
    /// Refresh's F5 shortcut (Excel's), with `modifiers`.
    func refreshShortcut(_ modifiers: EventModifiers) -> some View {
        keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: modifiers)
    }
}
#endif
