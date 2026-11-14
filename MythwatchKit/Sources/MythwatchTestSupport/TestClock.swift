import Foundation

/// A manually advanced clock. Nothing reads real time after `init`, and nothing sleeps.
@MainActor public final class TestClock {
    private var current: ContinuousClock.Instant

    /// `ContinuousClock.Instant` has no public initialiser, so one real reading taken here is
    /// the arbitrary origin. Only differences between readings are meaningful.
    public init() { current = ContinuousClock.now }

    public var now: @MainActor () -> ContinuousClock.Instant {
        { [self] in current }
    }

    public func advance(by duration: Duration) {
        current = current.advanced(by: duration)
    }
}
