import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchPlayback
import Observation

/// A connected backend: what the probe found and the adapter made for it.
public struct BackendSession: Sendable {
    public let info: BackendInfo
    public let adapter: any BackendAdapter

    public init(info: BackendInfo, adapter: any BackendAdapter) {
        self.info = info
        self.adapter = adapter
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
            session = .loaded(BackendSession(info: connected.info, adapter: connected.adapter))
        case .failure(let error):
            sessionConnection = nil
            session = .failed((error as? BackendError).map(UserMessage.init) ?? .unexpected)
        }
    }
}
