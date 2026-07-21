import Foundation

// MARK: - DateProvider Protocol

/// Protocol for abstracting date operations to enable testing
public protocol DateProviderProtocol: Sendable {
    /// Returns the current date/time
    func now() -> Date
    
    /// Calculates time interval since a given date
    func timeIntervalSince(_ date: Date) -> TimeInterval
    
    /// Returns start of day for a given date
    
    /// Adds time interval to a date
    func date(byAddingTimeInterval interval: TimeInterval, to date: Date) -> Date
}

// MARK: - Production Implementation

/// System implementation that uses actual system time
public final class SystemDateProvider: DateProviderProtocol, Sendable {
    
    public init() {}
    
    public func now() -> Date {
        return Date()
    }
    
    public func timeIntervalSince(_ date: Date) -> TimeInterval {
        return now().timeIntervalSince(date)
    }
    
    
    public func date(byAddingTimeInterval interval: TimeInterval, to date: Date) -> Date {
        return date.addingTimeInterval(interval)
    }
}