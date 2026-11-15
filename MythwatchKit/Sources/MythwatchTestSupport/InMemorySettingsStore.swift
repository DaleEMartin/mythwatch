import Foundation
import MythwatchFeatures
import Synchronization

/// A `SettingsStore` that keeps its value in memory. Synchronous, like the protocol, so a test
/// reads and writes it without `await`.
public final class InMemorySettingsStore: SettingsStore {
    private struct State {
        var current: AppSettings
        var saved: [AppSettings] = []
        var loadCount = 0
    }

    private let state: Mutex<State>

    /// Starts with `initial` (defaults when omitted). The initial value is not counted as a save.
    public init(_ initial: AppSettings = AppSettings()) { state = Mutex(State(current: initial)) }

    public func load() -> AppSettings {
        state.withLock {
            $0.loadCount += 1
            return $0.current
        }
    }

    public func save(_ settings: AppSettings) {
        state.withLock {
            $0.current = settings
            $0.saved.append(settings)
        }
    }

    public var saveCount: Int { state.withLock { $0.saved.count } }
    public var loadCount: Int { state.withLock { $0.loadCount } }
    /// Every value passed to `save`, oldest first.
    public var saved: [AppSettings] { state.withLock { $0.saved } }
}
