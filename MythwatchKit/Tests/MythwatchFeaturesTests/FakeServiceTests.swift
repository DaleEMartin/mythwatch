import Foundation
import MythwatchDomain
import MythwatchTestSupport
import Testing

private let id1 = RecordingID(rawValue: 1)
private let id2 = RecordingID(rawValue: 2)
private let missing = RecordingID(rawValue: 404)

private func makeStore() -> FakeBackendStore {
    FakeBackendStore(recordings: [.fixture(id: id1, title: "One"), .fixture(id: id2, title: "Two")])
}

@Suite("FakeRecordingsService")
struct FakeRecordingsServiceTests {
    @Test func listsRecordingsInInsertionOrder() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        #expect(try await fake.allRecordings().map(\.id) == [id1, id2])
    }

    @Test func fetchesByIDAndThrowsNotFoundForUnknown() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        #expect(try await fake.recording(id: id2).title == "Two")
        await #expect(throws: BackendError.notFound) { try await fake.recording(id: missing) }
    }

    @Test func setWatchedChangesTheStoredFlagBothWays() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        try await fake.setWatched(true, id: id1)
        #expect(try await fake.recording(id: id1).flags.contains(.watched))
        #expect(try await fake.allRecordings().first?.flags.contains(.watched) == true)
        try await fake.setWatched(false, id: id1)
        #expect(try await fake.recording(id: id1).flags.contains(.watched) == false)
    }

    @Test func setWatchedOnUnknownIDIsRejected() async {
        let fake = FakeRecordingsService(store: makeStore())
        await #expect(throws: BackendError.rejected("no such recording")) {
            try await fake.setWatched(true, id: missing)
        }
    }

    @Test func deleteMarksPendingSoTheListSkipsItButFetchStillFindsIt() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        try await fake.delete(id: id1, allowRerecord: false)
        #expect(try await fake.allRecordings().map(\.id) == [id2])
        #expect(try await fake.recording(id: id1).flags.contains(.deletePending))
    }

    @Test func deleteOfUnknownIDIsRejected() async {
        let fake = FakeRecordingsService(store: makeStore())
        await #expect(throws: BackendError.rejected("no such recording")) {
            try await fake.delete(id: missing, allowRerecord: true)
        }
    }

    @Test func callLogKeepsOrderAndArguments() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        _ = try await fake.allRecordings()
        _ = try await fake.recording(id: id1)
        try await fake.setWatched(true, id: id2)
        try await fake.delete(id: id1, allowRerecord: true)
        #expect(fake.calls == [
            .allRecordings, .recording(id1), .setWatched(true, id2),
            .delete(id1, allowRerecord: true),
        ])
    }

    @Test func injectedErrorIsThrownOnceThenCleared() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.failNext(.timedOut)
        await #expect(throws: BackendError.timedOut) { try await fake.allRecordings() }
        #expect(try await fake.allRecordings().count == 2)
    }

    @Test func injectedErrorCanTargetOneMethod() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.failNext(.notAuthorized, on: .setWatched)
        _ = try await fake.allRecordings()  // other method unaffected, error not consumed
        await #expect(throws: BackendError.notAuthorized) { try await fake.setWatched(true, id: id1) }
        try await fake.setWatched(true, id: id1)
    }

    @Test func persistentErrorKeepsFailingUntilCleared() async throws {
        let fake = FakeRecordingsService(store: makeStore())
        fake.failAlways(.unreachable("down"))
        for _ in 0..<3 {
            await #expect(throws: BackendError.unreachable("down")) { try await fake.allRecordings() }
        }
        fake.clearFailures()
        #expect(try await fake.allRecordings().count == 2)
    }

    @Test func failingCallIsStillLoggedAndChangesNothing() async throws {
        let store = makeStore()
        let fake = FakeRecordingsService(store: store)
        fake.failNext(.timedOut)
        await #expect(throws: BackendError.timedOut) { try await fake.setWatched(true, id: id1) }
        #expect(fake.calls == [.setWatched(true, id1)])
        #expect(store.recording(id: id1)?.flags.contains(.watched) == false)
    }
}

