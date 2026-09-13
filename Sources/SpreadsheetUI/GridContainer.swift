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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = context.coordinator.scrollView
        let grid = context.coordinator.gridView
        grid.document = document
        grid.onStateChange = onStateChange
        grid.refreshSize()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 3
        scroll.backgroundColor = .textBackgroundColor
        DispatchQueue.main.async {
            grid.window?.makeFirstResponder(grid)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let grid = context.coordinator.gridView
        grid.document = document
        grid.onStateChange = onStateChange
        grid.refreshSize()
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
