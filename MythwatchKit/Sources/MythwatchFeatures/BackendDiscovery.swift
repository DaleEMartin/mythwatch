import Foundation
import MythwatchBackend

/// Finds backends on the local network (SPEC 6.3). The production implementation is a later task;
/// this is the seam `AppModel` and the settings view models are written against.
public protocol BackendDiscovery: Sendable {
    func discover() -> AsyncStream<[DiscoveredBackend]>
}

public struct DiscoveredBackend: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let connection: BackendConnection

    public init(id: String, name: String, connection: BackendConnection) {
        self.id = id
        self.name = name
        self.connection = connection
    }
}
