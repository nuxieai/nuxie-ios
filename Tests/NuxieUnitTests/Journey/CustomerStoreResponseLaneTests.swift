import Foundation
import XCTest
@testable import Nuxie

final class CustomerStoreResponseLaneTests: XCTestCase {
    private var disk: CustomerStoreTestDatabase!
    private var store: SQLiteEventStore!
    private let owner = CustomerStoreOwner(scope: .testFixture, userId: "customer")

    override func setUpWithError() throws { disk = try CustomerStoreTestDatabase(); store = SQLiteEventStore() }
    override func tearDownWithError() throws { try disk.remove(); disk = nil; store = nil }

    private func lane(owner: CustomerStoreOwner? = nil, journeyId: String = "journey", sequence: Int64 = 7) -> CustomerResponseSaveLane {
        let sheet = JourneyResponseSave(distinctId: (owner ?? self.owner).userId, journeyId: journeyId,
            experienceId: "experience", experienceVersionId: "version", formName: "form", sequence: sequence,
            answers: ["answer": .string("exact"), "number": .number(1.5), "absent": .null])
        return CustomerResponseSaveLane(experienceId: "experience", versionId: "version", sequence: sequence, pending: sheet,
            retry: .init(attempts: 3, observedAt: 123, nextAttemptAt: 456, unknownFormSince: 100, lastCode: .unknownForm),
            display: .init(sequence: sequence, saving: false, saved: false, saveError: "unknown_form"))
    }

