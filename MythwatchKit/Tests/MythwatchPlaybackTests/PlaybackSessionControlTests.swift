import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionControlTests {
    // MARK: bookmark

    @Test func setBookmarkHereStoresTheCurrentPosition() async {
        let rig = SessionRig(bookmark: s(50))
        await rig.playing(at: s(1234))
        await rig.session.setBookmarkHere()
        #expect(rig.state.calls == [.setBookmark(s(1234), rig.id)])
        #expect(rig.store.bookmark(for: rig.id) == s(1234))
        #expect(rig.session.problem == nil)
    }

    @Test func setBookmarkHereUsesASeekTargetTheEngineHasNotReachedYet() async {
        let rig = SessionRig(automaticResponses: false)
        await rig.playing(at: s(100))
        rig.session.seek(to: s(2000))
        await rig.emit(.playing, at: ms(100_250))  // stale
        await rig.session.setBookmarkHere()
        #expect(rig.store.bookmark(for: rig.id) == s(2000))
    }

    @Test func aFailedBookmarkSetsProblemUntilOneSucceeds() async {
        let rig = SessionRig()
        await rig.playing(at: s(1234))
        rig.state.failNext(.rejected("DIAG"), on: .setBookmark)
        await rig.session.setBookmarkHere()
        #expect(rig.session.problem == "Couldn't set the bookmark.")
        #expect(rig.store.bookmark(for: rig.id) == nil)
        await rig.session.setBookmarkHere()
        #expect(rig.session.problem == nil)
        #expect(rig.store.bookmark(for: rig.id) == s(1234))
    }

    @Test func aProblemOfAnotherKindIsNotClearedByASuccess() async {
        let rig = SessionRig()
        await rig.playing(at: s(1234))
        rig.state.failNext(.rejected("DIAG"), on: .setBookmark)
        await rig.session.setBookmarkHere()
        await rig.pause()  // a successful position save
        await rig.settle()
        #expect(rig.storedResume == s(1234))
        #expect(rig.session.problem == "Couldn't set the bookmark.")
    }

    @Test func setBookmarkHereBeforeStartDoesNothing() async {
        let rig = SessionRig()
        await rig.session.setBookmarkHere()
        #expect(rig.state.calls.isEmpty)
    }

    // MARK: play / pause

    @Test(arguments: [
        (PlayerStatus.playing, [FakePlayerEngine.Call.pause]),
        (.paused, [.play]),
        (.loading, [.pause]),
        (.buffering, [.pause]),
        (.idle, []),
        (.failed("DIAG"), []),
        (.ended, []),
    ])
    func togglePlayPauseFollowsTheEnginesStatus(_ status: PlayerStatus, _ expected: [FakePlayerEngine.Call]) async {
        let rig = SessionRig(automaticResponses: false)
        await rig.start()
        await rig.emit(status, at: s(500))
        let before = rig.engine.calls.count
        rig.session.togglePlayPause()
        #expect(rig.engineCalls(after: before) == expected)
    }

    @Test func togglePlayPauseBeforeStartDoesNothing() {
        let rig = SessionRig()
        rig.session.togglePlayPause()
        #expect(rig.engine.calls.isEmpty)
    }

    @Test func pausingThroughTheSessionSavesWhenTheEngineReportsIt() async {
        let rig = SessionRig()
        await rig.playing(at: s(700))
        rig.session.togglePlayPause()
        await rig.engine.waitUntilDelivered()
        await rig.settle()
        #expect(rig.resumeWrites == [s(700)])
    }

    // MARK: engine failure

    @Test func anEngineFailureSurfacesAndKeepsTheViewersPlace() async {
        let rig = SessionRig()
        await rig.playing(at: s(500))
        let before = rig.engine.calls.count
        // A real engine may report a reset position with the failure.
        await rig.emit(.failed("stream dropped"), at: .zero)
        await rig.settle()
        #expect(rig.session.snapshot.status == .failed("stream dropped"))
        #expect(rig.resumeWrites == [s(500)])
        #expect(rig.engineCalls(after: before).isEmpty)  // no automatic retry
    }

    @Test func finishAfterAFailureReportsTheLastGoodPosition() async {
        let rig = SessionRig()
        await rig.playing(at: s(500))
        await rig.emit(.failed("stream dropped"), at: .zero)
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(500), reachedEnd: false, markedWatched: false))
        #expect(rig.resumeWrites == [s(500)])
        #expect(rig.storedResume == s(500))
        #expect(rig.engine.calls.last == .stop)
    }

    // MARK: lifetime

    @Test func aSessionDroppedWithoutFinishIsReleasedAndItsLoopEnds() async throws {
        let engine = FakePlayerEngine()
        let store = FakeBackendStore()
        let recording = Recording.fixture(id: sessionRecordingID)
        store.add(recording)
        let clock = TestClock()
        weak var weakSession: PlaybackSession?
        var loop: Task<Void, Never>?
        do {
            let session = PlaybackSession(
                recording: recording, start: .beginning, engine: engine,
                state: FakePlaybackStateService(store: store), markup: FakeMarkupService(store: store),
                recordings: FakeRecordingsService(store: store), media: FakeMediaLocator(),
                settings: PlaybackSettings(), now: clock.now)
            await session.start()
            await engine.waitUntilDelivered()
            loop = session.snapshotLoop
            weakSession = session
        }
        #expect(weakSession == nil)
        // deinit cancelled the loop (checked first, so a loop that was not cancelled fails here
        // instead of hanging the await below).
        let cancelled = try #require(loop).isCancelled
        try #require(cancelled)
        engine.setPosition(s(100))
        engine.finish()
        await loop?.value  // it has ended
    }
}
