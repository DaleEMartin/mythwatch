import Foundation
import MythwatchDomain
import Observation

/// The words a playback session shows the viewer, kept in one place (CLAUDE.md rule 8;
/// `UserMessage` lives in `MythwatchFeatures`, which this target cannot import). Fixed strings
/// only: an error's own text is never shown.
enum SessionLabels {
    static let breaksUnavailable = "Couldn't load the commercial breaks."
    static let resumeUnavailable =
        "Couldn't load your resume point, so this is playing from the beginning."
    static let bookmarkUnavailable =
        "Couldn't load the bookmark, so this is playing from the beginning."
    static let resumeAndBreaksUnavailable =
        "Couldn't load your resume point or the commercial breaks, so this is playing from the beginning."
    static let bookmarkAndBreaksUnavailable =
        "Couldn't load the bookmark or the commercial breaks, so this is playing from the beginning."
    static let positionNotSaved = "Couldn't save your place."
    static let bookmarkNotSet = "Couldn't set the bookmark."
    static let watchedNotSaved = "Couldn't mark this recording as watched."
}

/// One viewing of one recording (SPEC 5.2): starts the engine at the right place, saves the
/// resume position as the viewer watches, and on `finish()` decides whether the recording was
/// watched. The rules, and why, are in SPEC 5.2 "Refinements"; the short version:
///
/// - `start()` fetches the breaks and (for `.resume` / `.bookmark`) the stored position at the
///   same time, then loads and plays the engine and returns. It starts one task that reads
///   `engine.snapshots` for the session's life; `finish()` ends it, and so does `deinit`.
/// - Every snapshot goes through `handle(_:)`, the one place the session reacts to the engine
///   (M4-2 adds the commercial skipper there).
/// - Position saves are fire-and-forget and go through one queue: at most one in flight, and
///   the newest waiting position replaces an older one. `finish()` waits for the save in
///   flight, drops the waiting one, and then writes the final value itself, so nothing older
///   can land after it.
/// - The session owns its tasks. Releasing it without `finish()` ends the snapshot loop, but
///   no final save can be made from `deinit`: the player screen must call `finish()`.
@MainActor @Observable public final class PlaybackSession {
    public private(set) var snapshot: PlayerSnapshot
    /// Normalised; for the scrubber, whatever the skip mode.
    public private(set) var breaks: [CommercialBreak] = []
    /// Always nil until the skipper is wired in (M4-2).
    public private(set) var banner: SkipBanner?
    /// The newest non-fatal problem, in plain words; nil when there is none.
    public private(set) var problem: String?

    /// A seek counts as reached when the engine reports a position this close to the target.
    static let seekSettleTolerance: Duration = .seconds(2)
    /// After this much clock time the engine's own position counts again, reached or not.
    static let seekSettleTime: Duration = .seconds(3)

    private enum Phase { case new, starting, active, finishing }

    private enum ProblemKind { case start, position, bookmark, watched }

    private enum StartFetch: Sendable {
        case notNeeded, found(Duration?), failed
    }

    private struct PendingSeek {
        let target: Duration
        let at: ContinuousClock.Instant
    }

    /// What `finish()` decides from, taken before the engine is stopped.
    private struct FinalState {
        let position: Duration?
        let reachedEnd: Bool
        let watched: Bool
    }

    @ObservationIgnored private let recording: Recording
    @ObservationIgnored private let startPoint: StartPoint
    @ObservationIgnored private let engine: any PlayerEngine
    @ObservationIgnored private let state: any PlaybackStateService
    @ObservationIgnored private let markup: any MarkupService
    @ObservationIgnored private let recordings: any RecordingsService
    @ObservationIgnored private let media: any MediaLocator
    @ObservationIgnored private let settings: PlaybackSettings
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    @ObservationIgnored private var phase = Phase.new
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// The task reading `engine.snapshots`. Internal so a test can await its end.
    @ObservationIgnored private(set) var snapshotLoop: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<PlaybackOutcome, Never>?
    @ObservationIgnored private var problemKind: ProblemKind?

    // What the engine has said.
    @ObservationIgnored private var startPosition: Duration?
    @ObservationIgnored private var lastTrustedPosition: Duration?
    @ObservationIgnored private var endedSeen = false
    @ObservationIgnored private var pendingSeek: PendingSeek?

    // The save interval: clock time spent playing since the last save was sent.
    @ObservationIgnored private var playingSinceSave: Duration = .zero
    @ObservationIgnored private var lastSnapshotAt: ContinuousClock.Instant?
    @ObservationIgnored private var wasPlaying = false

