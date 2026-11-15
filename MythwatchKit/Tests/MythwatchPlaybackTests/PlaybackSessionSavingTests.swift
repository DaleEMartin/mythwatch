import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

private let couldNotSave = "Couldn't save your place."

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionSavingTests {
    // MARK: interval saves

    @Test func savesAfterTheSaveIntervalOfClockTimeWhilePlaying() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        await rig.play(for: s(29))
        await rig.settle()
        #expect(rig.resumeWrites.isEmpty)
        await rig.play(for: s(1))
        await rig.settle()
        #expect(rig.resumeWrites == [s(130)])
        #expect(rig.storedResume == s(130))
        // The interval starts again from that save.
        await rig.play(for: s(29))
        await rig.settle()
        #expect(rig.resumeWrites == [s(130)])
        await rig.play(for: s(1))
        await rig.settle()
        #expect(rig.resumeWrites == [s(130), s(160)])
    }

    @Test func theIntervalIsClockTimeNotMediaTime() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        // The media races ahead a minute in 20 s of clock time: not yet due.
        rig.clock.advance(by: s(20))
        await rig.emit(.playing, at: s(160))
        await rig.settle()
        #expect(rig.resumeWrites.isEmpty)
        // The media crawls 2 s in the next 10 s of clock time: now due.
        rig.clock.advance(by: s(10))
        await rig.emit(.playing, at: s(162))
        await rig.settle()
        #expect(rig.resumeWrites == [s(162)])
    }

    @Test func noIntervalSaveWhilePaused() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        await rig.play(for: s(10))
        await rig.pause()
        for i in 0..<12 {
            rig.clock.advance(by: s(10))
            // A paused engine may still report a slightly different position.
            await rig.emit(.paused, at: s(110) + ms(10 * i))
        }
        await rig.settle()
        #expect(rig.resumeWrites == [s(110)])  // the pause save only
    }

    @Test func pausedTimeDoesNotCountTowardTheInterval() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        await rig.play(for: s(10))
        await rig.pause()  // saves 110 and restarts the interval
        rig.clock.advance(by: s(120))
        await rig.emit(.paused, at: s(110))
        await rig.resume()
        await rig.play(for: s(29))
        await rig.settle()
        #expect(rig.resumeWrites == [s(110)])
        await rig.play(for: s(1))
        await rig.settle()
        #expect(rig.resumeWrites == [s(110), s(140)])
    }

    @Test func theIntervalContinuesAcrossAPauseThatSavedNothing() async {
        // A pause below the minimum saves nothing, so it does not restart the interval: playing
        // time before and after it adds up.
        let rig = SessionRig()
        await rig.playing(at: s(0))
        await rig.play(for: s(5))
        await rig.pause()
        rig.clock.advance(by: s(60))
        await rig.emit(.paused, at: s(5))
        await rig.resume()
        await rig.play(for: s(24))  // 29 s of playing in all
        await rig.settle()
        #expect(rig.resumeWrites.isEmpty)
        await rig.play(for: s(1))
        await rig.settle()
        #expect(rig.resumeWrites == [s(30)])
    }

    @Test func onlyPlayingCountsNotLoadingOrBuffering() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        await rig.play(for: s(20))
        await rig.emit(.buffering, at: s(120))
        rig.clock.advance(by: s(30))
        await rig.emit(.buffering, at: s(120))
        await rig.resume()
        await rig.play(for: s(9))
        await rig.settle()
        #expect(rig.resumeWrites.isEmpty)
        await rig.play(for: s(1))
        await rig.settle()
        #expect(rig.resumeWrites == [s(130)])
    }

    @Test func noisyPositionsDoNotCauseExtraSaves() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        // A real engine repeats positions and steps slightly backwards.
        let jitter: [Duration] = [ms(250), .zero, ms(-100), ms(250), ms(250), ms(-50)]
        var position = s(100)
        for i in 0..<240 {  // 60 s of clock time at 4 reports a second
            rig.clock.advance(by: ms(250))
            position += jitter[i % jitter.count]
            await rig.emit(.playing, at: position)
        }
        await rig.settle()
        #expect(rig.resumeWrites.count == 2)
    }

    // MARK: pause saves

    @Test func savesOnEveryTransitionToPaused() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        await rig.play(for: s(5))
        await rig.pause()
        await rig.settle()
        #expect(rig.resumeWrites == [s(105)])
        await rig.emit(.paused, at: s(105))  // still paused: not a transition
        await rig.resume()
        await rig.play(for: s(5))
        await rig.pause()
        await rig.settle()
        #expect(rig.resumeWrites == [s(105), s(110)])
        #expect(rig.storedResume == s(110))
    }

    @Test func pausingAgainAtTheSamePositionDoesNotSaveTwice() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        await rig.pause()
        await rig.resume()
        await rig.pause()
        await rig.settle()
        #expect(rig.resumeWrites == [s(100)])
    }

    // MARK: minimum

    @Test func neverSavesBelowTheMinimumAndLeavesAStoredPositionAlone() async {
        var settings = PlaybackSettings()
        settings.saveInterval = s(2)
        let rig = SessionRig(resume: s(600), settings: settings)
        await rig.playing(at: s(0))
        for _ in 0..<4 { await rig.play(for: s(2)) }  // 8 s, interval due four times
        await rig.play(for: ms(1900))  // 9.9 s
        await rig.pause()
        let outcome = await rig.finish()
        #expect(rig.resumeWrites.isEmpty)
        #expect(rig.storedResume == s(600))
        #expect(outcome == PlaybackOutcome(position: ms(9900), reachedEnd: false, markedWatched: false))
    }

    @Test func aSaveHeldBackByTheMinimumHappensWhenThePositionReachesIt() async {
        let rig = SessionRig()
        await rig.playing(at: s(0))
        await rig.play(for: s(25))
        rig.clock.advance(by: s(5))
        await rig.emit(.playing, at: s(2))  // 30 s played, but the viewer went back near the start
        await rig.play(for: s(7))  // position 9: still below the minimum
        await rig.settle()
        #expect(rig.resumeWrites.isEmpty)
        await rig.play(for: s(1))  // position 10: the overdue save goes at once
        await rig.settle()
        #expect(rig.resumeWrites == [s(10)])
    }

    // MARK: one save in flight

    @Test func onlyOneSaveInFlightAndTheNewestQueuedPositionWins() async throws {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.state.suspend(.setResumePosition)
        await rig.pause()  // 100: sent, parked
        try rig.requireSaveInFlight(s(100))
        try await rig.state.waitForParked(1)
        for position in [s(110), s(120)] {
            await rig.resume()
            await rig.emit(.playing, at: position)
            await rig.pause()  // queued; 120 replaces 110
        }
        // Snapshot handling never waited for the parked save.
        #expect(rig.session.snapshot.position == s(120))
        #expect(rig.resumeWrites == [s(100)])
        try #require(rig.state.parked.count == 1)
        rig.state.releaseAll()
        try await rig.state.waitForParked(1)
        try #require(rig.resumeWrites == [s(100), s(120)])
        rig.state.stopSuspending()
        rig.state.releaseAll()
        await rig.settle()
        #expect(rig.resumeWrites == [s(100), s(120)])
        #expect(rig.storedResume == s(120))
    }

    @Test func aQueuedSaveIsSentAfterTheInFlightOneFails() async throws {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.state.suspendNext(.setResumePosition)
        await rig.pause()
        try rig.requireSaveInFlight(s(100))
        try await rig.state.waitForParked(1)
        await rig.resume()
        await rig.emit(.playing, at: s(130))
        await rig.pause()
        rig.state.releaseAll(throwing: .timedOut)
        await rig.settle()
        #expect(rig.resumeWrites == [s(100), s(130)])
        #expect(rig.storedResume == s(130))
        #expect(rig.session.problem == nil)  // the later save succeeded
    }

    @Test func aFailedSaveSetsProblemAndPlaybackContinues() async {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.state.failNext(.rejected("DIAG"), on: .setResumePosition)
        await rig.pause()
        await rig.settle()
        #expect(rig.session.problem == couldNotSave)
        let callsBefore = rig.engine.calls.count
        await rig.resume()
        await rig.play(for: s(30))  // the next save is attempted as normal
        await rig.settle()
        #expect(rig.resumeWrites == [s(100), s(130)])
        #expect(rig.session.problem == nil)
        #expect(rig.engineCalls(after: callsBefore).isEmpty)  // nothing stopped or reloaded
        #expect(rig.session.snapshot.status == .playing)
    }

    @Test func aFailedSaveIsRetriedAtTheSamePosition() async {
        // The dedupe compares with what the backend holds, so a failed value is not skipped.
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.state.failNext(.timedOut, on: .setResumePosition)
        await rig.pause()
        await rig.settle()
        await rig.resume()
        await rig.pause()
        await rig.settle()
        #expect(rig.resumeWrites == [s(100), s(100)])
        #expect(rig.storedResume == s(100))
    }
}
