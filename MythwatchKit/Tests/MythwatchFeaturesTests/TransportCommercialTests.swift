import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

/// M4-3: what the player screen shows and does for commercials (SPEC 6.4 "Transport rules",
/// "Commercials"). A `TransportModel` over a real `PlaybackSession` with breaks, on the fakes.
@MainActor private final class CommercialRig {
    let recording = Recording.fixture(id: RecordingID(rawValue: 9), title: "Harbour Lights")
    let store = FakeBackendStore()
    let engine = FakePlayerEngine()
    let clock = TestClock()
    let session: PlaybackSession
    let model: TransportModel

    init(breaks: [CommercialBreak], mode: CommercialSkipMode = .auto) {
        store.add(recording, commercialBreaks: breaks)
        session = PlaybackSession(
            recording: recording, start: .beginning, engine: engine, state: FakePlaybackStateService(store: store),
            markup: FakeMarkupService(store: store), recordings: FakeRecordingsService(store: store),
            media: FakeMediaLocator(), settings: PlaybackSettings(commercialSkip: CommercialSkipConfig(mode: mode)),
            now: clock.now)
        model = TransportModel(session: session, recording: recording, now: clock.now)
    }

    func start() async {
        await session.start()
        await engine.waitUntilDelivered()
        model.tick()
    }

    func emit(_ status: PlayerStatus, at position: Duration, duration: Duration? = .seconds(3600)) async {
        engine.emit(PlayerSnapshot(status: status, position: position, duration: duration, rate: status == .playing ? 1 : 0))
        await engine.waitUntilDelivered()
        model.tick()
    }

    func advance(_ d: Duration) {
        clock.advance(by: d)
        model.tick()
    }

    var seeks: [Duration] { engine.calls.compactMap { if case .seek(let to) = $0 { to } else { nil } } }
    var pauses: Int { engine.calls.filter { $0 == .pause }.count }
}

private func brk(_ start: Int, _ end: Int) -> CommercialBreak {
    CommercialBreak(start: .seconds(start), end: .seconds(end))!
}

private func share(_ a: Double, _ b: Double) -> Double { a / b }

@MainActor @Suite(.timeLimit(.minutes(1)))
struct TransportCommercialTests {
    // MARK: Skipped banner

