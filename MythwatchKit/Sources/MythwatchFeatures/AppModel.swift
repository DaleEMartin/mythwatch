import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchPlayback
import Observation

/// A connected backend: what the probe found, the adapter made for it, and the name of the
/// adapter's factory ("MythTV v35").
public struct BackendSession: Sendable {
    public let info: BackendInfo
    public let adapter: any BackendAdapter
    public let adapterName: String

    public init(info: BackendInfo, adapter: any BackendAdapter, adapterName: String) {
        self.info = info
        self.adapter = adapter
        self.adapterName = adapterName
    }
}

/// The composition root's model (SPEC 6.3): owns the connection to the backend and, in later
/// tasks, makes the screens' view models.
///
/// Connection rules (SPEC 6.3 "Connection flow"):
/// - Each `connect()` reads the backend address from settings. None: any connect in flight is
///   cancelled, `session` becomes `.idle`, and nothing is sent.
/// - A `connect()` for the address already being connected joins that attempt and returns when it
///   finishes; it never probes again.
/// - A `connect()` for a different address cancels the attempt in flight; that attempt's outcome
///   is ignored, whatever it is and whenever it arrives.
/// - While connecting, `session` is `.loading`, except when it already holds a session for the
///   same address: that one stays visible until the new outcome replaces it.
/// - Success gives `.loaded`; any failure gives `.failed`, replacing an earlier session.
/// - An attempt belongs to the model, not to the caller: cancelling the task that called
///   `connect()` does not cancel the attempt (the caller still waits for it). The model cancels an
///   attempt only when it supersedes it, so a cancelled request never becomes a message.
@MainActor @Observable public final class AppModel {
    /// `.idle` = not connected and not connecting: no backend configured, or `connect()` not yet called.
    public private(set) var session: Loadable<BackendSession> = .idle

    private struct Attempt {
        let id: Int
        let connection: BackendConnection
        let task: Task<Void, Never>
    }

    // Kept for the `make...` methods later tasks add (SPEC 6.3).
    @ObservationIgnored let settings: any SettingsStore
    @ObservationIgnored let connector: BackendConnector
    @ObservationIgnored let makeEngine: @MainActor () -> any PlayerEngine
    @ObservationIgnored let discovery: any BackendDiscovery
    @ObservationIgnored let now: @MainActor () -> ContinuousClock.Instant

    /// The newest library model made by `makeLibraryModel()`, held weakly: show models report
    /// their writes to it so the library is right when the user goes back.
    @ObservationIgnored private weak var libraryModel: LibraryViewModel?

    @ObservationIgnored private var attempt: Attempt?
    @ObservationIgnored private var lastAttemptID = 0
    /// The address `session` was loaded from, while it is `.loaded`.
    @ObservationIgnored private var sessionConnection: BackendConnection?

    public init(
        settings: any SettingsStore, connector: BackendConnector,
        makeEngine: @escaping @MainActor () -> any PlayerEngine,
        discovery: any BackendDiscovery,
        now: @escaping @MainActor () -> ContinuousClock.Instant
    ) {
        self.settings = settings
        self.connector = connector
        self.makeEngine = makeEngine
        self.discovery = discovery
        self.now = now
    }

    /// Reads the backend address from settings, probes it, and builds the adapter. See the type's
    /// documentation for how concurrent and repeated calls behave.
    public func connect() async {
        guard let connection = settings.load().backend else {
            cancelAttempt()
            sessionConnection = nil
            session = .idle
            return
        }
        if let attempt, attempt.connection == connection {
            await attempt.task.value
            return
        }
        cancelAttempt()
        if !(session.value != nil && sessionConnection == connection) {
            sessionConnection = nil
            session = .loading
        }
        lastAttemptID += 1
        let id = lastAttemptID
        let connector = self.connector
        // Inherits the main actor; the connector's work runs off it.
        let task = Task { [weak self] in
            let outcome: Result<ConnectedBackend, any Error>
            do {
                outcome = .success(try await connector.connect(connection))
            } catch {
                outcome = .failure(error)
            }
            self?.finish(id, connection, outcome)
        }
        attempt = Attempt(id: id, connection: connection, task: task)
        await task.value
    }

    // MARK: View-model factories

    /// The adapter of the loaded session. The screens only exist once a session is loaded, so
    /// asking for a model without one is a programmer error and stops the app (the signatures
    /// are non-optional and non-throwing, SPEC 6.3).
    private var sessionAdapter: any BackendAdapter {
        guard let adapter = session.value?.adapter else {
            preconditionFailure("AppModel: a view model was requested before the session was loaded")
        }
        return adapter
    }

    /// The Recordings screen's model. Needs a loaded session.
    public func makeLibraryModel() -> LibraryViewModel {
        let model = LibraryViewModel(recordings: sessionAdapter.recordings)
        libraryModel = model
        return model
    }

    /// A show page's model. Needs a loaded session. Its successful writes are applied to the
    /// newest library model made by `makeLibraryModel()`, if that is still alive.
    public func makeShowModel(_ show: Show) -> ShowViewModel {
        ShowViewModel(
            show: show, recordings: sessionAdapter.recordings,
            onChange: { [weak libraryModel] change in libraryModel?.apply(change) })
    }

    /// An episode detail page's model. Needs a loaded session.
    public func makeEpisodeDetailModel(_ recording: Recording) -> EpisodeDetailModel {
        EpisodeDetailModel(recording: recording, state: sessionAdapter.playbackState)
    }

    /// The Settings screen's model. Needs no session: the screen is reachable while the backend
    /// is down. Saving a changed backend makes this `AppModel` connect again.
    public func makeSettingsModel() -> SettingsViewModel {
        SettingsViewModel(
            settings: settings, connector: connector, discovery: discovery,
            session: { [weak self] in self?.session ?? .idle },
            reconnect: { [weak self] in await self?.connect() })
    }

    /// The first-run screen's model. Needs no session (there is none yet). Connecting makes this
    /// `AppModel` connect from the settings it saves.
    public func makeOnboardingModel() -> OnboardingViewModel {
        OnboardingViewModel(
            settings: settings, connector: connector, discovery: discovery,
            session: { [weak self] in self?.session ?? .idle },
            reconnect: { [weak self] in await self?.connect() })
    }

    private func cancelAttempt() {
        attempt?.task.cancel()
        attempt = nil
    }

    private func finish(
        _ id: Int, _ connection: BackendConnection, _ outcome: Result<ConnectedBackend, any Error>
    ) {
        // A superseded attempt (cancelled, or replaced by a newer one) never touches `session`.
        guard let attempt, attempt.id == id, !Task.isCancelled else { return }
        self.attempt = nil
        switch outcome {
        case .success(let connected):
            sessionConnection = connection
            session = .loaded(
                BackendSession(
                    info: connected.info, adapter: connected.adapter,
                    adapterName: connected.adapterName))
        case .failure(let error):
            sessionConnection = nil
            session = .failed((error as? BackendError).map(UserMessage.init) ?? .unexpected)
        }
    }
}
