import Foundation
import MythwatchPlayback
import Synchronization

/// The snapshot queue behind `FakePlayerEngine.snapshots` (SPEC 8).
///
/// A pull-based `AsyncStream(unfolding:)` source, so the fake can see when the consumer asks for
/// the next element. That is what makes `waitUntilDelivered` deterministic: nothing polls,
/// sleeps or yields; waiting and parking both use continuations, each resumed exactly once
/// (removed under the lock first). It is a separate `Sendable` class so a consumer parked
/// in `next()` can be released from the fake's `deinit`.
final class SnapshotChannel: Sendable {
    private struct Parked {
        let id: Int
        let continuation: CheckedContinuation<PlayerSnapshot?, Never>
    }
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private struct State {
        var queue: [PlayerSnapshot] = []
        var finished = false
        var emitted = 0
        var pulls = 0
        var parked: [Parked] = []
        var waiters: [Waiter] = []
        var nextID = 0
    }

    private let state = Mutex(State())

    func send(_ snapshot: PlayerSnapshot) {
        let consumer: Parked? = state.withLock { st in
            guard !st.finished else { return nil }
            st.emitted += 1
            if st.parked.isEmpty {
                st.queue.append(snapshot)
                return nil
            }
            return st.parked.removeFirst()
        }
        consumer?.continuation.resume(returning: snapshot)
    }

    func finish() {
        let consumers: [Parked] = state.withLock { st in
            st.finished = true
            defer { st.parked = [] }
            return st.parked
        }
        for c in consumers { c.continuation.resume(returning: nil) }
    }

    /// The consumer has processed everything emitted once it has asked for one more element.
    private static func isDelivered(_ st: State) -> Bool { st.emitted == 0 || st.pulls > st.emitted }

    func next() async -> PlayerSnapshot? {
        let id = state.withLock { st -> Int in
            st.nextID += 1
            return st.nextID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PlayerSnapshot?, Never>) in
                let (immediate, released): (PlayerSnapshot??, [Waiter]) = state.withLock { st in
                    st.pulls += 1
                    var released: [Waiter] = []
                    if Self.isDelivered(st) {
                        released = st.waiters
                        st.waiters = []
                    }
                    if !st.queue.isEmpty { return (.some(st.queue.removeFirst()), released) }
                    // Checked under the lock: a cancellation either sees the parked entry
                    // (and removes it) or has already set the flag we read here.
                    if st.finished || Task.isCancelled { return (.some(nil), released) }
                    st.parked.append(Parked(id: id, continuation: continuation))
                    return (nil, released)
                }
                for w in released { w.continuation.resume() }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let parked: Parked? = state.withLock { st in
                guard let i = st.parked.firstIndex(where: { $0.id == id }) else { return nil }
                return st.parked.remove(at: i)
            }
            parked?.continuation.resume(returning: nil)
        }
    }

    func waitUntilDelivered() async {
        let id = state.withLock { st -> Int in
            st.nextID += 1
            return st.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let done = state.withLock { st -> Bool in
                    if Self.isDelivered(st) || Task.isCancelled { return true }
                    st.waiters.append(Waiter(id: id, continuation: continuation))
                    return false
                }
                if done { continuation.resume() }
            }
        } onCancel: {
            let waiter: Waiter? = state.withLock { st in
                guard let i = st.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return st.waiters.remove(at: i)
            }
            waiter?.continuation.resume()
        }
    }
}

/// A scriptable `PlayerEngine` (SPEC 8). Records every call, answers each as a plain engine
/// would (unless `automaticResponses` is off), and delivers snapshots on `snapshots`.
@MainActor public final class FakePlayerEngine: PlayerEngine {
    /// One call the engine received, with its arguments.
    public enum Call: Equatable, Sendable {
        case load(url: URL, startAt: Duration?)
        case play
        case pause
        case seek(to: Duration)
        case stop
        case selectAudioTrack(MediaTrack.ID?)
        case selectSubtitleTrack(MediaTrack.ID?)
    }

    public private(set) var calls: [Call] = []
    public private(set) var snapshot = PlayerSnapshot(status: .idle, position: .zero, duration: nil, rate: 0)