    @Test func anAutomaticSkipShowsTheSkippedBannerWithTheDistance() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        #expect(rig.model.commercialBanner == nil)
        await rig.emit(.playing, at: .seconds(600))
        #expect(rig.seeks == [.seconds(779)])
        #expect(rig.model.commercialBanner == .skipped(.seconds(179)))
        #expect(rig.model.bannerHidesAt == rig.clock.now() + .seconds(8))
    }

    @Test func goBackReturnsToTheBreakAndHidesTheBanner() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(600))
        rig.model.goBack()
        #expect(rig.seeks == [.seconds(779), .seconds(598)])
        #expect(rig.model.commercialBanner == nil)
        #expect(rig.model.bannerHidesAt == nil)
    }

    @Test func selectWhileTheSkippedBannerShowsGoesBackInsteadOfPausing() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(600))
        rig.model.select()
        #expect(rig.seeks.last == .seconds(598))
        #expect(rig.pauses == 0)
        #expect(rig.model.commercialBanner == nil)
    }

    @Test func playPauseWhileTheBannerShowsStillPauses() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(600))
        rig.model.playPause()
        #expect(rig.pauses == 1)
        #expect(rig.seeks == [.seconds(779)])
        #expect(rig.model.commercialBanner == .skipped(.seconds(179)))
    }

    @Test func theBannerHidesWhenTheModelsClockPassesUndoUntilEvenWhilePaused() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(600))
        rig.model.playPause()
        await rig.emit(.paused, at: .seconds(779))
        rig.advance(.milliseconds(7999))
        #expect(rig.model.commercialBanner == .skipped(.seconds(179)))
        rig.advance(.milliseconds(1))
        // No tick reached the session (paused), so it still holds the banner; the screen does not.
        #expect(rig.session.banner != nil)
        #expect(rig.model.commercialBanner == nil)
        #expect(rig.model.bannerHidesAt == nil)
    }

    @Test func selectAfterTheBannerExpiredTogglesPlayAndClearsTheSessionsBanner() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(600))
        rig.model.playPause()
        await rig.emit(.paused, at: .seconds(779))
        rig.advance(.seconds(9))
        rig.model.select()
        #expect(rig.engine.calls.last == .play)
        #expect(rig.seeks == [.seconds(779)])
    }

    @Test func goBackAfterTheBannerExpiredDoesNotSeekAndClearsTheSessionsBanner() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(600))
        rig.model.playPause()
        await rig.emit(.paused, at: .seconds(779))
        rig.advance(.seconds(9))
        rig.model.goBack()
        #expect(rig.seeks == [.seconds(779)])
        #expect(rig.session.banner == nil)
    }

    @Test func aScrubCommitsBeforeTheBannerActs() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(600))
        rig.model.playPause()
        await rig.emit(.paused, at: .seconds(779))
        rig.model.scrub(by: 0.5)
        let target = rig.model.scrubPosition
        rig.model.select()
        #expect(target != nil)
        #expect(rig.seeks.last == target)
        #expect(rig.model.scrubPosition == nil)
    }

    @Test func goBackCountsAsInput() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.playing, at: .seconds(100))
        rig.advance(.seconds(6))
        #expect(!rig.model.controlsVisible)
        await rig.emit(.playing, at: .seconds(600))
        rig.model.goBack()
        #expect(rig.model.controlsVisible)
    }

    // MARK: Skip offer (prompt mode)

    @Test func promptModeOffersASkipAndSelectAcceptsIt() async {
        let rig = CommercialRig(breaks: [brk(600, 780)], mode: .prompt)
        await rig.start()
        await rig.emit(.playing, at: .seconds(610))
        #expect(rig.model.commercialBanner == .offer)
        #expect(rig.model.bannerHidesAt == nil)
        rig.model.select()
        #expect(rig.seeks == [.seconds(779)])
        #expect(rig.pauses == 0)
        #expect(rig.model.commercialBanner == .skipped(.seconds(169)))
    }

    @Test func skipCommercialsAcceptsTheOffer() async {
        let rig = CommercialRig(breaks: [brk(600, 780)], mode: .prompt)
        await rig.start()
        await rig.emit(.playing, at: .seconds(610))
        rig.model.skipCommercials()
        #expect(rig.seeks == [.seconds(779)])
        #expect(rig.model.commercialBanner == .skipped(.seconds(169)))
    }

    @Test func theOfferDoesNotExpireWithTime() async {
        let rig = CommercialRig(breaks: [brk(600, 780)], mode: .prompt)
        await rig.start()
        await rig.emit(.playing, at: .seconds(610))
        rig.advance(.seconds(60))
        #expect(rig.model.commercialBanner == .offer)
    }

    @Test func offModeShowsNoBanner() async {
        let rig = CommercialRig(breaks: [brk(600, 780)], mode: .off)
        await rig.start()
        await rig.emit(.playing, at: .seconds(610))
        #expect(rig.model.commercialBanner == nil)
        rig.model.select()
        #expect(rig.pauses == 1)
    }

    // MARK: Scrubber

    @Test func breakSegmentsAreSharesOfTheDuration() async {
        let rig = CommercialRig(breaks: [brk(600, 780), brk(1800, 1980)])
        await rig.start()
        await rig.emit(.paused, at: .seconds(10), duration: .seconds(3600))
        let expected: [ClosedRange<Double>] = [share(600, 3600)...share(780, 3600), share(1800, 3600)...share(1980, 3600)]
        #expect(rig.model.breakSegments == expected)
    }

    @Test func breakSegmentsShowInEveryMode() async {
        for mode in CommercialSkipMode.allCases {
            let rig = CommercialRig(breaks: [brk(600, 780)], mode: mode)
            await rig.start()
            await rig.emit(.paused, at: .seconds(10), duration: .seconds(3600))
            #expect(rig.model.breakSegments.count == 1, "mode \(mode)")
        }
    }

    @Test func breakSegmentsNeedADuration() async {
        let rig = CommercialRig(breaks: [brk(600, 780)])
        await rig.start()
        await rig.emit(.paused, at: .seconds(10), duration: nil)
        #expect(rig.model.breakSegments.isEmpty)
    }

    @Test func breakSegmentsAreCutAtTheDuration() async {
        // A recording still growing: the duration so far ends inside one break, before another.
        let rig = CommercialRig(breaks: [brk(600, 780), brk(1800, 1980)])
        await rig.start()
        await rig.emit(.paused, at: .seconds(10), duration: .seconds(720))
        let expected: [ClosedRange<Double>] = [share(600, 720)...1.0]
        #expect(rig.model.breakSegments == expected)
    }
}
