import Foundation
import MythwatchDomain

/// Commercial-skip settings (SPEC 5.1).
public struct CommercialSkipConfig: Sendable, Equatable {
    public var mode: CommercialSkipMode
    /// Land this long before the break ends.
    public var landBeforeEnd: Duration
    /// No automatic action this soon after a user seek, a skip or an undo.
    public var quietPeriod: Duration
    /// Never skip a break that ends within this of the end of the file.
    public var endGuard: Duration
    public var undoWindow: Duration
    public var undoRewind: Duration

    public init(
        mode: CommercialSkipMode = .auto, landBeforeEnd: Duration = .seconds(1),
        quietPeriod: Duration = .seconds(3), endGuard: Duration = .seconds(10),
        undoWindow: Duration = .seconds(8), undoRewind: Duration = .seconds(2)
    ) {
        self.mode = mode
        self.landBeforeEnd = landBeforeEnd
        self.quietPeriod = quietPeriod
        self.endGuard = endGuard
        self.undoWindow = undoWindow
        self.undoRewind = undoRewind
    }
}

/// What the skipper asks its owner to do. Effects are data; the skipper performs none.
///
/// Order inside one returned array (SPEC 5.1): at most one `.seek` first; then removals
/// (`.withdrawOffer` before `.hideSkipped`); then additions (`.offerSkip`, `.showSkipped`).
public enum SkipEffect: Sendable, Equatable {
    case seek(to: Duration)
    /// Show the "skipped" banner with an undo. `skipped` is the distance actually jumped.
    case showSkipped(skipped: Duration, undoUntil: ContinuousClock.Instant)
    case hideSkipped
    /// Prompt mode: show the Skip button for this break.
    case offerSkip(CommercialBreak)
    case withdrawOffer
}

/// The commercial-skip rules R1-R11 of SPEC 5.1 as a value type. Every method returns effects and
/// performs none; time arrives only as `now` arguments.
public struct CommercialSkipper: Sendable, Equatable {
    /// The normalised breaks, for the scrubber (R10: exposed in every mode).
    public let breaks: [CommercialBreak]
    public private(set) var config: CommercialSkipConfig

    /// The skip that the banner on screen belongs to (R7).
    private struct Banner: Sendable, Equatable {
        /// Every break the skip covered: the one it fired for through the last one chained (R2).
        var breakIndices: ClosedRange<Int>
        var origin: Duration
        var undoUntil: ContinuousClock.Instant
    }

    /// Index into `breaks` of the armed break (R1); nil when none is left.
    private var armed: Int?
    /// Breaks undone by the viewer (R8).
    private var suppressed: Set<Int> = []
    /// End of the current quiet period (R4); none before the first seek, skip or undo.
    private var quietUntil: ContinuousClock.Instant?
    private var banner: Banner?
    /// Index of the break whose Skip button is showing (R9).
    private var offered: Int?
    /// The last position seen, to notice a position that goes backwards without a seek.
    private var lastPosition: Duration?
    /// The last tick's duration: `acceptOffer` has none of its own, and R2's chaining checks R5.
    private var lastDuration: Duration?
    /// Set by a mode change; the next tick re-arms from its position (R11).
    private var rearmPending = false

    public init(breaks: [CommercialBreak], config: CommercialSkipConfig) {
        self.breaks = Self.normalise(breaks)
        self.config = config
        self.armed = firstArmable(atOrAfter: .zero)
    }

    /// Changes the mode (R11). What the old mode put on screen and the new one would not show is
    /// removed at once: an offer is withdrawn whenever the mode changes, and the banner is hidden
    /// when the new mode is `.off` (its undo would do nothing). Re-arming from the current
    /// position happens on the next `tick`. Setting the current mode does nothing.
    public mutating func setMode(_ mode: CommercialSkipMode) -> [SkipEffect] {
        guard mode != config.mode else { return [] }
        var effects: [SkipEffect] = []
        if offered != nil {
            effects.append(.withdrawOffer)
            offered = nil
        }
        if mode == .off, banner != nil {
            effects.append(.hideSkipped)
            banner = nil
        }
        config.mode = mode
        rearmPending = true
        return effects
    }