    /// When true (the default) `load`, `play`, `pause`, `seek` and `stop` change `snapshot` and
    /// emit it. When false they are only logged, so a test can model a slow or misbehaving
    /// engine and drive every snapshot itself.
    public var automaticResponses = true

    public var audioTracks: [MediaTrack] = []
    public var subtitleTracks: [MediaTrack] = []
    public var selectedAudioTrack: MediaTrack.ID? {
        didSet { calls.append(.selectAudioTrack(selectedAudioTrack)) }
    }
    public var selectedSubtitleTrack: MediaTrack.ID? {
        didSet { calls.append(.selectSubtitleTrack(selectedSubtitleTrack)) }
    }

    /// One stream for the fake's whole life, created in `init`, so a read before or after the
    /// consumer starts sees the same thing and nothing emitted early is lost. The buffer is
    /// unbounded. Two consumers of it would split the elements between them.
    public let snapshots: AsyncStream<PlayerSnapshot>
    private let channel = SnapshotChannel()

    public init() {
        let channel = self.channel
        snapshots = AsyncStream(unfolding: { await channel.next() })
    }

    deinit { channel.finish() }

    // MARK: PlayerEngine

    public func load(url: URL, startAt: Duration?) {
        calls.append(.load(url: url, startAt: startAt))
        guard automaticResponses else { return }
        var s = snapshot
        s.status = .loading
        s.position = startAt ?? .zero
        s.rate = 0
        emit(s)
    }

    public func play() {
        calls.append(.play)
        guard automaticResponses else { return }
        var s = snapshot
        s.status = .playing
        s.rate = 1
        emit(s)
    }

    public func pause() {
        calls.append(.pause)
        guard automaticResponses else { return }
        var s = snapshot
        s.status = .paused
        s.rate = 0
        emit(s)
    }

    public func seek(to position: Duration) {
        calls.append(.seek(to: position))
        guard automaticResponses else { return }
        var s = snapshot
        s.position = position
        emit(s)
    }

    public func stop() {
        calls.append(.stop)
        guard automaticResponses else { return }
        emit(PlayerSnapshot(status: .idle, position: .zero, duration: snapshot.duration, rate: 0))
    }

    // MARK: Driving the engine from a test

    /// Makes `snapshot` this value and delivers it, even if equal to the current one (a real
    /// engine repeats positions). After `finish()` it still sets `snapshot` but delivers nothing.
    public func emit(_ snapshot: PlayerSnapshot) {
        self.snapshot = snapshot
        channel.send(snapshot)
    }

    /// While playing, moves the position forward by `duration` and emits. Otherwise does nothing
    /// and emits nothing.
    public func advancePlayback(by duration: Duration) {
        guard snapshot.status == .playing else { return }
        setPosition(snapshot.position + duration)
    }

    public func setStatus(_ status: PlayerStatus) { update { $0.status = status } }
    public func setPosition(_ position: Duration) { update { $0.position = position } }
    public func setDuration(_ duration: Duration?) { update { $0.duration = duration } }

    /// Status `.ended`, with the position at the duration when it is known.
    public func emitEnded() {
        update {
            $0.status = .ended
            $0.rate = 0
            if let d = $0.duration { $0.position = d }
        }
    }

    public func emitFailed(_ message: String) {
        update {
            $0.status = .failed(message)
            $0.rate = 0
        }
    }

    private func update(_ change: (inout PlayerSnapshot) -> Void) {
        var s = snapshot
        change(&s)
        emit(s)
    }

    // MARK: Stream control

    /// Ends the stream after what is buffered has been read.
    public func finish() { channel.finish() }

    /// Returns when the consumer of `snapshots` has finished handling everything emitted so far:
    /// it has taken the last snapshot and its loop has come back asking for the next. Returns at
    /// once if nothing was ever emitted. Meant for one consumer that has started reading; with no
    /// consumer and something emitted it waits until cancelled. Signalled, not polled.
    public func waitUntilDelivered() async { await channel.waitUntilDelivered() }
}
