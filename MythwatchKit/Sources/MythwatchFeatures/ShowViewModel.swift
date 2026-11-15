import Foundation
import MythwatchDomain
import Observation

/// The Show page's model (SPEC 6.4): a show's episodes by season, and the two writes on them.
///
/// State a view renders directly:
/// - `show`: the show with its current local state (title, poster, counts, recordings).
/// - `seasons` and `selectedSeason`. The first season is selected until `select(season:)` says
///   otherwise (the simplest default). If the selected season disappears (its last episode was
///   deleted) the first season left is shown; if it comes back (the delete failed) it is selected
///   again. `selectedSeason` is nil only when the show has no recordings.
/// - `isEmpty`: the show has no recordings left, so the view should close.
/// - `problem`: why the last write failed; the view shows it and may call `dismissProblem()`.
///   It clears when the next write starts.
///
/// Writes are optimistic: the local state changes before the call is made, and a failed call
/// puts it back and sets `problem`. Both return a task that finishes when the write has; a view
/// can ignore it. A write is never cancelled by its caller (the model owns it), because a call
/// cancelled half-way leaves the backend's state unknown.
///
/// - `toggleWatched(_:)` flips the episode's current local state. Writes to one recording are sent
///   one at a time, newest wish last: a toggle made while a write is in flight is not sent until
///   that write ends, and then only if the backend's state still differs from what is wanted
///   (on, off, on in quick succession sends one write). A failed write rolls the screen back to
///   the last state the backend confirmed, unless a later toggle has already asked for something
///   else; a later toggle is never undone by an earlier failure.
/// - `delete(_:)` removes the recording at once and sends `delete(id:allowRerecord: false)`;
///   a failure puts it back. The model never asks "are you sure": `askBeforeDelete` is the
///   view's concern.
///
/// After each successful write the model calls `onChange`, which `AppModel` wires to the
/// `LibraryViewModel`, so the library is correct when the user goes back.
@MainActor @Observable public final class ShowViewModel {
    public private(set) var show: Show
    public private(set) var problem: UserMessage?

    private struct SeasonKey { var id: Int? }
    private var selection: SeasonKey?

    private struct WatchedWrites {
        var confirmed: Bool
        var wanted: Bool
        var task: Task<Void, Never>?
    }

    @ObservationIgnored private let service: any RecordingsService
    @ObservationIgnored private let onChange: (@MainActor (RecordingChange) -> Void)?
    @ObservationIgnored private var watchedWrites: [RecordingID: WatchedWrites] = [:]
    /// Recordings removed locally while their delete is in flight, kept for a rollback.
    @ObservationIgnored private var removed: [RecordingID: Recording] = [:]

    public init(
        show: Show, recordings: any RecordingsService,
        onChange: (@MainActor (RecordingChange) -> Void)? = nil
    ) {
        self.show = show
        self.service = recordings
        self.onChange = onChange
    }

    // MARK: Seasons

    public var seasons: [Season] { LibraryBuilder.seasons(of: show) }

    public var selectedSeason: Season? {
        let all = seasons
        if let selection, let match = all.first(where: { $0.id == selection.id }) { return match }
        return all.first
    }

    /// Selects `season` (ignored when the show has no such season).
    public func select(season: Season) {
        guard seasons.contains(where: { $0.id == season.id }) else { return }
        selection = SeasonKey(id: season.id)
    }

    public var isEmpty: Bool { show.recordings.isEmpty }

    public func dismissProblem() { problem = nil }

    // MARK: Watched

    @discardableResult
    public func toggleWatched(_ recording: Recording) -> Task<Void, Never> {
        let id = recording.id
        guard let current = show.recordings.first(where: { $0.id == id }) else {
            return Task {}
        }
        problem = nil
        let wanted = !current.flags.contains(.watched)
        setLocalWatched(wanted, id: id)
        if var writes = watchedWrites[id] {
            writes.wanted = wanted
            watchedWrites[id] = writes
            return writes.task ?? Task {}
        }
        watchedWrites[id] = WatchedWrites(confirmed: !wanted, wanted: wanted)
        let task = Task<Void, Never> { [weak self] in
            if let self { await self.sendWatchedWrites(for: id) }
        }
        watchedWrites[id]?.task = task
        return task
    }

    private func sendWatchedWrites(for id: RecordingID) async {
        while let writes = watchedWrites[id], writes.wanted != writes.confirmed {
            let value = writes.wanted
            do {
                try await service.setWatched(value, id: id)
                watchedWrites[id]?.confirmed = value
                onChange?(.watched(id, value))
            } catch {
                problem = UserMessage.describing(error)
                // The value is only ever sent when it differs from `confirmed`, so wanting the
                // confirmed state is either a rollback (the failed value was still wanted) or
                // already true (a later toggle asked for it): setting it again changes nothing.
                guard let confirmed = watchedWrites[id]?.confirmed else { break }
                watchedWrites[id]?.wanted = confirmed
                setLocalWatched(confirmed, id: id)
            }
        }
        watchedWrites[id] = nil
    }

    private func setLocalWatched(_ watched: Bool, id: RecordingID) {
        func apply(_ recording: inout Recording) {
            if watched { recording.flags.insert(.watched) } else { recording.flags.remove(.watched) }
        }
        if let index = show.recordings.firstIndex(where: { $0.id == id }) {
            var recordings = show.recordings
            apply(&recordings[index])
            replaceRecordings(recordings)
        }
        if var stash = removed[id] {
            apply(&stash)
            removed[id] = stash
        }
    }

    // MARK: Delete

    @discardableResult
    public func delete(_ recording: Recording) -> Task<Void, Never> {
        let id = recording.id
        guard let index = show.recordings.firstIndex(where: { $0.id == id }) else { return Task {} }
        problem = nil
        var recordings = show.recordings
        removed[id] = recordings.remove(at: index)
        replaceRecordings(recordings)
        return Task<Void, Never> { [weak self] in
            if let self { await self.sendDelete(id) }
        }
    }

    private func sendDelete(_ id: RecordingID) async {
        do {
            try await service.delete(id: id, allowRerecord: false)
            removed[id] = nil
            onChange?(.deleted(id))
        } catch {
            problem = UserMessage.describing(error)
            guard let restored = removed.removeValue(forKey: id) else { return }
            var recordings = show.recordings + [restored]
            recordings.sort { a, b in
                a.recordingStart != b.recordingStart
                    ? a.recordingStart > b.recordingStart : a.id.rawValue > b.id.rawValue
            }
            replaceRecordings(recordings)
        }
    }

    /// Swaps in a new recording list (newest first) and recomputes the show's counts.
    private func replaceRecordings(_ recordings: [Recording]) {
        show.recordings = recordings
        show.episodeCount = recordings.count
        show.unwatchedCount = recordings.filter { !$0.flags.contains(.watched) }.count
    }
}
