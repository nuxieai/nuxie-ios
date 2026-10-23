import Foundation
import XCTest
@testable import Nuxie

final class CustomerStoreCutoverTests: XCTestCase {
    private var disk: CustomerStoreTestDatabase!
    private var store: SQLiteEventStore!
    private let owner = CustomerStoreOwner(scope: .testFixture, userId: "customer")

    override func setUpWithError() throws { disk = try CustomerStoreTestDatabase(); store = SQLiteEventStore() }
    override func tearDownWithError() throws { try disk.remove(); disk = nil; store = nil }

    private func seedOldState() async throws {
        try await store.initialize(path: disk.root)
        try await store.bindConversionAuthority(owner.scope)
        let event = try StoredEvent(id: "ordinary", name: "answer", properties: ["answer": 42], distinctId: owner.userId)
        _ = try await store.insert(event, deliveryState: .pending)
        try disk.seedJourney(owner: owner)
        let authority = CustomerStoreTestDatabase.quoted(owner.authorityScope)
        try disk.execute("""
        INSERT INTO journey_cursors VALUES(\(authority),'customer','journey',0,'ordinary',1,0,0,NULL,NULL,NULL,NULL,0,0);
        INSERT INTO journey_waits VALUES(\(authority),'customer','journey',0,1,'step','event',1,20,NULL,NULL);
        INSERT INTO journey_frequency VALUES(\(authority),'customer','experience',1,1);
        INSERT INTO journey_arm_receipts VALUES(\(authority),'customer','arm',X'7B7D',X'7B7D','event',NULL,0,'consumed',NULL);
        INSERT INTO journey_event_applications VALUES(\(authority),'customer','ordinary','input','journey',0,0,'applied',1);
        INSERT INTO journey_effects VALUES(\(authority),'customer','journey',0,'effect','step','commerce','awaiting_result',NULL,NULL,NULL,NULL);
        INSERT INTO journey_experiment_selections VALUES(\(authority),'customer','journey',0,'experiment','variant',0,'assigned','exposure',1,NULL,NULL);
        INSERT INTO journey_conversion_watches VALUES(\(authority),'customer','journey','experience','version','policy',X'7B7D',X'7B7D',1,NULL,NULL,20,NULL,NULL,NULL,NULL,30);
        INSERT INTO journey_response_saves VALUES(\(authority),'customer','journey','form','experience','version',1,1,X'7B7D',1,1,0,'',0,NULL,NULL,NULL,NULL);
        INSERT INTO journey_release_pins VALUES(\(authority),'customer','journey',0,'descriptor','descriptor','legacy.json',2);
        INSERT INTO journey_pending_work VALUES(\(authority),'customer','input','input','journey',0,0,'ordinary','input','failed',1,1,2,'retry');
        INSERT INTO stable_event_drops VALUES('privacy',1);
        INSERT INTO stable_event_routes VALUES('ordinary',0);
        INSERT INTO committed_route_deliveries VALUES('ordinary','session',0,X'7B7D',0);
        """)
    }

    private var executionTables: [String] {
        ["customer_scopes", "journey_execution_snapshots", "journeys", "journey_cursors", "journey_waits", "journey_frequency", "journey_arm_receipts",
         "journey_event_applications", "journey_effects", "journey_experiment_selections", "journey_conversion_watches", "journey_response_saves", "journey_release_pins", "journey_pending_work"]
    }

