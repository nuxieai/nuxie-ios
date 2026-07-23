import Foundation
import SQLite3

// SQLite constants for Swift
private let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistence surface the event log writes through. One implementation
/// (SQLite) in production; mocks in tests.
public protocol EventStoreProtocol: Sendable {
  func initialize(path: URL?) async throws
  func reset() async
  func close() async

  /// Insert a history-only row (already delivered by a direct-send path, or
  /// deliberately excluded from batch delivery).
  func insertHistory(_ event: StoredEvent) async throws

  /// Insert the canonical captured record (stored row == wire payload)
  /// marked pending network delivery.
  func insertPending(_ event: StoredEvent) async throws

  func queryRecentEvents(limit: Int) async throws -> [StoredEvent]
  func queryEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent]
  func queryEventsForUser(
    _ distinctId: String, name: String, since: Date?, until: Date?,
    ascending: Bool, limit: Int
  ) async throws -> [StoredEvent]
  func querySessionEvents(_ sessionId: String) async throws -> [StoredEvent]
  func getEventCount() async throws -> Int
  func hasEvent(name: String, distinctId: String, since: Date?) async throws -> Bool
  func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Int
  func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws
    -> Date?
  func getFirstEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws
    -> Date?
  func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int

  // MARK: - Durable delivery

  /// Load events awaiting delivery (oldest first) for queue rehydration.
  func queryPendingDelivery(limit: Int) async throws -> [StoredEvent]

  /// Mark events delivered (server ack or deliberate permanent drop).
  func markDelivered(ids: [String]) async throws

  /// Delete delivered rows older than the date. Never reaps pending rows.
  @discardableResult
  func deleteEventsOlderThan(_ olderThan: Date) async throws -> Int

  /// Delete the oldest delivered rows beyond the cap. Never reaps pending rows.
  @discardableResult
  func deleteOldestDeliveredEvents(keeping: Int) async throws -> Int
}

