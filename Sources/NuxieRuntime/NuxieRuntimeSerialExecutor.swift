import Foundation

/// Owns the single serialized lane used for runtime handles and FFI calls.
///
/// Keeping this executor in the Swift runtime module makes the threading
/// contract native to Apple clients instead of part of a cross-platform Rust
/// adapter. Handles may be created, used, and released only from this lane.
package final class NuxieRuntimeSerialExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nuxie.runtime.apple")

    package init() {}

    package func call<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    package func enqueue(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}
