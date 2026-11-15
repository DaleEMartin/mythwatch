import Foundation
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport

/// Neutral recordings for the view-model tests.
func rid(_ n: Int) -> RecordingID { RecordingID(rawValue: n) }

func episode(
    _ n: Int, title: String = "Garden Tales", season: Int? = 1, episode: Int? = nil,
    watched: Bool = false, key: String? = "KEY-GARDEN", day: Int = 0
) -> Recording {
    let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400 + Double(day))
    return .fixture(
        id: rid(n), title: title, subtitle: "Episode \(n)", season: season, episode: episode ?? n,
        seriesKey: key, recordingStart: start, recordingEnd: start.addingTimeInterval(1800),
        flags: watched ? [.watched] : [])
}

/// A `RecordingsService` that behaves like `URLSessionTransport` when its task is cancelled: it
/// reports `.unreachable` instead of `CancellationError`.
struct UnreachableOnCancel: RecordingsService {
    let inner: FakeRecordingsService
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch is CancellationError {
            throw BackendError.unreachable("cancelled")
        }
    }
    func allRecordings() async throws -> [Recording] { try await mapped { try await inner.allRecordings() } }
    func recording(id: RecordingID) async throws -> Recording { try await mapped { try await inner.recording(id: id) } }
    func setWatched(_ watched: Bool, id: RecordingID) async throws {
        try await mapped { try await inner.setWatched(watched, id: id) }
    }
    func delete(id: RecordingID, allowRerecord: Bool) async throws {
        try await mapped { try await inner.delete(id: id, allowRerecord: allowRerecord) }
    }
}

/// A `PlaybackStateService` that returns fixed answers, for values the fake store cannot hold
/// (a zero position).
struct StubPlaybackState: PlaybackStateService {
    var resume: Duration?
    var mark: Duration?
    func resumePosition(for id: RecordingID) async throws -> Duration? { resume }
    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {}
    func bookmark(for id: RecordingID) async throws -> Duration? { mark }
    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {}
}

/// Collects the changes a `ShowViewModel` reports.
@MainActor final class ChangeLog {
    private(set) var changes: [RecordingChange] = []
    func record(_ change: RecordingChange) { changes.append(change) }
}
