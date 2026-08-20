#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import XCTest
@testable import Nuxie

final class ResponseSessionModuleTests: XCTestCase {
    func testOperationReceiptRoundTripsForDurableJourneyPersistence() throws {
        let snapshot = ResponseSessionSnapshot(
            responseId: "rsp_test",
            journeyId: "journey-1",
            responseSchemaKey: "survey",
            responseSchemaVersionId: "survey-v1",
            schemaVersion: 1,
            state: .draft,
            values: ["reason": .string("price")],
            version: 1,
            createdAt: "2026-08-17T20:00:00Z",
            updatedAt: "2026-08-17T20:00:00Z",
            submittedAt: nil,
            abandonedAt: nil
        )
        let result = ResponseSessionOperationResult.accepted(status: .changed, snapshot: snapshot)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ResponseSessionOperationResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testDeterministicIdentityUsesPortableUTF8Vector() throws {
        XCTAssertEqual(
            try deriveResponseSessionId(journeyId: "journey-1"),
            "rsp_fdf96a130d4da11a334943fddeae435c692b09f043d68c86a2c0298edbe8def7"
        )
        XCTAssertEqual(
            try deriveResponseSessionId(journeyId: "é"),
            "rsp_10c43ce5a71ba6aef1b16665f36c31e8c6c3c9cd0906b971535336dc659148fa"
        )
    }

    func testDraftVersioningCanonicalizationAndReplay() async throws {
        let (store, module) = try await setup()
        let first = try await module.set(
            run: run,
            emissionId: "emission-1",
            screenId: "question",
            field: "reason",
            value: .string("price"),
            occurredAt: "2026-08-17T20:00:00Z"
        )
        let second = try await module.set(
            run: run,
            emissionId: "emission-2",
            screenId: "question",
            field: "channels",
            value: .array([.string("sms"), .string("email"), .string("sms")]),
            occurredAt: "2026-08-17T20:00:01Z"
        )
        let replay = try await module.set(
            run: run,
            emissionId: "emission-2",
            screenId: "question",
            field: "channels",
            value: .array([.string("sms")]),
            occurredAt: "2026-08-17T20:00:09Z"
        )

        XCTAssertEqual(first.snapshot?.version, 1)
        XCTAssertEqual(second.snapshot?.version, 2)
        XCTAssertEqual(
            second.snapshot?.values["channels"],
            .array([.string("email"), .string("sms")])
        )
        XCTAssertEqual(replay, second)
        let synchronization = await store.synchronizationItems()
        XCTAssertEqual(synchronization.count, 2)
    }

    func testInvalidMutationsDoNotCreateSession() async throws {
        let (store, module) = try await setup()
        let missing = try await module.set(
            run: run,
            emissionId: "bad-1",
            screenId: "question",
            field: "missing",
            value: .string("x"),
            occurredAt: "2026-08-17T20:00:00Z"
        )
        let uncaptured = try await module.set(
            run: run,
            emissionId: "bad-2",
            screenId: "question",
            field: "details",
            value: .string("x"),
            occurredAt: "2026-08-17T20:00:01Z"
        )
        let invalid = try await module.set(
            run: run,
            emissionId: "bad-3",
            screenId: "question",
            field: "score",
            value: .number(11),
            occurredAt: "2026-08-17T20:00:02Z"
        )

        XCTAssertEqual(missing, .rejected(diagnostic: .fieldMissing, snapshot: nil))
        XCTAssertEqual(uncaptured, .rejected(diagnostic: .fieldNotCaptured, snapshot: nil))
        XCTAssertEqual(invalid, .rejected(diagnostic: .valueInvalid, snapshot: nil))
        let stored = await store.load(journeyId: run.journeyId)
        XCTAssertNil(stored)
    }

    func testSubmissionRequiresSnapshotAndRequiredFieldsAndIsIdempotent() async throws {
        let (store, module) = try await setup()
        let missing = try await module.submit(
            run: run,
            operationId: "submit-invocation-1",
            expectedVersion: nil,
            occurredAt: "2026-08-17T20:00:00Z"
        )
        XCTAssertEqual(missing, .rejected(diagnostic: .requiredMissing, snapshot: nil))

        let draft = try await module.set(
            run: run,
            emissionId: "reason-1",
            screenId: "question",
            field: "reason",
            value: .string("fit"),
            occurredAt: "2026-08-17T20:00:01Z"
        )
        let conflict = try await module.submit(
            run: run,
            operationId: "submit-invocation-2",
            expectedVersion: nil,
            occurredAt: "2026-08-17T20:00:02Z"
        )
        XCTAssertEqual(conflict, .rejected(diagnostic: .snapshotConflict, snapshot: draft.snapshot))

        let submitted = try await module.submit(
            run: run,
            operationId: "submit-invocation-3",
            expectedVersion: draft.snapshot?.version,
            occurredAt: "2026-08-17T20:00:03Z"
        )
        let repeated = try await module.submit(
            run: run,
            operationId: "submit-invocation-4",
            expectedVersion: submitted.snapshot?.version,
            occurredAt: "2026-08-17T20:00:04Z"
        )

        XCTAssertEqual(submitted.snapshot?.state, .submitted)
        XCTAssertEqual(submitted.snapshot?.version, 2)
        XCTAssertEqual(repeated, .accepted(status: .alreadySubmitted, snapshot: submitted.snapshot))
        let synchronization = await store.synchronizationItems()
        XCTAssertEqual(synchronization.count, 2)
    }

    func testAbandonmentRetainsValuesAndAbsentSessionCreatesFence() async throws {
        let (store, module) = try await setup()
        _ = try await module.set(
            run: run,
            emissionId: "reason-1",
            screenId: "question",
            field: "reason",
            value: .string("price"),
            occurredAt: "2026-08-17T20:00:00Z"
        )
        let abandoned = try await module.abandon(
            run: run,
            terminalTransitionId: "terminal-1",
            occurredAt: "2026-08-17T20:00:01Z"
        )
        XCTAssertEqual(abandoned.snapshot?.state, .abandoned)
        XCTAssertEqual(abandoned.snapshot?.values["reason"], .string("price"))

        let emptyRun = ResponseSessionRunAuthority(
            journeyId: "journey-empty",
            executionOwnershipEpoch: 2,
            lifecycleGeneration: 3,
            schema: schema
        )
        _ = try await module.pinRun(emptyRun)
        _ = try await module.abandon(
            run: emptyRun,
            terminalTransitionId: "terminal-empty",
            occurredAt: "2026-08-17T20:00:02Z"
        )
        let synchronization = await store.synchronizationItems()
        guard case .terminalNoSession(_, let journeyId, _, _, _, let transitionId) = synchronization.last else {
            return XCTFail("expected terminal no-session fence")
        }
        XCTAssertEqual(journeyId, "journey-empty")
        XCTAssertEqual(transitionId, "terminal-empty")
    }

    func testProjectionHydratesAndPublishesCommittedVersions() async throws {
        let (_, module) = try await setup()
        let initial = try await module.current(journeyId: run.journeyId)
        XCTAssertNil(initial.sessionVersion)
        XCTAssertEqual(initial.values["reason"], .null)

        let observer = ProjectionObserver()
        let subscription = try await module.subscribe(journeyId: run.journeyId) { value in
            observer.append(value.sessionVersion)
        }
        _ = try await module.set(
            run: run,
            emissionId: "reason-1",
            screenId: "question",
            field: "reason",
            value: .string("price"),
            occurredAt: "2026-08-17T20:00:00Z"
        )
        _ = try await module.set(
            run: run,
            emissionId: "reason-repeated",
            screenId: "question",
            field: "reason",
            value: .string("price"),
            occurredAt: "2026-08-17T20:00:00Z"
        )
        await module.unsubscribe(journeyId: run.journeyId, id: subscription)
        XCTAssertEqual(observer.snapshot(), [nil, 1])
    }

    func testTimestampRequiresExplicitOffset() async throws {
        let (_, module) = try await setup()

        do {
            _ = try await module.set(
                run: run,
                emissionId: "missing-offset",
                screenId: "question",
                field: "reason",
                value: .string("price"),
                occurredAt: "2026-08-17T20:00:00"
            )
            XCTFail("expected invalid timestamp")
        } catch {
            XCTAssertEqual(error as? ResponseSessionModuleError, .invalidTimestamp)
        }
    }

    private let schema = PinnedResponseSessionSchema(
        key: "survey",
        versionId: "survey-v1",
        version: 1,
        fields: [
            ResponseSessionField(
                key: "reason",
                type: .enumeration,
                required: true,
                options: ["price", "fit"],
                minimum: nil,
                maximum: nil
            ),
            ResponseSessionField(
                key: "details",
                type: .text,
                required: false,
                options: nil,
                minimum: nil,
                maximum: nil
            ),
            ResponseSessionField(
                key: "channels",
                type: .multiEnumeration,
                required: false,
                options: ["email", "push", "sms"],
                minimum: nil,
                maximum: nil
            ),
            ResponseSessionField(
                key: "score",
                type: .number,
                required: false,
                options: nil,
                minimum: 1,
                maximum: 10
            ),
        ],
        capturesByScreen: [
            "question": ["reason", "channels", "score"],
            "details": ["details"],
        ]
    )

    private var run: ResponseSessionRunAuthority {
        ResponseSessionRunAuthority(
            journeyId: "journey-1",
            executionOwnershipEpoch: 2,
            lifecycleGeneration: 3,
            schema: schema
        )
    }

    private func setup() async throws -> (InMemoryResponseSessionStore, ResponseSessionModule) {
        let store = InMemoryResponseSessionStore()
        let module = ResponseSessionModule(store: store)
        _ = try await module.pinRun(run)
        return (store, module)
    }
}

private final class ProjectionObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64?] = []

    func append(_ value: UInt64?) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [UInt64?] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
#endif
