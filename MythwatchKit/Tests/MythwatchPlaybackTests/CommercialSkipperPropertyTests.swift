import MythwatchDomain
import Testing

@testable import MythwatchPlayback

/// SplitMix64: a small deterministic generator, so every case can be replayed from its seed.
/// (Not `SystemRandomNumberGenerator`, and not the standard library's `random(in:using:)`, whose
/// algorithm could change between toolchains.)
struct SplitMix64 {
    private(set) var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform enough for tests: an integer in `range`.
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func pick<T>(_ choices: [T]) -> T { choices[int(0...(choices.count - 1))] }

    /// True with probability 1 / n.
    mutating func oneIn(_ n: Int) -> Bool { int(1...n) == 1 }
}

/// The property of task M4-1:
///
/// For random break lists and tick sequences without user seeks, in `.auto` the engine position
/// never rests inside a non-suppressed, non-guarded break for more than one tick.
///
/// Precisely, with the rules as SPEC §5.1 states them:
///
/// - **Inside** a break means inside its *skippable part* `[start, landing)`, where
///   `landing = max(start, end - landBeforeEnd)`. The last `landBeforeEnd` of every break is
///   where R2 deliberately lands, so resting there is the design, not a failure.
/// - **Non-suppressed (R8):** the break has not been undone. The simulation calls `undo` at random
///   while a banner is up and tracks which break that suppressed.
/// - **Non-guarded (R5):** `duration` is nil, or `break.end + endGuard <= duration`.
/// - **Not landed in by the viewer (R3):** an `undo` is the viewer's action; if it lands inside a
///   break that starts before the landing point, that break plays (R1 never arms it) until the
///   position leaves it.
/// - **Quiet period (R4):** no automatic action before `quietUntil = lastSkipOrUndo + quietPeriod`.
///   A break entered during that time legitimately plays until the quiet period ends. So the
///   invariant is: on every tick at or after `quietUntil` whose position is inside an eligible
///   break, that same tick seeks to the break's landing point (the position rests inside for at
///   most that one tick). During the quiet period resting is allowed, and the test also checks
///   that the skipper does not seek then.
///
/// The R4 allowance is a real gap in the rules, not slack in the test: after a skip lands at
/// `end - landBeforeEnd`, a next break starting less than `quietPeriod - landBeforeEnd` (2 s with
/// the defaults) after the first one's end is entered during the quiet period and plays for up to
/// that long before it is skipped. The rule is left as written and flagged for the owner; the
/// example test `r4_quietPeriodAfterASkipDelaysTheSkipOfABreakStartingSoonAfterTheLanding` shows
/// the case.
///
/// The test also checks, on every tick: at most one seek; every seek goes forward to the landing
/// point of an eligible break containing the position, with `.showSkipped(landing - position,
/// now + undoWindow)` right after it; no offers in auto; `.hideSkipped` exactly on the first tick
/// at or after `undoUntil` with no new skip; `undo` gives `[.seek(max(0, origin - undoRewind)),
/// .hideSkipped]`.
///
/// A failure names its seed; replay that one case with `CommercialSkipperPropertyTests.run(seed:)`
/// (or `runPrompt(seed:)`), which returns the first violation as text.
@Suite struct CommercialSkipperPropertyTests {
    static let baseSeed: UInt64 = 0x4D59_5448_5741_5443   // "MYTHWATC"
    static let caseCount = 400

    struct Case: CustomStringConvertible {
        var raw: [CommercialBreak]
        var duration: Duration?
        var tick: Duration
        var config: CommercialSkipConfig
        var total: Duration

        var description: String {
            let spans = raw.map { "\($0.start)..<\($0.end)" }.joined(separator: ", ")
            return "breaks [\(spans)], duration \(duration.map { "\($0)" } ?? "nil"), "
                + "tick \(tick), landBeforeEnd \(config.landBeforeEnd), quiet \(config.quietPeriod), "
                + "undoRewind \(config.undoRewind)"
        }
    }

