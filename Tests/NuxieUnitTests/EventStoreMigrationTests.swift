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

    func testFreshStoreInstallsTheCompleteSchemaAsVersionOne() async throws {
        let store = SQLiteEventStore()
        try await store.initialize(path: temporaryRoot)
        await store.close()

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        XCTAssertEqual(try userVersion(in: database), 1)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM pragma_table_info('events');", in: database), 7)
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
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_events_%';",
                in: database
            ),
            8
        )
    }

    func testReopensValidVersionOneWithoutMutatingItsSchema() async throws {
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
        XCTAssertEqual(try userVersion(in: reopenedDatabase), 1)
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

    func testRejectsVersionTwoWithoutMutatingIt() async throws {
        let database = try openDatabase()
        try execute(
            """
            CREATE TABLE future_data (value TEXT NOT NULL);
            INSERT INTO future_data (value) VALUES ('keep-me');
            PRAGMA user_version = 2;
            """,
            on: database
        )
        let schemaVersionBefore = try scalarInt("PRAGMA schema_version;", in: database)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 2, operation: "validate user_version")

        let rejectedDatabase = try openDatabase()
        defer { sqlite3_close(rejectedDatabase) }
        XCTAssertEqual(try userVersion(in: rejectedDatabase), 2)
        XCTAssertEqual(try scalarInt("PRAGMA schema_version;", in: rejectedDatabase), schemaVersionBefore)
        XCTAssertEqual(try scalarInt("SELECT COUNT(*) FROM future_data;", in: rejectedDatabase), 1)
    }

    func testRejectsMalformedVersionOneWithoutMutatingIt() async throws {
        let database = try openDatabase()
        try createCurrentSchema(in: database, userIDIsRequired: false)
        let schemaVersionBefore = try scalarInt("PRAGMA schema_version;", in: database)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 1, operation: "verify events")

        let rejectedDatabase = try openDatabase()
        defer { sqlite3_close(rejectedDatabase) }
        XCTAssertEqual(try userVersion(in: rejectedDatabase), 1)
        XCTAssertEqual(try scalarInt("PRAGMA schema_version;", in: rejectedDatabase), schemaVersionBefore)
        XCTAssertEqual(
            try scalarInt(
                "SELECT \"notnull\" FROM pragma_table_info('events') WHERE name = 'user_id';",
                in: rejectedDatabase
            ),
            0
        )
    }

    func testRejectsVersionOneWhenARequiredIndexIsMissing() async throws {
        let database = try openDatabase()
        try createCurrentSchema(in: database, omittedIndex: "idx_events_delivery")
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 1, operation: "verify idx_events_delivery")
    }

    func testRejectsVersionOneWhenAnIndexHasTheWrongDefinition() async throws {
        let database = try openDatabase()
        try createCurrentSchema(in: database, omittedIndex: "idx_events_delivery")
        try execute("CREATE INDEX idx_events_delivery ON events(name);", on: database)
        sqlite3_close(database)

        let store = SQLiteEventStore()
        await assertSchemaFailure(store, targetVersion: 1, operation: "verify idx_events_delivery")
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
              session_id TEXT,
              delivery_state INTEGER NOT NULL DEFAULT 2
            );
            CREATE TABLE stable_event_drops (
              event_id TEXT PRIMARY KEY,
              created_at INTEGER NOT NULL
            );
            PRAGMA user_version = 1;
            """,
            on: database
        )

        let indexes: [(String, String)] = [
            ("idx_events_delivery", "events(delivery_state, timestamp)"),
            ("idx_events_timestamp", "events(timestamp)"),
            ("idx_events_user_id", "events(user_id)"),
            ("idx_events_name", "events(name)"),
            ("idx_events_session_id", "events(session_id)"),
            ("idx_events_user_name_time", "events(user_id, name, timestamp DESC)"),
            ("idx_events_user_time", "events(user_id, timestamp DESC)"),
            ("idx_events_session_time", "events(session_id, timestamp DESC)"),
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
