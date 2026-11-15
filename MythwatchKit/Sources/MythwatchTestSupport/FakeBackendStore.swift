import Foundation
import MythwatchDomain
import Synchronization

/// The in-memory "backend" the four service fakes of one adapter share, so a write through one
/// service is visible through another.
///
/// Stored positions are authoritative: `hasResumePosition` and `hasBookmark` on a returned
/// `Recording` are always derived from them, whatever flags the recording was added with.
/// `watched` and `deletePending` are ordinary flags. Insertion order is list order.
public final class FakeBackendStore: Sendable {
    private struct State {
        var order: [RecordingID] = []
        var recordings: [RecordingID: Recording] = [:]
        var resume: [RecordingID: Duration] = [:]
        var bookmarks: [RecordingID: Duration] = [:]
        var breaks: [RecordingID: [CommercialBreak]] = [:]

        func view(_ id: RecordingID) -> Recording? {
            guard var r = recordings[id] else { return nil }
            r.flags.subtract([.hasResumePosition, .hasBookmark])
            if resume[id] != nil { r.flags.insert(.hasResumePosition) }
            if bookmarks[id] != nil { r.flags.insert(.hasBookmark) }
            return r
        }
    }

    private let state = Mutex(State())

    public init(recordings: [Recording] = []) {
        for r in recordings { add(r) }
    }

    /// Adds a recording, or replaces the one with the same id in place (and its stored
    /// position, bookmark and breaks).
    public func add(
        _ recording: Recording, resumePosition: Duration? = nil, bookmark: Duration? = nil,
        commercialBreaks: [CommercialBreak] = []
    ) {
        state.withLock { s in
            if s.recordings[recording.id] == nil { s.order.append(recording.id) }
            s.recordings[recording.id] = recording
            s.resume[recording.id] = resumePosition
            s.bookmarks[recording.id] = bookmark
            s.breaks[recording.id] = commercialBreaks
        }
    }

    /// Every stored recording in insertion order, including delete-pending ones.
    public var allRecordings: [Recording] { state.withLock { s in s.order.compactMap { s.view($0) } } }

    public func recording(id: RecordingID) -> Recording? { state.withLock { $0.view(id) } }
    public func resumePosition(for id: RecordingID) -> Duration? { state.withLock { $0.resume[id] } }
    public func bookmark(for id: RecordingID) -> Duration? { state.withLock { $0.bookmarks[id] } }
    public func commercialBreaks(for id: RecordingID) -> [CommercialBreak] {
        state.withLock { $0.breaks[id] ?? [] }
    }

    /// Stores the breaks exactly as given: keeping them sorted and non-overlapping is the caller's job.
    public func setCommercialBreaks(_ breaks: [CommercialBreak], for id: RecordingID) {
        state.withLock { $0.breaks[id] = breaks }
    }

    // MARK: Writes used by the service fakes. Each returns false when the id is unknown.

    func setWatched(_ watched: Bool, id: RecordingID) -> Bool {
        state.withLock { s in
            guard s.recordings[id] != nil else { return false }
            if watched { s.recordings[id]?.flags.insert(.watched) } else { s.recordings[id]?.flags.remove(.watched) }
            return true
        }
    }

    func markDeletePending(id: RecordingID) -> Bool {
        state.withLock { s in
            guard s.recordings[id] != nil else { return false }
            s.recordings[id]?.flags.insert(.deletePending)
            return true
        }
    }

    func setResume(_ position: Duration?, id: RecordingID) -> Bool {
        state.withLock { s in
            guard s.recordings[id] != nil else { return false }
            s.resume[id] = position
            return true
        }
    }

    func setBookmark(_ position: Duration?, id: RecordingID) -> Bool {
        state.withLock { s in
            guard s.recordings[id] != nil else { return false }
            s.bookmarks[id] = position
            return true
        }
    }
}
