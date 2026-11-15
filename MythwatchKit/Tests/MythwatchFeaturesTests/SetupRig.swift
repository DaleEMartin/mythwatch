import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchTestSupport
import Observation
import Testing

// Shared fixtures for the Settings and Onboarding view-model tests. Every host name is fake.

let savedBackend = BackendConnection(baseURL: URL(string: "http://backend.invalid:6544")!)
let otherBackend = BackendConnection(baseURL: URL(string: "http://other.invalid:6544")!)

let adapterLabel = "MythTV v35 (fake)"

/// Suspends until `condition` holds for `model`, woken by Observation (no polling, no sleeping).
/// All of it runs on the main actor, so a change cannot slip in between the check and the wait.
@MainActor
func waitUntil<Model: Observable>(
    _ model: Model, _ condition: @MainActor @escaping (Model) -> Bool
) async {
    while !condition(model) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking { _ = condition(model) } onChange: { continuation.resume() }
        }
    }
}

/// Everything a setup screen's model needs, with fakes: a settings store, a connector over a
/// transport that can hold a probe open, a discovery, and stand-ins for the two things the
/// factory wires from `AppModel` (the live session and "connect again").
///
/// `backend.invalid` and `other.invalid` answer as v35 (the one registered factory supports v35);
/// `old.invalid` answers as v30, which nothing supports; any other host is unreachable.
@MainActor
final class SetupRig {
    let store: InMemorySettingsStore
    let transport: ParkingTransport
    let factory = FakeAdapterFactory(name: adapterLabel, supports: { $0.major == 35 })
    let discovery = FakeBackendDiscovery()
    let connector: BackendConnector

    /// What the stand-in `AppModel.session` reports.
    var session: Loadable<BackendSession> = .idle
    /// How many times "connect again" was asked for.
    private(set) var reconnectCount = 0
    /// Runs inside "connect again", after it is counted. A test sets the session here, or parks.
    var onReconnect: @MainActor () async -> Void = {}
    /// What the store held at each reconnect (to prove the save came first).
    private(set) var savedBackendAtReconnect: [BackendConnection?] = []

    init(saved: AppSettings = AppSettings()) {
        store = InMemorySettingsStore(saved)
        transport = ParkingTransport([
            "backend.invalid": backendAnswering(version: "v35.0", hostName: "backend-host"),
            "other.invalid": backendAnswering(version: "v35.0", hostName: "other-host"),
            "old.invalid": backendAnswering(version: "v30.0", hostName: "old-host"),
        ])
        var registry = AdapterRegistry()
        registry.register(factory)
        connector = BackendConnector(registry: registry, transport: transport)
    }

    func settingsModel() -> SettingsViewModel {
        SettingsViewModel(
            settings: store, connector: connector, discovery: discovery,
            session: { [self] in session },
            reconnect: { [self] in await reconnect() })
    }

    func onboardingModel() -> OnboardingViewModel {
        OnboardingViewModel(
            settings: store, connector: connector, discovery: discovery,
            session: { [self] in session },
            reconnect: { [self] in await reconnect() })
    }

    private func reconnect() async {
        reconnectCount += 1
        savedBackendAtReconnect.append(store.load().backend)
        await onReconnect()
    }

    /// A session as `AppModel` would report it for `host`.
    func loadedSession(hostName: String = "backend-host") -> Loadable<BackendSession> {
        .loaded(
            BackendSession(
                info: BackendInfo(version: BackendVersion(major: 35, minor: 0, raw: "v35.0"), hostName: hostName),
                adapter: factory.adapter, adapterName: adapterLabel))
    }
}

/// What both setup screens offer for choosing and testing an address, so those rules are tested
/// once for each model.
@MainActor
protocol AddressScreen: AnyObject, Observable {
    var addressText: String { get set }
    var connectionTest: Loadable<BackendInfo> { get }
    var adapterName: String? { get }
    var canTestConnection: Bool { get }
    var addressHint: String? { get }
    var discovered: [DiscoveredBackend] { get }
    func testConnection() async
    func startDiscovery()
    func stopDiscovery()
    func select(_ backend: DiscoveredBackend)
}

extension SettingsViewModel: AddressScreen {}
extension OnboardingViewModel: AddressScreen {}

enum ScreenKind: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case settings, onboarding
    var testDescription: String { rawValue }

    @MainActor func make(_ rig: SetupRig) -> any AddressScreen {
        switch self {
        case .settings: return rig.settingsModel()
        case .onboarding:
            // Onboarding starts with an empty field; type in the address the rig has saved, so
            // the same test can run against both screens.
            let model = rig.onboardingModel()
            if let saved = rig.store.load().backend { model.addressText = BackendAddress.text(for: saved) }
            return model
        }
    }
}

extension BackendAddress {
    /// The text a user would type for `connection`.
    static func text(for connection: BackendConnection) -> String {
        connection.baseURL.absoluteString.replacingOccurrences(of: "http://", with: "")
    }
}

let hostInfo = BackendInfo(version: BackendVersion(major: 35, minor: 0, raw: "v35.0"), hostName: "backend-host")
