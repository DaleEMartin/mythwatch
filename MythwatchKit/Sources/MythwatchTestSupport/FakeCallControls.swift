import Foundation
import MythwatchDomain
import Synchronization

/// One call a fake service received: an `Equatable` enum with the call's arguments, so a test
/// can write `#expect(fake.calls == [.setWatched(true, id)])`.
public protocol FakeCall: Equatable, Sendable {
    /// The method alone, without arguments; used to aim error injection and suspension.
    associatedtype Method: Hashable & Sendable
    var method: Method { get }
}

/// A call that is parked: it has been logged and is waiting for the test to release it.
public struct ParkedCall<Call: FakeCall>: Sendable, Equatable {
    public let call: Call
    let id: Int
}

/// The call log, error injection and suspension points shared by the async fakes (SPEC 8).
///
/// A final class guarding its state with `Mutex`, not an actor, so tests configure and inspect
/// a fake synchronously and only `await` the service calls themselves and `waitForParked`.
/// Nothing here sleeps, yields or polls: parking and waiting both use continuations, and
/// every continuation is resumed exactly once (it is removed under the lock before it is resumed).
public final class FakeCallRecorder<Call: FakeCall>: Sendable {
    typealias Method = Call.Method

    private struct Injection {
        let method: Method?
        let error: BackendError
    }

    private struct Parked {
        let id: Int
        let call: Call
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let id: Int
        let method: Method?
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var calls: [Call] = []
        var once: [Injection] = []
        var always: [Injection] = []
        var suspendedOnce: [Method?] = []
        var suspended: [Method?] = []
        var parked: [Parked] = []
        var waiters: [Waiter] = []
        var cancelledBeforeParking: Set<Int> = []
        var cancelledBeforeWaiting: Set<Int> = []
        var nextID = 0
    }

    private enum Decision {
        case proceed
        case fail(BackendError)
        case park(Int)
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: Inspection

    public var calls: [Call] { state.withLock { $0.calls } }

    public var parked: [ParkedCall<Call>] {
        state.withLock { $0.parked.map { ParkedCall(call: $0.call, id: $0.id) } }
    }

    // MARK: Configuration

    func failNext(_ error: BackendError, on method: Method?) {
        state.withLock { $0.once.append(Injection(method: method, error: error)) }
    }

    func failAlways(_ error: BackendError, on method: Method?) {
        state.withLock { $0.always.append(Injection(method: method, error: error)) }
    }

    func clearFailures() {
        state.withLock {
            $0.once.removeAll()
            $0.always.removeAll()
        }
    }

    func suspend(_ method: Method?) { state.withLock { $0.suspended.append(method) } }
    func suspendNext(_ method: Method?) { state.withLock { $0.suspendedOnce.append(method) } }

    func stopSuspending() {
        state.withLock {
            $0.suspended.removeAll()
            $0.suspendedOnce.removeAll()
        }
    }

    // MARK: Used by the fakes

    /// Logs without any failure or suspension (for synchronous fakes).
    func log(_ call: Call) { state.withLock { $0.calls.append(call) } }

    /// Every async fake method starts here. Order: log the call; throw an injected error if one
    /// applies (a one-shot first, then a persistent one); park if suspended; then return, and
    /// the fake applies the call's effect. So a parked call has been logged but has changed nothing.
    func begin(_ call: Call) async throws {
        func matches(_ method: Method?) -> Bool { method == nil || method == call.method }
        let decision = state.withLock { s -> Decision in
            s.calls.append(call)
            if let i = s.once.firstIndex(where: { matches($0.method) }) {
                return .fail(s.once.remove(at: i).error)
            }
            if let rule = s.always.first(where: { matches($0.method) }) { return .fail(rule.error) }
            let shouldPark: Bool
            if let i = s.suspendedOnce.firstIndex(where: matches) {
                s.suspendedOnce.remove(at: i)
                shouldPark = true
            } else {
                shouldPark = s.suspended.contains(where: matches)
            }
            guard shouldPark else { return .proceed }
            s.nextID += 1
            return .park(s.nextID)
        }
        switch decision {
        case .proceed: return
        case .fail(let error): throw error
        case .park(let id): try await park(id: id, call: call)
        }
    }