    public mutating func tick(position: Duration, duration: Duration?, now: ContinuousClock.Instant)
        -> [SkipEffect]
    {
        guard config.mode != .off else { return [] }   // R10

        if rearmPending {   // R11
            armed = firstArmable(atOrAfter: position)
            rearmPending = false
        } else if let last = lastPosition, position < last,
            let earlier = firstArmable(atOrAfter: position), earlier < (armed ?? breaks.count)
        {
            // Backwards without a seek notification: arm a break the position is now before.
            // Only ever moves the armed break earlier, so jitter inside a break never disarms it.
            armed = earlier
        }
        lastPosition = position
        lastDuration = duration

        // R6 (and suppressed breaks are never armed, R8).
        while let index = armed, position >= breaks[index].end {
            armed = nextArmable(after: index)
        }

        var seek: [SkipEffect] = []
        var removals: [SkipEffect] = []
        var additions: [SkipEffect] = []

        switch config.mode {
        case .auto:
            if !isQuiet(at: now), let index = armed, qualifies(index, position, duration) {   // R2, R4, R5
                let skip = performSkip(index, from: position, duration: duration, now: now)
                seek.append(skip.seek)
                additions.append(skip.banner)
            }
        case .prompt:   // R9
            if let index = offered, !(index == armed && qualifies(index, position, duration)) {
                removals.append(.withdrawOffer)
                offered = nil
            }
            if offered == nil, let index = armed, qualifies(index, position, duration) {
                additions.append(.offerSkip(breaks[index]))
                offered = index
            }
        case .off:
            break
        }

        // R7: the banner goes once its window is over (unless this tick just replaced it).
        if seek.isEmpty, let shown = banner, now >= shown.undoUntil {
            removals.append(.hideSkipped)
            banner = nil
        }
        return seek + removals + additions
    }

    /// The viewer moved the playhead (R1, R3, R4). A showing offer is withdrawn and a showing
    /// banner hidden: an undo would otherwise jump back over the viewer's own seek.
    public mutating func userSeeked(to position: Duration, now: ContinuousClock.Instant)
        -> [SkipEffect]
    {
        guard config.mode != .off else { return [] }
        armed = firstArmable(atOrAfter: position)
        rearmPending = false
        lastPosition = position
        quietUntil = now + config.quietPeriod
        var effects: [SkipEffect] = []
        if offered != nil {
            effects.append(.withdrawOffer)
            offered = nil
        }
        if banner != nil {
            effects.append(.hideSkipped)
            banner = nil
        }
        return effects
    }

    /// The viewer chose Skip (R9). Does what R2 does, with the given position as the origin.
    /// Without an offer showing it does nothing; if the position is no longer before the landing
    /// point it only withdraws the offer.
    public mutating func acceptOffer(position: Duration, now: ContinuousClock.Instant)
        -> [SkipEffect]
    {
        guard config.mode == .prompt, let index = offered else { return [] }
        offered = nil
        guard isBeforeLanding(index, position) else { return [.withdrawOffer] }
        let skip = performSkip(index, from: position, duration: lastDuration, now: now)
        return [skip.seek, .withdrawOffer, skip.banner]
    }

    /// Undoes the most recent skip while its banner's window is open (R7, R8).
    public mutating func undo(now: ContinuousClock.Instant) -> [SkipEffect] {
        guard config.mode != .off, let shown = banner, now < shown.undoUntil else { return [] }
        let target = max(.zero, shown.origin - config.undoRewind)
        suppressed.formUnion(shown.breakIndices)
        banner = nil
        quietUntil = now + config.quietPeriod
        armed = firstArmable(atOrAfter: target)
        rearmPending = false
        lastPosition = target
        var effects: [SkipEffect] = [.seek(to: target)]
        if offered != nil {
            effects.append(.withdrawOffer)
            offered = nil
        }
        effects.append(.hideSkipped)
        return effects
    }

