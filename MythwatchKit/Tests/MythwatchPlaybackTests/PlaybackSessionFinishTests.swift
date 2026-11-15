import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionFinishTests {
    // MARK: the watched decision

    @Test func belowTheThresholdSavesThePositionAndIsNotWatched() async {
        let rig = SessionRig()
        await rig.playing(at: s(1000), duration: hour)
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(1000), reachedEnd: false, markedWatched: false))
        #expect(rig.resumeWrites == [s(1000)])  // taken before stop reset the engine to 0
        #expect(rig.storedResume == s(1000))
        #expect(rig.recordings.calls.isEmpty)
        #expect(rig.engine.calls.last == .stop)
    }

    @Test(arguments: [950, 990, 1000])
    func atOrPastTheThresholdMarksWatchedAndClearsThePosition(_ seconds: Int) async {
        let rig = SessionRig(resume: s(400))
        await rig.playing(at: s(seconds), duration: s(1000))  // threshold 950 s
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(seconds), reachedEnd: false, markedWatched: true))
        #expect(rig.recordings.calls == [.setWatched(true, rig.id)])
        #expect(rig.resumeWrites == [nil])
        #expect(rig.storedResume == nil)
        #expect(rig.store.recording(id: rig.id)?.flags.contains(.watched) == true)
    }

    @Test func justBelowTheThresholdIsNotWatched() async {
        let rig = SessionRig()
        await rig.playing(at: ms(949_999), duration: s(1000))
        let outcome = await rig.finish()
        #expect(!outcome.markedWatched)
        #expect(rig.recordings.calls.isEmpty)
    }

    @Test(arguments: [Duration?.none, .some(.zero)])
    func anUnknownOrZeroDurationIsNeverPastTheThreshold(_ duration: Duration?) async {
        let rig = SessionRig()
        await rig.playing(at: s(5000), duration: duration)
        let outcome = await rig.finish()
        #expect(!outcome.markedWatched)
        #expect(rig.resumeWrites == [s(5000)])
    }

    @Test func endedCountsAsWatched() async {
        let rig = SessionRig()
        await rig.playing(at: s(100), duration: nil)
        await rig.emitEnded()
        let outcome = await rig.finish()
        #expect(outcome.reachedEnd)
        #expect(outcome.markedWatched)
        #expect(rig.recordings.calls == [.setWatched(true, rig.id)])
        #expect(rig.resumeWrites == [nil])
    }

    @Test func endedFinishesTheSessionWithoutTheView() async throws {
        let rig = SessionRig()
        await rig.playing(at: s(3000), duration: hour)
        rig.recordings.suspend(.setWatched)
        await rig.emitEnded()
        // Nobody called finish(): the session stopped the engine and is writing on its own.
        try #require(rig.engine.calls.last == .stop)  // (#require: otherwise the wait below hangs)
        try await rig.recordings.waitForParked(1)
        rig.recordings.releaseAll()
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: hour, reachedEnd: true, markedWatched: true))
        #expect(rig.recordings.calls == [.setWatched(true, rig.id)])
        #expect(rig.resumeWrites == [nil])
        #expect(rig.engine.calls.filter { $0 == .stop }.count == 1)
    }

    // MARK: once only

    @Test func finishTwiceDoesTheWorkOnce() async {
        let rig = SessionRig()
        await rig.playing(at: s(3500), duration: hour)
        let first = await rig.finish()
        let second = await rig.finish()
        #expect(first == second)
        #expect(rig.recordings.calls == [.setWatched(true, rig.id)])
        #expect(rig.resumeWrites == [nil])
        #expect(rig.engine.calls.filter { $0 == .stop }.count == 1)
    }

    @Test func concurrentFinishCallsShareOneFinish() async throws {
        let rig = SessionRig()
        await rig.playing(at: s(1000))
        rig.state.suspend(.setResumePosition)
        let first = Task { await rig.finish() }
        let second = Task { await rig.finish() }
        try await rig.state.waitForParked(1)
        rig.state.stopSuspending()
        rig.state.releaseAll()
        let a = await rig.value(first)
        let b = await rig.value(second)
        #expect(a == b)
        #expect(a == PlaybackOutcome(position: s(1000), reachedEnd: false, markedWatched: false))
        #expect(rig.resumeWrites == [s(1000)])
        #expect(rig.engine.calls.filter { $0 == .stop }.count == 1)
    }

    // MARK: ordering against saves in flight

    @Test func finishWhileASaveIsInFlightEndsWithTheFinalPositionStored() async throws {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.state.suspend(.setResumePosition)
        await rig.pause()  // 100 in flight, parked
        try rig.requireSaveInFlight(s(100))
        try await rig.state.waitForParked(1)
        await rig.resume()
        await rig.emit(.playing, at: s(150))
        await rig.pause()  // 150 queued
        await rig.resume()
        await rig.emit(.playing, at: s(170))
        let finishing = Task { await rig.finish() }
        try await rig.state.waitForParked(1)
        // finish() waits for the save in flight before writing anything of its own.
        try #require(rig.state.parked.map(\.call) == [.setResumePosition(s(100), rig.id)])
        rig.state.releaseAll()
        try await rig.state.waitForParked(1)
        try #require(rig.state.parked.map(\.call) == [.setResumePosition(s(170), rig.id)])
        rig.state.stopSuspending()
        rig.state.releaseAll()
        let outcome = await rig.value(finishing)
        // The queued 150 was dropped; nothing lands after the final value.
        #expect(rig.resumeWrites == [s(100), s(170)])
        #expect(rig.storedResume == s(170))
        #expect(outcome == PlaybackOutcome(position: s(170), reachedEnd: false, markedWatched: false))
        #expect(rig.session.finalWriteOverlaps == 0)  // the final write waited for the one in flight
    }

    @Test func finishAfterAFailedInFlightSaveStillWritesTheFinalPosition() async throws {
        let rig = SessionRig()
        await rig.playing(at: s(100))
        rig.state.suspendNext(.setResumePosition)
        await rig.pause()
        try rig.requireSaveInFlight(s(100))
        try await rig.state.waitForParked(1)
        await rig.resume()
        await rig.emit(.playing, at: s(170))
        let finishing = Task { await rig.finish() }
        try await rig.state.waitForParked(1)
        rig.state.releaseAll(throwing: .timedOut)
        _ = await rig.value(finishing)
        #expect(rig.resumeWrites == [s(100), s(170)])
        #expect(rig.storedResume == s(170))
        #expect(rig.session.finalWriteOverlaps == 0)
    }

    @Test func finishWhileWatchedWithASaveInFlightEndsCleared() async throws {
        let rig = SessionRig(resume: s(10))
        await rig.playing(at: s(3000), duration: hour)
        rig.state.suspendNext(.setResumePosition)
        await rig.pause()
        try rig.requireSaveInFlight(s(3000))
        try await rig.state.waitForParked(1)
        await rig.resume()
        await rig.emit(.playing, at: s(3500))
        let finishing = Task { await rig.finish() }
        try await rig.state.waitForParked(1)
        rig.state.releaseAll()
        let outcome = await rig.value(finishing)
        #expect(outcome.markedWatched)
        #expect(rig.resumeWrites == [s(3000), nil])
        #expect(rig.storedResume == nil)
        #expect(rig.session.finalWriteOverlaps == 0)
    }

    // MARK: after finish

    @Test func nothingHappensAfterFinish() async {
        let rig = SessionRig()
        await rig.playing(at: s(1000))
        _ = await rig.finish()
        let engineCalls = rig.engine.calls
        let stateCalls = rig.state.calls
        // The loop has ended, so nothing takes these (see `SessionRig.endStream()`).
        for i in 1...4 {
            rig.clock.advance(by: s(30))
            var snapshot = rig.engine.snapshot
            snapshot.status = i.isMultiple(of: 2) ? .paused : .playing
            snapshot.position = s(1000 + 30 * i)
            rig.engine.emit(snapshot)
        }
        await rig.endStream()
        await rig.settle()
        rig.session.togglePlayPause()
        rig.session.skipForward()
        rig.session.skipBackward()
        rig.session.seek(to: s(10))
        await rig.session.setBookmarkHere()
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == engineCalls)
        #expect(rig.state.calls == stateCalls)
        #expect(rig.recordings.calls.isEmpty)
    }

    @Test func finishBeforeStartWritesNothing() async {
        let rig = SessionRig(start: .resume, resume: s(600))
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: .zero, reachedEnd: false, markedWatched: false))
        await rig.guarded { await rig.session.start() }  // too late: the session is over
        #expect(rig.engine.calls.isEmpty)
        #expect(rig.state.calls.isEmpty)
        #expect(rig.markup.calls.isEmpty)
        #expect(rig.recordings.calls.isEmpty)
    }

    @Test func finishWhileStartingNeverLoadsTheEngine() async throws {
        let rig = SessionRig(start: .resume, resume: s(600))
        rig.markup.suspend()
        let starting = Task { await rig.session.start() }
        try await rig.markup.waitForParked(1)
        let outcome = await rig.finish()
        rig.markup.releaseAll()
        await rig.value(starting)
        #expect(outcome == PlaybackOutcome(position: .zero, reachedEnd: false, markedWatched: false))
        #expect(rig.engine.calls.isEmpty)
        #expect(rig.resumeWrites.isEmpty)
    }

    @Test func finishBeforeTheEngineReportsAPositionWritesNothing() async {
        let rig = SessionRig(start: .resume, resume: s(600), automaticResponses: false)
        await rig.start()
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(600), reachedEnd: false, markedWatched: false))
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: s(600)), .play, .stop])
        #expect(rig.resumeWrites.isEmpty)
        #expect(rig.storedResume == s(600))
    }

    // MARK: failed writes in finish

    @Test func aFailedWatchedWriteKeepsTheViewersPlace() async {
        let rig = SessionRig(resume: s(10))
        await rig.playing(at: s(3500), duration: hour)
        rig.recordings.failNext(.rejected("DIAG"))
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(3500), reachedEnd: false, markedWatched: false))
        #expect(rig.resumeWrites == [s(3500)])  // not cleared: the place is kept instead
        #expect(rig.storedResume == s(3500))
        #expect(rig.session.problem == "Couldn't mark this recording as watched.")
    }

    @Test func aFailedClearStillReportsWatched() async {
        let rig = SessionRig(resume: s(10))
        await rig.playing(at: s(3500), duration: hour)
        rig.state.failNext(.timedOut, on: .setResumePosition)
        let outcome = await rig.finish()
        #expect(outcome.markedWatched)
        #expect(rig.resumeWrites == [nil])
        #expect(rig.session.problem == "Couldn't save your place.")
    }

    @Test func aFailedFinalSaveStillReturnsAndSaysSo() async {
        let rig = SessionRig()
        await rig.playing(at: s(1000))
        rig.state.failNext(.timedOut, on: .setResumePosition)
        let outcome = await rig.finish()
        #expect(outcome == PlaybackOutcome(position: s(1000), reachedEnd: false, markedWatched: false))
        #expect(rig.session.problem == "Couldn't save your place.")
    }

    @Test func finishTakesTheEnginesNewestPositionBeforeStopping() async {
        // The loop has not handled the newest snapshot yet when finish() is called; the final
        // position is read from the engine before stop() resets it.
        let rig = SessionRig()
        await rig.playing(at: s(900))
        rig.engine.emit(PlayerSnapshot(status: .playing, position: s(1000), duration: hour, rate: 1))
        let outcome = await rig.finish()
        #expect(outcome.position == s(1000))
        #expect(rig.resumeWrites == [s(1000)])
    }

    @Test func finishDoesNotRewriteAPositionAlreadyStored() async {
        let rig = SessionRig()
        await rig.playing(at: s(1000))
        await rig.pause()
        await rig.settle()
        _ = await rig.finish()
        #expect(rig.resumeWrites == [s(1000)])
    }
}
