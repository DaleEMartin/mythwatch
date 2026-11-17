import XCTest

/// UI tests over the fakes (SPEC 7 "UI tests"): the app is launched with `-MythwatchFakes`, so it
/// runs on `DemoBackend` from `MythwatchTestSupport` and sends nothing to any network backend.
@MainActor
final class MythwatchUITests: XCTestCase {
    private let app = XCUIApplication()
    private var remote: XCUIRemote { XCUIRemote.shared }

    private func launch(backendSaved: Bool, extra: [String] = []) {
        continueAfterFailure = false
        app.launchArguments = ["-MythwatchFakes"] + (backendSaved ? ["-MythwatchFakesBackendSaved"] : []) + extra
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

    /// M4-3: the demo film resumes at 1:02:03 inside a break (1:00:00 to 1:03:00), so the skip
    /// happens at once and the banner shows; Select goes back to 2 s before where it was.
    @MainActor
    func testResumingIntoABreakSkipsItAndGoBackReturns() {
        launch(backendSaved: true)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        press(.down, untilFocusedPrefix: "card.continueWatching.")
        // Focus enters the shelf below wherever it was: start from the left end.
        for _ in 0..<3 { remote.press(.left) }
        press(.right, untilFocusedPrefix: "card.continueWatching.113", limit: 4)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        press(.down, untilFocusedPrefix: "detail.start.")
        press(.left, until: app.buttons["detail.start.resume"], limit: 4)
        remote.press(.select)

        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 5))
        let goBack = app.descendants(matching: .any)["player.banner.goBack"]
        XCTAssertTrue(goBack.waitForExistence(timeout: 5), "the skipped banner shows")
        XCTAssertEqual(app.staticTexts["player.elapsed"].label, "1:02:59")
        XCTAssertEqual(app.staticTexts["player.banner.skippedText"].label, "Skipped commercials \u{00B7} 0:56")
        attachScreenshot("8-player-skipped")

