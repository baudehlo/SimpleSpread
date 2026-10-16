import XCTest

/// Charts by touch on the charts sample (SIMPLESPREAD_DEMO=charts): a
/// column chart, selected, at sheet content (410, 20, 440 × 270); a line
/// chart at (0, 190, 400 × 250).
@MainActor
final class ChartTests: XCTestCase {
    lazy var app: XCUIApplication = {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SIMPLESPREAD_DEMO"] = "charts"
        app.launch()
        return app
    }()

    var grid: XCUIElement { app.descendants(matching: .any)["grid"] }

    /// A point on the sheet (content coordinates: A1's corner is 0, 0).
    func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 46 + x, dy: 24 + y))
    }

    var gridValue: String { grid.value as? String ?? "" }

    func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTapSelectsAndACellTapDeselects() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Delete Chart"].waitForExistence(timeout: 20)) // the panel
        at(200, 320).tap()                                   // the line chart
        XCTAssertTrue(gridValue.hasPrefix("Selected Chart"), gridValue)
        snap("line-selected")
        at(50, 600).tap()                                    // a cell well below
        XCTAssertFalse(gridValue.hasPrefix("Selected Chart"), gridValue)
        XCTAssertFalse(app.buttons["Delete Chart"].exists)
    }

    func testDragMovesTheSelectedChart() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["Delete Chart"].waitForExistence(timeout: 20))
        // Drag the column chart down by 400 points.
        at(630, 150).press(forDuration: 0.1, thenDragTo: at(630, 550))
        sleep(1)
        snap("chart-moved")
        // Where it was is cells now; where it went is the chart.
        at(630, 150).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Fill Down"].waitForExistence(timeout: 20))
        app.tap() // dismiss
        sleep(1)
        at(630, 550).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Edit Chart…"].waitForExistence(timeout: 20)) // the chart's menu
    }

    func testLongPressDeletes() {
        XCTAssertTrue(grid.waitForExistence(timeout: 60))
        at(200, 320).press(forDuration: 1.2)                 // the line chart
        XCTAssertTrue(app.buttons["Edit Chart…"].waitForExistence(timeout: 20))
        snap("chart-menu")
        app.buttons["Delete Chart"].firstMatch.tap()
        sleep(1)
        at(200, 320).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Fill Down"].waitForExistence(timeout: 20))
    }
}
