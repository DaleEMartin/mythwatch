import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

@MainActor
@Suite("EpisodeDetailModel")
struct EpisodeDetailModelTests {
    let recording = episode(1)
    let adapter: FakeBackendAdapter
    let model: EpisodeDetailModel

    init() {
        adapter = FakeBackendAdapter(recordings: [episode(1)])
        model = EpisodeDetailModel(recording: episode(1), state: adapter.playbackState)
    }

    var fake: FakePlaybackStateService { adapter.playbackStateFake }

    func points(_ m: EpisodeDetailModel? = nil) -> [StartPoint] { (m ?? model).startOptions.map(\.point) }

    // MARK: Start points

    @Test(arguments: [
        (false, false, [StartPoint.beginning]),
        (true, false, [.resume, .beginning]),
        (false, true, [.bookmark, .beginning]),
        (true, true, [.resume, .bookmark, .beginning]),
    ])
    func offersTheRightStartPointsForEachCombination(
        hasResume: Bool, hasBookmark: Bool, expected: [StartPoint]
    ) async {
        adapter.store.add(
            recording, resumePosition: hasResume ? .seconds(600) : nil,
            bookmark: hasBookmark ? .seconds(1200) : nil)
        await model.load()
        #expect(points() == expected)
        #expect(model.resumePosition == (hasResume ? .seconds(600) : nil))
        #expect(model.bookmark == (hasBookmark ? .seconds(1200) : nil))
        #expect(model.problem == nil)
        #expect(!model.isLoading)
    }

    @Test func beforeLoadingOnlyPlayFromBeginningIsOffered() {
        #expect(points() == [.beginning])
        #expect(model.recording == recording)
        #expect(model.problem == nil)
    }

    @Test func startOptionsCarryTheirPositionAndPlainEnglishLabels() async {
        adapter.store.add(recording, resumePosition: .seconds(754), bookmark: .seconds(3723))
        await model.load()
        let options = model.startOptions
        #expect(options.map(\.title) == ["Resume from 12:34", "Play from Bookmark at 1:02:03", "Play from Beginning"])
        #expect(options.map(\.position) == [.seconds(754), .seconds(3723), nil])
        #expect(options.map(\.id).count == Set(options.map(\.id)).count)
    }

    @Test func aPositionOfZeroOrLessIsTreatedAsNone() async {
        let model = EpisodeDetailModel(
            recording: recording, state: StubPlaybackState(resume: .zero, mark: .seconds(-5)))
        await model.load()
        #expect(model.resumePosition == nil)
        #expect(model.bookmark == nil)
        #expect(points(model) == [.beginning])
    }

    @Test func aTinyPositionIsStillOffered() async {
        let model = EpisodeDetailModel(
            recording: recording, state: StubPlaybackState(resume: .milliseconds(1500), mark: nil))
        await model.load()
        #expect(model.startOptions.first?.title == "Resume from 0:01")
    }

    // MARK: Loading

    @Test func loadFetchesBothPositionsAtTheSameTime() async throws {
        adapter.store.add(recording, resumePosition: .seconds(60), bookmark: .seconds(90))
        fake.suspend()
        let task = Task { await model.load() }
        try await fake.waitForParked(2)  // both calls are parked at once: neither waited for the other
        #expect(model.isLoading)
        #expect(fake.calls.count == 2)
        #expect(fake.calls.contains(.resumePosition(recording.id)) && fake.calls.contains(.bookmark(recording.id)))
        fake.releaseAll()
        await task.value
        #expect(!model.isLoading)
        #expect(points() == [.resume, .bookmark, .beginning])
    }

    @Test func aFailedPositionFetchStillOffersPlayFromBeginningAndTheBookmark() async {
        adapter.store.add(recording, resumePosition: .seconds(60), bookmark: .seconds(90))
        fake.failNext(.unreachable("DIAG"), on: .resumePosition)
        await model.load()
        #expect(points() == [.bookmark, .beginning])
        #expect(model.resumePosition == nil)
        #expect(model.problem == UserMessage(.unreachable("DIAG")))
    }

