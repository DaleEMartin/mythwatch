import Foundation
import MythwatchBackend
import MythwatchFeatures
import Synchronization
import Testing

// MARK: - Fakes for the two Bonjour ports (used only here)

/// A `BonjourBrowsing` the test drives with `push(_:)` and `end()`.
fileprivate final class FakeBonjourBrowser: BonjourBrowsing {
    private typealias Continuation = AsyncStream<Set<BonjourService>>.Continuation
    private struct State {
        var continuations: [Int: Continuation] = [:]
        var types: [String] = []
        var nextID = 0
        var terminated = 0
        var terminationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    private final class Box: Sendable { let state = Mutex(State()) }
    private let box = Box()

    var types: [String] { box.state.withLock { $0.types } }
    var openCount: Int { box.state.withLock { $0.continuations.count } }

    func browse(type: String) -> AsyncStream<Set<BonjourService>> {
        let box = self.box
        let (stream, continuation) = AsyncStream<Set<BonjourService>>.makeStream()
        let id = box.state.withLock { s in
            s.types.append(type)
            s.nextID += 1
            s.continuations[s.nextID] = continuation
            return s.nextID
        }
        continuation.onTermination = { _ in
            let ready = box.state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.continuations.removeValue(forKey: id)
                s.terminated += 1
                let n = s.terminated
                let ready = s.terminationWaiters.filter { $0.0 <= n }.map(\.1)
                s.terminationWaiters.removeAll { $0.0 <= n }
                return ready
            }
            ready.forEach { $0.resume() }
        }
        return stream
    }

    func push(_ services: Set<BonjourService>) {
        let targets = box.state.withLock { Array($0.continuations.values) }
        targets.forEach { $0.yield(services) }
    }

    func end() {
        let targets = box.state.withLock { Array($0.continuations.values) }
        targets.forEach { $0.finish() }
    }

    /// Returns once `count` browse streams have terminated.
    func waitForTerminations(_ count: Int) async {
        await withCheckedContinuation { c in
            let now = box.state.withLock { s -> Bool in
                if s.terminated >= count { return true }
                s.terminationWaiters.append((count, c))
                return false
            }
            if now { c.resume() }
        }
    }
}

/// A `BonjourResolving` whose calls park until the test answers them.
fileprivate final class FakeBonjourResolver: BonjourResolving {
    private struct State {
        /// Parked calls, oldest first.
        var pending: [(service: BonjourService, id: Int, c: CheckedContinuation<BonjourResolution?, Never>)] = []
        var nextID = 0
        var requests: [BonjourService: Int] = [:]
        var cancels: [BonjourService: Int] = [:]
        var waiters: [(BonjourService, Int, Bool, CheckedContinuation<Void, Never>)] = []

        mutating func takeReady() -> [CheckedContinuation<Void, Never>] {
            var ready: [CheckedContinuation<Void, Never>] = []
            waiters.removeAll { service, count, cancel, c in
                let seen = (cancel ? cancels[service] : requests[service]) ?? 0
                if seen >= count { ready.append(c); return true }
                return false
            }
            return ready
        }
    }
    private final class Box: Sendable { let state = Mutex(State()) }
    private let box = Box()
    /// When false, a cancelled call keeps waiting for `answer`, as a slow resolver might.
    let honoursCancellation: Bool

    init(honoursCancellation: Bool = true) { self.honoursCancellation = honoursCancellation }

    func requestCount(_ service: BonjourService) -> Int { box.state.withLock { $0.requests[service] ?? 0 } }

    func resolve(_ service: BonjourService) async -> BonjourResolution? {
        let box = self.box
        let honours = honoursCancellation
        let id = box.state.withLock { s in s.nextID += 1; return s.nextID }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<BonjourResolution?, Never>) in
                let (ready, cancelledAlready) = box.state.withLock { s in
                    s.requests[service, default: 0] += 1
                    let cancelled = honours && Task.isCancelled
                    if !cancelled { s.pending.append((service, id, c)) }
                    return (s.takeReady(), cancelled)
                }
                ready.forEach { $0.resume() }
                if cancelledAlready { c.resume(returning: nil) }
            }
        } onCancel: {
            let (ready, parked) = box.state.withLock { s in
                s.cancels[service, default: 0] += 1
                var parked: CheckedContinuation<BonjourResolution?, Never>?
                if honours, let i = s.pending.firstIndex(where: { $0.id == id }) {
                    parked = s.pending.remove(at: i).c
                }
                return (s.takeReady(), parked)
            }
            ready.forEach { $0.resume() }
            parked?.resume(returning: nil)
        }
    }

    /// Answers the oldest parked call for `service`.
    func answer(_ service: BonjourService, with resolution: BonjourResolution?) {
        let c = box.state.withLock { s -> CheckedContinuation<BonjourResolution?, Never>? in
            guard let i = s.pending.firstIndex(where: { $0.service == service }) else { return nil }
            return s.pending.remove(at: i).c
        }
        precondition(c != nil, "no resolve call is waiting for \(service.name)")
        c?.resume(returning: resolution)
    }

    /// Returns once `service` has been asked for `count` times.
    func waitForRequest(_ service: BonjourService, count: Int = 1) async {
        await wait(service, count, cancel: false)
    }

    /// Returns once a resolve of `service` has been cancelled `count` times.
    func waitForCancel(_ service: BonjourService, count: Int = 1) async {
        await wait(service, count, cancel: true)
    }

    private func wait(_ service: BonjourService, _ count: Int, cancel: Bool) async {
        await withCheckedContinuation { c in
            let ready = box.state.withLock { s in
                s.waiters.append((service, count, cancel, c))
                return s.takeReady()
            }
            ready.forEach { $0.resume() }
        }
    }
}

