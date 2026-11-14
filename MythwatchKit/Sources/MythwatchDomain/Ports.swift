import Foundation

/// v1 has no fields: fetches every non-deleted, non-LiveTV recording.
public struct RecordingQuery: Sendable {
    public init() {}
}

public protocol RecordingsService: Sendable {
    /// The adapter pages internally.
    func allRecordings() async throws -> [Recording]
    /// Throws `BackendError.notFound` when there is no such recording.
    func recording(id: RecordingID) async throws -> Recording
    func setWatched(_ watched: Bool, id: RecordingID) async throws
    func delete(id: RecordingID, allowRerecord: Bool) async throws
}

public protocol PlaybackStateService: Sendable {
    /// nil means none.
    func resumePosition(for id: RecordingID) async throws -> Duration?
    /// nil clears.
    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws
    func bookmark(for id: RecordingID) async throws -> Duration?
    func setBookmark(_ position: Duration?, for id: RecordingID) async throws
}

public protocol MarkupService: Sendable {
    /// Sorted and non-overlapping.
    func commercialBreaks(for id: RecordingID) async throws -> [CommercialBreak]
}

public protocol MediaLocator: Sendable {
    func streamURL(for recording: Recording) -> URL
    func artworkURL(for reference: ArtworkReference, maxWidth: Int) -> URL?
    func previewImageURL(for recording: Recording, maxWidth: Int) -> URL
}

/// Reserved so `BackendAdapter`'s shape does not change later.
public protocol LiveTVService: Sendable {}
/// Reserved so `BackendAdapter`'s shape does not change later.
public protocol VideoLibraryService: Sendable {}
