import Foundation
import MythwatchBackend
import MythwatchDomain

/// `GetLastPlayPos` / `GetSavedBookmark` and their setters, with `OffsetType=Duration`
/// (milliseconds). Clearing sends `OffsetType=Frame&Offset=0` (docs/BACKEND-V35.md, "Playback state").
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
        try await setPosition(position, path: "/Dvr/SetLastPlayPos", id: id)
    }

    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {
        try await setPosition(position, path: "/Dvr/SetSavedBookmark", id: id)
    }

    /// A position under 1 ms (or nil) clears. With `OffsetType=Duration` the backend turns 0 into
    /// the nearest keyframe, which may be after 0, and stores that; any other offset type is taken
    /// as a raw frame number, and frame 0 removes the mark and its flag.
    private func setPosition(_ position: Duration?, path: String, id: RecordingID) async throws {
        let milliseconds = position.map(Self.wholeMilliseconds) ?? 0
        if milliseconds < 0 {
            throw BackendError.rejected("\(path): negative offset")
        }
        let offset: [(name: String, value: String)] =
            milliseconds == 0
            ? [("OffsetType", "Frame"), ("Offset", "0")]
            : [("OffsetType", "Duration"), ("Offset", String(milliseconds))]
        try await client.postExpectingTrue(
            path: path, form: [("RecordedId", String(id.rawValue))] + offset)
    }

    /// Truncated toward zero.
    static func wholeMilliseconds(_ d: Duration) -> Int64 {
        let (seconds, attoseconds) = d.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