@Suite("FakePlaybackStateService")
struct FakePlaybackStateServiceTests {
    @Test func startsEmpty() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        #expect(try await fake.resumePosition(for: id1) == nil)
        #expect(try await fake.bookmark(for: id1) == nil)
    }

    @Test func resumePositionRoundTripsAndKeepsTheFlagConsistent() async throws {
        let store = makeStore()
        let fake = FakePlaybackStateService(store: store)
        try await fake.setResumePosition(.seconds(90), for: id1)
        #expect(try await fake.resumePosition(for: id1) == .seconds(90))
        #expect(store.recording(id: id1)?.flags.contains(.hasResumePosition) == true)
        try await fake.setResumePosition(nil, for: id1)
        #expect(try await fake.resumePosition(for: id1) == nil)
        #expect(store.recording(id: id1)?.flags.contains(.hasResumePosition) == false)
    }

    @Test func bookmarkRoundTripsAndKeepsTheFlagConsistent() async throws {
        let store = makeStore()
        let fake = FakePlaybackStateService(store: store)
        try await fake.setBookmark(.seconds(30), for: id2)
        #expect(try await fake.bookmark(for: id2) == .seconds(30))
        #expect(store.recording(id: id2)?.flags.contains(.hasBookmark) == true)
        try await fake.setBookmark(nil, for: id2)
        #expect(try await fake.bookmark(for: id2) == nil)
        #expect(store.recording(id: id2)?.flags.contains(.hasBookmark) == false)
    }

    @Test func zeroClearsLikeTheRealBackendsOffsetZero() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        try await fake.setResumePosition(.seconds(5), for: id1)
        try await fake.setResumePosition(.zero, for: id1)
        #expect(try await fake.resumePosition(for: id1) == nil)
    }

    @Test func negativePositionIsRejectedAndStoresNothing() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        await #expect(throws: BackendError.http(status: 400, message: nil)) {
            try await fake.setBookmark(.seconds(-1), for: id1)
        }
        #expect(try await fake.bookmark(for: id1) == nil)
    }

    @Test func writingToAnUnknownRecordingIsRejectedButReadingGivesNil() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        await #expect(throws: BackendError.rejected("no such recording")) {
            try await fake.setResumePosition(.seconds(1), for: missing)
        }
        #expect(try await fake.resumePosition(for: missing) == nil)
    }

    @Test func writeThroughOneServiceIsVisibleThroughAnother() async throws {
        let store = makeStore()
        let playback = FakePlaybackStateService(store: store)
        let recordings = FakeRecordingsService(store: store)
        try await playback.setResumePosition(.seconds(10), for: id1)
        try await playback.setBookmark(.seconds(20), for: id1)
        let flags = try await recordings.recording(id: id1).flags
        #expect(flags.contains(.hasResumePosition) && flags.contains(.hasBookmark))
        try await recordings.setWatched(true, id: id1)
        #expect(try await playback.resumePosition(for: id1) == .seconds(10))
    }

    @Test func callLogKeepsOrderAndArguments() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        _ = try await fake.resumePosition(for: id1)
        try await fake.setResumePosition(.seconds(3), for: id1)
        _ = try await fake.bookmark(for: id2)
        try await fake.setBookmark(nil, for: id2)
        #expect(fake.calls == [
            .resumePosition(id1), .setResumePosition(.seconds(3), id1), .bookmark(id2),
            .setBookmark(nil, id2),
        ])
    }

    @Test func injectedErrorIsThrownOnceThenCleared() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        fake.failNext(.timedOut, on: .setResumePosition)
        await #expect(throws: BackendError.timedOut) {
            try await fake.setResumePosition(.seconds(1), for: id1)
        }
        try await fake.setResumePosition(.seconds(1), for: id1)
        #expect(try await fake.resumePosition(for: id1) == .seconds(1))
    }

    @Test func persistentErrorKeepsFailingUntilCleared() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        fake.failAlways(.notAuthorized)
        await #expect(throws: BackendError.notAuthorized) { try await fake.bookmark(for: id1) }
        await #expect(throws: BackendError.notAuthorized) { try await fake.bookmark(for: id1) }
        fake.clearFailures()
        #expect(try await fake.bookmark(for: id1) == nil)
    }

    @Test func failingCallIsStillLoggedAndStoresNothing() async throws {
        let fake = FakePlaybackStateService(store: makeStore())
        fake.failNext(.timedOut)
        await #expect(throws: BackendError.timedOut) {
            try await fake.setBookmark(.seconds(9), for: id1)
        }
        #expect(fake.calls == [.setBookmark(.seconds(9), id1)])
        #expect(try await fake.bookmark(for: id1) == nil)
    }
}

@Suite("FakeMarkupService")
struct FakeMarkupServiceTests {
    private let spans = [
        TimeRange(start: .seconds(10), end: .seconds(20))!,
        TimeRange(start: .seconds(30), end: .seconds(40))!,
    ]

