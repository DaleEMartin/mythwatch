import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

// The manual acceptance script (TASKS "Manual acceptance", steps 4 and 5) run against the fakes:
// resume, a break arrives and is skipped with the banner, Go back returns to it and it plays
// through, a later break is still skipped; then the same recording in Skip-button mode and in Off.

private let firstBreak = cb(600, 720)
private let laterBreak = cb(1500, 1620)

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionCommercialScenarioTests {
    @Test func theManualAcceptanceStepsForCommercials() async {
        // Step 4: automatic skipping.
        let auto = await resumedAt5Minutes(.auto)
        await reachTheFirstBreak(auto)
        #expect(auto.seeks == [s(719)])  // skipped to 1 s before its end
        #expect(auto.session.banner == auto.skippedBanner(s(119)))
        await auto.play(for: s(2))
        auto.session.undoCommercialSkip()  // Go back
        await auto.engine.waitUntilDelivered()
        #expect(auto.seeks == [s(719), s(598)])
        #expect(auto.session.banner == nil)
        await auto.play(to: s(725))  // the break plays through to its end
        #expect(auto.seeks == [s(719), s(598)])
        #expect(auto.session.banner == nil)
        await reachTheLaterBreak(auto)
        #expect(auto.seeks == [s(719), s(598), s(1619)])  // still skipped
        #expect(auto.session.banner == auto.skippedBanner(s(119)))

        // Step 5: Skip-button mode.
        let prompt = await resumedAt5Minutes(.prompt)
        await reachTheFirstBreak(prompt)
        #expect(prompt.seeks.isEmpty)
        #expect(prompt.session.banner == .offer(firstBreak))
        await prompt.play(for: s(1))
        prompt.session.acceptSkipOffer()  // Skip, from 601
        await prompt.engine.waitUntilDelivered()
        #expect(prompt.seeks == [s(719)])
        #expect(prompt.session.banner == prompt.skippedBanner(s(118)))
        await prompt.play(for: s(2))
        prompt.session.undoCommercialSkip()  // Go back
        await prompt.engine.waitUntilDelivered()
        #expect(prompt.seeks == [s(719), s(599)])
        #expect(prompt.session.banner == nil)
        await prompt.play(to: s(725))  // plays through, and the Skip button does not come back
        #expect(prompt.seeks == [s(719), s(599)])
        #expect(prompt.session.banner == nil)
        await reachTheLaterBreak(prompt)
        #expect(prompt.seeks == [s(719), s(599)])  // offered, not skipped
        #expect(prompt.session.banner == .offer(laterBreak))

        // Step 5: Off.
        let off = await resumedAt5Minutes(.off)
        await reachTheFirstBreak(off)
        await off.play(to: s(725))
        await reachTheLaterBreak(off)
        await off.play(to: s(1625))
        #expect(off.seeks.isEmpty)
        #expect(off.session.banner == nil)
        #expect(off.session.breaks == [firstBreak, laterBreak])  // still on the scrubber
    }

    /// The recording resumed at 5:00, playing.
    private func resumedAt5Minutes(_ mode: CommercialSkipMode) async -> SessionRig {
        let rig = SessionRig(start: .resume, resume: s(300), breaks: [laterBreak, firstBreak],
                             settings: skipSettings(mode))
        await rig.start()
        #expect(rig.session.snapshot.status == .playing)
        #expect(rig.session.snapshot.position == s(300))
        #expect(rig.session.breaks == [firstBreak, laterBreak])
        return rig
    }

    /// Plays on to 9:59 (reported in one jump), then one more second into the break.
    private func reachTheFirstBreak(_ rig: SessionRig) async {
        rig.clock.advance(by: s(299))
        await rig.emit(.playing, at: s(599), duration: hour)
        #expect(rig.session.banner == nil)
        await rig.play(for: s(1))
    }

    private func reachTheLaterBreak(_ rig: SessionRig) async {
        rig.clock.advance(by: s(60))
        await rig.emit(.playing, at: s(1499))
        await rig.play(for: s(1))
    }
}
