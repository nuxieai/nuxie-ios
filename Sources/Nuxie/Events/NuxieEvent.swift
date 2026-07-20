import Foundation

/// Enhanced event model for dual-purpose event handling
public struct NuxieEvent {
    /// Time-ordered UUID v7 for unique identification
    public let id: String
    
    /// Event name (e.g., "subscription_viewed", "paywall_shown")
    public let name: String
    
    /// User identifier (distinct ID)
    public let distinctId: String
    
    /// Enriched event properties (includes $session_id when available)
    public let properties: [String: Any]
    
    /// Event timestamp
    public let timestamp: Date
    
    /// Initialize a new Nuxie event
    /// - Parameters:
    ///   - id: Unique identifier (defaults to time-ordered UUID)
    ///   - name: Event name
    ///   - distinctId: User identifier
    ///   - properties: Event properties (may include $session_id)
    ///   - timestamp: Event timestamp (defaults to now)
    public init(
        id: String = UUID.v7().uuidString,
        name: String,
        distinctId: String,
        properties: [String: Any] = [:],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.distinctId = distinctId
        self.properties = properties
        self.timestamp = timestamp
    }
    
    
}
