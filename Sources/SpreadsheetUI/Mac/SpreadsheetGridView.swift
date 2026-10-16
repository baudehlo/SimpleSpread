#if os(macOS)
import AppKit
import SpreadsheetCore

/// The Mac grid: an NSView inside an NSScrollView as the document view,
/// sized to the whole sheet (only the dirty rect is ever drawn). It
/// translates AppKit events into GridController calls, draws with
/// GridRenderer, and hosts the NSTextField cell editor.
@MainActor
final class SpreadsheetGridView: NSView, NSTextFieldDelegate {
    let controller = GridController()

    weak var document: SpreadsheetDocument? {
        get { controller.document }
        set { controller.document = newValue }
    }

    /// Called when the user changes selection (SwiftUI syncs the formula bar).
    var onStateChange: (() -> Void)? {
        get { controller.onStateChange }
        set { controller.onStateChange = newValue }
    }

    private var editorField: NSTextField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controller.host = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        controller.host = self
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    typealias EditMode = GridController.EditMode
    var editMode: EditMode { controller.editMode }
    var isEditing: Bool { controller.isEditing }
    var layout: GridLayout { controller.layout }

    // MARK: Size and drawing

    func refreshSize() {
        let size = GridGeometry.gridSize(controller.layout)
        if frame.size != size {
            setFrameSize(size)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let renderer = controller.renderer() else { return }
        renderer.draw(in: ctx, dirtyRect: dirtyRect)
    }

    /// Light/dark changed (the system, or View ▸ Appearance): the grid's
    /// colours resolve differently.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Scrolling

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @objc private func scrolled() {
        needsDisplay = true
    }

    func scrollActiveCellToVisible() {
        controller.scrollActiveCellToVisible()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard document != nil else { return }
        // Control-click arrives as a plain mouseDown; route it to the context menu.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let result = controller.press(at: point, extend: event.modifierFlags.contains(.shift),
                                      clickCount: event.clickCount)
        if case .showFilter(let columnOffset, let cell) = result {
            showFilterPopover(columnOffset: columnOffset, from: cell)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        controller.drag(to: convert(event.locationInWindow, from: nil))
        if controller.dragMode == .selectCells {
            autoscroll(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        controller.release()
    }

    // MARK: Context menu

    /// Right-click on a chart (edit, copy, delete), or on a row/column
    /// header (insert, delete, hide or unhide).
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let sections = controller.chartMenu(at: point) ?? controller.headerMenu(at: point) else {
            return nil
        }
        let menu = NSMenu()
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in section {
                menu.addItem(ActionMenuItem(item.title, handler: item.action))
            }
        }
        return menu
    }

    override func resetCursorRects() {
        // Column/row resize cursors over header boundaries, per pane.
        guard enclosingScrollView != nil else { return }
        let zones = controller.geometry.resizeZones()
        for rect in zones.columns { addCursorRect(rect, cursor: .resizeLeftRight) }
        for rect in zones.rows { addCursorRect(rect, cursor: .resizeUpDown) }
    }

    // MARK: Keyboard (Ready mode)

    override func keyDown(with event: NSEvent) {
        guard document != nil else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShift = flags.contains(.shift)
        let hasCommand = flags.contains(.command)

        if let key = Self.gridKey(for: event.keyCode) {
            if case .arrow = key {
                controller.handle(key, shift: hasShift, toEdge: hasCommand)
            } else {
                controller.handle(key, shift: hasShift)
            }
            return
        }
        guard !hasCommand else {
            super.keyDown(with: event)
            return
        }
        if Self.startsTyping(event) {
            // Type-to-replace: open an empty Enter-mode editor and hand
            // it this key, so an input method (Japanese, Chinese, dead
            // keys) composes it rather than receiving it raw.
            controller.beginEditing(mode: .enter, initialText: "")
            if let fieldEditor = editorField?.currentEditor() {
                fieldEditor.keyDown(with: event)
            } else {
                // No window, so no field editor (tests): type it in.
                editorField?.stringValue = event.characters ?? ""
            }
            return
        }
        super.keyDown(with: event)
    }

    /// The grid's own keys, by Mac virtual key code.
    static func gridKey(for keyCode: UInt16) -> GridController.Key? {
        switch keyCode {
        case 123: return .arrow(.left)
        case 124: return .arrow(.right)
        case 125: return .arrow(.down)
        case 126: return .arrow(.up)
        case 36: return .returnKey
        case 48: return .tab
        case 51, 117: return .delete // Delete / Forward delete
        case 122: return .f2
        case 115: return .home
        case 116: return .pageUp
        case 121: return .pageDown
        case 53: return .escape
        default: return nil
        }
    }

    /// Whether a key (without ⌘) starts type-to-replace editing: a printable
    /// character, or a dead key (no characters yet) for the input method to
    /// compose. Function keys (End, Help, F1–F35…, reported as private-use
    /// characters U+F700–U+F8FF) and control characters do not.
    static func startsTyping(_ event: NSEvent) -> Bool {
        if event.specialKey != nil { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.function) {
            return false
        }
        guard let characters = event.characters else { return false }
        guard let first = characters.unicodeScalars.first else {
            return true // a dead key: the editor's input method composes it
        }
        if (0xF700...0xF8FF).contains(first.value) { return false }
        return !CharacterSet.controlCharacters.contains(first)
    }

    // MARK: Edit menu (responder chain)

    // The standard Edit items send cut:/copy:/paste:/delete:/selectAll:/
    // undo:/redo: to the first responder. A focused text field (the cell
    // editor, formula bar, Find, name box, sheet rename) handles them first;
    // they reach the grid only when it is the first responder, or (undo and
    // redo) when the cell editor's field editor passes them up the chain.

    override func selectAll(_ sender: Any?) {
        controller.selectAll()
    }

    @objc func copy(_ sender: Any?) {
        controller.copy()
    }

    @objc func cut(_ sender: Any?) {
        controller.cut()
    }

    @objc func paste(_ sender: Any?) {
        controller.paste()
    }

    /// Edit ▸ Paste and Match Style, when the menu offers it.
    @objc func pasteAsPlainText(_ sender: Any?) {
        controller.pasteAsPlainText()
    }

    @objc func delete(_ sender: Any?) {
        controller.delete()
    }

    @objc func undo(_ sender: Any?) {
        if let typing = editorUndoManager {
            typing.undo()
            return
        }
        controller.undo()
    }

    @objc func redo(_ sender: Any?) {
        if let typing = editorUndoManager {
            typing.redo()
            return
        }
        controller.redo()
    }

    /// While the in-cell editor has focus, undo/redo arrive here from its
    /// field editor (the editor field is our subview) and belong to the
    /// typing, which the field editor records in its own undo manager.
    private var editorUndoManager: UndoManager? {
        guard isEditing, let text = window?.firstResponder as? NSTextView, text.isFieldEditor,
              text.delegate === editorField else { return nil }
        return text.undoManager
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let document else { return false }
        switch menuItem.action {
        case #selector(undo(_:)):
            let manager = editorUndoManager ?? document.undoManager
            menuItem.title = manager.undoMenuItemTitle
            return manager.canUndo
        case #selector(redo(_:)):
            let manager = editorUndoManager ?? document.undoManager
            menuItem.title = manager.redoMenuItemTitle
            return manager.canRedo
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return SpreadsheetDocument.pasteboardHasContent
        default:
            return true
        }
    }

    // MARK: Cell editor

    /// Begin in-place editing. `.enter` = typing replaced content (arrows
    /// commit); `.edit` = F2/double-click (arrows move the caret).
    func beginEditing(mode: EditMode, initialText: String?) {
        controller.beginEditing(mode: mode, initialText: initialText)
    }

    func commitEditorIfNeeded(refocus: Bool = true) {
        controller.commitEditorIfNeeded(refocus: refocus)
    }

    func cancelEditing() {
        controller.cancelEditing()
    }

    nonisolated func controlTextDidEndEditing(_ notification: Notification) {
        let ended = notification.object as? NSTextField
        MainActor.assumeIsolated {
            guard let field = editorField, ended === field else { return }
            controller.editorDidEndEditing()
        }
    }

    // NSTextFieldDelegate: intercept commit/cancel/arrow keys.
    nonisolated func control(_ control: NSControl, textView: NSTextView,
                             doCommandBy commandSelector: Selector) -> Bool {
        MainActor.assumeIsolated {
            let command: GridController.EditorCommand
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): command = .newline
            case #selector(NSResponder.insertTab(_:)): command = .tab
            case #selector(NSResponder.insertBacktab(_:)): command = .backtab
            case #selector(NSResponder.cancelOperation(_:)): command = .cancel
            case #selector(NSResponder.moveUp(_:)): command = .arrow(.up)
            case #selector(NSResponder.moveDown(_:)): command = .arrow(.down)
            case #selector(NSResponder.moveLeft(_:)): command = .arrow(.left)
            case #selector(NSResponder.moveRight(_:)): command = .arrow(.right)
            default: return false
            }
            return controller.editorCommand(command)
        }
    }
}

