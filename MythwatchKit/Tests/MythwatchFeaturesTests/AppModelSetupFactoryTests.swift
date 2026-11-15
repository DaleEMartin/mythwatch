import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Testing

/// A real `AppModel` over fakes, built without a session: Settings and Onboarding exist before
/// (and without) one, so their factories do not need it.
@MainActor
private struct Harness {
    let settings: InMemorySettingsStore
    let transport: ParkingTransport
    let factory = FakeAdapterFactory(name: "MythTV v35 (fake)", supports: { $0.major == 35 })
    let discovery = FakeBackendDiscovery()
    let app: AppModel

    init(saved: AppSettings = AppSettings()) {
        settings = InMemorySettingsStore(saved)
        transport = ParkingTransport([
            "backend.invalid": backendAnswering(version: "v35.0", hostName: "backend-host"),
            "other.invalid": backendAnswering(version: "v35.0", hostName: "other-host"),
        ])
        var registry = AdapterRegistry()
        registry.register(factory)
        app = AppModel(
            settings: settings, connector: BackendConnector(registry: registry, transport: transport),
            makeEngine: { fatalError("not used") }, discovery: discovery, now: TestClock().now)
    }
}

@MainActor
@Suite("AppModel setup-screen factories")
struct AppModelSetupFactoryTests {
    @Test func theSettingsModelNeedsNoSession() {
        let h = Harness(saved: AppSettings(backend: savedBackend, deinterlace: false))
        let model = h.app.makeSettingsModel()
        #expect(h.app.session.isIdle)
        #expect(model.addressText == "backend.invalid:6544")
        #expect(model.deinterlace == false)
    }

    @Test func theOnboardingModelNeedsNoSession() {
        let h = Harness()
        let model = h.app.makeOnboardingModel()
        #expect(h.app.session.isIdle)
        #expect(!model.canConnect)
    }

    @Test func aSavedBackendChangeMakesTheAppModelReconnect() async {
        let h = Harness(saved: AppSettings(backend: savedBackend))
        await h.app.connect()
        #expect(h.app.session.value?.info.hostName == "backend-host")
        let model = h.app.makeSettingsModel()
        model.addressText = "other.invalid"
        await model.save()
        #expect(h.settings.load().backend == otherBackend)
        #expect(h.app.session.value?.info.hostName == "other-host")
        #expect(h.factory.makeRequests.map(\.connection) == [savedBackend, otherBackend])
        #expect(model.reconnectProblem == nil)
    }

    @Test func savingOnlyPlaybackSettingsDoesNotMakeTheAppModelReconnect() async {
        let h = Harness(saved: AppSettings(backend: savedBackend))
        await h.app.connect()
        let probes = h.transport.probeCount
        let model = h.app.makeSettingsModel()
        model.commercialSkipMode = .off
        model.deinterlace = false
        await model.save()
        #expect(h.settings.load().commercialSkipMode == .off)
        #expect(h.transport.probeCount == probes)
        #expect(h.app.session.value != nil)
    }

    @Test func savingAnEmptyAddressDisconnectsTheAppModel() async {
        let h = Harness(saved: AppSettings(backend: savedBackend))
        await h.app.connect()
        let model = h.app.makeSettingsModel()
        model.addressText = ""
        await model.save()
        #expect(h.settings.load().backend == nil)
        #expect(h.app.session.isIdle)
    }

    @Test func aFailedReconnectIsReportedByTheSettingsModel() async {
        let h = Harness(saved: AppSettings(backend: savedBackend))
        let model = h.app.makeSettingsModel()
        model.addressText = "nowhere.invalid"
        await model.save()
        #expect(h.app.session.message != nil)
        #expect(model.reconnectProblem == h.app.session.message)
        #expect(model.reconnectProblem == UserMessage(.unreachable("any")))
    }

    @Test func aTestThroughTheFactoryModelUsesTheAppsConnectorAndLeavesTheSessionAlone() async {
        let h = Harness(saved: AppSettings(backend: savedBackend))
        await h.app.connect()
        let session = h.app.session.value
        let model = h.app.makeSettingsModel()
        model.addressText = "other.invalid"
        await model.testConnection()
        #expect(model.connectionTest.value?.hostName == "other-host")
        #expect(h.transport.requests.last?.url.host == "other.invalid")
        #expect(h.app.session.value?.info == session?.info)
        #expect(h.settings.load().backend == savedBackend)
    }

    @Test func theSettingsModelShowsTheLiveSessionsAdapterName() async {
        let h = Harness(saved: AppSettings(backend: savedBackend))
        let model = h.app.makeSettingsModel()
        #expect(model.adapterName == nil)  // not connected yet
        await h.app.connect()
        #expect(h.app.session.value?.adapterName == "MythTV v35 (fake)")
        #expect(model.adapterName == "MythTV v35 (fake)")
        #expect(model.backendInfo?.hostName == "backend-host")
    }

    @Test func theOnboardingModelConnectsTheAppModelAndKeepsOtherSettings() async {
        let h = Harness(saved: AppSettings(commercialSkipMode: .off, askBeforeDelete: false))
        let model = h.app.makeOnboardingModel()
        model.addressText = "backend.invalid"
        await model.connect()
        #expect(h.app.session.value?.info.hostName == "backend-host")
        #expect(model.connectState.value?.hostName == "backend-host")
        #expect(model.adapterName == "MythTV v35 (fake)")
        #expect(h.settings.load() == AppSettings(
            backend: savedBackend, commercialSkipMode: .off, askBeforeDelete: false))
    }

    @Test func aFailedOnboardingConnectShowsTheAppModelsMessage() async {
        let h = Harness()
        let model = h.app.makeOnboardingModel()
        model.addressText = "nowhere.invalid"
        await model.connect()
        #expect(model.connectState.message == h.app.session.message)
        #expect(model.connectState.message != nil)
    }

    @Test func discoveryComesFromTheAppsDiscovery() async {
        let h = Harness()
        let settings = h.app.makeSettingsModel()
        let onboarding = h.app.makeOnboardingModel()
        settings.startDiscovery()
        onboarding.startDiscovery()
        #expect(h.discovery.discoverCount == 2)
        let found = DiscoveredBackend(id: "a", name: "Den", connection: otherBackend)
        h.discovery.push([found])
        await waitUntil(settings) { $0.discovered == [found] }
        await waitUntil(onboarding) { $0.discovered == [found] }
        settings.stopDiscovery()
        onboarding.stopDiscovery()
        #expect(h.discovery.activeStreamCount == 0)
    }

    @Test func modelsMadeByTheFactoryDoNotKeepTheAppModelAlive() {
        var h: Harness? = Harness()
        weak var weakApp: AppModel?
        weakApp = h?.app
        let settings = h?.app.makeSettingsModel()
        let onboarding = h?.app.makeOnboardingModel()
        h = nil
        #expect(weakApp == nil)
        #expect(settings != nil && onboarding != nil)
    }
}
