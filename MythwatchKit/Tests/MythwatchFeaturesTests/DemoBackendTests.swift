import Foundation
import MythwatchFeatures
import MythwatchTestSupport
import Testing

/// The fake app the UI tests launch (SPEC 7 "UI tests") must connect and fill every shelf.
@MainActor
@Suite("DemoBackend")
struct DemoBackendTests {
    @Test func withABackendSavedItConnectsAndEveryShelfHasSomething() async throws {
        let app = DemoBackend.appModel(backendSaved: true)
        await app.connect()
        let session = try #require(app.session.value)
        #expect(session.adapterName == DemoBackend.adapterName)
        #expect(session.info.hostName == DemoBackend.hostName)
        let library = app.makeLibraryModel()
        await library.load()
        let value = try #require(library.library.value)
        #expect(value.continueWatching.count == 3)
        #expect(!value.recentlyRecorded.isEmpty)
        #expect(value.shows.count == 9)
        #expect(value.shows.contains { $0.kind == .movie })
    }

    @Test func withoutABackendSavedTheAppIsIdleAndDiscoveryOffersTheDemoBackend() async throws {
        let app = DemoBackend.appModel(backendSaved: false)
        await app.connect()
        #expect(app.session.isIdle)
        let onboarding = app.makeOnboardingModel()
        onboarding.startDiscovery()
        await waitUntil(onboarding) { !$0.discovered.isEmpty }
        #expect(onboarding.discovered.map(\.connection) == [DemoBackend.connection])
        onboarding.select(onboarding.discovered[0])
        await onboarding.connect()
        #expect(onboarding.connectState.value?.hostName == DemoBackend.hostName)
        #expect(app.session.value != nil)
        onboarding.stopDiscovery()
    }

    /// M4-3: the film resumes inside a commercial break, so the UI test can see a skip and undo
    /// it, and the demo engine knows each recording's length, so the scrubber can draw breaks.
    @Test func theFilmResumesInsideABreakAndTheEngineKnowsItsLength() async throws {
        let app = DemoBackend.appModel(backendSaved: true)
        await app.connect()
        let (film, resume) = try #require(DemoBackend.library().first { $0.0.title == "The Long Voyage" })
        let resumeAt = try #require(resume)
        let session = app.makePlaybackSession(film, start: .resume)
        await session.start()
        #expect(session.breaks.contains { $0.start <= resumeAt && resumeAt < $0.end })
        #expect(session.breaks.count > 1)
        #expect(session.engine.snapshot.duration == .seconds(7200))
        _ = await session.finish()
    }

    /// M5-1: a seek to the end ends playback, as a real engine does, so the UI test can skip to
    /// the end of a 30-minute episode and see the delete offer.
    @Test func seekingToTheEndEndsPlaybackAndTheOutcomeReachedTheEnd() async throws {
        let app = DemoBackend.appModel(backendSaved: true)
        await app.connect()
        let (episode, _) = try #require(DemoBackend.library().first { $0.0.title == "Garden Tales" })
        let session = app.makePlaybackSession(episode, start: .beginning)
        await session.start()
        session.seek(to: .seconds(1800))
        #expect(session.engine.snapshot.status == .ended)
        let outcome = await app.finishPlayback(session)
        #expect(outcome.reachedEnd)
    }

    // MARK: Scenarios for the M5-3 UI tests

    @Test func theEmptyScenarioConnectsToABackendWithNoRecordings() async throws {
        let app = DemoBackend.appModel(backendSaved: true, scenario: .emptyLibrary)
        await app.connect()
        let library = app.makeLibraryModel()
        await library.load()
        let value = try #require(library.library.value)
        #expect(value.shows.isEmpty)
        #expect(value.continueWatching.isEmpty)
    }

    @Test func theUnreachableScenarioFailsTheFirstConnectAndTheNextOneWorks() async throws {
        let app = DemoBackend.appModel(backendSaved: true, scenario: .unreachableAtLaunch)
        await app.connect()
        let message = try #require(app.session.message)
        #expect(message.title == UserMessage(.unreachable("")).title)
        #expect(message.canRetry)
        await app.connect()
        #expect(app.session.value != nil)
    }

    /// The outage begins when an episode page first fetches its positions: those fetches fail,
    /// and so does the next library fetch; after that the backend answers again.
    @Test func theOutageScenarioFailsAnEpisodePageAndTheNextRefreshThenRecovers() async throws {
        let app = DemoBackend.appModel(backendSaved: true, scenario: .outage)
        await app.connect()
        let library = app.makeLibraryModel()
        await library.load()
        #expect(library.library.value != nil)

        let (episode, resume) = try #require(DemoBackend.library().first { $0.1 != nil })
        let page = app.makeEpisodeDetailModel(episode)
        await page.load()
        #expect(page.canRetryLoad)
        await page.load()
        #expect(page.problem == nil)
        #expect(page.resumePosition == resume)

        await library.refresh()
        #expect(library.refreshProblem?.canRetry == true)
        #expect(library.library.value != nil)
        await library.refresh()
        #expect(library.refreshProblem == nil)
    }

    @Test func withoutAScenarioNothingFails() async throws {
        let app = DemoBackend.appModel(backendSaved: true)
        await app.connect()
        let library = app.makeLibraryModel()
        await library.load()
        let (episode, _) = try #require(DemoBackend.library().first { $0.1 != nil })
        let page = app.makeEpisodeDetailModel(episode)
        await page.load()
        #expect(page.problem == nil)
        await library.refresh()
        #expect(library.refreshProblem == nil)
    }
}
