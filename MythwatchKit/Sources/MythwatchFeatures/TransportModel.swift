import Foundation
import MythwatchDomain
import MythwatchPlayback
import Observation

/// The player screen's model (SPEC 6.4 "Transport rules"): what the controls show and what each
/// intent does, over one `PlaybackSession`. The view maps remote input to these intents and draws
/// the state; it decides nothing.
///
/// Time comes only from the injected `now`. There is no timer: the screen calls `tick()` when the
/// session's snapshot changes and when `hideAt` passes.
@MainActor @Observable public final class TransportModel {
    /// The tabs of the panel that a swipe down opens.
    public enum Panel: String, Sendable, CaseIterable, Identifiable {
        case info, audio, subtitles
        public var id: String { rawValue }
    }

    /// What Back (Menu) did: something inside the player, or nothing left, so leave the player.
    public enum BackResult: Sendable, Equatable { case handled, leave }

    /// No input for this long while playing hides the controls.
    public static let hideAfter: Duration = .seconds(5)
    /// A full swipe across the touch surface moves this share of the recording, ...
    static let scrubShare = 0.2
    /// ... but at least this much.
    static let minimumScrubSpan: Duration = .seconds(60)
    /// A full swipe when the duration is unknown.
    static let unknownDurationScrubSpan: Duration = .seconds(600)
    /// A paused scrub that rests this long moves the video there, so its frame shows.
    public static let scrubPreviewDelay: Duration = .milliseconds(400)

    public let session: PlaybackSession
    public let recording: Recording

    /// Whether the transport bar is on screen.
    public private(set) var controlsVisible = true
    /// When the controls will hide if nothing happens; nil when they will not (not playing,
    /// scrubbing, the panel open, or already hidden). The screen calls `tick()` at that moment.
    public private(set) var hideAt: ContinuousClock.Instant?
    /// The open panel tab, or nil.
    public private(set) var panel: Panel?
    /// The previewed position while scrubbing; nil when not scrubbing.
    public private(set) var scrubPosition: Duration?
    /// When the resting scrub will move the video to `scrubPosition` so its frame shows; nil when
    /// nothing is due. The screen calls `tick()` then.
    public private(set) var scrubPreviewAt: ContinuousClock.Instant?

    /// Read from the session when the panel opens and after each selection.
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var selectedAudioTrack: MediaTrack.ID?
    /// nil = subtitles off.
    public private(set) var selectedSubtitleTrack: MediaTrack.ID?

    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var lastInput: ContinuousClock.Instant
    /// Where the video was when the scrub began, to put it back on a cancel.
    @ObservationIgnored private var scrubOrigin: Duration?
    /// The scrub position the video was last moved to by a preview; nil if none yet.
    @ObservationIgnored private var previewed: Duration?
    /// When the session was last seen to start playing; nil while it is not playing.
    @ObservationIgnored private var playingSince: ContinuousClock.Instant?
    /// The `undoUntil` of a skipped banner this model's clock has passed. Observed, so the
    /// screen redraws when `tick()` hides the banner.
    private var expiredUndoUntil: ContinuousClock.Instant?

    public init(
        session: PlaybackSession, recording: Recording,
        now: @escaping @MainActor () -> ContinuousClock.Instant
    ) {
        self.session = session
        self.recording = recording
        self.now = now
        lastInput = now()
        status = session.snapshot.status
    }

    // MARK: State for the screen

    /// The session's status as of the last `tick()`. Kept here, not read from the snapshot, so
    /// that the screen around the panel is not redrawn on every position update while playing.
    public private(set) var status: PlayerStatus

    public var isPlaying: Bool { status == .playing }
    /// Loading or buffering: the screen shows a spinner.
    public var isWaiting: Bool { [.loading, .buffering].contains(status) }
    /// The recording played to its end; the screen closes.
    public var hasEnded: Bool { status == .ended }
    /// What to show when the engine failed, with Try Again and Close.
    public var failure: UserMessage? {
        if case .failed = status { return .playbackFailed }
        return nil
    }
    /// The session's newest non-fatal problem, already plain words.
    public var notice: String? { session.problem }

    // MARK: Commercials (M4-3)

    /// What the commercial banner shows. The words are the screen's (`Labels`).
    public enum CommercialBanner: Sendable, Equatable {
        /// Commercials were skipped by this distance; Select goes back.
        case skipped(Duration)
        /// Prompt mode: playback is in a break; Select skips it.
        case offer
    }

