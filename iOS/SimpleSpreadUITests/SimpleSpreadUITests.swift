import XCTest

/// The iPad app driven as a user would: the document browser, typing in
/// the grid, closing (which saves) and reopening. The grid is one view, so
/// cells are reached by position (100 x 22 point cells after 46 x 24 point
/// headers, at 100%) and read back through its accessibility value
/// ("B3, 84").
@MainActor
final class SimpleSpreadUITests: XCTestCase {
    /// Made on first use, on the main actor (XCUIApplication requires it;
    /// an XCTestCase's setUp isn't main-actor isolated).
    lazy var app: XCUIApplication = {
        continueAfterFailure = false
        return XCUIApplication()
    }()

    /// The point in the grid of a cell (row and column from 0), unscrolled.
    func cell(_ grid: XCUIElement, row: Int, column: Int) -> XCUICoordinate {
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 46 + 100 * column + 50, dy: 24 + 22 * row + 11))
    }

    func value(_ grid: XCUIElement) -> String {
        grid.value as? String ?? ""
    }

    /// Tap a cell until the grid shows it selected: on a slow simulator
    /// (CI) the first tap can land while the document is still appearing.
    func select(_ grid: XCUIElement, row: Int, column: Int, file: StaticString = #filePath, line: UInt = #line) {
        let name = "\(Character(UnicodeScalar(65 + column)!))\(row + 1)"
        for _ in 0..<5 {
            cell(grid, row: row, column: column).tap()
            if value(grid).hasPrefix(name + ",") || value(grid) == name { return }
            sleep(1)
        }
        XCTFail("couldn't select \(name): \(value(grid))", file: file, line: line)
    }

    /// Double-tap a cell and type into its editor (Return commits).
    func type(_ text: String, into grid: XCUIElement, row: Int, column: Int) {
        cell(grid, row: row, column: column).doubleTap()
        let editor = app.textFields.element(boundBy: app.textFields.count - 1)
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        app.typeText(text + "\n")
    }

    func testCreateTypeCloseAndReopen() throws {
        app.launch()
        let create = app.buttons["New Spreadsheet"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 60), app.debugDescription)
        create.tap()

        let grid = app.descendants(matching: .any)["grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 60), app.debugDescription)
        let name = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Untitled'")).firstMatch
        XCTAssertTrue(name.exists)
        let title = name.label

        type("42", into: grid, row: 1, column: 1)          // B2
        type("=B2*2", into: grid, row: 2, column: 1)       // B3
        select(grid, row: 2, column: 1)
        XCTAssertEqual(value(grid), "B3, 84")

        // Back to the browser: closing saves.
        app.buttons["Documents"].tap()
        let recent = app.cells.containing(.staticText, identifier: title).firstMatch
        let anyRecent = recent.exists ? recent : app.staticTexts[title].firstMatch
        XCTAssertTrue(anyRecent.waitForExistence(timeout: 60), app.debugDescription)
        anyRecent.tap()

        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        select(grid, row: 2, column: 1)
        XCTAssertEqual(value(grid), "B3, 84")
        select(grid, row: 1, column: 1)
        XCTAssertEqual(value(grid), "B2, 42")
    }

    func testKeyboardNavigationAndUndo() throws {
        app.launchEnvironment["SIMPLESPREAD_DEMO"] = "1"
        app.launch()
        let grid = app.descendants(matching: .any)["grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        select(grid, row: 1, column: 0)                    // A2
        XCTAssertEqual(value(grid), "A2, Widgets")
        // A hardware keyboard: arrows move, typing replaces, Return commits.
        grid.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertEqual(value(grid), "A3, Gadgets")
        grid.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertEqual(value(grid), "B3, 3")
        grid.typeKey("7", modifierFlags: [])                // starts an edit
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        select(grid, row: 2, column: 3)                    // D3 = B3*C3
        XCTAssertEqual(value(grid), "D3, $104.93")
        grid.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(value(grid), "D3, $44.97")
    }

    /// The App Store's 13-inch iPad screenshots (run on the 13-inch iPad
    /// simulator; attached to the test result).
    func testScreenshots() throws {
        for (name, demo) in [("1-budget", "1"), ("2-layout", "layout")] {
            app.launchEnvironment["SIMPLESPREAD_DEMO"] = demo
            app.launch()
            let grid = app.descendants(matching: .any)["grid"]
            XCTAssertTrue(grid.waitForExistence(timeout: 60))
            sleep(2)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }
}

@MainActor
final class CSVTests: XCTestCase {
    /// A CSV opens as a new spreadsheet (the text file is never written
    /// over), holding its values with numbers as numbers.
    func testOpeningACSVMakesASpreadsheet() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let csv = dir.appendingPathComponent("prices.csv")
        try "Item,Price\nTea,3.5\nCake,4\n".write(to: csv, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchEnvironment["SIMPLESPREAD_OPEN"] = csv.path
        app.launch()
        let grid = app.descendants(matching: .any)["grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts["prices"].waitForExistence(timeout: 20))
        // Tap until it takes (a slow simulator may still be presenting).
        for _ in 0..<5 where !(grid.value as? String ?? "").hasPrefix("B2") {
            grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 46 + 150, dy: 24 + 22 + 11)).tap()
            sleep(1)
        }
        XCTAssertEqual(grid.value as? String, "B2, 3.5")
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), "Item,Price\nTea,3.5\nCake,4\n")
    }
}
