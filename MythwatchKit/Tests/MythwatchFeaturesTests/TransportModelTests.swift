import Foundation
import Observation
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Synchronization
import Testing

/// Set from an observation's `onChange`, which may run on any thread.
private final class ChangeFlag: Sendable {
    private let state = Mutex(false)
    func set() { state.withLock { $0 = true } }
    var value: Bool { state.withLock { $0 } }
}

/// A `TransportModel` over a real `PlaybackSession` on the fakes. Time moves only through
/// `clock`; the engine only through the fake's emitters, each followed by `waitUntilDelivered()`.
@MainActor private final class TransportRig {
    let recording = Recording.fixture(id: RecordingID(rawValue: 7), title: "Garden Tales")
    let store = FakeBackendStore()
    let state: FakePlaybackStateService
    let engine = FakePlayerEngine()
    let clock = TestClock()
    let session: PlaybackSession
    let model: TransportModel

    init(resume: Duration? = nil) {
        store.add(recording, resumePosition: resume)
        state = FakePlaybackStateService(store: store)
        session = PlaybackSession(
            recording: recording, start: .beginning, engine: engine, state: state,
            markup: FakeMarkupService(store: store), recordings: FakeRecordingsService(store: store),
            media: FakeMediaLocator(), settings: PlaybackSettings(), now: clock.now)
        model = TransportModel(session: session, recording: recording, now: clock.now)
    }

    /// Started, then playing at `position`, with `tick()` called as the screen does on a change.
    func playing(at position: Duration, duration: Duration? = .seconds(3600)) async {
        await session.start()
        await engine.waitUntilDelivered()
        await emit(.playing, at: position, duration: duration)
    }

    func emit(_ status: PlayerStatus, at position: Duration, duration: Duration?? = nil) async {
        var s = engine.snapshot
        s.status = status
        s.position = position
        if let duration { s.duration = duration }
        s.rate = status == .playing ? 1 : 0
        engine.emit(s)
        await engine.waitUntilDelivered()
        model.tick()
    }

    /// Paused at `position` (through the model, as the viewer would).
    func paused(at position: Duration) async {
        await playing(at: position)
        model.playPause()
        await engine.waitUntilDelivered()
        model.tick()
    }

    func advance(_ d: Duration) {
        clock.advance(by: d)
        model.tick()
    }

