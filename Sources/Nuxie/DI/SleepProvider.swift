import Foundation

// MARK: - SleepProvider Protocol

/// Protocol for abstracting sleep operations to enable testing
public protocol SleepProviderProtocol: Sendable {
    /// Sleep for the specified duration
    /// - Parameter duration: Duration to sleep in seconds
    /// - Throws: If the sleep operation is cancelled or fails
    func sleep(for duration: TimeInterval) async throws
}

// MARK: - Production Implementation

/// System implementation that uses Task.sleep
public final class SystemSleepProvider: SleepProviderProtocol, Sendable {
    
    public init() {}
    
    public func sleep(for duration: TimeInterval) async throws {
        guard duration > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}