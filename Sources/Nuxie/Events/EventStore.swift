import Foundation
import SQLite3

// SQLite constants for Swift
private let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StableEventCaptureOutcome: Sendable {
  case captured(StoredEvent, isNew: Bool)
  case dropped
}

struct EventHistoryPruneResult: Equatable, Sendable {
  let countDeleted: Int
  let ageDeleted: Int
  let coverageStartingAt: Date
}

/// Persistence surface the event log writes through. One implementation
/// (SQLite) in production; mocks in tests.
protocol EventStoreProtocol: Sendable {
  func initialize(path: URL?) async throws
  func reset() async
  func close() async

  /// Insert a history-only row (already delivered by a direct-send path, or
  /// deliberately excluded from batch delivery).
  func insertHistory(_ event: StoredEvent) async throws

  /// Insert a history-only row unless its stable id already exists.
  /// Returns whether the row was newly committed.
  func insertHistoryIfAbsent(_ event: StoredEvent) async throws -> Bool

  /// Insert the canonical captured record (stored row == wire payload)
  /// marked pending network delivery.
  func insertPending(_ event: StoredEvent) async throws

  /// Insert a pending row unless its stable id already exists.
  /// Returns whether the row was newly committed.
  func insertPendingIfAbsent(_ event: StoredEvent) async throws -> Bool

  /// Read or atomically establish the terminal outcome for a stable event ID.
  /// A dropped outcome is deliberately separate from event history/delivery.
  func queryStableCapture(id: String) async throws -> StableEventCaptureOutcome?
  func commitStableCapture(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date
  ) async throws -> StableEventCaptureOutcome
  @discardableResult
  func deleteStableDropsOlderThan(_ olderThan: Date) async throws -> Int

  func queryRecentEvents(limit: Int) async throws -> [StoredEvent]
  func queryEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent]
  func queryEventsForUser(
    _ distinctId: String, name: String, since: Date?, until: Date?,
    ascending: Bool, limit: Int
  ) async throws -> [StoredEvent]
  func querySessionEvents(_ sessionId: String) async throws -> [StoredEvent]
  func getEventCount() async throws -> Int
  /// Atomically establish the conservative origin for a fresh current-schema
  /// database on its first SDK open.
  func readOrInitializeHistoryCoverage(startingAt: Date) async throws -> Date
  func historyCoverageStartingAt() async throws -> Date
  /// Monotonically fence history after a known persistence gap.
  func advanceHistoryCoverage(to startingAt: Date) async throws -> Date
  /// Delete retained rows and advance the durable coverage boundary in the
  /// same transaction. Either both effects commit or neither does.
  func pruneHistory(keeping: Int, olderThan: Date) async throws -> EventHistoryPruneResult
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

  /// Count every event still awaiting delivery, including rows outside the
  /// in-memory delivery window.
  func getPendingDeliveryCount() async throws -> Int

  /// Mark events delivered (server ack or deliberate permanent drop).
  func markDelivered(ids: [String]) async throws

}

