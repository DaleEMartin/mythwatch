import Foundation
import MythwatchBackend
import MythwatchDomain

/// `GetLastPlayPos` and `GetSavedBookmark` with `OffsetType=Duration` (milliseconds). The setters
/// are not implemented until M3-5 / M5-1 and send no request.
struct V35PlaybackStateService: PlaybackStateService {
    private let client: V35Client

    init(connection: BackendConnection, transport: any HTTPTransport) {
        self.client = V35Client(connection: connection, transport: transport)
    }

    func resumePosition(for id: RecordingID) async throws -> Duration? {
        try await position(path: "/Dvr/GetLastPlayPos", id: id)
    }

    func bookmark(for id: RecordingID) async throws -> Duration? {
        try await position(path: "/Dvr/GetSavedBookmark", id: id)
    }

    /// `"0"` means none and `"-1"` means the position cannot be expressed as a duration: both nil.
    private func position(path: String, id: RecordingID) async throws -> Duration? {
        let milliseconds = try await client.get(
            LongEnvelopeDTO.self, path: path,
            query: [("RecordedId", String(id.rawValue)), ("OffsetType", "Duration")]
        ).value
        return milliseconds > 0 ? .milliseconds(milliseconds) : nil
    }

    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {
        throw V35NotImplemented.error
    }

    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {
        throw V35NotImplemented.error
    }
}
