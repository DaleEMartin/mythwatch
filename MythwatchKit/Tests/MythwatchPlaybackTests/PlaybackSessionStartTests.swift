import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PlaybackSessionStartTests {
    // MARK: each start point loads the engine at the right place

    @Test func beginningLoadsFromTheStartWithoutFetchingAPosition() async {
        let rig = SessionRig(start: .beginning, resume: s(600), bookmark: s(1200))
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: nil), .play])
        #expect(rig.state.calls.isEmpty)
        #expect(rig.markup.calls == [.commercialBreaks(rig.id)])
        #expect(rig.media.calls == [.streamURL(rig.id)])
        #expect(rig.session.problem == nil)
    }

    @Test func resumeLoadsAtTheStoredResumePosition() async {
        let rig = SessionRig(start: .resume, resume: s(600), bookmark: s(1200))
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: s(600)), .play])
        #expect(rig.state.calls == [.resumePosition(rig.id)])
        #expect(rig.session.problem == nil)
    }

    @Test func bookmarkLoadsAtTheStoredBookmark() async {
        let rig = SessionRig(start: .bookmark, resume: s(600), bookmark: s(1200))
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: s(1200)), .play])
        #expect(rig.state.calls == [.bookmark(rig.id)])
        #expect(rig.session.problem == nil)
    }

    @Test(arguments: [StartPoint.resume, .bookmark])
    func aStartPointWithNothingStoredPlaysFromTheBeginningQuietly(_ start: StartPoint) async {
        let rig = SessionRig(start: start)
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: nil), .play])
        #expect(rig.session.problem == nil)
    }

    @Test func startReturnsOnceTheEngineIsToldToPlayAndTheSnapshotIsTracked() async {
        let rig = SessionRig(start: .resume, resume: s(600))
        await rig.start()
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: s(600)), .play])
        #expect(rig.session.snapshot.status == .playing)
        #expect(rig.session.snapshot.position == s(600))
    }

    // MARK: concurrency

    @Test(arguments: [StartPoint.resume, .bookmark])
    func positionAndBreaksAreFetchedConcurrently(_ start: StartPoint) async throws {
        let rig = SessionRig(start: start, resume: s(600), bookmark: s(1200), breaks: [cb(60, 120)])
        rig.state.suspend()
        rig.markup.suspend()
        let starting = Task { await rig.session.start() }
        // Both calls are parked at the same time: neither waited for the other.
        try await rig.state.waitForParked(1)
        try await rig.markup.waitForParked(1)
        #expect(rig.engine.calls.isEmpty)
        rig.state.releaseAll()
        rig.markup.releaseAll()
        await rig.value(starting)
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: start == .resume ? s(600) : s(1200)), .play])
        #expect(rig.session.breaks == [cb(60, 120)])
    }

    @Test func startCalledTwiceDoesTheWorkOnce() async throws {
        let rig = SessionRig(start: .resume, resume: s(600))
        rig.markup.suspend()
        let first = Task { await rig.session.start() }
        try await rig.markup.waitForParked(1)
        // The second call returns only once the first has loaded the engine.
        let second = Task { () -> [FakePlayerEngine.Call] in
            await rig.session.start()
            return rig.engine.calls
        }
        rig.markup.releaseAll()
        await rig.value(first)
        let callsWhenSecondReturned = await rig.value(second)
        #expect(callsWhenSecondReturned == [.load(url: sessionStreamURL, startAt: s(600)), .play])
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: s(600)), .play])
        #expect(rig.state.calls == [.resumePosition(rig.id)])
        #expect(rig.markup.calls == [.commercialBreaks(rig.id)])
        #expect(rig.media.calls == [.streamURL(rig.id)])
    }

    // MARK: breaks

    @Test func breaksAreExposedNormalisedForTheScrubber() async {
        let rig = SessionRig(breaks: [cb(600, 700), cb(60, 120), cb(110, 180)])
        await rig.guarded { await rig.session.start() }
        #expect(rig.session.breaks == [cb(60, 180), cb(600, 700)])
    }

    @Test func noBannerAndNoSkippingWithoutTheSkipper() async {
        let rig = SessionRig(breaks: [cb(0, 120)])
        await rig.playing(at: s(30))
        rig.session.acceptSkipOffer()
        rig.session.undoCommercialSkip()
        await rig.play(for: s(1))
        #expect(rig.session.banner == nil)
        #expect(!rig.engine.calls.contains { if case .seek = $0 { true } else { false } })
    }

    // MARK: failures

    @Test func aFailedBreaksFetchStillPlaysAndSetsProblem() async {
        let rig = SessionRig(start: .resume, resume: s(600), breaks: [cb(60, 120)])
        rig.markup.failNext(.rejected("DIAG-BREAKS"))
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: s(600)), .play])
        #expect(rig.session.breaks.isEmpty)
        #expect(rig.session.problem == "Couldn't load the commercial breaks.")
    }

    @Test func aFailedResumeFetchPlaysFromTheBeginningAndSetsProblem() async {
        let rig = SessionRig(start: .resume, resume: s(600), breaks: [cb(60, 120)])
        rig.state.failNext(.timedOut)
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: nil), .play])
        #expect(rig.session.breaks == [cb(60, 120)])
        #expect(rig.session.problem == "Couldn't load your resume point, so this is playing from the beginning.")
    }

    @Test func aFailedBookmarkFetchPlaysFromTheBeginningAndSetsProblem() async {
        let rig = SessionRig(start: .bookmark, bookmark: s(1200))
        rig.state.failNext(.unreachable("DIAG"))
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: nil), .play])
        #expect(rig.session.problem == "Couldn't load the bookmark, so this is playing from the beginning.")
    }

    @Test(arguments: [
        (StartPoint.resume, "Couldn't load your resume point or the commercial breaks, so this is playing from the beginning."),
        (StartPoint.bookmark, "Couldn't load the bookmark or the commercial breaks, so this is playing from the beginning."),
    ])
    func bothFetchesFailingStillPlays(_ start: StartPoint, _ message: String) async {
        let rig = SessionRig(start: start, resume: s(600), bookmark: s(1200), breaks: [cb(60, 120)])
        rig.state.failNext(.http(status: 500, message: "DIAG"))
        rig.markup.failNext(.malformedResponse("DIAG"))
        await rig.guarded { await rig.session.start() }
        #expect(rig.engine.calls == [.load(url: sessionStreamURL, startAt: nil), .play])
        #expect(rig.session.breaks.isEmpty)
        #expect(rig.session.problem == message)
    }

    @Test func aStartProblemNeverShowsTheErrorText() async {
        let rig = SessionRig(start: .resume, resume: s(600))
        rig.state.failNext(.rejected("DIAG-SECRET"))
        rig.markup.failNext(.http(status: 503, message: "DIAG-SECRET"))
        await rig.guarded { await rig.session.start() }
        let problem = rig.session.problem ?? ""
        #expect(!problem.isEmpty)
        #expect(!problem.contains("DIAG"))
        #expect(!problem.contains("503"))
    }
}
