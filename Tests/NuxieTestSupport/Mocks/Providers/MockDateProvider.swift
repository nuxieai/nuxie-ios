import Foundation
@testable import Nuxie

/// Mock implementation that allows controlling time in tests
// @unchecked Sendable: all access to `currentDate` is serialized through `lock`.
public final class MockDateProvider: DateProviderProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date
    
    /// Initialize with a fixed date (defaults to a known test date)
    public init(initialDate: Date = Date(timeIntervalSince1970: 1000000000)) {
        self.currentDate = initialDate
    }
    
    public func now() -> Date {
        return lock.withLock { currentDate }
    }
    
    /// Set the current date to a specific value
    public func setCurrentDate(_ date: Date) {
        lock.withLock { currentDate = date }
    }
    
    /// Advance the current date by a time interval
    public func advance(by interval: TimeInterval) {
        lock.withLock { currentDate = currentDate.addingTimeInterval(interval) }
    }
    
    public func timeIntervalSince(_ date: Date) -> TimeInterval {
        return lock.withLock { currentDate.timeIntervalSince(date) }
    }
    
    
    public func date(byAddingTimeInterval interval: TimeInterval, to date: Date) -> Date {
        return date.addingTimeInterval(interval)
    }
    
    // MARK: - Test Utilities
    
    /// Reset to a known date
    public func reset() {
        lock.withLock { currentDate = Date(timeIntervalSince1970: 1000000000) }
    }
}