// MARK: Accessibility

extension SpreadsheetGridView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Spreadsheet" }
    /// The selected cell and what it shows ("B3, 84").
    override func accessibilityValue() -> Any? { controller.accessibilitySummary }

    /// The charts on screen, each an element VoiceOver can press to select.
    override func accessibilityChildren() -> [Any]? {
        controller.visibleChartsForAccessibility.map { item in
            let screen = window.map { $0.convertToScreen(convert(item.frame, to: nil)) } ?? item.frame
            return ChartAccessibilityElement(id: item.id, label: item.label, screenFrame: screen, grid: self)
        }
    }
}

/// A chart on the grid, for VoiceOver: pressing it selects the chart.
private final class ChartAccessibilityElement: NSAccessibilityElement {
    let id: String
    weak var grid: SpreadsheetGridView?

    init(id: String, label: String, screenFrame: CGRect, grid: SpreadsheetGridView) {
        self.id = id
        self.grid = grid
        super.init()
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
        setAccessibilityParent(grid)
        setAccessibilityFrame(screenFrame)
    }

    override func accessibilityPerformPress() -> Bool {
        let id = self.id
        guard let grid else { return false }
        return MainActor.assumeIsolated {
            guard let document = grid.document else { return false }
            document.selectChart(id)
            grid.controller.stateChanged()
            return true
        }
    }
}

