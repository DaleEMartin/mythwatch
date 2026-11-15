import MythwatchDomain
import Testing

@testable import MythwatchPlayback

// MARK: - Helpers

/// Instants for tests. `ContinuousClock.Instant` has no public initialiser, so one reading is
/// taken as an arbitrary origin and every instant is origin + offset. Nothing depends on real
/// elapsed time.
let origin = ContinuousClock.now
func at(_ offset: Duration) -> ContinuousClock.Instant { origin + offset }
func at(seconds: Int) -> ContinuousClock.Instant { origin + .seconds(seconds) }

func s(_ seconds: Int) -> Duration { .seconds(seconds) }
func ms(_ milliseconds: Int) -> Duration { .milliseconds(milliseconds) }

/// A break in whole seconds.
func cb(_ start: Int, _ end: Int) -> CommercialBreak { cb(s(start), s(end)) }
func cb(_ start: Duration, _ end: Duration) -> CommercialBreak {
    guard let range = TimeRange(start: start, end: end) else {
        preconditionFailure("test break \(start)..<\(end) is empty")
    }
    return range
}

/// Thirty minutes: far enough from every break below that the end guard (R5) never applies
/// unless a test says so.
let longFile: Duration = .seconds(1800)

func skipper(
    _ breaks: [CommercialBreak], mode: CommercialSkipMode = .auto,
    undoRewind: Duration = .seconds(2)
) -> CommercialSkipper {
    CommercialSkipper(
        breaks: breaks, config: CommercialSkipConfig(mode: mode, undoRewind: undoRewind))
}

extension CommercialSkipper {
    /// Ticks with position == clock offset (playback started at the clock origin) and a long file.
    mutating func tick(_ position: Duration, now: Duration? = nil, duration: Duration? = longFile)
        -> [SkipEffect]
    {
        tick(position: position, duration: duration, now: at(now ?? position))
    }

    /// A tiny simulated engine: plays from `from` while the position is at most `to`, at 1x in
    /// `step` increments, with the clock offset moving by the same amount from `clockStart`. A
    /// `.seek(to:)` effect moves the position (the next tick reports the target). Returns every
    /// non-empty tick's effects keyed by the position that produced them.
    mutating func play(
        from: Duration, to: Duration, step: Duration = .milliseconds(250),
        clockStart: Duration? = nil, duration: Duration? = longFile
    ) -> [(position: Duration, effects: [SkipEffect])] {
        var out: [(Duration, [SkipEffect])] = []
        var position = from
        var clock = clockStart ?? from
        while position <= to {
            let effects = tick(position: position, duration: duration, now: at(clock))
            if !effects.isEmpty { out.append((position, effects)) }
            if case .seek(let target)? = effects.first {
                position = target
            } else {
                position += step
            }
            clock += step
        }
        return out
    }
}

// MARK: - normalise

@Suite struct CommercialSkipperNormaliseTests {
    @Test func sortsUnsortedBreaks() {
        #expect(CommercialSkipper.normalise([cb(300, 400), cb(10, 20), cb(100, 200)])
            == [cb(10, 20), cb(100, 200), cb(300, 400)])
    }

    @Test func mergesOverlappingBreaks() {
        #expect(CommercialSkipper.normalise([cb(10, 30), cb(20, 40)]) == [cb(10, 40)])
        #expect(CommercialSkipper.normalise([cb(20, 40), cb(10, 30), cb(35, 50)]) == [cb(10, 50)])
    }

    @Test func mergesAContainedBreakIntoItsContainer() {
        #expect(CommercialSkipper.normalise([cb(10, 40), cb(20, 30)]) == [cb(10, 40)])
        #expect(CommercialSkipper.normalise([cb(10, 40), cb(10, 20)]) == [cb(10, 40)])
    }

    @Test func mergesTouchingBreaks() {
        // Same contract as V35MarkupService's private normalise: touching ranges merge.
        #expect(CommercialSkipper.normalise([cb(10, 20), cb(20, 30)]) == [cb(10, 30)])
        #expect(CommercialSkipper.normalise([cb(20, 30), cb(10, 20), cb(30, 31)]) == [cb(10, 31)])
    }

    @Test func keepsBreaksSeparatedByTheSmallestGap() {
        let a = cb(s(10), s(20))
        let b = cb(s(20) + .nanoseconds(1), s(30))
        #expect(CommercialSkipper.normalise([b, a]) == [a, b])
    }

    @Test func dropsDuplicates() {
        #expect(CommercialSkipper.normalise([cb(10, 20), cb(10, 20)]) == [cb(10, 20)])
    }

    @Test func emptyListGivesEmptyList() {
        #expect(CommercialSkipper.normalise([]) == [])
    }

    /// "Drop empty / zero-length": `TimeRange` cannot hold an empty or reversed range, so such an
    /// input cannot reach `normalise` at all. The test pins that, and that the shortest range
    /// the type allows (1 ns) is kept and merges when it touches a neighbour.
    @Test func zeroLengthAndReversedRangesCannotBeConstructedAndTheShortestIsKept() {
        #expect(TimeRange(start: s(10), end: s(10)) == nil)
        #expect(TimeRange(start: s(10), end: s(9)) == nil)
        let tiny = cb(s(10), s(10) + .nanoseconds(1))
        #expect(CommercialSkipper.normalise([tiny]) == [tiny])
        #expect(CommercialSkipper.normalise([tiny, cb(s(10) + .nanoseconds(1), s(20))])
            == [cb(10, 20)])
    }

    @Test func initialiserNormalisesItsInput() {
        let skipper = skipper([cb(300, 400), cb(10, 30), cb(20, 40), cb(40, 50)])
        #expect(skipper.breaks == [cb(10, 50), cb(300, 400)])
    }
}

