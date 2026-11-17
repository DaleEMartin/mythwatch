import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

private let alpha = BackendConnection(baseURL: URL(string: "http://alpha:6544")!)

/// An `AppModel` already connected to a fake backend through the real connector and probe.
@MainActor
private struct Harness {
    let adapter: FakeBackendAdapter
    let model: AppModel

    static func connected(_ recordings: [Recording]) async -> Harness {
        let adapter = FakeBackendAdapter(recordings: recordings)
        let transport = FixtureTransport()
        transport.stub(.get, path: "/Myth/GetBackendInfo", body: #"{"BackendInfo": {"Build": {"Version": "v35.0"}}}"#)
        transport.stub(.get, path: "/Myth/GetHostName", body: #"{"String": "alpha-host"}"#)
        var registry = AdapterRegistry()
        registry.register(FakeAdapterFactory(adapter: adapter))
        let model = AppModel(
            settings: InMemorySettingsStore(AppSettings(backend: alpha)),
            connector: BackendConnector(registry: registry, transport: transport),
            makeEngine: { fatalError("not used") },
            discovery: FakeBackendDiscovery(),
            now: TestClock().now)
        await model.connect()
        return Harness(adapter: adapter, model: model)
    }
}

@MainActor
@Suite("AppModel view-model factories")
struct AppModelFactoryTests {
    private let recordings = [
        episode(1), episode(2), episode(3, title: "Harbour Lights", key: "KEY-HARBOUR"),
    ]

    @Test func aLibraryModelFromTheFactoryUsesTheSessionsAdapter() async {
        let h = await Harness.connected(recordings)
        let library = h.model.makeLibraryModel()
        await library.load()
        #expect(h.adapter.recordingsFake.calls == [.allRecordings])
        #expect(library.library.value?.shows.count == 2)
    }

    @Test func aShowModelFromTheFactoryWritesThroughTheSessionsAdapter() async throws {
        let h = await Harness.connected(recordings)
        let library = h.model.makeLibraryModel()
        await library.load()
        let show = try #require(library.library.value?.shows.first { $0.title == "Garden Tales" })
        let model = h.model.makeShowModel(show)
        #expect(model.show == show)
        await model.toggleWatched(model.seasons[0].episodes[0]).value
        await model.delete(model.seasons[0].episodes[1], allowRerecord: false).value
        #expect(h.adapter.recordingsFake.calls.suffix(2) == [
            .setWatched(true, rid(1)), .delete(rid(2), allowRerecord: false),
        ])
    }

    @Test func anEpisodeDetailModelFromTheFactoryReadsThroughTheSessionsAdapter() async {
        let h = await Harness.connected(recordings)
        h.adapter.store.add(recordings[0], resumePosition: .seconds(90))
        let model = h.model.makeEpisodeDetailModel(recordings[0])
        #expect(model.recording == recordings[0])
        await model.load()
        #expect(h.adapter.playbackStateFake.calls.contains(.resumePosition(rid(1))))
        #expect(model.startOptions.map(\.point) == [.resume, .beginning])
    }

    @Test func aWriteInAShowModelReachesTheLibraryModelFromTheSameAppModel() async throws {
        let h = await Harness.connected(recordings)
        let library = h.model.makeLibraryModel()
        await library.load()
        let show = try #require(library.library.value?.shows.first { $0.title == "Garden Tales" })
        let model = h.model.makeShowModel(show)

        await model.toggleWatched(model.seasons[0].episodes[0]).value
        let afterToggle = try #require(library.library.value?.shows.first { $0.title == "Garden Tales" })
        #expect(afterToggle.unwatchedCount == 1)

        await model.delete(model.seasons[0].episodes[1], allowRerecord: false).value
        #expect(library.library.value?.shows.first { $0.title == "Garden Tales" }?.episodeCount == 1)
        #expect(library.library.value?.recentlyRecorded.contains { $0.id == rid(2) } == false)

        await model.delete(model.seasons[0].episodes[0], allowRerecord: false).value
        #expect(library.library.value?.shows.map(\.title) == ["Harbour Lights"])
        // Nothing fetched the list again: the library was updated locally.
        #expect(h.adapter.recordingsFake.calls.filter { $0 == .allRecordings }.count == 1)
    }

    @Test func aFailedWriteLeavesTheLibraryModelAlone() async throws {
        let h = await Harness.connected(recordings)
        let library = h.model.makeLibraryModel()
        await library.load()
        let before = library.library.value
        let model = h.model.makeShowModel(try #require(before?.shows.first { $0.title == "Garden Tales" }))
        h.adapter.recordingsFake.failNext(.rejected("DIAG"))
        await model.toggleWatched(model.seasons[0].episodes[0]).value
        #expect(library.library.value == before)
    }

    @Test func aShowModelMadeWithoutALibraryModelStillWorks() async throws {
        let h = await Harness.connected(recordings)
        let show = LibraryBuilder.build(from: recordings).shows[0]
        let model = h.model.makeShowModel(show)
        await model.toggleWatched(model.seasons[0].episodes[0]).value
        #expect(h.adapter.recordingsFake.calls == [.setWatched(true, rid(1))])
    }

    @Test func aDeleteOnTheEpisodePageReachesTheLibraryAndTheShowPage() async throws {
        let h = await Harness.connected(recordings)
        let library = h.model.makeLibraryModel()
        await library.load()
        let show = try #require(library.library.value?.shows.first { $0.title == "Garden Tales" })
        let showModel = h.model.makeShowModel(show)
        let detail = h.model.makeEpisodeDetailModel(recordings[0])
        await detail.delete(allowRerecord: false).value
        #expect(h.adapter.recordingsFake.calls.last == .delete(rid(1), allowRerecord: false))
        #expect(detail.isDeleted)
        #expect(showModel.show.recordings.map(\.id) == [rid(2)])
        #expect(library.library.value?.shows.first { $0.title == "Garden Tales" }?.episodeCount == 1)
        #expect(h.adapter.recordingsFake.calls.filter { $0 == .allRecordings }.count == 1)
    }

    @Test func aShowModelThatIsGoneIsNotKeptAliveByTheAppModel() async throws {
        let h = await Harness.connected(recordings)
        weak var weakShow: ShowViewModel?
        do {
            let model = h.model.makeShowModel(LibraryBuilder.build(from: recordings).shows[0])
            weakShow = model
        }
        #expect(weakShow == nil)
        // An episode page opened from a shelf, with no show page alive, still deletes.
        let detail = h.model.makeEpisodeDetailModel(recordings[2])
        await detail.delete(allowRerecord: false).value
        #expect(detail.isDeleted)
    }

    @Test func artworkFromTheFactoryUsesTheSessionsMediaLocator() async {
        let h = await Harness.connected(recordings)
        let urls = h.model.makeArtwork().thumbnail(for: recordings[0], maxWidth: 320)
        #expect(urls == [h.adapter.mediaFake.previewImageURL(for: recordings[0], maxWidth: 320)])
    }

    @Test func aLibraryModelThatIsGoneIsNotKeptAliveByTheAppModel() async throws {
        let h = await Harness.connected(recordings)
        weak var weakLibrary: LibraryViewModel?
        do {
            let library = h.model.makeLibraryModel()
            weakLibrary = library
        }
        #expect(weakLibrary == nil)
    }
}
