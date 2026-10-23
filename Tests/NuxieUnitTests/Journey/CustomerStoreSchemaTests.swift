import Foundation
import SQLite3
import XCTest
@testable import Nuxie

final class CustomerStoreSchemaTests: XCTestCase {
    private var disk: CustomerStoreTestDatabase!
    private var store: SQLiteEventStore!
    private let owner = CustomerStoreOwner(scope: .testFixture, userId: "customer")

    override func setUpWithError() throws { disk = try CustomerStoreTestDatabase(); store = SQLiteEventStore() }
    override func tearDownWithError() throws { try disk.remove(); disk = nil; store = nil }

    func testFreshCreationInstallsAllCustomerTablesAndEventColumnsWithoutCutover() async throws {
        try await store.initialize(path: disk.root)
        let metadata = try await store.customerMetadata()
        XCTAssertEqual(metadata, CustomerStoreMetadata(stateVersion: "legacy", nextCaptureSequence: 1, cutoverSequence: 0, legacyCleanupPending: false))
        let expected = ["customer_store_metadata", "customer_scopes", "journey_execution_snapshots", "journeys", "journey_cursors", "journey_waits",
            "journey_frequency", "journey_arm_receipts", "journey_event_applications", "journey_effects", "journey_experiment_selections",
            "journey_conversion_watches", "journey_response_saves", "journey_release_pins", "journey_pending_work"]
        let tables = Set(try disk.strings("SELECT name FROM sqlite_master WHERE type='table';"))
        XCTAssertTrue(Set(expected).isSubset(of: tables))
        XCTAssertTrue(tables.contains("conversion_event_inbox"))
        XCTAssertEqual(try disk.integer("PRAGMA user_version;"), 5)
        XCTAssertEqual(try disk.strings("SELECT name FROM pragma_table_info('events');"), ["id", "name", "properties", "timestamp", "user_id", "delivery_state", "origin", "journey_origin", "capture_scope", "authority_scope", "scope", "capture_sequence", "accepted_at", "journey_plan_state", "measurement_state", "input_kind", "journey_id", "leg_generation", "event_role", "session_id"])
        XCTAssertEqual(try disk.strings("SELECT name FROM pragma_table_info('event_history_metadata') ORDER BY pk DESC;"), ["user_id", "scope", "coverage_start_ms"])
        await store.close()
    }

    func testUpgradeFromRealVersionFourPreservesEventBytesAndUploadState() async throws {
        try disk.withDatabase { try CustomerStoreTestDatabase.createVersion4(on: $0) }
        try disk.execute("""
        INSERT INTO events(rowid,id,name,properties,timestamp,user_id,delivery_state,origin,journey_origin)
          VALUES(7,'pending','answer',X'7B2261223A317D',-9223372036854775808,'customer',0,'device',X'7B7D');
        INSERT INTO events(rowid,id,name,properties,timestamp,user_id,delivery_state,origin,journey_origin)
          VALUES(42,'delivered','answer',X'7B2262223A327D',9223372036854775807,'other',2,'server',NULL);
        INSERT INTO event_history_metadata VALUES(1,12345);
        INSERT INTO stable_event_drops VALUES('privacy',456);
        """)
        let before = try disk.strings("SELECT id||':'||hex(properties)||':'||timestamp||':'||user_id||':'||delivery_state||':'||origin||':'||COALESCE(hex(journey_origin),'') FROM events ORDER BY id;")
        try await store.initialize(path: disk.root)
        await store.close()
        XCTAssertEqual(try disk.integer("PRAGMA user_version;"), 5)
        XCTAssertEqual(try disk.strings("SELECT id||':'||hex(properties)||':'||timestamp||':'||user_id||':'||delivery_state||':'||origin||':'||COALESCE(hex(journey_origin),'') FROM events ORDER BY id;"), before)
        XCTAssertEqual(try disk.integer("SELECT coverage_start_ms FROM event_history_metadata WHERE scope='legacy-global' AND user_id='';"), 12345)
        XCTAssertEqual(try disk.integer("SELECT COUNT(DISTINCT capture_sequence) FROM events;"), 2)
        XCTAssertEqual(try disk.strings("SELECT id||':'||capture_sequence FROM events ORDER BY rowid;"), ["pending:7", "delivered:42"])
        XCTAssertEqual(try disk.integer("SELECT next_capture_sequence FROM customer_store_metadata WHERE id=1;"), 43)
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM stable_event_drops WHERE event_id='privacy';"), 1)
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM events WHERE scope='legacy-unknown' AND authority_scope IS NULL;"), 2)
    }

