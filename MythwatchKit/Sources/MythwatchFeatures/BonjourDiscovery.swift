import Foundation
import MythwatchBackend

/// One Bonjour service instance as a browse reports it (SPEC 6.3 "Bonjour discovery").
public struct BonjourService: Hashable, Sendable {
    public let name: String
    public let type: String
    public let domain: String

    public init(name: String, type: String, domain: String) {
        self.name = name
        self.type = type
        self.domain = domain
    }
}

/// What resolving a `BonjourService` gives: the target host, the advertised port, and the raw
/// TXT record (length-prefixed strings).
public struct BonjourResolution: Hashable, Sendable {
    public let hostTarget: String
    public let port: Int
    public let txt: Data

    public init(hostTarget: String, port: Int, txt: Data = Data()) {
        self.hostTarget = hostTarget
        self.port = port
        self.txt = txt
    }
}

/// Browses one service type. Each value is the full set of instances present now.
/// The stream ends if browsing fails for good.
public protocol BonjourBrowsing: Sendable {
    func browse(type: String) -> AsyncStream<Set<BonjourService>>
}

/// Resolves a service instance. Returns nil when it cannot be resolved, and must return
/// promptly (nil) when the calling task is cancelled.
public protocol BonjourResolving: Sendable {
    func resolve(_ service: BonjourService) async -> BonjourResolution?
}

/// How a MythTV backend advertises itself, and how that becomes a `DiscoveredBackend`
/// (`docs/BACKEND-V35.md` "Discovery"). Pure.
public enum MythBackendAdvertisement {
    public static let serviceType = "_mythbackend._tcp"

    /// The backend advertises its UPnP server, which listens on the API port plus 6.
    static let advertisedPortOffset = 6
    private static let namePrefix = "Mythbackend on "

    /// The strings of a raw TXT record (each one a length byte and that many bytes). Stops at
    /// a string that runs past the end.
    public static func txtStrings(_ txt: Data) -> [String] {
        let bytes = [UInt8](txt)
        var strings: [String] = []
        var i = 0
        while i < bytes.count {
            let length = Int(bytes[i])
            let end = i + 1 + length
            guard end <= bytes.count else { break }
            strings.append(String(decoding: bytes[(i + 1)..<end], as: UTF8.self))
            i = end
        }
        return strings
    }

    /// The backend a resolved `_mythbackend._tcp` instance stands for, or nil when it is a slave
    /// or its host or port cannot make an address.
    public static func backend(_ service: BonjourService, _ resolution: BonjourResolution) -> DiscoveredBackend? {
        if txtStrings(resolution.txt).contains(where: { $0.lowercased() == "slave" }) { return nil }
        let apiPort = resolution.port - advertisedPortOffset
        guard (1...65535).contains(apiPort) else { return nil }
        var host = Substring(resolution.hostTarget)
        if host.hasSuffix(".") { host = host.dropLast() }
        // `BackendAddress` validates the host and builds the same URL the typed address would.
        guard !host.isEmpty, !host.contains(":"),
            let connection = BackendAddress.parse("\(host):\(apiPort)")
        else { return nil }
        return DiscoveredBackend(id: service.name, name: displayName(service.name), connection: connection)
    }

    private static func displayName(_ instance: String) -> String {
        guard instance.count > namePrefix.count,
            instance.prefix(namePrefix.count).lowercased() == namePrefix.lowercased()
        else { return instance }
        return String(instance.dropFirst(namePrefix.count))
    }
}

/// `BackendDiscovery` over Bonjour: browses `_mythbackend._tcp`, resolves each instance once per
/// appearance, and reports the backends found (SPEC 6.3 "Bonjour discovery").
public final class BonjourBackendDiscovery: BackendDiscovery {
    private let browser: any BonjourBrowsing
    private let resolver: any BonjourResolving

    public init(browser: any BonjourBrowsing, resolver: any BonjourResolving) {
        self.browser = browser
        self.resolver = resolver
    }

    private enum Event: Sendable {
        case browsed(Set<BonjourService>)
        case resolved(BonjourService, appearance: Int, BonjourResolution?)
        case browseEnded
    }

    public func discover() -> AsyncStream<[DiscoveredBackend]> {
        let (output, out) = AsyncStream<[DiscoveredBackend]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (events, sink) = AsyncStream<Event>.makeStream()
        let browse = browser.browse(type: MythBackendAdvertisement.serviceType)
        let resolver = self.resolver

        let browsing = Task {
            for await services in browse { sink.yield(.browsed(services)) }
            sink.yield(.browseEnded)
        }
        let running = Task {
            // Each appearance of a service gets a new number, so an answer for an earlier
            // appearance (or for a service that has gone) is recognised and dropped.
            var present: [BonjourService: Int] = [:]
            var resolving: [BonjourService: Task<Void, Never>] = [:]
            var found: [BonjourService: DiscoveredBackend] = [:]
            var reported: [DiscoveredBackend]?
            var nextAppearance = 0

            loop: for await event in events {
                switch event {
                case .browsed(let services):
                    for gone in present.keys where !services.contains(gone) {
                        present[gone] = nil
                        found[gone] = nil
                        resolving.removeValue(forKey: gone)?.cancel()
                    }
                    for new in services where present[new] == nil {
                        nextAppearance += 1
                        let appearance = nextAppearance
                        present[new] = appearance
                        resolving[new] = Task {
                            let resolution = await resolver.resolve(new)
                            sink.yield(.resolved(new, appearance: appearance, resolution))
                        }
                    }
                case .resolved(let service, let appearance, let resolution):
                    guard present[service] == appearance else { continue }
                    resolving[service] = nil
                    found[service] = resolution.flatMap { MythBackendAdvertisement.backend(service, $0) }
                case .browseEnded:
                    break loop
                }
                let list = found.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                if list != reported {
                    reported = list
                    out.yield(list)
                }
            }
            resolving.values.forEach { $0.cancel() }
            out.finish()
        }
        out.onTermination = { _ in
            browsing.cancel()
            running.cancel()
            sink.finish()
        }
        return output
    }
}
