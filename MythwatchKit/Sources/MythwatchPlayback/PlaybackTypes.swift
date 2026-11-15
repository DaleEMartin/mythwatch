import Foundation
import MythwatchDomain

/// Tunables of one playback session (SPEC 5.2).
public struct PlaybackSettings: Sendable, Equatable {
    public var commercialSkip: CommercialSkipConfig
    public var skipForward: Duration
    public var skipBackward: Duration
    public var saveInterval: Duration
    public var watchedFraction: Double
    public var minimumResumePosition: Duration

    public init(
        commercialSkip: CommercialSkipConfig = .init(), skipForward: Duration = .seconds(30),
        skipBackward: Duration = .seconds(10), saveInterval: Duration = .seconds(30),
        watchedFraction: Double = 0.95, minimumResumePosition: Duration = .seconds(10)
    ) {
        self.commercialSkip = commercialSkip
        self.skipForward = skipForward
        self.skipBackward = skipBackward
        self.saveInterval = saveInterval
        self.watchedFraction = watchedFraction
        self.minimumResumePosition = minimumResumePosition
    }
}

/// What `PlaybackSession.finish()` reports (SPEC 5.2).
public struct PlaybackOutcome: Sendable, Equatable {
    public var position: Duration
    public var reachedEnd: Bool
    public var markedWatched: Bool

    public init(position: Duration, reachedEnd: Bool, markedWatched: Bool) {
        self.position = position
        self.reachedEnd = reachedEnd
        self.markedWatched = markedWatched
    }
}

/// The commercial-skip banner on screen (SPEC 5.2). Built from `SkipEffect`: `.showSkipped`
/// gives `.skipped`, `.offerSkip` gives `.offer`.
public enum SkipBanner: Sendable, Equatable {
    /// "Skipped" with an undo, available until `undoUntil`.
    case skipped(Duration, undoUntil: ContinuousClock.Instant)
    /// The Skip button for this break (prompt mode).
    case offer(CommercialBreak)
}