    private func park(id: Int, call: Call) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { s -> (cancelled: Bool, wake: [Waiter]) in
                    if s.cancelledBeforeParking.remove(id) != nil { return (true, []) }
                    s.parked.append(Parked(id: id, call: call, continuation: continuation))
                    return (false, Self.takeSatisfiedWaiters(&s))
                }
                if outcome.cancelled { continuation.resume(throwing: CancellationError()) }
                for waiter in outcome.wake { waiter.continuation.resume() }
            }
        } onCancel: {
            let found = state.withLock { s -> Parked? in
                if let i = s.parked.firstIndex(where: { $0.id == id }) { return s.parked.remove(at: i) }
                s.cancelledBeforeParking.insert(id)  // cancelled before it parked
                return nil
            }
            found?.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: Waiting for parked calls

    private static func parkedCount(_ s: State, of method: Method?) -> Int {
        s.parked.filter { method == nil || $0.call.method == method }.count
    }

    private static func takeSatisfiedWaiters(_ s: inout State) -> [Waiter] {
        var woken: [Waiter] = []
        var remaining: [Waiter] = []
        for waiter in s.waiters {
            if parkedCount(s, of: waiter.method) >= waiter.count {
                woken.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }
        s.waiters = remaining
        return woken
    }

    func waitForParked(_ count: Int, of method: Method?) async throws {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { s -> Bool? in
                    if s.cancelledBeforeWaiting.remove(id) != nil { return true }
                    if Self.parkedCount(s, of: method) >= count { return false }
                    s.waiters.append(
                        Waiter(id: id, method: method, count: count, continuation: continuation))
                    return nil  // registered; resumed later
                }
                switch cancelled {
                case true?: continuation.resume(throwing: CancellationError())
                case false?: continuation.resume()
                case nil: break
                }
            }
        } onCancel: {
            let found = state.withLock { s -> Waiter? in
                if let i = s.waiters.firstIndex(where: { $0.id == id }) { return s.waiters.remove(at: i) }
                s.cancelledBeforeWaiting.insert(id)
                return nil
            }
            found?.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: Releasing

    @discardableResult
    func release(_ parked: ParkedCall<Call>, throwing error: BackendError?) -> Bool {
        let found = state.withLock { s -> Parked? in
            guard let i = s.parked.firstIndex(where: { $0.id == parked.id }) else { return nil }
            return s.parked.remove(at: i)
        }
        guard let found else { return false }
        if let error { found.continuation.resume(throwing: error) } else { found.continuation.resume() }
        return true
    }

    @discardableResult
    func releaseNext(of method: Method?, throwing error: BackendError?) -> Bool {
        let found = state.withLock { s -> Parked? in
            guard let i = s.parked.firstIndex(where: { method == nil || $0.call.method == method })
            else { return nil }
            return s.parked.remove(at: i)
        }
        guard let found else { return false }
        if let error { found.continuation.resume(throwing: error) } else { found.continuation.resume() }
        return true
    }

    func releaseAll(throwing error: BackendError?) {
        let all = state.withLock { s -> [Parked] in
            defer { s.parked.removeAll() }
            return s.parked
        }
        for p in all {
            if let error { p.continuation.resume(throwing: error) } else { p.continuation.resume() }
        }
    }
}

/// The test-facing controls, available on every async fake service.
public protocol FakeCallControls: Sendable {
    associatedtype Call: FakeCall
    var recorder: FakeCallRecorder<Call> { get }
}

extension FakeCallControls {
    /// Every call received, oldest first, including calls that failed or are parked.
    public var calls: [Call] { recorder.calls }

    /// Make the next call (of `method`, or of any method) throw `error`. Queued: two calls
    /// of `failNext` make two calls fail. The call is still logged and has no effect.
    public func failNext(_ error: BackendError, on method: Call.Method? = nil) {
        recorder.failNext(error, on: method)
    }

    /// Make every call (of `method`, or of any method) throw `error` until `clearFailures()`.
    public func failAlways(_ error: BackendError, on method: Call.Method? = nil) {
        recorder.failAlways(error, on: method)
    }

    /// Forget every injected error, one-shot and persistent.
    public func clearFailures() { recorder.clearFailures() }

    /// Park every later call of `method` (of any method when nil) until the test releases it,
    /// until `stopSuspending()`.
    public func suspend(_ method: Call.Method? = nil) { recorder.suspend(method) }

    /// Park only the next call of `method` (any method when nil).
    public func suspendNext(_ method: Call.Method? = nil) { recorder.suspendNext(method) }

    /// Stop parking new calls. Calls already parked stay parked until released.
    public func stopSuspending() { recorder.stopSuspending() }

    /// The calls parked now, oldest first.
    public var parked: [ParkedCall<Call>] { recorder.parked }

    /// Returns once at least `count` calls of `method` (of any method when nil) are parked;
    /// at once if they already are. Signalled by the fake, never polled. Throws
    /// `CancellationError` if the waiting task is cancelled.
    public func waitForParked(_ count: Int = 1, of method: Call.Method? = nil) async throws {
        try await recorder.waitForParked(count, of: method)
    }

    /// Resume one parked call, successfully or by throwing `error`. False when it is no longer
    /// parked (already released or cancelled).
    @discardableResult
    public func release(_ parked: ParkedCall<Call>, throwing error: BackendError? = nil) -> Bool {
        recorder.release(parked, throwing: error)
    }

    /// Resume the oldest parked call (of `method`, or of any method).
    @discardableResult
    public func releaseNext(of method: Call.Method? = nil, throwing error: BackendError? = nil) -> Bool {
        recorder.releaseNext(of: method, throwing: error)
    }

    /// Resume every parked call.
    public func releaseAll(throwing error: BackendError? = nil) { recorder.releaseAll(throwing: error) }
}
