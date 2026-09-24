import Foundation
import SQLite3

// SQLite constants for Swift
private let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StableEventCaptureOutcome: Sendable {
  case captured(StoredEvent, isNew: Bool)
  case dropped
}

enum EventDeliveryState: Int32, Sendable {
  case pending = 0
  case delivered = 2
}

struct EventHistoryPruneResult: Equatable, Sendable {
  let countDeleted: Int
  let ageDeleted: Int
  let coverageStartingAt: Date
}

struct PendingConversionOccurrence: Sendable {
  static let retentionMillis = 120 * 86_400_000
  let event: StoredEvent
  let acceptedAt: Date
}

struct EventStoreInsertCommit: Sendable {
  let newlyDurable: Bool
  let commitSequence: UInt64?
}

/// Process-local subscriber authority captured before asynchronous enrichment.
/// Stable receipts and the conversion inbox independently survive a restart.
struct CommittedRouteAdmission: Codable, Sendable, Equatable {
  let sessionId: String
  let subscribers: [UInt64: UInt64]
  let stableRouteEventId: String?
}

struct PendingCommittedRouteDelivery: Sendable {
  let event: StoredEvent
  let admission: CommittedRouteAdmission
  var nextSubscriber: Int
}

struct StableEventCaptureCommit: Sendable {
  let outcome: StableEventCaptureOutcome
  let commitSequence: UInt64?
  /// True while this canonical capture still owns local subscriber delivery.
  /// The receipt is cleared only after every committed subscriber returns.
  let localRoutePending: Bool

  init(
    outcome: StableEventCaptureOutcome,
    commitSequence: UInt64?,
    localRoutePending: Bool = false
  ) {
    self.outcome = outcome
    self.commitSequence = commitSequence
    self.localRoutePending = localRoutePending
  }
}

struct StableEventCaptureRecord: Sendable {
  let eventId: String
  let event: StoredEvent?
  let recordedAt: Date
}

enum StableEventCaptureCommitAdmissionError: Error {
  case rejected
}

/// A synchronous fence wrapped around the event store's terminal mutation.
/// The store invokes this only after every suspending enrichment step, so a
/// revoked caller cannot publish while identity or execution authority moves.
protocol StableEventCaptureCommitAdmission: Sendable {
  func commitIfCurrent(
    _ commit: () throws -> StableEventCaptureCommit
  ) rethrows -> StableEventCaptureCommit?
}

/// The same terminal fence applied once around a complete stable-event batch.
/// The storage implementation must commit every returned outcome or none of
/// them so callers never publish a prefix and then reuse the batch identity.
protocol StableEventCaptureBatchCommitAdmission:
  StableEventCaptureCommitAdmission
{
  func commitBatchIfCurrent(
    _ commit: () throws -> [StableEventCaptureCommit]
  ) rethrows -> [StableEventCaptureCommit]?
}

/// Persistence surface the event log writes through. One implementation
/// (SQLite) in production; mocks in tests.
protocol ConversionOccurrenceQueue: Sendable {
  func bindConversionAuthority(_ scope: JourneyStorageScope) async throws
  func pendingConversionOccurrences(distinctId: String, limit: Int, throughEventId: String?) async throws -> [PendingConversionOccurrence]
  func acknowledgeConversionOccurrence(eventId: String, distinctId: String) async throws
}

protocol EventStoreProtocol: ConversionOccurrenceQueue {
  func pruneConversionOccurrences(at: Date) async throws -> Int
  func initialize(path: URL?) async throws
  func reset() async
  func close() async

  /// Insert the canonical captured record unless its stable id already
  /// exists. When requested, the store assigns a sequence under the same
  /// serialization that determines commit order.
  func insert(
    _ event: StoredEvent,
    deliveryState: EventDeliveryState,
    origin: StoredEventOrigin,
    assigningCommitSequence: Bool,
    acceptedAt: Date,
    routeAdmission: CommittedRouteAdmission?
  ) async throws -> EventStoreInsertCommit
  func firstPendingCommittedRoute(sessionId: String) async throws -> PendingCommittedRouteDelivery?
  func checkpointCommittedRoute(eventId: String, sessionId: String, nextSubscriber: Int) async throws
  func acknowledgeCommittedRoute(eventId: String, sessionId: String) async throws
  func discardOtherCommittedRouteSessions(keeping sessionId: String) async throws

  /// Read or atomically establish the terminal outcome for a stable event ID.
  /// A dropped outcome is deliberately separate from event history/delivery.
  func queryStableCapture(id: String) async throws -> StableEventCaptureOutcome?
  func commitStableCapture(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date,
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureCommitAdmission)?
  ) async throws -> StableEventCaptureCommit
  func commitStableCaptureBatch(
    _ records: [StableEventCaptureRecord],
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureBatchCommitAdmission)?
  ) async throws -> [StableEventCaptureCommit]
  /// Stable capture plus its local-route outbox insertion, committed as one
  /// storage transaction. Replays return whether the existing outbox remains
  /// pending so a new process can resume subscriber delivery.
  func commitStableCaptureAndStageRoute(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date,
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureCommitAdmission)?
  ) async throws -> StableEventCaptureCommit
  func commitStableCaptureBatchAndStageRoutes(
    _ records: [StableEventCaptureRecord],
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureBatchCommitAdmission)?
  ) async throws -> [StableEventCaptureCommit]
  func queryPendingStableRoutes(
    distinctId: String, limit: Int
  ) async throws -> [StoredEvent]
  /// Visits the pending prefix present when recovery starts, loading at most
  /// one page at a time. Returning false leaves later routes pending.
  func visitPendingStableRoutes(
    distinctId: String,
    visitor: @escaping @Sendable (StoredEvent) async -> Bool
  ) async throws -> Bool
  func markStableRouteDelivered(eventId: String) async throws
  @discardableResult
  func deleteStableDropsOlderThan(_ olderThan: Date) async throws -> Int

  func queryRecentEvents(limit: Int) async throws -> [StoredEvent]
  func queryEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent]
  func queryEventsForUser(
    _ distinctId: String, name: String, since: Date?, until: Date?,
    ascending: Bool, limit: Int
  ) async throws -> [StoredEvent]
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

