import Foundation
import MythwatchDomain
import MythwatchPlayback
import Testing

@Suite struct PlaybackValueTypesTests {
    @Test func settingsDefaultsMatchSpecFieldByField() {
        let s = PlaybackSettings()
        #expect(s.commercialSkip == CommercialSkipConfig())
        #expect(s.skipForward == .seconds(30))
        #expect(s.skipBackward == .seconds(10))
        #expect(s.saveInterval == .seconds(30))
        #expect(s.watchedFraction == 0.95)
        #expect(s.minimumResumePosition == .seconds(10))
    }

    @Test func settingsInitialiserTakesEveryField() {
        let s = PlaybackSettings(
            commercialSkip: CommercialSkipConfig(mode: .prompt), skipForward: .seconds(60),
            skipBackward: .seconds(5), saveInterval: .seconds(15), watchedFraction: 0.9,
            minimumResumePosition: .seconds(20))
        #expect(s.commercialSkip.mode == .prompt)
        #expect(s.skipForward == .seconds(60))
        #expect(s.skipBackward == .seconds(5))
        #expect(s.saveInterval == .seconds(15))
        #expect(s.watchedFraction == 0.9)
        #expect(s.minimumResumePosition == .seconds(20))
        #expect(s != PlaybackSettings())
    }

    @Test func outcomeEquality() {
        let a = PlaybackOutcome(position: .seconds(5), reachedEnd: false, markedWatched: false)
        #expect(a == PlaybackOutcome(position: .seconds(5), reachedEnd: false, markedWatched: false))
        #expect(a != PlaybackOutcome(position: .seconds(5), reachedEnd: true, markedWatched: false))
        #expect(a.position == .seconds(5))
    }

    @Test func skipBannerEquality() throws {
        let origin = ContinuousClock.now
        let later = origin.advanced(by: .seconds(8))
        let b = try #require(CommercialBreak(start: .seconds(10), end: .seconds(20)))
        let c = try #require(CommercialBreak(start: .seconds(30), end: .seconds(40)))
        #expect(SkipBanner.skipped(.seconds(5), undoUntil: later) == .skipped(.seconds(5), undoUntil: later))
        #expect(SkipBanner.skipped(.seconds(5), undoUntil: later) != .skipped(.seconds(6), undoUntil: later))
        #expect(SkipBanner.skipped(.seconds(5), undoUntil: later) != .skipped(.seconds(5), undoUntil: origin))
        #expect(SkipBanner.offer(b) == .offer(b))
        #expect(SkipBanner.offer(b) != .offer(c))
        #expect(SkipBanner.offer(b) != .skipped(.seconds(5), undoUntil: later))
    }
}