        remote.press(.select)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: goBack)
        wait(for: [gone], timeout: 3)
        XCTAssertEqual(app.staticTexts["player.elapsed"].label, "1:02:01")
        attachScreenshot("9-player-went-back")

        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
    }

    /// M5-1: Delete always asks, offering both re-record choices (owner, 2026-11-15/16). On the
    /// fakes the delete succeeds and the page closes back to the show, without that episode.
    @MainActor
    func testDeleteOnTheEpisodePageOffersBothRerecordChoices() {
        launch(backendSaved: true)
        let title = openGardenEpisode()
        press(.down, untilFocusedPrefix: "detail.start.")
        press(.right, until: app.buttons["detail.delete"], limit: 4)
        remote.press(.select)

        XCTAssertTrue(dialogButton("Delete and Let MythTV Record It Again").waitForExistence(timeout: 5))
        XCTAssertTrue(dialogButton("Delete").exists)
        XCTAssertTrue(dialogButton("Cancel").exists)
        attachScreenshot("10-delete-dialog")
        // Focus starts on Cancel, at the bottom.
        press(.up, untilFocusedLabel: "Delete and Let MythTV Record It Again")
        remote.press(.select)

        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detail.title"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists,
                       "the deleted episode is gone from the show page")
    }

    /// M5-1: playing to the end (skipping forward until the demo engine ends) returns to the
    /// episode page with an offer to delete; Keep leaves the recording alone.
    @MainActor
    func testWatchingToTheEndOffersADelete() {
        launch(backendSaved: true)
        _ = openGardenEpisode()
        press(.down, untilFocusedPrefix: "detail.start.")
        press(.right, until: app.buttons["detail.start.beginning"], limit: 4)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 5))

        // 30-minute episode, 30 s skips: at most 60 presses reach the end.
        let player = app.otherElements["player.screen"]
        for _ in 0..<70 where player.exists { remote.press(.right) }

        let keep = dialogButton("Keep")
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "the delete offer shows after the end")
        XCTAssertTrue(dialogButton("Delete and Let MythTV Record It Again").exists)
        attachScreenshot("11-finished-offer")
        press(.down, untilFocusedLabel: "Keep")  // already focused: Keep is the cancel button
        remote.press(.select)

        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keep)
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.staticTexts["detail.title"].exists, "Keep leaves the episode page up")
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

    // MARK: States and resilience (M5-3)

    @MainActor
    func testAnEmptyLibrarySaysSo() {
        launch(backendSaved: true, extra: ["-MythwatchFakesEmpty"])
        XCTAssertTrue(app.otherElements["library.empty"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Recordings Yet"].exists)
        attachScreenshot("12-empty-library")
    }

    /// Acceptance item 9 on the fakes: the backend is off at launch, Try Again recovers.
    @MainActor
    func testUnreachableAtLaunchShowsTryAgainWhichRecovers() {
        launch(backendSaved: true, extra: ["-MythwatchFakesUnreachable"])
        XCTAssertTrue(app.otherElements["message.screen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Can't Reach Your MythTV Backend"].exists)
        attachScreenshot("13-unreachable")
        let retry = app.buttons["message.retry"]
        press(.down, until: retry, limit: 4)
        remote.press(.select)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["message.screen"].exists)
    }

    /// The backend drops while the viewer is on an episode page, and again for the library's
    /// refresh after playback. Each problem shows as a banner with Try Again, which recovers
    /// without leaving the page.
    @MainActor
    func testALostBackendIsRetriedWithoutLeavingThePage() {
        launch(backendSaved: true, extra: ["-MythwatchFakesOutage"])
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        // Garden Tales S2 E1 (105) has a resume position.
        press(.down, untilFocusedPrefix: "card.continueWatching.")
        for _ in 0..<3 { remote.press(.left) }
        press(.right, untilFocusedPrefix: "card.continueWatching.105", limit: 4)
        remote.press(.select)

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let episodeTitle = title.label
        let pageRetry = app.buttons["message.banner.retry"]
        XCTAssertTrue(pageRetry.waitForExistence(timeout: 5), "the failed load shows a banner with Try Again")
        XCTAssertFalse(app.buttons["detail.start.resume"].exists)
        attachScreenshot("14-episode-outage")
        press(.up, until: pageRetry, limit: 4)
        remote.press(.select)
        XCTAssertTrue(app.buttons["detail.start.resume"].waitForExistence(timeout: 5), "the retry found the position")
        XCTAssertFalse(app.otherElements["message.banner"].exists)
        XCTAssertEqual(title.label, episodeTitle, "still on the same page")

        // Play and leave: the library's reload after playback fails, and the library keeps its content.
        press(.down, untilFocusedPrefix: "detail.start.")
        press(.right, until: app.buttons["detail.start.beginning"], limit: 4)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 5))
        let libraryRetry = app.buttons["message.banner.retry"]
        XCTAssertTrue(libraryRetry.waitForExistence(timeout: 5), "the failed refresh shows a banner with Try Again")
        XCTAssertTrue(app.descendants(matching: .any)["shelf.continueWatching"].exists, "the library stays")
        attachScreenshot("15-library-outage")
        press(.up, until: libraryRetry, limit: 6)
        remote.press(.select)
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.otherElements["message.banner"])
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.scrollViews["library.screen"].exists)
    }

    /// VoiceOver reads one plain label per card, poster and episode row.
    @MainActor
    func testVoiceOverLabelsDescribeCardsPostersAndRows() {
        launch(backendSaved: true)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["card.continueWatching.105"].label,
                       "Garden Tales, Autumn Harvest 1, Season 2, Episode 1, Part watched")
        XCTAssertEqual(app.buttons["card.continueWatching.113"].label, "The Long Voyage, 2 hours, Part watched")

        // The grid is lazy: its posters exist once focus has scrolled to them.
        press(.down, untilFocusedPrefix: "show.")
        let garden = app.buttons["show.series:DEMO-GARDEN"]
        for _ in 0..<6 where !garden.hasFocus { remote.press(.left) }
        press(.right, until: garden, limit: 8)
        XCTAssertEqual(garden.label, "Garden Tales, 7 episodes, 5 unwatched")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        let row = app.buttons["episode.101"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Spring Planting 1, Season 1, Episode 1, First aired "), row.label)
        XCTAssertTrue(row.label.hasSuffix(", 30 minutes, Watched"), row.label)
    }

    /// Large text: every screen at the largest accessibility text size, for screenshots. The
    /// screens must still be reachable and their controls present.
    @MainActor
    func testEveryScreenAtTheLargestTextSize() {
        launch(backendSaved: true, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        attachScreenshot("large-1-library")
        press(.down, untilFocusedPrefix: "show.")
        attachScreenshot("large-2-grid")
        _ = openGardenEpisode()
        XCTAssertTrue(app.buttons["detail.start.beginning"].exists)
        XCTAssertTrue(app.buttons["detail.delete"].exists)
        attachScreenshot("large-4-episode")
        press(.down, untilFocusedPrefix: "detail.start.")
        press(.right, until: app.buttons["detail.start.beginning"], limit: 4)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["player.transport"].waitForExistence(timeout: 5))
        remote.press(.playPause)
        attachScreenshot("large-5-player")
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        attachScreenshot("large-3-show")
        remote.press(.menu)
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 5))
        for _ in 0..<8 { remote.press(.up) }
        remote.press(.right)
        XCTAssertTrue(app.textFields["address.field"].waitForExistence(timeout: 5))
        attachScreenshot("large-6-settings")
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

    /// A confirmation dialog's button by its label. tvOS shows the dialog as a sheet and lists
    /// each of its buttons twice (an outer one that takes focus, and ours inside it).
    private func dialogButton(_ label: String) -> XCUIElement {
        app.sheets.firstMatch.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Presses `direction` until a button labelled `label` has focus.
    private func press(
        _ direction: XCUIRemote.Button, untilFocusedLabel label: String, limit: Int = 6,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let focused = app.sheets.firstMatch.buttons
            .matching(NSPredicate(format: "label == %@ AND hasFocus == true", label)).firstMatch
        for _ in 0..<limit {
            if focused.exists { return }
            remote.press(direction)
        }
        XCTAssertTrue(focused.exists, "could not focus \(label)", file: file, line: line)
    }

    /// From the library, opens Garden Tales and the first episode of its selected season.
    /// Returns the episode's title as the page shows it.
    private func openGardenEpisode() -> String {
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        press(.down, untilFocusedPrefix: "show.")
        let garden = app.buttons["show.series:DEMO-GARDEN"]
        for _ in 0..<6 where !garden.hasFocus { remote.press(.left) }
        press(.right, until: garden, limit: 8)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        remote.press(.down)
        XCTAssertTrue(waitForFocus(prefix: "episode."))
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        return app.staticTexts["detail.title"].label
    }

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