    var seeks: [Duration] { engine.calls.compactMap { if case .seek(let to) = $0 { to } else { nil } } }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct TransportModelTests {
    // MARK: Auto-hide

    @Test func controlsHideFiveSecondsAfterPlayingStartsWithNoInput() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(10))
        #expect(rig.model.controlsVisible)
        #expect(rig.model.hideAt == rig.clock.now() + .seconds(5))
        rig.advance(.milliseconds(4900))
        #expect(rig.model.controlsVisible)
        rig.advance(.milliseconds(100))
        #expect(!rig.model.controlsVisible)
        #expect(rig.model.hideAt == nil)
    }

    @Test func timeSpentLoadingDoesNotCountTowardsHiding() async {
        let rig = TransportRig()
        await rig.session.start()  // the fake reports loading, then playing at once
        await rig.emit(.loading, at: .zero)
        rig.advance(.seconds(20))
        #expect(rig.model.controlsVisible)
        #expect(rig.model.hideAt == nil)
        await rig.emit(.playing, at: .seconds(1), duration: .seconds(3600))
        rig.advance(.seconds(4))
        #expect(rig.model.controlsVisible)
        rig.advance(.seconds(1))
        #expect(!rig.model.controlsVisible)
    }

    @Test func anyInputShowsTheControlsAndRestartsTheWait() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        rig.advance(.seconds(6))
        #expect(!rig.model.controlsVisible)

        rig.model.showControls()
        #expect(rig.model.controlsVisible)
        rig.advance(.seconds(3))
        rig.model.skipForward()  // an input: the wait starts again
        rig.advance(.seconds(4))
        #expect(rig.model.controlsVisible)
        rig.advance(.seconds(1))
        #expect(!rig.model.controlsVisible)
    }

    @Test func controlsStayWhilePaused() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(100))
        #expect(rig.model.hideAt == nil)
        rig.advance(.seconds(60))
        #expect(rig.model.controlsVisible)
    }

    @Test func aPauseFromElsewhereShowsHiddenControls() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        rig.advance(.seconds(6))
        #expect(!rig.model.controlsVisible)
        await rig.emit(.paused, at: .seconds(106))
        #expect(rig.model.controlsVisible)
    }

    @Test func controlsStayWhileThePanelIsOpenAndTheWaitRestartsWhenItCloses() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        rig.model.openPanel()
        rig.advance(.seconds(30))
        #expect(rig.model.hideAt == nil)
        #expect(rig.model.panel == .info)
        rig.model.closePanel()
        #expect(rig.model.hideAt == rig.clock.now() + .seconds(5))
    }

    // MARK: Scrubbing

    @Test func aSwipeWhilePlayingOnlyShowsTheControls() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        rig.advance(.seconds(6))
        rig.model.scrub(by: 0.5)
        #expect(rig.model.controlsVisible)
        #expect(rig.model.scrubPosition == nil)
        #expect(rig.seeks.isEmpty)
    }

    @Test func scrubbingWhilePausedPreviewsWithoutSeeking() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.1)  // a full swipe is a fifth of the hour: 720 s; a tenth of a swipe 72 s
        #expect(rig.model.scrubPosition == .seconds(672))
        #expect(rig.model.position == .seconds(672))
        #expect(rig.model.elapsedText == "11:12")
        rig.model.scrub(by: -0.05)
        #expect(rig.model.scrubPosition == .seconds(636))
        #expect(rig.seeks.isEmpty)
    }

    @Test func committingSeeksToThePreviewAndEndsTheScrub() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.model.commitScrub()
        #expect(rig.seeks == [.seconds(780)])
        #expect(rig.model.scrubPosition == nil)
        #expect(rig.engine.snapshot.status == .paused)  // committing does not play
    }

    @Test func cancellingLeavesThePositionAlone() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.model.cancelScrub()
        #expect(rig.model.scrubPosition == nil)
        #expect(rig.model.position == .seconds(600))
        #expect(rig.seeks.isEmpty)
    }

    // MARK: Scrub frame preview (owner, 2026-11-16)

    @Test func aScrubThatRestsShowsThatFrameAfterTheDelay() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)  // 780 s
        #expect(rig.model.scrubPreviewAt == rig.clock.now() + .milliseconds(400))
        rig.advance(.milliseconds(399))
        #expect(rig.seeks.isEmpty)
        rig.advance(.milliseconds(1))
        #expect(rig.seeks == [.seconds(780)])
        #expect(rig.model.scrubPosition == .seconds(780))  // still scrubbing
        #expect(rig.model.scrubPreviewAt == nil)
        rig.advance(.seconds(5))
        #expect(rig.seeks == [.seconds(780)])  // once per resting place
        #expect(rig.engine.snapshot.status == .paused)
    }

    @Test func movingAgainRestartsTheWaitAndPreviewsTheNewPlace() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.advance(.milliseconds(300))
        rig.model.scrub(by: 0.25)  // 960 s
        #expect(rig.model.scrubPreviewAt == rig.clock.now() + .milliseconds(400))
        rig.advance(.milliseconds(300))
        #expect(rig.seeks.isEmpty)
        rig.advance(.milliseconds(100))
        #expect(rig.seeks == [.seconds(960)])
        rig.model.scrub(by: -0.25)  // 780 s
        rig.advance(.milliseconds(400))
        #expect(rig.seeks == [.seconds(960), .seconds(780)])
    }

    @Test func noPreviewIsDueWhenNotScrubbing() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        #expect(rig.model.scrubPreviewAt == nil)
        rig.model.scrub(by: 0.25)
        rig.model.commitScrub()
        #expect(rig.model.scrubPreviewAt == nil)
    }

    @Test func cancellingAfterAPreviewPutsTheVideoBack() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.advance(.milliseconds(400))
        rig.model.cancelScrub()
        #expect(rig.seeks == [.seconds(780), .seconds(600)])
        #expect(rig.model.scrubPosition == nil)
    }

    @Test func backAfterAPreviewPutsTheVideoBack() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.advance(.milliseconds(400))
        #expect(rig.model.back() == .handled)
        #expect(rig.seeks == [.seconds(780), .seconds(600)])
    }

    @Test func openingThePanelAfterAPreviewPutsTheVideoBack() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.advance(.milliseconds(400))
        rig.model.openPanel()
        #expect(rig.seeks == [.seconds(780), .seconds(600)])
    }

    @Test func committingAfterAPreviewStaysThere() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.advance(.milliseconds(400))
        rig.model.select()
        #expect(rig.seeks.last == .seconds(780))
        #expect(!rig.seeks.contains(.seconds(600)))
        #expect(rig.model.scrubPosition == nil)
    }

    @Test func theScrubStaysWithinTheRecording() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: -5)
        #expect(rig.model.scrubPosition == .zero)
        rig.model.scrub(by: 50)
        #expect(rig.model.scrubPosition == .seconds(3600))
    }

    @Test func aShortRecordingScrubsAtLeastAMinutePerSwipe() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(30), duration: .seconds(120))
        rig.model.playPause()
        await rig.engine.waitUntilDelivered()
        rig.model.tick()
        rig.model.scrub(by: 0.5)
        #expect(rig.model.scrubPosition == .seconds(60))
    }

    @Test func withoutADurationAFullSwipeIsTenMinutes() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(30), duration: nil)
        rig.model.playPause()
        await rig.engine.waitUntilDelivered()
        rig.model.tick()
        rig.model.scrub(by: 0.5)
        #expect(rig.model.scrubPosition == .seconds(330))
    }

    @Test func selectCommitsAScrubElsePlaysOrPauses() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.model.select()
        #expect(rig.seeks == [.seconds(780)])
        #expect(rig.engine.snapshot.status == .paused)
        rig.model.select()
        #expect(rig.engine.snapshot.status == .playing)
        rig.model.select()
        #expect(rig.engine.snapshot.status == .paused)
    }

    @Test func playPauseDuringAScrubCommitsItAndPlays() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.model.playPause()
        #expect(rig.seeks == [.seconds(780)])
        #expect(rig.engine.snapshot.status == .playing)
        #expect(rig.model.scrubPosition == nil)
    }

    @Test func aSkipDuringAScrubCancelsItThenSkipsFromWhereTheVideoIs() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.model.skipForward()
        #expect(rig.model.scrubPosition == nil)
        #expect(rig.seeks == [.seconds(630)])
    }

    @Test func openingThePanelCancelsAScrub() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.model.openPanel(.audio)
        #expect(rig.model.scrubPosition == nil)
        #expect(rig.model.panel == .audio)
        #expect(rig.seeks.isEmpty)
    }

    // MARK: Back

    @Test func backCancelsAScrubThenClosesThePanelThenLeaves() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        #expect(rig.model.back() == .handled)
        #expect(rig.model.scrubPosition == nil)
        #expect(rig.seeks.isEmpty)

        rig.model.openPanel(.subtitles)
        #expect(rig.model.back() == .handled)
        #expect(rig.model.panel == nil)

        #expect(rig.model.back() == .leave)
    }

    // MARK: Playing and pausing

    @Test func playAndPauseOnlyActWhenTheyChangeSomething() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        let before = rig.engine.calls.count
        rig.model.play()
        #expect(rig.engine.calls.count == before)
        rig.model.pause()
        #expect(rig.engine.snapshot.status == .paused)
        rig.model.pause()
        rig.model.play()
        #expect(rig.engine.snapshot.status == .playing)
        #expect(Array(rig.engine.calls.dropFirst(before)) == [.pause, .play])
    }

    @Test func skipsAndSeeksGoToTheSession() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        rig.model.skipForward()
        rig.model.skipBackward()
        rig.model.seek(to: .seconds(50))
        #expect(rig.seeks == [.seconds(130), .seconds(120), .seconds(50)])
    }

    @Test func aSkipOfAGivenLengthCancelsAScrubAndShowsTheControls() async {
        let rig = TransportRig()
        await rig.paused(at: .seconds(600))
        rig.model.scrub(by: 0.25)
        rig.model.skip(by: .seconds(-10))
        #expect(rig.model.scrubPosition == nil)
        #expect(rig.seeks == [.seconds(590)])
        #expect(rig.model.controlsVisible)
    }

    // MARK: Time text

    @Test(arguments: [
        (Duration.zero, "0:00"), (.seconds(5), "0:05"), (.seconds(65), "1:05"), (.milliseconds(599_900), "9:59"),
        (.seconds(3599), "59:59"), (.seconds(3600), "1:00:00"), (.seconds(3723), "1:02:03"),
        (.seconds(36_000), "10:00:00"),
    ])
    func timeIsMinutesAndSecondsUnderAnHourElseHours(_ d: Duration, _ text: String) {
        #expect(TransportModel.timeText(d) == text)
    }

    @Test func elapsedAndRemainingTime() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(754), duration: .seconds(5400))
        #expect(rig.model.elapsedText == "12:34")
        #expect(rig.model.remainingText == "-1:17:26")
        #expect(rig.model.progress == 754.0 / 5400.0)
    }

    @Test func remainingTimeIsRoundedUpSoTheTwoAddUp() async {
        let rig = TransportRig()
        await rig.playing(at: .milliseconds(10_400), duration: .seconds(60))
        #expect(rig.model.elapsedText == "0:10")
        #expect(rig.model.remainingText == "-0:50")
    }

    @Test func withoutADurationThereIsNoRemainingTimeOrProgress() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(75), duration: nil)
        #expect(rig.model.elapsedText == "1:15")
        #expect(rig.model.remainingText == nil)
        #expect(rig.model.progress == nil)
    }

    // MARK: State for the screen

    @Test func aFailedEngineGivesThePlaybackMessage() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        #expect(rig.model.failure == nil)
        rig.engine.emitFailed("VLC error")
        await rig.engine.waitUntilDelivered()
        rig.model.tick()  // as the screen does on every snapshot change
        #expect(rig.model.failure == .playbackFailed)
        #expect(rig.model.failure?.detail.contains("VLC") == false)
    }

    @Test func theEndIsReported() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(100))
        #expect(!rig.model.hasEnded)
        // The session stops reading on `.ended`, so `waitUntilDelivered()` would never return:
        // wait for its observable snapshot to change instead.
        let session = rig.session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            withObservationTracking { _ = session.snapshot } onChange: { done.resume() }
            rig.engine.emitEnded()
        }
        rig.model.tick()  // as the screen does on every snapshot change
        #expect(rig.model.hasEnded)
        #expect(await rig.session.finish().reachedEnd)
    }

    @Test func loadingAndBufferingShowTheSpinner() async {
        let rig = TransportRig()
        await rig.session.start()
        await rig.emit(.loading, at: .zero)
        #expect(rig.model.isWaiting)
        await rig.emit(.playing, at: .seconds(1))
        #expect(!rig.model.isWaiting)
        #expect(rig.model.isPlaying)
        await rig.emit(.buffering, at: .seconds(2))
        #expect(rig.model.isWaiting)
    }

    // MARK: Panel

    @Test func openingThePanelReadsTheTracks() async {
        let rig = TransportRig()
        let english = MediaTrack(id: 1, name: "English", language: "English")
        let captions = MediaTrack(id: 3, name: "Track 1", language: nil)
        rig.engine.audioTracks = [english]
        rig.engine.subtitleTracks = [captions]
        rig.engine.selectedAudioTrack = 1
        await rig.playing(at: .seconds(100))

        rig.model.openPanel(.audio)
        #expect(rig.model.audioTracks == [english])
        #expect(rig.model.subtitleTracks == [captions])
        #expect(rig.model.selectedAudioTrack == 1)
        #expect(rig.model.selectedSubtitleTrack == nil)

        rig.model.selectSubtitleTrack(3)
        #expect(rig.model.selectedSubtitleTrack == 3)
        #expect(rig.engine.calls.last == .selectSubtitleTrack(3))
        rig.model.selectSubtitleTrack(nil)
        #expect(rig.model.selectedSubtitleTrack == nil)
        rig.model.selectAudioTrack(1)
        #expect(rig.engine.calls.last == .selectAudioTrack(1))
    }

    @Test func setBookmarkStoresWhereTheViewerIs() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(1234))
        await rig.model.setBookmark()
        #expect(rig.store.bookmark(for: rig.recording.id) == .seconds(1234))
    }

    @Test func theSessionsProblemIsTheNotice() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(1234))
        rig.state.failNext(.rejected("DIAG"), on: .setBookmark)
        await rig.model.setBookmark()
        #expect(rig.model.notice == "Couldn't set the bookmark.")
    }

    /// The screen redraws on every change it observes. While playing, the position changes about
    /// four times a second; what the screen around the panel reads must not change with it, or
    /// the player and its panel redraw all the time and focus in the panel is hard to move
    /// (owner, 2026-11-16). Only the time texts and progress may follow the position.
    @Test func positionUpdatesWhilePlayingNotifyOnlyTheTimeReaders() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(10))
        rig.model.openPanel(.info)
        let changed = ChangeFlag()
        withObservationTracking {
            _ = rig.model.isPlaying
            _ = rig.model.isWaiting
            _ = rig.model.hasEnded
            _ = rig.model.failure
            _ = rig.model.controlsVisible
            _ = rig.model.hideAt
            _ = rig.model.panel
            _ = rig.model.commercialBanner
            _ = rig.model.bannerHidesAt
        } onChange: { changed.set() }
        await rig.emit(.playing, at: .milliseconds(10_250))
        await rig.emit(.playing, at: .milliseconds(10_500))
        rig.advance(.seconds(1))
        #expect(!changed.value)
    }

    @Test func aStatusChangeStillNotifies() async {
        let rig = TransportRig()
        await rig.playing(at: .seconds(10))
        let changed = ChangeFlag()
        withObservationTracking { _ = rig.model.isPlaying } onChange: { changed.set() }
        await rig.emit(.paused, at: .seconds(11))
        #expect(changed.value)
        #expect(!rig.model.isPlaying)
    }
}