extension EventStoreProtocol {
  func insert(_ event: StoredEvent, deliveryState: EventDeliveryState,
              origin: StoredEventOrigin, assigningCommitSequence: Bool,
              acceptedAt: Date) async throws -> EventStoreInsertCommit {
    try await insert(event, deliveryState: deliveryState, origin: origin,
                     assigningCommitSequence: assigningCommitSequence,
                     acceptedAt: acceptedAt, routeAdmission: nil)
  }

  func insert(_ event: StoredEvent, deliveryState: EventDeliveryState,
              origin: StoredEventOrigin, assigningCommitSequence: Bool) async throws -> EventStoreInsertCommit {
    try await insert(event, deliveryState: deliveryState, origin: origin,
                     assigningCommitSequence: assigningCommitSequence, acceptedAt: Date())
  }

  func insert(
    _ event: StoredEvent,
    deliveryState: EventDeliveryState,
    origin: StoredEventOrigin = .device
  ) async throws -> Bool {
    try await insert(
      event,
      deliveryState: deliveryState,
      origin: origin,
      assigningCommitSequence: false
    ).newlyDurable
  }

  func commitStableCapture(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date
  ) async throws -> StableEventCaptureOutcome {
    try await commitStableCapture(
      eventId: eventId,
      event: event,
      recordedAt: recordedAt,
      assigningCommitSequence: false,
      admission: nil
    ).outcome
  }
}

