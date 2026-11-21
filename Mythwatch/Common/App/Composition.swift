import Foundation
import MythBackendV35
import MythwatchBackend
import MythwatchFeatures
#if DEBUG
import MythwatchTestSupport
#endif

/// The composition root (SPEC 6.3, 7): the one place concrete types are chosen.
enum Composition {
    static func makeAppModel(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        #if DEBUG
        if arguments.contains("-MythwatchFakes") {
            // M5-3: what goes wrong in the demo, for the resilience UI tests.
            let scenario: DemoBackend.Scenario =
                arguments.contains("-MythwatchFakesEmpty") ? .emptyLibrary
                : arguments.contains("-MythwatchFakesUnreachable") ? .unreachableAtLaunch
                : arguments.contains("-MythwatchFakesOutage") ? .outage
                : .normal
            return DemoBackend.appModel(
                backendSaved: arguments.contains("-MythwatchFakesBackendSaved"), scenario: scenario)
        }
        #endif
        var registry = AdapterRegistry()
        registry.register(V35AdapterFactory())
        let settings = UserDefaultsSettingsStore()
        return AppModel(
            settings: settings,
            connector: BackendConnector(registry: registry, transport: URLSessionTransport()),
            // One engine per playback, with the deinterlace setting as saved at that moment (SPEC 7).
            makeEngine: { VLCPlayerEngine(deinterlace: settings.load().deinterlace) },
            discovery: BonjourBackendDiscovery.onLocalNetwork(),
            now: { ContinuousClock.now })
    }
}