    @Test func aFailedBookmarkFetchStillOffersResume() async {
        adapter.store.add(recording, resumePosition: .seconds(60), bookmark: .seconds(90))
        fake.failNext(.timedOut, on: .bookmark)
        await model.load()
        #expect(points() == [.resume, .beginning])
        #expect(model.problem == UserMessage(.timedOut))
    }

    @Test func whenBothFetchesFailThereIsOneMessageAndPlayFromBeginningRemains() async {
        fake.failAlways(.timedOut)
        await model.load()
        #expect(points() == [.beginning])
        #expect(model.problem == UserMessage(.timedOut))
    }

    @Test func aFailureThatIsNotABackendErrorGivesTheGenericMessage() async {
        struct Oddity: Error {}
        struct Broken: PlaybackStateService {
            func resumePosition(for id: RecordingID) async throws -> Duration? { throw Oddity() }
            func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {}
            func bookmark(for id: RecordingID) async throws -> Duration? { nil }
            func setBookmark(_ position: Duration?, for id: RecordingID) async throws {}
        }
        let model = EpisodeDetailModel(recording: recording, state: Broken())
        await model.load()
        #expect(model.problem == .unexpected)
    }

    @Test func loadingAgainShowsTheNewPositionsAndClearsTheProblem() async {
        fake.failNext(.timedOut, on: .resumePosition)
        await model.load()
        #expect(model.problem != nil)
        adapter.store.add(recording, resumePosition: .seconds(300), bookmark: nil)
        await model.load()
        #expect(model.problem == nil)
        #expect(points() == [.resume, .beginning])
    }

    @Test func aReloadThatFailsKeepsWhatWasKnownBefore() async {
        adapter.store.add(recording, resumePosition: .seconds(60), bookmark: nil)
        await model.load()
        fake.failNext(.timedOut, on: .resumePosition)
        await model.load()
        #expect(model.resumePosition == .seconds(60))
        #expect(model.problem == UserMessage(.timedOut))
    }

    @Test func concurrentLoadsFetchOnce() async throws {
        adapter.store.add(recording, resumePosition: .seconds(60), bookmark: .seconds(90))
        fake.suspend()
        let first = Task { await model.load() }
        try await fake.waitForParked(2)
        let second = Task { await model.load() }
        fake.releaseAll()
        await first.value
        await second.value
        #expect(fake.calls.count == 2)
    }

    // MARK: Cancellation

    @Test(arguments: [false, true])
    func aCancelledLoadShowsNoErrorAndIsNotStuckLoading(urlSessionStyle: Bool) async throws {
        adapter.store.add(recording, resumePosition: .seconds(60), bookmark: nil)
        let state: any PlaybackStateService = urlSessionStyle ? UnreachableOnCancelState(inner: fake) : fake
        let model = EpisodeDetailModel(recording: recording, state: state)
        fake.suspend()
        let task = Task { await model.load() }
        try await fake.waitForParked(2)
        task.cancel()
        await task.value
        // After a cancelled load: nothing published, no message, not loading; values as before.
        #expect(!model.isLoading)
        #expect(model.problem == nil)
        #expect(model.resumePosition == nil)
        #expect(points(model) == [.beginning])
        fake.stopSuspending()
        await model.load()
        #expect(points(model) == [.resume, .beginning])
    }

    @Test func aCancelledReloadKeepsWhatWasKnownBefore() async throws {
        adapter.store.add(recording, resumePosition: .seconds(60), bookmark: nil)
        await model.load()
        fake.suspend()
        let task = Task { await model.load() }
        try await fake.waitForParked(2)
        task.cancel()
        await task.value
        #expect(model.resumePosition == .seconds(60))
        #expect(model.problem == nil)
        #expect(!model.isLoading)
    }
}

private struct UnreachableOnCancelState: PlaybackStateService {
    let inner: FakePlaybackStateService
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch is CancellationError {
            throw BackendError.unreachable("cancelled")
        }
    }
    func resumePosition(for id: RecordingID) async throws -> Duration? { try await mapped { try await inner.resumePosition(for: id) } }
    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {
        try await mapped { try await inner.setResumePosition(position, for: id) }
    }
    func bookmark(for id: RecordingID) async throws -> Duration? { try await mapped { try await inner.bookmark(for: id) } }
    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {
        try await mapped { try await inner.setBookmark(position, for: id) }
    }
}