    /// The banner to show, or nil. A skipped banner goes when this model's clock reaches its
    /// `undoUntil`, even if the session still holds it (no ticks reach the session while paused).
    public var commercialBanner: CommercialBanner? {
        switch session.banner {
        case .skipped(let distance, let undoUntil):
            return undoUntil == expiredUndoUntil || now() >= undoUntil ? nil : .skipped(distance)
        case .offer: return .offer
        case nil: return nil
        }
    }

    /// When the skipped banner will go; nil when none is showing. The screen calls `tick()` then.
    public var bannerHidesAt: ContinuousClock.Instant? {
        guard case .skipped(_, let undoUntil) = session.banner, commercialBanner != nil else { return nil }
        return undoUntil
    }

    /// The breaks as shares of the duration (0...1) for the scrubber, in every mode; cut at the
    /// duration, and empty without one.
    public var breakSegments: [ClosedRange<Double>] {
        guard let duration else { return [] }
        let total = Self.seconds(duration)
        return session.breaks.compactMap { b in
            guard b.start < duration else { return nil }
            return (Self.seconds(b.start) / total)...(Self.seconds(min(b.end, duration)) / total)
        }
    }

    /// The scrub preview while scrubbing, else where the video is.
    public var position: Duration { scrubPosition ?? session.snapshot.position }
    /// Known and above zero, else nil.
    public var duration: Duration? {
        guard let d = session.snapshot.duration, d > .zero else { return nil }
        return d
    }
    /// `position` as a share of `duration`, 0...1; nil without a duration.
    public var progress: Double? {
        guard let duration else { return nil }
        return min(1, max(0, Self.seconds(position) / Self.seconds(duration)))
    }
    /// "12:34" or "1:02:03", rounded down.
    public var elapsedText: String { Self.timeText(position) }
    /// "-1:15:46", rounded up so it adds up with `elapsedText`; nil without a duration.
    public var remainingText: String? {
        guard let duration else { return nil }
        let left = max(.zero, duration - position)
        let whole = Duration.seconds(left.components.seconds)
        return "-" + Self.timeText(left > whole ? whole + .seconds(1) : whole)
    }

    /// "m:ss" under an hour, else "h:mm:ss". Whole seconds, rounded down.
    public static func timeText(_ d: Duration) -> String { EpisodeLabels.clock(d) }

    // MARK: Time

    /// Notes whether the session is playing, and hides the controls once `hideAt` has passed.
    /// Call it when the session's snapshot changes and when `hideAt` arrives.
    public func tick() {
        if status != session.snapshot.status { status = session.snapshot.status }
        if let at = scrubPreviewAt, now() >= at, let target = scrubPosition {
            scrubPreviewAt = nil
            if previewed != target {
                previewed = target
                session.seek(to: target)
            }
        }
        if case .skipped(_, let undoUntil) = session.banner, now() >= undoUntil, expiredUndoUntil != undoUntil {
            expiredUndoUntil = undoUntil
        }
        if isPlaying {
            if playingSince == nil { playingSince = now() }
            if let hideAt, now() >= hideAt { controlsVisible = false }
        } else {
            playingSince = nil
            controlsVisible = true
        }
        updateHideAt()
    }

    /// Shows the controls and restarts the wait; every intent does this.
    public func showControls() {
        lastInput = now()
        controlsVisible = true
        updateHideAt()
    }

    private func updateHideAt() {
        guard controlsVisible, scrubPosition == nil, panel == nil, let playingSince else {
            hideAt = nil
            return
        }
        hideAt = max(lastInput, playingSince) + Self.hideAfter
    }

    // MARK: Intents

    /// Click: commits a scrub, else acts on the commercial banner (Go back, or Skip), else plays
    /// or pauses.
    public func select() {
        if scrubPosition != nil {
            commitScrub()
            return
        }
        switch commercialBanner {
        case .skipped: goBack()
        case .offer: skipCommercials()
        case nil: playPause()
        }
    }

    /// Undoes the last commercial skip. After the banner has gone it only clears the session's.
    public func goBack() {
        session.undoCommercialSkip()
        showControls()
    }

    /// Prompt mode: skips the break on offer.
    public func skipCommercials() {
        session.acceptSkipOffer()
        showControls()
    }

    /// Play/Pause: commits a scrub first, then plays or pauses.
    public func playPause() {
        if scrubPosition != nil { commitScrub() }
        session.togglePlayPause()
        showControls()
    }

