import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Synchronization
import Testing

private let id1 = RecordingID(rawValue: 1)
private let id2 = RecordingID(rawValue: 2)

private func makeStore() -> FakeBackendStore {
    FakeBackendStore(recordings: [.fixture(id: id1), .fixture(id: id2)])
}

@Suite("Fake suspension points")
struct FakeSuspensionTests {
    @Test func parkedCallDoesNotCompleteUntilReleased() async throws {
        let store = makeStore()
        let fake = FakeRecordingsService(store: store)
        fake.suspend(.setWatched)
        let task = Task { try await fake.setWatched(true, id: id1) }
        try await fake.waitForParked(1, of: .setWatched)
        // The call is logged and parked, but its effect has not happened.
        #expect(fake.calls == [.setWatched(true, id1)])
        #expect(fake.parked.map(\.call) == [.setWatched(true, id1)])
        #expect(store.recording(id: id1)?.flags.contains(.watched) == false)
        fake.releaseAll()
        try await task.value
        #expect(store.recording(id: id1)?.flags.contains(.watched) == true)
        #expect(fake.parked.isEmpty)
    }

    @Test func onlySuspendedMethodsPark() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend(.setWatched)
        #expect(try await fake.allRecordings().count == 2)
        #expect(fake.parked.isEmpty)
    }

    @Test func suspendWithoutAMethodParksEveryMethod() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend()
        let a = Task { try await fake.allRecordings() }
        let b = Task { try await fake.recording(id: id1) }
        try await fake.waitForParked(2)
        fake.releaseAll()
        _ = try await a.value
        _ = try await b.value
    }

    @Test func suspendNextParksOnlyTheNextMatchingCall() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspendNext(.setWatched)
        let first = Task { try await fake.setWatched(true, id: id1) }
        try await fake.waitForParked(1)
        try await fake.setWatched(true, id: id2)  // the second call runs straight through
        fake.releaseAll()
        try await first.value
        #expect(fake.calls == [.setWatched(true, id1), .setWatched(true, id2)])
    }

    @Test func stopSuspendingLetsLaterCallsThrough() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend()
        fake.stopSuspending()
        _ = try await fake.allRecordings()
    }

    @Test func releasingWithAnErrorMakesTheCallThrowAndChangesNothing() async throws {
        let store = makeStore()
        let fake = FakeRecordingsService(store: store)
        fake.suspend(.delete)
        let task = Task { try await fake.delete(id: id1, allowRerecord: false) }
        try await fake.waitForParked(1)
        fake.releaseNext(throwing: .timedOut)
        await #expect(throws: BackendError.timedOut) { try await task.value }
        #expect(store.recording(id: id1)?.flags.contains(.deletePending) == false)
    }

    @Test func twoParkedCallsCanBeReleasedNewestFirst() async throws {
        let store = makeStore()
        let fake = FakeRecordingsService(store: store)
        fake.suspend(.setWatched)
        let first = Task { try await fake.setWatched(true, id: id1) }
        try await fake.waitForParked(1)
        let second = Task { try await fake.setWatched(true, id: id2) }
        try await fake.waitForParked(2)
        let newest = try #require(fake.parked.last)
        #expect(newest.call == .setWatched(true, id2))
        fake.release(newest)
        try await second.value
        #expect(store.recording(id: id2)?.flags.contains(.watched) == true)
        #expect(store.recording(id: id1)?.flags.contains(.watched) == false)
        #expect(fake.parked.count == 1)
        fake.releaseAll()
        try await first.value
        #expect(store.recording(id: id1)?.flags.contains(.watched) == true)
    }

    @Test func twoParkedCallsCanBeReleasedOldestFirst() async throws {
        let store = makeStore()
        let fake = FakeRecordingsService(store: store)
        fake.suspend(.setWatched)
        let first = Task { try await fake.setWatched(true, id: id1) }
        try await fake.waitForParked(1)
        let second = Task { try await fake.setWatched(true, id: id2) }
        try await fake.waitForParked(2)
        fake.releaseNext()
        try await first.value
        #expect(store.recording(id: id2)?.flags.contains(.watched) == false)
        fake.releaseNext()
        try await second.value
        #expect(store.recording(id: id2)?.flags.contains(.watched) == true)
    }

    @Test func waitForParkedReturnsOnlyOnceEnoughAreParked() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend(.setWatched)
        let waiter = Task { () -> Int in
            try await fake.waitForParked(2, of: .setWatched)
            return fake.parked.count
        }
        let first = Task { try await fake.setWatched(true, id: id1) }
        try await fake.waitForParked(1)
        let second = Task { try await fake.setWatched(true, id: id2) }
        // The waiter can only have returned after the second call parked.
        #expect(try await waiter.value >= 2)
        fake.releaseAll()
        try await first.value
        try await second.value
    }

    @Test func waitForParkedReturnsAtOnceWhenAlreadyParked() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend()
        let task = Task { try await fake.allRecordings() }
        try await fake.waitForParked(1)
        try await fake.waitForParked(1)
        try await fake.waitForParked(0)
        fake.releaseAll()
        _ = try await task.value
    }

    @Test func waitForParkedCountsOnlyTheNamedMethod() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend()
        let a = Task { try await fake.allRecordings() }
        try await fake.waitForParked(1, of: .allRecordings)
        let waiter = Task { try await fake.waitForParked(1, of: .delete) }
        let b = Task { try await fake.delete(id: id1, allowRerecord: false) }
        try await waiter.value
        fake.releaseAll()
        _ = try await a.value
        try await b.value
    }

    @Test func cancellingAParkedCallThrowsAndLeavesNothingParked() async throws {
        let store = makeStore()
        let fake = FakeRecordingsService(store: store)
        fake.suspend(.setWatched)
        let task = Task { try await fake.setWatched(true, id: id1) }
        try await fake.waitForParked(1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fake.parked.isEmpty)
        #expect(store.recording(id: id1)?.flags.contains(.watched) == false)
        fake.releaseAll()  // nothing to resume, and no double resume
    }

    @Test func aCallMadeAfterItsTaskWasCancelledDoesNotPark() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend(.setWatched)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await fake.setWatched(true, id: id1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fake.parked.isEmpty)
    }

    @Test func cancellingAWaiterEndsItWithCancellation() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        let waiter = Task { try await fake.waitForParked(5) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
    }

    @Test func releasedCallIsNotReleasedTwice() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.suspend()
        let task = Task { try await fake.allRecordings() }
        try await fake.waitForParked(1)
        let parked = try #require(fake.parked.first)
        #expect(fake.release(parked))
        #expect(fake.release(parked) == false)
        _ = try await task.value
    }

    @Test func playbackStateMarkupAndInjectionComposeWithSuspension() async throws {
        let store = makeStore()
        let playback = FakePlaybackStateService(store: store)
        playback.suspend(.setResumePosition)
        let save = Task { try await playback.setResumePosition(.seconds(42), for: id1) }
        try await playback.waitForParked(1)
        // "A save is in flight": the position is not stored yet.
        #expect(try await playback.resumePosition(for: id1) == nil)
        playback.releaseAll()
        try await save.value
        #expect(try await playback.resumePosition(for: id1) == .seconds(42))

        let markup = FakeMarkupService(store: store)
        markup.suspend()
        let breaks = Task { try await markup.commercialBreaks(for: id1) }
        try await markup.waitForParked(1)
        markup.releaseAll()
        _ = try await breaks.value

        // An injected error wins over suspension: the call fails at once, nothing parks.
        playback.failNext(.timedOut)
        await #expect(throws: BackendError.timedOut) {
            try await playback.setResumePosition(.seconds(1), for: id1)
        }
        #expect(playback.parked.isEmpty)
    }
}