/// SQLite-based event storage implementation
/// Thread safety: Guaranteed by actor isolation
actor SQLiteEventStore: EventStoreProtocol {

  // MARK: - Properties

  private static let currentSchemaVersion: Int32 = 1

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
  /// direct-delivery paths never re-sends.
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

  private let createStableCaptureOutcomesSQL = """
    CREATE TABLE IF NOT EXISTS stable_event_drops (
      event_id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    );
    """

  private let createHistoryMetadataSQL = """
    CREATE TABLE IF NOT EXISTS event_history_metadata (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      coverage_start_ms INTEGER NOT NULL
    );
    """

  private let insertEventSQL = """
    INSERT INTO events (id, name, properties, timestamp, user_id, session_id, delivery_state)
    VALUES (?, ?, ?, ?, ?, ?, ?);
    """

  private let insertEventIfAbsentSQL = """
    INSERT OR IGNORE INTO events (id, name, properties, timestamp, user_id, session_id)
    VALUES (?, ?, ?, ?, ?, ?);
    """

  private let insertPendingEventIfAbsentSQL = """
    INSERT OR IGNORE INTO events (id, name, properties, timestamp, user_id, session_id, delivery_state)
    VALUES (?, ?, ?, ?, ?, ?, ?);
    """

  private let queryEventsSQL = """
    SELECT id, name, properties, timestamp, user_id, session_id
    FROM events
    ORDER BY timestamp DESC
    LIMIT ?;
    """

  private let queryEventByIdSQL = """
    SELECT id, name, properties, timestamp, user_id, session_id
    FROM events
    WHERE id = ?
    LIMIT 1;
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

    // Wait up to 5 seconds if database is locked
    _ = sqlite3_busy_timeout(db, 5_000)

    do {
      try prepareCurrentSchema()
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }

    // Set PRAGMAs for proper concurrency handling
    // WAL mode for better concurrent access
    _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    // Balance between safety and performance
    _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
    // Ensure referential integrity
    _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)

    LogInfo("Event database initialized at: \(dbPath)")
  }

  /// Install the complete launch schema as v1, or verify an existing v1
  /// store without mutating it. Pre-release layouts are intentionally
  /// rejected: there are no production databases to preserve.
  private func prepareCurrentSchema() throws {
    let version = try readUserVersion(targetVersion: nil)

    switch version {
    case 0:
      guard try userSchemaIsEmpty() else {
        throw schemaError(
          targetVersion: version,
          operation: "validate unversioned schema",
          code: SQLITE_SCHEMA,
          message: "Unversioned event stores are unsupported; reset local SDK data"
        )
      }
      try installCurrentSchema()
      LogInfo("Event store schema v1 installed")

    case Self.currentSchemaVersion:
      try verifyCurrentSchema()

    default:
      throw schemaError(
        targetVersion: version,
        operation: "validate user_version",
        code: SQLITE_SCHEMA,
        message: "Event-store schema v\(version) is unsupported; expected v1"
      )
    }
  }

  private func userSchemaIsEmpty() throws -> Bool {
    var stmt: OpaquePointer?
    let sql = """
      SELECT 1 FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%'
      LIMIT 1;
      """
    let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepareResult == SQLITE_OK else {
      throw schemaError(
        targetVersion: nil,
        operation: "inspect unversioned schema",
        code: prepareResult
      )
    }
    defer { sqlite3_finalize(stmt) }

    let stepResult = sqlite3_step(stmt)
    switch stepResult {
    case SQLITE_DONE:
      return true
    case SQLITE_ROW:
      return false
    default:
      throw schemaError(
        targetVersion: nil,
        operation: "inspect unversioned schema",
        code: stepResult
      )
    }
  }

  private struct TableColumn {
    let type: String
    let isNotNull: Bool
    let defaultValue: String?
    let primaryKeyPosition: Int32

    var isPrimaryKey: Bool { primaryKeyPosition != 0 }
  }

  private func installCurrentSchema() throws {
    let targetVersion = Self.currentSchemaVersion
    try executeSchemaSQL(
      "BEGIN IMMEDIATE;",
      targetVersion: targetVersion,
      operation: "begin transaction"
    )

    do {
      try executeSchemaSQL(
        createTableSQL,
        targetVersion: targetVersion,
        operation: "create events"
      )
      try executeSchemaSQL(
        createStableCaptureOutcomesSQL,
        targetVersion: targetVersion,
        operation: "create stable_event_drops"
      )
      try executeSchemaSQL(
        createHistoryMetadataSQL,
        targetVersion: targetVersion,
        operation: "create event_history_metadata"
      )
      for indexSQL in createIndexSQL {
        try executeSchemaSQL(
          indexSQL,
          targetVersion: targetVersion,
          operation: "create event index"
        )
      }
      try verifyCurrentSchema()
      try executeSchemaSQL(
        "PRAGMA user_version = \(targetVersion);",
        targetVersion: targetVersion,
        operation: "set user_version"
      )
      let recordedVersion = try readUserVersion(targetVersion: targetVersion)
      guard recordedVersion == targetVersion else {
        throw schemaError(
          targetVersion: targetVersion,
          operation: "verify user_version",
          code: SQLITE_SCHEMA,
          message: "Expected user_version \(targetVersion), found \(recordedVersion)"
        )
      }
      try executeSchemaSQL(
        "COMMIT;",
        targetVersion: targetVersion,
        operation: "commit transaction"
      )
    } catch {
      let rollbackResult = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      if rollbackResult != SQLITE_OK {
        LogError("Failed to roll back event-store schema installation: \(sqliteMessage())")
      }
      throw error
    }
  }

  private func verifyCurrentSchema() throws {
    let version = Self.currentSchemaVersion
    try verifyEventsTable(targetVersion: version)
    try verifyStableEventDropsTable(targetVersion: version)
    try verifyHistoryMetadataTable(targetVersion: version)
    let requiredIndexes: [(name: String, columns: [(String, Bool)])] = [
      ("idx_events_delivery", [("delivery_state", false), ("timestamp", false)]),
      ("idx_events_timestamp", [("timestamp", false)]),
      ("idx_events_user_id", [("user_id", false)]),
      ("idx_events_name", [("name", false)]),
      ("idx_events_session_id", [("session_id", false)]),
      (
        "idx_events_user_name_time",
        [("user_id", false), ("name", false), ("timestamp", true)]
      ),
      ("idx_events_user_time", [("user_id", false), ("timestamp", true)]),
      ("idx_events_session_time", [("session_id", false), ("timestamp", true)]),
    ]
    for indexName in requiredIndexes {
      try verifyIndex(
        named: indexName.name,
        expectedColumns: indexName.columns,
        targetVersion: version
      )
    }
  }

  private func verifyIndex(
    named indexName: String,
    expectedColumns: [(String, Bool)],
    targetVersion: Int32
  ) throws {
    guard try schemaObjectType(named: indexName, targetVersion: targetVersion) == "index" else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify \(indexName)",
        code: SQLITE_SCHEMA,
        message: "Required event-store index \(indexName) is missing"
      )
    }

    var stmt: OpaquePointer?
    let sql = """
      SELECT name, "desc"
      FROM pragma_index_xinfo(?)
      WHERE key = 1
      ORDER BY seqno;
      """
    let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepareResult == SQLITE_OK else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "inspect \(indexName)",
        code: prepareResult
      )
    }
    defer { sqlite3_finalize(stmt) }

    let bindResult = sqlite3_bind_text(stmt, 1, indexName, -1, SQLITE_TRANSIENT)
    guard bindResult == SQLITE_OK else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "inspect \(indexName)",
        code: bindResult
      )
    }

    var actualColumns: [(String, Bool)] = []
    while true {
      let stepResult = sqlite3_step(stmt)
      if stepResult == SQLITE_DONE { break }
      guard stepResult == SQLITE_ROW,
            let nameBytes = sqlite3_column_text(stmt, 0)
      else {
        throw schemaError(
          targetVersion: targetVersion,
          operation: "inspect \(indexName)",
          code: stepResult
        )
      }
      actualColumns.append((
        String(cString: nameBytes),
        sqlite3_column_int(stmt, 1) != 0
      ))
    }

    guard actualColumns.elementsEqual(
      expectedColumns,
      by: { $0.0 == $1.0 && $0.1 == $1.1 }
    ) else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify \(indexName)",
        code: SQLITE_SCHEMA,
        message: "Event-store index \(indexName) has the wrong columns or sort order"
      )
    }
  }

  private func verifyDeliveryStateColumn(targetVersion: Int32) throws {
    let columns = try tableColumns(named: "events", targetVersion: targetVersion)
    guard let deliveryState = columns["delivery_state"],
          deliveryState.type.caseInsensitiveCompare("INTEGER") == .orderedSame,
          deliveryState.isNotNull,
          deliveryState.defaultValue == "2"
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify events.delivery_state",
        code: SQLITE_SCHEMA,
        message: "events.delivery_state must be INTEGER NOT NULL DEFAULT 2"
      )
    }
  }

  private func verifyEventsTable(targetVersion: Int32) throws {
    _ = try verifyEventsBaseTable(targetVersion: targetVersion)
    try verifyDeliveryStateColumn(targetVersion: targetVersion)
  }

  @discardableResult
  private func verifyEventsBaseTable(targetVersion: Int32) throws -> [String: TableColumn] {
    guard try schemaObjectType(named: "events", targetVersion: targetVersion) == "table" else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify events",
        code: SQLITE_SCHEMA,
        message: "events is not a table"
      )
    }

    let columns = try tableColumns(named: "events", targetVersion: targetVersion)
    guard columns.count == 7,
          let id = columns["id"],
          id.type.caseInsensitiveCompare("TEXT") == .orderedSame,
          id.primaryKeyPosition == 1,
          columns.values.filter(\.isPrimaryKey).count == 1,
          let name = columns["name"],
          name.type.caseInsensitiveCompare("TEXT") == .orderedSame,
          name.isNotNull,
          let properties = columns["properties"],
          properties.type.caseInsensitiveCompare("BLOB") == .orderedSame,
          properties.isNotNull,
          let timestamp = columns["timestamp"],
          timestamp.type.caseInsensitiveCompare("INTEGER") == .orderedSame,
          timestamp.isNotNull,
          let userId = columns["user_id"],
          userId.type.caseInsensitiveCompare("TEXT") == .orderedSame,
          userId.isNotNull,
          let sessionId = columns["session_id"],
          sessionId.type.caseInsensitiveCompare("TEXT") == .orderedSame,
          !sessionId.isNotNull
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify events",
        code: SQLITE_SCHEMA,
        message: "events must exactly define id TEXT PRIMARY KEY, name TEXT NOT NULL, "
          + "properties BLOB NOT NULL, timestamp INTEGER NOT NULL, user_id TEXT NOT NULL, "
          + "nullable session_id TEXT, and delivery_state INTEGER NOT NULL DEFAULT 2"
      )
    }
    return columns
  }

  private func verifyStableEventDropsTable(targetVersion: Int32) throws {
    guard try schemaObjectType(named: "stable_event_drops", targetVersion: targetVersion)
      == "table"
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify stable_event_drops",
        code: SQLITE_SCHEMA,
        message: "stable_event_drops is not a table"
      )
    }

    let columns = try tableColumns(named: "stable_event_drops", targetVersion: targetVersion)
    guard columns.count == 2,
          let eventId = columns["event_id"],
          eventId.type.caseInsensitiveCompare("TEXT") == .orderedSame,
          eventId.primaryKeyPosition == 1,
          columns.values.filter(\.isPrimaryKey).count == 1,
          let createdAt = columns["created_at"],
          createdAt.type.caseInsensitiveCompare("INTEGER") == .orderedSame,
          createdAt.isNotNull
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify stable_event_drops",
        code: SQLITE_SCHEMA,
        message: "stable_event_drops must define event_id TEXT as its sole PRIMARY KEY "
          + "and created_at INTEGER NOT NULL"
      )
    }
  }

  private func verifyHistoryMetadataTable(targetVersion: Int32) throws {
    guard try schemaObjectType(named: "event_history_metadata", targetVersion: targetVersion)
      == "table"
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify event_history_metadata",
        code: SQLITE_SCHEMA,
        message: "event_history_metadata is not a table"
      )
    }

    let columns = try tableColumns(
      named: "event_history_metadata",
      targetVersion: targetVersion
    )
    guard columns.count == 2,
          let id = columns["id"],
          id.type.caseInsensitiveCompare("INTEGER") == .orderedSame,
          id.primaryKeyPosition == 1,
          columns.values.filter(\.isPrimaryKey).count == 1,
          let coverageStart = columns["coverage_start_ms"],
          coverageStart.type.caseInsensitiveCompare("INTEGER") == .orderedSame,
          coverageStart.isNotNull
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify event_history_metadata",
        code: SQLITE_SCHEMA,
        message: "event_history_metadata must define id INTEGER as its sole PRIMARY KEY "
          + "and coverage_start_ms INTEGER NOT NULL"
      )
    }
  }

  private func tableColumns(
    named tableName: String,
    targetVersion: Int32
  ) throws -> [String: TableColumn] {
    var stmt: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(
      db,
      "PRAGMA table_info(\(tableName));",
      -1,
      &stmt,
      nil
    )
    guard prepareResult == SQLITE_OK else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "inspect \(tableName)",
        code: prepareResult
      )
    }
    defer { sqlite3_finalize(stmt) }

    var columns: [String: TableColumn] = [:]
    while true {
      let stepResult = sqlite3_step(stmt)
      if stepResult == SQLITE_DONE {
        return columns
      }
      guard stepResult == SQLITE_ROW else {
        throw schemaError(
          targetVersion: targetVersion,
          operation: "inspect \(tableName)",
          code: stepResult
        )
      }

      guard let nameBytes = sqlite3_column_text(stmt, 1),
            let typeBytes = sqlite3_column_text(stmt, 2)
      else {
        throw schemaError(
          targetVersion: targetVersion,
          operation: "inspect \(tableName)",
          code: SQLITE_SCHEMA,
          message: "SQLite returned an incomplete column description"
        )
      }
      let name = String(cString: nameBytes)
      let defaultValue = sqlite3_column_text(stmt, 4).map(String.init(cString:))
      columns[name] = TableColumn(
        type: String(cString: typeBytes),
        isNotNull: sqlite3_column_int(stmt, 3) != 0,
        defaultValue: defaultValue,
        primaryKeyPosition: sqlite3_column_int(stmt, 5)
      )
    }
  }

  private func schemaObjectType(
    named objectName: String,
    targetVersion: Int32
  ) throws -> String? {
    var stmt: OpaquePointer?
    let sql = "SELECT type FROM sqlite_master WHERE name = ? LIMIT 1;"
    let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepareResult == SQLITE_OK else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "inspect \(objectName)",
        code: prepareResult
      )
    }
    defer { sqlite3_finalize(stmt) }

    let bindResult = sqlite3_bind_text(stmt, 1, objectName, -1, SQLITE_TRANSIENT)
    guard bindResult == SQLITE_OK else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "inspect \(objectName)",
        code: bindResult
      )
    }

    let stepResult = sqlite3_step(stmt)
    if stepResult == SQLITE_DONE {
      return nil
    }
    guard stepResult == SQLITE_ROW else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "inspect \(objectName)",
        code: stepResult
      )
    }
    return sqlite3_column_text(stmt, 0).map(String.init(cString:))
  }

  private func readUserVersion(targetVersion: Int32?) throws -> Int32 {
    var stmt: OpaquePointer?
    let prepareResult = sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil)
    guard prepareResult == SQLITE_OK else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "read user_version",
        code: prepareResult
      )
    }
    defer { sqlite3_finalize(stmt) }

    let stepResult = sqlite3_step(stmt)
    guard stepResult == SQLITE_ROW else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "read user_version",
        code: stepResult
      )
    }
    return sqlite3_column_int(stmt, 0)
  }

  private func executeSchemaSQL(
    _ sql: String,
    targetVersion: Int32,
    operation: String
  ) throws {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: operation,
        code: result
      )
    }
  }

  private func schemaError(
    targetVersion: Int32?,
    operation: String,
    code: Int32,
    message: String? = nil
  ) -> EventStorageError {
    .invalidSchema(
      EventStoreSchemaError(
        targetVersion: targetVersion,
        operation: operation,
        sqliteCode: code,
        sqliteMessage: message ?? sqliteMessage()
      )
    )
  }

  private func sqliteMessage() -> String {
    db.map { String(cString: sqlite3_errmsg($0)) } ?? "Event database is not open"
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
  func insertEventIfAbsent(
    _ event: StoredEvent,
    sql: String? = nil
  ) throws -> Bool {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(
      db,
      sql ?? insertEventIfAbsentSQL,
      -1,
      &statement,
      nil
    ) != SQLITE_OK {
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

  func insertPendingEventIfAbsent(_ event: StoredEvent) throws -> Bool {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, insertPendingEventIfAbsentSQL, -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
      )
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
    sqlite3_bind_int(statement, 7, DeliveryState.pending.rawValue)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 4, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
      )
    }
    return sqlite3_changes(db) == 1
  }

  public func insertHistoryIfAbsent(_ event: StoredEvent) async throws -> Bool {
    try insertEventIfAbsent(event)
  }

  public func queryStableCapture(
    id: String
  ) throws -> StableEventCaptureOutcome? {
    if let event = try queryEvent(id: id) {
      return .captured(event, isNew: false)
    }
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(
      db,
      "SELECT 1 FROM stable_event_drops WHERE event_id = ? LIMIT 1;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK else {
      throw EventStorageError.queryFailed(
        NSError(
          domain: "SQLite",
          code: 27,
          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
      )
    }
    sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
    return sqlite3_step(statement) == SQLITE_ROW ? .dropped : nil
  }

  public func commitStableCapture(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date
  ) throws -> StableEventCaptureOutcome {
    if let existing = try queryStableCapture(id: eventId) {
      return existing
    }
    if let event {
      let inserted = try insertPendingEventIfAbsent(event)
      guard let canonical = try queryEvent(id: eventId) else {
        throw EventStorageError.queryFailed(
          NSError(
            domain: "SQLite",
            code: 28,
            userInfo: [NSLocalizedDescriptionKey: "stable captured event disappeared"]
          )
        )
      }
      return .captured(canonical, isNew: inserted)
    }

    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(
      db,
      "INSERT OR IGNORE INTO stable_event_drops (event_id, created_at) VALUES (?, ?);",
      -1,
      &statement,
      nil
    ) == SQLITE_OK else {
      throw EventStorageError.insertFailed(
        NSError(
          domain: "SQLite",
          code: 29,
          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
      )
    }
    sqlite3_bind_text(statement, 1, eventId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(
      statement,
      2,
      Int64(recordedAt.timeIntervalSince1970 * 1_000)
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EventStorageError.insertFailed(
        NSError(
          domain: "SQLite",
          code: 30,
          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
      )
    }
    return .dropped
  }

  public func deleteStableDropsOlderThan(_ olderThan: Date) throws -> Int {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(
      db,
      "DELETE FROM stable_event_drops WHERE created_at < ?;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK else {
      throw EventStorageError.deleteFailed(
        NSError(
          domain: "SQLite",
          code: 31,
          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
      )
    }
    sqlite3_bind_int64(
      statement,
      1,
      Int64(olderThan.timeIntervalSince1970 * 1_000)
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EventStorageError.deleteFailed(
        NSError(
          domain: "SQLite",
          code: 32,
          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
      )
    }
    return Int(sqlite3_changes(db))
  }

  /// Return the canonical row for a stable event identity. Duplicate capture
  /// callers must route this persisted snapshot, rather than rebuilding the
  /// event with a new timestamp, session, or enrichment.
  public func queryEvent(id: String) throws -> StoredEvent? {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    guard sqlite3_prepare_v2(db, queryEventByIdSQL, -1, &statement, nil) == SQLITE_OK else {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 5, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }
    sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let propertiesBlob = sqlite3_column_blob(statement, 2) else {
      throw EventStorageError.invalidProperties
    }
    let propertiesData = Data(
      bytes: propertiesBlob,
      count: Int(sqlite3_column_bytes(statement, 2))
    )
    let sessionId: String? = {
      guard sqlite3_column_type(statement, 5) != SQLITE_NULL,
            let text = sqlite3_column_text(statement, 5) else { return nil }
      return String(cString: text)
    }()

    return StoredEvent(
      id: String(cString: sqlite3_column_text(statement, 0)),
      name: String(cString: sqlite3_column_text(statement, 1)),
      properties: propertiesData,
      timestamp: Date(
        timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000.0
      ),
      distinctId: String(cString: sqlite3_column_text(statement, 4)),
      sessionId: sessionId
    )
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
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW {
      return Int(sqlite3_column_int(statement, 0))
    }
    let errorMessage = String(cString: sqlite3_errmsg(db))
    throw EventStorageError.queryFailed(
      NSError(domain: "SQLite", code: 8, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
  }

  // MARK: - Durable history coverage

  public func readOrInitializeHistoryCoverage(startingAt: Date) throws -> Date {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let startingMs = Self.coverageMilliseconds(for: startingAt)
    let sql = "INSERT OR IGNORE INTO event_history_metadata (id, coverage_start_ms) VALUES (1, ?);"
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw coverageUpdateError(code: 28)
    }
    sqlite3_bind_int64(statement, 1, startingMs)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw coverageUpdateError(code: 29)
    }
    return try historyCoverageStartingAt()
  }

  public func historyCoverageStartingAt() throws -> Date {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let sql = "SELECT coverage_start_ms FROM event_history_metadata WHERE id = 1;"
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw coverageQueryError(code: 30)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw coverageQueryError(code: 31)
    }
    return Self.coverageDate(from: sqlite3_column_int64(statement, 0))
  }

  public func advanceHistoryCoverage(to startingAt: Date) throws -> Date {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let startingMs = Self.coverageMilliseconds(for: startingAt)
    let sql = """
      INSERT INTO event_history_metadata (id, coverage_start_ms)
      VALUES (1, ?)
      ON CONFLICT(id) DO UPDATE SET
        coverage_start_ms = MAX(coverage_start_ms, excluded.coverage_start_ms);
      """
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw coverageUpdateError(code: 32)
    }
    sqlite3_bind_int64(statement, 1, startingMs)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw coverageUpdateError(code: 33)
    }
    return try historyCoverageStartingAt()
  }

  public func pruneHistory(
    keeping: Int,
    olderThan: Date
  ) throws -> EventHistoryPruneResult {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    guard keeping >= 0 else {
      throw EventStorageError.deleteFailed(
        NSError(domain: "SQLite", code: 34, userInfo: [NSLocalizedDescriptionKey: "Negative retention cap"]))
    }
    // Refuse to prune until an explicit conservative origin exists. Guessing a
    // boundary after deletion would make a legacy gap look complete.
    _ = try historyCoverageStartingAt()
    try executeCoverageSQL("BEGIN IMMEDIATE TRANSACTION;", code: 35)

    do {
      let cutoffMs = Self.coverageMilliseconds(for: olderThan)
      let ageDeleted = try deleteAgedDeliveredEvents(olderThanMs: cutoffMs)

      let totalAfterAge = try scalarCount("SELECT COUNT(*) FROM events;", code: 36)
      let requestedCountDeletes = max(0, totalAfterAge - keeping)
      let countPrune = try deleteOldestDeliveredEventsForCoverage(
        limit: requestedCountDeletes
      )

      var candidateMs: Int64?
      if ageDeleted > 0 { candidateMs = cutoffMs }
      if let countBoundaryMs = countPrune.boundaryMs {
        candidateMs = max(candidateMs ?? Int64.min, countBoundaryMs)
      }
      if let candidateMs {
        try updateCoverageWithinTransaction(to: candidateMs)
      }
      let coverage = try historyCoverageStartingAt()
      try executeCoverageSQL("COMMIT;", code: 37)
      return EventHistoryPruneResult(
        countDeleted: countPrune.deleted,
        ageDeleted: ageDeleted,
        coverageStartingAt: coverage
      )
    } catch {
      _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      throw error
    }
  }

  private func deleteAgedDeliveredEvents(olderThanMs: Int64) throws -> Int {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let sql = "DELETE FROM events WHERE timestamp < ? AND delivery_state = ?;"
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw coverageDeleteError(code: 38)
    }
    sqlite3_bind_int64(statement, 1, olderThanMs)
    sqlite3_bind_int(statement, 2, DeliveryState.delivered.rawValue)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw coverageDeleteError(code: 39)
    }
    return Int(sqlite3_changes(db))
  }

  /// Returns the first excluded millisecond after the newest count-pruned row.
  private func deleteOldestDeliveredEventsForCoverage(
    limit: Int
  ) throws -> (boundaryMs: Int64?, deleted: Int) {
    guard limit > 0 else { return (nil, 0) }
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let boundarySQL = """
      SELECT MAX(timestamp) FROM (
        SELECT timestamp FROM events
        WHERE delivery_state = ?
        ORDER BY timestamp ASC, id ASC
        LIMIT ?
      );
      """
    var boundaryStatement: OpaquePointer?
    defer { sqlite3_finalize(boundaryStatement) }
    guard sqlite3_prepare_v2(db, boundarySQL, -1, &boundaryStatement, nil) == SQLITE_OK else {
      throw coverageQueryError(code: 40)
    }
    sqlite3_bind_int(boundaryStatement, 1, DeliveryState.delivered.rawValue)
    sqlite3_bind_int64(boundaryStatement, 2, Int64(limit))
    guard sqlite3_step(boundaryStatement) == SQLITE_ROW else {
      throw coverageQueryError(code: 41)
    }
    guard sqlite3_column_type(boundaryStatement, 0) != SQLITE_NULL else { return (nil, 0) }
    let newestDeletedMs = sqlite3_column_int64(boundaryStatement, 0)

    let deleteSQL = """
      DELETE FROM events WHERE id IN (
        SELECT id FROM events
        WHERE delivery_state = ?
        ORDER BY timestamp ASC, id ASC
        LIMIT ?
      );
      """
    var deleteStatement: OpaquePointer?
    defer { sqlite3_finalize(deleteStatement) }
    guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
      throw coverageDeleteError(code: 42)
    }
    sqlite3_bind_int(deleteStatement, 1, DeliveryState.delivered.rawValue)
    sqlite3_bind_int64(deleteStatement, 2, Int64(limit))
    guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
      throw coverageDeleteError(code: 43)
    }
    let deleted = Int(sqlite3_changes(db))
    guard deleted > 0 else { return (nil, 0) }
    let boundary = newestDeletedMs == Int64.max ? Int64.max : newestDeletedMs + 1
    return (boundary, deleted)
  }

  private func updateCoverageWithinTransaction(to startingMs: Int64) throws {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let sql = """
      UPDATE event_history_metadata
      SET coverage_start_ms = MAX(coverage_start_ms, ?)
      WHERE id = 1;
      """
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw coverageUpdateError(code: 44)
    }
    sqlite3_bind_int64(statement, 1, startingMs)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw coverageUpdateError(code: 45)
    }
  }

  private func scalarCount(_ sql: String, code: Int) throws -> Int {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_ROW
    else { throw coverageQueryError(code: code) }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func executeCoverageSQL(_ sql: String, code: Int) throws {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw coverageUpdateError(code: code)
    }
  }

  private func coverageQueryError(code: Int) -> EventStorageError {
    EventStorageError.queryFailed(sqliteError(code: code))
  }

  private func coverageUpdateError(code: Int) -> EventStorageError {
    EventStorageError.updateFailed(sqliteError(code: code))
  }

  private func coverageDeleteError(code: Int) -> EventStorageError {
    EventStorageError.deleteFailed(sqliteError(code: code))
  }

  private func sqliteError(code: Int) -> NSError {
    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Database not initialized"
    return NSError(
      domain: "SQLite",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private static func coverageMilliseconds(for date: Date) -> Int64 {
    let raw = date.timeIntervalSince1970 * 1_000
    if raw >= Double(Int64.max) { return Int64.max }
    if raw <= Double(Int64.min) { return Int64.min }
    return Int64(raw.rounded(.up))
  }

  private static func coverageDate(from milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
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
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW {
      return sqlite3_column_int(statement, 0) != 0
    }
    let errorMessage = String(cString: sqlite3_errmsg(db))
    throw EventStorageError.queryFailed(
      NSError(domain: "SQLite", code: 9, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
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
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW {
      return Int(sqlite3_column_int(statement, 0))
    }
    let errorMessage = String(cString: sqlite3_errmsg(db))
    throw EventStorageError.queryFailed(
      NSError(domain: "SQLite", code: 10, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
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
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW {
      if sqlite3_column_type(statement, 0) == SQLITE_NULL {
        return nil
      }
      let timestampMs = sqlite3_column_int64(statement, 0)
      return Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
    }

    let errorMessage = String(cString: sqlite3_errmsg(db))
    throw EventStorageError.queryFailed(
      NSError(domain: "SQLite", code: 11, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
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
    sqlite3_bind_int64(statement, bindIndex, Int64(limit))

    var events: [StoredEvent] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        let errorMessage = String(cString: sqlite3_errmsg(db))
        throw EventStorageError.queryFailed(
          NSError(
            domain: "SQLite",
            code: 25,
            userInfo: [NSLocalizedDescriptionKey: errorMessage]
          )
        )
      }
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

    let result = sqlite3_step(statement)
    if result == SQLITE_ROW {
      guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
      return Date(
        timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000.0
      )
    }
    let errorMessage = String(cString: sqlite3_errmsg(db))
    throw EventStorageError.queryFailed(
      NSError(domain: "SQLite", code: 26, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
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
    sqlite3_bind_int64(statement, 2, Int64(limit))

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
      ORDER BY timestamp ASC, id ASC
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
    sqlite3_bind_int64(statement, 2, Int64(limit))

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

  public func getPendingDeliveryCount() throws -> Int {
    guard let db = db else {
      throw EventStorageError.databaseNotInitialized
    }

    let sql = "SELECT COUNT(*) FROM events WHERE delivery_state = ?;"
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 25, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    sqlite3_bind_int(statement, 1, DeliveryState.pending.rawValue)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      throw EventStorageError.queryFailed(
        NSError(domain: "SQLite", code: 26, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }

    return Int(sqlite3_column_int64(statement, 0))
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

  public func insertPendingIfAbsent(_ event: StoredEvent) throws -> Bool {
    try insertPendingEventIfAbsent(event)
  }
}
