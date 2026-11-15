import Foundation
import MythwatchBackend
import MythwatchDomain
import MythwatchFeatures
import MythwatchPlayback
import MythwatchTestSupport
import Synchronization
import Testing

// MARK: - Probe replies

// `BackendProbe`'s two version-neutral endpoints and the one key path it reads (SPEC §4). These
// tests drive the real probe through the real connector, so they have to answer it.
private let infoPath = "/Myth/GetBackendInfo"
private let hostNamePath = "/Myth/GetHostName"

private func backendAnswering(version: String, hostName: String) -> FixtureTransport {
    let t = FixtureTransport()
    t.stub(.get, path: infoPath, body: #"{"BackendInfo": {"Build": {"Version": "\#(version)"}}}"#)
    t.stub(.get, path: hostNamePath, body: #"{"String": "\#(hostName)"}"#)
    return t
}

private let alpha = BackendConnection(baseURL: URL(string: "http://alpha:6544")!)
private let beta = BackendConnection(baseURL: URL(string: "http://beta:6544")!)
private let v35 = BackendVersion(major: 35, minor: 0, raw: "v35.0")
private let v36 = BackendVersion(major: 36, minor: 0, raw: "v36.0")

// MARK: - A transport that can hold a request open

/// An `HTTPTransport` for these tests: answers each host from its own `FixtureTransport`, and
/// can park the next request to a host until the test releases it. Built on the same
/// continuation pattern as `FakeCallRecorder` (SPEC §8): nothing sleeps, yields or polls.
///
/// Cancelling a parked request's task behaves like `URLSessionTransport` (it throws
/// `.unreachable`, SPEC §4) unless the request was parked with `.keepParked`, which ignores
/// cancellation so a test can deliver a stale answer after a newer one.
private final class ParkingTransport: HTTPTransport {
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

private struct Oddity: Error, CustomStringConvertible {
    var description: String { "DIAG-oddity: something no adapter should throw" }
}

// MARK: - Fixture

/// One model over two backends: `alpha` reports v35 (made by `factory35`), `beta` reports v36
/// (made by `factory36`). Each factory returns its own `FakeBackendAdapter`.
@MainActor
private struct Harness {
    let settings: InMemorySettingsStore
    let transport: ParkingTransport
    let factory35 = FakeAdapterFactory(name: "Fake 35", supports: { $0.major == 35 })
    let factory36 = FakeAdapterFactory(name: "Fake 36", supports: { $0.major == 36 })
    let model: AppModel

    init(backend: BackendConnection? = alpha, registerFactories: Bool = true) {
        settings = InMemorySettingsStore(AppSettings(backend: backend))
        transport = ParkingTransport([
            "alpha": backendAnswering(version: "v35.0", hostName: "alpha-host"),
            "beta": backendAnswering(version: "v36.0", hostName: "beta-host"),
        ])
        var registry = AdapterRegistry()
        if registerFactories {
            registry.register(factory35)
            registry.register(factory36)
        }
        model = AppModel(
            settings: settings,
            connector: BackendConnector(registry: registry, transport: transport),
            makeEngine: { fatalError("M2-4: AppModel must not make a player engine") },
            discovery: FakeBackendDiscovery(),
            now: TestClock().now)
    }

    func use(_ connection: BackendConnection?) {
        var s = settings.load()
        s.backend = connection
        settings.save(s)
    }

    var session: BackendSession? { model.session.value }
    var adapter: FakeBackendAdapter? { session?.adapter as? FakeBackendAdapter }
}

// MARK: - Tests

@MainActor
@Suite("AppModel connection flow")
struct AppModelTests {
    // MARK: Basic states

    @Test func startsIdleAndDoesNothingUntilConnectIsCalled() {
        let h = Harness()
        #expect(h.model.session.isIdle)
        #expect(h.transport.requests.isEmpty)
        #expect(h.settings.loadCount == 0)
    }

    @Test func noBackendConfiguredStaysIdleAndSendsNothing() async {
        let h = Harness(backend: nil)
        await h.model.connect()
        #expect(h.model.session.isIdle)
        #expect(h.transport.requests.isEmpty)
        #expect(h.factory35.makeRequests.isEmpty)
    }

    @Test func successLoadsInfoAndAdapter() async throws {
        let h = Harness()
        await h.model.connect()
        let session = try #require(h.session)
        #expect(session.info == BackendInfo(version: v35, hostName: "alpha-host"))
        #expect(session.info.version.raw == "v35.0")
        #expect(h.adapter === h.factory35.adapter)
        #expect(h.factory35.makeRequests == [.init(connection: alpha, version: v35)])
        #expect(h.transport.probeCount == 1)
    }

    @Test func isLoadingWhileTheProbeIsInFlight() async throws {
        let h = Harness()
        h.transport.parkNext("alpha")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()
        #expect(h.model.session.isLoading)
        #expect(h.factory35.makeRequests.isEmpty)
        h.transport.releaseNext("alpha")
        await task.value
        #expect(h.adapter === h.factory35.adapter)
    }

    // MARK: Failures

    @Test func aBackendErrorBecomesItsUserMessage() async {
        let h = Harness()
        h.transport.parkNext("alpha")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()
        h.transport.releaseNext("alpha", throwing: BackendError.unreachable("DIAG Connection refused"))
        await task.value
        #expect(h.model.session.message == UserMessage(.unreachable("DIAG Connection refused")))
        #expect(h.model.session.message?.detail.contains("DIAG") == false)
    }

    @Test func anUnsupportedVersionNamesTheVersion() async throws {
        let h = Harness(registerFactories: false)
        await h.model.connect()
        let message = try #require(h.model.session.message)
        #expect(message == UserMessage(.unsupportedVersion("v35.0")))
        #expect(message.detail.contains("v35.0"))
        #expect(!message.canRetry)
    }

    @Test func anErrorThatIsNotABackendErrorGetsTheGenericMessage() async {
        let h = Harness()
        h.transport.parkNext("alpha")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()
        h.transport.releaseNext("alpha", throwing: Oddity())
        await task.value
        #expect(h.model.session.message == .unexpected)
    }

    @Test func aFailureAfterASuccessReplacesTheSessionWithTheMessage() async {
        let h = Harness()
        await h.model.connect()
        #expect(h.session != nil)
        h.transport.parkNext("alpha")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()
        h.transport.releaseNext("alpha", throwing: BackendError.timedOut)
        await task.value
        #expect(h.model.session.message == UserMessage(.timedOut))
        #expect(h.session == nil)
    }

    @Test func retryingAfterAFailureShowsLoading() async {
        let h = Harness()
        h.transport.parkNext("alpha")
        let first = Task { await h.model.connect() }
        await h.transport.waitForParked()
        h.transport.releaseNext("alpha", throwing: BackendError.timedOut)
        await first.value
        #expect(h.model.session.message != nil)

        h.transport.parkNext("alpha")
        let retry = Task { await h.model.connect() }
        await h.transport.waitForParked()
        #expect(h.model.session.isLoading)
        h.transport.releaseNext("alpha")
        await retry.value
        #expect(h.adapter === h.factory35.adapter)
    }

    // MARK: Concurrency

    @Test func twoConcurrentConnectsProbeOnceAndBothWaitForIt() async {
        let h = Harness()
        h.transport.parkNext("alpha")
        // Both calls are enqueued on the main actor before this test suspends, so both reach
        // `connect()` before the probe can start.
        let first = Task { await h.model.connect() }
        let second = Task { await h.model.connect() }
        await h.transport.waitForParked()
        #expect(h.model.session.isLoading)
        h.transport.releaseNext("alpha")
        await first.value
        await second.value
        #expect(h.transport.probeCount == 1)
        #expect(h.factory35.makeRequests.count == 1)
        #expect(h.adapter === h.factory35.adapter)
    }

    @Test func aConnectThatJoinsAnInFlightOneDoesNotReturnEarly() async {
        let h = Harness()
        h.transport.parkNext("alpha")
        let first = Task { await h.model.connect() }
        await h.transport.waitForParked()
        let second = Task { () -> Bool in
            await h.model.connect()
            return h.model.session.value != nil  // read on return: the joined connect has finished
        }
        h.transport.releaseNext("alpha")
        #expect(await second.value)
        await first.value
        #expect(h.transport.probeCount == 1)
    }

    // MARK: Changing and repeating the address

    @Test func changingTheAddressAndReconnectingReplacesTheSession() async throws {
        let h = Harness()
        await h.model.connect()
        #expect(h.adapter === h.factory35.adapter)

        h.use(beta)
        h.transport.parkNext("beta")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()
        #expect(h.model.session.isLoading)  // the alpha session is not shown for beta
        h.transport.releaseNext("beta")
        await task.value

        let session = try #require(h.session)
        #expect(session.info == BackendInfo(version: v36, hostName: "beta-host"))
        #expect(h.adapter === h.factory36.adapter)
        #expect(h.factory36.makeRequests == [.init(connection: beta, version: v36)])
    }

    @Test func reconnectingToTheSameAddressKeepsTheSessionVisibleUntilTheNewOneArrives() async throws {
        let h = Harness()
        await h.model.connect()
        h.transport.parkNext("alpha")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()
        #expect(h.adapter === h.factory35.adapter)
        #expect(h.factory35.makeRequests.count == 1)
        h.transport.releaseNext("alpha")
        await task.value
        #expect(h.factory35.makeRequests.count == 2)  // a new adapter was made and installed
        #expect(h.adapter === h.factory35.adapter)
        #expect(h.transport.probeCount == 2)
    }

    @Test func aStaleSuccessArrivingWhileTheNewAddressLoadsIsIgnored() async {
        let h = Harness()
        h.transport.parkNext("alpha", onCancel: .keepParked)
        let old = Task { await h.model.connect() }
        await h.transport.waitForParked(host: "alpha")

        h.use(beta)
        h.transport.parkNext("beta")
        let new = Task { await h.model.connect() }
        await h.transport.waitForParked(host: "beta")

        h.transport.releaseNext("alpha")  // the old probe answers anyway
        await old.value
        #expect(h.model.session.isLoading)
        #expect(h.session == nil)

        h.transport.releaseNext("beta")
        await new.value
        #expect(h.adapter === h.factory36.adapter)
    }

    @Test func aStaleSuccessArrivingAfterTheNewSessionIsIgnored() async {
        let h = Harness()
        h.transport.parkNext("alpha", onCancel: .keepParked)
        let old = Task { await h.model.connect() }
        await h.transport.waitForParked(host: "alpha")

        h.use(beta)
        await h.model.connect()
        #expect(h.adapter === h.factory36.adapter)

        h.transport.releaseNext("alpha")
        await old.value
        #expect(h.adapter === h.factory36.adapter)
        #expect(h.session?.info.hostName == "beta-host")
    }

    @Test func aConnectForANewAddressCancelsTheOldOneWithoutShowingUnreachable() async {
        let h = Harness()
        h.transport.parkNext("alpha")  // cancelling it throws .unreachable, like URLSession
        let old = Task { await h.model.connect() }
        await h.transport.waitForParked(host: "alpha")

        h.use(beta)
        h.transport.parkNext("beta")
        let new = Task { await h.model.connect() }
        // The new connect cancels the old request before it starts its own probe.
        await h.transport.waitForParked(host: "beta")
        #expect(h.transport.cancelledCount == 1)
        #expect(h.transport.releaseNext("alpha") == false)  // (if it was not cancelled, unblocks it)
        await old.value  // its cancelled request threw .unreachable
        #expect(h.model.session.isLoading)
        #expect(h.model.session.message == nil)

        h.transport.releaseNext("beta")
        await new.value
        #expect(h.adapter === h.factory36.adapter)
        #expect(h.factory35.makeRequests.isEmpty)
    }

    @Test func removingTheBackendWhileConnectingCancelsAndGoesIdle() async {
        let h = Harness()
        h.transport.parkNext("alpha")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()

        h.use(nil)
        await h.model.connect()
        #expect(h.model.session.isIdle)
        #expect(h.transport.cancelledCount == 1)
        #expect(h.transport.releaseNext("alpha") == false)  // (if it was not cancelled, unblocks it)
        await task.value
        #expect(h.model.session.isIdle)
        #expect(h.factory35.makeRequests.isEmpty)
    }

    @Test func removingTheBackendAfterASuccessGoesIdle() async {
        let h = Harness()
        await h.model.connect()
        h.use(nil)
        await h.model.connect()
        #expect(h.model.session.isIdle)
        #expect(h.transport.probeCount == 1)
    }

    // MARK: Cancellation by the caller

    @Test func cancellingTheCallerDoesNotCancelTheConnect() async {
        let h = Harness()
        h.transport.parkNext("alpha")
        let task = Task { await h.model.connect() }
        await h.transport.waitForParked()
        task.cancel()
        // Had the cancellation reached the request, it would have been ended synchronously above.
        #expect(h.transport.cancelledCount == 0)
        #expect(h.model.session.isLoading)
        h.transport.releaseNext("alpha")
        await task.value
        #expect(h.model.session.message == nil)
        #expect(h.adapter === h.factory35.adapter)
    }

    @Test func aConnectStartedFromACancelledTaskStillCompletes() async {
        let h = Harness()
        let task = Task { await h.model.connect() }
        task.cancel()  // before it starts: the test has not suspended since creating it
        await task.value
        #expect(h.model.session.message == nil)
        #expect(h.adapter === h.factory35.adapter)
    }
}
