import XCTest

/// Screenshots of the app's states, for a person to look over (attached
/// to the test result). Each also checks the state appeared.
@MainActor
final class ReviewTests: XCTestCase {
    /// The app on the sample sheet, launched on first use (on the main
    /// actor, which XCUIApplication requires and setUp isn't).
    lazy var app: XCUIApplication = {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SIMPLESPREAD_DEMO"] = "1"
        app.launch()
        return app
    }()

    func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    var grid: XCUIElement { app.descendants(matching: .any)["grid"] }

    func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    func testHeaderMenu() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        at(46 + 250, 12).press(forDuration: 1.2)          // column C's header
        XCTAssertTrue(app.buttons["Insert Column Left"].waitForExistence(timeout: 20))
        snap("header-menu")
    }

    func testCellMenu() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        at(46 + 150, 24 + 22 * 2 + 11).press(forDuration: 1.2) // B3
        XCTAssertTrue(app.buttons["Fill Down"].waitForExistence(timeout: 20))
        snap("cell-menu")
    }

    func testFilterPopover() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        at(46 + 100 - 9, 24 + 11).tap()                     // A1's filter button
        XCTAssertTrue(app.buttons["Apply"].waitForExistence(timeout: 20))
        snap("filter-popover")
    }

    func testEditingWithTheOnscreenKeyboard() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        at(46 + 50, 24 + 22 * 9 + 11).doubleTap()           // A10
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 20))
        app.typeText("=SUM(B2:B4)")
        sleep(1)
        snap("editing")
    }

    func testEditMenuOnTheSelectedCell() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        at(46 + 350, 24 + 22 * 7 + 11).tap()                // D8, already selected
        XCTAssertTrue(app.menuItems["Edit"].waitForExistence(timeout: 20) || app.buttons["Edit"].waitForExistence(timeout: 1))
        snap("edit-menu")
    }

    func testPinchZoom() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        grid.pinch(withScale: 1.8, velocity: 1)
        sleep(1)
        snap("zoomed")
    }
}
