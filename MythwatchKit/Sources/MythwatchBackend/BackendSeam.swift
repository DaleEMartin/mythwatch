import Foundation
import MythwatchDomain

public struct BackendConnection: Hashable, Sendable, Codable {
    public var baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }
}

/// A backend's reported version, reduced to major and minor.
///
/// Equality, hashing and ordering all use `major` and `minor` only. `raw` is kept for
/// diagnostics and error messages and does not take part, so `v35.0` and `v35.0-12-gabcdef`
/// are equal.
public struct BackendVersion: Hashable, Sendable, Comparable {
    public let major: Int
    public let minor: Int
    public let raw: String

    public init(major: Int, minor: Int, raw: String) {
        self.major = major
        self.minor = minor
        self.raw = raw
    }

    /// Accepts an optional leading `v`, a major number, and an optional `.minor`; anything
    /// after that (`.1`, `-12-gabcdef`, `-Pre-676-...`) is ignored. Returns nil otherwise.
    public init?(parsing raw: String) {
        var rest = Substring(raw)
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        let majorDigits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard let major = Int(majorDigits) else { return nil }
        rest = rest.dropFirst(majorDigits.count)
        var minor = 0
        if rest.first == "." {
            let minorDigits = rest.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
            if let m = Int(minorDigits) { minor = m }
        }
        self.init(major: major, minor: minor, raw: raw)
    }

    public static func == (lhs: BackendVersion, rhs: BackendVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
    }

    public static func < (lhs: BackendVersion, rhs: BackendVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public struct BackendCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let recordings = BackendCapabilities(rawValue: 1 << 0)
    public static let resumePosition = BackendCapabilities(rawValue: 1 << 1)
    public static let bookmarks = BackendCapabilities(rawValue: 1 << 2)
    public static let commercialBreaks = BackendCapabilities(rawValue: 1 << 3)
    public static let deleteRecording = BackendCapabilities(rawValue: 1 << 4)
    public static let liveTV = BackendCapabilities(rawValue: 1 << 5)
    public static let videoLibrary = BackendCapabilities(rawValue: 1 << 6)
    public static let login = BackendCapabilities(rawValue: 1 << 7)
}

public protocol BackendAdapter: Sendable {
    var version: BackendVersion { get }
    var capabilities: BackendCapabilities { get }
    var recordings: any RecordingsService { get }
    var playbackState: any PlaybackStateService { get }
    var markup: any MarkupService { get }
    var media: any MediaLocator { get }
    var liveTV: (any LiveTVService)? { get }
    var videoLibrary: (any VideoLibraryService)? { get }
}

public protocol BackendAdapterFactory: Sendable {
    var name: String { get }
    func supports(_ version: BackendVersion) -> Bool
    func makeAdapter(
        connection: BackendConnection, version: BackendVersion, transport: any HTTPTransport
    ) -> any BackendAdapter
}

public struct AdapterRegistry: Sendable {
    private var factories: [any BackendAdapterFactory] = []

    public init() {}

    public mutating func register(_ factory: any BackendAdapterFactory) {
        factories.append(factory)
    }

    /// The first registered factory whose `supports` is true; else `.unsupportedVersion(raw)`.
    public func factory(for version: BackendVersion) throws -> any BackendAdapterFactory {
        guard let found = factories.first(where: { $0.supports(version) }) else {
            throw BackendError.unsupportedVersion(version.raw)
        }
        return found
    }
}

/// What `BackendConnector.connect` produces: the probed info and the adapter made for it, so a
/// caller that needs the host name does not probe a second time. `adapterName` is the `name` of
/// the factory that made the adapter ("MythTV v35"), for screens that say what Mythwatch is using.
public struct ConnectedBackend: Sendable {
    public let info: BackendInfo
    public let adapter: any BackendAdapter
    public let adapterName: String

    public init(info: BackendInfo, adapter: any BackendAdapter, adapterName: String) {
        self.info = info
        self.adapter = adapter
        self.adapterName = adapterName
    }
}

public struct BackendConnector: Sendable {
    private let registry: AdapterRegistry
    private let transport: any HTTPTransport

    public init(registry: AdapterRegistry, transport: any HTTPTransport) {
        self.registry = registry
        self.transport = transport
    }

    /// Probe once, resolve a factory, make the adapter. Errors from each step surface unchanged.
    public func connect(_ connection: BackendConnection) async throws -> ConnectedBackend {
        let info = try await BackendProbe(transport: transport).probe(connection)
        let factory = try registry.factory(for: info.version)
        let adapter = factory.makeAdapter(connection: connection, version: info.version, transport: transport)
        return ConnectedBackend(info: info, adapter: adapter, adapterName: factory.name)
    }
}