    // The save queue.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The position being written now. Internal so a test can check a save was sent.
    @ObservationIgnored private(set) var saveInFlight: Duration?
    /// Final writes in `finish()` that started while a save was still in flight. Always 0; a
    /// test checks it, since the ordering cannot be observed from the fakes deterministically.
    @ObservationIgnored private(set) var finalWriteOverlaps = 0
    @ObservationIgnored private var queuedSave: Duration?
    /// The resume position this session last wrote successfully; nil before any write.
    @ObservationIgnored private var storedPosition: Duration?

    public init(
        recording: Recording, start: StartPoint, engine: any PlayerEngine,
        state: any PlaybackStateService, markup: any MarkupService,
        recordings: any RecordingsService, media: any MediaLocator,
        settings: PlaybackSettings, now: @escaping @MainActor () -> ContinuousClock.Instant
    ) {
        self.recording = recording
        self.startPoint = start
        self.engine = engine
        self.state = state
        self.markup = markup
        self.recordings = recordings
        self.media = media
        self.settings = settings
        self.now = now
        self.snapshot = engine.snapshot
    }

    deinit {
        // Only cancellation is possible here: no async write can be made from deinit.
        snapshotLoop?.cancel()
    }

    // MARK: Start

    /// Fetches the breaks and the start position at the same time, then loads the engine and
    /// tells it to play. Returns then, not when playback ends. A second call waits for the
    /// first and does nothing more; a call after `finish()` does nothing.
    public func start() async {
        if let startTask {
            await startTask.value
            return
        }
        guard phase == .new else { return }
        phase = .starting
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        let id = recording.id
        async let fetchedBreaks = Self.fetchBreaks(markup, id)
        async let fetchedStart = Self.fetchStart(startPoint, state, id)
        let (breaksResult, startResult) = await (fetchedBreaks, fetchedStart)
        guard phase == .starting else { return }  // finished while fetching

        breaks = CommercialSkipper.normalise(breaksResult ?? [])
        var startAt: Duration?
        var positionFailed = false
        switch startResult {
        case .notNeeded: break
        case .found(let position): startAt = position.flatMap { $0 > .zero ? $0 : nil }
        case .failed: positionFailed = true
        }
        if let message = Self.startProblem(
            startPoint, positionFailed: positionFailed, breaksFailed: breaksResult == nil)
        {
            report(.start, message)
        }

        startPosition = startAt
        phase = .active
        startSnapshotLoop()
        engine.load(url: media.streamURL(for: recording), startAt: startAt)
        engine.play()
    }

    nonisolated private static func fetchBreaks(
        _ markup: any MarkupService, _ id: RecordingID
    ) async -> [CommercialBreak]? {
        try? await markup.commercialBreaks(for: id)
    }

    nonisolated private static func fetchStart(
        _ start: StartPoint, _ state: any PlaybackStateService, _ id: RecordingID
    ) async -> StartFetch {
        do {
            switch start {
            case .beginning: return .notNeeded
            case .resume: return .found(try await state.resumePosition(for: id))
            case .bookmark: return .found(try await state.bookmark(for: id))
            }
        } catch {
            return .failed
        }
    }

    private static func startProblem(_ start: StartPoint, positionFailed: Bool, breaksFailed: Bool) -> String? {
        switch (positionFailed, breaksFailed, start) {
        case (false, false, _): nil
        case (false, true, _): SessionLabels.breaksUnavailable
        case (true, false, .bookmark): SessionLabels.bookmarkUnavailable
        case (true, false, _): SessionLabels.resumeUnavailable
        case (true, true, .bookmark): SessionLabels.bookmarkAndBreaksUnavailable
        case (true, true, _): SessionLabels.resumeAndBreaksUnavailable
        }
    }

