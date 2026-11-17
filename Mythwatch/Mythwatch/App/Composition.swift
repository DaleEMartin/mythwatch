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
            return DemoBackend.appModel(backendSaved: arguments.contains("-MythwatchFakesBackendSaved"))
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

