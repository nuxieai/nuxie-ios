import Foundation
import Darwin

package enum NuxieRuntimeExecutorError: Error, Equatable, Sendable {
    case closed
}

/// Owns the temporary serialized lane used by the legacy adapter.
///
/// The temporary legacy adapter predates the portable C ABI's strict
/// creator-thread contract. Preserve its proven dispatch-backed behavior until
/// UNIV-1831 removes the compatibility target.
package final class NuxieRuntimeSerialExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nuxie.runtime.apple.legacy")

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

/// Owns the dedicated OS-thread lane required by portable C ABI handles.
///
/// Native file, player, view-model, result, and renderer handles are created,
/// used, and released only from this lane.
package final class NuxieRuntimePinnedThreadExecutor: @unchecked Sendable {
    private final class Worker: @unchecked Sendable {
        private let condition = NSCondition()
        private let stopped = DispatchSemaphore(value: 0)
        private var jobs: [@Sendable () -> Void] = []
        private var isStopping = false
        private var workerThread: pthread_t?

        func submit(_ job: @escaping @Sendable () -> Void) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard !isStopping else { return false }
            jobs.append(job)
            condition.signal()
            return true
        }

        func run() {
            condition.lock()
            workerThread = pthread_self()
            condition.unlock()
            while let job = nextJob() {
                job()
            }
            stopped.signal()
        }

        func stopAndWait() {
            condition.lock()
            let shouldSignal = !isStopping
            let isWorkerThread = workerThread.map { pthread_equal($0, pthread_self()) != 0 }
                ?? false
            isStopping = true
            condition.broadcast()
            condition.unlock()
            if shouldSignal, !isWorkerThread {
                stopped.wait()
            }
        }

        private func nextJob() -> (@Sendable () -> Void)? {
            condition.lock()
            defer { condition.unlock() }
            while jobs.isEmpty, !isStopping {
                condition.wait()
            }
            if !jobs.isEmpty {
                return jobs.removeFirst()
            }
            return nil
        }
    }

    private let worker: Worker
    private let thread: Thread

    package init() {
        let worker = Worker()
        self.worker = worker
        let thread = Thread { worker.run() }
        thread.name = "com.nuxie.runtime.apple.native"
        thread.qualityOfService = .default
        self.thread = thread
        thread.start()
    }

    deinit {
        worker.stopAndWait()
    }

    package func call<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            guard worker.submit({
                continuation.resume(with: Result(catching: operation))
            }) else {
                continuation.resume(throwing: NuxieRuntimeExecutorError.closed)
                return
            }
        }
    }

    /// Runs the final lane-confined operation and then stops the lane even when
    /// that operation reports a consuming native destruction failure.
    package func callThenShutdown<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        defer { shutdown() }
        return try await call(operation)
    }

    package func enqueue(_ operation: @escaping @Sendable () -> Void) {
        _ = worker.submit(operation)
    }

    package func shutdown() {
        worker.stopAndWait()
    }
}
