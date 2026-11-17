import Foundation
import Network
import Synchronization
import dnssd

// The production Bonjour ports (SPEC 6.3 "Bonjour discovery"). Thin wrappers over the system
// APIs with no logic of their own; package tests never use them (no real I/O). The app reaches
// them through `BonjourBackendDiscovery.onLocalNetwork()`.

extension BonjourBackendDiscovery {
    /// Discovery on the local network, for the composition root.
    public static func onLocalNetwork() -> BonjourBackendDiscovery {
        BonjourBackendDiscovery(browser: NetworkBonjourBrowser(), resolver: DNSServiceBonjourResolver())
    }
}

/// Browses with `NWBrowser`. Each value is the full set of instances; an instance seen on
/// several interfaces is reported once. The stream ends if the browser fails; it stays open
/// while it waits (for example until the user allows local network access).
public struct NetworkBonjourBrowser: BonjourBrowsing {
    public init() {}

    public func browse(type: String) -> AsyncStream<Set<BonjourService>> {
        let (stream, continuation) = AsyncStream<Set<BonjourService>>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: NWParameters())
        browser.browseResultsChangedHandler = { results, _ in
            continuation.yield(
                Set(
                    results.compactMap { result in
                        guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                        return BonjourService(name: name, type: type, domain: domain)
                    }))
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: continuation.finish()
            default: break
            }
        }
        continuation.onTermination = { _ in browser.cancel() }
        browser.start(queue: DispatchQueue(label: "Mythwatch.Bonjour.browse"))
        return stream
    }
}

/// Resolves with `DNSServiceResolve`: the first answer wins. Gives nil on an error, after
/// `timeout`, or when the calling task is cancelled.
public struct DNSServiceBonjourResolver: BonjourResolving {
    public let timeout: Duration

    public init(timeout: Duration = .seconds(5)) { self.timeout = timeout }

    public func resolve(_ service: BonjourService) async -> BonjourResolution? {
        let operation = ResolveOperation(service: service, timeout: timeout)
        return await withTaskCancellationHandler {
            await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }
}

/// One resolve. Everything that touches the `DNSServiceRef` runs on `queue` (serial): start,
/// the callback (`DNSServiceSetDispatchQueue`), the timeout and the finish that deallocates it.
/// The callback's context is this object unretained; that is safe because `run()` keeps it
/// alive until `finish`, and after `DNSServiceRefDeallocate` on the same queue no callback runs.
private final class ResolveOperation: Sendable {
    private struct State {
        var continuation: CheckedContinuation<BonjourResolution?, Never>?
        var ref: DNSServiceRef?
        var finished = false
    }

    private let service: BonjourService
    private let timeout: Duration
    private let queue = DispatchQueue(label: "Mythwatch.Bonjour.resolve")
    private let state = Mutex(State())

    init(service: BonjourService, timeout: Duration) {
        self.service = service
        self.timeout = timeout
    }

    func run() async -> BonjourResolution? {
        await withCheckedContinuation { continuation in
            queue.async { self.start(continuation) }
        }
    }

    func cancel() {
        queue.async { self.finish(nil) }
    }

    private func start(_ continuation: CheckedContinuation<BonjourResolution?, Never>) {
        let cancelledAlready = state.withLock { s in
            if s.finished { return true }
            s.continuation = continuation
            return false
        }
        if cancelledAlready {
            continuation.resume(returning: nil)
            return
        }
        // The ref is made and stored inside the lock so it never leaves the state's region.
        // Callbacks cannot run before this block returns: they are delivered on this queue.
        let started = state.withLock { s -> Bool in
            var ref: DNSServiceRef?
            let error = DNSServiceResolve(
                &ref, 0, 0, service.name, service.type, service.domain, resolveReply,
                Unmanaged.passUnretained(self).toOpaque())
            guard error == kDNSServiceErr_NoError, let ref else { return false }
            DNSServiceSetDispatchQueue(ref, queue)
            s.ref = ref
            return true
        }
        guard started else {
            finish(nil)
            return
        }
        let (seconds, attoseconds) = timeout.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { self.finish(nil) }
    }

    /// Called on `queue` only.
    fileprivate func finish(_ resolution: BonjourResolution?) {
        let (continuation, ref) = state.withLock { s -> (CheckedContinuation<BonjourResolution?, Never>?, DNSServiceRef?) in
            s.finished = true
            defer {
                s.continuation = nil
                s.ref = nil
            }
            return (s.continuation, s.ref)
        }
        if let ref { DNSServiceRefDeallocate(ref) }
        continuation?.resume(returning: resolution)
    }
}

private let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, hostTarget, port, txtLength, txt, context in
    guard let context else { return }
    let operation = Unmanaged<ResolveOperation>.fromOpaque(context).takeUnretainedValue()
    guard error == kDNSServiceErr_NoError, let hostTarget else {
        operation.finish(nil)
        return
    }
    let record = txt.map { Data(bytes: $0, count: Int(txtLength)) } ?? Data()
    operation.finish(
        BonjourResolution(hostTarget: String(cString: hostTarget), port: Int(UInt16(bigEndian: port)), txt: record))
}
