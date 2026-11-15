import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

private func seeks(_ calls: [FakePlayerEngine.Call]) -> [Duration] {
    calls.compactMap { if case .seek(let to) = $0 { to } else { nil } }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionSeekingTests {
    @Test func skipForwardAndBackUseTheSettings() async {
        var settings = PlaybackSettings()
        settings.skipForward = s(45)
        settings.skipBackward = s(15)
        let rig = SessionRig(settings: settings)
        await rig.playing(at: s(100))
        rig.session.skipForward()
        await rig.engine.waitUntilDelivered()
        rig.session.skipBackward()
        await rig.engine.waitUntilDelivered()
        #expect(seeks(rig.engine.calls) == [s(145), s(130)])
    }

    @Test func seekGoesWhereTheViewerChose() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.session.seek(to: s(1234))
        #expect(seeks(rig.engine.calls) == [s(1234)])
    }

    @Test func skipsAreClampedAtZero() async {
        let rig = SessionRig()
        await rig.playing(at: s(4))
        rig.session.skipBackward()
        rig.session.seek(to: s(-5))
        #expect(seeks(rig.engine.calls) == [.zero, .zero])
    }

    @Test func skipsAndSeeksAreClampedAtTheDuration() async {
        let rig = SessionRig()
        await rig.playing(at: s(3590), duration: hour)
        rig.session.skipForward()
        rig.session.seek(to: s(5000))
        #expect(seeks(rig.engine.calls) == [hour, hour])
    }

    @Test func withUnknownDurationOnlyZeroClamps() async {
        let rig = SessionRig()
        await rig.playing(at: s(100), duration: nil)
        rig.session.seek(to: s(99_999))
        rig.session.seek(to: s(3))
        rig.session.skipBackward()
        #expect(seeks(rig.engine.calls) == [s(99_999), s(3), .zero])
    }

    @Test func rapidSkipsAccumulateWhenTheEngineMovesAtOnce() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.session.skipForward()
        rig.session.skipForward()
        #expect(seeks(rig.engine.calls) == [s(130), s(160)])
    }

    @Test func rapidSkipsAccumulateBeforeTheEngineReportsANewPosition() async {
        let rig = SessionRig(automaticResponses: false)
        await rig.playing(at: s(100))
        rig.session.skipForward()
        rig.session.skipForward()
        rig.session.skipBackward()
        #expect(seeks(rig.engine.calls) == [s(130), s(160), s(150)])
    }

    // MARK: stale positions after a seek

    @Test func aStalePositionAfterASeekIsNotSavedOnPause() async {
        let rig = SessionRig(automaticResponses: false)
        await rig.playing(at: s(100))
        rig.session.skipForward()
        await rig.emit(.playing, at: ms(100_250))  // stale: from before the seek
        await rig.emit(.paused, at: ms(100_300))  // still stale
        await rig.settle()
        #expect(rig.resumeWrites == [s(130)])
        // A skip from here starts at the target, not the stale position.
        rig.session.skipForward()
        #expect(seeks(rig.engine.calls) == [s(130), s(160)])
    }

    @Test func aStalePositionAfterASeekIsNotSavedByTheInterval() async {
        let rig = SessionRig(automaticResponses: false)
        await rig.playing(at: s(600))
        rig.clock.advance(by: s(29))
        await rig.emit(.playing, at: s(629))
        rig.session.skipBackward()  // to 619
        rig.clock.advance(by: s(1))
        await rig.emit(.playing, at: ms(629_250))  // stale; the interval is due now
        await rig.settle()
        #expect(rig.resumeWrites == [s(619)])
    }

    @Test func theEnginesPositionIsTrustedAgainOnceItReachesTheTarget() async {
        let rig = SessionRig(automaticResponses: false)
        await rig.playing(at: s(100))
        rig.session.skipForward()  // to 130
        await rig.emit(.playing, at: ms(131_500))  // landed near the target (keyframe)
        await rig.emit(.playing, at: s(133))
        await rig.emit(.paused, at: s(133))
        await rig.settle()
        #expect(rig.resumeWrites == [s(133)])
        rig.session.skipForward()
        #expect(seeks(rig.engine.calls) == [s(130), s(163)])
    }

    @Test func theTargetIsTrustedOnlyForTheSettleTime() async {
        // An engine that ignores a seek: after the settle time its own position counts again.
        let rig = SessionRig(automaticResponses: false)
        await rig.playing(at: s(100))
        rig.session.skipForward()  // to 130
        rig.clock.advance(by: PlaybackSession.seekSettleTime)
        await rig.emit(.playing, at: s(103))
        await rig.emit(.paused, at: s(103))
        await rig.settle()
        #expect(rig.resumeWrites == [s(103)])
    }

    @Test func seekingBeforeStartDoesNothing() async {
        let rig = SessionRig()
        rig.session.skipForward()
        rig.session.skipBackward()
        rig.session.seek(to: s(100))
        #expect(rig.engine.calls.isEmpty)
    }
}