// MARK: - Rules

@Suite struct CommercialSkipperRuleTests {

    // R1 Armed break

    @Test func r1_armsTheFirstBreakAtPositionZeroAtInitSoABreakAtZeroIsSkipped() {
        var sut = skipper([cb(0, 60)])
        #expect(sut.tick(.zero) == [
            .seek(to: s(59)), .showSkipped(skipped: s(59), undoUntil: at(seconds: 8)),
        ])
    }

    @Test func r1_userSeekBackBeforeAPassedBreakRearmsIt() {
        var sut = skipper([cb(60, 120)])
        #expect(sut.tick(s(60)).first == .seek(to: s(119)))
        _ = sut.play(from: s(119), to: s(200))
        #expect(sut.userSeeked(to: s(30), now: at(seconds: 200)) == [])
        // Quiet period after the seek ends long before the break; the break is skipped again.
        let effects = sut.play(from: s(30), to: s(70), clockStart: s(200))
        #expect(effects.first?.position == s(60))
        #expect(effects.first?.effects.first == .seek(to: s(119)))
    }

    @Test func r1_userSeekLandingExactlyOnABreakStartArmsIt() {
        // R1 arms "the first break whose start is at or after" the position, so a seek that lands
        // exactly on a start arms that break; it is skipped once the quiet period ends (R4).
        var sut = skipper([cb(60, 120)])
        #expect(sut.userSeeked(to: s(60), now: at(seconds: 0)) == [])
        let effects = sut.play(from: s(60), to: s(70), clockStart: .zero)
        #expect(effects.count == 1)
        #expect(effects.first?.position == s(63))
        #expect(effects.first?.effects == [
            .seek(to: s(119)), .showSkipped(skipped: s(56), undoUntil: at(seconds: 11)),
        ])
    }

    // R2 Auto trigger

    @Test func r2_autoTriggerSeeksToJustBeforeTheBreakEndsAndShowsTheBanner() {
        var sut = skipper([cb(60, 120)])
        #expect(sut.tick(ms(59_750)) == [])
        // Order: the engine command first, then the banner.
        #expect(sut.tick(s(60)) == [
            .seek(to: s(119)), .showSkipped(skipped: s(59), undoUntil: at(seconds: 68)),
        ])
    }

    @Test func r2_firesWhenA250msTickStepsOverTheBreakStart() {
        // Ticks at 10.0 and 10.25 never equal the start at 10.1.
        var sut = skipper([cb(ms(10_100), s(70))])
        let effects = sut.play(from: .zero, to: s(12))
        #expect(effects.count == 1)
        #expect(effects.first?.position == ms(10_250))
        #expect(effects.first?.effects == [
            .seek(to: s(69)),
            .showSkipped(skipped: ms(58_750), undoUntil: at(ms(18_250))),
        ])
    }

    @Test func r2_skippedIsTheDistanceActuallyJumpedNotTheBreakLength() {
        var sut = skipper([cb(60, 120)])
        _ = sut.userSeeked(to: s(50), now: at(seconds: 0))   // quiet until clock 3 s
        // First tick past the quiet period is already 15 s into the break.
        #expect(sut.tick(position: s(75), duration: longFile, now: at(seconds: 25)) == [
            .seek(to: s(119)), .showSkipped(skipped: s(44), undoUntil: at(seconds: 33)),
        ])
    }

    @Test func r2_armsTheNextBreakAfterASkipSoTwoBreaksBackToBackAreBothSkipped() {
        // A 5 s station ident between two breaks: both are skipped, each with its own banner.
        var sut = skipper([cb(60, 120), cb(125, 180)])
        let effects = sut.play(from: s(59), to: s(200), clockStart: s(59))
        // Skip at 60 (clock 60) lands at 119; 125 is reached at clock 66.25.
        #expect(effects.map(\.position) == [s(60), s(125), ms(186_750)])
        #expect(effects[0].effects == [
            .seek(to: s(119)), .showSkipped(skipped: s(59), undoUntil: at(seconds: 68)),
        ])
        // The second skip happens while the first banner is up: it replaces it (no hide first).
        #expect(effects[1].effects == [
            .seek(to: s(179)), .showSkipped(skipped: s(54), undoUntil: at(ms(74_250))),
        ])
        // Only the second banner's window remains; it is hidden once, at clock 74.25.
        #expect(effects[2].effects == [.hideSkipped])
    }

    @Test func r2_breakShorterThanLandBeforeEndIsNeverSkippedBackwards() {
        // Landing point max(start, end - 1 s) = start: nothing ahead to skip, so nothing is emitted
        // and the break plays.
        var sut = skipper([cb(ms(60_000), ms(60_800)), cb(100, 160)])
        let effects = sut.play(from: s(59), to: s(101), clockStart: s(59))
        #expect(effects.map(\.position) == [s(100)])
    }

    @Test func r2_positionAlreadyInTheLandingTailIsNotSkipped() {
        var sut = skipper([cb(60, 120)])
        _ = sut.userSeeked(to: s(50), now: at(seconds: 0))
        // The first tick after the quiet period is 0.5 s before the end: past the landing point.
        #expect(sut.tick(position: ms(119_500), duration: longFile, now: at(seconds: 10)) == [])
        #expect(sut.play(from: s(120), to: s(200), clockStart: s(11)).isEmpty)
    }

    @Test func r2_tickingTwiceWithTheSameValuesDoesNotEmitTwice() {
        var sut = skipper([cb(60, 120)])
        #expect(sut.tick(s(60)).count == 2)
        #expect(sut.tick(s(60)) == [])
    }

    // R3 Seeking into a break does not skip it

    @Test func r3_seekingIntoABreakPlaysIt() {
        var sut = skipper([cb(60, 120), cb(300, 360)])
        #expect(sut.userSeeked(to: s(70), now: at(seconds: 0)) == [])
        let effects = sut.play(from: s(70), to: s(301), clockStart: .zero)
        #expect(effects.map(\.position) == [s(300)])
    }

    @Test func r3_seekingIntoABreakInPromptModeOffersNothing() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.userSeeked(to: s(70), now: at(seconds: 0))
        #expect(sut.play(from: s(70), to: s(130), clockStart: .zero).isEmpty)
    }

    // R4 Quiet period

    @Test func r4_noAutomaticSkipWithinTheQuietPeriodAfterAUserSeekThenSkipIfStillInside() {
        var sut = skipper([cb(60, 120)])
        _ = sut.userSeeked(to: s(59), now: at(seconds: 0))
        #expect(sut.tick(position: s(60), duration: longFile, now: at(seconds: 1)) == [])
        #expect(sut.tick(position: ms(61_999), duration: longFile, now: at(ms(2_999))) == [])
        // Exactly quietPeriod after the seek the quiet period is over.
        #expect(sut.tick(position: s(62), duration: longFile, now: at(seconds: 3)) == [
            .seek(to: s(119)), .showSkipped(skipped: s(57), undoUntil: at(seconds: 11)),
        ])
    }

    @Test func r4_quietPeriodAfterASkipDelaysTheSkipOfABreakStartingSoonAfterTheLanding() {
        // Documents the rule as written (see the property test): breaks 1 s apart. The first skip
        // lands at 119 at clock 60, so the quiet period runs to clock 63. The position enters the
        // second break at 121 (clock 62) and it plays until clock 63 (position 122), then is
        // skipped. The viewer sees 1 s of the second commercial.
        var sut = skipper([cb(60, 120), cb(121, 180)])
        #expect(sut.tick(position: s(60), duration: longFile, now: at(seconds: 60)).count == 2)
        let effects = sut.play(from: s(119), to: s(185), clockStart: s(60))
        #expect(effects.count == 1)
        #expect(effects.first?.position == s(122))
        #expect(effects.first?.effects == [
            .seek(to: s(179)), .showSkipped(skipped: s(57), undoUntil: at(seconds: 71)),
        ])
    }

    @Test func r4_breakPassedEntirelyDuringTheQuietPeriodIsNotSkippedAfterIt() {
        // R6 applies: the armed break was passed, so the end of the quiet period does nothing.
        var sut = skipper([cb(60, 62), cb(300, 360)])
        _ = sut.userSeeked(to: s(59), now: at(seconds: 0))
        let effects = sut.play(from: s(59), to: s(301), clockStart: .zero)
        #expect(effects.map(\.position) == [s(300)])
    }

    @Test func r4_undoStartsAQuietPeriod() {
        // Breaks P 55..<59 and B 60..<120. After a seek to 59.5 (P passed, B armed), B is skipped
        // at 63 (clock 3). Undo at clock 4 with a 10 s rewind lands at 53, quiet to clock 7, and
        // re-arms P (it starts after 53). P is entered at clock 6, inside the quiet period, and
        // is skipped at clock 7 when the quiet period ends. B is suppressed and plays.
        var sut = skipper([cb(55, 59), cb(60, 120)], undoRewind: s(10))
        _ = sut.userSeeked(to: ms(59_500), now: at(seconds: 0))
        #expect(sut.tick(position: s(63), duration: longFile, now: at(seconds: 3)).count == 2)
        #expect(sut.undo(now: at(seconds: 4)) == [.seek(to: s(53)), .hideSkipped])
        let effects = sut.play(from: s(53), to: s(130), clockStart: s(4))
        // Skip of P at clock 7 lands at 58; its banner goes at clock 15 (position 65.75, in B).
        #expect(effects.map(\.position) == [s(56), ms(65_750)])
        #expect(effects.first?.effects == [
            .seek(to: s(58)), .showSkipped(skipped: s(2), undoUntil: at(seconds: 15)),
        ])
        #expect(effects.last?.effects == [.hideSkipped])
    }

    @Test func r4_modeChangeDoesNotStartAQuietPeriod() {
        var sut = skipper([cb(60, 120)], mode: .off)
        _ = sut.tick(s(50))
        #expect(sut.setMode(.auto) == [])
        #expect(sut.tick(s(51)) == [])
        #expect(sut.tick(s(60)).first == .seek(to: s(119)))   // 9 s later; no quiet involved
        var sut2 = skipper([cb(60, 120)], mode: .off)
        #expect(sut2.setMode(.auto) == [])
        // The very next tick is inside the break exactly at its start: skipped at once.
        #expect(sut2.tick(s(60)).first == .seek(to: s(119)))
    }

    // R5 End guard

    @Test func r5_breakEndingWithinTheEndGuardIsNotSkipped() {
        // File 1000 s; break ends at 995: 995 + 10 > 1000, so it plays to the end.
        var sut = skipper([cb(900, 995)])
        #expect(sut.play(from: s(899), to: s(1000), duration: s(1000)).isEmpty)
    }

    @Test func r5_breakEndingExactlyAtTheGuardIsSkipped() {
        // 990 + 10 == 1000 is not greater than 1000.
        var sut = skipper([cb(900, 990)])
        #expect(sut.tick(s(900), duration: s(1000)).first == .seek(to: s(989)))
    }

    @Test func r5_unknownDurationMeansNoGuard() {
        var sut = skipper([cb(900, 995)])
        #expect(sut.tick(s(900), duration: nil).first == .seek(to: s(994)))
    }

    @Test func r5_guardIsEvaluatedEachTickWithTheLatestDuration() {
        // A recording still in progress grows: guarded at first, then not, while still inside.
        var sut = skipper([cb(900, 995)])
        #expect(sut.tick(s(900), duration: s(1000)) == [])
        #expect(sut.tick(s(901), duration: s(1000)) == [])
        #expect(sut.tick(s(902), duration: s(1010)).first == .seek(to: s(994)))
    }

    @Test func r5_guardedBreakIsNotOffered() {
        var sut = skipper([cb(900, 995)], mode: .prompt)
        #expect(sut.play(from: s(899), to: s(1000), duration: s(1000)).isEmpty)
    }

    @Test func r5_anOfferIsWithdrawnWhenTheBreakBecomesGuarded() {
        var sut = skipper([cb(900, 995)], mode: .prompt)
        #expect(sut.tick(s(900), duration: nil) == [.offerSkip(cb(900, 995))])
        #expect(sut.tick(s(901), duration: s(1000)) == [.withdrawOffer])
    }

    // R6 Passed breaks

    @Test func r6_aBreakJumpedPastIsArmedPastWithoutEffects() {
        var sut = skipper([cb(60, 120), cb(300, 360)])
        #expect(sut.tick(s(50)) == [])
        #expect(sut.tick(s(130)) == [])   // jumped over 60..<120 with no seek notification
        let effects = sut.play(from: s(130), to: s(301))
        #expect(effects.map(\.position) == [s(300)])
    }

    @Test func r6_jumpPastSeveralBreaksIntoAnotherSkipsThatOne() {
        var sut = skipper([cb(60, 70), cb(80, 90), cb(100, 160)])
        #expect(sut.tick(s(50)) == [])
        #expect(sut.tick(s(110), now: s(51)) == [
            .seek(to: s(159)), .showSkipped(skipped: s(49), undoUntil: at(seconds: 59)),
        ])
    }

    // R7 Undo

    @Test func r7_undoSeeksBackBeforeTheOriginHidesTheBannerAndTheBreakThenPlays() {
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(ms(60_250), now: s(60))
        // Order: the engine command first, then the banner removal.
        #expect(sut.undo(now: at(seconds: 63)) == [.seek(to: ms(58_250)), .hideSkipped])
        #expect(sut.play(from: ms(58_250), to: s(200), clockStart: s(63)).isEmpty)
    }

    @Test func r7_undoClampsTheRewindAtZero() {
        var sut = skipper([cb(1, 60)])
        #expect(sut.tick(s(1)).first == .seek(to: s(59)))
        #expect(sut.undo(now: at(seconds: 2)) == [.seek(to: .zero), .hideSkipped])
    }

    @Test func r7_tickHidesTheBannerOnceWhenTheWindowEnds() {
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(s(60))   // undoUntil = clock 68
        let effects = sut.play(from: s(119), to: s(140), clockStart: s(60))
        #expect(effects.count == 1)
        #expect(effects.first?.position == s(127))   // clock 68
        #expect(effects.first?.effects == [.hideSkipped])
    }

    @Test func r7_undoAtOrAfterTheWindowDoesNothing() {
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(s(60))
        #expect(sut.undo(now: at(seconds: 68)) == [])
        // The banner is still hidden by the next tick, exactly once.
        #expect(sut.tick(s(127), now: s(68)) == [.hideSkipped])
        #expect(sut.tick(s(128), now: s(69)) == [])
        #expect(sut.undo(now: at(seconds: 69)) == [])
    }

    @Test func r7_undoJustInsideTheWindowWorks() {
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(s(60))
        #expect(sut.undo(now: at(s(68) - .nanoseconds(1))) == [.seek(to: s(58)), .hideSkipped])
        #expect(sut.undo(now: at(s(68) - .nanoseconds(1))) == [])
    }

    @Test func r7_undoWithoutASkipDoesNothing() {
        var sut = skipper([cb(60, 120)])
        #expect(sut.undo(now: at(seconds: 1)) == [])
    }

    @Test func r7_undoAfterASecondSkipUndoesOnlyTheSecond() {
        var sut = skipper([cb(60, 120), cb(125, 180)])
        let effects = sut.play(from: s(59), to: s(126), clockStart: s(59))
        #expect(effects.map(\.position) == [s(60), s(125)])   // second skip at clock 66
        #expect(sut.undo(now: at(seconds: 67)) == [.seek(to: s(123)), .hideSkipped])
        // The second break now plays (suppressed); the first is not suppressed: a seek back
        // before it skips it again.
        #expect(sut.play(from: s(123), to: s(200), clockStart: s(67)).isEmpty)
        _ = sut.userSeeked(to: s(40), now: at(seconds: 200))
        let again = sut.play(from: s(40), to: s(200), clockStart: s(200))
        #expect(again.map(\.position) == [s(60), ms(126_750)])   // the skip, then its banner goes
        #expect(again.first?.effects.first == .seek(to: s(119)))
    }

    @Test func r7_userSeekDuringTheWindowHidesTheBannerAndEndsUndo() {
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(s(60))
        #expect(sut.userSeeked(to: s(200), now: at(seconds: 62)) == [.hideSkipped])
        #expect(sut.undo(now: at(seconds: 63)) == [])
        #expect(sut.play(from: s(200), to: s(210), clockStart: s(62)).isEmpty)   // no 2nd hide
    }

    @Test func r7_undoLandingInsideThePreviousBreakPlaysIt() {
        // Breaks 50..<59 and 60..<120. Skip of the second at 63 (after a seek to 59), rewind 5 s:
        // undo lands at 58, inside the first break, which is not armed (R1/R3) and plays.
        var sut = skipper([cb(50, 59), cb(60, 120), cb(300, 360)], undoRewind: s(5))
        _ = sut.userSeeked(to: s(59), now: at(seconds: 0))
        #expect(sut.tick(position: s(63), duration: longFile, now: at(seconds: 3)).count == 2)
        #expect(sut.undo(now: at(seconds: 4)) == [.seek(to: s(58)), .hideSkipped])
        let effects = sut.play(from: s(58), to: s(301), clockStart: s(4))
        #expect(effects.map(\.position) == [s(300)])
    }

    // R8 Suppressed breaks

    @Test(arguments: [CommercialSkipMode.auto, .prompt])
    func r8_suppressedBreakIsNeverArmedAgainInAnyMode(mode: CommercialSkipMode) {
        var sut = skipper([cb(60, 120), cb(300, 360)])
        _ = sut.tick(s(60))
        _ = sut.undo(now: at(seconds: 61))
        _ = sut.setMode(mode)
        _ = sut.userSeeked(to: s(10), now: at(seconds: 100))
        let effects = sut.play(from: s(10), to: s(301), clockStart: s(100))
        #expect(effects.map(\.position) == [s(300)])
        // The only effect is for the second break, never the first.
        for (_, list) in effects {
            #expect(!list.contains(.offerSkip(cb(60, 120))))
            #expect(!list.contains(.seek(to: s(119))))
        }
    }

    // R9 Prompt mode

    @Test func r9_offersOnceOnEnteringAndWithdrawsOnceOnLeaving() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        let effects = sut.play(from: s(59), to: s(125))
        #expect(effects.map(\.position) == [s(60), s(119)])
        #expect(effects[0].effects == [.offerSkip(cb(60, 120))])
        // Withdrawn at the landing point: after it there is nothing left to skip.
        #expect(effects[1].effects == [.withdrawOffer])
    }

    @Test func r9_offerWithdrawnWhenPlaybackJumpsPastTheBreak() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        #expect(sut.tick(s(60)) == [.offerSkip(cb(60, 120))])
        #expect(sut.tick(s(130)) == [.withdrawOffer])
        #expect(sut.tick(s(131)) == [])
    }

    @Test func r9_acceptOfferSkipsWithBannerAndUndo() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.tick(s(60))
        // Order: seek, then the offer goes, then the banner comes.
        #expect(sut.acceptOffer(position: s(70), now: at(seconds: 70)) == [
            .seek(to: s(119)), .withdrawOffer,
            .showSkipped(skipped: s(49), undoUntil: at(seconds: 78)),
        ])
        #expect(sut.tick(s(119), now: s(70)) == [])
        #expect(sut.undo(now: at(seconds: 72)) == [.seek(to: s(68)), .hideSkipped])
        // Suppressed: no offer when the position comes back into the break.
        #expect(sut.play(from: s(68), to: s(125), clockStart: s(72)).isEmpty)
    }

    @Test func r9_acceptOfferStartsAQuietPeriodButItDoesNotDelayTheNextOffer() {
        var sut = skipper([cb(60, 120), cb(120 + 1, 180)], mode: .prompt)
        _ = sut.tick(s(60))
        _ = sut.acceptOffer(position: s(60), now: at(seconds: 60))   // lands 119 at clock 60
        let effects = sut.play(from: s(119), to: s(122), clockStart: s(60))
        // Break 2 entered at 121, clock 62: inside the quiet period, offered anyway.
        #expect(effects.map(\.position) == [s(121)])
        #expect(effects.first?.effects == [.offerSkip(cb(121, 180))])
    }

    @Test func r9_quietPeriodAfterAUserSeekDoesNotDelayTheOffer() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.userSeeked(to: s(59), now: at(seconds: 0))
        #expect(sut.tick(position: s(60), duration: longFile, now: at(seconds: 1))
            == [.offerSkip(cb(60, 120))])
    }

    @Test func r9_userSeekOutOfAnOfferedBreakWithdrawsTheOffer() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.tick(s(60))
        #expect(sut.userSeeked(to: s(10), now: at(seconds: 61)) == [.withdrawOffer])
        #expect(sut.tick(s(10), now: s(61)) == [])
    }

    @Test func r9_userSeekWithinTheOfferedBreakWithdrawsItAndTheBreakPlays() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.tick(s(60))
        #expect(sut.userSeeked(to: s(90), now: at(seconds: 61)) == [.withdrawOffer])
        #expect(sut.play(from: s(90), to: s(130), clockStart: s(61)).isEmpty)
    }

    @Test func r9_acceptWithoutAnOfferDoesNothing() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        #expect(sut.acceptOffer(position: s(70), now: at(seconds: 70)) == [])
        var auto = skipper([cb(60, 120)])
        #expect(auto.acceptOffer(position: s(70), now: at(seconds: 70)) == [])
    }

    @Test func r9_acceptAfterThePositionLeftTheBreakOnlyWithdraws() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.tick(s(60))
        #expect(sut.acceptOffer(position: ms(119_500), now: at(seconds: 70)) == [.withdrawOffer])
        #expect(sut.undo(now: at(seconds: 71)) == [])
    }

    @Test func r9_promptModeNeverSkipsByItself() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        for (_, list) in sut.play(from: .zero, to: s(200)) {
            #expect(!list.contains { if case .seek = $0 { true } else { false } })
        }
    }

    // R10 Off

    @Test func r10_offModeEmitsNothingEverAndStillExposesTheBreaks() {
        var sut = skipper([cb(0, 30), cb(60, 120)], mode: .off)
        #expect(sut.breaks == [cb(0, 30), cb(60, 120)])
        #expect(sut.play(from: .zero, to: s(200)).isEmpty)
        #expect(sut.userSeeked(to: s(60), now: at(seconds: 201)) == [])
        #expect(sut.acceptOffer(position: s(61), now: at(seconds: 202)) == [])
        #expect(sut.undo(now: at(seconds: 203)) == [])
        #expect(sut.play(from: s(60), to: s(200), clockStart: s(203)).isEmpty)
    }

    // R11 Mode change

    @Test func r11_switchingToOffHidesTheBannerAtOnceAndUndoThenDoesNothing() {
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(s(60))
        #expect(sut.setMode(.off) == [.hideSkipped])
        #expect(sut.undo(now: at(seconds: 61)) == [])
        #expect(sut.play(from: s(119), to: s(200), clockStart: s(60)).isEmpty)
    }

    @Test func r11_switchingFromPromptToOffWithdrawsTheOffer() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.tick(s(60))
        #expect(sut.setMode(.off) == [.withdrawOffer])
        #expect(sut.play(from: s(61), to: s(200)).isEmpty)
    }

    @Test func r11_autoToPromptMidBreakLetsTheBreakPlay() {
        // In auto, inside an armed break during a quiet period; switching to prompt re-arms from
        // the position on the next tick (R1), so the break being played is not offered.
        var sut = skipper([cb(60, 120), cb(300, 360)])
        _ = sut.userSeeked(to: s(59), now: at(seconds: 0))
        #expect(sut.tick(position: s(60), duration: longFile, now: at(seconds: 1)) == [])
        #expect(sut.setMode(.prompt) == [])
        let effects = sut.play(from: s(61), to: s(301), clockStart: s(2))
        #expect(effects.map(\.position) == [s(300)])
        #expect(effects.first?.effects == [.offerSkip(cb(300, 360))])
    }

    @Test func r11_promptWithAnOfferShowingToAutoWithdrawsAndTheBreakPlays() {
        var sut = skipper([cb(60, 120), cb(300, 360)], mode: .prompt)
        #expect(sut.tick(s(60)) == [.offerSkip(cb(60, 120))])
        #expect(sut.setMode(.auto) == [.withdrawOffer])
        let effects = sut.play(from: s(61), to: s(301))
        #expect(effects.map(\.position) == [s(300)])
        #expect(effects.first?.effects.first == .seek(to: s(359)))
    }

    @Test func r11_autoToPromptKeepsTheBannerAndItsUndo() {
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(s(60))
        #expect(sut.setMode(.prompt) == [])
        #expect(sut.undo(now: at(seconds: 62)) == [.seek(to: s(58)), .hideSkipped])
    }

    @Test func r11_offToAutoMidBreakPlaysThatBreakAndSkipsTheNext() {
        var sut = skipper([cb(60, 120), cb(300, 360)], mode: .off)
        _ = sut.play(from: s(50), to: s(70))
        #expect(sut.setMode(.auto) == [])
        let effects = sut.play(from: ms(70_250), to: s(301))
        #expect(effects.map(\.position) == [s(300)])
    }

    @Test func r11_offToPromptBeforeABreakOffersIt() {
        var sut = skipper([cb(60, 120)], mode: .off)
        _ = sut.play(from: .zero, to: s(30))
        #expect(sut.setMode(.prompt) == [])
        let effects = sut.play(from: ms(30_250), to: s(61))
        #expect(effects.map(\.position) == [s(60)])
    }

    @Test func r11_settingTheSameModeDoesNothing() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        _ = sut.tick(s(60))
        let before = sut
        #expect(sut.setMode(.prompt) == [])
        #expect(sut == before)
    }

    @Test func r11_modeIsReadableAfterAChange() {
        var sut = skipper([cb(60, 120)])
        _ = sut.setMode(.off)
        #expect(sut.config.mode == .off)
    }
}

