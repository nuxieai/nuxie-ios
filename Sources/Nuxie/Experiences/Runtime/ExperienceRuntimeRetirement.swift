import Foundation

enum ExperienceRuntimeRetirementError: LocalizedError, Equatable, Sendable {
    case timedOut

    var errorDescription: String? { "Native runtime retirement did not finish within 5 seconds." }
}

/// The authored waits of one Experience: exit and move watchdogs, and a sheet
/// the person is holding. Each has its own limit, so a retirement wait of the
/// same Experience counts only the time when none of them runs.
final class ExperienceAuthoredTime: @unchecked Sendable {
    private static let sliceNanoseconds: UInt64 = 50_000_000
    private let lock = NSLock()
    private var running = 0
    private var started: UInt64 = 0

    /// Runs `body` on the caller's actor as one authored span.
    static func during<Value>(_ time: ExperienceAuthoredTime?, isolation: isolated (any Actor)? = #isolation,
                              _ body: () async throws -> Value) async rethrows -> Value {
        time?.begin()
        defer { time?.end() }
        return try await body()
    }

    private func begin() {
        lock.lock()
        running += 1
        started &+= 1
        lock.unlock()
    }

    private func end() {
        lock.lock()
        running -= 1
        lock.unlock()
    }

    private var mark: (running: Int, started: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (running, started)
    }

    /// Sleeps until `nanoseconds` have passed outside every authored wait. A
    /// slice that any authored wait touched does not count.
    func sleepNative(nanoseconds: UInt64) async throws {
        var remaining = nanoseconds
        while remaining > 0 {
            let slice = min(remaining, Self.sliceNanoseconds)
            let before = mark
            try await Task.sleep(nanoseconds: slice)
            let after = mark
            if before.running == 0, after.running == 0, before.started == after.started { remaining -= slice }
        }
    }
}

/// Bounds the host's wait, never native ownership. The unstructured operation
/// keeps its owner and artifact leases until it actually returns.
enum ExperienceRuntimeRetirement {
    static let timeoutNanoseconds: UInt64 = 5_000_000_000

    /// `authoredTime` pauses the limit during the Experience's authored waits;
    /// nil bounds native work alone.
    static func wait<Value: Sendable>(
        timeoutNanoseconds: UInt64 = ExperienceRuntimeRetirement.timeoutNanoseconds,
        authoredTime: ExperienceAuthoredTime?,
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
                    if let authoredTime { try await authoredTime.sleepNative(nanoseconds: timeoutNanoseconds) }
                    else { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
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