    func testLaneRoundTripsEveryWireRetryAndDisplayFieldThroughSQL() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        let expected = lane()
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: expected)
        await store.close()
        try await store.initialize(path: disk.root)
        let read = try await store.responseSaveLane(owner: owner, journeyId: "journey", formName: "form")
        let restored = try XCTUnwrap(read)
        XCTAssertEqual(restored.sequence, 7)
        XCTAssertEqual(restored.pending, expected.pending)
        XCTAssertEqual(restored.retry, expected.retry)
        XCTAssertEqual(restored.display, expected.display)
        let sheet = try XCTUnwrap(restored.pending)
        XCTAssertEqual(try sheet.encodedForTransport(apiKey: "key"), try XCTUnwrap(expected.pending).encodedForTransport(apiKey: "key"))
        XCTAssertEqual(try disk.strings("SELECT user_id||':'||journey_id||':'||form_name||':'||experience_id||':'||version_id||':'||sequence||':'||pending_sequence||':'||display_sequence||':'||saving||':'||saved||':'||save_error||':'||attempts||':'||observed_at||':'||next_attempt_at||':'||unknown_form_since||':'||last_code FROM journey_response_saves;"), ["customer:journey:form:experience:version:7:7:7:0:0:unknown_form:3:123:456:100:unknown_form"])
        await store.close()
    }

    func testAnotherCustomerAuthorityOrJourneyCannotReadOrWriteTheLane() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: lane())
        for other in [CustomerStoreOwner(scope: .testFixture, userId: "other"), CustomerStoreOwner(scope: .init(namespaceHash: "other"), userId: "customer")] {
            let invisible = try await store.responseSaveLane(owner: other, journeyId: "journey", formName: "form")
            XCTAssertNil(invisible)
            do { try await store.putResponseSaveLane(owner: other, journeyId: "journey", formName: "form", lane: lane()); XCTFail("A foreign owner must not reserve or replace a lane") } catch JourneyResponseSaveError.wrongOwner { }
        }
        let invisible = try await store.responseSaveLane(owner: owner, journeyId: "other-journey", formName: "form")
        XCTAssertNil(invisible)
        do { try await store.putResponseSaveLane(owner: owner, journeyId: "other-journey", formName: "form", lane: lane()); XCTFail("The pending sheet must belong to the addressed Journey") } catch JourneyResponseSaveError.wrongOwner { }
        do { try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "other-form", lane: lane()); XCTFail("The pending sheet must belong to the addressed form") } catch JourneyResponseSaveError.wrongOwner { }
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM journey_response_saves;"), 1)
        await store.close()
    }

    func testNewLaneRequiresAnOwnedJourneyAndPinnedExperienceVersion() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        for invalid in [lane(journeyId: "absent"), CustomerResponseSaveLane(experienceId: "different", versionId: "version", sequence: 1, pending: nil, retry: nil, display: nil),
                        CustomerResponseSaveLane(experienceId: "experience", versionId: "different", sequence: 1, pending: nil, retry: nil, display: nil)] {
            do { try await store.putResponseSaveLane(owner: owner, journeyId: invalid.pending?.journeyId ?? "journey", formName: "form", lane: invalid); XCTFail("Lane ownership must be authenticated by an existing Journey") } catch JourneyResponseSaveError.wrongOwner { }
        }
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM journey_response_saves;"), 0)
        await store.close()
    }

    func testIndependentCustomersAndAuthoritiesCanOwnIdenticallyNamedLanes() async throws {
        try await store.initialize(path: disk.root)
        var owners: [CustomerStoreOwner] = []
        for scope in [JourneyStorageScope.testFixture, .init(namespaceHash: "other")] {
            for user in ["customer", "other"] { owners.append(.init(scope: scope, userId: user)) }
        }
        for (index, owner) in owners.enumerated() {
            try disk.seedJourney(owner: owner)
            try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: lane(owner: owner, sequence: Int64(index + 1)))
        }
        for (index, owner) in owners.enumerated() {
            let restored = try await store.responseSaveLane(owner: owner, journeyId: "journey", formName: "form")
            XCTAssertEqual(restored?.sequence, Int64(index + 1))
        }
        XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM journey_response_saves;"), 4)
        await store.close()
    }

    func testSequenceBoundsRejectInvalidWritesAndLeavePreviousLaneUntouched() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: lane())
        for sequence in [Int64(-1), 9_007_199_254_740_992, Int64.max] {
            do { try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: lane(sequence: sequence)); XCTFail("Sequences must stay in the wire-safe integer range") } catch JourneyResponseSaveError.sequenceExhausted { }
        }
        for assignment in ["sequence=-1", "sequence=9007199254740992", "sequence=7.5", "pending_sequence=7.5", "pending_sequence=0", "pending_sequence=8", "display_sequence=0", "display_sequence=8", "pending_answers_json=NULL", "saving=2", "saved=-1", "attempts=-1"] {
            XCTAssertThrowsError(try disk.execute("UPDATE journey_response_saves SET \(assignment);"), assignment)
        }
        let restored = try await store.responseSaveLane(owner: owner, journeyId: "journey", formName: "form")
        XCTAssertEqual(restored?.sequence, 7)
        XCTAssertEqual(restored?.pending?.sequence, 7)
        await store.close()
    }

    func testPendingAndDisplayMayLagLatestSequenceAndLaneSurvivesCompletion() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        let previous = lane()
        let next = CustomerResponseSaveLane(experienceId: "experience", versionId: "version", sequence: 9,
            pending: previous.pending, retry: previous.retry, display: previous.display)
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: next)
        try disk.execute("DELETE FROM journeys;")
        let cleared = CustomerResponseSaveLane(experienceId: "experience", versionId: "version", sequence: 9, pending: nil, retry: nil, display: nil)
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: cleared)
        let restored = try await store.responseSaveLane(owner: owner, journeyId: "journey", formName: "form")
        XCTAssertEqual(restored?.sequence, 9)
        XCTAssertNil(restored?.pending)
        XCTAssertNil(restored?.retry)
        XCTAssertNil(restored?.display)
        await store.close()
    }

    func testAContinuationCanReplaceThePendingVersionOnlyWithOwnedJourneyAuthority() async throws {
        try await store.initialize(path: disk.root)
        try disk.seedJourney(owner: owner)
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: lane())
        let sheet = JourneyResponseSave(distinctId: owner.userId, journeyId: "journey", experienceId: "experience", experienceVersionId: "next-version",
            formName: "form", sequence: 8, answers: ["answer": .string("next")])
        let next = CustomerResponseSaveLane(experienceId: "experience", versionId: "next-version", sequence: 8, pending: sheet, retry: nil, display: .saving(sequence: 8))
        do { try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: next); XCTFail("A lane cannot invent a pinned version") } catch JourneyResponseSaveError.wrongOwner { }
        try disk.execute("UPDATE journeys SET version_id='next-version',leg_generation=1;")
        try await store.putResponseSaveLane(owner: owner, journeyId: "journey", formName: "form", lane: next)
        let restored = try await store.responseSaveLane(owner: owner, journeyId: "journey", formName: "form")
        XCTAssertEqual(restored?.versionId, "next-version")
        XCTAssertEqual(restored?.pending, sheet)
        await store.close()
    }

    func testLocalOnlyInputIsExcludedFromUploadHistoryAndConversionInbox() async throws {
        try await store.initialize(path: disk.root)
        let event = try StoredEvent(id: "local", name: "response", distinctId: owner.userId)
        _ = try await store.insert(event, deliveryState: .localOnly)
        let upload = try await store.queryPendingDelivery(limit: 10)
        let history = try await store.queryEventsForUser(owner.userId, limit: 10)
        let recent = try await store.queryRecentEvents(limit: 10)
        let count = try await store.countEvents(name: "response", distinctId: owner.userId, since: nil, until: nil)
        let conversions = try await store.measurementInputs(distinctId: owner.userId)
        XCTAssertTrue(upload.isEmpty)
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(recent.isEmpty)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(conversions.isEmpty)
        XCTAssertEqual(try disk.integer("SELECT delivery_state FROM events WHERE id='local';"), 3)
        XCTAssertEqual(try disk.strings("SELECT input_kind FROM events WHERE id='local';"), ["response_change"])
        await store.close()
    }
}