// MARK: - Other listed cases

@Suite struct CommercialSkipperEdgeTests {
    @Test func noBreaksMeansNoEffectsInAnyMode() {
        for mode in CommercialSkipMode.allCases {
            var sut = skipper([], mode: mode)
            #expect(sut.play(from: .zero, to: s(100)).isEmpty)
            #expect(sut.userSeeked(to: s(10), now: at(seconds: 101)) == [])
            #expect(sut.acceptOffer(position: s(10), now: at(seconds: 101)) == [])
            #expect(sut.undo(now: at(seconds: 101)) == [])
        }
    }

    @Test func backwardsTickBeforeAPassedBreakRearmsIt() {
        // The engine reports a lower position with no seek notification (an internal correction
        // or a stream restart). A break that starts at or after the new position is armed again.
        var sut = skipper([cb(60, 120)])
        _ = sut.tick(s(60))
        _ = sut.play(from: s(119), to: s(125), clockStart: s(60))
        // (The banner's window ended long ago; this tick hides it.)
        #expect(sut.tick(position: s(30), duration: longFile, now: at(seconds: 100)) == [.hideSkipped])
        let effects = sut.play(from: ms(30_250), to: s(61), clockStart: ms(100_250))
        #expect(effects.map(\.position) == [s(60)])
        #expect(effects.first?.effects.first == .seek(to: s(119)))
    }

