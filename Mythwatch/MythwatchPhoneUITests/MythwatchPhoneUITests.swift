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
        // The iOS 26 dialog exposes each button twice (sheet and its popover form): take the first.
        let rerecord = app.buttons["delete.rerecord"].firstMatch
        XCTAssertTrue(rerecord.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["delete.noRerecord"].firstMatch.exists)
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
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.textFields["address.field"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["address.field"].value as? String, "demo-backend:6544")
        attachScreenshot("5-settings")
        let licences = app.buttons["settings.licences"]
        for _ in 0..<6 where !licences.isHittable { app.swipeUp() }
        licences.tap()
        XCTAssertTrue(app.scrollViews["licences.screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "GNU Lesser General Public License")).firstMatch.exists)
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
}
