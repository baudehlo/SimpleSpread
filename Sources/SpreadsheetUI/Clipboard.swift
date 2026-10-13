import AppKit
import SpreadsheetCore

/// Pasteboard integration: internal lossless payload + TSV for other apps.
extension SpreadsheetDocument {
    private static let payloadType = NSPasteboard.PasteboardType(ClipboardPayload.pasteboardType)

    public func copySelectionToPasteboard(cut: Bool = false) {
        commitPendingEdit()
        // Cutting moves cells; a pivot table can't move (it would arrive as
        // plain values), so refuse before anything reaches the pasteboard.
        if cut, refuseIfPivot(selection.range) { return }
        // The payload carries its own origin, so formulas translate however
        // far it travels (another window, or after a relaunch).
        let payload = selectionPayload(isCut: cut)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let encoded = try? JSONEncoder().encode(payload) {
            pasteboard.setData(encoded, forType: SpreadsheetDocument.payloadType)
        }
        pasteboard.setString(selectionTSV(skippingFiltered: !cut), forType: .string)
        if cut {
            clearSelectionContents(skippingFiltered: false)
        }
    }

    public func pasteFromPasteboard() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: SpreadsheetDocument.payloadType),
           let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) {
            paste(payload: payload)
            return
        }
        if let text = pasteboard.string(forType: .string) {
            paste(text: text)
        }
    }

    /// Paste and Match Style: the pasteboard's text only, parsed as typed.
    public func pastePlainTextFromPasteboard() {
        if let text = NSPasteboard.general.string(forType: .string) {
            paste(text: text)
        }
    }

    /// Whether Paste has anything to paste.
    static var pasteboardHasContent: Bool {
        NSPasteboard.general.availableType(from: [payloadType, .string]) != nil
    }
}