    @Test func returnsTheStoredBreaksAndNoneForOthers() async throws {
        let store = makeStore()
        store.setCommercialBreaks(spans, for: id1)
        let fake = FakeMarkupService(store: store)
        #expect(try await fake.commercialBreaks(for: id1) == spans)
        #expect(try await fake.commercialBreaks(for: id2) == [])
        #expect(try await fake.commercialBreaks(for: missing) == [])
    }

    @Test func callLogKeepsOrderAndArguments() async throws {
        let fake = FakeMarkupService(store: makeStore())
        _ = try await fake.commercialBreaks(for: id2)
        _ = try await fake.commercialBreaks(for: id1)
        #expect(fake.calls == [.commercialBreaks(id2), .commercialBreaks(id1)])
    }

    @Test func injectedErrorIsThrownOnceThenCleared() async throws {
        let fake = FakeMarkupService(store: makeStore())
        fake.failNext(.malformedResponse("x"))
        await #expect(throws: BackendError.malformedResponse("x")) {
            try await fake.commercialBreaks(for: id1)
        }
        #expect(try await fake.commercialBreaks(for: id1) == [])
    }

    @Test func persistentErrorKeepsFailingUntilCleared() async throws {
        let fake = FakeMarkupService(store: makeStore())
        fake.failAlways(.timedOut)
        await #expect(throws: BackendError.timedOut) { try await fake.commercialBreaks(for: id1) }
        await #expect(throws: BackendError.timedOut) { try await fake.commercialBreaks(for: id1) }
        fake.clearFailures()
        _ = try await fake.commercialBreaks(for: id1)
    }

    @Test func failingCallIsStillLogged() async {
        let fake = FakeMarkupService(store: makeStore())
        fake.failNext(.timedOut)
        _ = try? await fake.commercialBreaks(for: id1)
        #expect(fake.calls == [.commercialBreaks(id1)])
    }
}

@Suite("FakeMediaLocator")
struct FakeMediaLocatorTests {
    private let base = URL(string: "http://fake-host:1234/prefix/")!
    private let recording = Recording.fixture(
        id: id1, artwork: [ArtworkReference(kind: .poster, locator: "a b/c?d=1")])

    @Test func urlsAreAbsoluteUnderTheBaseAndDeterministic() {
        let fake = FakeMediaLocator(baseURL: base)
        let stream = fake.streamURL(for: recording)
        #expect(AdapterConformance.isURL(stream, under: base))
        #expect(AdapterConformance.isURL(fake.previewImageURL(for: recording, maxWidth: 320), under: base))
        let art = fake.artworkURL(for: recording.artwork[0], maxWidth: 320)
        #expect(art.map { AdapterConformance.isURL($0, under: base) } == true)
        #expect(fake.streamURL(for: recording) == stream)
        #expect(stream != fake.streamURL(for: .fixture(id: id2)))
    }

    @Test func widthChangesPreviewAndArtworkURLs() {
        let fake = FakeMediaLocator(baseURL: base)
        #expect(
            fake.previewImageURL(for: recording, maxWidth: 160)
                != fake.previewImageURL(for: recording, maxWidth: 320))
    }

    @Test func defaultBaseURLIsAbsolute() {
        let fake = FakeMediaLocator()
        #expect(AdapterConformance.isAbsolute(fake.streamURL(for: recording)))
    }

    @Test func callLogKeepsOrderAndArguments() {
        let fake = FakeMediaLocator(baseURL: base)
        _ = fake.streamURL(for: recording)
        _ = fake.previewImageURL(for: recording, maxWidth: 640)
        _ = fake.artworkURL(for: recording.artwork[0], maxWidth: 160)
        #expect(fake.calls == [
            .streamURL(id1), .previewImageURL(id1, maxWidth: 640),
            .artworkURL(recording.artwork[0], maxWidth: 160),
        ])
    }
}

@Suite("FakeBackendStore")
struct FakeBackendStoreTests {
    @Test func addDerivesFlagsFromStoredPositions() {
        let store = FakeBackendStore()
        store.add(.fixture(id: id1, flags: [.hasBookmark]), resumePosition: .seconds(5))
        let flags = store.recording(id: id1)?.flags
        #expect(flags?.contains(.hasResumePosition) == true)
        #expect(flags?.contains(.hasBookmark) == false)
    }

    @Test func addingTheSameIDReplacesInPlace() {
        let store = FakeBackendStore(recordings: [.fixture(id: id1), .fixture(id: id2)])
        store.add(.fixture(id: id1, title: "New"))
        #expect(store.allRecordings.map(\.id) == [id1, id2])
        #expect(store.recording(id: id1)?.title == "New")
    }
}
