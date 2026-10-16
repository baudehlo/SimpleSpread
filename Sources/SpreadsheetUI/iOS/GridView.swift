#if os(iOS)
import UIKit
import SwiftUI
import SpreadsheetCore

/// The iPad grid. The scroll view scrolls over the whole sheet (its content
/// size is the grid at the zoom level); the drawing happens in a canvas the
/// size of the screen that follows the scroll offset, so a million-row
/// sheet never needs a million-row layer. Taps, drags, the pointer, pinch,
/// menus and hardware keys become GridController calls; GridRenderer draws.
@MainActor
final class GridView: UIScrollView {
    let controller = GridController()
    private let canvas = GridCanvas()
    private var editorField: CellEditorField?
    /// The zoom the content size and canvas are laid out for.
    private(set) var zoom: CGFloat = 1

    weak var document: SpreadsheetDocument? {
        get { controller.document }
        set { controller.document = newValue }
    }

    var onStateChange: (() -> Void)? {
        get { controller.onStateChange }
        set { controller.onStateChange = newValue }
    }

    /// Grids on screen, for GridFocus.
    static let all = NSHashTable<GridView>.weakObjects()

    override init(frame: CGRect) {
        super.init(frame: frame)
        controller.host = self
        // A finger is less precise than a pointer: bigger targets.
        controller.hitSlop = 10
        canvas.grid = self
        addSubview(canvas)
        backgroundColor = SystemColors.textBackground
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true
        keyboardDismissMode = .none
        delaysContentTouches = false
        installGestures()
        Self.all.add(self)
        accessibilityIdentifier = "grid"
        accessibilityLabel = "Spreadsheet"
        accessibilityTraits = [.allowsDirectInteraction]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (grid: GridView, _: UITraitCollection) in
            grid.canvas.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Coordinates

    /// Grid (view-coordinate) point for a point in this scroll view.
    func gridPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / zoom, y: point.y / zoom)
    }

    /// A grid rect in this scroll view's coordinates.
    func scrollRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }

    // MARK: Size, zoom and drawing

    func refreshSize() {
        let grid = GridGeometry.gridSize(controller.layout)
        let size = CGSize(width: grid.width * zoom, height: grid.height * zoom)
        if contentSize != size { contentSize = size }
        canvas.setNeedsDisplay()
    }

    /// Change the zoom, keeping the grid point under `anchor` (a point in
    /// this view's bounds coordinates, relative to its top-left) in place.
    /// No anchor: the top-left of the view stays put, as on the Mac.
    func apply(zoom newZoom: CGFloat, anchor: CGPoint? = nil) {
        guard abs(newZoom - zoom) > 0.0001 else { return }
        let onScreen = anchor ?? .zero
        let focus = gridPoint(CGPoint(x: contentOffset.x + onScreen.x, y: contentOffset.y + onScreen.y))
        zoom = newZoom
        refreshSize()
        var offset = CGPoint(x: focus.x * zoom - onScreen.x, y: focus.y * zoom - onScreen.y)
        offset.x = max(0, min(offset.x, contentSize.width - bounds.width))
        offset.y = max(0, min(offset.y, contentSize.height - bounds.height))
        contentOffset = offset
        repositionEditor()
        canvas.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The canvas covers exactly what is on screen.
        if canvas.frame != bounds {
            let heightChanged = canvas.frame.height != bounds.height
            canvas.frame = bounds
            // The keyboard came up (or went): keep the cell being typed in clear of it.
            if heightChanged, controller.isEditing {
                DispatchQueue.main.async { self.controller.scrollActiveCellToVisible() }
            }
        }
        canvas.setNeedsDisplay()
    }

    fileprivate func drawGrid(in rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var decorations = GridDecorations()
        // Touch has grips; a pointer the Mac's fill handle. Both show: the
        // handle is the pointer's, the grips are the finger's.
        decorations.fillHandle = true
        decorations.selectionGrips = true
        guard let renderer = controller.renderer(decorations: decorations) else { return }
        let visible = visibleGridRect
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        renderer.draw(in: ctx, dirtyRect: visible)
    }

    // MARK: Gestures

    private var tapGesture: UITapGestureRecognizer!
    /// The last tap, to spot a second one (a double tap edits the cell).
    /// One recognizer rather than a double-tap one, so a single tap
    /// selects at once instead of waiting to see whether another follows.
    private var lastTap: (time: TimeInterval, point: CGPoint)?
    /// A finger drag that starts on a selection grip or a header edge.
    private var handleDrag: UIPanGestureRecognizer!
    /// A pointer (trackpad or mouse) drag: selects, as on the Mac.
    private var pointerDrag: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!
    private var pendingMenu: DispatchWorkItem?
    private var editMenu: UIEditMenuInteraction!
    private var pinchStartZoom: CGFloat = 1
    /// What the open context menu acts on (grid coordinates).
    private var menuHighlight: CGRect?

    private func installGestures() {
        tapGesture = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        addGestureRecognizer(tapGesture)

        handleDrag = UIPanGestureRecognizer(target: self, action: #selector(handleDragged(_:)))
        handleDrag.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber,
                                        UITouch.TouchType.pencil.rawValue as NSNumber]
        handleDrag.maximumNumberOfTouches = 1
        addGestureRecognizer(handleDrag)
        // Scrolling waits for the handle drag to decline (at once, unless
        // the finger came down on a handle).
        panGestureRecognizer.require(toFail: handleDrag)

        pointerDrag = UIPanGestureRecognizer(target: self, action: #selector(pointerDragged(_:)))
        pointerDrag.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        pointerDrag.allowedScrollTypesMask = []
        addGestureRecognizer(pointerDrag)
        // The pointer's drag selects; its scroll wheel and two-finger
        // trackpad swipes still scroll.
        panGestureRecognizer.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber,
                                                  UITouch.TouchType.pencil.rawValue as NSNumber]

        pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)

        addInteraction(UIContextMenuInteraction(delegate: self))
        addInteraction(UIPointerInteraction(delegate: self))
        editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let document else { return }
        let point = gridPoint(gesture.location(in: self))
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTap, now - last.time < 0.35,
           hypot(point.x - last.point.x, point.y - last.point.y) < 12 {
            lastTap = nil
            doubleTapped(at: point)
            return
        }
        lastTap = (now, point)
        let before = document.selection
        let wasEditing = controller.isEditing
        let extend = gesture.modifierFlags.contains(.shift)
        let result = controller.press(at: point, extend: extend, clickCount: 1)
        controller.release()
        if !controller.isEditing { _ = becomeFirstResponder() }
        if case .showFilter(let columnOffset, let cell) = result {
            showFilterPopover(columnOffset: columnOffset, from: cell)
            return
        }
        // A tap on the cell that was already selected: the edit menu, once
        // it's clear this isn't the start of a double tap.
        if !wasEditing, !extend, before.isSingleCell, document.selection == before, document.selectedChartID == nil,
           controller.geometry.region(at: point) == .cells {
            let location = gesture.location(in: self)
            let work = DispatchWorkItem { [weak self] in
                self?.editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
            }
            pendingMenu = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func doubleTapped(at point: CGPoint) {
        pendingMenu?.cancel()
        pendingMenu = nil
        controller.press(at: point, clickCount: 2)
        controller.release()
    }

    @objc private func handleDragged(_ gesture: UIPanGestureRecognizer) {
        let point = gridPoint(gesture.location(in: self))
        switch gesture.state {
        case .began:
            if let anchor = controller.gripHit(at: point) {
                controller.beginGripDrag(anchor: anchor)
            } else {
                controller.press(at: point)
            }
        case .changed:
            controller.drag(to: point)
            autoscroll(at: gesture.location(in: self))
        default:
            stopAutoscroll()
            controller.release()
        }
    }

    @objc private func pointerDragged(_ gesture: UIPanGestureRecognizer) {
        let point = gridPoint(gesture.location(in: self))
        switch gesture.state {
        case .began:
            // The press itself arrived as a tap only if it didn't move; a
            // drag starts here, from where the button went down.
            let start = gridPoint(CGPoint(x: gesture.location(in: self).x - gesture.translation(in: self).x,
                                          y: gesture.location(in: self).y - gesture.translation(in: self).y))
            let result = controller.press(at: start, extend: gesture.modifierFlags.contains(.shift))
            if case .showFilter(let columnOffset, let cell) = result {
                showFilterPopover(columnOffset: columnOffset, from: cell)
            }
            controller.drag(to: point)
            if !controller.isEditing { _ = becomeFirstResponder() }
        case .changed:
            controller.drag(to: point)
            if controller.isSelectingByDrag { autoscroll(at: gesture.location(in: self)) }
        default:
            stopAutoscroll()
            controller.release()
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let document else { return }
        switch gesture.state {
        case .began:
            pinchStartZoom = document.zoomLevel
        case .changed:
            let range = SpreadsheetDocument.zoomRange
            let target = min(max(pinchStartZoom * gesture.scale, range.lowerBound), range.upperBound)
            let location = gesture.location(in: self)
            apply(zoom: target, anchor: CGPoint(x: location.x - contentOffset.x, y: location.y - contentOffset.y))
            // The document follows (menus and the status bar show it); the
            // view already has it, so the round trip back is a no-op.
            document.setZoom(target)
        default:
            break
        }
    }

    // MARK: Autoscroll (dragging a selection past the edge)

    private var autoscrollTimer: Timer?
    private var autoscrollPoint: CGPoint = .zero

    private func autoscroll(at point: CGPoint) {
        autoscrollPoint = point
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollStep() }
        }
    }

    private func autoscrollStep() {
        let edge: CGFloat = 40
        let inView = CGPoint(x: autoscrollPoint.x - contentOffset.x, y: autoscrollPoint.y - contentOffset.y)
        var delta = CGPoint.zero
        if inView.x > bounds.width - edge { delta.x = 12 } else if inView.x < edge + GridLayout.headerWidth * zoom { delta.x = -12 }
        if inView.y > bounds.height - edge { delta.y = 12 } else if inView.y < edge + GridLayout.headerHeight * zoom { delta.y = -12 }
        guard delta != .zero else { return }
        var offset = CGPoint(x: contentOffset.x + delta.x, y: contentOffset.y + delta.y)
        offset.x = max(0, min(offset.x, contentSize.width - bounds.width))
        offset.y = max(0, min(offset.y, contentSize.height - bounds.height))
        guard offset != contentOffset else { return }
        let moved = CGPoint(x: offset.x - contentOffset.x, y: offset.y - contentOffset.y)
        contentOffset = offset
        autoscrollPoint.x += moved.x
        autoscrollPoint.y += moved.y
        controller.drag(to: gridPoint(autoscrollPoint))
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var undoManager: UndoManager? { document?.undoManager }

    override var keyCommands: [UIKeyCommand]? {
        guard !controller.isEditing else { return nil }
        var commands: [UIKeyCommand] = []
        func add(_ input: String, _ flags: UIKeyModifierFlags = [], _ action: Selector) {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                      UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
            for flags: UIKeyModifierFlags in [[], .shift, .command, [.command, .shift]] {
                add(input, flags, #selector(arrowKey(_:)))
            }
        }
        for flags: UIKeyModifierFlags in [[], .shift] {
            add("\r", flags, #selector(returnKey(_:)))
            add("\t", flags, #selector(tabKey(_:)))
        }
        add("\u{8}", [], #selector(deleteKey(_:)))
        add(UIKeyCommand.inputDelete, [], #selector(deleteKey(_:)))
        add(UIKeyCommand.inputEscape, [], #selector(escapeKey(_:)))
        add(UIKeyCommand.inputHome, [], #selector(homeKey(_:)))
        add(UIKeyCommand.inputPageUp, [], #selector(pageUpKey(_:)))
        add(UIKeyCommand.inputPageDown, [], #selector(pageDownKey(_:)))
        add(UIKeyCommand.f2, [], #selector(f2Key(_:)))
        return commands
    }

    @objc private func arrowKey(_ command: UIKeyCommand) {
        let direction: SelectionState.Direction
        switch command.input {
        case UIKeyCommand.inputUpArrow: direction = .up
        case UIKeyCommand.inputDownArrow: direction = .down
        case UIKeyCommand.inputLeftArrow: direction = .left
        default: direction = .right
        }
        controller.handle(.arrow(direction), shift: command.modifierFlags.contains(.shift),
                          toEdge: command.modifierFlags.contains(.command))
    }

    @objc private func returnKey(_ command: UIKeyCommand) {
        controller.handle(.returnKey, shift: command.modifierFlags.contains(.shift))
    }

    @objc private func tabKey(_ command: UIKeyCommand) {
        controller.handle(.tab, shift: command.modifierFlags.contains(.shift))
    }

    @objc private func deleteKey(_ command: UIKeyCommand) { controller.handle(.delete) }
    @objc private func escapeKey(_ command: UIKeyCommand) { controller.handle(.escape) }
    @objc private func homeKey(_ command: UIKeyCommand) { controller.handle(.home) }
    @objc private func pageUpKey(_ command: UIKeyCommand) { controller.handle(.pageUp) }
    @objc private func pageDownKey(_ command: UIKeyCommand) { controller.handle(.pageDown) }
    @objc private func f2Key(_ command: UIKeyCommand) { controller.handle(.f2) }

    /// Typing on a hardware keyboard while the grid has focus replaces the
    /// cell (Enter mode), as on the Mac.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !controller.isEditing, let key = presses.first?.key, Self.startsTyping(key) {
            controller.beginEditing(mode: .enter, initialText: key.characters)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    /// Whether a key starts type-to-replace editing: a printable character
    /// without ⌘ or ⌃. Arrows, Return, Tab, Escape, Delete, Home/End, the
    /// page keys and function keys go on to the key commands (UIKit offers
    /// presses here first).
    static func startsTyping(_ key: UIKey) -> Bool {
        let flags = key.modifierFlags
        if flags.contains(.command) || flags.contains(.control) { return false }
        if nonTypingKeys.contains(key.keyCode) || key.characters.hasPrefix("UIKeyInput") { return false }
        guard let first = key.characters.unicodeScalars.first else { return false }
        if (0xF700...0xF8FF).contains(first.value) { return false }
        return !CharacterSet.controlCharacters.contains(first)
    }

    private static let nonTypingKeys: Set<UIKeyboardHIDUsage> = {
        var keys: Set<UIKeyboardHIDUsage> = [
            .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
            .keyboardReturnOrEnter, .keypadEnter, .keyboardTab, .keyboardEscape,
            .keyboardDeleteOrBackspace, .keyboardDeleteForward, .keyboardInsert,
            .keyboardHome, .keyboardEnd, .keyboardPageUp, .keyboardPageDown,
        ]
        let functionKeys: [UIKeyboardHIDUsage] = [
            .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
            .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
            .keyboardF13, .keyboardF14, .keyboardF15, .keyboardF16, .keyboardF17, .keyboardF18,
            .keyboardF19, .keyboardF20, .keyboardF21, .keyboardF22, .keyboardF23, .keyboardF24,
        ]
        keys.formUnion(functionKeys)
        return keys
    }()

    // MARK: Edit actions (menu bar, keyboard shortcuts, the edit menu)

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(selectAll(_:)):
            return document != nil
        case #selector(paste(_:)):
            return document != nil && SpreadsheetDocument.pasteboardHasContent
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) { controller.copy() }
    override func cut(_ sender: Any?) { controller.cut() }
    override func paste(_ sender: Any?) { controller.paste() }
    override func delete(_ sender: Any?) { controller.delete() }
    override func selectAll(_ sender: Any?) { controller.selectAll() }

    // MARK: Cell editor

    private func repositionEditor() {
        guard let field = editorField, let frame = field.gridFrame else { return }
        field.frame = scrollRect(frame)
        field.font = PlatformFont.cellFont(name: CellStyle.defaultFontName, size: CellStyle.defaultFontSize * zoom)
    }

    fileprivate func editorReturn() -> Bool { controller.editorCommand(.newline) }
    fileprivate func editorCommand(_ command: GridController.EditorCommand) -> Bool {
        controller.editorCommand(command)
    }
    fileprivate var editorArrowsMoveSelection: Bool { controller.editMode == .enter }

    fileprivate func editorEnded(_ field: CellEditorField) {
        guard field === editorField else { return }
        controller.editorDidEndEditing()
    }

    func scrollActiveCellToVisible() {
        controller.scrollActiveCellToVisible()
    }
}

// MARK: - Accessibility

extension GridView {
    /// One element for the grid, except while a cell is being typed in:
    /// then the editor is what VoiceOver (and UI tests) reach.
    override var isAccessibilityElement: Bool {
        get { !controller.isEditing }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get { editorField.map { [$0] } }
        set {}
    }

    /// VoiceOver reads the selected cell and what it shows ("B3, 84").
    override var accessibilityValue: String? {
        get { controller.accessibilitySummary }
        set {}
    }

    /// The charts on screen, as actions that select them (a chart is
    /// pixels in the grid, which is one element).
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            controller.visibleChartsForAccessibility.map { item in
                UIAccessibilityCustomAction(name: "Select " + item.label) { [weak self] _ in
                    guard let self, let document = self.document else { return false }
                    document.selectChart(item.id)
                    self.controller.stateChanged()
                    return true
                }
            }
        }
        set {}
    }
}

extension GridView: GridHost {
    var visibleGridRect: CGRect {
        CGRect(x: contentOffset.x / zoom, y: contentOffset.y / zoom,
               width: bounds.width / zoom, height: bounds.height / zoom)
    }

    func gridNeedsDisplay() {
        canvas.setNeedsDisplay()
    }

    func gridSizeChanged() {
        refreshSize()
    }

    func scrollGrid(to origin: CGPoint) {
        var offset = CGPoint(x: origin.x * zoom, y: origin.y * zoom)
        offset.x = max(0, min(offset.x, contentSize.width - bounds.width))
        offset.y = max(0, min(offset.y, contentSize.height - bounds.height))
        setContentOffset(offset, animated: false)
    }

    func showEditor(text: String, frame: CGRect) {
        let field = CellEditorField(frame: scrollRect(frame))
        field.gridFrame = frame
        field.grid = self
        field.text = text
        field.borderStyle = .line
        field.backgroundColor = SystemColors.textBackground
        field.font = PlatformFont.cellFont(name: CellStyle.defaultFontName, size: CellStyle.defaultFontSize * zoom)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .next
        field.delegate = field
        addSubview(field)
        editorField = field
        field.becomeFirstResponder()
        // Caret at end.
        let end = field.endOfDocument
        field.selectedTextRange = field.textRange(from: end, to: end)
    }

    var editorText: String {
        editorField?.text ?? ""
    }

    func selectionDidChange() {
        if UIAccessibility.isVoiceOverRunning, let summary = controller.accessibilitySummary {
            UIAccessibility.post(notification: .announcement, argument: summary)
        }
    }

    func removeEditor(refocusGrid: Bool) {
        guard let field = editorField else { return }
        editorField = nil
        if refocusGrid, field.isFirstResponder { _ = becomeFirstResponder() }
        field.removeFromSuperview()
    }
}

// MARK: - Gesture rules

extension GridView {
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === handleDrag {
            // Only from a selection grip or a header edge; anything else scrolls.
            let point = gridPoint(gesture.location(in: self))
            if controller.gripHit(at: point) != nil { return true }
            // On the selected chart: move or resize it rather than scroll.
            if controller.selectedChartHit(at: point) { return true }
            let geometry = controller.geometry
            let content = geometry.contentPoint(point)
            switch geometry.region(at: point) {
            case .columnHeader: return geometry.columnBoundary(near: content.x, slop: controller.hitSlop) != nil
            case .rowHeader: return geometry.rowBoundary(near: content.y, slop: controller.hitSlop) != nil
            default: return false
            }
        }
        return super.gestureRecognizerShouldBegin(gesture)
    }
}

// MARK: - Context menus

extension GridView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let document else { return nil }
        let point = gridPoint(location)
        let sections: [[GridController.MenuItem]]
        if let chart = controller.chartMenu(at: point) {
            sections = chart
        } else if let header = controller.headerMenu(at: point) {
            sections = header
        } else if controller.geometry.region(at: point) == .cells {
            // Like a right-click in Excel: outside the selection, select the cell first.
            let address = controller.geometry.address(at: point)
            if !document.activeSheet.expandedForMerges(document.selection.range).contains(address) {
                controller.press(at: point)
                controller.release()
            }
            sections = cellMenu()
        } else {
            return nil
        }
        menuHighlight = menuHighlightRect(at: point)
        return UIContextMenuConfiguration(identifier: "grid" as NSString, previewProvider: nil) { _ in
            UIMenu(children: sections.map { section in
                UIMenu(options: .displayInline, children: section.map { item in
                    UIAction(title: item.title, attributes: item.destructive ? .destructive : []) { _ in item.action() }
                })
            })
        }
    }

    /// The menu lifts just what it acts on (a header, or the selected
    /// cells), not a snapshot of the whole grid.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        menuPreview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        menuPreview()
    }

    private func menuPreview() -> UITargetedPreview? {
        guard let rect = menuHighlight else { return nil }
        var onCanvas = scrollRect(rect)
        onCanvas.origin.x -= contentOffset.x
        onCanvas.origin.y -= contentOffset.y
        onCanvas = onCanvas.intersection(canvas.bounds)
        guard !onCanvas.isNull, !onCanvas.isEmpty else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: onCanvas, cornerRadius: 4)
        return UITargetedPreview(view: canvas, parameters: parameters)
    }

    /// What a menu at a point acts on, in grid coordinates: a row or
    /// column header (the whole selection's, when the press is inside it),
    /// or the selected cells.
    private func menuHighlightRect(at point: CGPoint) -> CGRect? {
        guard let document else { return nil }
        let geometry = controller.geometry
        let selection = geometry.viewRect(document.activeSheet.expandedForMerges(document.selection.range))
        let visible = geometry.visible
        switch geometry.region(at: point) {
        case .columnHeader:
            return CGRect(x: selection.minX, y: visible.minY, width: selection.width, height: GridLayout.headerHeight)
        case .rowHeader:
            return CGRect(x: visible.minX, y: selection.minY, width: GridLayout.headerWidth, height: selection.height)
        case .cells:
            // A chart's menu lifts the chart.
            if let chart = document.selectedChart { return SheetChartLayer.frame(of: chart, in: geometry) }
            return selection
        case .corner:
            return nil
        }
    }

    /// Cut/Copy/Paste and the commands that act on the selected cells.
    private func cellMenu() -> [[GridController.MenuItem]] {
        typealias Item = GridController.MenuItem
        let c = controller
        func doc(_ title: String, destructive: Bool = false, _ body: @escaping (SpreadsheetDocument) -> Void) -> Item {
            Item(title: title, destructive: destructive) { [weak c] in
                guard let c, let document = c.document else { return }
                document.commitPendingEdit()
                body(document)
                c.stateChanged()
            }
        }
        var clipboard = [Item(title: "Cut") { [weak c] in c?.cut() },
                         Item(title: "Copy") { [weak c] in c?.copy() }]
        if SpreadsheetDocument.pasteboardHasContent {
            clipboard.append(Item(title: "Paste") { [weak c] in c?.paste() })
        }
        return [
            clipboard,
            [doc("Fill Down") { $0.fillDown() },
             doc("Fill Right") { $0.fillRight() },
             doc("Clear Contents") { $0.clearSelectionContents() }],
            [doc("Insert Rows Above") { $0.insertRows(at: $0.selection.range.start.row, count: $0.selection.range.rowCount) },
             doc("Insert Columns Left") { $0.insertColumns(at: $0.selection.range.start.column, count: $0.selection.range.columnCount) },
             doc("Delete Rows", destructive: true) { $0.deleteRows(at: $0.selection.range.start.row, count: $0.selection.range.rowCount) },
             doc("Delete Columns", destructive: true) { $0.deleteColumns(at: $0.selection.range.start.column, count: $0.selection.range.columnCount) }],
        ]
    }
}

extension GridView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let edit = UIAction(title: "Edit") { [weak self] _ in
            self?.controller.beginEditing(mode: .edit, initialText: nil)
        }
        let fillDown = UIAction(title: "Fill Down") { [weak self] _ in
            self?.document?.fillDown()
            self?.controller.stateChanged()
        }
        return UIMenu(children: [edit] + suggestedActions + [fillDown])
    }
}

