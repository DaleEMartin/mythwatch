import XCTest

/// UI tests over the fakes (SPEC 7 "UI tests"): the app is launched with `-MythwatchFakes`, so it
/// runs on `DemoBackend` from `MythwatchTestSupport` and sends nothing to any network backend.
@MainActor
final class MythwatchUITests: XCTestCase {
    private let app = XCUIApplication()
    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(backendSaved: Bool) {
        continueAfterFailure = false
        app.launchArguments = ["-MythwatchFakes"] + (backendSaved ? ["-MythwatchFakesBackendSaved"] : [])
        app.launch()
    }

    // MARK: Tests

    @MainActor
    func testOnboardingConnectsAndShowsTheLibrary() {
        launch(backendSaved: false)
        XCTAssertTrue(app.otherElements["onboarding.screen"].waitForExistence(timeout: 10))
        attachScreenshot("1-onboarding")

        // Choosing the discovered backend fills in its address.
        press(.up, until: app.buttons["onboarding.discovered.demo-backend"])
        remote.press(.select)
        let field = app.textFields["address.field"]
        let filled = expectation(for: NSPredicate(format: "value == %@", "demo-backend:6544"), evaluatedWith: field)
        wait(for: [filled], timeout: 5)

        press(.down, untilFocusedPrefix: "address.test")
        press(.right, until: app.buttons["onboarding.connect"])
        remote.press(.select)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["onboarding.screen"].exists)
    }

    @MainActor
    func testFocusMovesFromTheShelvesToTheShowsGrid() {
        launch(backendSaved: true)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        attachScreenshot("2-library")

        remote.press(.down)
        XCTAssertTrue(waitForFocus(prefix: "card.continueWatching."))
        remote.press(.down)
        XCTAssertTrue(waitForFocus(prefix: "card.recentlyRecorded."))
        remote.press(.down)
        XCTAssertTrue(waitForFocus(prefix: "show."))
        attachScreenshot("3-library-grid")
    }

    @MainActor
    func testOpenAShowThenAnEpisodeThenGoBack() {
        launch(backendSaved: true)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))

        press(.down, untilFocusedPrefix: "show.")
        // Focus enters the grid in whichever column is below the card it left: look both ways.
        let garden = app.buttons["show.series:DEMO-GARDEN"]
        for _ in 0..<6 where !garden.hasFocus { remote.press(.left) }
        press(.right, until: garden, limit: 8)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["show.title"].label, "Garden Tales")

        // Into the episode list, then the first episode of the selected season.
        remote.press(.down)
        XCTAssertTrue(waitForFocus(prefix: "episode."))
        attachScreenshot("4-show")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["detail.start.beginning"].exists)
        XCTAssertTrue(app.buttons["detail.delete"].exists)
        attachScreenshot("5-episode")

        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detail.title"].exists)
        remote.press(.menu)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["show.title"].exists)
    }

    @MainActor
    func testPlayFromTheEpisodePageThenLeave() {
        launch(backendSaved: true)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        press(.down, untilFocusedPrefix: "card.continueWatching.")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        let title = app.staticTexts["detail.title"].label
        press(.down, untilFocusedPrefix: "detail.start.")
        press(.right, until: app.buttons["detail.start.beginning"], limit: 4)
        remote.press(.select)

        // The player: the remote's input view has focus, and the transport bar is up.
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFocus(prefix: "player.input"))
        let transport = app.otherElements["player.transport"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["player.elapsed"].label, "0:00")
        attachScreenshot("7-player")

        // Playing with no input, the bar hides after 5 s; pausing brings it back.
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: transport)
        wait(for: [hidden], timeout: 10)
        remote.press(.playPause)
        XCTAssertTrue(transport.waitForExistence(timeout: 3))
        sleep(6)
        XCTAssertTrue(transport.exists, "the bar stays while paused")

        // Menu leaves the player for the episode page it came from.
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.title"].label, title)
        XCTAssertFalse(app.otherElements["player.screen"].exists)
    }

    @MainActor
    func testSettingsShowsTheConnectedBackend() {
        launch(backendSaved: true)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        remote.press(.right)  // the tab bar has focus at launch
        XCTAssertTrue(app.textFields["address.field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["address.field"].value as? String, "demo-backend:6544")
        attachScreenshot("6-settings")
    }

    /// Screenshots against a real backend whose address is already saved in the app's settings.
    /// Skipped unless the runner's environment has `MYTHWATCH_LIVE_UI` (pass
    /// `TEST_RUNNER_MYTHWATCH_LIVE_UI=1` to xcodebuild). Read-only: it moves focus, opens pages
    /// and goes back; it never opens a context menu or presses Delete.
    @MainActor
    func testLiveWalkthroughTakesScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYTHWATCH_LIVE_UI"] != nil)
        continueAfterFailure = false
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 20))
        attachScreenshot("live-1-library")

        press(.down, untilFocusedPrefix: "card.")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 10))
        sleep(2)  // let the positions and the image arrive
        attachScreenshot("live-2-episode")
        remote.press(.menu)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 5))

        press(.down, untilFocusedPrefix: "show.")
        sleep(2)
        attachScreenshot("live-3-grid")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 10))
        sleep(2)
        attachScreenshot("live-4-show")
        remote.press(.menu)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 5))
    }

    // MARK: Focus helpers

    private func waitForFocus(prefix: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", prefix)
        return app.descendants(matching: .any).element(matching: predicate).waitForExistence(timeout: timeout)
    }

    /// Presses `direction` until `target` has focus, at most `limit` times.
    private func press(
        _ direction: XCUIRemote.Button, until target: XCUIElement, limit: Int = 12,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<limit {
            if target.exists && target.hasFocus { return }
            remote.press(direction)
        }
        XCTAssertTrue(target.exists && target.hasFocus, "could not focus \(target)", file: file, line: line)
    }

    /// Presses `direction` until an element whose identifier starts with `prefix` has focus.
    private func press(
        _ direction: XCUIRemote.Button, untilFocusedPrefix prefix: String, limit: Int = 12,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<limit {
            if waitForFocus(prefix: prefix, timeout: 0.5) { return }
            remote.press(direction)
        }
        XCTAssertTrue(waitForFocus(prefix: prefix), "nothing focused with prefix \(prefix)", file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
