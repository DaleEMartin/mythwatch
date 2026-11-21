import XCTest

/// UI tests for the iPhone app, against the in-app fakes (`-MythwatchFakes`, SPEC 7 "UI tests";
/// SPEC 11). The demo data is `DemoBackend`'s: "Garden Tales" is a show with several episodes.
final class MythwatchPhoneUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @discardableResult
    private func launch(backendSaved: Bool = true, _ extra: [String] = []) -> XCUIApplication {
        app = XCUIApplication()
        app.launchArguments = ["-MythwatchFakes"] + (backendSaved ? ["-MythwatchFakesBackendSaved"] : []) + extra
        app.launch()
        return app
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scrolls the library until `element` is on screen.
    private func scrollTo(_ element: XCUIElement, in scroll: XCUIElement, limit: Int = 8) {
        for _ in 0..<limit where !(element.exists && element.isHittable) { scroll.swipeUp() }
    }

    /// Library → Garden Tales → its first episode. Returns the episode's title.
    @discardableResult
    private func openGardenEpisode() -> String {
        let library = app.scrollViews["library.screen"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        let garden = app.buttons["show.series:DEMO-GARDEN"]
        scrollTo(garden, in: library)
        garden.tap()
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["show.title"].label, "Garden Tales")
        let episode = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode.'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        episode.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        return app.staticTexts["detail.title"].label
    }

    func testOnboardingConnectsAndShowsTheLibrary() {
        launch(backendSaved: false)
        XCTAssertTrue(app.otherElements["onboarding.screen"].waitForExistence(timeout: 10))
        attachScreenshot("1-onboarding")
        app.buttons["onboarding.discovered.demo-backend"].tap()
        let field = app.textFields["address.field"]
        let filled = expectation(for: NSPredicate(format: "value == %@", "demo-backend:6544"), evaluatedWith: field)
        wait(for: [filled], timeout: 5)
        app.buttons["onboarding.connect"].tap()
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["onboarding.screen"].exists)
    }

    func testTheLibraryHasBothShelvesAndTheShows() {
        launch()
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card.continueWatching.'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card.recentlyRecorded.'")).firstMatch.exists)
        attachScreenshot("2-library")
        let show = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'show.'")).firstMatch
        scrollTo(show, in: app.scrollViews["library.screen"])
        XCTAssertTrue(show.isHittable)
    }

    func testOpenAShowThenAnEpisodeThenGoBack() {
        launch()
        openGardenEpisode()
        XCTAssertTrue(app.buttons["detail.start.beginning"].exists)
        XCTAssertTrue(app.buttons["detail.delete"].exists)
        attachScreenshot("3-episode")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 5))
    }

    func testDeleteOnTheEpisodePageOffersBothRerecordChoices() {
        launch()
        let title = openGardenEpisode()
        app.buttons["detail.delete"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        // iOS 26 lists each alert button twice in the accessibility tree: take the first.
        let rerecord = alert.buttons["Delete and Let MythTV Record It Again"].firstMatch
        XCTAssertTrue(rerecord.exists)
        XCTAssertTrue(alert.buttons["Delete"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        attachScreenshot("4-delete-dialog")
        rerecord.tap()
        XCTAssertTrue(app.staticTexts["show.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["detail.title"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists,
                       "the deleted episode is gone from the show page")
    }

    func testSettingsShowsTheConnectedBackendAndTheLicences() {
        launch()
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        // iPhone: the tab bar at the bottom. iPad: the tabs at the top, not reported as a tab bar.
        let tab = app.tabBars.buttons["Settings"]
        (tab.exists ? tab : app.buttons["Settings"].firstMatch).tap()
        XCTAssertTrue(app.textFields["address.field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["address.field"].value as? String, "demo-backend:6544")
        attachScreenshot("5-settings")
        let licences = app.buttons["settings.licences"]
        for _ in 0..<6 where !licences.isHittable { app.swipeUp() }
        licences.tap()
        XCTAssertTrue(app.scrollViews["licences.screen"].waitForExistence(timeout: 5))
        func shows(_ text: String) -> Bool {
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
        }
        XCTAssertTrue(shows("MobileVLCKit 3.7.4"))
        XCTAssertTrue(shows("GNU Lesser General Public License"))
        let notices = app.scrollViews["licences.screen"]
        for _ in 0..<6 where !shows("libzvbi is left out") { notices.swipeUp() }
        XCTAssertTrue(shows("libzvbi is left out"), "M6-6: the iPhone build leaves zvbi out too")
    }

    func testAnEmptyLibrarySaysSo() {
        launch(["-MythwatchFakesEmpty"])
        XCTAssertTrue(app.otherElements["library.empty"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No Recordings Yet"].exists)
    }

    func testUnreachableAtLaunchShowsTryAgainWhichRecovers() {
        launch(["-MythwatchFakesUnreachable"])
        XCTAssertTrue(app.otherElements["message.screen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Can't Reach Your MythTV Backend"].exists)
        attachScreenshot("6-unreachable")
        app.buttons["message.retry"].tap()
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["message.screen"].exists)
    }

    // MARK: Player (M6-4)

    /// From the episode page to the player and back. Skip forward moves 30 s; playing with no
    /// input hides the controls after 5 s, and a tap on the picture brings them back.
    func testPlayFromTheEpisodePageThenClose() {
        launch()
        let title = openGardenEpisode()
        app.buttons["detail.start.beginning"].tap()
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 5))
        let transport = app.otherElements["player.transport"]
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["player.elapsed"].label, "0:00")
        app.buttons["player.skipForward"].tap()
        let skipped = expectation(for: NSPredicate(format: "label == %@", "0:30"), evaluatedWith: app.staticTexts["player.elapsed"])
        wait(for: [skipped], timeout: 5)
        attachScreenshot("7-player")

        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: transport)
        wait(for: [hidden], timeout: 10)
        app.otherElements["player.surface"].tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 3))

        app.buttons["player.close"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detail.title"].label, title)
        XCTAssertFalse(app.otherElements["player.screen"].exists)
    }

    /// M4-3 on the phone: the demo film resumes inside a break, the skip happens at once, and
    /// Go Back returns to 2 s before where it was.
    func testResumingIntoABreakSkipsItAndGoBackReturns() {
        launch()
        XCTAssertTrue(app.scrollViews["library.screen"].waitForExistence(timeout: 10))
        app.buttons["card.continueWatching.113"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
        app.buttons["detail.start.resume"].tap()

        let goBack = app.buttons["player.banner.goBack"]
        XCTAssertTrue(goBack.waitForExistence(timeout: 5), "the skipped banner shows")
        XCTAssertEqual(app.staticTexts["player.elapsed"].label, "1:02:59")
        XCTAssertEqual(app.staticTexts["player.banner.skippedText"].label, "Skipped commercials \u{00B7} 0:56")
        attachScreenshot("8-player-skipped")
        goBack.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: goBack)
        wait(for: [gone], timeout: 3)
        XCTAssertEqual(app.staticTexts["player.elapsed"].label, "1:02:01")
    }

    /// The tracks and info sheet: Set Bookmark Here is in it, and Done closes it.
    func testTheInfoSheetHasTheBookmarkButton() {
        launch()
        openGardenEpisode()
        app.buttons["detail.start.beginning"].tap()
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 5))
        app.buttons["player.more"].tap()
        XCTAssertTrue(app.buttons["player.bookmark"].waitForExistence(timeout: 5))
        attachScreenshot("9-player-sheet")
        app.buttons["player.panel.done"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["player.bookmark"])
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.otherElements["player.screen"].exists)
    }

    /// M5-1 on the phone: playing to the end closes the player and offers a delete; Keep leaves
    /// the recording alone.
    func testWatchingToTheEndOffersADelete() {
        launch()
        openGardenEpisode()
        app.buttons["detail.start.beginning"].tap()
        let player = app.otherElements["player.screen"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        let skip = app.buttons["player.skipForward"]
        // 30-minute episode, 30 s skips: at most 60 taps reach the end.
        for _ in 0..<70 where player.exists && skip.exists { skip.tap() }
        let keep = app.alerts.buttons["Keep"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "the delete offer shows after the end")
        XCTAssertTrue(app.alerts.buttons["Delete and Let MythTV Record It Again"].exists)
        attachScreenshot("10-finished-offer")
        keep.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: keep)
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.staticTexts["detail.title"].exists, "Keep leaves the episode page up")
    }

    /// The player turns with the phone, and its controls still work in landscape.
    func testThePlayerWorksInLandscape() {
        launch()
        openGardenEpisode()
        app.buttons["detail.start.beginning"].tap()
        XCTAssertTrue(app.otherElements["player.screen"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let skip = app.buttons["player.skipForward"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        skip.tap()
        let skipped = expectation(for: NSPredicate(format: "label == %@", "0:30"), evaluatedWith: app.staticTexts["player.elapsed"])
        wait(for: [skipped], timeout: 5)
        XCTAssertTrue(app.buttons["player.close"].isHittable)
        attachScreenshot("11-player-landscape")
        app.buttons["player.close"].tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 5))
    }
}
