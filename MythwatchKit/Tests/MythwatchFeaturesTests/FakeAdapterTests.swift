import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchTestSupport
import Testing

private let id1 = RecordingID(rawValue: 1)
private let connection = BackendConnection(baseURL: URL(string: "http://backend:6544")!)

@Suite("FakeBackendAdapter")
struct FakeBackendAdapterTests {
    @Test func defaultsHaveNoOptionalServicesAndCapabilitiesToMatch() {
        let adapter = FakeBackendAdapter()
        #expect(adapter.liveTV == nil)
        #expect(adapter.videoLibrary == nil)
        #expect(adapter.capabilities == [
            .recordings, .resumePosition, .bookmarks, .commercialBreaks, .deleteRecording,
        ])
    }

    @Test func givingAnOptionalServiceAddsItsCapability() {
        let adapter = FakeBackendAdapter(liveTV: FakeLiveTVService(), videoLibrary: FakeVideoLibraryService())
        #expect(adapter.liveTV != nil && adapter.videoLibrary != nil)
        #expect(adapter.capabilities.contains(.liveTV) && adapter.capabilities.contains(.videoLibrary))
    }

    @Test func versionAndCapabilitiesAreSettable() {
        let adapter = FakeBackendAdapter()
        adapter.version = BackendVersion(major: 40, minor: 1, raw: "v40.1")
        adapter.capabilities = [.recordings]
        #expect(adapter.version.major == 40)
        #expect(adapter.capabilities == [.recordings])
    }

    @Test func recordingsSeedTheStore() async throws {
        let adapter = FakeBackendAdapter(recordings: [.fixture(id: id1)])
        #expect(try await adapter.recordings.allRecordings().map(\.id) == [id1])
    }

    @Test func fourFakesShareOneStore() async throws {
        let adapter = FakeBackendAdapter(recordings: [.fixture(id: id1)])
        try await adapter.playbackState.setResumePosition(.seconds(7), for: id1)
        try await adapter.recordings.setWatched(true, id: id1)
        let recording = try await adapter.recordings.recording(id: id1)
        #expect(recording.flags.contains(.hasResumePosition) && recording.flags.contains(.watched))
        adapter.store.setCommercialBreaks([TimeRange(start: .seconds(1), end: .seconds(2))!], for: id1)
        #expect(try await adapter.markup.commercialBreaks(for: id1).count == 1)
        #expect(AdapterConformance.isURL(adapter.media.streamURL(for: recording), under: adapter.mediaFake.baseURL))
    }

    @Test func concreteFakesAreReachableForInspection() async throws {
        let adapter = FakeBackendAdapter(recordings: [.fixture(id: id1)])
        _ = try await adapter.recordings.recording(id: id1)
        #expect(adapter.recordingsFake.calls == [.recording(id1)])
        #expect(adapter.playbackStateFake.calls.isEmpty)
        #expect(adapter.markupFake.calls.isEmpty)
        #expect(adapter.mediaFake.calls.isEmpty)
    }

    @Test func aSharedStoreCanBeGivenIn() async throws {
        let store = FakeBackendStore(recordings: [.fixture(id: id1)])
        let a = FakeBackendAdapter(store: store)
        let b = FakeBackendAdapter(store: store)
        try await a.recordings.setWatched(true, id: id1)
        #expect(try await b.recordings.recording(id: id1).flags.contains(.watched))
    }
}

@Suite("FakeAdapterFactory")
struct FakeAdapterFactoryTests {
    private let v35 = BackendVersion(major: 35, minor: 0, raw: "v35.0")
    private let v36 = BackendVersion(major: 36, minor: 0, raw: "v36.0")

    @Test func supportsIsConfigurableAndDefaultsToEverything() {
        #expect(FakeAdapterFactory().supports(v36))
        let only35 = FakeAdapterFactory(supports: { $0.major == 35 })
        #expect(only35.supports(v35))
        #expect(only35.supports(v36) == false)
    }

    @Test func hasANameAndKeepsIt() {
        #expect(FakeAdapterFactory(name: "Fake v35").name == "Fake v35")
    }

    @Test func returnsTheGivenAdapterAndRecordsWhatItWasAskedToMake() async throws {
        let adapter = FakeBackendAdapter(recordings: [.fixture(id: id1)])
        let factory = FakeAdapterFactory(adapter: adapter)
        let made = factory.makeAdapter(connection: connection, version: v35, transport: FixtureTransport())
        #expect(try await made.recordings.allRecordings().map(\.id) == [id1])
        _ = factory.makeAdapter(connection: connection, version: v36, transport: FixtureTransport())
        #expect(factory.makeRequests == [
            .init(connection: connection, version: v35), .init(connection: connection, version: v36),
        ])
    }

    @Test func worksThroughTheRealRegistry() async throws {
        let first = FakeAdapterFactory(name: "first", supports: { $0.major == 35 })
        let second = FakeAdapterFactory(name: "second", supports: { $0.major == 36 })
        var registry = AdapterRegistry()
        registry.register(first)
        registry.register(second)
        #expect(try registry.factory(for: v36).name == "second")
        #expect(try registry.factory(for: v35).name == "first")
        #expect(throws: BackendError.unsupportedVersion("v99")) {
            try registry.factory(for: BackendVersion(major: 99, minor: 0, raw: "v99"))
        }
    }

    @Test func worksThroughTheRealConnector() async throws {
        let transport = FixtureTransport()
        transport.stub(
            .get, path: "/Myth/GetBackendInfo",
            body: #"{"BackendInfo":{"Build":{"Version":"v36.0"}}}"#)
        transport.stub(.get, path: "/Myth/GetHostName", body: #"{"String":"box"}"#)
        let factory = FakeAdapterFactory(supports: { $0.major == 36 })
        var registry = AdapterRegistry()
        registry.register(factory)
        let adapter = try await BackendConnector(registry: registry, transport: transport)
            .connect(connection)
        #expect(adapter is FakeBackendAdapter)
        #expect(factory.makeRequests.map(\.version.major) == [36])
    }
}
