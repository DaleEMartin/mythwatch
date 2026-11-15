import Testing

@testable import MythwatchPlayback

@Suite struct StartPointTests {
    @Test func hasTheThreeStartPointsOfTheSpec() {
        let all: [StartPoint] = [.beginning, .resume, .bookmark]
        #expect(Set(all.map { "\($0)" }) == ["beginning", "resume", "bookmark"])
        #expect(StartPoint.resume == .resume)
        #expect(StartPoint.resume != .bookmark)
    }
}