    private func startSnapshotLoop() {
        let stream = engine.snapshots  // read once: a second reader would split the elements
        snapshotLoop = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.handle(snapshot)
            }
        }
    }

    // MARK: Snapshots

    /// The one place the session reacts to the engine.
    private func handle(_ new: PlayerSnapshot) {
        guard phase == .active else { return }
        let previous = snapshot
        snapshot = new
        let instant = now()

        settlePendingSeek(new, at: instant)
        if Self.isTrusted(new.status) { lastTrustedPosition = new.position }
        if new.status == .ended { endedSeen = true }
        countPlayingTime(new, at: instant)

        // M4-2: the commercial skipper ticks here, every snapshot:
        // apply(skipper.tick(position: new.position, duration: new.duration, now: instant)).

        if new.status == .paused, previous.status != .paused {
            requestSave(viewerPosition)
        } else if case .failed = new.status, !Self.isFailed(previous.status) {
            requestSave(viewerPosition)  // keep the place even though the stream dropped
        } else if new.status == .playing, playingSinceSave >= settings.saveInterval {
            requestSave(viewerPosition)
        }

        if new.status == .ended { beginFinish() }
    }

    /// Positions reported in these states are where the viewer is. `.loading` and `.idle` may
    /// report 0 or a stale value, and an engine may reset the position when it fails.
    private static func isTrusted(_ status: PlayerStatus) -> Bool {
        switch status {
        case .playing, .paused, .buffering, .ended: true
        case .idle, .loading, .failed: false
        }
    }

    private static func isFailed(_ status: PlayerStatus) -> Bool {
        if case .failed = status { true } else { false }
    }

    /// Only clock time between a `.playing` snapshot and the next snapshot counts.
    private func countPlayingTime(_ new: PlayerSnapshot, at instant: ContinuousClock.Instant) {
        if wasPlaying, let last = lastSnapshotAt, instant > last {
            playingSinceSave += last.duration(to: instant)
        }
        lastSnapshotAt = instant
        wasPlaying = new.status == .playing
    }

    private func settlePendingSeek(_ new: PlayerSnapshot, at instant: ContinuousClock.Instant) {
        guard let pending = pendingSeek else { return }
        let distance = new.position > pending.target ? new.position - pending.target : pending.target - new.position
        if distance <= Self.seekSettleTolerance || pending.at.duration(to: instant) >= Self.seekSettleTime
            || new.status == .ended
        {
            pendingSeek = nil
        }
    }

    /// Where the viewer is: a seek the engine has not reached yet, else the last trusted
    /// position the loop has handled.
    private var viewerPosition: Duration? { pendingSeek?.target ?? lastTrustedPosition }

    /// As `viewerPosition`, but also looks at the engine's current snapshot, which may be newer
    /// than the last one the loop handled. For user actions and `finish()`.
    private var viewerPositionNow: Duration? {
        if let pendingSeek { return pendingSeek.target }
        let fresh = engine.snapshot
        return Self.isTrusted(fresh.status) ? fresh.position : lastTrustedPosition
    }

    // MARK: Saving

    /// Sends a position save, or queues it behind the one in flight. Never awaited.
    private func requestSave(_ position: Duration?) {
        guard phase == .active, let position, position >= settings.minimumResumePosition else { return }
        // Skip a value the backend will already hold once everything pending has landed.
        // This does not restart the interval, so a skipped save is tried again later.
        if position == (queuedSave ?? saveInFlight ?? storedPosition) { return }
        playingSinceSave = .zero
        if saveInFlight != nil {
            queuedSave = position  // replaces any older queued value
        } else {
            sendSave(position)
        }
    }

    private func sendSave(_ position: Duration) {
        saveInFlight = position
        let state = self.state
        let id = recording.id
        saveTask = Task { [weak self] in
            let succeeded: Bool
            do {
                try await state.setResumePosition(position, for: id)
                succeeded = true
            } catch {
                succeeded = false
            }
            self?.saveEnded(position, succeeded: succeeded)
        }
    }

    private func saveEnded(_ position: Duration, succeeded: Bool) {
        saveInFlight = nil
        saveTask = nil
        if succeeded {
            storedPosition = position
            resolve(.position)
        } else {
            report(.position, SessionLabels.positionNotSaved)
        }
        // While finishing, a queued value is dropped: finish() writes the final one itself.
        guard phase == .active, let next = queuedSave else {
            queuedSave = nil
            return
        }
        queuedSave = nil
        sendSave(next)
    }

    /// Returns once no position save is in flight or queued. Internal: for `finish()` and tests.
    func waitForPendingSaves() async {
        while let task = saveTask { await task.value }
    }

    /// Returns once the snapshot loop has ended (at once if it never started). For tests.
    func waitForSnapshotLoopToEnd() async {
        await snapshotLoop?.value
    }

    // MARK: Controls

    /// Pauses when the engine is playing or about to (`.loading`, `.buffering`); plays when it
    /// is paused; otherwise does nothing.
    public func togglePlayPause() {
        guard phase == .active else { return }
        switch engine.snapshot.status {
        case .playing, .loading, .buffering: engine.pause()
        case .paused: engine.play()
        case .idle, .ended, .failed: break
        }
    }

    public func skipForward() { userSeek(to: seekBase + settings.skipForward) }

    public func skipBackward() { userSeek(to: seekBase - settings.skipBackward) }

    /// A scrub the viewer committed.
    public func seek(to position: Duration) { userSeek(to: position) }

    /// Skips start from a seek the engine has not reached yet, so rapid skips add up.
    private var seekBase: Duration { pendingSeek?.target ?? engine.snapshot.position }

    private func userSeek(to requested: Duration) {
        guard phase == .active else { return }
        var target = max(requested, .zero)
        if let duration = engine.snapshot.duration, duration > .zero { target = min(target, duration) }
        pendingSeek = PendingSeek(target: target, at: now())
        engine.seek(to: target)
        // M4-2: apply(skipper.userSeeked(to: target, now: now())) here.
    }

    /// Does nothing until the skipper is wired in (M4-2).
    public func undoCommercialSkip() {}

    /// Does nothing until the skipper is wired in (M4-2).
    public func acceptSkipOffer() {}

    /// Stores the viewer's position as the bookmark. A failure sets `problem`.
    public func setBookmarkHere() async {
        guard phase == .active, let position = viewerPositionNow else { return }
        do {
            try await state.setBookmark(position, for: recording.id)
            resolve(.bookmark)
        } catch {
            report(.bookmark, SessionLabels.bookmarkNotSet)
        }
    }

    // MARK: Finish

    /// Stops the engine, waits for a save in flight, and writes the final state: watched and
    /// cleared at or past the threshold or at the end, otherwise the position. Does the work
    /// once; every call (including concurrent ones, and the one the session makes itself when
    /// the engine reports `.ended`) returns the same outcome.
    public func finish() async -> PlaybackOutcome {
        await beginFinish().value
    }

    @discardableResult
    private func beginFinish() -> Task<PlaybackOutcome, Never> {
        if let finishTask { return finishTask }
        let task: Task<PlaybackOutcome, Never>
        if phase == .active {
            let final = finalState()  // before stop(), which may reset the position
            phase = .finishing
            snapshotLoop?.cancel()
            queuedSave = nil
            engine.stop()
            task = Task { await self.complete(final) }
        } else {
            // Not started, or still fetching: the engine was never loaded and nothing is written.
            phase = .finishing
            startTask?.cancel()
            task = Task { PlaybackOutcome(position: .zero, reachedEnd: false, markedWatched: false) }
        }
        finishTask = task
        return task
    }

    private func finalState() -> FinalState {
        let fresh = engine.snapshot
        let reachedEnd = endedSeen || fresh.status == .ended
        let position = fresh.status == .ended ? fresh.position : viewerPositionNow
        var watched = reachedEnd
        if let duration = fresh.duration ?? snapshot.duration, duration > .zero, let position,
            position >= duration * settings.watchedFraction
        {
            watched = true
        }
        return FinalState(position: position, reachedEnd: reachedEnd, watched: watched)
    }

    private func complete(_ final: FinalState) async -> PlaybackOutcome {
        await waitForPendingSaves()
        var markedWatched = false
        if final.watched {
            do {
                try await recordings.setWatched(true, id: recording.id)
                markedWatched = true
                resolve(.watched)
            } catch {
                report(.watched, SessionLabels.watchedNotSaved)
            }
        }
        if markedWatched {
            await writeFinalPosition(nil)
        } else if let position = final.position, position >= settings.minimumResumePosition,
            position != storedPosition
        {
            // Below the threshold, or the watched write failed: keep the viewer's place.
            await writeFinalPosition(position)
        }
        return PlaybackOutcome(
            position: final.position ?? startPosition ?? .zero, reachedEnd: final.reachedEnd,
            markedWatched: markedWatched)
    }

    private func writeFinalPosition(_ position: Duration?) async {
        if saveInFlight != nil { finalWriteOverlaps += 1 }
        do {
            try await state.setResumePosition(position, for: recording.id)
            storedPosition = position
            resolve(.position)
        } catch {
            report(.position, SessionLabels.positionNotSaved)
        }
    }

    // MARK: Problems

    private func report(_ kind: ProblemKind, _ message: String) {
        problemKind = kind
        problem = message
    }

    /// Clears `problem` when it came from the same kind of operation that just succeeded.
    private func resolve(_ kind: ProblemKind) {
        guard problemKind == kind else { return }
        problemKind = nil
        problem = nil
    }
}