    static func makeCase(_ rng: inout SplitMix64) -> Case {
        let ms: (Int) -> Duration = { .milliseconds($0) }
        var raw: [CommercialBreak] = []
        var cursor = rng.oneIn(6) ? Duration.zero : ms(rng.int(0...30_000))
        for _ in 0..<rng.int(0...6) {
            let length = rng.oneIn(6) ? ms(rng.int(100...1_500)) : ms(rng.int(2_000...120_000))
            let start = cursor
            raw.append(TimeRange(start: start, end: start + length)!)
            switch rng.int(0...5) {
            case 0: cursor = start + length / 2                       // overlapping
            case 1: cursor = start + length                           // touching
            case 2, 3: cursor = start + length + ms(rng.int(1...3_000))   // short gap (an ident)
            default: cursor = start + length + ms(rng.int(3_000...60_000))
            }
        }
        // Shuffle (Fisher-Yates with our generator) so the initialiser has to sort.
        if raw.count > 1 {
            for i in stride(from: raw.count - 1, to: 0, by: -1) {
                raw.swapAt(i, rng.int(0...i))
            }
        }
        let total = (raw.map(\.end).max() ?? cursor) + .seconds(30)
        let duration: Duration? = rng.oneIn(4) ? nil : total - ms(rng.int(0...25_000))
        var config = CommercialSkipConfig()
        config.landBeforeEnd = rng.pick([.zero, ms(500), .seconds(1), .seconds(2)])
        config.quietPeriod = rng.pick([.zero, .seconds(1), .seconds(3), .seconds(5)])
        config.undoRewind = rng.pick([.zero, .seconds(2), .seconds(5)])
        let tick = rng.pick([ms(100), ms(250), ms(500), ms(1_000)])
        return Case(raw: raw, duration: duration, tick: tick, config: config, total: total)
    }

    @Test func autoNeverRestsInsideAnEligibleBreakForMoreThanOneTick() {
        for index in 0..<Self.caseCount {
            let seed = Self.baseSeed &+ UInt64(index)
            if let failure = Self.run(seed: seed) {
                Issue.record("seed \(seed) (case \(index)): \(failure)")
                return
            }
        }
    }

    /// Runs one case; returns a description of the first violation, or nil.
    static func run(seed: UInt64) -> String? {
        var rng = SplitMix64(seed: seed)
        let c = makeCase(&rng)
        var sut = CommercialSkipper(breaks: c.raw, config: c.config)
        let breaks = sut.breaks
        let cfg = c.config

        func landing(_ i: Int) -> Duration { max(breaks[i].start, breaks[i].end - cfg.landBeforeEnd) }
        func guarded(_ i: Int) -> Bool {
            guard let d = c.duration else { return false }
            return breaks[i].end + cfg.endGuard > d
        }

        var position = Duration.zero
        var clock = Duration.zero
        var quietUntil: Duration?
        var bannerUntil: Duration?
        var lastSkip: (index: Int, origin: Duration)?
        var suppressed: Set<Int> = []
        var viewerLanded: Int?   // R3: a break an undo landed inside

        func eligible(_ i: Int) -> Bool { !suppressed.contains(i) && !guarded(i) && viewerLanded != i }
        func inSkippablePart(_ i: Int, _ p: Duration) -> Bool { breaks[i].start <= p && p < landing(i) }

        var step = 0
        while position <= c.total && step < 20_000 {
            step += 1
            let p = position
            let now = origin + clock
            if let v = viewerLanded, !(breaks[v].start <= p && p < breaks[v].end) { viewerLanded = nil }
            var where_: String { "step \(step), position \(p), clock \(clock); \(c)" }

            let effects = sut.tick(position: p, duration: c.duration, now: now)
            let inQuiet = quietUntil.map { clock < $0 } ?? false
            let restingIn = breaks.indices.first { eligible($0) && inSkippablePart($0, p) }

            if effects.contains(where: { if case .offerSkip = $0 { true } else { false } })
                || effects.contains(.withdrawOffer)
            {
                return "offer effect in auto mode \(effects) at \(where_)"
            }

            if case .seek(let target)? = effects.first {
                if inQuiet { return "skipped during the quiet period at \(where_)" }
                guard let i = breaks.indices.first(where: { inSkippablePart($0, p) }) else {
                    return "seek to \(target) from outside any break at \(where_)"
                }
                if !eligible(i) {
                    return "skipped an ineligible break \(i) (suppressed \(suppressed.contains(i)), "
                        + "guarded \(guarded(i)), viewer-landed \(viewerLanded == i)) at \(where_)"
                }
                let expected: [SkipEffect] = [
                    .seek(to: landing(i)),
                    .showSkipped(skipped: landing(i) - p, undoUntil: now + cfg.undoWindow),
                ]
                if effects != expected { return "effects \(effects), expected \(expected) at \(where_)" }
                quietUntil = clock + cfg.quietPeriod
                bannerUntil = clock + cfg.undoWindow
                lastSkip = (i, p)
                position = landing(i)
            } else {
                if let i = restingIn, !inQuiet {
                    return "rested inside eligible break \(i) (\(breaks[i].start)..<\(breaks[i].end)) "
                        + "outside the quiet period at \(where_)"
                }
                let hidesNow = bannerUntil.map { clock >= $0 } ?? false
                let expected: [SkipEffect] = hidesNow ? [.hideSkipped] : []
                if effects != expected { return "effects \(effects), expected \(expected) at \(where_)" }
                if hidesNow { bannerUntil = nil }
            }

            // Sometimes undo while a banner is up (half the time in the same instant as the tick).
            if let until = bannerUntil, let skip = lastSkip, rng.oneIn(12) {
                let undoClock = rng.oneIn(2) ? clock : min(clock + c.tick / 2, until)
                let undone = sut.undo(now: origin + undoClock)
                if undoClock >= until {
                    if undone != [] { return "undo after the window gave \(undone) at \(where_)" }
                } else {
                    let target = max(.zero, skip.origin - cfg.undoRewind)
                    if undone != [.seek(to: target), .hideSkipped] {
                        return "undo gave \(undone), expected seek to \(target) at \(where_)"
                    }
                    suppressed.insert(skip.index)
                    quietUntil = undoClock + cfg.quietPeriod
                    bannerUntil = nil
                    lastSkip = nil
                    position = target
                    viewerLanded = breaks.indices.first {
                        breaks[$0].start < target && target < breaks[$0].end
                    }
                    clock = undoClock
                }
            }

            // The simulated engine: plays at 1x, or is paused for this tick one time in ten.
            if !rng.oneIn(10) { position += c.tick }
            clock += c.tick
        }
        return nil
    }

