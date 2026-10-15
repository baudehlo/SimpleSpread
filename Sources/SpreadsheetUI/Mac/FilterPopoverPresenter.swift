#if os(macOS)
import AppKit
import SwiftUI

extension SpreadsheetGridView {
    /// Open a filter column's popover under its header cell.
    func showFilterPopover(columnOffset: Int, from rect: CGRect) {
        guard let document else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let view = FilterPopoverView(document: document, columnOffset: columnOffset) { [weak popover, weak self] in
            popover?.performClose(nil)
            self?.window?.makeFirstResponder(self)
            self?.needsDisplay = true
        }
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }
}
#endif
