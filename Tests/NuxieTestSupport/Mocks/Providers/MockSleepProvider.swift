import Foundation
@testable import Nuxie

/// Mock implementation of sleep provider for testing async operations
// @unchecked Sendable: all mutable state is serialized through `lock`.
public final class MockSleepProvider: SleepProviderProtocol, @unchecked Sendable {
    
    // MARK: - Types
    
    /// Represents a pending sleep operation
    public struct PendingSleep {
        public let duration: TimeInterval
        public let continuation: CheckedContinuation<Void, Error>
        public let timestamp: Date
        
        init(duration: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
            self.duration = duration
            self.continuation = continuation
            self.timestamp = Date()
        }
    }
    
    // MARK: - Properties
    
    private var pendingSleeps: [UUID: PendingSleep] = [:]
    private let lock = NSLock()
    
    private var _sleepCalls: [(duration: TimeInterval, timestamp: Date)] = []
    private var _shouldCompleteImmediately = false
    private var _errorToThrow: Error?

    /// All sleep calls that have been made (for testing assertions)
    public var sleepCalls: [(duration: TimeInterval, timestamp: Date)] {
        lock.withLock { _sleepCalls }
    }

    /// Whether to immediately complete sleep operations (default: false)
    public var shouldCompleteImmediately: Bool {
        get { lock.withLock { _shouldCompleteImmediately } }
        set { lock.withLock { _shouldCompleteImmediately = newValue } }
    }

    /// Error to throw on sleep operations (for testing error scenarios)
    public var errorToThrow: Error? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - SleepProviderProtocol
    
    public func sleep(for duration: TimeInterval) async throws {
        let (error, completeImmediately): (Error?, Bool) = lock.withLock {
            _sleepCalls.append((duration: duration, timestamp: Date()))
            return (_errorToThrow, _shouldCompleteImmediately)
        }

        // If configured to throw an error, do so
        if let error = error {
            throw error
        }

        // If configured to complete immediately, return
        if completeImmediately {
            return
        }
        
        // Otherwise, wait for manual completion (and handle cancellation)
        let id = UUID.v7()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let pendingSleep = PendingSleep(duration: duration, continuation: continuation)
                
                lock.withLock {
                    pendingSleeps[id] = pendingSleep
                }
            }
        } onCancel: {
            lock.withLock {
                if let pending = pendingSleeps.removeValue(forKey: id) {
                    pending.continuation.resume(throwing: CancellationError())
                }
            }
        }
    }
    
    // MARK: - Test Control Methods
    
    /// Complete all pending sleep operations
    public func completeAllSleeps() {
        lock.withLock {
            let sleepers = pendingSleeps
            pendingSleeps.removeAll()
            for sleep in sleepers.values {
                sleep.continuation.resume()
            }
        }
    }
    
    /// Complete sleep operations with the specified duration
    public func completeSleeps(withDuration duration: TimeInterval) {
        lock.withLock {
            let sleepsToComplete = pendingSleeps.filter { $0.value.duration == duration }
            for (id, sleep) in sleepsToComplete {
                sleep.continuation.resume()
                pendingSleeps.removeValue(forKey: id)
            }
        }
    }
    
    /// Cancel all pending sleep operations with CancellationError
    public func cancelAllSleeps() {
        lock.withLock {
            for sleep in pendingSleeps.values {
                sleep.continuation.resume(throwing: CancellationError())
            }
            pendingSleeps.removeAll()
        }
    }
    
    /// Get the number of currently pending sleep operations
    public var pendingSleepCount: Int {
        lock.withLock {
            return pendingSleeps.count
        }
    }
    
    /// Get all pending sleep durations
    public var pendingSleepDurations: [TimeInterval] {
        lock.withLock {
            return pendingSleeps.values.map { $0.duration }
        }
    }
    
    /// Reset all state for clean test setup
    public func reset() {
        lock.withLock {
            // Cancel any pending sleeps
            let sleepers = pendingSleeps
            pendingSleeps.removeAll()
            for sleep in sleepers.values {
                sleep.continuation.resume(throwing: CancellationError())
            }
            _sleepCalls.removeAll()
            _shouldCompleteImmediately = false
            _errorToThrow = nil
        }
    }
}

// MARK: - Extensions

extension NSLock {
    /// Execute a closure while holding the lock
    func withLock<T>(_ closure: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try closure()
    }
}
