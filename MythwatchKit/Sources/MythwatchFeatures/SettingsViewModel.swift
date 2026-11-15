import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchPlayback
import Observation

/// The Settings screen's model (SPEC 6.4 "Settings rules").
///
/// Edits stay in this model until `save()`. The backend address is edited as text
/// (`addressText`); every other setting is a plain property.
@MainActor @Observable public final class SettingsViewModel {
    // MARK: Editable fields

    /// What is typed in the address field. Editing it so that it means a different backend clears
    /// the connection test.
    public var addressText: String {
        didSet { addressDidChange() }
    }
    public var commercialSkipMode: CommercialSkipMode
    /// Only the values in `skipForwardChoices` are accepted; anything else is ignored.
    public var skipForwardSeconds: Int {
        didSet { if !Self.skipForwardChoices.contains(skipForwardSeconds) { skipForwardSeconds = oldValue } }
    }
    /// Only the values in `skipBackwardChoices` are accepted; anything else is ignored.
    public var skipBackwardSeconds: Int {
        didSet { if !Self.skipBackwardChoices.contains(skipBackwardSeconds) { skipBackwardSeconds = oldValue } }
    }
    public var deinterlace: Bool
    public var askBeforeDelete: Bool

    public static var skipForwardChoices: [Int] { AppSettings.skipForwardChoices }
    public static var skipBackwardChoices: [Int] { AppSettings.skipBackwardChoices }

    // MARK: State

    /// The result of the last `testConnection()` for the address now typed. `.idle` until a test
    /// is run and again as soon as the address means a different backend.
    public private(set) var connectionTest: Loadable<BackendInfo> = .idle
    /// Backends found on the network while listening (`startDiscovery()`).
    public private(set) var discovered: [DiscoveredBackend] = []
    /// True while the backend change from the last `save()` is being connected.
    public var isReconnecting: Bool { reconnecting > 0 }
    /// Why the last save's reconnect failed, if it did. Cleared when the next save starts.
    public private(set) var reconnectProblem: UserMessage?

    private var saved: AppSettings
    private var testedConnection: BackendConnection?
    private var testedAdapterName: String?
    private var reconnecting = 0

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let connector: BackendConnector
    @ObservationIgnored private let discovery: any BackendDiscovery
    @ObservationIgnored private let session: @MainActor () -> Loadable<BackendSession>
    @ObservationIgnored private let reconnect: @MainActor () async -> Void
    @ObservationIgnored private let tester = ConnectionTestRunner()
    @ObservationIgnored private let listener = DiscoveryListener()

    /// - Parameters:
    ///   - session: the app's live session (what `AppModel.session` holds now).
    ///   - reconnect: connects again from the stored settings (`AppModel.connect()`).
    public init(
        settings: any SettingsStore, connector: BackendConnector, discovery: any BackendDiscovery,
        session: @escaping @MainActor () -> Loadable<BackendSession>,
        reconnect: @escaping @MainActor () async -> Void
    ) {
        let current = settings.load()
        store = settings
        self.connector = connector
        self.discovery = discovery
        self.session = session
        self.reconnect = reconnect
        saved = current
        addressText = current.backend.map(AddressInput.text(for:)) ?? ""
        commercialSkipMode = current.commercialSkipMode
        skipForwardSeconds = current.skipForwardSeconds
        skipBackwardSeconds = current.skipBackwardSeconds
        deinterlace = current.deinterlace
        askBeforeDelete = current.askBeforeDelete
    }

    // MARK: Derived state a view binds to

    private var input: AddressInput { AddressInput(addressText) }

    /// A hint to show under the address field when the text is not an address. Nil for a valid
    /// address and for an empty one (empty means "no backend").
    public var addressHint: String? { input.isInvalid ? SetupLabels.invalidAddress : nil }

    /// Whether Test Connection can be offered: the address is valid.
    public var canTestConnection: Bool { input.connection != nil }

    /// The settings as edited, or nil while the address is not valid. An empty address means no
    /// backend.
    public var editedSettings: AppSettings? {
        let backend: BackendConnection?
        switch input {
        case .invalid: return nil
        case .empty: backend = nil
        case .valid(let connection): backend = connection
        }
        return AppSettings(
            backend: backend, commercialSkipMode: commercialSkipMode,
            skipForwardSeconds: skipForwardSeconds, skipBackwardSeconds: skipBackwardSeconds,
            deinterlace: deinterlace, askBeforeDelete: askBeforeDelete)
    }

    /// Whether the edits differ from what is saved. Text that is not an address counts as a
    /// change (there is something to fix) that cannot be saved.
    public var hasUnsavedChanges: Bool {
        guard let edited = editedSettings else { return true }
        return edited != saved
    }

    /// Whether Save can be offered: something changed and the address is valid or empty.
    public var canSave: Bool { editedSettings.map { $0 != saved } ?? false }

    /// What the screen should say about the backend now typed: the test result when there is
    /// one, otherwise the live session when the typed address is the saved one.
    public var backendInfo: BackendInfo? {
        if let info = connectionTest.value { return info }
        return liveSession?.info
    }

    /// The name of the adapter in use for `backendInfo` ("MythTV v35").
    public var adapterName: String? {
        if connectionTest.value != nil { return testedAdapterName }
        return liveSession?.adapterName
    }

    private var liveSession: BackendSession? {
        guard let connection = input.connection, connection == saved.backend else { return nil }
        return session().value
    }

    // MARK: Actions

    /// Probes the address now typed (not the saved one) and resolves its adapter. Changes
    /// nothing else: nothing is saved and the app's session is untouched. Does nothing unless
    /// `canTestConnection`.
    public func testConnection() async {
        guard let connection = input.connection else { return }
        testedConnection = connection
        testedAdapterName = nil
        connectionTest = .loading
        await tester.run(connection, using: connector) { [weak self] outcome in
            self?.finishTest(connection, outcome)
        }
    }

    /// Stores the edited settings. If the backend changed (compared as parsed addresses), the
    /// app then connects again, and this returns when that has finished. Does nothing unless
    /// `canSave`.
    public func save() async {
        guard canSave, let edited = editedSettings else { return }
        let backendChanged = edited.backend != saved.backend
        store.save(edited)
        saved = edited
        if let connection = edited.backend {
            let text = AddressInput.text(for: connection)
            if addressText != text { addressText = text }
        }
        guard backendChanged else { return }
        reconnectProblem = nil
        reconnecting += 1
        await reconnect()
        reconnecting -= 1
        if reconnecting == 0 { reconnectProblem = session().message }
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
        guard testedConnection != nil || !connectionTest.isIdle else { return }
        if input.connection != testedConnection {
            tester.cancel()
            testedConnection = nil
            testedAdapterName = nil
            connectionTest = .idle
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
