import Foundation

/// FIFO chaining for deferred async work: each enqueued operation runs after
/// the previous one completes. Used by the runner for trigger-reset writes
/// that must not interleave. Extracted from JourneyRunner (Phase 6).
// @unchecked Sendable: `tail`/`tailGeneration` are only accessed under `lock`.
final class SerialTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var tailGeneration: UInt64 = 0

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tailGeneration += 1
        let generation = tailGeneration
        let next = Task { [weak self] in
            _ = await previous?.value
            await operation()
            self?.finish(generation: generation)
        }
        tail = next
        lock.unlock()
    }

    private func finish(generation: UInt64) {
        lock.lock()
        if tailGeneration == generation {
            tail = nil
        }
        lock.unlock()
    }
}
