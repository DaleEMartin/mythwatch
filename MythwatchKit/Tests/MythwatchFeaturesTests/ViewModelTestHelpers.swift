import Foundation
import MythwatchDomain
import MythwatchBackend
import MythwatchFeatures
import MythwatchTestSupport
import Synchronization

/// Neutral recordings for the view-model tests.
func rid(_ n: Int) -> RecordingID { RecordingID(rawValue: n) }

func episode(
    _ n: Int, title: String = "Garden Tales", season: Int? = 1, episode: Int? = nil,
    watched: Bool = false, key: String? = "KEY-GARDEN", day: Int = 0
) -> Recording {
    let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400 + Double(day))
    return .fixture(
        id: rid(n), title: title, subtitle: "Episode \(n)", season: season, episode: episode ?? n,
        seriesKey: key, recordingStart: start, recordingEnd: start.addingTimeInterval(1800),
        flags: watched ? [.watched] : [])
}

/// A `RecordingsService` that behaves like `URLSessionTransport` when its task is cancelled: it
/// reports `.unreachable` instead of `CancellationError`.
struct UnreachableOnCancel: RecordingsService {
    let inner: FakeRecordingsService
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch is CancellationError {
            throw BackendError.unreachable("cancelled")
        }
    }
    func allRecordings() async throws -> [Recording] { try await mapped { try await inner.allRecordings() } }
    func recording(id: RecordingID) async throws -> Recording { try await mapped { try await inner.recording(id: id) } }
    func setWatched(_ watched: Bool, id: RecordingID) async throws {
        try await mapped { try await inner.setWatched(watched, id: id) }
    }
    func delete(id: RecordingID, allowRerecord: Bool) async throws {
        try await mapped { try await inner.delete(id: id, allowRerecord: allowRerecord) }
    }
}

/// A `PlaybackStateService` that returns fixed answers, for values the fake store cannot hold
/// (a zero position).
struct StubPlaybackState: PlaybackStateService {
    var resume: Duration?
    var mark: Duration?
    func resumePosition(for id: RecordingID) async throws -> Duration? { resume }
    func setResumePosition(_ position: Duration?, for id: RecordingID) async throws {}
    func bookmark(for id: RecordingID) async throws -> Duration? { mark }
    func setBookmark(_ position: Duration?, for id: RecordingID) async throws {}
}

/// Collects the changes a `ShowViewModel` reports.
@MainActor final class ChangeLog {
    private(set) var changes: [RecordingChange] = []
    func record(_ change: RecordingChange) { changes.append(change) }
}

// MARK: - Probe replies

// `BackendProbe`'s two version-neutral endpoints and the one key path it reads (SPEC §4). These
// tests drive the real probe through the real connector, so they have to answer it.
let infoPath = "/Myth/GetBackendInfo"
let hostNamePath = "/Myth/GetHostName"

func backendAnswering(version: String, hostName: String) -> FixtureTransport {
    let t = FixtureTransport()
    t.stub(.get, path: infoPath, body: #"{"BackendInfo": {"Build": {"Version": "\#(version)"}}}"#)
    t.stub(.get, path: hostNamePath, body: #"{"String": "\#(hostName)"}"#)
    return t
}

// MARK: - A transport that can hold a request open

/// An `HTTPTransport` for these tests: answers each host from its own `FixtureTransport`, and
/// can park the next request to a host until the test releases it. Built on the same
/// continuation pattern as `FakeCallRecorder` (SPEC §8): nothing sleeps, yields or polls.
///
/// Cancelling a parked request's task behaves like `URLSessionTransport` (it throws
/// `.unreachable`, SPEC §4) unless the request was parked with `.keepParked`, which ignores
/// cancellation so a test can deliver a stale answer after a newer one.
final class ParkingTransport: HTTPTransport {
    enum OnCancel: Sendable { case throwUnreachable, keepParked }

    private struct Parked {
        let id: Int
        let host: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let host: String?
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var parkNext: [String: OnCancel] = [:]
        var parked: [Parked] = []
        var waiters: [Waiter] = []
        var requests: [HTTPRequest] = []
        var cancelledBeforeParking: Set<Int> = []
        var cancelledCount = 0
        var nextID = 0
    }

    private let hosts: [String: FixtureTransport]
    private let state = Mutex(State())

    init(_ hosts: [String: FixtureTransport]) { self.hosts = hosts }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var probeCount: Int { requests.filter { $0.url.path == infoPath }.count }
    /// How many parked requests were ended by cancelling their task.
    var cancelledCount: Int { state.withLock { $0.cancelledCount } }

    /// Park the next request to `host` until it is released.
    func parkNext(_ host: String, onCancel: OnCancel = .throwUnreachable) {
        state.withLock { $0.parkNext[host] = onCancel }
    }

    /// Returns once at least `count` requests (to `host`, or to any host) are parked.
    func waitForParked(_ count: Int = 1, host: String? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s -> Bool in
                if Self.parkedCount(s, host) >= count { return true }
                s.waiters.append(Waiter(host: host, count: count, continuation: continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Let the oldest parked request to `host` continue to its fixture, or throw `error` instead.
    @discardableResult
    func releaseNext(_ host: String, throwing error: (any Error)? = nil) -> Bool {
        let found = state.withLock { s -> Parked? in
            guard let i = s.parked.firstIndex(where: { $0.host == host }) else { return nil }
            return s.parked.remove(at: i)
        }
        guard let found else { return false }
        if let error { found.continuation.resume(throwing: error) } else { found.continuation.resume() }
        return true
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let host = request.url.host ?? ""
        let park = state.withLock { s -> (id: Int, mode: OnCancel)? in
            s.requests.append(request)
            guard let mode = s.parkNext.removeValue(forKey: host) else { return nil }
            s.nextID += 1
            return (s.nextID, mode)
        }
        if let park { try await self.park(id: park.id, host: host, onCancel: park.mode) }
        guard let fixture = hosts[host] else { throw BackendError.unreachable("no fixture for \(host)") }
        return try await fixture.send(request)
    }

    private static func parkedCount(_ s: State, _ host: String?) -> Int {
        s.parked.filter { host == nil || $0.host == host }.count
    }

    private func park(id: Int, host: String, onCancel: OnCancel) async throws {
        let cancelled = BackendError.unreachable("cancelled")  // what URLSessionTransport throws
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { s -> (cancelled: Bool, wake: [Waiter]) in
                    if s.cancelledBeforeParking.remove(id) != nil { return (true, []) }
                    s.parked.append(Parked(id: id, host: host, continuation: continuation))
                    var wake: [Waiter] = []
                    var remaining: [Waiter] = []
                    for waiter in s.waiters {
                        if Self.parkedCount(s, waiter.host) >= waiter.count {
                            wake.append(waiter)
                        } else {
                            remaining.append(waiter)
                        }
                    }
                    s.waiters = remaining
                    return (false, wake)
                }
                if outcome.cancelled { continuation.resume(throwing: cancelled) }
                for waiter in outcome.wake { waiter.continuation.resume() }
            }
        } onCancel: {
            guard onCancel == .throwUnreachable else { return }
            let found = state.withLock { s -> Parked? in
                s.cancelledCount += 1
                if let i = s.parked.firstIndex(where: { $0.id == id }) { return s.parked.remove(at: i) }
                s.cancelledBeforeParking.insert(id)
                return nil
            }
            found?.continuation.resume(throwing: cancelled)
        }
    }
}