    /// Sorts by start, drops empty ranges (`TimeRange` cannot hold one) and merges ranges that
    /// overlap or touch. The same contract as `V35MarkupService`'s private normalise.
    public static func normalise(_ breaks: [CommercialBreak]) -> [CommercialBreak] {
        var result: [CommercialBreak] = []
        for next in breaks.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = result.last, next.start <= last.end {
                if next.end > last.end, let merged = CommercialBreak(start: last.start, end: next.end) {
                    result[result.count - 1] = merged
                }
            } else {
                result.append(next)
            }
        }
        return result
    }

    // MARK: - Private

    /// R2 for one break and the breaks chained after it: seek to the last one's landing point,
    /// show the banner, start a quiet period and arm the first break after the chain.
    private mutating func performSkip(
        _ index: Int, from position: Duration, duration: Duration?, now: ContinuousClock.Instant
    ) -> (seek: SkipEffect, banner: SkipEffect) {
        let last = chainEnd(from: index, duration: duration)
        let target = landing(last)
        let undoUntil = now + config.undoWindow
        banner = Banner(breakIndices: index...last, origin: position, undoUntil: undoUntil)
        quietUntil = now + config.quietPeriod
        armed = nextArmable(after: last)
        return (.seek(to: target), .showSkipped(skipped: target - position, undoUntil: undoUntil))
    }

    /// R2's chaining: the last break the skip for `first` lands after. Playback resumes at the
    /// landing point at 1x, so a following break starting less than `quietPeriod` after it would
    /// be entered during the skip's quiet period; such a break is jumped over too, and the test
    /// repeats from its landing point. A suppressed (R8) or guarded (R5) break ends the chain. A
    /// break with no skippable part is never a landing point: it is passed, and belongs to the
    /// chain only if a later break does.
    private func chainEnd(from first: Int, duration: Duration?) -> Int {
        var last = first
        var point = landing(first)
        var next = first + 1
        while next < breaks.count, !suppressed.contains(next), !isGuarded(next, duration),
            breaks[next].start < point + config.quietPeriod
        {
            if landing(next) > breaks[next].start {
                last = next
                point = landing(next)
            }
            next += 1
        }
        return last
    }

    /// R1: the first break, not suppressed, whose start is at or after `position`.
    private func firstArmable(atOrAfter position: Duration) -> Int? {
        breaks.indices.first { !suppressed.contains($0) && breaks[$0].start >= position }
    }

    private func nextArmable(after index: Int) -> Int? {
        breaks.indices.first { $0 > index && !suppressed.contains($0) }
    }

    /// R2's landing point.
    private func landing(_ index: Int) -> Duration {
        max(breaks[index].start, breaks[index].end - config.landBeforeEnd)
    }

    /// Inside the part of the break before its landing point: skipping would move forward.
    private func isBeforeLanding(_ index: Int, _ position: Duration) -> Bool {
        position >= breaks[index].start && position < landing(index)
    }

    /// R5, evaluated with this tick's duration. Unknown duration means no guard.
    private func isGuarded(_ index: Int, _ duration: Duration?) -> Bool {
        guard let duration else { return false }
        return breaks[index].end + config.endGuard > duration
    }

    /// The armed break may be skipped (auto) or offered (prompt) now.
    private func qualifies(_ index: Int, _ position: Duration, _ duration: Duration?) -> Bool {
        isBeforeLanding(index, position) && !isGuarded(index, duration)
    }

    private func isQuiet(at now: ContinuousClock.Instant) -> Bool {
        guard let quietUntil else { return false }
        return now < quietUntil
    }
}
