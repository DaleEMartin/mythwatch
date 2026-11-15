import Foundation
import MythwatchBackend
import MythwatchDomain

// Pieces the Settings and Onboarding view models share (SPEC 6.4 "Address rules").

/// Wording the setup screens add on top of `UserMessage`. Kept in one place, like `EpisodeLabels`.
enum SetupLabels {
    static let invalidAddress =
        "That doesn't look like an address. Try something like 192.168.1.20 or mybackend.local."
}

/// What the address field holds, as the models see it.
enum AddressInput: Equatable {
    /// Nothing typed (blank counts as nothing).
    case empty
    case valid(BackendConnection)
    case invalid

    init(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .empty
        } else if let connection = BackendAddress.parse(text) {
            self = .valid(connection)
        } else {
            self = .invalid
        }
    }

    var connection: BackendConnection? {
        if case .valid(let connection) = self { return connection }
        return nil
    }

    var isInvalid: Bool { self == .invalid }

    /// The text that stands for `connection` in the address field. Always parses back to the same
    /// connection: plain `host:port` for http, with the scheme kept for https.
    static func text(for connection: BackendConnection) -> String {
        let full = connection.baseURL.absoluteString
        let text = full.hasPrefix("http://") ? String(full.dropFirst("http://".count)) : full
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

/// Cancels its task when the last reference goes away. Models hold their background work through
/// one of these, so a model that is released never leaves a task running (a task cannot be
/// cancelled from `deinit` of a main-actor class directly, but this object's `deinit` can).
final class TaskLifetime: Sendable {
    let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    deinit { task.cancel() }
}

/// Runs one connection test at a time for a setup screen.
///
/// - A test for the address already being tested joins it (one probe); a test for another address
///   cancels the one in flight, and only the newest test ever publishes.
/// - A test belongs to the runner, not to its caller: cancelling the caller does not cancel it.
///   It is cancelled when superseded, by `cancel()`, or when the runner (and so the model) goes
///   away. A cancelled test publishes nothing, so no message comes of a cancelled request (which
///   `URLSessionTransport` reports as `.unreachable`).
@MainActor
final class ConnectionTestRunner {
    private struct Attempt {
        let id: Int
        let connection: BackendConnection
        let lifetime: TaskLifetime
    }

    private var attempt: Attempt?
    private var lastID = 0

    func run(
        _ connection: BackendConnection, using connector: BackendConnector,
        publish: @escaping @MainActor (Result<ConnectedBackend, any Error>) -> Void
    ) async {
        if let attempt, attempt.connection == connection {
            await attempt.lifetime.task.value
            return
        }
        cancel()
        lastID += 1
        let id = lastID
        // Inherits the main actor; the connector's work runs off it.
        let task = Task { [weak self] in
            let outcome: Result<ConnectedBackend, any Error>
            do {
                outcome = .success(try await connector.connect(connection))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.attempt?.id == id, !Task.isCancelled else { return }
            self.attempt = nil
            publish(outcome)
        }
        let lifetime = TaskLifetime(task)
        attempt = Attempt(id: id, connection: connection, lifetime: lifetime)
        await task.value
    }

    func cancel() {
        attempt?.lifetime.task.cancel()
        attempt = nil
    }
}

/// Listens to `BackendDiscovery` between `start` and `stop`.
@MainActor
final class DiscoveryListener {
    private var lifetime: TaskLifetime?

    var isListening: Bool { lifetime != nil }

    /// Opens a stream and calls `update` with each list. Does nothing when already listening.
    func start(
        _ discovery: any BackendDiscovery,
        update: @escaping @MainActor ([DiscoveredBackend]) -> Void
    ) {
        guard lifetime == nil else { return }
        let stream = discovery.discover()
        lifetime = TaskLifetime(
            Task {
                for await list in stream {
                    if Task.isCancelled { break }
                    update(list)
                }
            })
    }

    func stop() {
        lifetime?.task.cancel()
        lifetime = nil
    }
}
