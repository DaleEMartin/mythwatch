import Foundation
import MythwatchBackend
import MythwatchDomain

/// The adapter for MythTV 35.x. The app registers `V35AdapterFactory` in its composition root.
public struct V35AdapterFactory: BackendAdapterFactory {
    public init() {}

    public var name: String { "MythTV v35" }

    public func supports(_ version: BackendVersion) -> Bool { version.major == 35 }

    public func makeAdapter(
        connection: BackendConnection, version: BackendVersion, transport: any HTTPTransport
    ) -> any BackendAdapter {
        V35Adapter(connection: connection, version: version, transport: transport)
    }
}

struct V35Adapter: BackendAdapter {
    let version: BackendVersion
    let recordings: any RecordingsService
    let playbackState: any PlaybackStateService
    let markup: any MarkupService
    let media: any MediaLocator

    /// Per docs/BACKEND-V35.md, "Capabilities". Every listed write is implemented.
    var capabilities: BackendCapabilities {
        [.recordings, .resumePosition, .bookmarks, .commercialBreaks, .deleteRecording]
    }
    var liveTV: (any LiveTVService)? { nil }
    var videoLibrary: (any VideoLibraryService)? { nil }

    init(connection: BackendConnection, version: BackendVersion, transport: any HTTPTransport) {
        self.version = version
        recordings = V35RecordingsService(connection: connection, transport: transport)
        playbackState = V35PlaybackStateService(connection: connection, transport: transport)
        markup = V35MarkupService(connection: connection, transport: transport)
        media = V35MediaLocator(connection: connection)
    }
}
