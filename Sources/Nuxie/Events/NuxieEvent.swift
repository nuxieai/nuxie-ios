import Foundation

/// Enhanced event model for dual-purpose event handling
// @unchecked Sendable: all stored properties are immutable (`let`); the
// [String: Any] payload is a write-once snapshot never mutated after init.
public struct NuxieEvent: @unchecked Sendable {
    /// Time-ordered UUID v7 for unique identification
    public let id: String
    
    /// Event name (e.g., "subscription_viewed", "paywall_shown")
    public let name: String

    /// Capture-time name used only for forwarding classification. A
    /// beforeSend rename changes `name` but does not change this value.
    let forwardingName: String
    
    /// User identifier (distinct ID)
    public let distinctId: String
    
    /// Enriched event properties
    public let properties: [String: Any]
    
    /// Event timestamp
    public let timestamp: Date
    
    /// Initialize a new Nuxie event
    /// - Parameters:
    ///   - id: Unique identifier (defaults to time-ordered UUID)
    ///   - name: Event name
    ///   - distinctId: User identifier
    ///   - properties: Event properties
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
        self.forwardingName = name
        self.distinctId = distinctId
        self.properties = properties
        self.timestamp = timestamp
    }

    init(
        id: String,
        name: String,
        forwardingName: String,
        distinctId: String,
        properties: [String: Any],
        timestamp: Date
    ) {
        self.id = id
        self.name = name
        self.forwardingName = forwardingName
        self.distinctId = distinctId
        self.properties = properties
        self.timestamp = timestamp
    }
    
    
}