    func testGateDiscardsOldJourneyStateBeforeDecodingAndPreservesOrdinaryEvidence() async throws {
        try disk.withDatabase { try CustomerStoreTestDatabase.createVersion4(on: $0) }
        try await seedOldState()
        let legacyDirectory = disk.root.appendingPathComponent("journey-journal-v2")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let journal = legacyDirectory.appendingPathComponent(owner.scope.customerDigest(distinctId: owner.userId) + ".json")
        let invalidJournal = Data("not decodable as a journal".utf8)
        try invalidJournal.write(to: journal)
        let revocation = journal.deletingPathExtension().appendingPathExtension("revoked")
        try Data("revoked".utf8).write(to: revocation)
        let protectedFiles = ["pending-purchases.json", "transaction-evidence.json", "account-ownership.json", "feature-use-commands-v1.json", "entitlements.json"]
        for name in protectedFiles { try Data(name.utf8).write(to: disk.root.appendingPathComponent(name)) }
        let eventBefore = try disk.strings("SELECT hex(properties)||':'||timestamp||':'||delivery_state||':'||origin FROM events;")
        await store.close()
        store = SQLiteEventStore()
        try await store.initialize(path: disk.root)
        let beforeGate = try await store.customerMetadata()
        XCTAssertEqual(beforeGate.stateVersion, "legacy")
        XCTAssertEqual(try disk.integer("PRAGMA user_version;"), 5)
        XCTAssertEqual(try Data(contentsOf: journal), invalidJournal)
        for table in executionTables { XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM \(table);"), 1, table) }
        let metadata = try await store.openCustomerState(cutoverAt: 500)
        XCTAssertEqual(metadata.stateVersion, "device-customer-state-v1")
        XCTAssertEqual(metadata.cutoverSequence, 1)
        XCTAssertTrue(metadata.legacyCleanupPending)
        for table in executionTables { XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM \(table);"), 0, table) }
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM sqlite_master WHERE name='conversion_event_inbox';"), 0)
        XCTAssertEqual(try disk.strings("SELECT hex(properties)||':'||timestamp||':'||delivery_state||':'||origin FROM events;"), eventBefore)
        XCTAssertEqual(try disk.strings("SELECT journey_plan_state||':'||measurement_state FROM events;"), ["retired:done"])
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM stable_event_drops WHERE event_id='privacy';"), 1)
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM stable_event_routes;"), 1)
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM committed_route_deliveries;"), 1)
        XCTAssertEqual(try Data(contentsOf: journal), invalidJournal)
        XCTAssertEqual(try Data(contentsOf: revocation), Data("revoked".utf8))
        for name in protectedFiles { XCTAssertEqual(try Data(contentsOf: disk.root.appendingPathComponent(name)), Data(name.utf8)) }
        let pending = try await store.queryPendingDelivery(limit: 10)
        XCTAssertEqual(pending.map(\.id), ["ordinary"])
        let coverage = try await store.historyCoverage(owner: owner)
        XCTAssertEqual(coverage, 500)
        try disk.seedJourney(owner: owner, journeyId: "new-journey")
        await store.close()
        store = SQLiteEventStore()
        try await store.initialize(path: disk.root)
        let second = try await store.openCustomerState(cutoverAt: 999)
        XCTAssertEqual(second, metadata)
        XCTAssertEqual(try disk.strings("SELECT journey_id FROM journeys;"), ["new-journey"])
        XCTAssertEqual(try Data(contentsOf: journal), invalidJournal)
        await store.close()
    }

    func testCutoverFencesIncompleteScopedHistoryEvenWithProvenEvents() async throws {
        try disk.withDatabase { try CustomerStoreTestDatabase.createVersion4(on: $0) }
        let authority = CustomerStoreTestDatabase.quoted(owner.authorityScope)
        try disk.execute("""
        INSERT INTO events VALUES('proven','answer',X'7B7D',200,'customer',0,'device',NULL);
        INSERT INTO events VALUES('delivered','purchase',X'7B7D',250,'customer',2,'device',NULL);
        INSERT INTO events VALUES('unproven','answer',X'7B7D',200,'other-customer',2,'device',NULL);
        INSERT INTO events VALUES('unproven-authority','answer',X'7B7D',200,'other-customer',2,'device',NULL);
        INSERT INTO event_history_metadata VALUES(1,100);
        INSERT INTO conversion_scope_bindings VALUES('capture-old-key',\(authority));
        INSERT INTO conversion_event_inbox VALUES('proven','customer',X'7B7D',200,\(authority));
        INSERT INTO conversion_event_inbox VALUES('unproven','other-customer',X'7B7D',200,'capture-unbound');
        """)
        try await store.initialize(path: disk.root)
        try disk.execute("UPDATE events SET authority_scope='authority-unproven',scope='authority-unproven' WHERE id='unproven-authority';")
        await store.close()
        store = SQLiteEventStore()
        try await store.initialize(path: disk.root)
        _ = try await store.openCustomerState(cutoverAt: 500)
        let scopedCoverage = try await store.historyCoverage(owner: owner)
        let coverageStart = try XCTUnwrap(scopedCoverage)
        XCTAssertEqual(coverageStart, 500)
        let coverage = EventHistoryCoverage.retainedWindow(startingAt: Date(timeIntervalSince1970: Double(coverageStart) / 1000))
        let querySince = Date(timeIntervalSince1970: 0.150)
        XCTAssertFalse(coverage.contains(since: querySince), "A pre-cutover history question must remain incomplete even when individual events have proven authority")
        XCTAssertTrue(coverage.contains(since: Date(timeIntervalSince1970: 0.500)))
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM events WHERE scope=\(authority) AND user_id='customer' AND name='purchase' AND timestamp BETWEEN 150 AND 400;"), 0)
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM events WHERE scope='legacy-unknown' AND user_id='customer' AND name='purchase' AND timestamp BETWEEN 150 AND 400 AND delivery_state=2;"), 1)
        XCTAssertEqual(try disk.integer("SELECT coverage_start_ms FROM event_history_metadata WHERE scope='legacy-unknown' AND user_id='customer';"), 500)
        XCTAssertEqual(try disk.integer("SELECT coverage_start_ms FROM event_history_metadata WHERE scope='legacy-unknown' AND user_id='other-customer';"), 500)
        XCTAssertEqual(try disk.integer("SELECT coverage_start_ms FROM event_history_metadata WHERE scope='authority-unproven' AND user_id='other-customer';"), 500)
        XCTAssertEqual(try disk.integer("SELECT coverage_start_ms FROM event_history_metadata WHERE scope='legacy-global' AND user_id='';"), 100)
        XCTAssertEqual(try disk.strings("SELECT scope FROM events WHERE id='proven';"), [owner.authorityScope])
        await store.close()
    }

    func testSecondLaunchDoesNotDiscardNewStateOrRepeatCleanup() async throws {
        try await seedOldState()
        let first = try await store.openCustomerState(cutoverAt: 500)
        try await store.finishLegacyCleanup(cutoverSequence: first.cutoverSequence)
        try disk.seedJourney(owner: owner, journeyId: "new-journey")
        let newEvent = try StoredEvent(id: "new-event", name: "answer", distinctId: owner.userId)
        _ = try await store.insert(newEvent, deliveryState: .pending)
        await store.close()
        try await store.initialize(path: disk.root)
        let second = try await store.openCustomerState(cutoverAt: 999)
        XCTAssertEqual(second.stateVersion, first.stateVersion)
        XCTAssertEqual(second.cutoverSequence, first.cutoverSequence)
        XCTAssertFalse(second.legacyCleanupPending)
        XCTAssertEqual(second.nextCaptureSequence, 3)
        XCTAssertEqual(try disk.strings("SELECT journey_plan_state||':'||measurement_state FROM events WHERE id='new-event';"), ["pending:pending"])
        XCTAssertEqual(try disk.strings("SELECT journey_id FROM journeys;"), ["new-journey"])
        let coverage = try await store.historyCoverage(owner: owner)
        XCTAssertEqual(coverage, 500)
        await store.close()
    }

    func testFailureInsideGateRollsBackDeletesEventChangesAndInboxDDL() async throws {
        try await seedOldState()
        let before = try disk.strings("SELECT scope||':'||journey_plan_state||':'||measurement_state||':'||capture_sequence FROM events;")
        let metadataBefore = try await store.customerMetadata()
        // The final failure occurs after the inbox DROP, proving transactional DDL too.
        for failure in ["BEFORE DELETE ON journey_frequency", "BEFORE INSERT ON event_history_metadata", "BEFORE UPDATE ON customer_store_metadata"] {
            try disk.execute("CREATE TRIGGER interrupt_cutover \(failure) BEGIN SELECT RAISE(ABORT,'interrupted'); END;")
            do { _ = try await store.openCustomerState(cutoverAt: 500); XCTFail("An interrupted gate must fail") } catch { }
            XCTAssertEqual(try disk.strings("SELECT scope||':'||journey_plan_state||':'||measurement_state||':'||capture_sequence FROM events;"), before)
            let metadataAfter = try await store.customerMetadata()
            XCTAssertEqual(metadataAfter, metadataBefore)
            for table in executionTables { XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM \(table);"), 1, table) }
            XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM conversion_event_inbox;"), 1)
            XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM event_history_metadata;"), 0)
            try disk.execute("DROP TRIGGER interrupt_cutover;")
        }
        await store.close()
        try await store.initialize(path: disk.root)
        let afterReopen = try await store.customerMetadata()
        XCTAssertEqual(afterReopen, metadataBefore)
        await store.close()
    }

    func testFutureStateVersionFailsClosedAndKeepsOldState() async throws {
        try await seedOldState()
        try disk.execute("UPDATE customer_store_metadata SET state_version='device-customer-state-v99';")
        do {
            _ = try await store.openCustomerState(cutoverAt: 500)
            XCTFail("Unknown semantic versions must be refused")
        } catch CustomerStoreError.unsupportedStateVersion(let value) {
            XCTAssertEqual(value, "device-customer-state-v99")
        }
        for table in executionTables { XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM \(table);"), 1, table) }
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM conversion_event_inbox;"), 1)
        XCTAssertEqual(try disk.strings("SELECT journey_plan_state||':'||measurement_state FROM events;"), ["pending:pending"])
        await store.close()
    }

    func testLegacyEventsGainAuthorityOnlyFromAnImmutableBinding() async throws {
        try disk.withDatabase { try CustomerStoreTestDatabase.createVersion4(on: $0) }
        let authority = CustomerStoreTestDatabase.quoted(owner.authorityScope)
        try disk.execute("""
        INSERT INTO events VALUES('proven','answer',X'7B7D',1,'customer',0,'device',NULL);
        INSERT INTO events VALUES('unproven','answer',X'7B7D',1,'customer',2,'device',NULL);
        INSERT INTO conversion_scope_bindings VALUES('capture-old-key',\(authority));
        INSERT INTO conversion_event_inbox VALUES('proven','customer',X'7B7D',1,\(authority));
        INSERT INTO conversion_event_inbox VALUES('unproven','customer',X'7B7D',1,'capture-unbound');
        """)
        try await store.initialize(path: disk.root)
        _ = try await store.openCustomerState(cutoverAt: 500)
        XCTAssertEqual(try disk.strings("SELECT scope FROM events WHERE id='proven';"), [owner.authorityScope])
        XCTAssertEqual(try disk.strings("SELECT scope FROM events WHERE id='unproven';"), ["legacy-unknown"])
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM events WHERE id='unproven' AND authority_scope IS NULL;"), 1)
        await store.close()
    }
}