// MARK: - Pointer

extension GridView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        let point = gridPoint(request.location)
        let geometry = controller.geometry
        let content = geometry.contentPoint(point)
        switch geometry.region(at: point) {
        case .columnHeader where geometry.columnBoundary(near: content.x, slop: 4) != nil:
            return UIPointerRegion(rect: CGRect(x: request.location.x - 4, y: request.location.y - 4, width: 8, height: 8),
                                   identifier: "column")
        case .rowHeader where geometry.rowBoundary(near: content.y, slop: 4) != nil:
            return UIPointerRegion(rect: CGRect(x: request.location.x - 4, y: request.location.y - 4, width: 8, height: 8),
                                   identifier: "row")
        default:
            return defaultRegion
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        switch region.identifier as? String {
        case "column":
            let style = UIPointerStyle(shape: .verticalBeam(length: 18), constrainedAxes: [])
            style.accessories = [.arrow(.left), .arrow(.right)]
            return style
        case "row":
            let style = UIPointerStyle(shape: .horizontalBeam(length: 18), constrainedAxes: [])
            style.accessories = [.arrow(.top), .arrow(.bottom)]
            return style
        default:
            return nil
        }
    }
}

// MARK: - Filter popover

extension GridView {
    /// Open a filter column's popover from its header cell.
    func showFilterPopover(columnOffset: Int, from rect: CGRect) {
        guard let document, let presenter = owningViewController() else { return }
        var host: UIHostingController<FilterPopoverView>?
        let view = FilterPopoverView(document: document, columnOffset: columnOffset) { [weak self] in
            host?.dismiss(animated: true)
            _ = self?.becomeFirstResponder()
            self?.canvas.setNeedsDisplay()
        }
        let controller = UIHostingController(rootView: view)
        host = controller
        controller.modalPresentationStyle = .popover
        controller.preferredContentSize = controller.sizeThatFits(in: CGSize(width: 360, height: 700))
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = scrollRect(rect)
            popover.permittedArrowDirections = [.up, .down]
        }
        presenter.present(controller, animated: true)
    }

    func owningViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}

