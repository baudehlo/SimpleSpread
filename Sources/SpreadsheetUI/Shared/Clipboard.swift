import Foundation
import SpreadsheetCore
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// Pasteboard integration: internal lossless payload, plus TSV and an HTML
/// table for other apps (Numbers ignores TSV quoting, so a cell with a line
/// break only survives the trip as HTML; Excel reads both).
extension SpreadsheetDocument {
    public func copySelectionToPasteboard(cut: Bool = false) {
        commitPendingEdit()
        // Cutting moves cells; a pivot table can't move (it would arrive as
        // plain values), so refuse before anything reaches the pasteboard.
        if cut, refuseIfPivot(selection.range) { return }
        // The payload carries its own origin, so formulas translate however
        // far it travels (another window, or after a relaunch).
        let payload = selectionPayload(isCut: cut)
        SystemPasteboard.write(payload: try? JSONEncoder().encode(payload),
                               text: selectionTSV(skippingFiltered: !cut),
                               html: selectionHTML(skippingFiltered: !cut))
        if cut {
            clearSelectionContents(skippingFiltered: false)
        }
    }

    public func pasteFromPasteboard() {
        if let data = SystemPasteboard.payload(),
           let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) {
            paste(payload: payload)
            return
        }
        if let text = SystemPasteboard.text() {
            paste(text: text)
        }
    }

    /// Paste and Match Style: the pasteboard's text only, parsed as typed.
    public func pastePlainTextFromPasteboard() {
        if let text = SystemPasteboard.text() {
            paste(text: text)
        }
    }

    /// Whether Paste has anything to paste.
    static var pasteboardHasContent: Bool {
        SystemPasteboard.hasContent
    }
}

/// The general pasteboard, as the clipboard code uses it.
@MainActor
enum SystemPasteboard {
    private static let payloadType = ClipboardPayload.pasteboardType

    static func write(payload: Data?, text: String, html: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let payload {
            pasteboard.setData(payload, forType: NSPasteboard.PasteboardType(payloadType))
        }
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(html, forType: .html)
        #else
        var item: [String: Any] = [
            UTType.utf8PlainText.identifier: text,
            UTType.html.identifier: html,
        ]
        if let payload { item[payloadType] = payload }
        UIPasteboard.general.setItems([item])
        #endif
    }

    static func payload() -> Data? {
        #if os(macOS)
        NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(payloadType))
        #else
        UIPasteboard.general.data(forPasteboardType: payloadType)
        #endif
    }

    static func text() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    static var hasContent: Bool {
        #if os(macOS)
        NSPasteboard.general.availableType(from: [NSPasteboard.PasteboardType(payloadType), .string]) != nil
        #else
        // Asking about types, not contents: no paste permission prompt.
        UIPasteboard.general.hasStrings || UIPasteboard.general.contains(pasteboardTypes: [payloadType])
        #endif
    }
}
