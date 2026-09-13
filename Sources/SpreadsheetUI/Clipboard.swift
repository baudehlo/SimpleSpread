import AppKit
import SpreadsheetCore

/// Pasteboard integration: internal lossless payload + TSV for other apps.
extension SpreadsheetDocument {
    private static let payloadType = NSPasteboard.PasteboardType(ClipboardPayload.pasteboardType)

    /// Where the last copy came from (for relative-reference adjustment).
    private static var copyOrigins: [ObjectIdentifier: CellAddress] = [:]

    public func copySelectionToPasteboard(cut: Bool = false) {
        let payload = selectionPayload(isCut: cut)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let encoded = try? JSONEncoder().encode(payload) {
            pasteboard.setData(encoded, forType: SpreadsheetDocument.payloadType)
        }
        pasteboard.setString(selectionTSV(), forType: .string)
        SpreadsheetDocument.copyOrigins[ObjectIdentifier(self)] = selection.range.start
        if cut {
            clearSelectionContents()
        }
    }

    public func pasteFromPasteboard() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: SpreadsheetDocument.payloadType),
           let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) {
            paste(payload: payload,
                  sourceOrigin: SpreadsheetDocument.copyOrigins[ObjectIdentifier(self)])
            return
        }
        if let text = pasteboard.string(forType: .string) {
            paste(text: text)
        }
    }
}