    func testFailedUpgradeRollsBackDDLAndVersionFourRows() async throws {
        try disk.withDatabase { try CustomerStoreTestDatabase.createVersion4(on: $0) }
        try disk.execute("""
        INSERT INTO events VALUES('kept','answer',X'7B7D',7,'customer',0,'device',NULL);
        CREATE INDEX idx_events_measurement ON events(id);
        """)
        let before = try disk.strings("SELECT type||':'||name||':'||sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name;")
        let schemaVersion = try disk.integer("PRAGMA schema_version;")
        do { try await store.initialize(path: disk.root); XCTFail("The conflicting index must interrupt the upgrade after earlier DDL") } catch { }
        XCTAssertEqual(try disk.integer("PRAGMA user_version;"), 4)
        XCTAssertEqual(try disk.integer("PRAGMA schema_version;"), schemaVersion)
        XCTAssertEqual(try disk.strings("SELECT type||':'||name||':'||sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name;"), before)
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM events WHERE id='kept' AND delivery_state=0;"), 1)
        await store.close()
    }

    func testCaptureSequenceBackfillFailureReportsSchemaOperationAndRollsBack() async throws {
        try disk.withDatabase { try CustomerStoreTestDatabase.createVersion4(on: $0) }
        try disk.execute("""
        INSERT INTO events VALUES('kept','answer',X'7B7D',7,'customer',0,'device',NULL);
        CREATE TRIGGER reject_backfill BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT,'injected backfill failure'); END;
        """)
        let before = try disk.strings("SELECT type||':'||name||':'||sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name;")
        do {
            try await store.initialize(path: disk.root)
            XCTFail("The injected backfill failure must reject the upgrade")
        } catch let EventStorageError.invalidSchema(error) {
            XCTAssertEqual(error.targetVersion, 5)
            XCTAssertEqual(error.operation, "backfill capture sequence")
            XCTAssertEqual(error.sqliteCode, SQLITE_CONSTRAINT)
            XCTAssertTrue(error.sqliteMessage.contains("injected backfill failure"))
        } catch {
            XCTFail("Expected a schema error identifying the failed backfill, got \(error)")
        }
        XCTAssertEqual(try disk.integer("PRAGMA user_version;"), 4)
        XCTAssertEqual(try disk.strings("SELECT type||':'||name||':'||sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name;"), before)
        XCTAssertEqual(try disk.strings("SELECT id||':'||hex(properties)||':'||timestamp||':'||delivery_state FROM events;"), ["kept:7B7D:7:0"])
        await store.close()
    }

