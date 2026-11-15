import Foundation
import MythwatchFeatures
import Synchronization

/// A `BackendDiscovery` the test drives with `push(_:)`.
///
/// Every `discover()` call gets its own stream (so a second call does not steal from the first),
/// and a new stream starts with the latest pushed list, if any, as a real discovery would report
/// what it already knows. Each stream is unbounded: a test pushes a handful of lists and sees all
/// of them in order. A stream the consumer drops is forgotten at once. `finish()` and `deinit`
/// end every stream; `discover()` after `finish()` gives an already-finished stream.
public final class FakeBackendDiscovery: BackendDiscovery {
    private typealias Continuation = AsyncStream<[DiscoveredBackend]>.Continuation

    private struct State {
        var continuations: [Int: Continuation] = [:]
        var latest: [DiscoveredBackend]?
        var finished = false
        var discoverCount = 0
        var nextID = 0
    }

    /// Held by the streams' termination handlers as well as by the fake; the fake's `deinit`
    /// empties it, which breaks the cycle through the continuations.
    private final class Box: Sendable {
        let state = Mutex(State())
    }

    private let box = Box()

    public init() {}

    deinit { finish() }

    /// How many times `discover()` has been called.
    public var discoverCount: Int { box.state.withLock { $0.discoverCount } }
    /// How many streams are open now.
    public var activeStreamCount: Int { box.state.withLock { $0.continuations.count } }

    public func discover() -> AsyncStream<[DiscoveredBackend]> {
        let box = self.box
        let (stream, continuation) = AsyncStream<[DiscoveredBackend]>.makeStream(
            bufferingPolicy: .unbounded)
        let id = box.state.withLock { s -> Int? in
            s.discoverCount += 1
            if s.finished { return nil }
            s.nextID += 1
            s.continuations[s.nextID] = continuation
            if let latest = s.latest { continuation.yield(latest) }
            return s.nextID
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { _ in
            box.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Delivers `list` to every open stream, and to streams opened later (as their first value).
    public func push(_ list: [DiscoveredBackend]) {
        let targets = box.state.withLock { s -> [Continuation] in
            s.latest = list
            return Array(s.continuations.values)
        }
        for continuation in targets { continuation.yield(list) }
    }

    /// Ends every open stream.
    public func finish() {
        let targets = box.state.withLock { s -> [Continuation] in
            s.finished = true
            defer { s.continuations.removeAll() }
            return Array(s.continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }
}
