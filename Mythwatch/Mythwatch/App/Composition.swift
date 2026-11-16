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
        return AppModel(
            settings: UserDefaultsSettingsStore(),
            connector: BackendConnector(registry: registry, transport: URLSessionTransport()),
            makeEngine: { preconditionFailure("The player arrives in M3-3.") },
            discovery: NoBackendDiscovery(),
            now: { ContinuousClock.now })
    }
}

/// Bonjour discovery arrives in M5-2. Until then nothing is ever found.
struct NoBackendDiscovery: BackendDiscovery {
    func discover() -> AsyncStream<[DiscoveredBackend]> { AsyncStream { $0.finish() } }
}
