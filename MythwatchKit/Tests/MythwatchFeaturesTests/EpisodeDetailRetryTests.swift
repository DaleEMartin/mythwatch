import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport
import Testing

/// SPEC 6.4 "Episode detail rules", M5-3: Try Again on the page's problem banner reloads the
/// positions, but only for a problem that came from loading them and that trying again can fix.
@MainActor
@Suite("EpisodeDetailModel retry")
struct EpisodeDetailRetryTests {
    let recording = episode(1)
    let adapter: FakeBackendAdapter
    let model: EpisodeDetailModel

    init() {
        adapter = FakeBackendAdapter(recordings: [episode(1)])
        model = EpisodeDetailModel(
            recording: episode(1), state: adapter.playbackState, recordings: adapter.recordings)
    }

    var state: FakePlaybackStateService { adapter.playbackStateFake }

    @Test func withNoProblemThereIsNothingToRetry() async {
        #expect(!model.canRetryLoad)
        await model.load()
        #expect(!model.canRetryLoad)
    }

    @Test func aLoadThatCouldNotReachTheBackendCanBeRetried() async {
        state.failNext(.unreachable("DIAG"), on: .resumePosition)
        await model.load()
        #expect(model.canRetryLoad)
    }

    @Test func retryingWhenTheBackendIsBackClearsTheProblemAndOffersResume() async {
        adapter.store.add(recording, resumePosition: .seconds(300), bookmark: nil)
        state.failNext(.unreachable("DIAG"), on: .resumePosition)
        state.failNext(.unreachable("DIAG"), on: .bookmark)
        await model.load()
        #expect(model.startOptions.map(\.point) == [.beginning])
        await model.load()
        #expect(model.problem == nil)
        #expect(!model.canRetryLoad)
        #expect(model.startOptions.map(\.point) == [.resume, .beginning])
    }

    @Test func aLoadProblemThatTryingAgainCannotFixIsNotOfferedForRetry() async {
        state.failNext(.notFound, on: .bookmark)
        await model.load()
        #expect(model.problem != nil)
        #expect(!model.canRetryLoad)
    }

    @Test func aFailedDeleteIsNotRetriedByReloading() async {
        adapter.recordingsFake.failNext(.unreachable("DIAG"), on: .delete)
        await model.delete(allowRerecord: false).value
        #expect(model.problem?.canRetry == true)
        #expect(!model.canRetryLoad)
    }

    @Test func aDeleteStartedAfterAFailedLoadClearsTheRetry() async throws {
        state.failNext(.unreachable("DIAG"), on: .resumePosition)
        await model.load()
        adapter.recordingsFake.suspend(.delete)
        let task = model.delete(allowRerecord: false)
        try await adapter.recordingsFake.waitForParked(1, of: .delete)
        #expect(!model.canRetryLoad)
        adapter.recordingsFake.releaseAll()
        await task.value
    }

    @Test func aFailedDeleteAfterAFailedLoadIsNotRetriedByReloading() async {
        state.failNext(.unreachable("DIAG"), on: .resumePosition)
        await model.load()
        adapter.recordingsFake.failNext(.unreachable("DIAG"), on: .delete)
        await model.delete(allowRerecord: false).value
        #expect(model.problem != nil)
        #expect(!model.canRetryLoad)
    }

    @Test func aFailedLoadAfterAFailedDeleteCanBeRetried() async {
        adapter.recordingsFake.failNext(.timedOut, on: .delete)
        await model.delete(allowRerecord: false).value
        state.failNext(.timedOut, on: .resumePosition)
        await model.load()
        #expect(model.canRetryLoad)
    }
}
