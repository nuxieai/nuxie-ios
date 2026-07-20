import Foundation
@testable import Nuxie

/// Mock implementation that allows controlling time in tests
public final class MockDateProvider: DateProviderProtocol {
    private var currentDate: Date
    
    /// Initialize with a fixed date (defaults to a known test date)
    public init(initialDate: Date = Date(timeIntervalSince1970: 1000000000)) {
        self.currentDate = initialDate
    }
    
    public func now() -> Date {
        return currentDate
    }
    
    /// Set the current date to a specific value
    public func setCurrentDate(_ date: Date) {
        currentDate = date
    }
    
    /// Advance the current date by a time interval
    public func advance(by interval: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(interval)
    }
    
    public func timeIntervalSince(_ date: Date) -> TimeInterval {
        return currentDate.timeIntervalSince(date)
    }
    
    
    public func date(byAddingTimeInterval interval: TimeInterval, to date: Date) -> Date {
        return date.addingTimeInterval(interval)
    }
    
    // MARK: - Test Utilities
    
    /// Reset to a known date
    public func reset() {
        currentDate = Date(timeIntervalSince1970: 1000000000)
    }
}