// MARK: - Helpers

private func service(_ host: String) -> BonjourService {
    BonjourService(name: "Mythbackend on \(host)", type: "_mythbackend._tcp.", domain: "local.")
}

private func txt(_ strings: String...) -> Data {
    var data = Data()
    for s in strings {
        let bytes = Array(s.utf8)
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
    }
    return data
}

private func master(_ host: String, port: Int = 6550) -> BonjourResolution {
    BonjourResolution(hostTarget: "\(host).local.", port: port, txt: txt("master"))
}

private func expected(_ host: String, apiPort: Int = 6544) -> DiscoveredBackend {
    DiscoveredBackend(
        id: "Mythbackend on \(host)", name: host,
        connection: BackendAddress.parse("\(host).local:\(apiPort)")!)
}

// MARK: - Mapping

@Suite("MythBackendAdvertisement")
struct MythBackendAdvertisementTests {
    @Test func serviceTypeIsMythbackend() {
        #expect(MythBackendAdvertisement.serviceType == "_mythbackend._tcp")
    }

    /// What basement advertised on 2026-11-16 (`dns-sd -L`): basement.local.:6550, TXT "\x06master".
    @Test func basementsAdvertisementMapsToItsAPIAddress() throws {
        let resolution = BonjourResolution(
            hostTarget: "basement.local.", port: 6550, txt: Data([6] + Array("master".utf8)))
        let backend = try #require(MythBackendAdvertisement.backend(service("basement"), resolution))
        #expect(backend.id == "Mythbackend on basement")
        #expect(backend.name == "basement")
        #expect(backend.connection == BackendAddress.parse("basement.local:6544"))
        #expect(backend.connection.baseURL.absoluteString == "http://basement.local:6544")
    }

    @Test func theAPIPortIsTheAdvertisedPortMinusSix() {
        let backend = MythBackendAdvertisement.backend(service("box"), master("box", port: 7550))
        #expect(backend?.connection == BackendAddress.parse("box.local:7544"))
    }

    @Test(arguments: [0, 1, 6, -1, 65_542])
    func aPortThatGivesNoValidAPIPortIsSkipped(port: Int) {
        #expect(MythBackendAdvertisement.backend(service("box"), master("box", port: port)) == nil)
    }

