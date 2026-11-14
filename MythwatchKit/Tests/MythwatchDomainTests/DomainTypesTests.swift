import Testing
import MythwatchDomain

@Suite struct CalendarDayTests {
    @Test func parsesValidDay() {
        let day = CalendarDay(parsing: "2025-02-28")
        #expect(day == CalendarDay(year: 2025, month: 2, day: 28))
        #expect(day?.year == 2025)
        #expect(day?.month == 2)
        #expect(day?.day == 28)
    }

    @Test func parsesLeapDay() {
        #expect(CalendarDay(parsing: "2024-02-29") != nil)
        #expect(CalendarDay(parsing: "2025-02-29") == nil)
    }

    @Test func rejectsEmpty() {
        #expect(CalendarDay(parsing: "") == nil)
    }

    @Test(arguments: [
        "garbage", "2025", "2025-02", "2025-2-3", "2025/02/03", "2025-02-03T00:00:00Z",
        " 2025-02-03", "2025-02-03 ", "20250203", "abcd-ef-gh", "+025-02-03", "2025-0a-03",
    ])
    func rejectsGarbage(_ text: String) {
        #expect(CalendarDay(parsing: text) == nil)
    }

    @Test(arguments: ["2025-02-30", "2025-13-01", "2025-00-10", "2025-01-00", "2025-04-31", "0000-01-01"])
    func rejectsImpossibleDates(_ text: String) {
        #expect(CalendarDay(parsing: text) == nil)
    }

    @Test func memberwiseInitRejectsImpossibleDates() {
        #expect(CalendarDay(year: 2025, month: 13, day: 1) == nil)
        #expect(CalendarDay(year: 2025, month: 2, day: 30) == nil)
    }

    @Test func ordersByYearThenMonthThenDay() throws {
        let a = try #require(CalendarDay(parsing: "2024-12-31"))
        let b = try #require(CalendarDay(parsing: "2025-01-01"))
        let c = try #require(CalendarDay(parsing: "2025-01-02"))
        let d = try #require(CalendarDay(parsing: "2025-02-01"))
        #expect(a < b)
        #expect(b < c)
        #expect(c < d)
        #expect(!(d < a))
        #expect([d, b, a, c].sorted() == [a, b, c, d])
    }
}

@Suite struct TimeRangeTests {
    @Test func acceptsStartBeforeEnd() {
        let range = TimeRange(start: .seconds(1), end: .seconds(2))
        #expect(range?.start == .seconds(1))
        #expect(range?.end == .seconds(2))
    }

    @Test func rejectsEqualBounds() {
        #expect(TimeRange(start: .seconds(5), end: .seconds(5)) == nil)
    }

    @Test func rejectsReversedBounds() {
        #expect(TimeRange(start: .seconds(6), end: .seconds(5)) == nil)
    }
}

@Suite struct RecordingFlagsTests {
    @Test func emptyHasNoFlags() {
        let flags: RecordingFlags = []
        #expect(flags.isEmpty)
        #expect(!flags.contains(.watched))
    }

    @Test func unionAndContains() {
        let flags: RecordingFlags = [.watched, .hasBookmark]
        #expect(flags.contains(.watched))
        #expect(flags.contains([.watched, .hasBookmark]))
        #expect(!flags.contains(.damaged))
        #expect(flags.union(.damaged).contains(.damaged))
    }

    @Test func intersectionAndSubtracting() {
        let a: RecordingFlags = [.watched, .hasCutList, .commercialsFlagged]
        let b: RecordingFlags = [.hasCutList, .deletePending]
        #expect(a.intersection(b) == .hasCutList)
        #expect(a.subtracting(b) == [.watched, .commercialsFlagged])
    }

    @Test func insertAndRemove() {
        var flags: RecordingFlags = []
        flags.insert(.recordingInProgress)
        #expect(flags == .recordingInProgress)
        flags.remove(.recordingInProgress)
        #expect(flags.isEmpty)
    }

    @Test func flagsAreDistinct() {
        let all: [RecordingFlags] = [
            .watched, .hasBookmark, .hasResumePosition, .commercialsFlagged, .hasCutList,
            .recordingInProgress, .deletePending, .damaged,
        ]
        #expect(Set(all).count == all.count)
        #expect(all.reduce(into: RecordingFlags()) { $0.formUnion($1) }.rawValue.nonzeroBitCount == all.count)
    }
}

@Suite struct BackendErrorTests {
    @Test func equatable() {
        #expect(BackendError.http(status: 404, message: nil) == .http(status: 404, message: nil))
        #expect(BackendError.http(status: 404, message: nil) != .http(status: 500, message: nil))
        #expect(BackendError.timedOut != .notFound)
    }
}
