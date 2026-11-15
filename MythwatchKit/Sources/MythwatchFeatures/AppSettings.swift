import Foundation
import MythwatchBackend
import MythwatchPlayback

/// User settings (SPEC 6.2).
///
/// Decoding is lenient by design: a missing key, a value of the wrong type, or a value outside
/// its allowed set loads as that field's default and never affects the other fields. Unknown keys
/// are ignored.
public struct AppSettings: Sendable, Equatable, Codable {
    public static let skipForwardChoices = [10, 15, 30, 60]
    public static let skipBackwardChoices = [5, 10, 15, 30]

    public var backend: BackendConnection?
    public var commercialSkipMode: CommercialSkipMode
    public var skipForwardSeconds: Int
    public var skipBackwardSeconds: Int
    public var deinterlace: Bool
    public var askBeforeDelete: Bool

    public init(
        backend: BackendConnection? = nil,
        commercialSkipMode: CommercialSkipMode = .auto,
        skipForwardSeconds: Int = 30,
        skipBackwardSeconds: Int = 10,
        deinterlace: Bool = true,
        askBeforeDelete: Bool = true
    ) {
        self.backend = backend
        self.commercialSkipMode = commercialSkipMode
        self.skipForwardSeconds = skipForwardSeconds
        self.skipBackwardSeconds = skipBackwardSeconds
        self.deinterlace = deinterlace
        self.askBeforeDelete = askBeforeDelete
    }

    private enum CodingKeys: String, CodingKey {
        case backend, commercialSkipMode, skipForwardSeconds, skipBackwardSeconds, deinterlace,
            askBeforeDelete
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        // `try?` on each field: a bad field falls back to its default, the rest are kept.
        // (`try?` flattens the optional, so a missing key and a bad value both give nil.)
        backend = try? c.decodeIfPresent(BackendConnection.self, forKey: .backend)
        commercialSkipMode =
            (try? c.decodeIfPresent(CommercialSkipMode.self, forKey: .commercialSkipMode))
            ?? d.commercialSkipMode
        let forward = try? c.decodeIfPresent(Int.self, forKey: .skipForwardSeconds)
        skipForwardSeconds =
            forward.flatMap { Self.skipForwardChoices.contains($0) ? $0 : nil }
            ?? d.skipForwardSeconds
        let backward = try? c.decodeIfPresent(Int.self, forKey: .skipBackwardSeconds)
        skipBackwardSeconds =
            backward.flatMap { Self.skipBackwardChoices.contains($0) ? $0 : nil }
            ?? d.skipBackwardSeconds
        deinterlace = (try? c.decodeIfPresent(Bool.self, forKey: .deinterlace)) ?? d.deinterlace
        askBeforeDelete =
            (try? c.decodeIfPresent(Bool.self, forKey: .askBeforeDelete)) ?? d.askBeforeDelete
    }
}

public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// Stores settings as one JSON blob under `settings.v1`. Anything unreadable loads as defaults.
///
/// `@unchecked Sendable` because this SDK does not declare `UserDefaults` `Sendable`. It is safe
/// because the only stored property is an immutable `let` reference to a `UserDefaults`, which
/// Apple documents as thread-safe (reads and writes may come from any thread), and the store
/// keeps no other state.
public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let key = "settings.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> AppSettings {
        // `data(forKey:)` returns nil when the stored value is not `Data`.
        guard let data = defaults.data(forKey: Self.key),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