// MARK: - Canvas

/// Draws what is on screen; the grid keeps it over the visible bounds.
private final class GridCanvas: UIView {
    weak var grid: GridView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        contentMode = .redraw
        backgroundColor = SystemColors.textBackground
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        grid?.drawGrid(in: rect)
    }
}

// MARK: - Cell editor

/// The in-cell text field: Return, Tab and Escape (and the arrows, while
/// typing replaces the cell) go to the grid, as on the Mac.
private final class CellEditorField: UITextField, UITextFieldDelegate {
    weak var grid: GridView?
    /// Where the editor sits, in grid coordinates (re-placed on zoom).
    var gridFrame: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The iPad keyboard's shortcut bar: formula characters, and Tab.
        let item = inputAssistantItem
        func key(_ title: String) -> UIBarButtonItem {
            UIBarButtonItem(primaryAction: UIAction(title: title) { [weak self] _ in self?.insertText(title) })
        }
        item.leadingBarButtonGroups = [UIBarButtonItemGroup(barButtonItems: ["=", "(", ")", ":", "$", ","].map(key),
                                                            representativeItem: nil)]
        let tab = UIBarButtonItem(primaryAction: UIAction(image: UIImage(systemName: "arrow.right.to.line")) { [weak self] _ in
            _ = self?.grid?.editorCommand(.tab)
        })
        item.trailingBarButtonGroups = [UIBarButtonItemGroup(barButtonItems: [tab], representativeItem: nil)]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabKey)),
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(backtabKey)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeKey)),
        ]
        if grid?.editorArrowsMoveSelection == true {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow,
                          UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
                commands.append(UIKeyCommand(input: input, modifierFlags: [], action: #selector(arrowKey(_:))))
            }
        }
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func tabKey() { _ = grid?.editorCommand(.tab) }
    @objc private func backtabKey() { _ = grid?.editorCommand(.backtab) }
    @objc private func escapeKey() { _ = grid?.editorCommand(.cancel) }

    @objc private func arrowKey(_ command: UIKeyCommand) {
        let direction: SelectionState.Direction
        switch command.input {
        case UIKeyCommand.inputUpArrow: direction = .up
        case UIKeyCommand.inputDownArrow: direction = .down
        case UIKeyCommand.inputLeftArrow: direction = .left
        default: direction = .right
        }
        _ = grid?.editorCommand(.arrow(direction))
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        _ = grid?.editorReturn()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        grid?.editorEnded(self)
    }
}