    @Test func theSmallestAndLargestUsablePortsMap() {
        #expect(MythBackendAdvertisement.backend(service("box"), master("box", port: 7))?.connection
            == BackendAddress.parse("box.local:1"))
        #expect(MythBackendAdvertisement.backend(service("box"), master("box", port: 65_541))?.connection
            == BackendAddress.parse("box.local:65535"))
    }

    @Test func aSlaveBackendIsSkipped() {
        let slave = BonjourResolution(hostTarget: "box.local.", port: 6550, txt: txt("slave"))
        #expect(MythBackendAdvertisement.backend(service("box"), slave) == nil)
        let shouting = BonjourResolution(hostTarget: "box.local.", port: 6550, txt: txt("SLAVE"))
        #expect(MythBackendAdvertisement.backend(service("box"), shouting) == nil)
    }

    @Test func aMissingOrUnknownTXTIsKept() {
        let none = BonjourResolution(hostTarget: "box.local.", port: 6550)
        #expect(MythBackendAdvertisement.backend(service("box"), none) == expected("box"))
        let other = BonjourResolution(hostTarget: "box.local.", port: 6550, txt: txt("something"))
        #expect(MythBackendAdvertisement.backend(service("box"), other) == expected("box"))
    }

    @Test func theHostIsUsedWithoutItsTrailingDotAndInLowerCase() {
        let resolution = BonjourResolution(hostTarget: "Den-Box.local.", port: 6550, txt: txt("master"))
        let backend = MythBackendAdvertisement.backend(service("den"), resolution)
        #expect(backend?.connection.baseURL.absoluteString == "http://den-box.local:6544")
        let noDot = BonjourResolution(hostTarget: "box.local", port: 6550, txt: txt("master"))
        #expect(MythBackendAdvertisement.backend(service("box"), noDot)?.connection
            == BackendAddress.parse("box.local:6544"))
    }

    @Test(arguments: ["", ".", "bad host.local.", "a/b.local."])
    func aHostThatIsNotAHostNameIsSkipped(host: String) {
        let resolution = BonjourResolution(hostTarget: host, port: 6550, txt: txt("master"))
        #expect(MythBackendAdvertisement.backend(service("box"), resolution) == nil)
    }

    @Test func theNameDropsTheMythbackendPrefixInAnyCase() {
        let lower = BonjourService(name: "mythbackend on Den", type: "_mythbackend._tcp.", domain: "local.")
        #expect(MythBackendAdvertisement.backend(lower, master("den"))?.name == "Den")
    }

    @Test func aNameWithoutThePrefixIsUsedWhole() {
        let other = BonjourService(name: "Basement DVR", type: "_mythbackend._tcp.", domain: "local.")
        let backend = MythBackendAdvertisement.backend(other, master("den"))
        #expect(backend?.name == "Basement DVR")
        #expect(backend?.id == "Basement DVR")
    }

    @Test func aNameThatIsOnlyThePrefixIsUsedWhole() {
        let bare = BonjourService(name: "Mythbackend on ", type: "_mythbackend._tcp.", domain: "local.")
        #expect(MythBackendAdvertisement.backend(bare, master("den"))?.name == "Mythbackend on ")
    }

    @Test func txtStringsReadsLengthPrefixedStrings() {
        #expect(MythBackendAdvertisement.txtStrings(Data()) == [])
        #expect(MythBackendAdvertisement.txtStrings(txt("master")) == ["master"])
        #expect(MythBackendAdvertisement.txtStrings(txt("a=1", "master")) == ["a=1", "master"])
        #expect(MythBackendAdvertisement.txtStrings(Data([0]) + txt("x")) == ["", "x"])
    }

    @Test func txtStringsStopsAtATruncatedString() {
        #expect(MythBackendAdvertisement.txtStrings(txt("ok") + Data([9, 65, 66])) == ["ok"])
    }
}

// MARK: - Discovery

@Suite("BonjourBackendDiscovery", .timeLimit(.minutes(1)))
private struct BonjourBackendDiscoveryTests {
    let browser = FakeBonjourBrowser()
    let resolver = FakeBonjourResolver()
    var discovery: BonjourBackendDiscovery { BonjourBackendDiscovery(browser: browser, resolver: resolver) }

    @Test func discoverBrowsesForMythbackendAtOnce() {
        let stream = discovery.discover()
        #expect(browser.types == ["_mythbackend._tcp"])
        _ = stream
    }

    @Test func eachDiscoverOpensItsOwnBrowse() {
        let d = discovery
        let a = d.discover()
        let b = d.discover()
        #expect(browser.types.count == 2)
        #expect(browser.openCount == 2)
        _ = (a, b)
    }

