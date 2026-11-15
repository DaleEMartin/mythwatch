import Foundation
import MythwatchDomain
import Synchronization

private let unknownRecording = BackendError.rejected("no such recording")

/// In-memory `RecordingsService` over a shared `FakeBackendStore`.
///
/// Write behaviour follows docs/BACKEND-V35.md: a write to an unknown id is `.rejected`;
/// `delete` is asynchronous on a real backend, so it marks the recording `deletePending`:
/// `allRecordings()` then skips it and `recording(id:)` still returns it.
public final class FakeRecordingsService: RecordingsService, FakeCallControls {
    public enum Call: FakeCall {
        case allRecordings
        case recording(RecordingID)
        case setWatched(Bool, RecordingID)
        case delete(RecordingID, allowRerecord: Bool)

        public enum Method: Hashable, Sendable { case allRecordings, recording, setWatched, delete }
        public var method: Method {
            switch self {
            case .allRecordings: .allRecordings
            case .recording: .recording
            case .setWatched: .setWatched
            case .delete: .delete
            }
        }
    }

    public let store: FakeBackendStore
    public let recorder = FakeCallRecorder<Call>()

    public init(store: FakeBackendStore = FakeBackendStore()) { self.store = store }

    public func allRecordings() async throws -> [Recording] {
        try await recorder.begin(.allRecordings)
        return store.allRecordings.filter { !$0.flags.contains(.deletePending) }
    }

    public func recording(id: RecordingID) async throws -> Recording {
        try await recorder.begin(.recording(id))
        guard let found = store.recording(id: id) else { throw BackendError.notFound }
        return found
    }

    public func setWatched(_ watched: Bool, id: RecordingID) async throws {
        try await recorder.begin(.setWatched(watched, id))
        guard store.setWatched(watched, id: id) else { throw unknownRecording }
    }

    public func delete(id: RecordingID, allowRerecord: Bool) async throws {
        try await recorder.begin(.delete(id, allowRerecord: allowRerecord))
        guard store.markDeletePending(id: id) else { throw unknownRecording }
    }
}

/// In-memory `PlaybackStateService` over a shared `FakeBackendStore`.
///
/// Follows docs/BACKEND-V35.md: reading an unknown id gives nil (the backend answers 0); writing
/// to one is `.rejected`; a negative position is `.http(status: 400)`; `nil` and zero both clear
/// (the real call clears with `Offset=0`). The recording's `hasResumePosition` / `hasBookmark`
/// flag follows the stored value. Unlike the real backend, a read returns exactly what was written.
public final class FakePlaybackStateService: PlaybackStateService, FakeCallControls {
    public enum Call: FakeCall {
        case resumePosition(RecordingID)
        case setResumePosition(Duration?, RecordingID)
        case bookmark(RecordingID)
        case setBookmark(Duration?, RecordingID)

        public enum Method: Hashable, Sendable {
            case resumePosition, setResumePosition, bookmark, setBookmark
        }
        public var method: Method {
            switch self {
            case .resumePosition: .resumePosition
            case .setResumePosition: .setResumePosition
            case .bookmark: .bookmark
            case .setBookmark: .setBookmark
            }
        }
    }

    public let store: FakeBackendStore
    public let recorder = FakeCallRecorder<Call>()

    public init(store: FakeBackendStore = FakeBackendStore()) { self.store = store }

    public func resumePosition(for id: RecordingID) async throws -> Duration? {
        try await recorder.begin(.resumePosition(id))
        return store.resumePosition(for: id)
    }

    public func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {
        try await recorder.begin(.setResumePosition(position, id))
        guard store.setResume(try Self.stored(position), id: id) else { throw unknownRecording }
    }

    public func bookmark(for id: RecordingID) async throws -> Duration? {
        try await recorder.begin(.bookmark(id))
        return store.bookmark(for: id)
    }

    public func setBookmark(_ position: Duration?, for id: RecordingID) async throws {
        try await recorder.begin(.setBookmark(position, id))
        guard store.setBookmark(try Self.stored(position), id: id) else { throw unknownRecording }
    }

    private static func stored(_ position: Duration?) throws -> Duration? {
        guard let position else { return nil }
        if position < .zero { throw BackendError.http(status: 400, message: nil) }
        return position == .zero ? nil : position
    }
}

/// In-memory `MarkupService` over a shared `FakeBackendStore`. An id with no breaks (or an
/// unknown id, as on a real backend) gives an empty list.
public final class FakeMarkupService: MarkupService, FakeCallControls {
    public enum Call: FakeCall {
        case commercialBreaks(RecordingID)

        public enum Method: Hashable, Sendable { case commercialBreaks }
        public var method: Method { .commercialBreaks }
    }

    public let store: FakeBackendStore
    public let recorder = FakeCallRecorder<Call>()

    public init(store: FakeBackendStore = FakeBackendStore()) { self.store = store }

    public func commercialBreaks(for id: RecordingID) async throws -> [CommercialBreak] {
        try await recorder.begin(.commercialBreaks(id))
        return store.commercialBreaks(for: id)
    }
}

/// `MediaLocator` that builds deterministic absolute URLs under `baseURL`. Synchronous, so it has
/// a call log but no error injection or suspension.
public final class FakeMediaLocator: MediaLocator {
    public enum Call: Equatable, Sendable {
        case streamURL(RecordingID)
        case previewImageURL(RecordingID, maxWidth: Int)
        case artworkURL(ArtworkReference, maxWidth: Int)
    }

    public let baseURL: URL
    private let log = FakeCallLog<Call>()

    public init(baseURL: URL = URL(string: "http://fake-backend:6544")!) { self.baseURL = baseURL }

    public var calls: [Call] { log.calls }

    public func streamURL(for recording: Recording) -> URL {
        log.append(.streamURL(recording.id))
        return url("stream/\(recording.id.rawValue)")
    }

    public func previewImageURL(for recording: Recording, maxWidth: Int) -> URL {
        log.append(.previewImageURL(recording.id, maxWidth: maxWidth))
        return url("preview/\(recording.id.rawValue)", ["width": String(maxWidth)])
    }

    public func artworkURL(for reference: ArtworkReference, maxWidth: Int) -> URL? {
        log.append(.artworkURL(reference, maxWidth: maxWidth))
        return url(
            "artwork/\(reference.kind)", ["locator": reference.locator, "width": String(maxWidth)])
    }

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var prefix = parts.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        parts.path = prefix + "/fake/" + path
        if !query.isEmpty {
            parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return parts.url ?? baseURL
    }
}

/// A plain ordered log behind a `Mutex`, for the synchronous fakes.
final class FakeCallLog<Call: Equatable & Sendable>: Sendable {
    private let state = Mutex<[Call]>([])
    var calls: [Call] { state.withLock { $0 } }
    func append(_ call: Call) { state.withLock { $0.append(call) } }
}

/// Stand-ins for the reserved optional services, so a test can give an adapter a `liveTV` or
/// `videoLibrary`.
public struct FakeLiveTVService: LiveTVService { public init() {} }
public struct FakeVideoLibraryService: VideoLibraryService { public init() {} }
