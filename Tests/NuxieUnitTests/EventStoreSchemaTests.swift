import Foundation
import SQLite3
import XCTest

@testable import Nuxie

final class EventStoreSchemaTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventStoreSchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
    }

    func testVersionThreeUpgradePreservesOrdinaryPendingEvents() async throws {
        let original = SQLiteEventStore()
        try await original.initialize(path: temporaryRoot)
        let event = try StoredEvent(id: "ordinary", name: "finished", properties: ["answer": 42], distinctId: "customer")
        _ = try await original.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: true)
        await original.close()
        let database = try openDatabase()
        try execute("ALTER TABLE events DROP COLUMN journey_origin; PRAGMA user_version = 3;", on: database)
        sqlite3_close(database)
        let upgraded = SQLiteEventStore()
        try await upgraded.initialize(path: temporaryRoot)
        let pending = try await upgraded.queryPendingDelivery(limit: 10)
        XCTAssertEqual(pending.map(\.id), ["ordinary"])
        XCTAssertNil(pending.first?.journeyOrigin)
        XCTAssertEqual(pending.first?.getPropertiesDict()["answer"] as? Int, 42)
        await upgraded.close()
        let inspected = try openDatabase()
        defer { sqlite3_close(inspected) }
        XCTAssertEqual(try userVersion(in: inspected), 4)
    }

    func testOriginSurvivesDatabaseReopenAndDeliveryRecovery() async throws {
        let origin = JourneyEventOrigin(
            journeyId: "journey", experienceId: "experience", versionId: "version",
            legId: "leg", generation: 0, stepId: "step", occurrenceId: "event"
        )
        let first = SQLiteEventStore()
        try await first.initialize(path: temporaryRoot)
        let event = try StoredEvent(id: "event", name: "finished", properties: ["answer": 42],
            distinctId: "customer", journeyOrigin: origin)
        _ = try await first.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: true)
        await first.close()
        let reopened = SQLiteEventStore()
        try await reopened.initialize(path: temporaryRoot)
        let direct = try await reopened.queryEvent(id: "event")
        let pending = try await reopened.queryPendingDelivery(limit: 10)
        let history = try await reopened.queryEventsForUser("customer", limit: 10)
        XCTAssertEqual(direct?.journeyOrigin, origin)
        XCTAssertEqual(pending.first?.journeyOrigin, origin)
        XCTAssertEqual(history.first?.journeyOrigin, origin)
        let conversions = try await reopened.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(conversions.first?.event.journeyOrigin, origin)
        await reopened.close()
    }

    func testConversionExpiryIsInclusiveScopedAndLeavesEventDeliveryIntact() async throws {
        let first = SQLiteEventStore(conversionCaptureScope: "first")
        let other = SQLiteEventStore(conversionCaptureScope: "other")
        try await first.initialize(path: temporaryRoot)
        try await other.initialize(path: temporaryRoot)
        let accepted = Date(timeIntervalSince1970: 100)
        for (store, id) in [(first, "first-event"), (other, "other-event")] {
            let event = try StoredEvent(id: id, name: "outcome", timestamp: accepted, distinctId: "customer")
            _ = try await store.insert(event, deliveryState: .pending, origin: .device,
                assigningCommitSequence: true, acceptedAt: accepted)
        }
        let boundary = accepted.addingTimeInterval(Double(PendingConversionOccurrence.retentionMillis) / 1000)
        let atBoundary = try await first.pruneConversionOccurrences(at: boundary)
        XCTAssertEqual(atBoundary, 0)
        let expired = try await first.pruneConversionOccurrences(at: boundary.addingTimeInterval(0.001))
        XCTAssertEqual(expired, 1)
        let gone = try await first.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertTrue(gone.isEmpty)
        let isolated = try await other.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(isolated.map { $0.event.id }, ["other-event"])
        let analytics = try await first.queryEvent(id: "first-event")
        XCTAssertNotNil(analytics)
        let delivery = try await first.queryPendingDelivery(limit: 10)
        XCTAssertEqual(Set(delivery.map(\.id)), ["first-event", "other-event"])
        let rolledBackClock = try await first.pruneConversionOccurrences(at: accepted)
        XCTAssertEqual(rolledBackClock, 0)
        await first.close()
        await other.close()
    }

    func testConversionInboxUsesAuthenticatedAppScopeAndSurvivesCredentialRotation() async throws {
        let original = SQLiteEventStore(conversionCaptureScope: "old-key")
        try await original.initialize(path: temporaryRoot)
        let event = try StoredEvent(id: "goal", name: "outcome", distinctId: "customer")
        _ = try await original.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: true)
        let app = JourneyStorageScope(authority: .init(appId: "app-a", environment: "production"))
        try await original.bindConversionAuthority(app)
        await original.close()

        for (key, authority) in [
            ("other-key", ProfileDeliveryAuthority(appId: "app-b", environment: "production")),
            ("test-key", ProfileDeliveryAuthority(appId: "app-a", environment: "test"))
        ] {
            let other = SQLiteEventStore(conversionCaptureScope: key)
            try await other.initialize(path: temporaryRoot)
            try await other.bindConversionAuthority(JourneyStorageScope(authority: authority))
            let invisible = try await other.pendingConversionOccurrences(distinctId: "customer")
            XCTAssertTrue(invisible.isEmpty)
            try await other.acknowledgeConversionOccurrence(eventId: "goal", distinctId: "customer")
            do {
                try await other.bindConversionAuthority(app)
                XCTFail("A bound credential cannot be reassigned to another app/environment")
            } catch { }
            await other.close()
        }

        let rotated = SQLiteEventStore(conversionCaptureScope: "new-key")
        try await rotated.initialize(path: temporaryRoot)
        let unbound = try await rotated.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertTrue(unbound.isEmpty)
        try await rotated.bindConversionAuthority(app)
        let pending = try await rotated.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(pending.map { $0.event.id }, ["goal"])
        await rotated.close()
        let reopened = SQLiteEventStore(conversionCaptureScope: "new-key")
        try await reopened.initialize(path: temporaryRoot)
        let restored = try await reopened.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(restored.map { $0.event.id }, ["goal"])
        try await reopened.acknowledgeConversionOccurrence(eventId: "goal", distinctId: "customer")
        await reopened.close()
    }

    func testConversionInboxCutoffDoesNotConsumeEventsBeyondCurrentRoute() async throws {
        let store = SQLiteEventStore()
        try await store.initialize(path: temporaryRoot)
        for id in ["entry", "later-goal"] {
            let event = try StoredEvent(id: id, name: id, distinctId: "customer")
            _ = try await store.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: true)
        }
        let prefix = try await store.pendingConversionOccurrences(distinctId: "customer", throughEventId: "entry")
        XCTAssertEqual(prefix.map { $0.event.id }, ["entry"])
        try await store.acknowledgeConversionOccurrence(eventId: "entry", distinctId: "customer")
        let repeated = try await store.pendingConversionOccurrences(distinctId: "customer", throughEventId: "entry")
        XCTAssertTrue(repeated.isEmpty)
        let remainder = try await store.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(remainder.map { $0.event.id }, ["later-goal"])
        await store.close()
    }

    func testConversionInboxSurvivesHistoryDeletionAndReopenUntilScopedAcknowledgement() async throws {
        let store = SQLiteEventStore()
        try await store.initialize(path: temporaryRoot)
        let event = try StoredEvent(id: "goal", name: "outcome", properties: ["product": "pro"],
            timestamp: Date(timeIntervalSince1970: 100), distinctId: "customer")
        _ = try await store.insert(event, deliveryState: .pending, origin: .device,
            assigningCommitSequence: true, acceptedAt: Date(timeIntervalSince1970: 200))
        _ = try await store.insert(event, deliveryState: .pending, origin: .device,
            assigningCommitSequence: true, acceptedAt: Date(timeIntervalSince1970: 300))
        await store.close()
        let database = try openDatabase()
        try execute("DELETE FROM events;", on: database)
        sqlite3_close(database)
        try await store.initialize(path: temporaryRoot)
        _ = try await store.insert(event, deliveryState: .pending, origin: .device,
            assigningCommitSequence: true, acceptedAt: Date(timeIntervalSince1970: 400))
        let pending = try await store.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.event.id, "goal")
        XCTAssertEqual(pending.first?.acceptedAt, Date(timeIntervalSince1970: 200))
        let other = try await store.pendingConversionOccurrences(distinctId: "other")
        XCTAssertTrue(other.isEmpty)
        try await store.acknowledgeConversionOccurrence(eventId: "goal", distinctId: "other")
        let retained = try await store.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(retained.count, 1)
        try await store.acknowledgeConversionOccurrence(eventId: "goal", distinctId: "customer")
        let acknowledged = try await store.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertTrue(acknowledged.isEmpty)
        await store.close()
    }

    func testStableCaptureStagesConversionWithOriginalAcceptanceTime() async throws {
        let store = SQLiteEventStore()
        try await store.initialize(path: temporaryRoot)
        let event = try StoredEvent(id: "purchase", name: SystemEventNames.purchaseCompleted,
            timestamp: Date(timeIntervalSince1970: 100), distinctId: "customer")
        _ = try await store.commitStableCapture(eventId: event.id, event: event,
            recordedAt: Date(timeIntervalSince1970: 200), assigningCommitSequence: true, admission: nil)
        _ = try await store.commitStableCapture(eventId: event.id, event: event,
            recordedAt: Date(timeIntervalSince1970: 300), assigningCommitSequence: true, admission: nil)
        let pending = try await store.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.acceptedAt, Date(timeIntervalSince1970: 200))
        await store.close()
    }

    func testConversionInboxWriteFailureRollsBackEventInsert() async throws {
        let store = SQLiteEventStore()
        try await store.initialize(path: temporaryRoot)
        let database = try openDatabase()
        try execute("CREATE TRIGGER reject_conversion BEFORE INSERT ON conversion_event_inbox BEGIN SELECT RAISE(ABORT, 'injected failure'); END;", on: database)
        sqlite3_close(database)
        let event = try StoredEvent(id: "atomic", name: "outcome", distinctId: "customer")
        do {
            _ = try await store.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: true)
            XCTFail("Capture must not commit without its conversion occurrence")
        } catch { }
        let captured = try await store.queryEvent(id: "atomic")
        XCTAssertNil(captured)
        let pending = try await store.pendingConversionOccurrences(distinctId: "customer")
        XCTAssertTrue(pending.isEmpty)
        await store.close()
    }

    func testFreshStoreInstallsTheCompleteSchemaAsVersionThree() async throws {
        let store = SQLiteEventStore()
        try await store.initialize(path: temporaryRoot)
        await store.close()

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        XCTAssertEqual(try userVersion(in: database), 4)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM pragma_table_info('events');", in: database), 8)
        XCTAssertEqual(
            try scalarInt(
                "SELECT \"notnull\" FROM pragma_table_info('events') WHERE name = 'origin';",
                in: database
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('events') "
                    + "WHERE name = 'origin' AND type = 'TEXT' "
                    + "AND dflt_value = '''device''';",
                in: database
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT \"notnull\" FROM pragma_table_info('events') WHERE name = 'user_id';",
                in: database
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'stable_event_drops';",
                in: database
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'stable_event_routes';",
                in: database
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('stable_event_routes');",
                in: database
            ),
            2
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'event_history_metadata';",
                in: database
            ),
            1
        )
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_events_%';",
                in: database
            ),
            6
        )
    }

    func testUpgradesValidVersionTwoWithoutDeletingEvents() async throws {
        let firstStore = SQLiteEventStore()
        try await firstStore.initialize(path: temporaryRoot)
        await firstStore.close()

        let initialDatabase = try openDatabase()
        let initialSchemaVersion = try scalarInt("PRAGMA schema_version;", in: initialDatabase)
        sqlite3_close(initialDatabase)

        let reopenedStore = SQLiteEventStore()
        try await reopenedStore.initialize(path: temporaryRoot)
        await reopenedStore.close()

        let reopenedDatabase = try openDatabase()
        defer { sqlite3_close(reopenedDatabase) }
        XCTAssertEqual(try userVersion(in: reopenedDatabase), 4)
        XCTAssertEqual(
            try scalarInt("PRAGMA schema_version;", in: reopenedDatabase),
            initialSchemaVersion
        )
    }

    func testRejectsUnversionedPreReleaseStoreWithoutMutatingIt() async throws {
        let database = try openDatabase()
        try execute(
            """
            CREATE TABLE events (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              properties BLOB NOT NULL,
              timestamp INTEGER NOT NULL,
              user_id TEXT,
              session_id TEXT
            );
            INSERT INTO events (id, name, properties, timestamp, user_id, session_id)
            VALUES ('pre-release', 'old', X'7B7D', 1000, NULL, NULL);
            PRAGMA user_version = 0;
            """,
            on: database
        )
        let schemaVersionBefore = try scalarInt("PRAGMA schema_version;", in: database)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 0, operation: "validate unversioned schema")

        let rejectedDatabase = try openDatabase()
        defer { sqlite3_close(rejectedDatabase) }
        XCTAssertEqual(try userVersion(in: rejectedDatabase), 0)
        XCTAssertEqual(try scalarInt("PRAGMA schema_version;", in: rejectedDatabase), schemaVersionBefore)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM events;", in: rejectedDatabase), 1)
        XCTAssertEqual(
            try scalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('events') WHERE name = 'delivery_state';",
                in: rejectedDatabase
            ),
            0
        )
    }

    func testRejectsFutureVersionWithoutMutatingIt() async throws {
        let database = try openDatabase()
        try execute(
            """
            CREATE TABLE future_data (value TEXT NOT NULL);
            INSERT INTO future_data (value) VALUES ('keep-me');
            PRAGMA user_version = 5;
            """,
            on: database
        )
        let schemaVersionBefore = try scalarInt("PRAGMA schema_version;", in: database)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 5, operation: "validate user_version")

        let rejectedDatabase = try openDatabase()
        defer { sqlite3_close(rejectedDatabase) }
        XCTAssertEqual(try userVersion(in: rejectedDatabase), 5)
        XCTAssertEqual(try scalarInt("PRAGMA schema_version;", in: rejectedDatabase), schemaVersionBefore)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM future_data;", in: rejectedDatabase), 1)
    }

    func testRejectsMalformedVersionTwoWithoutMutatingIt() async throws {
        let database = try openDatabase()
        try createCurrentSchema(in: database, userIDIsRequired: false)
        let schemaVersionBefore = try scalarInt("PRAGMA schema_version;", in: database)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 2, operation: "verify events")

        let rejectedDatabase = try openDatabase()
        defer { sqlite3_close(rejectedDatabase) }
        XCTAssertEqual(try userVersion(in: rejectedDatabase), 2)
        XCTAssertEqual(try scalarInt("PRAGMA schema_version;", in: rejectedDatabase), schemaVersionBefore)
        XCTAssertEqual(
            try scalarInt(
                "SELECT \"notnull\" FROM pragma_table_info('events') WHERE name = 'user_id';",
                in: rejectedDatabase
            ),
            0
        )
    }

    func testRejectsVersionTwoWhenARequiredIndexIsMissing() async throws {
        let database = try openDatabase()
        try createCurrentSchema(in: database, omittedIndex: "idx_events_delivery")
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 2, operation: "verify idx_events_delivery")
    }

    func testRejectsVersionTwoWithoutHistoryMetadata() async throws {
        let database = try openDatabase()
        try createCurrentSchema(in: database, includeHistoryMetadata: false)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(
            store,
            targetVersion: 2,
            operation: "verify event_history_metadata"
        )
    }

    func testRejectsVersionTwoWhenAnIndexHasTheWrongDefinition() async throws {
        let database = try openDatabase()
        try createCurrentSchema(in: database, omittedIndex: "idx_events_delivery")
        try execute("CREATE INDEX idx_events_delivery ON events(name);", on: database)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 2, operation: "verify idx_events_delivery")
    }

    private func assertSchemaFailure(
        _ store: SQLiteEventStore,
        targetVersion: Int32,
        operation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await store.initialize(path: temporaryRoot)
            XCTFail("Expected schema validation to fail", file: file, line: line)
        } catch let EventStorageError.invalidSchema(error) {
            XCTAssertEqual(error.targetVersion, targetVersion, file: file, line: line)
            XCTAssertEqual(error.operation, operation, file: file, line: line)
            XCTAssertEqual(error.sqliteCode, SQLITE_SCHEMA, file: file, line: line)
        } catch {
            XCTFail("Expected EventStorageError.invalidSchema, got \(error)", file: file, line: line)
        }
        await store.close()
    }

    private var databaseDirectory: URL {
        temporaryRoot.appendingPathComponent("nuxie", isDirectory: true)
    }

    private var databaseURL: URL {
        databaseDirectory.appendingPathComponent("events.db")
    }

    private func openDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open(databaseURL.path, &database)
        guard result == SQLITE_OK, let database else {
            defer { sqlite3_close(database) }
            throw sqliteError(database, result: result)
        }
        return database
    }

    private func createCurrentSchema(
        in database: OpaquePointer,
        userIDIsRequired: Bool = true,
        includeHistoryMetadata: Bool = true,
        omittedIndex: String? = nil
    ) throws {
        try execute(
            """
            CREATE TABLE events (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              properties BLOB NOT NULL,
              timestamp INTEGER NOT NULL,
              user_id TEXT \(userIDIsRequired ? "NOT NULL" : ""),
              delivery_state INTEGER NOT NULL DEFAULT 2,
              origin TEXT NOT NULL DEFAULT 'device'
            );
            CREATE TABLE stable_event_drops (
              event_id TEXT PRIMARY KEY,
              created_at INTEGER NOT NULL
            );
            CREATE TABLE stable_event_routes (
              event_id TEXT PRIMARY KEY,
              delivery_state INTEGER NOT NULL DEFAULT 0,
              FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
            );
            PRAGMA user_version = 2;
            """,
            on: database
        )

        if includeHistoryMetadata {
            try execute(
                """
                CREATE TABLE event_history_metadata (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  coverage_start_ms INTEGER NOT NULL
                );
                """,
                on: database
            )
        }

        let indexes: [(String, String)] = [
            ("idx_events_delivery", "events(delivery_state, timestamp)"),
            ("idx_events_timestamp", "events(timestamp)"),
            ("idx_events_user_id", "events(user_id)"),
            ("idx_events_name", "events(name)"),
            ("idx_events_user_name_time", "events(user_id, name, timestamp DESC)"),
            ("idx_events_user_time", "events(user_id, timestamp DESC)"),
        ]
        for (name, definition) in indexes where name != omittedIndex {
            try execute("CREATE INDEX \(name) ON \(definition);", on: database)
        }
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw sqliteError(database, result: result)
        }
    }

    private func userVersion(in database: OpaquePointer) throws -> Int {
        try scalarInt("PRAGMA user_version;", in: database)
    }

    private func scalarInt(_ sql: String, in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw sqliteError(database, result: prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw sqliteError(database, result: stepResult)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func sqliteError(_ database: OpaquePointer?, result: Int32) -> NSError {
        NSError(
            domain: "EventStoreSchemaTests.SQLite",
            code: Int(result),
            userInfo: [
                NSLocalizedDescriptionKey: database.map { String(cString: sqlite3_errmsg($0)) }
                    ?? "SQLite error \(result)"
            ]
        )
    }
}