// MARK: - SwiftUI

/// Bridges the UIKit grid into SwiftUI and keeps it in sync with the
/// document's revision, selection and zoom.
struct GridContainer: UIViewRepresentable {
    @ObservedObject var document: SpreadsheetDocument
    /// Bumped by SwiftUI to ask the grid to redraw (e.g. selection from name box).
    let revision: Int
    let onStateChange: () -> Void

    final class Coordinator {
        var lastScrollTick = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> GridView {
        let grid = GridView(frame: .zero)
        grid.document = document
        grid.onStateChange = onStateChange
        grid.apply(zoom: document.zoomLevel)
        grid.refreshSize()
        DispatchQueue.main.async { _ = grid.becomeFirstResponder() }
        return grid
    }

    func updateUIView(_ grid: GridView, context: Context) {
        grid.document = document
        grid.onStateChange = onStateChange
        grid.refreshSize()
        // Zoom from the menu or status bar keeps the top-left in place, as
        // on the Mac (a pinch has already applied its own).
        if abs(grid.zoom - document.zoomLevel) > 0.001 {
            grid.apply(zoom: document.zoomLevel)
            DispatchQueue.main.async { grid.scrollActiveCellToVisible() }
        }
        if context.coordinator.lastScrollTick != document.scrollTick {
            context.coordinator.lastScrollTick = document.scrollTick
            DispatchQueue.main.async { grid.scrollActiveCellToVisible() }
        }
    }
}
#endif
