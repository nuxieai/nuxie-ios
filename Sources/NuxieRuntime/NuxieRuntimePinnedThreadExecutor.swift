import Foundation

package enum NuxieRuntimeExecutorError: Error, Equatable, Sendable {
    case closed
}

#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
/// Swift result delivery over the runtime's CommandQueue-owned native thread.
package final class NuxieRuntimePinnedThreadExecutor: @unchecked Sendable {
    private let native = NuxieNativeExecutor()

    package init() {}

    deinit { native.close() }

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
        let value: T
        do {
            value = try await call(operation)
        } catch {
            try? await shutdown()
            throw error
        }
        try await shutdown()
        return value
    }

    package func enqueue(_ operation: @escaping @Sendable () -> Void) {
        _ = native.submit(operation, abandoned: {})
    }

    package var queuedJobCountForTesting: Int { native.pendingCount }

    /// Suspends until accepted work and native resources have drained.
    package func shutdown() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try native.shutdown { continuation.resume() }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#endif
