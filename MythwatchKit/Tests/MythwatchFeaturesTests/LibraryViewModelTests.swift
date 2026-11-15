import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport
import Testing

@MainActor
@Suite("LibraryViewModel")
struct LibraryViewModelTests {
    let adapter: FakeBackendAdapter
    let model: LibraryViewModel

    init() {
        let adapter = FakeBackendAdapter(recordings: [episode(1), episode(2), episode(3, title: "Harbour Lights", key: "KEY-HARBOUR")])
        self.adapter = adapter
        model = LibraryViewModel(recordings: adapter.recordings)
    }

    var fake: FakeRecordingsService { adapter.recordingsFake }

    // MARK: Loading

    @Test func startsIdle() {
        #expect(model.library.isIdle)
        #expect(!model.isRefreshing)
        #expect(model.refreshProblem == nil)
    }

    @Test func loadGoesThroughLoadingToLoaded() async throws {
        fake.suspend(.allRecordings)
        let task = Task { await model.load() }
        try await fake.waitForParked()
        #expect(model.library.isLoading)
        fake.releaseAll()
        await task.value
        #expect(model.library.value == LibraryBuilder.build(from: adapter.store.allRecordings))
        #expect(model.library.value?.shows.count == 2)
        #expect(fake.calls == [.allRecordings])
    }

    @Test(arguments: [
        BackendError.unreachable("DIAG refused"), .timedOut, .notFound, .rejected("DIAG no"),
    ])
    func failureGivesFailedWithTheMessageAndItsRetryFlag(error: BackendError) async {
        fake.failNext(error)
        await model.load()
        #expect(model.library.message == UserMessage(error))
        #expect(model.library.message?.canRetry == UserMessage(error).canRetry)
        #expect(model.library.message?.detail.contains("DIAG") == false)
    }

    @Test func anErrorThatIsNotABackendErrorGivesTheGenericMessage() async {
        let service = ThrowingService()
        let model = LibraryViewModel(recordings: service)
        await model.load()
        #expect(model.library.message == .unexpected)
    }

    @Test func retryAfterAFailureShowsLoadingThenTheLibrary() async throws {
        fake.failNext(.unreachable("x"))
        await model.load()
        #expect(model.library.message != nil)
        fake.suspend(.allRecordings)
        let task = Task { await model.load() }
        try await fake.waitForParked()
        #expect(model.library.isLoading)
        fake.releaseAll()
        await task.value
        #expect(model.library.value != nil)
    }

    @Test func loadWhenAlreadyLoadedDoesNotFetchAgain() async {
        await model.load()
        await model.load()
        #expect(fake.calls == [.allRecordings])
    }

    // MARK: Refresh

    @Test func refreshKeepsOldContentVisibleWhileLoadingAndReplacesItOnSuccess() async throws {
        await model.load()
        let old = try #require(model.library.value)
        adapter.store.add(episode(4, title: "Lantern Street", key: "KEY-LANTERN"))
        fake.suspend(.allRecordings)
        let task = Task { await model.refresh() }
        try await fake.waitForParked()
        #expect(model.library.value == old)
        #expect(model.isRefreshing)
        fake.releaseAll()
        await task.value
        #expect(!model.isRefreshing)
        #expect(model.library.value?.shows.count == 3)
    }

    @Test func aFailedRefreshKeepsTheOldLibraryAndReportsTheProblemSeparately() async throws {
        await model.load()
        let old = try #require(model.library.value)
        fake.failNext(.timedOut)
        await model.refresh()
        #expect(model.library.value == old)
        #expect(model.refreshProblem == UserMessage(.timedOut))
        #expect(!model.isRefreshing)
    }

    @Test func theRefreshProblemClearsWhenTheNextRefreshStartsAndStaysClearedOnSuccess() async throws {
        await model.load()
        fake.failNext(.timedOut)
        await model.refresh()
        #expect(model.refreshProblem != nil)
        fake.suspend(.allRecordings)
        let task = Task { await model.refresh() }
        try await fake.waitForParked()
        #expect(model.refreshProblem == nil)
        fake.releaseAll()
        await task.value
        #expect(model.refreshProblem == nil)
        #expect(model.library.value != nil)
    }

    @Test func refreshBeforeAnythingIsLoadedBehavesLikeLoad() async throws {
        fake.suspend(.allRecordings)
        let task = Task { await model.refresh() }
        try await fake.waitForParked()
        #expect(model.library.isLoading)
        fake.releaseAll()
        await task.value
        #expect(model.library.value != nil)
    }

    @Test func aFailedRefreshBeforeAnythingIsLoadedIsAFailedLibrary() async {
        fake.failNext(.timedOut)
        await model.refresh()
        #expect(model.library.message == UserMessage(.timedOut))
        #expect(model.refreshProblem == nil)
    }

    @Test func reloadAfterPlaybackRefreshesAndKeepsContentVisible() async throws {
        await model.load()
        adapter.store.add(episode(4, title: "Lantern Street", key: "KEY-LANTERN"))
        fake.suspend(.allRecordings)
        let task = Task { await model.reloadAfterPlayback() }
        try await fake.waitForParked()
        #expect(model.library.value?.shows.count == 2)
        fake.releaseAll()
        await task.value
        #expect(model.library.value?.shows.count == 3)
    }

    @Test func aRefreshAfterADeleteDropsTheDeletePendingRecording() async throws {
        await model.load()
        try await fake.delete(id: rid(3), allowRerecord: false)
        await model.refresh()
        #expect(model.library.value?.shows.map(\.title) == ["Garden Tales"])
    }

    // MARK: Concurrency

