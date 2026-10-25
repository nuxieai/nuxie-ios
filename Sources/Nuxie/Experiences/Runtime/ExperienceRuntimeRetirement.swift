import Foundation

enum ExperienceRuntimeRetirementError: LocalizedError, Equatable, Sendable {
    case timedOut

    var errorDescription: String? { "Native runtime retirement did not finish within 5 seconds." }
}

/// Bounds the host's wait, never native ownership. The unstructured operation
/// keeps its owner and artifact leases until it actually returns.
enum ExperienceRuntimeRetirement {
    static let timeoutNanoseconds: UInt64 = 5_000_000_000

    static func wait<Value: Sendable>(
        timeoutNanoseconds: UInt64 = ExperienceRuntimeRetirement.timeoutNanoseconds,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let race = Race(continuation)
            Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    race.finish(.failure(ExperienceRuntimeRetirementError.timedOut))
                } catch { /* The operation finished first. */ }
            }
            race.register(timer)
        }
    }

    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var timer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

        func register(_ timer: Task<Void, Never>) {
            lock.lock()
            let finished = continuation == nil
            if !finished { self.timer = timer }
            lock.unlock()
            if finished { timer.cancel() }
        }

        func finish(_ result: Result<Value, Error>) {
            lock.lock()
            let continuation = self.continuation
            let timer = self.timer
            self.continuation = nil
            self.timer = nil
            lock.unlock()
            timer?.cancel()
            continuation?.resume(with: result)
        }
    }
}
