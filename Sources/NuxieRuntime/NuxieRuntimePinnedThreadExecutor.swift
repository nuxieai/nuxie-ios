import Foundation

package enum NuxieRuntimeExecutorError: Error, Equatable, Sendable {
    case closed
}

/// Swift result delivery over the runtime's CommandQueue-owned native thread.
package final class NuxieRuntimePinnedThreadExecutor: @unchecked Sendable {
    private let native = NuxieNativeExecutor()

    package init() {}

    deinit { native.shutdown() }

    package func call<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            guard native.submit({
                continuation.resume(with: Result(catching: operation))
            }, abandoned: {
                continuation.resume(throwing: NuxieRuntimeExecutorError.closed)
            }) else {
                continuation.resume(throwing: NuxieRuntimeExecutorError.closed)
                return
            }
        }
    }

    package func callThenShutdown<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        defer { shutdown() }
        return try await call(operation)
    }

    package func enqueue(_ operation: @escaping @Sendable () -> Void) {
        _ = native.submit(operation, abandoned: {})
    }

    package var queuedJobCountForTesting: Int { native.pendingCount }

    package func shutdown() { native.shutdown() }
}
