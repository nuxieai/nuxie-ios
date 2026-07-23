import Foundation

/// Identifies whether a locally stored fact originated on this device or on the server.
public enum StoredEventOrigin: String, Codable, Sendable {
    /// The SDK created the event on this device.
    case device
    /// The server authored and delivered the fact.
    case server
}

/// Represents an event stored locally in the SQLite database.
/// All stored properties are immutable Sendable value types (the properties
/// dictionary is pre-encoded to `Data`), so the row can cross actor
/// boundaries — e.g. EventLog → store — without copies or warnings.
public struct StoredEvent: Codable, Sendable {
    static let originProperty = "$nuxie_event_origin"
    /// Unique identifier for the event
    let id: String
    
    /// Event name
    let name: String
    
    /// Event properties as JSON data (for efficient storage)
    let properties: Data
    
    /// When the event was created
    let timestamp: Date
    
    /// Distinct ID associated with the event (identified or anonymous).
    /// Always present for SDK-generated events.
    let distinctId: String
    
    /// Session ID for efficient database queries (also in properties as $session_id)
    let sessionId: String?

    /// Origin of the committed fact. Legacy rows and device events default to device.
    public var origin: StoredEventOrigin {
        guard let rawValue = getPropertiesDict()[Self.originProperty] as? String else {
            return .device
        }
        return StoredEventOrigin(rawValue: rawValue) ?? .device
    }
    
    /// Initializer for creating a new stored event
    /// - Parameters:
    ///   - id: Unique identifier (defaults to UUID)
    ///   - name: Event name
    ///   - properties: Event properties dictionary
    ///   - timestamp: Event timestamp (defaults to now)
    ///   - distinctId: Distinct ID (required)
    init(
        id: String = UUID.v7().uuidString,
        name: String,
        properties: [String: Any] = [:],
        timestamp: Date = Date(),
        distinctId: String
    ) throws {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.distinctId = distinctId
        
        // Extract session ID from properties for efficient database queries
        self.sessionId = properties["$session_id"] as? String
        
        // Convert properties to AnyCodable and encode to Data
        let anyCodableProps = properties.mapValues { AnyCodable($0) }
        self.properties = try JSONEncoder().encode(anyCodableProps)
    }
    
    /// Convenience initializer with pre-encoded properties data
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - name: Event name
    ///   - properties: Event properties as JSON Data
    ///   - timestamp: Event timestamp
    ///   - distinctId: Distinct ID (required)
    ///   - sessionId: Session ID (optional)
    init(
        id: String,
        name: String,
        properties: Data,
        timestamp: Date,
        distinctId: String,
        sessionId: String?
    ) {
        self.id = id
        self.name = name
        self.properties = properties
        self.timestamp = timestamp
        self.distinctId = distinctId
        self.sessionId = sessionId
    }
    
    /// Get properties as decoded [String: AnyCodable] dictionary (lazy decoding)
    /// - Returns: Decoded properties dictionary
    /// - Throws: DecodingError if properties cannot be decoded
    func getProperties() throws -> [String: AnyCodable] {
        return try JSONDecoder().decode([String: AnyCodable].self, from: properties)
    }
    
    /// Get properties as [String: Any] dictionary
    /// - Returns: Properties dictionary
    func getPropertiesDict() -> [String: Any] {
        guard let props = try? getProperties() else {
            return [:]
        }
        return props.mapValues { $0.value }
    }
}

/// Error types for event storage operations
enum EventStorageError: Error, LocalizedError {
    case databaseNotInitialized
    case invalidProperties
    case insertFailed(Error)
    case queryFailed(Error)
    case updateFailed(Error)
    case deleteFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Event database not initialized"
        case .invalidProperties:
            return "Invalid event properties - cannot serialize to JSON"
        case .insertFailed(let error):
            return "Failed to insert event: \(error.localizedDescription)"
        case .queryFailed(let error):
            return "Failed to query events: \(error.localizedDescription)"
        case .updateFailed(let error):
            return "Failed to update events: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete events: \(error.localizedDescription)"
        }
    }
}