    @Test func concurrentLoadAndRefreshFetchOnceAndBothFinishWithTheResult() async throws {
        fake.suspend(.allRecordings)
        let first = Task { await model.load() }
        try await fake.waitForParked()
        let second = Task { await model.refresh() }
        let third = Task { await model.load() }
        fake.releaseAll()
        await first.value
        await second.value
        await third.value
        #expect(fake.calls == [.allRecordings])
        #expect(model.library.value != nil)
    }

    @Test func aLocalChangeDuringAFetchMakesTheFetchRunAgainSoItsStaleResultIsNotShown() async throws {
        await model.load()
        fake.suspendNext(.allRecordings)
        let task = Task { await model.refresh() }
        try await fake.waitForParked()
        model.apply(.deleted(rid(3)))
        #expect(model.library.value?.shows.map(\.title) == ["Garden Tales"])
        fake.releaseAll()
        await task.value
        // The first answer predates the change, so it was dropped and the library was fetched again.
        #expect(fake.calls == [.allRecordings, .allRecordings, .allRecordings])
    }

    // MARK: Cancellation

    @Test(arguments: [false, true])
    func aCancelledLoadShowsNoErrorAndIsNotStuckLoading(urlSessionStyle: Bool) async throws {
        let service: any RecordingsService = urlSessionStyle ? UnreachableOnCancel(inner: fake) : fake
        let model = LibraryViewModel(recordings: service)
        fake.suspend(.allRecordings)
        let task = Task { await model.load() }
        try await fake.waitForParked()
        #expect(model.library.isLoading)
        task.cancel()
        await task.value
        // State after a cancelled first load: idle, as if load() had not been called.
        #expect(model.library.isIdle)
        #expect(model.library.message == nil)
        #expect(!model.isRefreshing)
        // And it can load again.
        fake.stopSuspending()
        await model.load()
        #expect(model.library.value != nil)
    }

    @Test func aCancelledRefreshKeepsTheOldContentAndReportsNothing() async throws {
        let model = LibraryViewModel(recordings: UnreachableOnCancel(inner: fake))
        await model.load()
        let old = try #require(model.library.value)
        fake.suspend(.allRecordings)
        let task = Task { await model.refresh() }
        try await fake.waitForParked()
        task.cancel()
        await task.value
        #expect(model.library.value == old)
        #expect(model.refreshProblem == nil)
        #expect(!model.isRefreshing)
    }

    @Test func aCancelledRetryAfterAFailureGoesBackToTheFailure() async throws {
        fake.failNext(.timedOut)
        await model.load()
        fake.suspend(.allRecordings)
        let task = Task { await model.load() }
        try await fake.waitForParked()
        task.cancel()
        await task.value
        #expect(model.library.message == UserMessage(.timedOut))
    }

    @Test func cancellingOneOfTwoWaitersDoesNotCancelTheFetchButCancellingBothDoes() async throws {
        fake.suspend(.allRecordings)
        let first = Task { await model.load() }
        try await fake.waitForParked()
        let second = Task { await model.refresh() }
        first.cancel()
        // The fetch is still wanted by `second`: nothing is cancelled and the call stays parked.
        #expect(fake.parked.count == 1)
        fake.releaseAll()
        await first.value
        await second.value
        #expect(model.library.value != nil)

        fake.clearFailures()
        fake.suspend(.allRecordings)
        let third = Task { await model.refresh() }
        let fourth = Task { await model.refresh() }
        try await fake.waitForParked()
        third.cancel()
        fourth.cancel()
        await third.value
        await fourth.value
        #expect(model.library.value != nil)  // old content kept
        #expect(model.refreshProblem == nil)
        #expect(!model.isRefreshing)
    }

    // MARK: Local changes

    @Test func applyingAWatchedChangeUpdatesCountsAndShelves() async throws {
        let withResume = episode(5, title: "Lantern Street", key: "KEY-LANTERN")
        adapter.store.add(withResume, resumePosition: .seconds(60))
        await model.load()
        #expect(model.library.value?.continueWatching.map(\.id) == [rid(5)])
        model.apply(.watched(rid(1), true))
        let garden = try #require(model.library.value?.shows.first { $0.title == "Garden Tales" })
        #expect(garden.unwatchedCount == 1)
        model.apply(.watched(rid(5), true))
        #expect(model.library.value?.continueWatching.isEmpty == true)
        model.apply(.watched(rid(1), false))
        let again = try #require(model.library.value?.shows.first { $0.title == "Garden Tales" })
        #expect(again.unwatchedCount == 2)
    }

    @Test func applyingADeleteRemovesTheRecordingAndAShowThatHasNoneLeft() async throws {
        await model.load()
        model.apply(.deleted(rid(1)))
        #expect(model.library.value?.recentlyRecorded.map(\.id).contains(rid(1)) == false)
        #expect(model.library.value?.shows.first { $0.title == "Garden Tales" }?.episodeCount == 1)
        model.apply(.deleted(rid(3)))
        #expect(model.library.value?.shows.map(\.title) == ["Garden Tales"])
    }

    @Test func aChangeBeforeAnythingIsLoadedIsHarmless() async {
        model.apply(.deleted(rid(1)))
        #expect(model.library.isIdle)
        await model.load()
        #expect(model.library.value != nil)
    }
}

private struct ThrowingService: RecordingsService {
    struct Oddity: Error {}
    func allRecordings() async throws -> [Recording] { throw Oddity() }
    func recording(id: RecordingID) async throws -> Recording { throw Oddity() }
    func setWatched(_ watched: Bool, id: RecordingID) async throws { throw Oddity() }
    func delete(id: RecordingID, allowRerecord: Bool) async throws { throw Oddity() }
}
