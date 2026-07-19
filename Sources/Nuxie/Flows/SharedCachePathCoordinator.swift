import Foundation

/// Serializes cache transactions that target the same canonical path across
/// otherwise-independent store actors in this process.
///
/// The operation may suspend (for example while downloading). Explicit keyed
/// ownership, rather than actor isolation alone, keeps a second call queued
/// while the coordinator actor remains reentrant.
actor SharedCachePathCoordinator {
    static let shared = SharedCachePathCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var isOwned = false
        var waiters: [Waiter] = []
    }

    private var states: [String: State] = [:]

    func withExclusiveAccess<Value: Sendable>(
        to url: URL,
        lockScope: CacheFilesystemLockScope,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let key = url.standardizedFileURL.path
        try await acquire(key)
        do {
            try Task.checkCancellation()
            let value = try await CacheFilesystemLock.withTargetTransaction(
                scope: lockScope,
                targetURL: url,
                operation: operation
            )
            release(key)
            return value
        } catch {
            release(key)
            throw error
        }
    }

    private func acquire(_ key: String) async throws {
        try Task.checkCancellation()
        if states[key]?.isOwned != true {
            states[key] = State(isOwned: true)
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                states[key, default: State(isOwned: true)].waiters.append(
                    Waiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for key: String) {
        guard var state = states[key],
              let index = state.waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = state.waiters.remove(at: index)
        states[key] = state
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ key: String) {
        guard var state = states[key] else { return }
        guard !state.waiters.isEmpty else {
            states[key] = nil
            return
        }
        let next = state.waiters.removeFirst()
        states[key] = state
        next.continuation.resume()
    }
}