    /// Prompt mode, the same random cases: offers and withdrawals alternate, an offer is only ever
    /// for an eligible break whose skippable part holds the position, it is withdrawn on the first
    /// tick the position is outside that part, and accepting it behaves like R2.
    @Test func promptOffersAlternateWithWithdrawalsAndAreForTheBreakBeingPlayed() {
        for index in 0..<Self.caseCount {
            let seed = Self.baseSeed &+ 0x1_0000 &+ UInt64(index)
            if let failure = Self.runPrompt(seed: seed) {
                Issue.record("seed \(seed) (prompt case \(index)): \(failure)")
                return
            }
        }
    }

    static func runPrompt(seed: UInt64) -> String? {
        var rng = SplitMix64(seed: seed)
        var c = makeCase(&rng)
        c.config.mode = .prompt
        var sut = CommercialSkipper(breaks: c.raw, config: c.config)
        let breaks = sut.breaks
        let cfg = c.config
        func landing(_ i: Int) -> Duration { max(breaks[i].start, breaks[i].end - cfg.landBeforeEnd) }
        func guarded(_ i: Int) -> Bool {
            guard let d = c.duration else { return false }
            return breaks[i].end + cfg.endGuard > d
        }

        var position = Duration.zero
        var clock = Duration.zero
        var offered: Int?
        var step = 0
        while position <= c.total && step < 20_000 {
            step += 1
            let p = position
            let now = origin + clock
            var where_: String { "step \(step), position \(p), clock \(clock); \(c)" }
            let effects = sut.tick(position: p, duration: c.duration, now: now)
                .filter { $0 != .hideSkipped }
            if effects.contains(where: { if case .seek = $0 { true } else { false } }) {
                return "prompt mode seeked by itself: \(effects) at \(where_)"
            }
            var expectWithdraw = false
            if let o = offered, !(breaks[o].start <= p && p < landing(o)) {
                expectWithdraw = true
                offered = nil
            }
            let offerIndex = breaks.indices.first {
                !guarded($0) && breaks[$0].start <= p && p < landing($0)
            }
            var expected: [SkipEffect] = expectWithdraw ? [.withdrawOffer] : []
            // Playback only moves forward here and accepting lands past the skippable part, so
            // every eligible break whose skippable part holds the position is armed and offered.
            if offered == nil, let i = offerIndex {
                expected.append(.offerSkip(breaks[i]))
                offered = i
            }
            if effects != expected { return "effects \(effects), expected \(expected) at \(where_)" }

            if let o = offered, rng.oneIn(8) {
                let accepted = sut.acceptOffer(position: p, now: now)
                let expectedAccept: [SkipEffect] = [
                    .seek(to: landing(o)), .withdrawOffer,
                    .showSkipped(skipped: landing(o) - p, undoUntil: now + cfg.undoWindow),
                ]
                if accepted != expectedAccept {
                    return "accept gave \(accepted), expected \(expectedAccept) at \(where_)"
                }
                offered = nil
                position = landing(o)
            }
            if !rng.oneIn(10) { position += c.tick }
            clock += c.tick
        }
        return nil
    }

    @Test func generatorIsDeterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        #expect((0..<10).map { _ in a.next() } == (0..<10).map { _ in b.next() })
    }
}
