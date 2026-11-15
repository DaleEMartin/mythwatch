import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

// The commercial skipper wired into `PlaybackSession` (M4-2; SPEC 5.2 "Commercials").
// Default skip settings throughout: land 1 s before the end, 3 s quiet period, 8 s undo window,
// undo rewinds 2 s, 10 s end guard. The rig's duration is an hour unless a test says otherwise.

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionCommercialTests {
    // MARK: the task's list

    @Test func effectsBecomeEngineSeeksAndBannerChanges() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(59))
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == nil)

        await rig.play(for: s(1))  // 60: the break arrives
        #expect(rig.seeks == [s(119)])
        #expect(rig.session.banner == rig.skippedBanner(s(59)))
        #expect(rig.engine.snapshot.position == s(119))

        // `.hideSkipped` comes from the first tick at or after the end of the undo window.
        await rig.play(for: s(7))
        #expect(rig.session.banner != nil)
        await rig.play(for: s(1))
        #expect(rig.session.banner == nil)
        #expect(rig.seeks == [s(119)])
    }

    @Test func aUserSkipThatLandsInABreakPlaysIt() async {
        let rig = SessionRig(breaks: [cb(60, 120), cb(600, 660)])
        await rig.playing(at: s(50))
        rig.session.skipForward()  // to 80, inside the first break
        await rig.engine.waitUntilDelivered()
        await rig.play(to: s(125))
        #expect(rig.seeks == [s(80)])  // R3: it played through
        #expect(rig.session.banner == nil)
        // The next break is still skipped.
        rig.clock.advance(by: s(474))
        await rig.emit(.playing, at: s(599))
        await rig.play(for: s(1))
        #expect(rig.seeks == [s(80), s(659)])
    }

    @Test func undoReturnsBeforeTheBreakWhichThenPlays() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(59))
        await rig.play(for: s(1))  // skipped from 60 to 119
        await rig.play(for: s(2))
        rig.session.undoCommercialSkip()
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks == [s(119), s(58)])  // origin 60 less the 2 s rewind
        #expect(rig.session.banner == nil)
        await rig.play(to: s(125))
        #expect(rig.seeks == [s(119), s(58)])  // the break played through
        #expect(rig.session.banner == nil)
    }

    @Test func promptModeOffersAndSeeksOnlyWhenAccepted() async {
        let rig = SessionRig(breaks: [cb(60, 120)], settings: skipSettings(.prompt))
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        #expect(rig.session.banner == .offer(cb(60, 120)))
        await rig.play(for: s(2))
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == .offer(cb(60, 120)))

        rig.session.acceptSkipOffer()  // from the viewer's position, 62
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks == [s(119)])
        #expect(rig.session.banner == rig.skippedBanner(s(57)))
    }

    @Test(arguments: CommercialSkipMode.allCases)
    func breaksAreExposedForTheScrubberInEveryMode(_ mode: CommercialSkipMode) async {
        let rig = SessionRig(breaks: [cb(600, 660), cb(60, 100), cb(90, 120)], settings: skipSettings(mode))
        #expect(rig.session.breaks.isEmpty)  // not known before start
        await rig.start()
        #expect(rig.session.breaks == [cb(60, 120), cb(600, 660)])  // normalised
        await rig.emit(.playing, at: s(61))
        #expect(rig.session.breaks == [cb(60, 120), cb(600, 660)])
    }

    @Test(arguments: [
        (CommercialSkipMode.auto, [s(119)], true),
        (.prompt, [], false),
        (.off, [], false),
    ])
    func theModeIsReadFromTheSettingsAtStart(
        _ mode: CommercialSkipMode, _ expectedSeeks: [Duration], _ skipped: Bool
    ) async {
        let rig = SessionRig(breaks: [cb(60, 120)], settings: skipSettings(mode))
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        #expect(rig.seeks == expectedSeeks)
        switch mode {
        case .auto: #expect(rig.session.banner == rig.skippedBanner(s(59)))
        case .prompt: #expect(rig.session.banner == .offer(cb(60, 120)))
        case .off: #expect(rig.session.banner == nil)
        }
        #expect(skipped == (rig.engine.snapshot.position == s(119)))
    }

    // MARK: which position is ticked, and when

    @Test func aUserSkipIntoABreakPlaysItEvenWhenTheEngineReportsStalePositions() async {
        // The skipper is ticked with the viewer's position (the seek target while a seek is
        // pending), so a pre-seek position cannot re-arm the break the viewer skipped into.
        let rig = SessionRig(breaks: [cb(60, 120)], automaticResponses: false)
        await rig.playing(at: s(50))
        rig.session.skipForward()  // to 80
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: ms(50_250))  // stale: from before the seek
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: s(80))  // the engine arrives
        await rig.play(to: s(125))  // well past the quiet period
        #expect(rig.seeks == [s(80)])
        #expect(rig.session.banner == nil)
    }

    @Test func aStaleReportAfterAnAcceptedSkipDoesNotOfferTheBreakAgain() async {
        let rig = SessionRig(breaks: [cb(60, 120), cb(600, 660)], settings: skipSettings(.prompt),
                             automaticResponses: false)
        await rig.playing(at: s(59))
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: s(60))
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: ms(60_250))
        rig.session.acceptSkipOffer()
        let banner = rig.skippedBanner(ms(58_750))
        #expect(rig.session.banner == banner)
        // The engine has not caught up: it jitters back before the break, then inside it.
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: ms(59_900))
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: ms(60_500))
        #expect(rig.session.banner == banner)
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: s(119))
        #expect(rig.session.banner == banner)
        #expect(rig.seeks == [s(119)])
    }

    @Test func untrustedPositionsNeverTriggerASkip() async {
        // Resuming at 20 minutes in a recording with a break at 0: a loading engine reporting 0
        // must not skip that break (and pull the viewer back to 59 s).
        let rig = SessionRig(start: .resume, resume: s(1200), breaks: [cb(0, 60)], automaticResponses: false)
        await rig.start()
        await rig.emit(.idle, at: .zero)
        await rig.emit(.loading, at: .zero)
        await rig.emit(.playing, at: s(1200))
        await rig.emit(.failed("DIAG"), at: .zero)
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == nil)
    }

    @Test func aBreakIsNotSkippedWhilePausedButWhenPlayResumes() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(59))
        // The engine's first report inside the break is a pause.
        rig.clock.advance(by: ms(1500))
        await rig.emit(.paused, at: ms(60_500))
        rig.clock.advance(by: s(30))
        await rig.emit(.paused, at: ms(60_500))
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == nil)
        await rig.emit(.playing, at: ms(60_500))
        #expect(rig.seeks == [s(119)])
        #expect(rig.session.banner == rig.skippedBanner(ms(58_500)))  // the window starts now
    }

    @Test func aBreakIsSkippedWhileBuffering() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(59))
        rig.clock.advance(by: s(1))
        await rig.emit(.buffering, at: s(61))
        #expect(rig.seeks == [s(119)])
    }

    @Test func theEndedSnapshotDoesNotTick() async {
        // Duration unknown, so no end guard: only the status keeps this break from being skipped
        // on the way out.
        let rig = SessionRig(breaks: [cb(3500, 3700)])
        await rig.playing(at: s(3400), duration: nil)
        await rig.emit(.ended, at: s(3550))
        let outcome = await rig.finish()
        #expect(rig.seeks.isEmpty)
        #expect(outcome == PlaybackOutcome(position: s(3550), reachedEnd: true, markedWatched: true))
    }

    @Test func theSameSnapshotTwiceSeeksOnce() async {
        let rig = SessionRig(breaks: [cb(60, 120)], automaticResponses: false)
        await rig.playing(at: s(59))
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: s(60))
        await rig.emit(.playing, at: s(60))
        #expect(rig.seeks == [s(119)])
        #expect(rig.session.banner == rig.skippedBanner(s(59)))
    }

    // MARK: automatic seeks and the pending seek

    @Test func aPauseRightAfterASkipSavesTheLandingEvenIfTheEngineLags() async {
        let rig = SessionRig(breaks: [cb(60, 120)], automaticResponses: false)
        await rig.playing(at: s(59))
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: s(60))
        rig.clock.advance(by: ms(250))
        await rig.emit(.paused, at: ms(60_250))  // stale
        await rig.settle()
        #expect(rig.resumeWrites == [s(119)])
    }

    @Test func userSkipsAfterAnAutomaticSkipStartFromTheLanding() async {
        let rig = SessionRig(breaks: [cb(60, 120)], automaticResponses: false)
        await rig.playing(at: s(59))
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: s(60))
        rig.session.skipForward()
        rig.session.skipForward()
        #expect(rig.seeks == [s(119), s(149), s(179)])
    }

    @Test func anAutomaticSeekIsNotTreatedAsAUserSeek() async {
        // Were the skipper's own seek reported back to it as a user seek, it would hide the
        // banner it had just shown (in the skipper) and there would be nothing left to undo.
        let rig = SessionRig(breaks: [cb(60, 120), cb(121, 150)],
                             settings: PlaybackSettings(commercialSkip: CommercialSkipConfig(quietPeriod: .zero)))
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        #expect(rig.seeks == [s(119)])
        await rig.play(to: s(122))
        #expect(rig.seeks == [s(119), s(149)])
        rig.session.undoCommercialSkip()
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks == [s(119), s(149), s(119)])  // 121 less the rewind
    }

    // MARK: saves around a skip

    @Test func anIntervalSaveDueOnTheSkippingSnapshotStoresTheLanding() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(30))
        rig.clock.advance(by: s(30))
        await rig.emit(.playing, at: s(60))  // the interval is due and the break arrives
        await rig.settle()
        #expect(rig.resumeWrites == [s(119)])
        #expect(rig.storedResume == s(119))
    }

    @Test func anIntervalSaveJustAfterASkipNeverStoresAPositionInTheBreak() async {
        let rig = SessionRig(breaks: [cb(60, 120)], automaticResponses: false)
        await rig.playing(at: s(30))
        rig.clock.advance(by: ms(29_750))
        await rig.emit(.playing, at: s(60))  // skipped; the interval is not due yet
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: ms(60_250))  // stale, and the interval is due
        await rig.settle()
        #expect(rig.resumeWrites == [s(119)])
    }

    @Test func afterAnUndoTheNextSaveIsBeforeTheBreak() async {
        let rig = SessionRig(breaks: [cb(60, 120)], automaticResponses: false)
        await rig.playing(at: s(59))
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: s(60))
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: s(119))
        rig.clock.advance(by: s(2))
        await rig.emit(.playing, at: s(121))
        rig.session.undoCommercialSkip()
        rig.clock.advance(by: ms(250))
        await rig.emit(.paused, at: ms(121_250))  // stale: from before the undo
        await rig.settle()
        #expect(rig.resumeWrites == [s(58)])
    }

    // MARK: finish

    @Test func finishDuringTheUndoWindowKeepsTheLandingAndEndsSkipping() async {
        let rig = SessionRig(breaks: [cb(60, 120), cb(600, 660)], automaticResponses: false)
        await rig.playing(at: s(59))
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: s(60))
        #expect(rig.session.banner == rig.skippedBanner(s(59)))
        let before = rig.engine.calls.count
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(119), reachedEnd: false, markedWatched: false))
        #expect(rig.resumeWrites == [s(119)])
        #expect(rig.session.banner == nil)
        // Nothing more from the skipper: no ticks, no undo, no accept.
        rig.clock.advance(by: s(1))
        var snapshot = rig.engine.snapshot
        snapshot.status = .playing
        snapshot.position = s(601)
        rig.engine.emit(snapshot)
        await rig.endStream()
        rig.session.undoCommercialSkip()
        rig.session.acceptSkipOffer()
        #expect(rig.engineCalls(after: before) == [.stop])
        #expect(rig.session.banner == nil)
    }

    @Test func finishWhileTheSkipButtonShowsRemovesItAndSkipThenDoesNothing() async {
        let rig = SessionRig(breaks: [cb(60, 120)], settings: skipSettings(.prompt))
        await rig.playing(at: s(59))
        await rig.play(for: s(2))
        #expect(rig.session.banner == .offer(cb(60, 120)))
        let before = rig.engine.calls.count
        let outcome = await rig.finish()
        #expect(outcome.position == s(61))
        #expect(rig.session.banner == nil)
        rig.session.acceptSkipOffer()
        #expect(rig.engineCalls(after: before) == [.stop])
        #expect(rig.session.banner == nil)
    }

    @Test func aRecordingWhoseLastBreakIsGuardedFinishesNormally() async {
        let rig = SessionRig(breaks: [cb(985, 995)])  // ends within 10 s of the end: guarded
        await rig.playing(at: s(980), duration: s(1000))
        await rig.play(to: s(999))
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == nil)
        await rig.emitEnded()
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(1000), reachedEnd: true, markedWatched: true))
        #expect(rig.recordings.calls == [.setWatched(true, rig.id)])
    }

    // MARK: banners

    @Test func aBannerLeftUpWhilePausedIsClearedByGoBackAfterTheWindow() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        await rig.play(for: s(1))
        await rig.pause()
        rig.clock.advance(by: s(60))  // a paused engine may report nothing at all
        #expect(rig.session.banner == .skipped(s(59), undoUntil: rig.clock.now() - s(53)))
        rig.session.undoCommercialSkip()  // too late: nothing to undo
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks == [s(119)])
        #expect(rig.session.banner == nil)
    }

    @Test func goBackWithinTheWindowWorksWhilePaused() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        await rig.pause()
        rig.clock.advance(by: s(5))
        rig.session.undoCommercialSkip()
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks == [s(119), s(58)])
        #expect(rig.session.banner == nil)
    }

    @Test func aUserSeekHidesTheBanner() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        #expect(rig.session.banner != nil)
        rig.session.skipBackward()
        await rig.engine.waitUntilDelivered()
        #expect(rig.session.banner == nil)
        #expect(rig.seeks == [s(119), s(109)])
    }

    @Test func aUserSeekWithdrawsAnOfferAndTheBreakThenPlays() async {
        let rig = SessionRig(breaks: [cb(60, 120)], settings: skipSettings(.prompt))
        await rig.playing(at: s(59))
        await rig.play(for: s(2))
        #expect(rig.session.banner == .offer(cb(60, 120)))
        rig.session.seek(to: s(90))
        await rig.engine.waitUntilDelivered()
        #expect(rig.session.banner == nil)
        await rig.play(to: s(125))
        #expect(rig.session.banner == nil)
        #expect(rig.seeks == [s(90)])
    }

    @Test func aSecondSkipReplacesTheBannerAndUndoGoesBackOverItOnly() async {
        // 123 is not before 119 + the 3 s quiet period, so the second break is not chained.
        let rig = SessionRig(breaks: [cb(60, 120), cb(123, 150)])
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        #expect(rig.session.banner == rig.skippedBanner(s(59)))
        await rig.play(to: s(123))
        #expect(rig.seeks == [s(119), s(149)])
        #expect(rig.session.banner == rig.skippedBanner(s(26)))
        rig.session.undoCommercialSkip()
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks == [s(119), s(149), s(121)])
        #expect(rig.session.banner == nil)
    }

    @Test func anOfferMovesToTheNextBreakWhenPlaybackJumpsIntoIt() async {
        // One tick withdraws the old offer and makes the new one: [.withdrawOffer, .offerSkip].
        let rig = SessionRig(breaks: [cb(60, 120), cb(300, 400)], settings: skipSettings(.prompt))
        await rig.playing(at: s(59))
        await rig.play(for: s(2))
        #expect(rig.session.banner == .offer(cb(60, 120)))
        rig.clock.advance(by: ms(250))
        await rig.emit(.playing, at: s(301))  // the engine jumped without being asked
        #expect(rig.session.banner == .offer(cb(300, 400)))
        #expect(rig.seeks.isEmpty)
    }

    @Test func anOfferDuringTheUndoWindowReplacesTheBannerAndOutlivesItsExpiry() async {
        // Prompt mode: Skip at the first break, and the next one (not chained: 125 is not
        // before 119 + 3) starts 6 s later, inside the first banner's 8 s undo window.
        let rig = SessionRig(breaks: [cb(60, 120), cb(125, 200)], settings: skipSettings(.prompt))
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        rig.session.acceptSkipOffer()
        await rig.engine.waitUntilDelivered()
        #expect(rig.session.banner == rig.skippedBanner(s(59)))
        await rig.play(to: s(125))
        #expect(rig.session.banner == .offer(cb(125, 200)))  // the newer replaces the older
        await rig.play(to: s(128))  // the first banner's window ends: its `.hideSkipped` arrives
        #expect(rig.session.banner == .offer(cb(125, 200)))
        #expect(rig.seeks == [s(119)])
    }

    @Test func anAcceptedOfferReplacesTheOfferWithTheSkippedBanner() async {
        // [.seek, .withdrawOffer, .showSkipped]; then Go back: [.seek, .hideSkipped].
        let rig = SessionRig(breaks: [cb(60, 120)], settings: skipSettings(.prompt))
        await rig.playing(at: s(59))
        await rig.play(for: s(1))
        rig.session.acceptSkipOffer()
        await rig.engine.waitUntilDelivered()
        #expect(rig.session.banner == rig.skippedBanner(s(59)))
        rig.session.undoCommercialSkip()
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks == [s(119), s(58)])
        #expect(rig.session.banner == nil)
        await rig.play(to: s(125))  // suppressed: it plays, and is not offered again
        #expect(rig.session.banner == nil)
        #expect(rig.seeks == [s(119), s(58)])
    }

    // MARK: start

    @Test func resumingInsideABreakSkipsIt() async {
        let rig = SessionRig(start: .resume, resume: s(1200), breaks: [cb(1170, 1260)])
        await rig.start()
        #expect(rig.seeks == [s(1259)])
        #expect(rig.session.banner == rig.skippedBanner(s(59)))
    }

    @Test func startingAtABookmarkInsideABreakPlaysIt() async {
        let rig = SessionRig(start: .bookmark, bookmark: s(1200), breaks: [cb(1170, 1260), cb(1800, 1900)])
        await rig.start()
        await rig.play(to: s(1265))
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == nil)
        // A later break is skipped as usual.
        rig.clock.advance(by: s(534))
        await rig.emit(.playing, at: s(1799))
        await rig.play(for: s(1))
        #expect(rig.seeks == [s(1899)])
    }

    @Test func aFailedBreaksFetchSkipsNothing() async {
        let rig = SessionRig(breaks: [cb(60, 120)])
        rig.markup.failNext(.rejected("DIAG"))
        await rig.playing(at: s(59))
        await rig.play(to: s(125))
        #expect(rig.session.breaks.isEmpty)
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == nil)
    }

    @Test func offModeNeverSeeksOrShowsABanner() async {
        let rig = SessionRig(breaks: [cb(60, 120)], settings: skipSettings(.off))
        await rig.playing(at: s(59))
        await rig.play(to: s(125))
        rig.session.acceptSkipOffer()
        rig.session.undoCommercialSkip()
        await rig.engine.waitUntilDelivered()
        #expect(rig.seeks.isEmpty)
        #expect(rig.session.banner == nil)
        #expect(rig.session.breaks == [cb(60, 120)])
    }

    @Test func undoAndAcceptDoNothingBeforeStart() {
        let rig = SessionRig(breaks: [cb(0, 60)])
        rig.session.undoCommercialSkip()
        rig.session.acceptSkipOffer()
        #expect(rig.engine.calls.isEmpty)
        #expect(rig.session.banner == nil)
    }
}
