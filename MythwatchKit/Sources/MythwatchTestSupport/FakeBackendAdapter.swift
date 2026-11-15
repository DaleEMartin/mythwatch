import Foundation
import MythwatchBackend
import MythwatchDomain
import Synchronization

/// The four service fakes bundled as a `BackendAdapter`, over one shared `FakeBackendStore`.
///
/// `liveTV` and `videoLibrary` are nil by default and `capabilities` matches the services that
/// exist (recordings, positions, bookmarks, breaks and delete; plus `.liveTV` / `.videoLibrary`
/// when given). `version` and `capabilities` can be changed at any time.
public final class FakeBackendAdapter: BackendAdapter {
    public static let defaultVersion = BackendVersion(major: 1, minor: 0, raw: "fake-1.0")

    private struct Settable {
        var version: BackendVersion
        var capabilities: BackendCapabilities
    }

    private let settable: Mutex<Settable>

    public let store: FakeBackendStore
    public let recordingsFake: FakeRecordingsService
    public let playbackStateFake: FakePlaybackStateService
    public let markupFake: FakeMarkupService
    public let mediaFake: FakeMediaLocator
    public let liveTV: (any LiveTVService)?
    public let videoLibrary: (any VideoLibraryService)?

    public init(
        recordings: [Recording] = [],
        store: FakeBackendStore? = nil,
        version: BackendVersion = FakeBackendAdapter.defaultVersion,
        capabilities: BackendCapabilities? = nil,
        baseURL: URL = URL(string: "http://fake-backend:6544")!,
        liveTV: (any LiveTVService)? = nil,
        videoLibrary: (any VideoLibraryService)? = nil
    ) {
        let store = store ?? FakeBackendStore()
        for r in recordings { store.add(r) }
        self.store = store
        recordingsFake = FakeRecordingsService(store: store)
        playbackStateFake = FakePlaybackStateService(store: store)
        markupFake = FakeMarkupService(store: store)
        mediaFake = FakeMediaLocator(baseURL: baseURL)
        self.liveTV = liveTV
        self.videoLibrary = videoLibrary
        var derived: BackendCapabilities = [
            .recordings, .resumePosition, .bookmarks, .commercialBreaks, .deleteRecording,
        ]
        if liveTV != nil { derived.insert(.liveTV) }
        if videoLibrary != nil { derived.insert(.videoLibrary) }
        settable = Mutex(Settable(version: version, capabilities: capabilities ?? derived))
    }

    public var version: BackendVersion {
        get { settable.withLock { $0.version } }
        set { settable.withLock { $0.version = newValue } }
    }

    public var capabilities: BackendCapabilities {
        get { settable.withLock { $0.capabilities } }
        set { settable.withLock { $0.capabilities = newValue } }
    }

    public var recordings: any RecordingsService { recordingsFake }
    public var playbackState: any PlaybackStateService { playbackStateFake }
    public var markup: any MarkupService { markupFake }
    public var media: any MediaLocator { mediaFake }
}

/// A `BackendAdapterFactory` for tests: `supports` is a closure (every version by default),
/// `makeRequests` records each `makeAdapter` call, and it returns the adapter it was given.
public final class FakeAdapterFactory: BackendAdapterFactory {
    public struct MakeRequest: Equatable, Sendable {
        public let connection: BackendConnection
        public let version: BackendVersion
        public init(connection: BackendConnection, version: BackendVersion) {
            self.connection = connection
            self.version = version
        }
    }

    public let name: String
    public let adapter: FakeBackendAdapter
    private let supportsVersion: @Sendable (BackendVersion) -> Bool
    private let log = FakeCallLog<MakeRequest>()

    public init(
        name: String = "Fake backend",
        adapter: FakeBackendAdapter = FakeBackendAdapter(),
        supports: @escaping @Sendable (BackendVersion) -> Bool = { _ in true }
    ) {
        self.name = name
        self.adapter = adapter
        self.supportsVersion = supports
    }

    /// Every `makeAdapter` call so far, oldest first.
    public var makeRequests: [MakeRequest] { log.calls }

    public func supports(_ version: BackendVersion) -> Bool { supportsVersion(version) }

    public func makeAdapter(
        connection: BackendConnection, version: BackendVersion, transport: any HTTPTransport
    ) -> any BackendAdapter {
        log.append(MakeRequest(connection: connection, version: version))
        return adapter
    }
}
