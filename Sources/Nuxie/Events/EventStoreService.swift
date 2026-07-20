import Foundation

/// Protocol for event store operations
protocol EventStoreProtocol {
    /// Initialize the event storage system
    /// - Throws: EventStorageError if initialization fails
    func initialize(path: URL?) async throws
        
    /// Reset the event store (close and delete database)
    func reset() async
    
    /// Store an event with automatic session and timestamp handling
    /// - Parameters:
    ///   - name: Event name
    ///   - properties: Event properties
    ///   - distinctId: Distinct ID (optional)
    /// - Throws: EventStorageError if storage fails
    func storeEvent(name: String, properties: [String: Any], distinctId: String) async throws

    /// Store a fully prepared event with a stable id for local history queries.
    /// - Parameter event: Event to insert
    /// - Throws: EventStorageError if storage fails
    func storePreparedEvent(_ event: StoredEvent) async throws
    
    /// Get recent events for analysis
    /// - Parameter limit: Maximum events to return (default: 100)
    /// - Returns: Array of stored events
    /// - Throws: EventStorageError if query fails
    func getRecentEvents(limit: Int) async throws -> [StoredEvent]
    
    /// Get events for a specific user
    /// - Parameters:
    ///   - distinctId: Distinct ID to filter by
    ///   - limit: Maximum events to return
    /// - Returns: Array of stored events for the user
    /// - Throws: EventStorageError if query fails
    func getEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent]
    
    /// Get events for a specific session
    /// - Parameter sessionId: Session ID to filter by
    /// - Returns: Array of events from the specified session
    /// - Throws: EventStorageError if query fails
    func getEvents(for sessionId: String) async throws -> [StoredEvent]
    
    /// Get event count statistics
    /// - Returns: Total number of events stored
    /// - Throws: EventStorageError if query fails
    func getEventCount() async throws -> Int
    
    /// Force cleanup of old events
    /// - Returns: Number of events deleted
    /// - Throws: EventStorageError if cleanup fails
    @discardableResult
    func forceCleanup() async throws -> Int
    
    /// Close the event store (called on SDK teardown)
    func close() async
    
    // MARK: - Event Query Methods
    
    /// Check if a specific event exists for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional date to filter events after
    /// - Returns: True if event exists, false otherwise
    /// - Throws: EventStorageError if query fails
    func hasEvent(name: String, distinctId: String, since: Date?) async throws -> Bool
    
    /// Count events of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to count
    ///   - distinctId: User ID to filter by
    ///   - since: Optional start date (inclusive)
    ///   - until: Optional end date (inclusive)
    /// - Returns: Number of matching events
    /// - Throws: EventStorageError if query fails
    func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Int
    
    /// Get the timestamp of the most recent event of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional start date (inclusive)
    ///   - until: Optional end date (inclusive)
    /// - Returns: Date of most recent event, or nil if no events found
    /// - Throws: EventStorageError if query fails
    func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date?
    
    /// Reassign events from one user to another (for anonymous → identified transitions)
    /// - Parameters:
    ///   - fromUserId: Old user ID (typically anonymous)
    ///   - toUserId: New user ID (typically identified)
    /// - Returns: Number of events reassigned
    /// - Throws: EventStorageError if update fails
    func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int

    /// Events for a user filtered by name (and optionally time) at the SQL
    /// layer — for IR query paths.
    func getEventsForUser(
        _ distinctId: String, name: String, since: Date?, until: Date?,
        ascending: Bool, limit: Int
    ) async throws -> [StoredEvent]

    /// Earliest matching event time (SQL MIN)
    func getFirstEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date?

    // MARK: - Durable delivery

    /// Persist the canonical captured event (same id/timestamp/properties as
    /// the wire payload) marked pending network delivery.
    func storeEventForDelivery(_ event: NuxieEvent) async throws

    /// Load events awaiting delivery (oldest first) for queue rehydration.
    func loadPendingDelivery(limit: Int) async -> [NuxieEvent]

    /// Mark events delivered (server ack or deliberate permanent drop).
    func markDelivered(ids: [String]) async
}

/// Manager for handling event storage operations with business logic
final class EventStore: EventStoreProtocol {
    
    // MARK: - Properties
    
    private let eventStore: SQLiteEventStore
    private let maxEventsStored: Int
    private let cleanupThresholdDays: Int

    // MARK: - Initialization
    
    /// Initialize the event store manager with custom settings (for testing or specific configurations)
    /// - Parameters:
    ///   - maxEventsStored: Maximum events to keep in storage (default: 10,000)
    ///   - cleanupThresholdDays: Delete events older than this many days (default: 30)
    init(
        maxEventsStored: Int = 10_000,
        cleanupThresholdDays: Int = 30
    ) {
        self.eventStore = SQLiteEventStore()
        self.maxEventsStored = maxEventsStored
        self.cleanupThresholdDays = cleanupThresholdDays
    }
    
