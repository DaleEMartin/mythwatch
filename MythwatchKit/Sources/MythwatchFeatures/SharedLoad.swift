import Foundation

/// One load at a time, shared by every caller that asks while it runs.
///
/// - A call made while a load is running joins it and returns when it finishes; nothing is
///   fetched twice.
/// - The load belongs to this object, not to its first caller. Cancelling a caller only stops that
///   caller from waiting for the result; the load is cancelled when *every* caller has been
///   cancelled. A cancelled load publishes nothing (not even an error: `URLSessionTransport`
///   reports cancellation as `.unreachable`) and `abandon` runs at once, so the model can put its
///   state back instead of staying in `.loading`.
/// - A load that has been cancelled or replaced never calls `publish`.
@MainActor
final class SharedLoad<Output: Sendable> {
    @MainActor private final class Running {
        let id: Int
        var task: Task<Void, Never>?
        var waiters: Set<Int> = []
        let abandon: @MainActor () -> Void
        init(id: Int, abandon: @escaping @MainActor () -> Void) {
            self.id = id
            self.abandon = abandon
        }
    }

    private var running: Running?
    private var counter = 0

    var isRunning: Bool { running != nil }

    func run(
        fetch: @escaping @MainActor () async -> Output,
        publish: @escaping @MainActor (Output) -> Void,
        abandon: @escaping @MainActor () -> Void
    ) async {
        counter += 1
        let waiter = counter
        let current: Running
        if let running {
            current = running
        } else {
            current = Running(id: counter, abandon: abandon)
            running = current
            let id = current.id
            current.task = Task { [weak self] in
                let output = await fetch()
                guard let self, self.running?.id == id, !Task.isCancelled else { return }
                self.running = nil
                publish(output)
            }
        }
        current.waiters.insert(waiter)
        guard let task = current.task else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiterCancelled(waiter, of: current) }
        }
    }

    private func waiterCancelled(_ waiter: Int, of current: Running) {
        current.waiters.remove(waiter)
        guard current.waiters.isEmpty, running?.id == current.id else { return }
        running = nil
        current.task?.cancel()
        current.abandon()
    }
}