    @Test func backwardsJitterInsideTheArmedBreakKeepsItArmed() {
        // In the quiet period after a seek to 59, the break is armed; a small backwards report
        // inside it must not disarm it (re-arming from 60.4 would arm the later break instead),
        // so it is still skipped when the quiet period ends.
        var sut = skipper([cb(60, 120), cb(300, 360)])
        _ = sut.userSeeked(to: s(59), now: at(seconds: 0))
        #expect(sut.tick(position: ms(60_500), duration: longFile, now: at(ms(1_500))) == [])
        #expect(sut.tick(position: ms(60_400), duration: longFile, now: at(ms(1_750))) == [])
        #expect(sut.tick(position: ms(61_900), duration: longFile, now: at(seconds: 3)).first
            == .seek(to: s(119)))
    }

    @Test func staleBackwardsReportsRightAfterASkipDoNotSkipAgain() {
        var sut = skipper([cb(60, 120)])
        #expect(sut.tick(position: ms(60_050), duration: longFile, now: at(seconds: 0)).count == 2)
        // The engine still reports pre-seek positions for a moment, one of them before the start.
        #expect(sut.tick(position: ms(59_900), duration: longFile, now: at(ms(250))) == [])
        #expect(sut.tick(position: ms(60_200), duration: longFile, now: at(ms(500))) == [])
        let effects = sut.play(from: s(119), to: s(140), clockStart: ms(750))
        #expect(effects.map(\.effects) == [[.hideSkipped]])
    }

    @Test func positionThatGoesBackwardsInPromptModeWithdrawsAndReoffers() {
        var sut = skipper([cb(60, 120)], mode: .prompt)
        #expect(sut.tick(s(60)) == [.offerSkip(cb(60, 120))])
        #expect(sut.tick(s(59), now: s(61)) == [.withdrawOffer])
        #expect(sut.tick(s(60), now: s(62)) == [.offerSkip(cb(60, 120))])
    }

    @Test func isEquatableAndSendable() {
        let a = skipper([cb(60, 120)])
        var b = a
        #expect(a == b)
        _ = b.tick(s(60))
        #expect(a != b)
        let sendable: any Sendable = a
        _ = sendable
    }

    @Test func configDefaultsMatchTheSpec() {
        let config = CommercialSkipConfig()
        #expect(config.mode == .auto)
        #expect(config.landBeforeEnd == .seconds(1))
        #expect(config.quietPeriod == .seconds(3))
        #expect(config.endGuard == .seconds(10))
        #expect(config.undoWindow == .seconds(8))
        #expect(config.undoRewind == .seconds(2))
    }
}