    // MARK: - Public Methods
    
    /// Initialize the event storage system
    /// - Parameter path: Custom database path (optional)
    /// - Throws: EventStorageError if initialization fails
    func initialize(path: URL?) async throws {
        try await eventStore.initialize(path: path)
        
        // Perform cleanup on initialization
        try await performCleanupIfNeeded()
        
        LogInfo("EventStoreManager initialized")
    }
    
    /// Reset the event store (close and delete database)
    func reset() async {
        // Close the store
        await eventStore.reset()
                
        LogInfo("EventStore reset completed")
    }
    
    /// Store an event with automatic session and timestamp handling
    /// - Parameters:
    ///   - name: Event name
    ///   - properties: Event properties
    ///   - distinctId: Distinct ID (optional)
    /// - Throws: EventStorageError if storage fails
    func storeEvent(
        name: String,
        properties: [String: Any] = [:],
        distinctId: String
    ) async throws {
        LogDebug("EventStore.storeEvent called - name: \(name), distinctId: \(distinctId)")
        
        // Create enriched properties with metadata
        var enrichedProperties = properties
        enrichedProperties["sdk_version"] = SDKVersion.current
        enrichedProperties["platform"] = currentPlatform()
        
        // Add device info if not already present
        if enrichedProperties["device_model"] == nil {
            enrichedProperties["device_model"] = getDeviceModel()
        }
        if enrichedProperties["os_version"] == nil {
            enrichedProperties["os_version"] = getOSVersion()
        }
        
        // Create stored event
        // Note: Session ID should be provided by the caller (e.g., NuxieSDK)
        // EventStore should not fetch it directly to avoid coupling
        let event = try StoredEvent(
            name: name,
            properties: enrichedProperties,
            distinctId: distinctId
        )
        
        LogDebug("Created StoredEvent with id: \(event.id)")
        
        // Store the event
        try await eventStore.insertEvent(event)
        
        LogDebug("Stored event: \(name) (user: \(NuxieLogger.shared.logDistinctID(distinctId)))")
        
        // Trigger cleanup if we're over the limit
        try await performCleanupIfNeeded()
    }

    func storePreparedEvent(_ event: StoredEvent) async throws {
        try await eventStore.insertEvent(event)
        try await performCleanupIfNeeded()
    }
    
    /// Get recent events for analysis
    /// - Parameter limit: Maximum events to return (default: 100)
    /// - Returns: Array of stored events
    /// - Throws: EventStorageError if query fails
    func getRecentEvents(limit: Int = 100) async throws -> [StoredEvent] {
        return try await eventStore.queryRecentEvents(limit: limit)
    }
    
    /// Get events for a specific user
    /// - Parameters:
    ///   - distinctId: Distinct ID to filter by
    ///   - limit: Maximum events to return
    /// - Returns: Array of stored events for the user
    /// - Throws: EventStorageError if query fails
    func getEventsForUser(_ distinctId: String, limit: Int = 100) async throws -> [StoredEvent] {
        // Use efficient database query with indexed user_id column
        return try await eventStore.queryEventsForUser(distinctId, limit: limit)
    }
    
    /// Get events for a specific session
    /// - Parameter sessionId: Session ID to filter by
    /// - Returns: Array of events from the specified session
    /// - Throws: EventStorageError if query fails
    func getEvents(for sessionId: String) async throws -> [StoredEvent] {
        // Use efficient database query with indexed session_id column
        return try await eventStore.querySessionEvents(sessionId)
    }
    
    
    /// Get event count statistics
    /// - Returns: Total number of events stored
    /// - Throws: EventStorageError if query fails
    func getEventCount() async throws -> Int {
        return try await eventStore.getEventCount()
    }
    
    /// Force cleanup of old events
    /// - Returns: Number of events deleted
    /// - Throws: EventStorageError if cleanup fails
    @discardableResult
    func forceCleanup() async throws -> Int {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -cleanupThresholdDays, to: Date()) ?? Date()
        let deletedCount = try await eventStore.deleteEventsOlderThan(cutoffDate)
        
        if deletedCount > 0 {
            LogInfo("Cleaned up \(deletedCount) old events")
        }
        
