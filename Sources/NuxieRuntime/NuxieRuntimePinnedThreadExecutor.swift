import Foundation
import Darwin

package enum NuxieRuntimeExecutorError: Error, Equatable, Sendable {
    case closed
}

/// Owns the dedicated OS-thread lane required by portable C ABI handles.
///
/// Native file, player, view-model, result, and renderer handles are created,
/// used, and released only from this lane.
package final class NuxieRuntimePinnedThreadExecutor: @unchecked Sendable {
    private final class Worker: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [@Sendable () -> Void] = []
        private var isStopping = false

        func submit(_ job: @escaping @Sendable () -> Void) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard !isStopping else { return false }
            jobs.append(job)
            condition.signal()
            return true
        }

        var queuedJobCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return jobs.count
        }

        func run() {
            while let job = nextJob() {
                job()
            }
        }

        func requestStop() {
            condition.lock()
            isStopping = true
            condition.broadcast()
            condition.unlock()
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
        worker.requestStop()
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

    package var queuedJobCountForTesting: Int { worker.queuedJobCount }

    package func shutdown() {
        // A wedged driver must not block the releasing host thread. The worker
        // still drains accepted jobs, retaining every captured native owner.
        worker.requestStop()
    }
}
