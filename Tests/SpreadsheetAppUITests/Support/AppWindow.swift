#if os(macOS)
import AppKit
import Foundation
import ObjectiveC
import SwiftUI
import Testing
import Vision
@testable import SpreadsheetCore
@testable import SpreadsheetFiles
@testable import SpreadsheetUI

/// Whether the UI tests run: only when asked (scripts/ui-tests.sh), as they
/// take minutes.
enum UITests {
    static let enabled = ProcessInfo.processInfo.environment["SIMPLESPREAD_UI_TESTS"] == "1"
    /// Where screenshots go: every failure's, and every step's with
    /// SIMPLESPREAD_UI_SHOTS=1.
    static let artifacts: URL = {
        let base = ProcessInfo.processInfo.environment["SIMPLESPREAD_UI_ARTIFACTS"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/ui-test-artifacts")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static let shootsEveryStep = ProcessInfo.processInfo.environment["SIMPLESPREAD_UI_SHOTS"] == "1"
}

/// A line of text read off the screen, and where (in the window's coordinates).
struct ScreenText: CustomStringConvertible {
    let text: String
    let frame: CGRect
    /// Where a part of the line is (the recogniser can run neighbouring
    /// labels together: "Select All Clear").
    var frameOf: ((Range<String.Index>) -> CGRect?)? = nil
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    var description: String { "\"\(text)\"" }
}

/// A document window as the app shows it (DocumentWindowView in a hosting
/// view), off screen, driven like a person drives it: clicks, drags and
/// keys sent to the window, menu commands from the menus' own catalog, and
/// what's on screen read back with text recognition. The window never
/// shows and the app is never activated, so it runs alongside other work.
@MainActor
final class AppWindow {
    let document: SpreadsheetDocument
    let window: NSWindow
    let name: String
    private var step = 0

    /// AppKit spends a click in an inactive app on activating it (unless
    /// the view takes first clicks), so a test's clicks would do nothing. A
    /// person's app is active; activating this one would take the screen
    /// from whoever is using it. So the test process says it's active
    /// without becoming so.
    private static let activeApp: Void = {
        let selector = #selector(getter: NSApplication.isActive)
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        let alwaysActive: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(method, imp_implementationWithBlock(alwaysActive))
    }()

    init(_ document: SpreadsheetDocument, name: String = #function, size: CGSize = CGSize(width: 1280, height: 800)) async {
        _ = Self.activeApp
        self.document = document
        self.name = name.replacingOccurrences(of: "()", with: "")
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                          styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DocumentWindowView(document: document))
        // Key within this process (the app isn't activated: nothing moves to the front).
        window.makeKeyAndOrderFront(nil)
        await settle(0.6)
        if let grid { window.makeFirstResponder(grid) }
        grid?.controller.chartLayer.rendersSynchronously = true
        // This run's shots and trace only.
        try? FileManager.default.removeItem(at: traceFile.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: traceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: traceFile)
        trace("opened")
    }

    /// Each step, appended to `<artifacts>/<test>/trace.log` as it happens:
    /// if the test host dies mid-test (AppKit can end it without a word),
    /// the last line says where.
    var traceFile: URL { UITests.artifacts.appendingPathComponent(name).appendingPathComponent("trace.log") }

    func trace(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: traceFile) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    func close() {
        window.attachedSheet.map { window.endSheet($0) }
        window.close()
    }

    /// Let SwiftUI, the grid and any animation catch up.
    func settle(_ seconds: Double = 0.25) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Finding views

    var grid: SpreadsheetGridView? { Self.find(SpreadsheetGridView.self, in: window.contentView) }

    static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    /// The sheet (dialog) shown on the window, if any.
    var sheet: NSWindow? { window.attachedSheet }

    /// Popovers (the filter popover) showing from this window.
    var popovers: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0 !== window && $0 !== sheet && $0.className.contains("Popover") }
    }

    // MARK: The grid

    /// A cell's centre, in the window's coordinates.
    func point(_ a1: String) throws -> CGPoint {
        let grid = try #require(grid)
        let rect = grid.controller.geometry.cellRect(try #require(CellAddress(a1: a1)))
        return grid.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// A point in the grid's view coordinates, in the window's.
    func windowPoint(grid point: CGPoint) throws -> CGPoint {
        try #require(grid).convert(point, to: nil)
    }

    /// Scroll so a cell shows (as a person scrolls to it).
    func reveal(_ a1: String) async throws {
        let grid = try #require(grid)
        let rect = grid.controller.geometry.cellRect(try #require(CellAddress(a1: a1)))
        if !grid.visibleRect.insetBy(dx: 60, dy: 40).contains(rect) {
            grid.scrollToVisible(rect.insetBy(dx: -120, dy: -80))
            await settle(0.15)
        }
    }

    func click(_ a1: String, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) async throws {
        try await reveal(a1)
        try await click(at: point(a1), count: count, modifiers: modifiers)
    }

    func click(at point: CGPoint, in target: NSWindow? = nil, count: Int = 1,
               modifiers: NSEvent.ModifierFlags = []) async throws {
        let target = target ?? window
        trace("click \(count)× at \(point)\(target === window ? "" : " in \(Swift.type(of: target))")")
        // A click goes to the window it's in, which becomes key (a popover's too).
        if !target.isKeyWindow, target.canBecomeKey { target.makeKey() }
        for n in 1...count {
            if isOnGrid(point, in: target) {
                send(.leftMouseDown, at: point, in: target, clickCount: n, modifiers: modifiers)
                send(.leftMouseUp, at: point, in: target, clickCount: n, modifiers: modifiers)
            } else {
                // Controls (buttons, segmented controls, checkboxes) track the
                // mouse in a loop of their own until it comes up: the mouse-up
                // waits in the queue for that loop, and goes to the window if
                // nothing took it.
                pressedViewWasGrid = false
                let down = makeMouse(.leftMouseDown, at: point, in: target, clickCount: n, modifiers: modifiers)
                let up = makeMouse(.leftMouseUp, at: point, in: target, clickCount: n, modifiers: modifiers)
                if let control = control(at: point, in: target) {
                    // AppKit controls track the mouse in an event loop of their
                    // own, which a test host can't run: operate them as an
                    // accessibility press does.
                    press(control, at: point)
                } else {
                    // SwiftUI recognises a tap over a turn of the run loop.
                    target.sendEvent(down)
                    try? await Task.sleep(for: .milliseconds(30))
                    target.sendEvent(up)
                }
            }
        }
        // The grid acts at once; SwiftUI controls on the next turn or two.
        await settle(target === window && pressedViewWasGrid ? 0.02 : 0.25)
    }

    /// Press, move in steps, release.
    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 8) async {
        trace("drag \(start) → \(end)")
        send(.leftMouseDown, at: start, in: window, clickCount: 1)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            send(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                 in: window, clickCount: 1)
        }
        send(.leftMouseUp, at: end, in: window, clickCount: 1)
        await settle()
    }

    func drag(_ from: String, to: String) async throws {
        await drag(from: try point(from), to: try point(to))
    }

    /// The context menu a right-click there shows (its item titles), and
    /// optionally choose one.
    @discardableResult
    func rightClick(at point: CGPoint, choose title: String? = nil) async throws -> [String] {
        trace("right-click at \(point) choosing \(title ?? "nothing")")
        let grid = try #require(grid)
        let event = makeMouse(.rightMouseDown, at: point, in: window, clickCount: 1, modifiers: [])
        guard let menu = grid.menu(for: event) else { return [] }
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        if let title, let item = menu.items.first(where: { $0.title == title }) {
            menu.performActionForItem(at: menu.index(of: item))
            await settle()
        }
        return titles
    }

    private func makeMouse(_ type: NSEvent.EventType, at point: CGPoint, in target: NSWindow, clickCount: Int,
                           modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// The grid (an AppKit view) gets its mouse events as the window passes
    /// them on once it's active: an inactive app's window spends the first
    /// click on activating, unless the view takes first clicks, which the
    /// grid (like most Mac content views) doesn't. SwiftUI controls do, so
    /// they're sent through the window, as the system sends them.
    private var pressedView: NSView?
    private var pressedViewWasGrid = false

    private func gridView(at point: CGPoint, in target: NSWindow) -> SpreadsheetGridView? {
        let content = target.contentView
        var v = content.flatMap { $0.hitTest($0.superview?.convert(point, from: nil) ?? point) }
        while let current = v {
            if let g = current as? SpreadsheetGridView { return g }
            v = current.superview
        }
        return nil
    }

    private func isOnGrid(_ point: CGPoint, in target: NSWindow) -> Bool { gridView(at: point, in: target) != nil }

    /// The AppKit control (which tracks the mouse itself) there, if any.
    /// Found by where controls are, not by hit-testing: SwiftUI hit-tests to
    /// its own container and passes clicks on to the controls it hosts.
    private func control(at point: CGPoint, in target: NSWindow) -> NSControl? {
        func search(_ view: NSView) -> NSControl? {
            guard !view.isHidden, view.alphaValue > 0 else { return nil }
            for sub in view.subviews.reversed() { if let hit = search(sub) { return hit } }
            // Labels are text fields too: only an editable one is a control.
            // A list (a table) takes its clicks as events, row by row.
            if let control = view as? NSControl, (control as? NSTextField)?.isEditable ?? true, control.isEnabled,
               !(control is NSTableView),
               view.convert(view.bounds, to: nil).contains(point) {
                return control
            }
            return nil
        }
        return target.contentView.flatMap(search)
    }

    private func press(_ control: NSControl, at point: CGPoint) {
        switch control {
        case let field as NSTextField:
            // Clicking a text field starts editing in it (its own mouse
            // tracking would wait forever for events).
            field.window?.makeFirstResponder(field)
        case let segmented as NSSegmentedControl:
            let local = segmented.convert(point, from: nil)
            var x: CGFloat = 0
            let auto = segmented.bounds.width / CGFloat(max(1, segmented.segmentCount))
            for i in 0..<segmented.segmentCount {
                let w = segmented.width(forSegment: i) > 0 ? segmented.width(forSegment: i) : auto
                if local.x < x + w || i == segmented.segmentCount - 1 {
                    segmented.selectedSegment = i
                    break
                }
                x += w
            }
            if let action = segmented.action { NSApp.sendAction(action, to: segmented.target, from: segmented) }
        case let button as NSButton:
            button.performClick(nil)
        default:
            if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
        }
    }

    private func send(_ type: NSEvent.EventType, at point: CGPoint, in target: NSWindow, clickCount: Int,
                      modifiers: NSEvent.ModifierFlags = []) {
        let event = makeMouse(type, at: point, in: target, clickCount: clickCount, modifiers: modifiers)
        let gridView = gridView(at: point, in: target)
        switch type {
        case .leftMouseDown:
            pressedView = gridView
            pressedViewWasGrid = gridView != nil
            if let gridView { gridView.mouseDown(with: event); return }
        case .leftMouseDragged:
            if let pressed = pressedView { pressed.mouseDragged(with: event); return }
        case .leftMouseUp:
            defer { pressedView = nil }
            if let pressed = pressedView { pressed.mouseUp(with: event); return }
        default:
            break
        }
        target.sendEvent(event)
    }

    /// A chart's frame on screen (window coordinates).
    func chartFrame(_ chart: SheetChart) throws -> CGRect {
        let grid = try #require(grid)
        return grid.convert(SheetChartLayer.frame(of: chart, in: grid.controller.geometry), to: nil)
    }

    /// A header cell's filter button (the AutoFilter dropdown), in window coordinates.
    func filterButton(_ a1: String) throws -> CGPoint {
        let grid = try #require(grid)
        let cell = grid.controller.geometry.cellRect(try #require(CellAddress(a1: a1)))
        let button = try #require(GridGeometry.dropdownButtonRect(in: cell))
        return grid.convert(CGPoint(x: button.midX, y: button.midY), to: nil)
    }

    /// An Edit menu action as its menu item sends it: to the first responder.
    func edit(_ action: String) async {
        // To the window's focused view, up the responder chain, as the menu
        // sends it to the key window's.
        _ = window.firstResponder?.tryToPerform(Selector(action), with: nil)
        await settle(0.1)
    }

    // MARK: Keys

    enum Key {
        case returnKey, tab, escape, delete, forwardDelete, up, down, left, right, f2
        case character(String)

        var code: UInt16 {
            switch self {
            case .returnKey: 36
            case .tab: 48
            case .escape: 53
            case .delete: 51
            case .forwardDelete: 117
            case .up: 126
            case .down: 125
            case .left: 123
            case .right: 124
            case .f2: 120
            case .character: 0
            }
        }

        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .tab: "\t"
            case .escape: "\u{1b}"
            case .delete: "\u{7f}"
            case .forwardDelete: String(UnicodeScalar(NSDeleteFunctionKey)!)
            case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .left: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right: String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .f2: String(UnicodeScalar(NSF2FunctionKey)!)
            case .character(let c): c
            }
        }
    }

    func press(_ key: Key, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) async {
        let target = target ?? sheet ?? window
        trace("key \(key)\(modifiers.isEmpty ? "" : " \(modifiers.rawValue)")")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: target.windowNumber, context: nil,
                                         characters: key.characters, charactersIgnoringModifiers: key.characters,
                                         isARepeat: false, keyCode: key.code)!
            target.sendEvent(event)
        }
        await settle(0.1)
    }

    /// Type text, a key at a time, into whatever has focus.
    func type(_ text: String, in target: NSWindow? = nil) async {
        for ch in text { await press(.character(String(ch)), in: target) }
        await settle(0.1)
    }

    // MARK: Menus

    /// Run a menu command as its menu item does.
    func menu(_ title: String, in menu: String? = nil) async throws {
        trace("menu \(menu.map { "\($0) ▸ " } ?? "")\(title)")
        let command = try #require(DocumentCommand.all.first {
            $0.name == title && (menu == nil || $0.menu == menu)
        }, "no menu command \(title)")
        #expect(command.isEnabled(document), "\(title) is disabled")
        perform(document) { command.run($0) }
        await settle(0.12)
    }

    /// Choose `item` in the pop-up menu showing `current` (a SwiftUI
    /// menu-style Picker is a pop-up button), as choosing it from its menu.
    func choose(_ item: String, inPopUpShowing current: String, in target: NSWindow? = nil) async throws {
        trace("choose \(item) in the pop-up showing \(current)")
        let target = target ?? sheet ?? window
        func popUps(_ view: NSView?) -> [NSPopUpButton] {
            guard let view else { return [] }
            return (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popUps)
        }
        let candidates = popUps(target.contentView)
        let button = try #require(candidates.first { $0.titleOfSelectedItem == current },
                                  "no pop-up showing \(current): \(candidates.map { $0.titleOfSelectedItem ?? "" })")
        let index = button.indexOfItem(withTitle: item)
        try #require(index >= 0, "\(current)'s menu has no \(item): \(button.itemTitles)")
        button.selectItem(at: index)
        if let action = button.action { NSApp.sendAction(action, to: button.target, from: button) }
        if let menuItem = button.item(at: index), let action = menuItem.action {
            NSApp.sendAction(action, to: menuItem.target, from: menuItem)
        }
        await settle()
    }

    // MARK: Reading the screen

    /// The text showing in the window (or its sheet), read with text recognition.
    func screenText(in target: NSWindow? = nil) throws -> [ScreenText] {
        let target = target ?? window
        guard let view = target.contentView else { return [] }
        view.layoutSubtreeIfNeeded()
        view.display()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return [] }
        // Upscaled: recognition reads small interface text far better.
        let scale = 3
        let w = cg.width * scale, h = cg.height * scale
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        try VNImageRequestHandler(cgImage: try #require(ctx.makeImage())).perform([request])
        // Vision's boxes are normalised with the origin bottom-left, as
        // the window's: scale them onto the view's rectangle in the window.
        let area = view.convert(view.bounds, to: nil)
        @Sendable func toWindow(_ b: CGRect) -> CGRect {
            CGRect(x: area.minX + b.minX * area.width, y: area.minY + b.minY * area.height,
                   width: b.width * area.width, height: b.height * area.height)
        }
        return (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            let inWindow = toWindow(observation.boundingBox)
            return ScreenText(text: top.string, frame: inWindow, frameOf: { range in
                (try? top.boundingBox(for: range)).flatMap { $0 }.map { toWindow($0.boundingBox) }
            })
        }
    }

    /// Text on screen matching `label`: exactly, or near enough (case,
    /// spacing and the recogniser's l/1/I slips aside).
    func find(_ label: String, in target: NSWindow? = nil, exact: Bool = false) throws -> ScreenText? {
        let lines = try screenText(in: target)
        // When a label shows more than once (a dialog's title and its button,
        // "Sort"), the lowest: buttons sit below what they belong to.
        func lowest(_ hits: [ScreenText]) -> ScreenText? { hits.min { $0.frame.minY < $1.frame.minY } }
        if let hit = lowest(lines.filter { $0.text == label }) { return hit }
        // The recogniser adds stray marks ("(Create") and mixes up l, 1 and I.
        let wanted = Self.fold(label)
        if let hit = lowest(lines.filter { Self.fold($0.text) == wanted }) { return hit }
        // A whole word within a line ("Clear" in "Select All Clear").
        for line in lines {
            var searchStart = line.text.startIndex
            while let range = line.text.range(of: label, options: .caseInsensitive, range: searchStart..<line.text.endIndex) {
                let before = range.lowerBound == line.text.startIndex || line.text[line.text.index(before: range.lowerBound)] == " "
                let after = range.upperBound == line.text.endIndex || line.text[range.upperBound] == " "
                if before, after, let frame = line.frameOf?(range) { return ScreenText(text: label, frame: frame) }
                searchStart = range.upperBound
            }
        }
        guard !exact else { return nil }
        return lines.first { Self.fold($0.text).contains(wanted) }
    }

    func shows(_ label: String, in target: NSWindow? = nil) throws -> Bool { try find(label, in: target) != nil }

    /// Wait until `label` shows (or `timeout` passes).
    func waitFor(_ label: String, in target: @autoclosure () -> NSWindow? = nil, timeout: Double = 3) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try find(label, in: target()) != nil { return true }
            await settle(0.2)
        } while Date() < deadline
        return false
    }

    /// Click the control showing `label` (a button, a checkbox's label, a
    /// tab), in the window or its sheet.
    func click(text label: String, in target: NSWindow? = nil, exact: Bool = false) async throws {
        let target = target ?? sheet ?? window
        let shown = try screenText(in: target)
        let hit = try #require(try find(label, in: target, exact: exact), "no \"\(label)\" on screen: \(shown)")
        trace("click \"\(label)\"")
        try await click(at: hit.center, in: target)
    }

    private static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "1", with: "l").replacingOccurrences(of: "i", with: "l")
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Screenshots

    /// Save what the window shows (and its sheet), named for the step.
    @discardableResult
    func screenshot(_ label: String, popover: NSWindow? = nil) -> URL? {
        step += 1
        let folder = UITests.artifacts.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var last: URL?
        for (suffix, target) in [("", window), ("-sheet", sheet), ("-popover", popover ?? popovers.first)] {
            guard let target, let view = target.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = folder.appendingPathComponent(String(format: "%02d-%@%@.png", step, label, suffix))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            last = url
        }
        return last
    }

    /// A step: shot when every step is asked for; on a failed check the
    /// test calls `screenshot` itself.
    func note(_ label: String) {
        trace("— \(label)")
        if UITests.shootsEveryStep { screenshot(label) }
    }
}

/// Check `condition`, saving a screenshot of `app` when it fails.
@MainActor
func check(_ condition: Bool, _ message: String, _ app: AppWindow,
           sourceLocation: SourceLocation = #_sourceLocation) {
    if !condition {
        let shot = app.screenshot("FAILED")
        Issue.record("\(message) (screenshot: \(shot?.path ?? "none"))", sourceLocation: sourceLocation)
    }
}
#endif