        return deletedCount
    }
    
    /// Close the event store (called on SDK teardown)
    func close() async {
        await eventStore.close()
        LogInfo("EventStoreManager closed")
    }
    
    
    // MARK: - Event Query Methods
    
    /// Check if a specific event exists for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional date to filter events after
    /// - Returns: True if event exists, false otherwise
    /// - Throws: EventStorageError if query fails
    func hasEvent(name: String, distinctId: String, since: Date? = nil) async throws -> Bool {
        return try await eventStore.hasEvent(name: name, distinctId: distinctId, since: since)
    }
    
    /// Count events of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to count
    ///   - distinctId: User ID to filter by
    ///   - since: Optional date to filter events after
    /// - Returns: Number of matching events
    /// - Throws: EventStorageError if query fails
    func countEvents(name: String, distinctId: String, since: Date? = nil, until: Date? = nil) async throws -> Int {
        return try await eventStore.countEvents(name: name, distinctId: distinctId, since: since, until: until)
    }
    
    /// Get the timestamp of the most recent event of a specific type for a user
    /// - Parameters:
    ///   - name: Event name to search for
    ///   - distinctId: User ID to filter by
    ///   - since: Optional start date (inclusive)
    ///   - until: Optional end date (inclusive)
    /// - Returns: Date of most recent event, or nil if no events found
    /// - Throws: EventStorageError if query fails
    func getLastEventTime(name: String, distinctId: String, since: Date? = nil, until: Date? = nil) async throws -> Date? {
        return try await eventStore.getLastEventTime(name: name, distinctId: distinctId, since: since, until: until)
    }
    
    /// Reassign events from one user to another (for anonymous → identified transitions)
    /// - Parameters:
    ///   - fromUserId: Old user ID (typically anonymous)
    ///   - toUserId: New user ID (typically identified)
    /// - Returns: Number of events reassigned
    /// - Throws: EventStorageError if update fails
    func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        let reassignedCount = try await eventStore.reassignEvents(from: fromUserId, to: toUserId)
        if reassignedCount > 0 {
            LogInfo("Reassigned \(reassignedCount) events from \(NuxieLogger.shared.logDistinctID(fromUserId)) to \(NuxieLogger.shared.logDistinctID(toUserId))")
        }
        return reassignedCount
    }
    
    /// Events for a user filtered by name (and optionally time) at the SQL
    /// layer — for IR query paths.
    func getEventsForUser(
        _ distinctId: String, name: String, since: Date?, until: Date?,
        ascending: Bool, limit: Int
    ) async throws -> [StoredEvent] {
        try await eventStore.queryEventsForUser(
            distinctId, name: name, since: since, until: until,
            ascending: ascending, limit: limit)
    }

    func getFirstEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date? {
        try await eventStore.getFirstEventTime(name: name, distinctId: distinctId, since: since, until: until)
    }

    // MARK: - Durable delivery

    func storeEventForDelivery(_ event: NuxieEvent) async throws {
        let stored = try StoredEvent(
            id: event.id,
            name: event.name,
            properties: event.properties,
            timestamp: event.timestamp,
            distinctId: event.distinctId
        )
        try await eventStore.insertEvent(stored, deliveryState: .pending)
        try await performCleanupIfNeeded()
    }

    func loadPendingDelivery(limit: Int) async -> [NuxieEvent] {
        do {
            let stored = try await eventStore.queryPendingDelivery(limit: limit)
            return stored.map { row in
                NuxieEvent(
                    id: row.id,
                    name: row.name,
                    distinctId: row.distinctId,
                    properties: row.getPropertiesDict(),
                    timestamp: row.timestamp
                )
            }
        } catch {
            LogWarning("Failed to load pending-delivery events: \(error)")
            return []
        }
    }

    func markDelivered(ids: [String]) async {
        do {
            try await eventStore.markDelivered(ids: ids)
        } catch {
            // Worst case these rows re-send after relaunch; the server dedupes
            // on the event-id idempotency key.
            LogWarning("Failed to mark \(ids.count) events delivered: \(error)")
        }
    }

    // MARK: - Private Methods

    /// Cleanup runs at most once per `cleanupCheckInterval` inserts — the old
    /// per-insert COUNT(*) was a wasted query on every event.
    private var insertsSinceCleanupCheck = 0
    private let cleanupCheckInterval = 100

    private func performCleanupIfNeeded() async throws {
        insertsSinceCleanupCheck += 1
        guard insertsSinceCleanupCheck >= cleanupCheckInterval else { return }
        insertsSinceCleanupCheck = 0

        let eventCount = try await eventStore.getEventCount()
        guard eventCount > maxEventsStored else { return }

        // Enforce the cap by COUNT (the old age-based delete let active users
        // grow unboundedly within the retention window), then apply the age
        // policy on top.
        let cappedDeletes = try await eventStore.deleteOldestDeliveredEvents(keeping: maxEventsStored)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -cleanupThresholdDays, to: Date()) ?? Date()
        let agedDeletes = try await eventStore.deleteEventsOlderThan(cutoffDate)
        LogInfo("Retention cleanup: removed \(cappedDeletes) over-cap + \(agedDeletes) aged events (had \(eventCount))")
    }
    
    private func getDeviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }
    
    private func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func currentPlatform() -> String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "unknown"
        #endif
    }
}
