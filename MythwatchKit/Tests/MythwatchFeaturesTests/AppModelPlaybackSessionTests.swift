import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

private let alpha = BackendConnection(baseURL: URL(string: "http://alpha:6544")!)

/// The engines `makeEngine` has handed out, newest last.
@MainActor private final class EngineFactory {
    var made: [FakePlayerEngine] = []
    func make() -> any PlayerEngine {
        let engine = FakePlayerEngine()
        made.append(engine)
        return engine
    }
}

@MainActor
@Suite("AppModel.makePlaybackSession", .timeLimit(.minutes(1)))
struct AppModelPlaybackSessionTests {
    private let recording = episode(1)

    private func connectedModel(
        _ settings: AppSettings, adapter: FakeBackendAdapter, engines: EngineFactory, clock: TestClock
    ) async -> AppModel {
        let transport = FixtureTransport()
        transport.stub(.get, path: "/Myth/GetBackendInfo", body: #"{"BackendInfo": {"Build": {"Version": "v35.0"}}}"#)
        transport.stub(.get, path: "/Myth/GetHostName", body: #"{"String": "alpha-host"}"#)
        var registry = AdapterRegistry()
        registry.register(FakeAdapterFactory(adapter: adapter))
        let model = AppModel(
            settings: InMemorySettingsStore(settings),
            connector: BackendConnector(registry: registry, transport: transport),
            makeEngine: { engines.make() },
            discovery: FakeBackendDiscovery(),
            now: clock.now)
        await model.connect()
        return model
    }

    @Test func aSessionUsesTheAdaptersServicesAFreshEngineAndTheCurrentSettings() async throws {
        let adapter = FakeBackendAdapter()
        adapter.store.add(recording, resumePosition: .seconds(600))
        let engines = EngineFactory()
        let clock = TestClock()
        var settings = AppSettings(backend: alpha)
        settings.skipForwardSeconds = 45
        let model = await connectedModel(settings, adapter: adapter, engines: engines, clock: clock)

        let session = model.makePlaybackSession(recording, start: .resume)
        #expect(engines.made.count == 1)
        let engine = try #require(engines.made.first)
        await session.start()
        await engine.waitUntilDelivered()

        #expect(adapter.playbackStateFake.calls == [.resumePosition(rid(1))])
        #expect(adapter.markupFake.calls == [.commercialBreaks(rid(1))])
        #expect(adapter.mediaFake.calls == [.streamURL(rid(1))])
        let url = adapter.mediaFake.streamURL(for: recording)
        #expect(engine.calls == [.load(url: url, startAt: .seconds(600)), .play])

        session.skipForward()  // the settings' 45 s, not the default 30 s
        #expect(engine.calls.last == .seek(to: .seconds(645)))

        // The model's clock drives the save interval.
        clock.advance(by: .seconds(30))
        engine.advancePlayback(by: .seconds(1))
        await engine.waitUntilDelivered()
        let outcome = await session.finish()
        #expect(adapter.playbackStateFake.calls.contains(.setResumePosition(.seconds(646), rid(1))))
        #expect(outcome.position == .seconds(646))
        #expect(adapter.recordingsFake.calls.isEmpty)
    }

    @Test func eachSessionGetsItsOwnEngine() async {
        let adapter = FakeBackendAdapter(recordings: [recording])
        let engines = EngineFactory()
        let model = await connectedModel(
            AppSettings(backend: alpha), adapter: adapter, engines: engines, clock: TestClock())
        _ = model.makePlaybackSession(recording, start: .beginning)
        _ = model.makePlaybackSession(recording, start: .beginning)
        #expect(engines.made.count == 2)
        #expect(engines.made[0] !== engines.made[1])
    }

    @Test func settingsAreReadWhenTheSessionIsMade() async throws {
        let adapter = FakeBackendAdapter(recordings: [recording])
        let engines = EngineFactory()
        let store = InMemorySettingsStore(AppSettings(backend: alpha))
        let transport = FixtureTransport()
        transport.stub(.get, path: "/Myth/GetBackendInfo", body: #"{"BackendInfo": {"Build": {"Version": "v35.0"}}}"#)
        transport.stub(.get, path: "/Myth/GetHostName", body: #"{"String": "alpha-host"}"#)
        var registry = AdapterRegistry()
        registry.register(FakeAdapterFactory(adapter: adapter))
        let model = AppModel(
            settings: store, connector: BackendConnector(registry: registry, transport: transport),
            makeEngine: { engines.make() }, discovery: FakeBackendDiscovery(), now: TestClock().now)
        await model.connect()
        var changed = store.load()
        changed.skipBackwardSeconds = 20
        store.save(changed)

        let session = model.makePlaybackSession(recording, start: .beginning)
        await session.start()
        let engine = try #require(engines.made.first)
        engine.emit(PlayerSnapshot(status: .playing, position: .seconds(100), duration: nil, rate: 1))
        await engine.waitUntilDelivered()
        session.skipBackward()
        #expect(engine.calls.last == .seek(to: .seconds(80)))
        _ = await session.finish()
    }

    // MARK: Leaving and retrying (M3-4)

    @Test func finishingPlaybackSavesTheplaceThenReloadsTheLibrary() async throws {
        let adapter = FakeBackendAdapter(recordings: [recording])
        let engines = EngineFactory()
        let model = await connectedModel(
            AppSettings(backend: alpha), adapter: adapter, engines: engines, clock: TestClock())
        let library = model.makeLibraryModel()
        await library.load()
        #expect(library.library.value?.continueWatching.isEmpty == true)

        let session = model.makePlaybackSession(recording, start: .beginning)
        await session.start()
        let engine = try #require(engines.made.first)
        engine.emit(PlayerSnapshot(status: .playing, position: .seconds(300), duration: .seconds(1800), rate: 1))
        await engine.waitUntilDelivered()

        let outcome = await model.finishPlayback(session)
        #expect(outcome.position == .seconds(300))
        #expect(engine.calls.last == .stop)
        // The reload ran after the save: the library already shows the recording as part watched.
        #expect(adapter.recordingsFake.calls == [.allRecordings, .allRecordings])
        #expect(library.library.value?.continueWatching.map(\.id) == [recording.id])
    }

    @Test func finishingPlaybackWithNoLibraryModelStillFinishes() async {
        let adapter = FakeBackendAdapter(recordings: [recording])
        let model = await connectedModel(
            AppSettings(backend: alpha), adapter: adapter, engines: EngineFactory(), clock: TestClock())
        let session = model.makePlaybackSession(recording, start: .beginning)
        let outcome = await model.finishPlayback(session)
        #expect(outcome == PlaybackOutcome(position: .zero, reachedEnd: false, markedWatched: false))
        #expect(adapter.recordingsFake.calls.isEmpty)
    }

    @Test func retryFinishesTheFailedSessionThenResumesWhereItStopped() async throws {
        let adapter = FakeBackendAdapter(recordings: [recording])
        let engines = EngineFactory()
        let model = await connectedModel(
            AppSettings(backend: alpha), adapter: adapter, engines: engines, clock: TestClock())
        let library = model.makeLibraryModel()
        await library.load()

        let failed = model.makePlaybackSession(recording, start: .beginning)
        await failed.start()
        let first = try #require(engines.made.first)
        first.emit(PlayerSnapshot(status: .playing, position: .seconds(500), duration: .seconds(1800), rate: 1))
        first.emitFailed("diag")
        await first.waitUntilDelivered()

        let retry = await model.retryPlayback(failed, recording: recording)
        #expect(first.calls.last == .stop)
        #expect(engines.made.count == 2)
        #expect(adapter.recordingsFake.calls == [.allRecordings])  // no library reload for a retry

        await retry.start()
        let second = try #require(engines.made.last)
        #expect(second.calls.first == .load(url: adapter.mediaFake.streamURL(for: recording), startAt: .seconds(500)))
        _ = await retry.finish()
    }
}
