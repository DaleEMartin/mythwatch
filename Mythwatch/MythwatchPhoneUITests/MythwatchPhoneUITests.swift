import XCTest

/// UI tests for the iPhone app, against the in-app fakes (`-MythwatchFakes`, SPEC 7 "UI tests").
final class MythwatchPhoneUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(backendSaved: Bool = true, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MythwatchFakes"] + (backendSaved ? ["-MythwatchFakesBackendSaved"] : []) + extra
        app.launch()
        return app
    }

    func testLaunchConnectsToTheFakeBackend() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["phone.connected"].waitForExistence(timeout: 10))
    }
}
