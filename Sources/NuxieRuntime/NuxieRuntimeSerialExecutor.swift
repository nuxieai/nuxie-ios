import Foundation
import Darwin

package enum NuxieRuntimeExecutorError: Error, Equatable, Sendable {
    case closed
}

/// Owns the single serialized lane used for runtime handles and FFI calls.
///
/// Keeping this executor in the Swift runtime module makes the threading
/// contract native to Apple clients instead of part of a cross-platform Rust
/// adapter. Handles may be created, used, and released only from this lane.
package final class NuxieRuntimeSerialExecutor: @unchecked Sendable {
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
        thread.name = "com.nuxie.runtime.apple"
        thread.qualityOfService = .userInitiated
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
