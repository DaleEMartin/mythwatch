import Foundation
import MythwatchBackend
import MythwatchDomain
import Observation

/// The first-run screen's model (SPEC 6.4 "Onboarding rules"): pick or type a backend, optionally
/// test it, connect.
@MainActor @Observable public final class OnboardingViewModel {
    /// What is typed in the address field. Editing it so that it means a different backend clears
    /// the connection test and any failed connect.
    public var addressText: String = "" {
        didSet { addressDidChange() }
    }

    /// The result of the last `testConnection()` for the address now typed.
    public private(set) var connectionTest: Loadable<BackendInfo> = .idle
    /// The outcome of `connect()`: `.idle` before, `.loading` while connecting, `.loaded` with
    /// what was detected when done (the screen can move on), `.failed` with a message.
    public private(set) var connectState: Loadable<BackendInfo> = .idle
    /// Backends found on the network while listening (`startDiscovery()`).
    public private(set) var discovered: [DiscoveredBackend] = []

    private var testedConnection: BackendConnection?
    private var testedAdapterName: String?
    private var failedConnection: BackendConnection?
    private var connectedAdapterName: String?

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let connector: BackendConnector
    @ObservationIgnored private let discovery: any BackendDiscovery
    @ObservationIgnored private let session: @MainActor () -> Loadable<BackendSession>
    @ObservationIgnored private let reconnect: @MainActor () async -> Void
    @ObservationIgnored private let tester = ConnectionTestRunner()
    @ObservationIgnored private let listener = DiscoveryListener()

    /// - Parameters:
    ///   - session: the app's live session (what `AppModel.session` holds now).
    ///   - reconnect: connects from the stored settings (`AppModel.connect()`).
    public init(
        settings: any SettingsStore, connector: BackendConnector, discovery: any BackendDiscovery,
        session: @escaping @MainActor () -> Loadable<BackendSession>,
        reconnect: @escaping @MainActor () async -> Void
    ) {
        store = settings
        self.connector = connector
        self.discovery = discovery
        self.session = session
        self.reconnect = reconnect
    }

    // MARK: Derived state a view binds to

    private var input: AddressInput { AddressInput(addressText) }

    /// A hint to show under the address field when the text is not an address. Nil for a valid
    /// address and for an empty one.
    public var addressHint: String? { input.isInvalid ? SetupLabels.invalidAddress : nil }

    /// Whether Test Connection can be offered: the address is valid.
    public var canTestConnection: Bool { input.connection != nil }

    /// Whether Connect can be offered: the address is valid and a connect is not already running.
    public var canConnect: Bool { input.connection != nil && !isConnecting }

    public var isConnecting: Bool { connectState.isLoading }

    /// The name of the adapter in use for the backend that was tested or connected
    /// ("MythTV v35"). Nil until one of them succeeds.
    public var adapterName: String? {
        if connectionTest.value != nil { return testedAdapterName }
        if connectState.value != nil { return connectedAdapterName }
        return nil
    }

    // MARK: Actions

    /// Probes the address now typed and resolves its adapter. Saves nothing and leaves the app's
    /// session alone. Does nothing unless `canTestConnection`.
    public func testConnection() async {
        guard let connection = input.connection else { return }
        testedConnection = connection
        testedAdapterName = nil
        connectionTest = .loading
        await tester.run(connection, using: connector) { [weak self] outcome in
            self?.finishTest(connection, outcome)
        }
    }

    /// Saves the address as the backend (every other setting is kept) and connects the app to
    /// it. The outcome is in `connectState`. A failure keeps the saved address so the user can
    /// retry or edit it. Does nothing unless `canConnect`.
    public func connect() async {
        guard canConnect, let connection = input.connection else { return }
        var settings = store.load()
        settings.backend = connection
        store.save(settings)
        connectedAdapterName = nil
        connectState = .loading
        await reconnect()
        // The address was changed while connecting: the outcome is about another backend.
        guard input.connection == connection else {
            connectState = .idle
            return
        }
        switch session() {
        case .loaded(let live):
            connectedAdapterName = live.adapterName
            connectState = .loaded(live.info)
        case .failed(let message):
            failedConnection = connection
            connectState = .failed(message)
        case .idle, .loading:
            connectState = .idle
        }
    }

    /// Fills the address with the chosen backend. Nothing is tested or saved.
    public func select(_ backend: DiscoveredBackend) {
        addressText = AddressInput.text(for: backend.connection)
    }

    /// Starts listening for backends. Call when the screen appears; does nothing if listening.
    public func startDiscovery() {
        listener.start(discovery) { [weak self] list in self?.discovered = list }
    }

    /// Stops listening and clears the list. Call when the screen disappears.
    public func stopDiscovery() {
        listener.stop()
        discovered = []
    }

    // MARK: Private

    private func addressDidChange() {
        let connection = input.connection
        if (testedConnection != nil || !connectionTest.isIdle), connection != testedConnection {
            tester.cancel()
            testedConnection = nil
            testedAdapterName = nil
            connectionTest = .idle
        }
        // A failure is about the address that was tried; once it means another backend, drop it.
        if connectState.message != nil, connection != failedConnection {
            connectState = .idle
        }
    }

    private func finishTest(_ connection: BackendConnection, _ outcome: Result<ConnectedBackend, any Error>) {
        guard testedConnection == connection else { return }
        switch outcome {
        case .success(let connected):
            testedAdapterName = connected.adapterName
            connectionTest = .loaded(connected.info)
        case .failure(let error):
            connectionTest = .failed(.describing(error))
        }
    }
}
