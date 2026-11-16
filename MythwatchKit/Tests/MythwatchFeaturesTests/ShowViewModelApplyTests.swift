import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport
import Testing

/// SPEC 6.4 "Show rules": `apply(_:)` takes in a change made elsewhere (the episode page).
@MainActor
@Suite("ShowViewModel apply")
struct ShowViewModelApplyTests {
    let adapter: FakeBackendAdapter
    let log = ChangeLog()
    let model: ShowViewModel

    init() {
        adapter = FakeBackendAdapter(recordings: [episode(1), episode(2)])
        let show = LibraryBuilder.build(from: adapter.store.allRecordings).shows[0]
        let log = self.log
        model = ShowViewModel(show: show, recordings: adapter.recordings, onChange: { log.record($0) })
    }

    var ids: [Int] { model.show.recordings.map(\.id.rawValue) }

    @Test func aDeletedRecordingLeavesTheShowAndItsCounts() {
        model.apply(.deleted(rid(1)))
        #expect(ids == [2])
        #expect(model.show.episodeCount == 1)
        #expect(model.show.unwatchedCount == 1)
        #expect(!model.isEmpty)
    }

    @Test func deletingTheLastRecordingElsewhereEmptiesTheShow() {
        model.apply(.deleted(rid(1)))
        model.apply(.deleted(rid(2)))
        #expect(model.isEmpty)
        #expect(model.selectedSeason == nil)
    }

    @Test func aWatchedChangeIsShownWithItsCount() {
        model.apply(.watched(rid(2), true))
        #expect(model.show.recordings.first { $0.id == rid(2) }?.flags.contains(.watched) == true)
        #expect(model.show.unwatchedCount == 1)
        model.apply(.watched(rid(2), false))
        #expect(model.show.unwatchedCount == 2)
    }

    @Test func aChangeForARecordingTheShowDoesNotHaveIsIgnored() {
        let before = model.show
        model.apply(.deleted(rid(99)))
        model.apply(.watched(rid(99), true))
        #expect(model.show == before)
    }

    @Test func applyingSendsNothingAndReportsNothing() {
        model.apply(.deleted(rid(1)))
        model.apply(.watched(rid(2), true))
        #expect(adapter.recordingsFake.calls.isEmpty)
        #expect(log.changes.isEmpty)
    }

    @Test func aWatchedChangeIsIgnoredWhileTheShowsOwnWatchedWriteIsInFlight() async throws {
        adapter.recordingsFake.suspend(.setWatched)
        let task = model.toggleWatched(model.show.recordings.first { $0.id == rid(1) }!)
        try await adapter.recordingsFake.waitForParked(1, of: .setWatched)
        model.apply(.watched(rid(1), false))  // the page's own wish wins
        #expect(model.show.recordings.first { $0.id == rid(1) }?.flags.contains(.watched) == true)
        adapter.recordingsFake.releaseAll()
        await task.value
    }
}
