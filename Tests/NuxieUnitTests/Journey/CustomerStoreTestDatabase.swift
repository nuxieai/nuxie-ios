import Foundation
import SQLite3
import XCTest
@testable import Nuxie

/// Independent SQL fixtures describe the shipped v4 layout and observable rows.
final class CustomerStoreTestDatabase: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CustomerStore-\(UUID().uuidString)")
    var databaseURL: URL { root.appendingPathComponent("nuxie/events.db") }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nuxie"), withIntermediateDirectories: true)
    }

    func remove() throws { try FileManager.default.removeItem(at: root) }

    func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &pointer) == SQLITE_OK, let pointer else { throw CustomerStoreError.invalidRow }
        defer { sqlite3_close(pointer) }
        try Self.execute("PRAGMA foreign_keys=ON;", on: pointer)
        return try body(pointer)
    }

    static func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CustomerStoreTests.SQLite", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    func execute(_ sql: String) throws { try withDatabase { try Self.execute(sql, on: $0) } }

    func strings(_ sql: String) throws -> [String] {
        try withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CustomerStoreError.invalidRow }
            defer { sqlite3_finalize(statement) }
            var rows: [String] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw CustomerStoreError.invalidRow }
                rows.append(String(cString: value))
            }
        }
    }

    func integer(_ sql: String) throws -> Int64 {
        let rows = try strings(sql)
        guard let value = rows.first.flatMap(Int64.init) else { throw CustomerStoreError.invalidRow }
        return value
    }

    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    static func createVersion4(on db: OpaquePointer) throws {
        try execute("""
        CREATE TABLE events(id TEXT PRIMARY KEY,name TEXT NOT NULL,properties BLOB NOT NULL,timestamp INTEGER NOT NULL,
          user_id TEXT NOT NULL,delivery_state INTEGER NOT NULL DEFAULT 2,origin TEXT NOT NULL DEFAULT 'device',journey_origin BLOB);
        CREATE INDEX idx_events_delivery ON events(delivery_state,timestamp);
        CREATE INDEX idx_events_timestamp ON events(timestamp);
        CREATE INDEX idx_events_user_id ON events(user_id);
        CREATE INDEX idx_events_name ON events(name);
        CREATE INDEX idx_events_user_name_time ON events(user_id,name,timestamp DESC);
        CREATE INDEX idx_events_user_time ON events(user_id,timestamp DESC);
        CREATE TABLE stable_event_drops(event_id TEXT PRIMARY KEY,created_at INTEGER NOT NULL);
        CREATE TABLE stable_event_routes(event_id TEXT PRIMARY KEY,delivery_state INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY(event_id) REFERENCES events(id) ON DELETE CASCADE);
        CREATE TABLE event_history_metadata(id INTEGER PRIMARY KEY CHECK(id=1),coverage_start_ms INTEGER NOT NULL);
        CREATE TABLE conversion_event_inbox(event_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,payload BLOB NOT NULL,accepted_at INTEGER NOT NULL,scope TEXT NOT NULL);
        CREATE INDEX idx_conversion_inbox_user ON conversion_event_inbox(scope,user_id);
        CREATE INDEX idx_conversion_inbox_expiry ON conversion_event_inbox(scope,accepted_at);
        CREATE TABLE conversion_scope_bindings(capture_scope TEXT PRIMARY KEY,authority_scope TEXT NOT NULL);
        CREATE TABLE committed_route_deliveries(event_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,commit_sequence INTEGER NOT NULL,
          admission BLOB NOT NULL,next_subscriber INTEGER NOT NULL DEFAULT 0,FOREIGN KEY(event_id) REFERENCES events(id) ON DELETE CASCADE);
        CREATE INDEX idx_committed_routes_session ON committed_route_deliveries(session_id,commit_sequence);
        PRAGMA user_version=4;
        """, on: db)
    }

    func seedJourney(owner: CustomerStoreOwner, journeyId: String = "journey", experience: String = "experience", version: String = "version", generation: Int64 = 0) throws {
        let authority = Self.quoted(owner.authorityScope)
        let user = Self.quoted(owner.userId)
        let journey = Self.quoted(journeyId)
        try execute("""
        INSERT OR IGNORE INTO customer_scopes VALUES(\(authority),\(user),0,0,'device-customer-state-v1');
        INSERT OR IGNORE INTO journey_execution_snapshots VALUES(\(authority),\(user),'snapshot',X'7B7D',X'7B7D',X'7B7D');
        INSERT INTO journeys(authority_scope,user_id,journey_id,leg_generation,experience_id,version_id,leg_id,
          descriptor_sha256,policy_hash,snapshot_id,frequency_json,started_at,is_enrollment,started_event_id,completed_event_id,
          step_id,cursor_revision,status,context_json,outputs_json)
        VALUES(\(authority),\(user),\(journey),\(generation),\(Self.quoted(experience)),\(Self.quoted(version)),'leg',
          'descriptor','policy','snapshot',X'7B7D',-9223372036854775808,1,'started','completed','step',0,'waiting',X'7B7D',X'7B7D');
        """)
    }
}
