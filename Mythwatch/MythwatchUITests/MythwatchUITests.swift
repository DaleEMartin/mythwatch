import XCTest

final class MythwatchUITests: XCTestCase {
    @MainActor
    func testLaunchShowsPlaceholder() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Mythwatch"].waitForExistence(timeout: 10))
    }
}