/// SQLite-based event storage implementation
/// Thread safety: Guaranteed by actor isolation
actor SQLiteEventStore: EventStoreProtocol {

  // MARK: - Properties

  private static let currentSchemaVersion: Int32 = 3

  // nonisolated(unsafe): accessed from the actor's methods (isolated) and
  // from deinit, which has exclusive access to the last reference.
  private nonisolated(unsafe) var db: OpaquePointer?
  private(set) var dbPath: String?
  private var nextCommitSequence: UInt64 = 0
  private let conversionCaptureScope: String

  // MARK: - SQL Statements

  private let createTableSQL = """
    CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        properties BLOB NOT NULL,
        timestamp INTEGER NOT NULL,
        user_id TEXT NOT NULL,
        delivery_state INTEGER NOT NULL DEFAULT 2,
        origin TEXT NOT NULL DEFAULT 'device'
    );
    """

  private let createIndexSQL = [
    "CREATE INDEX IF NOT EXISTS idx_events_delivery ON events(delivery_state, timestamp);",
    "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_id ON events(user_id);",
    "CREATE INDEX IF NOT EXISTS idx_events_name ON events(name);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_name_time ON events(user_id, name, timestamp DESC);",
    "CREATE INDEX IF NOT EXISTS idx_events_user_time ON events(user_id, timestamp DESC);",
  ]

  private let createStableCaptureOutcomesSQL = """
    CREATE TABLE IF NOT EXISTS stable_event_drops (
      event_id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    );
    """

  private let createStableEventRoutesSQL = """
    CREATE TABLE IF NOT EXISTS stable_event_routes (
      event_id TEXT PRIMARY KEY,
      delivery_state INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
    );
    """

  private let createConversionInboxSQL = """
    CREATE TABLE conversion_event_inbox (
      event_id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      payload BLOB NOT NULL,
      accepted_at INTEGER NOT NULL,
      scope TEXT NOT NULL
    );
    CREATE INDEX idx_conversion_inbox_user ON conversion_event_inbox(scope, user_id);
    CREATE INDEX idx_conversion_inbox_expiry ON conversion_event_inbox(scope, accepted_at);
    CREATE TABLE conversion_scope_bindings (
      capture_scope TEXT PRIMARY KEY,
      authority_scope TEXT NOT NULL
    );
    CREATE TABLE committed_route_deliveries (
      event_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      commit_sequence INTEGER NOT NULL,
      admission BLOB NOT NULL,
      next_subscriber INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_committed_routes_session ON committed_route_deliveries(session_id, commit_sequence);
    """

  private let createHistoryMetadataSQL = """
    CREATE TABLE IF NOT EXISTS event_history_metadata (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      coverage_start_ms INTEGER NOT NULL
    );
    """

  private let insertEventSQL = """
    INSERT OR IGNORE INTO events (
      id, name, properties, timestamp, user_id, delivery_state, origin
    ) VALUES (?, ?, ?, ?, ?, ?, ?);
    """

  private let queryEventsSQL = """
    SELECT id, name, properties, timestamp, user_id
    FROM events
    ORDER BY timestamp DESC
    LIMIT ?;
    """

  private let queryEventByIdSQL = """
    SELECT id, name, properties, timestamp, user_id
    FROM events
    WHERE id = ?
    LIMIT 1;
    """

  private let countEventsSQL = "SELECT COUNT(*) FROM events;"

  // MARK: - Initialization

  public init(conversionCaptureScope: String = "test-fixture") {
    self.conversionCaptureScope = "capture-" + conversionCaptureScope
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

  /// Add the conversion inbox to the established event store without changing
  /// retained events. Retired runtime layouts and unknown future versions are
  /// rejected without mutation.
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
      LogInfo("Event store schema v3 installed")


    case 2:
      // Preserve ordinary event and purchase evidence; this upgrade does not
      // revive any retired Journey contracts or infer conversions from history.
      try verifySchemaObjects(targetVersion: 2)
      try executeSchemaSQL("BEGIN IMMEDIATE;", targetVersion: 3, operation: "begin conversion inbox upgrade")
      do {
        try executeSchemaSQL(createConversionInboxSQL, targetVersion: 3, operation: "create conversion inbox")
        try verifyCurrentSchema()
        try executeSchemaSQL("PRAGMA user_version = 3; COMMIT;", targetVersion: 3, operation: "commit conversion inbox upgrade")
      } catch {
        _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        throw error
      }

    // Pre-GA hard cut: old event stores are deliberately unsupported. There
    // is no migration path from the retired journey ownership protocol.
    case Self.currentSchemaVersion:
      try verifyCurrentSchema()

    default:
      throw schemaError(
        targetVersion: version,
        operation: "validate user_version",
        code: SQLITE_SCHEMA,
        message: "Event-store schema v\(version) is unsupported; expected v3"
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
        createStableEventRoutesSQL,
        targetVersion: targetVersion,
        operation: "create stable_event_routes"
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
      try executeSchemaSQL(createConversionInboxSQL, targetVersion: targetVersion, operation: "create conversion inbox")
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
    try verifySchemaObjects(targetVersion: version)
  }

  private func verifySchemaObjects(targetVersion: Int32) throws {
    let version = targetVersion
    try verifyEventsTable(targetVersion: version)
    try verifyStableEventDropsTable(targetVersion: version)
    try verifyStableEventRoutesTable(targetVersion: version)
    try verifyHistoryMetadataTable(targetVersion: version)
    if version >= 3 {
      let routes = try tableColumns(named: "committed_route_deliveries", targetVersion: version)
      guard routes.count == 5, routes["event_id"]?.primaryKeyPosition == 1,
            routes["session_id"]?.isNotNull == true, routes["commit_sequence"]?.type == "INTEGER",
            routes["admission"]?.type == "BLOB", routes["next_subscriber"]?.type == "INTEGER" else {
        throw schemaError(targetVersion: version, operation: "verify committed routing", code: SQLITE_SCHEMA,
                          message: "Invalid committed route delivery queue")
      }
      try verifyIndex(named: "idx_committed_routes_session", expectedColumns: [("session_id", false), ("commit_sequence", false)], targetVersion: version)
      let columns = try tableColumns(named: "conversion_event_inbox", targetVersion: version)
      guard columns.count == 5, columns["scope"]?.type == "TEXT", columns["scope"]?.isNotNull == true,
            columns["event_id"]?.primaryKeyPosition == 1,
            columns["event_id"]?.type == "TEXT", columns["user_id"]?.type == "TEXT",
            columns["user_id"]?.isNotNull == true, columns["payload"]?.type == "BLOB",
            columns["payload"]?.isNotNull == true, columns["accepted_at"]?.type == "INTEGER",
            columns["accepted_at"]?.isNotNull == true else {
        throw schemaError(targetVersion: version, operation: "verify conversion inbox", code: SQLITE_SCHEMA,
                          message: "Invalid durable conversion inbox")
      }
      try verifyIndex(named: "idx_conversion_inbox_user", expectedColumns: [("scope", false), ("user_id", false)], targetVersion: version)
      try verifyIndex(named: "idx_conversion_inbox_expiry", expectedColumns: [("scope", false), ("accepted_at", false)], targetVersion: version)
      let bindings = try tableColumns(named: "conversion_scope_bindings", targetVersion: version)
      guard bindings.count == 2, bindings["capture_scope"]?.type == "TEXT",
            bindings["capture_scope"]?.primaryKeyPosition == 1,
            bindings["authority_scope"]?.type == "TEXT", bindings["authority_scope"]?.isNotNull == true else {
        throw schemaError(targetVersion: version, operation: "verify conversion scope", code: SQLITE_SCHEMA,
                          message: "Invalid authenticated conversion scope bindings")
      }
    }
    let requiredIndexes: [(name: String, columns: [(String, Bool)])] = [
      ("idx_events_delivery", [("delivery_state", false), ("timestamp", false)]),
      ("idx_events_timestamp", [("timestamp", false)]),
      ("idx_events_user_id", [("user_id", false)]),
      ("idx_events_name", [("name", false)]),
      (
        "idx_events_user_name_time",
        [("user_id", false), ("name", false), ("timestamp", true)]
      ),
      ("idx_events_user_time", [("user_id", false), ("timestamp", true)]),
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
    let columns = try verifyEventsBaseTable(targetVersion: targetVersion)
    try verifyDeliveryStateColumn(targetVersion: targetVersion)
    guard let origin = columns["origin"],
          origin.type.caseInsensitiveCompare("TEXT") == .orderedSame,
          origin.isNotNull,
          origin.defaultValue == "'device'"
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify events.origin",
        code: SQLITE_SCHEMA,
        message: "events.origin must be TEXT NOT NULL DEFAULT 'device'"
      )
    }
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
          columns["origin"] != nil
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify events",
        code: SQLITE_SCHEMA,
        message: "events must exactly define id TEXT PRIMARY KEY, name TEXT NOT NULL, "
          + "properties BLOB NOT NULL, timestamp INTEGER NOT NULL, user_id TEXT NOT NULL, "
          + "delivery_state INTEGER NOT NULL DEFAULT 2, and origin TEXT NOT NULL DEFAULT 'device'"
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

  private func verifyStableEventRoutesTable(targetVersion: Int32) throws {
    guard try schemaObjectType(
      named: "stable_event_routes",
      targetVersion: targetVersion
    ) == "table" else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify stable_event_routes",
        code: SQLITE_SCHEMA,
        message: "stable_event_routes is not a table"
      )
    }
    let columns = try tableColumns(
      named: "stable_event_routes",
      targetVersion: targetVersion
    )
    guard columns.count == 2,
          let eventId = columns["event_id"],
          eventId.type.caseInsensitiveCompare("TEXT") == .orderedSame,
          eventId.primaryKeyPosition == 1,
          columns.values.filter(\.isPrimaryKey).count == 1,
          let deliveryState = columns["delivery_state"],
          deliveryState.type.caseInsensitiveCompare("INTEGER") == .orderedSame,
          deliveryState.isNotNull,
          deliveryState.defaultValue == "0"
    else {
      throw schemaError(
        targetVersion: targetVersion,
        operation: "verify stable_event_routes",
        code: SQLITE_SCHEMA,
        message: "stable_event_routes must define event_id TEXT PRIMARY KEY and "
          + "delivery_state INTEGER NOT NULL DEFAULT 0"
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
    nextCommitSequence = 0
  }

  // MARK: - Event Operations

  /// Insert a new event into the database, or validate an existing stable id.
  /// The ignored path compares the canonical stored bytes so a legitimate
  /// replay remains benign while a conflicting reuse is diagnosed.
  public func insert(
    _ event: StoredEvent,
    deliveryState: EventDeliveryState,
    origin: StoredEventOrigin,
    assigningCommitSequence: Bool,
    acceptedAt: Date = Date(),
    routeAdmission: CommittedRouteAdmission? = nil
  ) throws -> EventStoreInsertCommit {
    guard db != nil else { throw EventStorageError.databaseNotInitialized }
    let previousSequence = nextCommitSequence
    try executeSchemaSQL("SAVEPOINT capture_with_conversion;", targetVersion: 3, operation: "begin capture")
    do {
      let result = try insertWithConversion(event, deliveryState: deliveryState, origin: origin,
                                           assigningCommitSequence: assigningCommitSequence, acceptedAt: acceptedAt)
      if result.newlyDurable, let routeAdmission {
        guard let sequence = result.commitSequence else { throw EventStorageError.invalidProperties }
        try stageCommittedRoute(eventId: event.id, sequence: sequence, admission: routeAdmission)
      }
      try executeSchemaSQL("RELEASE capture_with_conversion;", targetVersion: 3, operation: "commit capture")
      return result
    } catch {
      _ = sqlite3_exec(db, "ROLLBACK TO capture_with_conversion; RELEASE capture_with_conversion;", nil, nil, nil)
      nextCommitSequence = previousSequence
      throw error
    }
  }

  private func withCommittedRouteStatement<T>(
    _ sql: String, _ body: (OpaquePointer?) throws -> T
  ) throws -> T {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.queryFailed(NSError(domain: "Nuxie.EventStore", code: 71,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]))
    }
    return try body(statement)
  }

  private func stageCommittedRoute(
    eventId: String, sequence: UInt64, admission: CommittedRouteAdmission
  ) throws {
    guard sequence <= UInt64(Int64.max) else { throw EventStorageError.invalidProperties }
    let bytes = try JSONEncoder().encode(admission)
    try withCommittedRouteStatement("INSERT OR IGNORE INTO committed_route_deliveries(event_id, session_id, commit_sequence, admission) VALUES (?, ?, ?, ?);") { statement in
      sqlite3_bind_text(statement, 1, eventId, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(statement, 2, admission.sessionId, -1, SQLITE_TRANSIENT)
      sqlite3_bind_int64(statement, 3, Int64(sequence))
      _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT) }
      guard sqlite3_step(statement) == SQLITE_DONE else { throw EventStorageError.invalidProperties }
    }
  }

  public func firstPendingCommittedRoute(sessionId: String) throws -> PendingCommittedRouteDelivery? {
    try withCommittedRouteStatement("SELECT event_id, admission, next_subscriber FROM committed_route_deliveries WHERE session_id = ? ORDER BY commit_sequence LIMIT 1;") { statement in
      sqlite3_bind_text(statement, 1, sessionId, -1, SQLITE_TRANSIENT)
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return nil }
      guard result == SQLITE_ROW, let id = sqlite3_column_text(statement, 0),
            let blob = sqlite3_column_blob(statement, 1) else { throw EventStorageError.invalidProperties }
      let eventId = String(cString: id)
      let bytes = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
      let admission = try JSONDecoder().decode(CommittedRouteAdmission.self, from: bytes)
      let nextSubscriber = Int(sqlite3_column_int64(statement, 2))
      guard admission.sessionId == sessionId, nextSubscriber >= 0,
            let event = try queryEvent(id: eventId) else { throw EventStorageError.invalidProperties }
      return PendingCommittedRouteDelivery(event: event, admission: admission, nextSubscriber: nextSubscriber)
    }
  }

  public func checkpointCommittedRoute(eventId: String, sessionId: String, nextSubscriber: Int) throws {
    guard nextSubscriber >= 0 else { throw EventStorageError.invalidProperties }
    try withCommittedRouteStatement("UPDATE committed_route_deliveries SET next_subscriber = ? WHERE event_id = ? AND session_id = ?;") { statement in
      sqlite3_bind_int64(statement, 1, Int64(nextSubscriber))
      sqlite3_bind_text(statement, 2, eventId, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(statement, 3, sessionId, -1, SQLITE_TRANSIENT)
      guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw EventStorageError.invalidProperties }
    }
  }

  public func acknowledgeCommittedRoute(eventId: String, sessionId: String) throws {
    try withCommittedRouteStatement("DELETE FROM committed_route_deliveries WHERE event_id = ? AND session_id = ?;") { statement in
      sqlite3_bind_text(statement, 1, eventId, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(statement, 2, sessionId, -1, SQLITE_TRANSIENT)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw EventStorageError.invalidProperties }
    }
  }

  public func discardOtherCommittedRouteSessions(keeping sessionId: String) throws {
    try withCommittedRouteStatement("DELETE FROM committed_route_deliveries WHERE session_id != ?;") { statement in
      sqlite3_bind_text(statement, 1, sessionId, -1, SQLITE_TRANSIENT)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw EventStorageError.invalidProperties }
    }
  }

  private func insertWithConversion(
    _ event: StoredEvent, deliveryState: EventDeliveryState, origin: StoredEventOrigin,
    assigningCommitSequence: Bool, acceptedAt: Date
  ) throws -> EventStoreInsertCommit {
    LogDebug("SQLiteEventStore.insert - id: \(event.id), name: \(event.name)")
    
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

    sqlite3_bind_int64(statement, 4, try Self.historyMilliseconds(for: event.timestamp, rounding: .down))  // Store as milliseconds

    sqlite3_bind_text(statement, 5, event.distinctId, -1, SQLITE_TRANSIENT)

    sqlite3_bind_int(statement, 6, deliveryState.rawValue)
    sqlite3_bind_text(statement, 7, origin.rawValue, -1, SQLITE_TRANSIENT)

    // Execute
    if sqlite3_step(statement) != SQLITE_DONE {
      let errorMessage = String(cString: sqlite3_errmsg(db))
      LogError("Failed to execute insert statement: \(errorMessage)")
      throw EventStorageError.insertFailed(
        NSError(domain: "SQLite", code: 4, userInfo: [NSLocalizedDescriptionKey: errorMessage]))
    }
    
    let newlyDurable = sqlite3_changes(db) == 1
    if newlyDurable {
      try stageConversionOccurrence(event, acceptedAt: acceptedAt)
      LogDebug("Successfully inserted event into database: \(event.name)")
    } else {
      guard let stored = try queryEvent(id: event.id) else {
        throw EventStorageError.queryFailed(
          NSError(
            domain: "SQLite",
            code: 48,
            userInfo: [NSLocalizedDescriptionKey: "Ignored event row disappeared"]
          )
        )
      }
      if !stored.isByteEquivalent(to: event) {
        LogError(
          "Event id collision for \(event.id): stored '\(stored.name)', attempted '\(event.name)'"
        )
      }
    }
    return EventStoreInsertCommit(
      newlyDurable: newlyDurable,
      commitSequence: takeCommitSequence(if: assigningCommitSequence)
    )
  }

  /// The retained horizon includes the longest attribution window and accepted
  /// offline backdating. Expiring measurement never deletes analytics or delivery.
  func pruneConversionOccurrences(at now: Date) throws -> Int {
    guard db != nil else { throw EventStorageError.databaseNotInitialized }
    let millis = try Self.historyMilliseconds(for: now, rounding: .toNearestOrAwayFromZero)
    let floor = millis.subtractingReportingOverflow(Int64(PendingConversionOccurrence.retentionMillis))
    guard !floor.overflow else { throw EventStorageError.invalidProperties }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "DELETE FROM conversion_event_inbox WHERE scope = ? AND accepted_at < ?;", -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 66))
    }
    sqlite3_bind_text(statement, 1, try conversionScope(), -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(statement, 2, floor.partialValue)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 67)) }
    return Int(sqlite3_changes(db))
  }

  private func conversionScope() throws -> String {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT authority_scope FROM conversion_scope_bindings WHERE capture_scope = ?;", -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.invalidProperties
    }
    sqlite3_bind_text(statement, 1, conversionCaptureScope, -1, SQLITE_TRANSIENT)
    switch sqlite3_step(statement) {
    case SQLITE_DONE: return conversionCaptureScope
    case SQLITE_ROW:
      guard let text = sqlite3_column_text(statement, 0) else { throw EventStorageError.invalidProperties }
      return String(cString: text)
    default: throw EventStorageError.invalidProperties
    }
  }

  /// Called only with profile-authenticated authority. The mapping is immutable:
  /// a credential cannot move old captures to another app or environment.
  func bindConversionAuthority(_ scope: JourneyStorageScope) throws {
    guard db != nil else { throw EventStorageError.databaseNotInitialized }
    try executeSchemaSQL("SAVEPOINT bind_conversion_scope;", targetVersion: 3, operation: "begin scope binding")
    do {
      let existing = try conversionScope()
      let target = scope.conversionNamespace
      guard existing == conversionCaptureScope || existing == target else { throw EventStorageError.invalidProperties }
      for sql in [
        "INSERT OR IGNORE INTO conversion_scope_bindings(authority_scope, capture_scope) VALUES (?1, ?2);",
        "UPDATE conversion_event_inbox SET scope = ?1 WHERE scope = ?2;"
      ] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw EventStorageError.invalidProperties }
        sqlite3_bind_text(statement, 1, target, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, conversionCaptureScope, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw EventStorageError.invalidProperties }
      }
      try executeSchemaSQL("RELEASE bind_conversion_scope;", targetVersion: 3, operation: "commit scope binding")
    } catch {
      _ = sqlite3_exec(db, "ROLLBACK TO bind_conversion_scope; RELEASE bind_conversion_scope;", nil, nil, nil)
      throw error
    }
  }

  func pendingConversionOccurrences(distinctId: String, limit: Int = 100, throughEventId: String? = nil) throws -> [PendingConversionOccurrence] {
    guard db != nil else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let cutoff = throughEventId == nil ? "" : " AND rowid <= (SELECT rowid FROM conversion_event_inbox WHERE event_id = ?4 AND user_id = ?1 AND scope = ?2)"
    let sql = "SELECT payload, accepted_at FROM conversion_event_inbox WHERE user_id = ?1 AND scope = ?2" + cutoff + " ORDER BY rowid LIMIT ?3;"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 62))
    }
    sqlite3_bind_text(statement, 1, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, try conversionScope(), -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(statement, 3, Int32(max(1, min(limit, 1000))))
    if let throughEventId { sqlite3_bind_text(statement, 4, throughEventId, -1, SQLITE_TRANSIENT) }
    var result: [PendingConversionOccurrence] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return result }
      guard status == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else {
        throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 63))
      }
      let bytes = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
      let event = try ExactJSONCodec.decode(StoredEvent.self, from: bytes)
      guard event.distinctId == distinctId else { throw EventStorageError.invalidProperties }
      result.append(.init(event: event,
        acceptedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000)))
    }
  }

  func acknowledgeConversionOccurrence(eventId: String, distinctId: String) throws {
    guard db != nil else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "DELETE FROM conversion_event_inbox WHERE event_id = ? AND user_id = ? AND scope = ?;", -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 64))
    }
    sqlite3_bind_text(statement, 1, eventId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 3, try conversionScope(), -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 65))
    }
  }

  private func stageConversionOccurrence(_ event: StoredEvent, acceptedAt: Date) throws {
    _ = try pruneConversionOccurrences(at: acceptedAt)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let sql = "INSERT OR IGNORE INTO conversion_event_inbox(event_id, user_id, payload, accepted_at, scope) VALUES (?, ?, ?, ?, ?);"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 60))
    }
    let payload = try ExactJSONCodec.encode(event)
    sqlite3_bind_text(statement, 1, event.id, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(statement, 2, event.distinctId, -1, SQLITE_TRANSIENT)
    _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
    sqlite3_bind_int64(statement, 4, try Self.historyMilliseconds(for: acceptedAt, rounding: .toNearestOrAwayFromZero))
    sqlite3_bind_text(statement, 5, try conversionScope(), -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EventStorageError.insertFailed(NSError(domain: "SQLite", code: 61))
    }
    if sqlite3_changes(db) == 0 {
      // History may already have been pruned while measurement is pending.
      // Preserve the first acceptance, and reject conflicting stable identity.
      var existing: OpaquePointer?
      defer { sqlite3_finalize(existing) }
      guard sqlite3_prepare_v2(db, "SELECT payload FROM conversion_event_inbox WHERE event_id = ? AND scope = ?;", -1, &existing, nil) == SQLITE_OK else {
        throw EventStorageError.invalidProperties
      }
      sqlite3_bind_text(existing, 1, event.id, -1, SQLITE_TRANSIENT)
      sqlite3_bind_text(existing, 2, try conversionScope(), -1, SQLITE_TRANSIENT)
      guard sqlite3_step(existing) == SQLITE_ROW, let blob = sqlite3_column_blob(existing, 0) else {
        throw EventStorageError.invalidProperties
      }
      let retained = try ExactJSONCodec.decode(StoredEvent.self,
        from: Data(bytes: blob, count: Int(sqlite3_column_bytes(existing, 0))))
      guard retained.isByteEquivalent(to: event) else { throw EventStorageError.invalidProperties }
    }
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
    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      return .dropped
    case SQLITE_DONE:
      return nil
    default:
      throw EventStorageError.queryFailed(
        NSError(
          domain: "SQLite",
          code: 47,
          userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))
          ]
        )
      )
    }
  }

  public func commitStableCapture(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date,
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureCommitAdmission)?
  ) throws -> StableEventCaptureCommit {
    if let admission {
      guard let committed = try admission.commitIfCurrent({
        try commitStableCaptureUnfenced(
          eventId: eventId,
          event: event,
          recordedAt: recordedAt,
          assigningCommitSequence: assigningCommitSequence
        )
      }) else {
        throw StableEventCaptureCommitAdmissionError.rejected
      }
      return committed
    }
    return try commitStableCaptureUnfenced(
      eventId: eventId,
      event: event,
      recordedAt: recordedAt,
      assigningCommitSequence: assigningCommitSequence
    )
  }

  public func commitStableCaptureAndStageRoute(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date,
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureCommitAdmission)?
  ) throws -> StableEventCaptureCommit {
    let operation = {
      try self.commitStableCaptureAndStageRouteUnfenced(
        eventId: eventId,
        event: event,
        recordedAt: recordedAt,
        assigningCommitSequence: assigningCommitSequence
      )
    }
    if let admission {
      guard let committed = try admission.commitIfCurrent(operation) else {
        throw StableEventCaptureCommitAdmissionError.rejected
      }
      return committed
    }
    return try operation()
  }

  private func commitStableCaptureAndStageRouteUnfenced(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date,
    assigningCommitSequence: Bool
  ) throws -> StableEventCaptureCommit {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let sequenceBeforeTransaction = nextCommitSequence
    guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
      == SQLITE_OK else {
      throw EventStorageError.insertFailed(NSError(
        domain: "Nuxie.EventStore",
        code: 52,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
    do {
      let commit = try commitStableCaptureUnfenced(
        eventId: eventId,
        event: event,
        recordedAt: recordedAt,
        assigningCommitSequence: assigningCommitSequence
      )
      let result = StableEventCaptureCommit(
        outcome: commit.outcome,
        commitSequence: commit.commitSequence,
        localRoutePending: try stageStableRoute(
          eventId: eventId,
          outcome: commit.outcome
        )
      )
      guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
        throw EventStorageError.insertFailed(NSError(
          domain: "Nuxie.EventStore",
          code: 53,
          userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
        ))
      }
      return result
    } catch {
      _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      nextCommitSequence = sequenceBeforeTransaction
      throw error
    }
  }

  /// Commits an indivisible batch of stable event outcomes.
  ///
  /// - Parameters:
  ///   - records: Stable event records to deduplicate and commit together.
  ///   - assigningCommitSequence: Whether newly stored events receive a
  ///     contiguous commit sequence in this transaction.
  ///   - admission: Optional authority checked around the final synchronous
  ///     database mutation.
  /// - Returns: One terminal commit result for every input record, in order.
  public func commitStableCaptureBatch(
    _ records: [StableEventCaptureRecord],
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureBatchCommitAdmission)?
  ) throws -> [StableEventCaptureCommit] {
    let operation = {
      try self.commitStableCaptureBatchUnfenced(
        records,
        assigningCommitSequence: assigningCommitSequence,
        stageRoutes: false
      )
    }
    if let admission {
      guard let committed = try admission.commitBatchIfCurrent(operation) else {
        throw StableEventCaptureCommitAdmissionError.rejected
      }
      return committed
    }
    return try operation()
  }

  public func commitStableCaptureBatchAndStageRoutes(
    _ records: [StableEventCaptureRecord],
    assigningCommitSequence: Bool,
    admission: (any StableEventCaptureBatchCommitAdmission)?
  ) throws -> [StableEventCaptureCommit] {
    let operation = {
      try self.commitStableCaptureBatchUnfenced(
        records,
        assigningCommitSequence: assigningCommitSequence,
        stageRoutes: true
      )
    }
    if let admission {
      guard let committed = try admission.commitBatchIfCurrent(operation) else {
        throw StableEventCaptureCommitAdmissionError.rejected
      }
      return committed
    }
    return try operation()
  }

  private func commitStableCaptureBatchUnfenced(
    _ records: [StableEventCaptureRecord],
    assigningCommitSequence: Bool,
    stageRoutes: Bool
  ) throws -> [StableEventCaptureCommit] {
    guard !records.isEmpty else { return [] }
    guard let db else { throw EventStorageError.databaseNotInitialized }
    let sequenceBeforeTransaction = nextCommitSequence
    guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
      == SQLITE_OK else {
      throw EventStorageError.insertFailed(NSError(
        domain: "SQLite",
        code: 50,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
    do {
      let commits = try records.map { record in
        let commit = try commitStableCaptureUnfenced(
          eventId: record.eventId,
          event: record.event,
          recordedAt: record.recordedAt,
          assigningCommitSequence: assigningCommitSequence
        )
        guard stageRoutes else { return commit }
        return StableEventCaptureCommit(
          outcome: commit.outcome,
          commitSequence: commit.commitSequence,
          localRoutePending: try stageStableRoute(
            eventId: record.eventId,
            outcome: commit.outcome
          )
        )
      }
      guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
        throw EventStorageError.insertFailed(NSError(
          domain: "SQLite",
          code: 51,
          userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
        ))
      }
      return commits
    } catch {
      _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      nextCommitSequence = sequenceBeforeTransaction
      throw error
    }
  }

  private func commitStableCaptureUnfenced(
    eventId: String,
    event: StoredEvent?,
    recordedAt: Date,
    assigningCommitSequence: Bool
  ) throws -> StableEventCaptureCommit {
    if let existing = try queryStableCapture(id: eventId) {
      return StableEventCaptureCommit(
        outcome: existing,
        commitSequence: takeCommitSequence(if: assigningCommitSequence)
      )
    }
    if let event {
      let inserted = try insert(
        event,
        deliveryState: .pending,
        origin: .device,
        assigningCommitSequence: false,
        acceptedAt: recordedAt
      )
      guard let canonical = try queryEvent(id: eventId) else {
        throw EventStorageError.queryFailed(
          NSError(
            domain: "SQLite",
            code: 28,
            userInfo: [NSLocalizedDescriptionKey: "stable captured event disappeared"]
          )
        )
      }
      return StableEventCaptureCommit(
        outcome: .captured(canonical, isNew: inserted.newlyDurable),
        commitSequence: takeCommitSequence(if: assigningCommitSequence)
      )
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
    return StableEventCaptureCommit(
      outcome: .dropped,
      commitSequence: takeCommitSequence(if: assigningCommitSequence)
    )
  }

  private func stageStableRoute(
    eventId: String,
    outcome: StableEventCaptureOutcome
  ) throws -> Bool {
    guard case .captured = outcome else { return false }
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var insert: OpaquePointer?
    defer { sqlite3_finalize(insert) }
    guard sqlite3_prepare_v2(
      db,
      "INSERT OR IGNORE INTO stable_event_routes (event_id) VALUES (?);",
      -1,
      &insert,
      nil
    ) == SQLITE_OK else {
      throw EventStorageError.insertFailed(NSError(
        domain: "Nuxie.EventStore",
        code: 54,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
    sqlite3_bind_text(insert, 1, eventId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(insert) == SQLITE_DONE else {
      throw EventStorageError.insertFailed(NSError(
        domain: "Nuxie.EventStore",
        code: 55,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }

    var query: OpaquePointer?
    defer { sqlite3_finalize(query) }
    guard sqlite3_prepare_v2(
      db,
      "SELECT delivery_state FROM stable_event_routes WHERE event_id = ? LIMIT 1;",
      -1,
      &query,
      nil
    ) == SQLITE_OK else {
      throw EventStorageError.queryFailed(NSError(
        domain: "Nuxie.EventStore",
        code: 56,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
    sqlite3_bind_text(query, 1, eventId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(query) == SQLITE_ROW else {
      throw EventStorageError.queryFailed(NSError(
        domain: "Nuxie.EventStore",
        code: 57,
        userInfo: [NSLocalizedDescriptionKey: "Stable route receipt disappeared"]
      ))
    }
    return sqlite3_column_int(query, 0) == EventDeliveryState.pending.rawValue
  }

  public func queryPendingStableRoutes(
    distinctId: String, limit: Int
  ) throws -> [StoredEvent] {
    try pendingStableRoutePage(distinctId: distinctId, after: 0, through: .max, limit: limit)
      .map(\.event)
  }

  public func visitPendingStableRoutes(
    distinctId: String,
    visitor: @escaping @Sendable (StoredEvent) async -> Bool
  ) async throws -> Bool {
    let upperBound = try stableRouteUpperBound()
    var cursor: Int64 = 0
    while true {
      let page = try pendingStableRoutePage(
        distinctId: distinctId, after: cursor, through: upperBound, limit: 100
      )
      guard let last = page.last else { return true }
      for route in page {
        guard await visitor(route.event) else { return false }
      }
      cursor = last.sequence
    }
  }

  private func stableRouteUpperBound() throws -> Int64 {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rowid), 0) FROM stable_event_routes;", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else {
      throw EventStorageError.queryFailed(NSError(
        domain: "Nuxie.EventStore", code: 58,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func pendingStableRoutePage(
    distinctId: String, after: Int64, through: Int64, limit: Int
  ) throws -> [(sequence: Int64, event: StoredEvent)] {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let sql = """
      SELECT stable_event_routes.rowid, events.id
      FROM stable_event_routes
      JOIN events ON events.id = stable_event_routes.event_id
      WHERE stable_event_routes.delivery_state = ? AND events.user_id = ?
        AND stable_event_routes.rowid > ? AND stable_event_routes.rowid <= ?
      ORDER BY stable_event_routes.rowid ASC LIMIT ?;
      """
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw EventStorageError.queryFailed(NSError(
        domain: "Nuxie.EventStore", code: 58,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
    sqlite3_bind_int(statement, 1, EventDeliveryState.pending.rawValue)
    sqlite3_bind_text(statement, 2, distinctId, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(statement, 3, after)
    sqlite3_bind_int64(statement, 4, through)
    sqlite3_bind_int64(statement, 5, Int64(max(0, limit)))
    var routes: [(sequence: Int64, event: StoredEvent)] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW,
            let bytes = sqlite3_column_text(statement, 1) else {
        throw EventStorageError.queryFailed(NSError(
          domain: "Nuxie.EventStore", code: 59,
          userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
        ))
      }
      let sequence = sqlite3_column_int64(statement, 0)
      if let event = try queryEvent(id: String(cString: bytes)) {
        routes.append((sequence: sequence, event: event))
      }
    }
    return routes
  }

  public func markStableRouteDelivered(eventId: String) throws {
    guard let db else { throw EventStorageError.databaseNotInitialized }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(
      db,
      "UPDATE stable_event_routes SET delivery_state = ? WHERE event_id = ?;",
      -1,
      &statement,
      nil
    ) == SQLITE_OK else {
      throw EventStorageError.updateFailed(NSError(
        domain: "Nuxie.EventStore",
        code: 60,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
    sqlite3_bind_int(statement, 1, EventDeliveryState.delivered.rawValue)
    sqlite3_bind_text(statement, 2, eventId, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw EventStorageError.updateFailed(NSError(
        domain: "Nuxie.EventStore",
        code: 61,
        userInfo: [NSLocalizedDescriptionKey: sqliteMessage()]
      ))
    }
  }

  private func takeCommitSequence(if requested: Bool) -> UInt64? {
    guard requested else { return nil }
    defer { nextCommitSequence &+= 1 }
    return nextCommitSequence
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

    switch sqlite3_step(statement) {
    case SQLITE_ROW:
      break
    case SQLITE_DONE:
      return nil
    default:
      throw EventStorageError.queryFailed(
        NSError(
          domain: "SQLite",
          code: 48,
          userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))
          ]
        )
      )
    }
    guard let propertiesBlob = sqlite3_column_blob(statement, 2) else {
      throw EventStorageError.invalidProperties
    }
    let propertiesData = Data(
      bytes: propertiesBlob,
      count: Int(sqlite3_column_bytes(statement, 2))
    )
    return StoredEvent(
      id: String(cString: sqlite3_column_text(statement, 0)),
      name: String(cString: sqlite3_column_text(statement, 1)),
      properties: propertiesData,
      timestamp: Date(
        timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000.0
      ),
      distinctId: String(cString: sqlite3_column_text(statement, 4))
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

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId
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
    let sql = """
      DELETE FROM events
      WHERE timestamp < ?
        AND delivery_state = ?
        AND \(Self.noPendingLocalRoutes)
        AND origin != 'server';
      """
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw coverageDeleteError(code: 38)
    }
    sqlite3_bind_int64(statement, 1, olderThanMs)
    sqlite3_bind_int(statement, 2, EventDeliveryState.delivered.rawValue)
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
          AND \(Self.noPendingLocalRoutes)
          AND origin != 'server'
        ORDER BY timestamp ASC, id ASC
        LIMIT ?
      );
      """
    var boundaryStatement: OpaquePointer?
    defer { sqlite3_finalize(boundaryStatement) }
    guard sqlite3_prepare_v2(db, boundarySQL, -1, &boundaryStatement, nil) == SQLITE_OK else {
      throw coverageQueryError(code: 40)
    }
    sqlite3_bind_int(boundaryStatement, 1, EventDeliveryState.delivered.rawValue)
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
          AND \(Self.noPendingLocalRoutes)
          AND origin != 'server'
        ORDER BY timestamp ASC, id ASC
        LIMIT ?
      );
      """
    var deleteStatement: OpaquePointer?
    defer { sqlite3_finalize(deleteStatement) }
    guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK else {
      throw coverageDeleteError(code: 42)
    }
    sqlite3_bind_int(deleteStatement, 1, EventDeliveryState.delivered.rawValue)
    sqlite3_bind_int64(deleteStatement, 2, Int64(limit))
    guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
      throw coverageDeleteError(code: 43)
    }
    let deleted = Int(sqlite3_changes(db))
    guard deleted > 0 else { return (nil, 0) }
    let boundary = newestDeletedMs == Int64.max ? Int64.max : newestDeletedMs + 1
    return (boundary, deleted)
  }

  /// Network acknowledgement does not release a record still owed to local
  /// subscribers. Both retention selectors must use the same predicate.
  private static let noPendingLocalRoutes = """
    NOT EXISTS (
      SELECT 1 FROM committed_route_deliveries WHERE event_id = events.id
    ) AND NOT EXISTS (
      SELECT 1 FROM stable_event_routes
      WHERE event_id = events.id AND delivery_state = \(EventDeliveryState.pending.rawValue)
    )
    """

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

  // Foundation stores Date relative to 2001. Converting an exact epoch
  // millisecond through that origin can move it by one representable Double
  // tick. Snap only that conversion noise before applying the authored bound.
  private static func normalizedMilliseconds(for date: Date) -> Double {
    let seconds = date.timeIntervalSince1970
    let milliseconds = seconds * 1_000
    let nearest = milliseconds.rounded()
    let tolerance = (seconds.ulp + date.timeIntervalSinceReferenceDate.ulp) * 1_000 + milliseconds.ulp
    return abs(milliseconds - nearest) <= tolerance ? nearest : milliseconds
  }

  private static func historyMilliseconds(for date: Date, rounding: FloatingPointRoundingRule) throws -> Int64 {
    let raw = normalizedMilliseconds(for: date).rounded(rounding)
    guard raw.isFinite, raw >= Double(Int64.min), raw < Double(Int64.max) else {
      throw EventStorageError.queryFailed(NSError(domain: "SQLite", code: 49,
        userInfo: [NSLocalizedDescriptionKey: "History timestamp is outside the supported range"]))
    }
    return Int64(raw)
  }

  private static func coverageMilliseconds(for date: Date) -> Int64 {
    let raw = normalizedMilliseconds(for: date)
    if !raw.isFinite { return Int64.max }
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
      let timestampMs = try Self.historyMilliseconds(for: since, rounding: .up)
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
      let timestampMs = try Self.historyMilliseconds(for: since, rounding: .up)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
      bindIndex += 1
    }
    if let until = until {
      let timestampMs = try Self.historyMilliseconds(for: until, rounding: .down)
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
      let timestampMs = try Self.historyMilliseconds(for: since, rounding: .up)
      sqlite3_bind_int64(statement, bindIndex, timestampMs)
      bindIndex += 1
    }
    if let until = until {
      let timestampMs = try Self.historyMilliseconds(for: until, rounding: .down)
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
      SELECT id, name, properties, timestamp, user_id
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
      sqlite3_bind_int64(statement, bindIndex, try Self.historyMilliseconds(for: since, rounding: .up)); bindIndex += 1
    }
    if let until {
      sqlite3_bind_int64(statement, bindIndex, try Self.historyMilliseconds(for: until, rounding: .down)); bindIndex += 1
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
      events.append(StoredEvent(
        id: String(cString: idText),
        name: name,
        properties: Data(bytes: propertiesBlob, count: Int(sqlite3_column_bytes(statement, 2))),
        timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000.0),
        distinctId: distinctId
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
      sqlite3_bind_int64(statement, bindIndex, try Self.historyMilliseconds(for: since, rounding: .up)); bindIndex += 1
    }
    if let until {
      sqlite3_bind_int64(statement, bindIndex, try Self.historyMilliseconds(for: until, rounding: .down)); bindIndex += 1
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
      SELECT id, name, properties, timestamp, user_id
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

      // Don't decode properties - keep as Data for lazy decoding
      let event = StoredEvent(
        id: id,
        name: name,
        properties: propertiesData,
        timestamp: timestamp,
        distinctId: distinctId
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
      SELECT id, name, properties, timestamp, user_id
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

    sqlite3_bind_int(statement, 1, EventDeliveryState.pending.rawValue)
    sqlite3_bind_int64(statement, 2, Int64(limit))

    var events: [StoredEvent] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let idText = sqlite3_column_text(statement, 0),
            let nameText = sqlite3_column_text(statement, 1),
            let propertiesBlob = sqlite3_column_blob(statement, 2),
            let userIdText = sqlite3_column_text(statement, 4)
      else { continue }

      events.append(StoredEvent(
        id: String(cString: idText),
        name: String(cString: nameText),
        properties: Data(bytes: propertiesBlob, count: Int(sqlite3_column_bytes(statement, 2))),
        timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000.0),
        distinctId: String(cString: userIdText)
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

    sqlite3_bind_int(statement, 1, EventDeliveryState.pending.rawValue)
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
    let sql = "UPDATE events SET delivery_state = \(EventDeliveryState.delivered.rawValue) WHERE id IN (\(placeholders));"

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

}
