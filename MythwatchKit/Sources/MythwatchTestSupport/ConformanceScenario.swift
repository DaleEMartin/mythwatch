import Foundation
import MythwatchBackend
import MythwatchDomain

/// What an adapter's test target supplies so `AdapterConformance` can check that adapter
/// (SPEC §9). It knows nothing about any backend version: the adapter is wired to canned data by
/// the adopting target, and the facts below are the ones the suite cannot discover by itself.
///
/// The scenario's data must list at least two recordings, and every listed id must be fetchable
/// with `recording(id:)`.
public protocol ConformanceScenario: Sendable {
    /// The connection the adapter is built for. Media URLs must lie under its base URL.
    var connection: BackendConnection { get }

    /// A new adapter wired to the scenario's canned data. Called once at the start of each check.
    func makeAdapter() async throws -> any BackendAdapter

    /// An id no recording has. Must not be listed; `recording(id:)` must throw `.notFound` for it.
    var absentID: RecordingID { get }

    /// A recording whose commercial breaks are not empty (proves the breaks check is not vacuous).
    var idWithBreaks: RecordingID { get }

    /// A recording with neither a stored resume position nor a bookmark.
    var idWithoutStoredPosition: RecordingID { get }

    /// A recording with a stored resume position, or nil when the scenario's data has none.
    var idWithResumePosition: RecordingID? { get }

    /// A recording with a stored bookmark, or nil when the scenario's data has none.
    var idWithBookmark: RecordingID? { get }
}