    @Test func theFirstBrowseReportIsPassedOnEvenWhenEmpty() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([])
        #expect(await it.next() == [])
    }

    @Test func aReportedBackendIsListedOnceResolved() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([service("basement")])
        #expect(await it.next() == [])  // present but not yet resolved
        await resolver.waitForRequest(service("basement"))
        resolver.answer(service("basement"), with: master("basement"))
        #expect(await it.next() == [expected("basement")])
    }

    @Test func backendsAreSortedByName() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([service("zebra"), service("alpha")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("zebra"))
        resolver.answer(service("zebra"), with: master("zebra"))
        #expect(await it.next() == [expected("zebra")])
        await resolver.waitForRequest(service("alpha"))
        resolver.answer(service("alpha"), with: master("alpha"))
        #expect(await it.next() == [expected("alpha"), expected("zebra")])
    }

    @Test func aBackendStillPresentIsNotResolvedAgain() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([service("a")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("a"))
        resolver.answer(service("a"), with: master("a"))
        #expect(await it.next() == [expected("a")])
        browser.push([service("a"), service("b")])
        await resolver.waitForRequest(service("b"))
        resolver.answer(service("b"), with: master("b"))
        #expect(await it.next() == [expected("a"), expected("b")])
        #expect(resolver.requestCount(service("a")) == 1)
    }

    @Test func aBackendThatGoesAwayIsRemoved() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([service("a"), service("b")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("a"))
        resolver.answer(service("a"), with: master("a"))
        #expect(await it.next() == [expected("a")])
        await resolver.waitForRequest(service("b"))
        resolver.answer(service("b"), with: master("b"))
        #expect(await it.next() == [expected("a"), expected("b")])
        browser.push([service("b")])
        #expect(await it.next() == [expected("b")])
    }

    @Test func aBackendThatGoesAwayWhileResolvingIsCancelled() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([service("a")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("a"))
        browser.push([])
        await resolver.waitForCancel(service("a"))
        // Nothing changed for the list, so the next value is the next real change.
        browser.push([service("b")])
        await resolver.waitForRequest(service("b"))
        resolver.answer(service("b"), with: master("b"))
        #expect(await it.next() == [expected("b")])
    }

    @Test func aLateAnswerForABackendThatWentAwayIsIgnored() async {
        let resolver = FakeBonjourResolver(honoursCancellation: false)
        var it = BonjourBackendDiscovery(browser: browser, resolver: resolver).discover().makeAsyncIterator()
        browser.push([service("a")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("a"))
        browser.push([])
        await resolver.waitForCancel(service("a"))
        resolver.answer(service("a"), with: master("a"))  // too late: "a" has gone
        browser.push([service("b")])
        await resolver.waitForRequest(service("b"))
        resolver.answer(service("b"), with: master("b"))
        #expect(await it.next() == [expected("b")])
    }

    @Test func aLateAnswerFromAnEarlierAppearanceIsIgnored() async {
        let resolver = FakeBonjourResolver(honoursCancellation: false)
        var it = BonjourBackendDiscovery(browser: browser, resolver: resolver).discover().makeAsyncIterator()
        browser.push([service("a")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("a"))
        browser.push([])
        await resolver.waitForCancel(service("a"))
        // The first call is still parked; answer it (with another host) after "a" is back.
        browser.push([service("a")])
        resolver.answer(service("a"), with: master("old"))  // the first appearance's call
        await resolver.waitForRequest(service("a"), count: 2)
        resolver.answer(service("a"), with: master("a"))
        #expect(await it.next() == [expected("a")])
    }

    @Test func aBackendThatCannotBeResolvedIsNotListedAndIsTriedAgainWhenItReturns() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([service("a")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("a"))
        resolver.answer(service("a"), with: nil)
        browser.push([])
        browser.push([service("a")])
        await resolver.waitForRequest(service("a"), count: 2)
        resolver.answer(service("a"), with: master("a"))
        #expect(await it.next() == [expected("a")])
    }

    @Test func aSlaveDoesNotChangeTheList() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([service("slave"), service("m")])
        #expect(await it.next() == [])
        await resolver.waitForRequest(service("slave"))
        resolver.answer(
            service("slave"), with: BonjourResolution(hostTarget: "slave.local.", port: 6550, txt: txt("slave")))
        await resolver.waitForRequest(service("m"))
        resolver.answer(service("m"), with: master("m"))
        #expect(await it.next() == [expected("m")])
    }

    @Test func theStreamEndsWhenBrowsingEnds() async {
        var it = discovery.discover().makeAsyncIterator()
        browser.push([])
        #expect(await it.next() == [])
        browser.end()
        #expect(await it.next() == nil)
    }

    @Test func droppingTheStreamStopsBrowsingAndCancelsResolves() async {
        let d = discovery
        do {
            var it = d.discover().makeAsyncIterator()
            browser.push([service("a")])
            #expect(await it.next() == [])
            await resolver.waitForRequest(service("a"))
        }
        await browser.waitForTerminations(1)
        await resolver.waitForCancel(service("a"))
        #expect(browser.openCount == 0)
    }

    @Test func cancellingTheConsumerStopsBrowsing() async {
        let stream = discovery.discover()
        let consumer = Task { for await _ in stream {} }
        browser.push([])
        consumer.cancel()
        await browser.waitForTerminations(1)
        #expect(browser.openCount == 0)
    }
}
