import SwiftUI
import AppKit
import SpreadsheetCore

/// Bridges the AppKit grid into SwiftUI and keeps it in sync with the
/// document's revision/selection.
struct GridContainer: NSViewRepresentable {
    @ObservedObject var document: SpreadsheetDocument
    /// Bumped by SwiftUI to ask the grid to redraw (e.g. selection from name box).
    let revision: Int
    let onStateChange: () -> Void

    @MainActor
    final class Coordinator {
        let scrollView = NSScrollView()
        let gridView = SpreadsheetGridView()
        weak var document: SpreadsheetDocument?
        var magnificationObservation: NSKeyValueObservation?
        var lastScrollTick = 0

        /// Pinch/smart-magnify gestures change magnification directly; mirror
        /// them into the document so menus and the status bar stay in sync.
        func startObservingMagnification() {
            magnificationObservation = scrollView.observe(\.magnification) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    guard let self, let document = self.document else { return }
                    let zoom = scroll.magnification
                    if abs(document.zoomLevel - zoom) > 0.001 {
                        document.setZoom(zoom)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = context.coordinator.scrollView
        let grid = context.coordinator.gridView
        context.coordinator.document = document
        grid.document = document
        grid.onStateChange = onStateChange
        grid.refreshSize()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = SpreadsheetDocument.zoomRange.lowerBound
        scroll.maxMagnification = SpreadsheetDocument.zoomRange.upperBound
        scroll.backgroundColor = .textBackgroundColor
        context.coordinator.startObservingMagnification()
        DispatchQueue.main.async {
            grid.window?.makeFirstResponder(grid)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let grid = context.coordinator.gridView
        context.coordinator.document = document
        grid.document = document
        grid.onStateChange = onStateChange
        grid.refreshSize()
        // Apply document zoom (menu / status bar) to the scroll view, keeping
        // the visible center stable.
        if abs(nsView.magnification - document.zoomLevel) > 0.001 {
            let visible = nsView.contentView.documentVisibleRect
            let center = CGPoint(x: visible.midX, y: visible.midY)
            nsView.setMagnification(document.zoomLevel, centeredAt: center)
        }
        // Scroll the active cell into view when asked (find / name-box jumps).
        if context.coordinator.lastScrollTick != document.scrollTick {
            context.coordinator.lastScrollTick = document.scrollTick
            DispatchQueue.main.async { grid.scrollActiveCellToVisible() }
        }
    }
}

/// Focused-value plumbing so menu commands reach the active window's document.
struct DocumentFocusKey: FocusedValueKey {
    typealias Value = SpreadsheetDocument
}

struct GridFocusKey: FocusedValueKey {
    typealias Value = GridActions
}

/// Grid actions surfaced to menus (editing state lives in AppKit).
@MainActor
public struct GridActions {
    weak var grid: SpreadsheetGridView?

    func commitPendingEdit() {
        grid?.commitEditorIfNeeded()
    }

    func redraw() {
        grid?.refreshSize()
        grid?.needsDisplay = true
    }

    func scrollToActiveCell() {
        grid?.scrollActiveCellToVisible()
    }
}

extension FocusedValues {
    var spreadsheetDocument: SpreadsheetDocument? {
        get { self[DocumentFocusKey.self] }
        set { self[DocumentFocusKey.self] = newValue }
    }

    var gridActions: GridActions? {
        get { self[GridFocusKey.self] }
        set { self[GridFocusKey.self] = newValue }
    }
}