extension SpreadsheetGridView: GridHost {
    var visibleGridRect: CGRect {
        enclosingScrollView?.documentVisibleRect ?? bounds
    }

    func gridNeedsDisplay() {
        needsDisplay = true
    }

    func gridSizeChanged() {
        refreshSize()
    }

    func scrollGrid(to origin: CGPoint) {
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func showEditor(text: String, frame: CGRect) {
        let field = NSTextField(frame: frame)
        field.delegate = self
        field.isBordered = true
        field.focusRingType = .exterior
        field.font = PlatformFont.cellFont(name: CellStyle.defaultFontName, size: CellStyle.defaultFontSize)
        field.stringValue = text
        field.backgroundColor = .textBackgroundColor
        field.drawsBackground = true
        addSubview(field)
        editorField = field
        window?.makeFirstResponder(field)
        // Caret at end.
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    var editorText: String {
        editorField?.stringValue ?? ""
    }

    func selectionDidChange() {
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func removeEditor(refocusGrid: Bool) {
        guard let field = editorField else { return }
        editorField = nil
        if refocusGrid, field.currentEditor() != nil { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
    }
}

extension SpreadsheetGridView: NSMenuItemValidation {}

/// A menu item that runs a closure (keeps context-menu code free of @objc selectors).
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
#endif