    func testLaggingCaptureSequenceFailsLoudlyWithoutChangingEarlierEvents() async throws {
        try await store.initialize(path: disk.root)
        let acceptedAt = Date(timeIntervalSince1970: 100)
        for id in ["first", "second"] {
            let event = try StoredEvent(id: id, name: "answer", timestamp: acceptedAt, distinctId: owner.userId)
            _ = try await store.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: true, acceptedAt: acceptedAt)
        }
        let before = try disk.strings("SELECT id||':'||hex(properties)||':'||timestamp||':'||delivery_state||':'||capture_sequence FROM events ORDER BY id;")
        let inboxBefore = try disk.strings("SELECT event_id||':'||hex(payload)||':'||accepted_at FROM conversion_event_inbox ORDER BY event_id;")
        try disk.execute("UPDATE customer_store_metadata SET next_capture_sequence=1 WHERE id=1;")
        for id in ["rejected", "also-rejected"] {
            let event = try StoredEvent(id: id, name: "answer", timestamp: acceptedAt, distinctId: owner.userId)
            do {
                _ = try await store.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: true, acceptedAt: acceptedAt)
                XCTFail("A trigger that leaves a capture sequence at zero must fail the capture")
            } catch let EventStorageError.insertFailed(error) {
                XCTAssertTrue(error.localizedDescription.contains("capture sequence"))
            } catch {
                XCTFail("Expected an explicit capture sequence failure, got \(error)")
            }
            XCTAssertEqual(try disk.strings("SELECT id||':'||hex(properties)||':'||timestamp||':'||delivery_state||':'||capture_sequence FROM events ORDER BY id;"), before)
            XCTAssertEqual(try disk.strings("SELECT event_id||':'||hex(payload)||':'||accepted_at FROM conversion_event_inbox ORDER BY event_id;"), inboxBefore)
            XCTAssertEqual(try disk.integer("SELECT next_capture_sequence FROM customer_store_metadata WHERE id=1;"), 1)
        }
        try disk.execute("UPDATE customer_store_metadata SET next_capture_sequence=3 WHERE id=1;")
        let recovered = try StoredEvent(id: "recovered", name: "answer", timestamp: acceptedAt, distinctId: owner.userId)
        let commit = try await store.insert(recovered, deliveryState: .pending, origin: .device, assigningCommitSequence: true, acceptedAt: acceptedAt)
        XCTAssertTrue(commit.newlyDurable)
        XCTAssertEqual(commit.commitSequence, 2)
        XCTAssertEqual(try disk.integer("SELECT capture_sequence FROM events WHERE id='recovered';"), 3)
        await store.close()
    }

    func testUnallocatedSequenceCannotBlockLaterInsertions() async throws {
        try await store.initialize(path: disk.root)
        let event = try StoredEvent(id: "first", name: "answer", distinctId: owner.userId)
        _ = try await store.insert(event, deliveryState: .pending)
        try disk.execute("""
        UPDATE customer_store_metadata SET next_capture_sequence=1 WHERE id=1;
        INSERT OR IGNORE INTO events(id,name,properties,timestamp,user_id)
          VALUES('unallocated','answer',X'7B7D',1,'customer');
        """)
        XCTAssertEqual(try disk.integer("SELECT capture_sequence FROM events WHERE id='unallocated';"), 0)
        let later = try StoredEvent(id: "later", name: "answer", distinctId: owner.userId)
        let committed = try await store.insert(later, deliveryState: .pending, origin: .device, assigningCommitSequence: false)
        XCTAssertTrue(committed.newlyDurable)
        XCTAssertEqual(try disk.integer("SELECT capture_sequence FROM events WHERE id='later';"), 2)
        XCTAssertEqual(try disk.integer("SELECT capture_sequence FROM events WHERE id='first';"), 1)
        XCTAssertEqual(try disk.integer("SELECT capture_sequence FROM events WHERE id='unallocated';"), 0)
        await store.close()
    }

    func testFutureSchemaRefusesWithoutChangingAnyObject() async throws {
        try disk.execute("CREATE TABLE future_private_state(value BLOB); INSERT INTO future_private_state VALUES(X'010203'); PRAGMA user_version=99;")
        let before = try disk.strings("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name;")
        do { try await store.initialize(path: disk.root); XCTFail("Future versions must fail closed") } catch { }
        XCTAssertEqual(try disk.integer("PRAGMA user_version;"), 99)
        XCTAssertEqual(try disk.strings("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name;"), before)
        XCTAssertEqual(try disk.strings("SELECT hex(value) FROM future_private_state;"), ["010203"])
        await store.close()
    }

    func testCustomersAndAuthoritiesHaveIndependentScopesAndCoverage() async throws {
        try await store.initialize(path: disk.root)
        let scopes: [JourneyStorageScope] = [.testFixture, .init(namespaceHash: "other-authority")]
        var owners: [CustomerStoreOwner] = []
        for scope in scopes {
            for user in ["customer", "other-customer"] {
                let owner = CustomerStoreOwner(scope: scope, userId: user)
                owners.append(owner)
                let epoch = Int64(owners.count)
                try await store.putCustomerScope(.init(owner: owner, executionEpoch: epoch, executionRevoked: epoch % 2 == 0, openedStateVersion: "device-customer-state-v1"))
                try await store.advanceHistoryCoverage(owner: owner, to: epoch * 100)
            }
        }
        for (index, owner) in owners.enumerated() {
            let scope = try await store.customerScope(owner: owner)
            let coverage = try await store.historyCoverage(owner: owner)
            XCTAssertEqual(scope?.executionEpoch, Int64(index + 1))
            XCTAssertEqual(coverage, Int64(index + 1) * 100)
        }
        try await store.advanceHistoryCoverage(owner: owners[0], to: .max)
        let unaffected = try await store.historyCoverage(owner: owners[1])
        XCTAssertEqual(unaffected, 200)
        await store.close()
    }

    func testForeignKeysRejectOrphansAndCrossCustomerEventReferencesOnWriter() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        let missing = CustomerJourneyKey(owner: owner, journeyId: "missing", legGeneration: 0)
        let sha = String(repeating: "a", count: 64)
        let pin = CustomerReleasePin(objectSHA256: sha, kind: .descriptor,
            relativePath: owner.scope.customerDigest(distinctId: owner.userId) + "/" + sha + ".json", sizeBytes: 1)
        do { try await store.replaceReleasePins(for: missing, pins: [pin]); XCTFail("The writer connection must enforce the Journey foreign key") } catch { }
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM journey_release_pins;"), 0)
        let authority = CustomerStoreTestDatabase.quoted(owner.authorityScope)
        try disk.execute("INSERT INTO events(id,name,properties,timestamp,user_id,scope) VALUES('foreign','answer',X'7B7D',1,'other',\(authority));")
        XCTAssertThrowsError(try disk.execute("INSERT INTO journey_event_applications VALUES(\(authority),'customer','foreign','target',NULL,NULL,NULL,'applied',1);"))
        XCTAssertThrowsError(try disk.execute("INSERT INTO journey_waits VALUES(\(authority),'customer','missing',0,0,'step','event',1,NULL,NULL,NULL);"))
        XCTAssertThrowsError(try disk.seedJourney(owner: owner, journeyId: "duplicate-experience"))
        XCTAssertEqual(try disk.strings("PRAGMA foreign_key_check;"), [])
        await store.close()
    }

    func testEffectProvenanceSurvivesJourneyDeletionAndResultIdentityIsImmutable() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        let authority = CustomerStoreTestDatabase.quoted(owner.authorityScope)
        try disk.execute("""
        INSERT INTO events(id,name,properties,timestamp,user_id,scope) VALUES('first-result','answer',X'7B7D',1,'customer',\(authority));
        INSERT INTO events(id,name,properties,timestamp,user_id,scope) VALUES('second-result','answer',X'7B7D',2,'customer',\(authority));
        INSERT INTO journey_effects VALUES(\(authority),'customer','journey',0,'effect','step','commerce','applied',NULL,NULL,'first-result',1);
        DELETE FROM journeys;
        """)
        XCTAssertEqual(try disk.strings("SELECT journey_id||':'||result_event_id FROM journey_effects;"), ["journey:first-result"])
        XCTAssertThrowsError(try disk.execute("UPDATE journey_effects SET result_event_id='second-result';"))
        XCTAssertThrowsError(try disk.execute("UPDATE journey_effects SET result_event_id=NULL;"))
        XCTAssertThrowsError(try disk.execute("DELETE FROM events WHERE id='first-result';"))
        await store.close()
    }

    func testEveryRequiredIndexHasTheOrderedColumnsAndUniqueness() async throws {
        try await store.initialize(path: disk.root)
        let expected: [(String, [String])] = [
            ("idx_events_scope_name_time", ["scope", "user_id", "name", "timestamp", "id"]),
            ("idx_events_scope_time", ["scope", "user_id", "timestamp", "id"]),
            ("idx_events_measurement", ["scope", "user_id", "measurement_state", "capture_sequence"]),
            ("idx_events_journey_role", ["scope", "user_id", "journey_id", "leg_generation", "event_role"]),
            ("idx_events_capture_sequence", ["capture_sequence"]), ("idx_events_owner_id", ["scope", "user_id", "id"]),
            ("idx_journey_waits_deadline", ["authority_scope", "user_id", "deadline_at"]),
            ("idx_journey_pending_work_due", ["next_attempt_at", "authority_scope", "user_id", "journey_id"]),
            ("idx_journey_watches_expiry", ["authority_scope", "user_id", "expires_at", "basis_at"]),
            ("idx_journey_effect_results", ["authority_scope", "user_id", "result_event_id"]),
        ]
        let actual = Set(try disk.strings("SELECT name FROM sqlite_master WHERE type='index';"))
        for (name, columns) in expected {
            XCTAssertTrue(actual.contains(name), name)
            XCTAssertEqual(try disk.strings("SELECT name FROM pragma_index_info('\(name)') ORDER BY seqno;"), columns, name)
        }
        XCTAssertEqual(try disk.integer("SELECT \"unique\" FROM pragma_index_list('events') WHERE name='idx_events_capture_sequence';"), 1)
        XCTAssertEqual(try disk.integer("SELECT partial FROM pragma_index_list('events') WHERE name='idx_events_capture_sequence';"), 1)
        await store.close()
    }

    func testReadOnlyAccessCannotCreateMigrateOrWriteAndSeesCommittedWAL() async throws {
        let absent = disk.root.appendingPathComponent("missing")
        let reader = SQLiteEventStore(accessMode: .readOnly)
        do { try await reader.initialize(path: absent); XCTFail("A reader must not create a missing database") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        try disk.withDatabase { try CustomerStoreTestDatabase.createVersion4(on: $0) }
        do { try await reader.initialize(path: disk.root); XCTFail("A reader must not migrate version four") } catch { }
        XCTAssertEqual(try disk.integer("PRAGMA user_version;"), 4)
        try await store.initialize(path: disk.root)
        let first = try StoredEvent(id: "first", name: "answer", distinctId: owner.userId)
        _ = try await store.insert(first, deliveryState: .pending)
        try await reader.initialize(path: disk.root)
        let read = try await reader.queryEvent(id: "first")
        XCTAssertEqual(read?.id, "first")
        do {
            try await reader.putCustomerScope(.init(owner: owner, executionEpoch: 0, executionRevoked: false, openedStateVersion: "device-customer-state-v1"))
            XCTFail("A read-only connection must refuse customer mutations")
        } catch { }
        let second = try StoredEvent(id: "second", name: "answer", distinctId: owner.userId)
        _ = try await store.insert(second, deliveryState: .pending)
        let committed = try await reader.queryEvent(id: "second")
        XCTAssertEqual(committed?.id, "second")
        await reader.reset()
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.databaseURL.path))
        await store.close()
    }

    func testLargeExactJSONAndInt64TimesSurviveSQLAndReopen() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        let json = Data(("{\"é\":\"composed\",\"e\\u0301\":\"decomposed\",\"large\":\"" + String(repeating: "x", count: 1_100_000) + "\"}").utf8)
        let answers = try ExactJSONCodec.decode(ExactJSONObject<JourneyReleaseJSONValue>.self, from: json)
        let sheet = JourneyResponseSave(distinctId: owner.userId, journeyId: "journey", experienceId: "experience", experienceVersionId: "version", formName: "form", sequence: 9_007_199_254_740_991, answers: answers)
        let retry = CustomerResponseSaveRetry(attempts: .max, observedAt: .min, nextAttemptAt: .max, unknownFormSince: .min, lastCode: .unknownForm)
        let lane = CustomerResponseSaveLane(experienceId: "experience", versionId: "version", sequence: sheet.sequence, pending: sheet, retry: retry, display: .saving(sequence: sheet.sequence))
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: lane)
        await store.close()
        try await store.initialize(path: disk.root)
        let read = try await store.responseSaveLane(owner: owner, journeyId: "journey", formName: "form")
        let restored = try XCTUnwrap(read)
        XCTAssertEqual(restored.pending, sheet)
        XCTAssertEqual(restored.retry, retry)
        XCTAssertEqual(restored.pending?.answers.count, 3)
        XCTAssertEqual(try disk.integer("SELECT observed_at FROM journey_response_saves;"), Int64.min)
        XCTAssertEqual(try disk.integer("SELECT next_attempt_at FROM journey_response_saves;"), Int64.max)
        XCTAssertEqual(try disk.integer("SELECT started_at FROM journeys;"), Int64.min)
        XCTAssertGreaterThan(try disk.integer("SELECT length(pending_answers_json) FROM journey_response_saves;"), 1_100_000)
        await store.close()
    }
}
