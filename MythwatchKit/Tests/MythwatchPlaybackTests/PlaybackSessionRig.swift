import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

@testable import MythwatchPlayback

// Shared set-up for the `PlaybackSession` suites (M3-2).
//
// Determinism: time moves only through `clock.advance(by:)`; the engine moves only through the
// fake's emitters; after every emission the rig awaits `engine.waitUntilDelivered()` before
// anything is asserted; service calls are held open only with the fakes' suspension points; and
// "no save work pending" is the session's internal `waitForPendingSaves()`.
//
// Each suite carries `.timeLimit(.minutes(1))`. A correct session never comes near it (the whole
// package runs in about a second); it only turns a deadlock in a broken session (for example
// fetching the start position and the breaks one after the other, which the concurrency test
// waits on) into a failure instead of a hung run. Nothing in the code under test reads real time.

let sessionRecordingID = RecordingID(rawValue: 7)
let sessionStreamURL = URL(string: "http://fake-backend:6544/fake/stream/7")!
let hour: Duration = .seconds(3600)

@MainActor final class SessionRig {
    let recording: Recording
    let store = FakeBackendStore()
    let state: FakePlaybackStateService
    let markup: FakeMarkupService
    let recordings: FakeRecordingsService
    let media = FakeMediaLocator()
    let engine = FakePlayerEngine()
    let clock: TestClock
    let settings: PlaybackSettings
    let session: PlaybackSession

    init(
        start: StartPoint = .beginning, resume: Duration? = nil, bookmark: Duration? = nil,
        breaks: [CommercialBreak] = [], settings: PlaybackSettings = PlaybackSettings(),
        automaticResponses: Bool = true
    ) {
        recording = .fixture(id: sessionRecordingID)
        store.add(recording, resumePosition: resume, bookmark: bookmark, commercialBreaks: breaks)
        state = FakePlaybackStateService(store: store)
        markup = FakeMarkupService(store: store)
        recordings = FakeRecordingsService(store: store)
        engine.automaticResponses = automaticResponses
        self.settings = settings
        let clock = TestClock()
        self.clock = clock
        session = PlaybackSession(
            recording: recording, start: start, engine: engine, state: state, markup: markup,
            recordings: recordings, media: media, settings: settings, now: clock.now)
    }

    var id: RecordingID { recording.id }

    /// Starts the session and waits until it has handled whatever the engine emitted.
    func start() async {
        await guarded { await self.session.start() }
        await engine.waitUntilDelivered()
    }

    /// `session.finish()`, guarded (see `guarded(_:)`).
    func finish() async -> PlaybackOutcome { await guarded { await self.session.finish() } }

    /// The value of a task the test started, guarded (see `guarded(_:)`).
    func value<T: Sendable>(_ task: Task<T, Never>) async -> T { await guarded { await task.value } }

    /// Runs `body`, and if the test is cancelled (its time limit) while it waits, stops every
    /// fake's suspension and releases every parked call, failing it.
    ///
    /// The session's work runs in unstructured tasks, and awaiting one is not ended by
    /// cancelling the waiter. Without this, a broken session whose write is parked behind a
    /// `suspend` nobody releases would hang the whole run (seen in the mutation check: a queued
    /// save landing after `finish()` left the final write parked and the run waited for ever).
    func guarded<T: Sendable>(_ body: () async -> T) async -> T {
        let state = self.state, markup = self.markup, recordings = self.recordings
        return await withTaskCancellationHandler {
            await body()
        } onCancel: {
            state.stopSuspending()
            markup.stopSuspending()
            recordings.stopSuspending()
            state.releaseAll(throwing: .timedOut)
            markup.releaseAll(throwing: .timedOut)
            recordings.releaseAll(throwing: .timedOut)
        }
    }

    /// Started from the beginning and now playing at `position`.
    func playing(at position: Duration, duration: Duration? = hour) async {
        await start()
        await emit(.playing, at: position, duration: duration)
    }

    /// Emits a snapshot with this status and position (duration kept unless given) and waits for
    /// the session to handle it.
    func emit(_ status: PlayerStatus, at position: Duration, duration: Duration?? = nil) async {
        var s = engine.snapshot
        s.status = status
        s.position = position
        if let duration { s.duration = duration }
        s.rate = status == .playing ? 1 : 0
        engine.emit(s)
        if status == .ended { await endStream() } else { await engine.waitUntilDelivered() }
    }

    /// The engine reports the end of the file, and the rig waits until the session has handled it.
    func emitEnded() async {
        engine.emitEnded()
        await endStream()
    }

    /// Ends the engine's stream and returns once the session's snapshot loop has ended.
    ///
    /// Used instead of `waitUntilDelivered()` once the session may have stopped reading: on
    /// `.ended` the session finishes itself and cancels its own loop, and a cancelled
    /// `AsyncStream(unfolding:)` consumer never asks the fake for another element, so
    /// `waitUntilDelivered()` would wait for ever. Ending the stream lets a loop that is (wrongly)
    /// still running drain what was emitted and stop, so a broken session fails the test
    /// instead of hanging it.
    func endStream() async {
        engine.finish()
        await guarded { await self.session.waitForSnapshotLoopToEnd() }
    }

    /// Moves the clock and (while playing) the position on together, then waits for the session.
    func play(for d: Duration) async {
        clock.advance(by: d)
        engine.advancePlayback(by: d)
        await engine.waitUntilDelivered()
    }

    /// The engine reports a pause at the current position.
    func pause() async { await emit(.paused, at: engine.snapshot.position) }

    /// The engine reports playing again at the current position.
    func resume() async { await emit(.playing, at: engine.snapshot.position) }

    /// Every `setResumePosition` value sent, in order (nil = a clear).
    var resumeWrites: [Duration?] {
        var out: [Duration?] = []
        for call in state.calls {
            if case .setResumePosition(let p, _) = call { out.append(p) }
        }
        return out
    }

    var storedResume: Duration? { store.resumePosition(for: id) }

    /// Fails the test at once unless the session has a position save in flight, so a test never
    /// waits for a save to park that was never sent.
    func requireSaveInFlight(_ position: Duration, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try #require(session.saveInFlight == position, sourceLocation: sourceLocation)
    }

    /// Returns once the session has no position save in flight or queued.
    func settle() async { await guarded { await self.session.waitForPendingSaves() } }

    /// The engine calls made after the first `count`.
    func engineCalls(after count: Int) -> [FakePlayerEngine.Call] { Array(engine.calls.dropFirst(count)) }
}