/// SQLite-based event storage implementation
/// Thread safety: Guaranteed by actor isolation
public actor SQLiteEventStore: EventStoreProtocol {

  // MARK: - Properties

  // nonisolated(unsafe): accessed from the actor's methods (isolated) and
  // from deinit, which has exclusive access to the last reference.
  private nonisolated(unsafe) var db: OpaquePointer?
  private(set) var dbPath: String?

  // MARK: - SQL Statements

  private let createTableSQL = """
    CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        properties BLOB NOT NULL,
        timestamp INTEGER NOT NULL,
        user_id TEXT NOT NULL,
        session_id TEXT,
        delivery_state INTEGER NOT NULL DEFAULT 2
    );
    """

  /// delivery_state values. Rows default to .delivered so history written by
  /// direct-delivery paths (and pre-migration rows) never re-sends.
  public enum DeliveryState: Int32, Sendable {
    case pending = 0
    case delivered = 2
  }

  private let createIndexSQL = [
    "CREATE INDEX IF NOT EXISTS idx_events_delivery ON events(delivery_state, timestamp);",
    "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_id ON events(user_id);",
    "CREATE INDEX IF NOT EXISTS idx_events_name ON events(name);",
    "CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_id);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_name_time ON events(user_id, name, timestamp DESC);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_time ON events(user_id, timestamp DESC);",
    "CREATE INDEX IF NOT EXISTS idx_events_session_time ON events(session_id, timestamp DESC);",
  ]

  private let insertEventSQL = """
    INSERT INTO events (id, name, properties, timestamp, user_id, session_id, delivery_state)
    VALUES (?, ?, ?, ?, ?, ?, ?);
    """

  private let insertEventIfAbsentSQL = """
    INSERT OR IGNORE INTO events (id, name, properties, timestamp, user_id, session_id)
    VALUES (?, ?, ?, ?, ?, ?);
    """

  private let queryEventsSQL = """
    SELECT id, name, properties, timestamp, user_id, session_id
    FROM events
    ORDER BY timestamp DESC
    LIMIT ?;
    """

  // Age-based retention must never reap rows still awaiting delivery — a
  // long-offline device's pending events survive until acked (or deliberately
  // dropped, which also marks them delivered).
  private let deleteOldEventsSQL = """
    DELETE FROM events
    WHERE timestamp < ? AND delivery_state = 2;
    """

  private let countEventsSQL = "SELECT COUNT(*) FROM events;"

  // MARK: - Initialization

  public init() {
  }

  deinit {
    // deinit has exclusive access to actor state, but cannot call the
    // actor-isolated close(); close the raw handle directly with the same
    // semantics (safety net for a store dropped without an explicit close).
    if let db = db {
      sqlite3_close(db)
    }
  }

  // MARK: - Database Management

  /// Initialize the database and create tables
  /// - Parameter path: Path to SQLite database file
  /// - Throws: EventStorageError if initialization fails
  public func initialize(path: URL?) throws {
    // Determine the base directory
    let baseDir: URL
    if let customPath = path {
      // Use custom path with nuxie subdirectory
      baseDir = customPath.appendingPathComponent("nuxie", isDirectory: true)
    } else {
      // Use default Application Support/nuxie directory
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
      baseDir = appSupport.appendingPathComponent("nuxie", isDirectory: true)
    }
    
    // Create directory if needed
    try? FileManager.default.createDirectory(
      at: baseDir, withIntermediateDirectories: true, attributes: nil)
    
    // Set database path
    let dbPath = baseDir.appendingPathComponent("events.db")
    self.dbPath = dbPath.path

    // Open database
    if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      sqlite3_close(db)
      db = nil
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Set PRAGMAs for proper concurrency handling
    // WAL mode for better concurrent access
    _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    // Wait up to 5 seconds if database is locked
    _ = sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
    // Balance between safety and performance
    _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
    // Ensure referential integrity
    _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

    // Create table
    if sqlite3_exec(db, createTableSQL, nil, nil, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    migrateSchemaIfNeeded()

    // Create indexes
    for indexSQL in createIndexSQL {
      if sqlite3_exec(db, indexSQL, nil, nil, nil) != SQLITE_OK {
        let errorMessage = String(cString: sqlite3_errmsg(db))
        LogWarning("Failed to create index: \(errorMessage)")
      }
    }

    LogInfo("Event database initialized at: \(dbPath)")
  }

  /// Versioned, additive schema migration (PRAGMA user_version).
  private func migrateSchemaIfNeeded() {
    var version: Int32 = 0
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
       sqlite3_step(stmt) == SQLITE_ROW {
      version = sqlite3_column_int(stmt, 0)
    }
    sqlite3_finalize(stmt)

    if version < 1 {
      // v1: delivery_state column. CREATE TABLE IF NOT EXISTS already includes
      // it for fresh databases; pre-existing tables need the ALTER (which
      // fails harmlessly with "duplicate column" when the column exists).
      _ = sqlite3_exec(
        db,
        "ALTER TABLE events ADD COLUMN delivery_state INTEGER NOT NULL DEFAULT 2;",
        nil, nil, nil)
      _ = sqlite3_exec(db, "PRAGMA user_version = 1;", nil, nil, nil)
      LogInfo("Event store schema migrated to v1 (delivery_state)")
    }
  }

  /// Close the database connection
  public func close() {
    if let db = db {
      sqlite3_close(db)
      self.db = nil
    }
  }

  /// Reset the database (close and delete database)
  public func reset() {
    close()
    if let dbPath = dbPath {
      try? FileManager.default.removeItem(atPath: dbPath)
      self.dbPath = nil
    }
  }

  // MARK: - Event Operations

  /// Insert a new event into the database
  /// - Parameter event: Event to store
  /// - Throws: EventStorageError if insert fails
  public func insertEvent(_ event: StoredEvent, deliveryState: DeliveryState = .delivered) throws {
    LogDebug("SQLiteEventStore.insertEvent - id: \(event.id), name: \(event.name)")
    
    guard let db = db else {
      LogError("Database not initialized!")
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, insertEventSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      LogError("Failed to prepare insert statement: \(errorMessage)")
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, event.id, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, event.name, -1, SQLITE_TRANSIENT)

    // Properties are already Data, bind directly
    _ = event.properties.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
    }

    sqlite3_bind_int64(statement, 4, Int64(event.timestamp.timeIntervalSince1970 * 1000))  // Store as milliseconds

    sqlite3_bind_text(statement, 5, event.distinctId, -1, SQLITE_TRANSIENT)

    // Use sessionId field directly for database storage
    if let sessionId = event.sessionId {
      sqlite3_bind_text(statement, 6, sessionId, -1, SQLITE_TRANSIENT)
    } else {
      sqlite3_bind_null(statement, 6)
    }

    sqlite3_bind_int(statement, 7, deliveryState.rawValue)

    // Execute
    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      LogError("Failed to execute insert statement: \(errorMessage)")
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }
    
    LogDebug("Successfully inserted event into database: \(event.name)")
  }

  /// Insert an event unless its stable id has already been committed.
  func insertEventIfAbsent(_ event: StoredEvent) throws -> Bool {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(db, insertEventIfAbsentSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    sqlite3_bind_text(statement, 1, event.id, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, event.name, -1, SQLITE_TRANSIENT)
    _ = event.properties.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
    }
    sqlite3_bind_int64(statement, 4, Int64(event.timestamp.timeIntervalSince1970 * 1000))
    sqlite3_bind_text(statement, 5, event.distinctId, -1, SQLITE_TRANSIENT)
    if let sessionId = event.sessionId {
      sqlite3_bind_text(statement, 6, sessionId, -1, SQLITE_TRANSIENT)
    } else {
      sqlite3_bind_null(statement, 6)
    }

    guard sqlite3_step(statement) == SQLITE_DONE else {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    return sqlite3_changes(db) == 1
  }

  /// Query recent events from the database
  /// - Parameter limit: Maximum number of events to return (default: 100)
  /// - Returns: Array of stored events
  /// - Throws: EventStorageError if query fails
  public func queryRecentEvents(limit: Int = 100) throws -> [StoredEvent] {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, queryEventsSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 5, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind limit
    sqlite3_bind_int(statement, 1, Int32(limit))

    // Execute and collect results
    var events: [StoredEvent] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let id: String = {
        if let text = sqlite3_column_text(statement, 0) {
          return String(cString: text)
        }
        return ""
      }()

      let name: String = {
        if let text = sqlite3_column_text(statement, 1) {
          return String(cString: text)
        }
        return ""
      }()

      let propertiesBlob = sqlite3_column_blob(statement, 2)
      let propertiesSize = sqlite3_column_bytes(statement, 2)
      let propertiesData = Data(bytes: propertiesBlob!, count: Int(propertiesSize))

      let timestampMs = sqlite3_column_int64(statement, 3)
      let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

      let distinctId = String(cString: sqlite3_column_text(statement, 4))

      let sessionId: String? = {
        if sqlite3_column_type(statement, 5) == SQLITE_NULL {
          return nil
        }
        if let text = sqlite3_column_text(statement, 5) {
          return String(cString: text)
        }
        return nil
      }()

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId,
        sessionId: sessionId
      )

      events.append(event)
    }

    return events
  }

  /// Delete events older than the specified date
  /// - Parameter olderThan: Delete events older than this date
  /// - Returns: Number of events deleted
  /// - Throws: EventStorageError if deletion fails
  public func deleteEventsOlderThan(_ olderThan: Date) throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, deleteOldEventsSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.deleteFailed(
        NSError(domain: "SQLite", code: 6, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind timestamp (in milliseconds)
    let timestampMs = Int64(olderThan.timeIntervalSince1970 * 1000)
    sqlite3_bind_int64(statement, 1, timestampMs)

    // Execute
    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.deleteFailed(
        NSError(domain: "SQLite", code: 7, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    return Int(sqlite3_changes(db))
  }

  /// Get total count of events in database
  /// - Returns: Number of events stored
  /// - Throws: EventStorageError if query fails
  public func getEventCount() throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, countEventsSQL, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 8, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      return Int(sqlite3_column_int(statement, 0))
    }

    return 0
  }

  // MARK: - Event Query Methods

  /// Check if a specific event exists for a user
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional date to filter events after
  /// - Returns: True if event exists, false otherwise
  /// - Throws: EventStorageError if query fails
  public func hasEvent(name: String, distinctId: String, since: Date? = nil) throws -> Bool {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql: String
    if since != nil {
      sql = """
        SELECT EXISTS(
            SELECT 1 FROM events
            WHERE user_id = ? AND name = ? AND timestamp >= ?
            LIMIT 1
        );
        """
    } else {
      sql = """
        SELECT EXISTS(
            SELECT 1 FROM events 
            WHERE user_id = ? AND name = ?
            LIMIT 1
        );
        """
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 9, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)

    if let since = since {
      let timestampMs = Int64(since.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, 3, timestampMs)
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      return sqlite3_column_int(statement, 0) != 0
    }

    return false
  }

  /// Count events of a specific type for a user
  /// - Parameters:
  ///   - name: Event name to count
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Number of matching events
  /// - Throws: EventStorageError if query fails
  public func countEvents(name: String, distinctId: String, since: Date? = nil, until: Date? = nil) throws
    -> Int
  {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var sql = "SELECT COUNT(*) FROM events WHERE user_id = ? AND name = ?"
    var bindIndex: Int32 = 3

    if since != nil {
      sql += " AND timestamp >= ?"
    }
    if until != nil {
      sql += " AND timestamp <= ?"
    }
    sql += ";"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 10, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)

    if let since = since {
      let timestampMs = Int64(since.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
      bindIndex += 1
    }
    if let until = until {
      let timestampMs = Int64(until.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      return Int(sqlite3_column_int(statement, 0))
    }

    return 0
  }

  /// Get the timestamp of the most recent event of a specific type for a user
  /// - Parameters:
  ///   - name: Event name to search for
  ///   - distinctId: User ID to filter by
  ///   - since: Optional start date (inclusive)
  ///   - until: Optional end date (inclusive)
  /// - Returns: Date of most recent event, or nil if no events found
  /// - Throws: EventStorageError if query fails
  public func getLastEventTime(name: String, distinctId: String, since: Date? = nil, until: Date? = nil)
    throws -> Date?
  {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var sql = "SELECT MAX(timestamp) FROM events WHERE user_id = ? AND name = ?"
    var bindIndex: Int32 = 3

    if since != nil {
      sql += " AND timestamp >= ?"
    }
    if until != nil {
      sql += " AND timestamp <= ?"
    }
    sql += ";"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 11, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)

    if let since = since {
      let timestampMs = Int64(since.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
      bindIndex += 1
    }
    if let until = until {
      let timestampMs = Int64(until.timeIntervalSince1970 * 1000)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
    }

    // Execute
    if sqlite3_step(statement) == SQLITE_ROW {
      if sqlite3_column_type(statement, 0) == SQLITE_NULL {
        return nil
      }
      let timestampMs = sqlite3_column_int64(statement, 0)
      return Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
    }

    return nil
  }

  /// Query events for a specific user with efficient database filtering
  /// - Parameters:
  ///   - distinctId: User ID to filter by
  ///   - limit: Maximum number of events to return
  /// - Returns: Array of events for the user
  /// - Throws: EventStorageError if query fails
  /// Events for a user filtered by NAME (and optionally time) at the SQL
  /// layer — the IR query paths previously fetched the last N events of ALL
  /// names and filtered in Swift, so heavy users' history evicted the queried
  /// event's older instances (wrong counts, wrong firstTime).
  public func queryEventsForUser(
    _ distinctId: String,
    name: String,
    since: Date?,
    until: Date?,
    ascending: Bool,
    limit: Int
  ) throws -> [StoredEvent] {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var sql = """
      SELECT id, name, properties, timestamp, user_id, session_id
      FROM events
      WHERE user_id = ? AND name = ?
      """
    if since != nil { sql += " AND timestamp >= ?" }
    if until != nil { sql += " AND timestamp <= ?" }
    sql += " ORDER BY timestamp \(ascending ? "ASC" : "DESC") LIMIT ?;"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 25, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    var bindIndex: Int32 = 1
    sqlite3_bind_text(statement, bindIndex, distinctId, -1, SQLITE_TRANSIENT); bindIndex += 1
    sqlite3_bind_text(statement, bindIndex, name, -1, SQLITE_TRANSIENT); bindIndex += 1
    if let since {
      sqlite3_bind_int64(statement, bindIndex, Int64(since.timeIntervalSince1970 * 1000)); bindIndex += 1
    }
    if let until {
      sqlite3_bind_int64(statement, bindIndex, Int64(until.timeIntervalSince1970 * 1000)); bindIndex += 1
    }
    sqlite3_bind_int(statement, bindIndex, Int32(limit))

    var events: [StoredEvent] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = sqlite3_column_text(statement, 0),
            let propertiesBlob = sqlite3_column_blob(statement, 2)
      else { continue }
      let sessionId: String? = {
        if sqlite3_column_type(statement, 5) == SQLITE_NULL { return nil }
        if let text = sqlite3_column_text(statement, 5) { return String(cString: text) }
        return nil
      }()
      events.append(StoredEvent(
        id: String(cString: idText),
        name: name,
        properties: Data(bytes: propertiesBlob, count: Int(sqlite3_column_bytes(statement, 2))),
        timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000.0),
        distinctId: distinctId,
        sessionId: sessionId
      ))
    }
    return events
  }

  /// Earliest matching event time via SQL MIN (predicate-free firstTime).
  public func getFirstEventTime(name: String, distinctId: String, since: Date?, until: Date?) throws -> Date? {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var sql = "SELECT MIN(timestamp) FROM events WHERE user_id = ? AND name = ?"
    if since != nil { sql += " AND timestamp >= ?" }
    if until != nil { sql += " AND timestamp <= ?" }
    sql += ";"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 26, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    var bindIndex: Int32 = 1
    sqlite3_bind_text(statement, bindIndex, distinctId, -1, SQLITE_TRANSIENT); bindIndex += 1
    sqlite3_bind_text(statement, bindIndex, name, -1, SQLITE_TRANSIENT); bindIndex += 1
    if let since {
      sqlite3_bind_int64(statement, bindIndex, Int64(since.timeIntervalSince1970 * 1000)); bindIndex += 1
    }
    if let until {
      sqlite3_bind_int64(statement, bindIndex, Int64(until.timeIntervalSince1970 * 1000)); bindIndex += 1
    }

    if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL {
      return Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000.0)
    }
    return nil
  }

  public func queryEventsForUser(_ distinctId: String, limit: Int = 100) throws -> [StoredEvent] {
    LogDebug("SQLiteEventStore.queryEventsForUser - distinctId: \(distinctId), limit: \(limit)")
    
    guard let db = db else {
      LogError("Database not initialized for query!")
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      SELECT id, name, properties, timestamp, user_id, session_id
      FROM events
      WHERE user_id = ?
      ORDER BY timestamp DESC
      LIMIT ?;
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 13, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(statement, 2, Int32(limit))

    // Execute and collect results
    var events: [StoredEvent] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let id: String = {
        if let text = sqlite3_column_text(statement, 0) {
          return String(cString: text)
        }
        return ""
      }()

      let name: String = {
        if let text = sqlite3_column_text(statement, 1) {
          return String(cString: text)
        }
        return ""
      }()

      let propertiesBlob = sqlite3_column_blob(statement, 2)
      let propertiesSize = sqlite3_column_bytes(statement, 2)
      let propertiesData = Data(bytes: propertiesBlob!, count: Int(propertiesSize))

      let timestampMs = sqlite3_column_int64(statement, 3)
      let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

      // user_id is already known (we're filtering by it)

      let sessionId: String? = {
        if sqlite3_column_type(statement, 5) == SQLITE_NULL {
          return nil
        }
        if let text = sqlite3_column_text(statement, 5) {
          return String(cString: text)
        }
        return nil
      }()

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId,
        sessionId: sessionId
      )

      events.append(event)
    }

    LogDebug("SQLiteEventStore.queryEventsForUser returning \(events.count) events")
    return events
  }

  // MARK: - Durable delivery

  /// Load events awaiting network delivery, oldest first.
  public func queryPendingDelivery(limit: Int) throws -> [StoredEvent] {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      SELECT id, name, properties, timestamp, user_id, session_id
      FROM events
      WHERE delivery_state = ?
      ORDER BY timestamp ASC
      LIMIT ?;
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 20, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    sqlite3_bind_int(statement, 1, DeliveryState.pending.rawValue)
    sqlite3_bind_int(statement, 2, Int32(limit))

    var events: [StoredEvent] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = sqlite3_column_text(statement, 0),
            let nameText = sqlite3_column_text(statement, 1),
            let propertiesBlob = sqlite3_column_blob(statement, 2),
            let userIdText = sqlite3_column_text(statement, 4)
      else { continue }

      let sessionId: String? = {
        if sqlite3_column_type(statement, 5) == SQLITE_NULL { return nil }
        if let text = sqlite3_column_text(statement, 5) { return String(cString: text) }
        return nil
      }()

      events.append(StoredEvent(
        id: String(cString: idText),
        name: String(cString: nameText),
        properties: Data(bytes: propertiesBlob, count: Int(sqlite3_column_bytes(statement, 2))),
        timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000.0),
        distinctId: String(cString: userIdText),
        sessionId: sessionId
      ))
    }
    return events
  }

  /// Mark events as delivered (server ack, or a deliberate permanent drop —
  /// either way they must never re-send).
  public func markDelivered(ids: [String]) throws {
    guard !ids.isEmpty else { return }
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
    let sql = "UPDATE events SET delivery_state = \(DeliveryState.delivered.rawValue) WHERE id IN (\(placeholders));"

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.updateFailed(
        NSError(domain: "SQLite", code: 21, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    for (index, id) in ids.enumerated() {
      sqlite3_bind_text(statement, Int32(index + 1), id, -1, SQLITE_TRANSIENT)
    }

    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.updateFailed(
        NSError(domain: "SQLite", code: 22, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }
  }

  /// Enforce the retention cap by deleting the oldest DELIVERED events beyond
  /// `keeping`. Pending-delivery rows are never deleted (they are bounded by
  /// the network queue's maxQueueSize).
  public func deleteOldestDeliveredEvents(keeping: Int) throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      DELETE FROM events
      WHERE delivery_state = \(DeliveryState.delivered.rawValue)
        AND id IN (
          SELECT id FROM events
          ORDER BY timestamp ASC
          LIMIT max(0, (SELECT COUNT(*) FROM events) - ?)
        );
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.deleteFailed(
        NSError(domain: "SQLite", code: 23, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    sqlite3_bind_int(statement, 1, Int32(keeping))

    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.deleteFailed(
        NSError(domain: "SQLite", code: 24, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    return Int(sqlite3_changes(db))
  }

  /// Reassign events from one user to another (for anonymous → identified transitions)
  /// - Parameters:
  ///   - fromUserId: Old user ID (typically anonymous)
  ///   - toUserId: New user ID (typically identified)
  /// - Returns: Number of events reassigned
  /// - Throws: EventStorageError if update fails
  public func reassignEvents(from fromUserId: String, to toUserId: String) throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      UPDATE events
      SET user_id = ?
      WHERE user_id = ?;
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 14, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind parameters
    sqlite3_bind_text(statement, 1, toUserId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, fromUserId, -1, SQLITE_TRANSIENT)

    // Execute
    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 15, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    return Int(sqlite3_changes(db))
  }

  /// Query events for a specific session
  /// - Parameter sessionId: Session ID to filter by
  /// - Returns: Array of events from the session
  /// - Throws: EventStorageError if query fails
  public func querySessionEvents(_ sessionId: String) throws -> [StoredEvent] {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql = """
      SELECT id, name, properties, timestamp, user_id, session_id
      FROM events
      WHERE session_id = ?
      ORDER BY timestamp DESC;
      """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    // Prepare statement
    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 12, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    // Bind session ID
    sqlite3_bind_text(statement, 1, sessionId, -1, SQLITE_TRANSIENT)

    // Execute and collect results
    var events: [StoredEvent] = []

    while sqlite3_step(statement) == SQLITE_ROW {
      let id: String = {
        if let text = sqlite3_column_text(statement, 0) {
          return String(cString: text)
        }
        return ""
      }()

      let name: String = {
        if let text = sqlite3_column_text(statement, 1) {
          return String(cString: text)
        }
        return ""
      }()

      let propertiesBlob = sqlite3_column_blob(statement, 2)
      let propertiesSize = sqlite3_column_bytes(statement, 2)
      let propertiesData = Data(bytes: propertiesBlob!, count: Int(propertiesSize))

      let timestampMs = sqlite3_column_int64(statement, 3)
      let timestamp = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)

      let distinctId = String(cString: sqlite3_column_text(statement, 4))

      // Session ID is already known (we're filtering by it)

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId,
        sessionId: sessionId
      )

      events.append(event)
    }

    return events
  }
}

// MARK: - EventStoreProtocol delivery-state entry points

extension SQLiteEventStore {
  public func insertHistory(_ event: StoredEvent) throws {
    try insertEvent(event, deliveryState: .delivered)
  }

  public func insertPending(_ event: StoredEvent) throws {
    try insertEvent(event, deliveryState: .pending)
  }
}
