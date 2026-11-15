import Foundation
import MythwatchDomain
import Observation

/// The Recordings screen's model (SPEC 6.4).
///
/// State a view renders directly:
/// - `library`: `.idle`, `.loading` (nothing to show yet), `.loaded(Library)` or `.failed`.
/// - `isRefreshing`: a fetch is running while `library` already holds content, which stays
///   visible. The view may show a small spinner.
/// - `refreshProblem`: the last refresh failed. The old library stays on screen and this says why;
///   the view may show it as a banner. It clears when the next fetch starts.
///
/// Rules:
/// - `load()` fetches when nothing is loaded yet (idle or failed). When a library is loaded it does
///   nothing, so a view that appears again does not re-fetch; `refresh()` always fetches.
/// - Only one fetch runs at a time. A `load()` or `refresh()` made while one runs joins it and
///   returns when it finishes, so nothing is fetched twice and an older answer cannot overwrite a
///   newer one.
/// - Cancellation: the fetch belongs to the model. It is cancelled only when every caller waiting
///   for it has been cancelled. A cancelled fetch shows no message and leaves `library` as it was
///   before the fetch began: `.idle` after a cancelled first load (the next `load()` starts
///   again), the old content after a cancelled refresh, the old failure after a cancelled retry.
/// - `apply(_:)` changes the loaded library locally (used by the show model after a write). A fetch
///   already running predates the change, so its answer is dropped and the list is fetched again.
@MainActor @Observable public final class LibraryViewModel {
    public private(set) var library: Loadable<Library> = .idle
    public private(set) var isRefreshing = false
    public private(set) var refreshProblem: UserMessage?

    @ObservationIgnored private let service: any RecordingsService
    @ObservationIgnored private var recordings: [Recording] = []
    @ObservationIgnored private var changeCount = 0
    @ObservationIgnored private var stateBeforeFetch: Loadable<Library> = .idle
    @ObservationIgnored private let shared = SharedLoad<Result<[Recording], any Error>>()

    public init(recordings: any RecordingsService) {
        self.service = recordings
    }

    /// Loads the library the first time. Does nothing when one is already loaded.
    public func load() async {
        if library.value != nil && !shared.isRunning { return }
        await fetch()
    }

    /// Fetches again. Content already on screen stays visible until the new list arrives; if the
    /// fetch fails the old content stays and `refreshProblem` says why.
    public func refresh() async {
        await fetch()
    }

    /// Called by the player screen when playback ends: positions and watched marks have changed
    /// on the backend. Same as `refresh()`; it is a method so the view model does not need to
    /// know about the player.
    public func reloadAfterPlayback() async {
        await fetch()
    }

    /// Applies a change the backend has accepted, without fetching.
    public func apply(_ change: RecordingChange) {
        changeCount += 1
        switch change {
        case .watched(let id, let watched):
            guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
            if watched {
                recordings[index].flags.insert(.watched)
            } else {
                recordings[index].flags.remove(.watched)
            }
        case .deleted(let id):
            recordings.removeAll { $0.id == id }
        }
        if library.value != nil { library = .loaded(LibraryBuilder.build(from: recordings)) }
    }

    private func fetch() async {
        if !shared.isRunning {
            stateBeforeFetch = library
            refreshProblem = nil
            if library.value == nil { library = .loading } else { isRefreshing = true }
        }
        let service = self.service
        await shared.run(
            fetch: { [weak self] in
                while true {
                    let startedAt = self?.changeCount
                    do {
                        let result = try await service.allRecordings()
                        if let self, self.changeCount != startedAt, !Task.isCancelled { continue }
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }
            },
            publish: { [weak self] outcome in self?.publish(outcome) },
            abandon: { [weak self] in
                guard let self else { return }
                self.library = self.stateBeforeFetch
                self.isRefreshing = false
            })
    }

    private func publish(_ outcome: Result<[Recording], any Error>) {
        isRefreshing = false
        switch outcome {
        case .success(let fetched):
            recordings = fetched
            library = .loaded(LibraryBuilder.build(from: fetched))
        case .failure(let error):
            let message = UserMessage.describing(error)
            if library.value != nil { refreshProblem = message } else { library = .failed(message) }
        }
    }
}