    /// Plays if paused; otherwise nothing (a remote command, not a toggle).
    public func play() {
        if session.engine.snapshot.status == .paused { session.togglePlayPause() }
        showControls()
    }

    /// Pauses if playing or about to; otherwise nothing.
    public func pause() {
        if [.playing, .loading, .buffering].contains(session.engine.snapshot.status) { session.togglePlayPause() }
        showControls()
    }

    /// Cancels a scrub, then skips from where the video is.
    public func skipForward() {
        endScrub(restore: false)
        session.skipForward()
        showControls()
    }

    public func skipBackward() {
        endScrub(restore: false)
        session.skipBackward()
        showControls()
    }

    /// A skip of a given length (negative = back), from a remote command with its own interval.
    public func skip(by offset: Duration) {
        endScrub(restore: false)
        session.skip(by: offset)
        showControls()
    }

    /// A seek from elsewhere (a remote command).
    public func seek(to position: Duration) {
        endScrub(restore: false)
        session.seek(to: position)
        showControls()
    }

    /// A swipe across the touch surface; 1 is one full swipe to the right. While paused it moves
    /// the scrub preview (starting a scrub at the video's position); otherwise it only shows the
    /// controls.
    public func scrub(by swipes: Double) {
        if session.snapshot.status == .paused {
            if scrubPosition == nil {
                scrubOrigin = session.snapshot.position
                previewed = nil
            }
            let start = scrubPosition ?? session.snapshot.position
            var target = start + scrubSpan * swipes
            target = max(.zero, target)
            if let duration { target = min(target, duration) }
            scrubPosition = target
            scrubPreviewAt = now() + Self.scrubPreviewDelay
        }
        showControls()
    }

    /// Seeks to the preview and ends the scrub. Does not play.
    public func commitScrub() {
        guard let target = scrubPosition else { return }
        endScrub(restore: false)
        session.seek(to: target)
        showControls()
    }

    /// Ends the scrub, putting the video back where it was if a preview moved it.
    public func cancelScrub() {
        endScrub(restore: true)
        showControls()
    }

    /// The screen's scene stopped being active (SPEC 6.4 "Leaving the foreground", M6-2): a scrub
    /// is cancelled and playback pauses, which saves the position (SPEC 5.2). Coming back does
    /// not play; the viewer finds the controls up and presses Play.
    public func leftForeground() {
        endScrub(restore: true)
        pause()
    }

    /// Ends a scrub; with `restore`, moves the video back to where the scrub began if a preview
    /// moved it. Without, the video stays where it is (a skip then acts from there).
    private func endScrub(restore: Bool) {
        if restore, previewed != nil, let scrubOrigin { session.seek(to: scrubOrigin) }
        scrubPosition = nil
        scrubPreviewAt = nil
        scrubOrigin = nil
        previewed = nil
    }

    /// Back: cancels a scrub, else closes the panel, else it is time to leave.
    public func back() -> BackResult {
        if scrubPosition != nil {
            cancelScrub()
            return .handled
        }
        if panel != nil {
            closePanel()
            return .handled
        }
        return .leave
    }

    /// Opens the panel on this tab (cancelling a scrub) and reads the tracks.
    public func openPanel(_ tab: Panel = .info) {
        if scrubPosition != nil { endScrub(restore: true) }
        panel = tab
        refreshTracks()
        showControls()
    }

    public func closePanel() {
        panel = nil
        showControls()
    }

    public func selectAudioTrack(_ id: MediaTrack.ID?) {
        session.selectAudioTrack(id)
        refreshTracks()
    }

    /// nil turns subtitles off.
    public func selectSubtitleTrack(_ id: MediaTrack.ID?) {
        session.selectSubtitleTrack(id)
        refreshTracks()
    }

    /// Stores where the viewer is as the bookmark; a failure shows in `notice`.
    public func setBookmark() async {
        await session.setBookmarkHere()
    }

    // MARK: Helpers

    private func refreshTracks() {
        audioTracks = session.audioTracks
        subtitleTracks = session.subtitleTracks
        selectedAudioTrack = session.selectedAudioTrack
        selectedSubtitleTrack = session.selectedSubtitleTrack
    }

    private var scrubSpan: Duration {
        guard let duration else { return Self.unknownDurationScrubSpan }
        return max(duration * Self.scrubShare, Self.minimumScrubSpan)
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
