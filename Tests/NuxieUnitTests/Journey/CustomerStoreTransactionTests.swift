import Foundation
import SQLite3
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class CustomerStoreTransactionTests: XCTestCase {
    func testAdmissionRollsBackEveryStatement() async throws { try await assertRollback(.admission) }
    func testRendererInvocationRollsBackEveryStatement() async throws { try await assertRollback(.renderer) }
    func testPurchaseResultRollsBackEveryStatement() async throws { try await assertRollback(.purchase) }
    func testRestoreResultRollsBackEveryStatement() async throws { try await assertRollback(.restore) }
    func testExposureAndStableEventRollBackEveryStatement() async throws { try await assertRollback(.exposure) }
    func testMeasurementProjectionAndDoneBitRollBackEveryStatement() async throws { try await assertRollback(.measurement) }
    func testResponseReservationRollsBackEveryStatement() async throws { try await assertRollback(.response) }
    func testCompletionAndReportRollBackEveryStatement() async throws { try await assertRollback(.completion) }
    func testCompletionPrivacyDropRollsBackEveryStatement() async throws { try await assertRollback(.privacyCompletion) }
    func testReceiptCompactionRollsBackEveryStatement() async throws { try await assertRollback(.compaction) }
    func testWaitOutletCursorInputAndNativeSnapshotRollBackTogether() async throws { try await assertRollback(.wait) }

    private func assertRollback(_ operation: CustomerExecutionTestRig.Operation) async throws {
        let baseline = try await CustomerExecutionTestRig(operation)
        _ = try await baseline.store.executeCustomerCommand(baseline.command)
        let count = await baseline.store.customerStatementNumber
        await baseline.remove()
        XCTAssertGreaterThan(count, 0)
        let points = (1...count).map(CustomerTransactionFaultPoint.statement) + [.beforeCommit]
        for point in points {
            let rig = try await CustomerExecutionTestRig(operation)
            let before = try rig.databaseSnapshot()
            await rig.store.setCustomerFaultInjector { if $0 == point { throw CustomerExecutionTestFault.interrupted } }
            do { _ = try await rig.store.executeCustomerCommand(rig.command); XCTFail("Expected interruption at \(point)") }
            catch CustomerExecutionTestFault.interrupted { }
            await rig.reopen()
            XCTAssertEqual(try rig.databaseSnapshot(), before, "\(operation) at \(point)")
            await rig.remove()
        }
    }

    func testDuplicateWrongEffectAndStaleRevisionCannotAdvanceAnotherStep() async throws {
        let rig = try await CustomerExecutionTestRig(.purchase)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        guard case let .settleEffect(transition, effectId, stepId) = rig.command.mutation else { return XCTFail("Missing effect fixture") }
        var wrong = rig.command!
        wrong = .init(owner: rig.owner, epoch: 0, mutation: .settleEffect(transition, effectId: "another-effect", stepId: stepId))
        let rejected = try await rig.store.executeCustomerCommand(wrong)
        XCTAssertTrue(rejected.replayed)
        var stale = transition
        stale = .init(key: transition.key, expectedRevision: transition.expectedRevision + 1, eventId: transition.eventId,
            targetKey: transition.targetKey, stepId: transition.stepId, context: transition.context)
        do {
            _ = try await rig.store.executeCustomerCommand(.init(owner: rig.owner, epoch: 0, mutation: .settleEffect(stale, effectId: effectId, stepId: stepId)))
            XCTFail("A stale cursor cannot settle the effect")
        } catch CustomerStoreError.staleRevision { }
        _ = try await rig.store.executeCustomerCommand(rig.command)
        let replay = try await rig.store.executeCustomerCommand(rig.command)
        XCTAssertTrue(replay.replayed)
        let active = try await rig.store.activeJourneys(owner: rig.owner)
        XCTAssertEqual(active.first?.stepId, "next")
        XCTAssertEqual(active.first?.cursorRevision, 1)
        await rig.store.close()
    }

    func testStaleCompletionCannotDeleteTheNewerCursorOrInsertItsReport() async throws {
        let rig = try await CustomerExecutionTestRig(.completion)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        _ = try await rig.facade.transition(rig.journey.id, stepId: "newer", context: rig.journey.context)
        do {
            _ = try await rig.store.executeCustomerCommand(rig.command)
            XCTFail("A completion may end only the cursor whose outputs it projected")
        } catch CustomerStoreError.staleRevision { }
        await rig.reopen()
        let active = try await rig.store.activeJourneys(owner: rig.owner)
        let report = try await rig.store.queryEvent(id: rig.journey.completedEventId)
        XCTAssertEqual(active.first?.stepId, "newer")
        XCTAssertEqual(active.first?.cursorRevision, 1)
        XCTAssertNil(report)
        await rig.store.close()
    }

    func testStableIdentityRejectsDifferentPayloadAndOrigin() async throws {
        let rig = try await CustomerExecutionTestRig(.admission)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        let origin = JourneyEventOrigin(journeyId: "journey", experienceId: "experience", versionId: "version", legId: "leg", generation: 0, stepId: "step", occurrenceId: "trigger")
        for event in [
            try StoredEvent(id: "trigger", name: "go", properties: ["different": true], timestamp: .init(timeIntervalSince1970: 100), distinctId: rig.owner.userId),
            try StoredEvent(id: "trigger", name: "go", timestamp: .init(timeIntervalSince1970: 100), distinctId: rig.owner.userId, journeyOrigin: origin),
        ] {
            do { _ = try await rig.store.insert(event, deliveryState: .pending); XCTFail("A stable identity cannot change") }
            catch CustomerStoreError.eventIdentityConflict { }
        }
        do {
            _ = try await rig.store.insert(StoredEvent(id: "trigger", name: "go", timestamp: .init(timeIntervalSince1970: 100), distinctId: rig.owner.userId),
                deliveryState: .pending, origin: .server, assigningCommitSequence: false)
            XCTFail("The committed event origin cannot change")
        } catch CustomerStoreError.eventIdentityConflict { }
        let stored = try await rig.store.queryEvent(id: "trigger")
        XCTAssertNil(stored?.journeyOrigin)
        XCTAssertTrue(stored?.getPropertiesDict().isEmpty == true)
        await rig.store.close()
    }

    func testLagIsSampledAtFirstExecutorAndSurvivesFailedFirstAndLaterCheckpointSaves() async throws {
        let rig = try await CustomerExecutionTestRig(.wait)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        let initial = try await rig.store.activeJourneys(owner: rig.owner)
        let admitted = try XCTUnwrap(initial.first)
        XCTAssertNil(admitted.initialLagMillis)
        let first = try await rig.facade.beginEvaluation(admitted, at: .init(timeIntervalSince1970: 300), triggeringAt: .init(timeIntervalSince1970: 100))
        XCTAssertEqual(first.initialLagMillis, 200_000)
        await rig.store.setCustomerFaultInjector { if $0 == .beforeCommit { throw CustomerExecutionTestFault.interrupted } }
        do { _ = try await rig.store.executeCustomerCommand(rig.command); XCTFail("Checkpoint should fail") }
        catch CustomerExecutionTestFault.interrupted { }
        await rig.store.setCustomerFaultInjector(nil)
        let retry = try await rig.facade.beginEvaluation(first, at: .init(timeIntervalSince1970: 900), triggeringAt: .init(timeIntervalSince1970: 100))
        XCTAssertEqual(retry.initialLagMillis, 200_000)
        XCTAssertEqual(retry.evaluationAt, 300_000)
        _ = try await rig.store.executeCustomerCommand(rig.command)
        await rig.reopen()
        let restored = try await rig.store.activeJourneys(owner: rig.owner)
        let saved = try XCTUnwrap(restored.first)
        XCTAssertEqual(saved.stepId, "next")
        XCTAssertNotNil(saved.nativeSnapshot)
        XCTAssertNil(saved.park)
        await rig.store.close()
    }

    func testDelayedFirstExecutionAndFailedFirstAndLaterParksKeepSavedTiming() async throws {
        let rig = try await CustomerExecutionTestRig(.admission)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        _ = try await rig.store.executeCustomerCommand(rig.command)
        let admittedRows = try await rig.store.activeJourneys(owner: rig.owner)
        let admitted = try XCTUnwrap(admittedRows.first)
        XCTAssertNil(admitted.evaluationAt)
        XCTAssertNil(admitted.initialLagMillis)
        let first = try await rig.facade.beginEvaluation(admitted, at: .init(timeIntervalSince1970: 300), triggeringAt: .init(timeIntervalSince1970: 100))
        XCTAssertEqual(first.initialLagMillis, 200_000)
        let firstPark = CustomerInputTransition(key: rig.facade.key(first), expectedRevision: 0, eventId: nil,
            targetKey: "first-park", stepId: "wait", context: first.context, checkpoint: .init(anchorAtMillis: 100_000, wakeAtMillis: 160_000))
        await rig.store.setCustomerFaultInjector { if $0 == .beforeCommit { throw CustomerExecutionTestFault.interrupted } }
        do { _ = try await rig.facade.command(.applyInput(firstPark)); XCTFail("First park should fail") }
        catch CustomerExecutionTestFault.interrupted { }
        await rig.store.setCustomerFaultInjector(nil)
        let retried = try await rig.facade.beginEvaluation(first, at: .init(timeIntervalSince1970: 500), triggeringAt: .init(timeIntervalSince1970: 100))
        XCTAssertEqual(retried.evaluationAt, 300_000)
        XCTAssertEqual(retried.initialLagMillis, 200_000)
        _ = try await rig.facade.command(.applyInput(firstPark))
        try await rig.facade.captureFixtureInput(id: "resume", name: "go", at: .init(timeIntervalSince1970: 120))
        let current = try await rig.facade.current(first.id)
        var resume = CustomerInputTransition(key: rig.facade.key(current), expectedRevision: 1, eventId: "resume", targetKey: "wait:1", stepId: "later", context: current.context)
        resume.consumesWait = true
        let resumed = try await rig.facade.command(.resolveWait(resume))
        let next = try XCTUnwrap(resumed.journey)
        let evaluated = try await rig.facade.beginEvaluation(next, at: .init(timeIntervalSince1970: 500), triggeringAt: .init(timeIntervalSince1970: 120))
        let laterPark = CustomerInputTransition(key: rig.facade.key(evaluated), expectedRevision: 2, eventId: nil,
            targetKey: "later-park", stepId: "later", context: evaluated.context, checkpoint: .init(anchorAtMillis: 120_000, wakeAtMillis: 180_000))
        await rig.store.setCustomerFaultInjector { if $0 == .beforeCommit { throw CustomerExecutionTestFault.interrupted } }
        do { _ = try await rig.facade.command(.applyInput(laterPark)); XCTFail("Later park should fail") }
        catch CustomerExecutionTestFault.interrupted { }
        await rig.store.setCustomerFaultInjector(nil)
        let laterRetry = try await rig.facade.beginEvaluation(evaluated, at: .init(timeIntervalSince1970: 900), triggeringAt: .init(timeIntervalSince1970: 120))
        XCTAssertEqual(laterRetry.evaluationAt, 500_000)
        XCTAssertEqual(laterRetry.initialLagMillis, 380_000)
        _ = try await rig.facade.command(.applyInput(laterPark))
        await rig.reopen()
        let restored = try await rig.store.activeJourneys(owner: rig.owner)
        XCTAssertEqual(restored.first?.park?.anchorAt, .init(timeIntervalSince1970: 120))
        XCTAssertEqual(restored.first?.lastConsumed?.eventId, "resume")
        await rig.store.close()
    }

    func testConversionUsesImmutableEntryContextAndFixedExpiryAfterCompletion() async throws {
        let rig = try await CustomerExecutionTestRig(.measurement)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        _ = try await rig.facade.complete(rig.journey.id, outcome: "done", at: .init(timeIntervalSince1970: 130))
        let identity = MockIdentityService()
        let fence = JourneyProfileFence()
        let admission = JourneyCommitAdmission.executionOnly(identity: identity, executionFence: fence, executionFenceToken: fence.token())
        let event = try await rig.store.queryEvent(id: "goal")
        let occurrence = try XCTUnwrap(event).customerEvent
        _ = try await rig.facade.recordConversionOccurrence(occurrence, acceptedAt: occurrence.timestamp, matching: [], admission: admission)
        let watches = try await rig.store.customerWatches(owner: rig.owner)
        let watch = try XCTUnwrap(watches[rig.journey.journeyId])
        XCTAssertEqual(watch.entryContext.context.responses["answer"], .number(42))
        XCTAssertEqual(watch.conversion?.eventId, "goal")
        XCTAssertEqual(watch.expiresAt, 160_000)
        XCTAssertEqual(watch.legCompletedAt, 130_000)
        let pending = try await rig.store.measurementInputs(distinctId: rig.owner.userId)
        XCTAssertFalse(pending.contains { $0.event.id == "goal" })
        await rig.store.close()
    }

    func testWaitReadsBoundedPagesAndConsumesEqualTimestampIdentitiesOnceAcrossReopen() async throws {
        let rig = try await CustomerExecutionTestRig(.wait)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        for index in 0..<260 {
            _ = try await rig.store.insert(StoredEvent(id: String(format: "candidate-%03d", index), name: "go",
                properties: ["ready": false], timestamp: .init(timeIntervalSince1970: 101.5), distinctId: rig.owner.userId), deliveryState: .pending)
        }
        for id in ["z-match", "a-match"] {
            _ = try await rig.store.insert(StoredEvent(id: id, name: "go", properties: ["ready": true],
                timestamp: .init(timeIntervalSince1970: 102), distinctId: rig.owner.userId), deliveryState: .pending)
        }
        await rig.reopen()
        let executor = JourneyControlExecutor(timezones: try SignedTimezoneBundle.load(),
            currentDeviceTimezone: TimeZone(identifier: "Etc/UTC")!, appDefaultTimezone: "Etc/UTC")
        let step = try ExactJSONCodec.decode(Journey.Step.self, from: Data(#"{"kind":"action","id":"next","action":{"type":"wait_until","trigger":{"kind":"event","eventName":"go"},"condition":{"type":"Truthy","value":{"type":"Event.Field","key":"ready"}},"maxTimeMs":100000},"outlets":{"satisfied":"chosen","timeout":"expired"}}"#.utf8))
        let current = try await rig.facade.current(rig.journey.id)
        var transition = CustomerInputTransition(key: rig.facade.key(current), expectedRevision: current.cursorRevision,
            eventId: "a-match", targetKey: "wait:1", stepId: "chosen", context: current.context,
            nativeSnapshot: current.nativeSnapshot, consumesWait: true)
        transition.waitEvaluation = .init(step: step, context: current.context,
            checkpoint: .init(anchorAtMillis: 100_000, wakeAtMillis: 200_000), executor: executor, assignments: [:], customer: [:])
        let first = try await rig.store.executeCustomerCommand(.init(owner: rig.owner, epoch: 0, mutation: .resolveWait(transition)))
        let chosen = try XCTUnwrap(first.journey)
        XCTAssertEqual(chosen.lastConsumed?.eventId, "a-match")
        XCTAssertNotNil(chosen.nativeSnapshot)
        let nextPark = CustomerInputTransition(key: rig.facade.key(chosen), expectedRevision: chosen.cursorRevision,
            eventId: nil, targetKey: "next-park", stepId: "next", context: chosen.context,
            checkpoint: .init(anchorAtMillis: 102_000, wakeAtMillis: 200_000), nativeSnapshot: chosen.nativeSnapshot)
        _ = try await rig.store.executeCustomerCommand(.init(owner: rig.owner, epoch: 0, mutation: .applyInput(nextPark)))
        transition = CustomerInputTransition(key: rig.facade.key(chosen), expectedRevision: chosen.cursorRevision + 1,
            eventId: "a-match", targetKey: "wait:3", stepId: "chosen", context: chosen.context, nativeSnapshot: chosen.nativeSnapshot, consumesWait: true)
        do {
            _ = try await rig.store.executeCustomerCommand(.init(owner: rig.owner, epoch: 0, mutation: .resolveWait(transition)))
            XCTFail("The consumed occurrence cannot satisfy a second wait")
        } catch CustomerStoreError.staleRevision { }
        transition.eventId = "z-match"
        transition.waitEvaluation = .init(step: step, context: chosen.context,
            checkpoint: .init(anchorAtMillis: 102_000, wakeAtMillis: 200_000), executor: executor, assignments: [:], customer: [:])
        let second = try await rig.store.executeCustomerCommand(.init(owner: rig.owner, epoch: 0, mutation: .resolveWait(transition)))
        XCTAssertEqual(second.journey?.lastConsumed?.eventId, "z-match")
        await rig.store.close()
    }

    func testGlobalPruningSkipsReferencedRowsAndStillDeletesEligibleHistory() async throws {
        let rig = try await CustomerExecutionTestRig(.wait)
        defer { try? FileManager.default.removeItem(at: rig.disk.root) }
        _ = try await rig.store.executeCustomerCommand(rig.command)
        let unreferenced = try StoredEvent(id: "unreferenced", name: "old", timestamp: .init(timeIntervalSince1970: 1), distinctId: rig.owner.userId)
        _ = try await rig.store.insert(unreferenced, deliveryState: .delivered)
        try await rig.store.acknowledgeMeasurement(eventId: unreferenced.id, distinctId: rig.owner.userId)
        try await rig.store.markDelivered(ids: ["trigger", "matched"])
        _ = try await rig.store.readOrInitializeHistoryCoverage(startingAt: .init(timeIntervalSince1970: 0))
        _ = try await rig.store.pruneHistory(keeping: 0, olderThan: .init(timeIntervalSince1970: 1000))
        let retained = try await rig.store.queryEvent(id: "matched")
        let removed = try await rig.store.queryEvent(id: "unreferenced")
        XCTAssertNotNil(retained)
        XCTAssertNil(removed)
        await rig.store.close()
    }
}

enum CustomerExecutionTestFault: Error { case interrupted }

/// All setup uses typed commands and the event capture API. Crash points never edit rows.
final class CustomerExecutionTestRig {
    enum Operation: String { case admission, renderer, purchase, restore, exposure, response, completion, privacyCompletion, compaction, wait, measurement }
    let disk: CustomerStoreTestDatabase
    var store: SQLiteEventStore
    let owner = CustomerStoreOwner(scope: .testFixture, userId: "customer")
    var facade: CustomerJourneyStore!
    var command: CustomerExecutionCommand!
    var journey: JourneyRun!

    init(_ operation: Operation) async throws {
        disk = try CustomerStoreTestDatabase()
        store = SQLiteEventStore()
        try await store.initialize(path: disk.root)
        try await store.bindConversionAuthority(owner.scope)
        facade = try await CustomerJourneyStore(directory: disk.root, distinctId: owner.userId, openedAt: .init(timeIntervalSince1970: 100), store: store)
        _ = try await store.insert(StoredEvent(id: "trigger", name: "go", timestamp: .init(timeIntervalSince1970: 100), distinctId: owner.userId), deliveryState: .delivered)
        let arm = ArmedJourney(reference: .init(experienceId: "experience", versionId: "version", legId: String(repeating: "a", count: 64), descriptorSha256: String(repeating: "b", count: 64)),
            binding: .init(type: .new, journeyId: nil, generation: nil),
            entryCondition: .init(type: .event, eventName: "go", segmentId: nil, member: nil, condition: nil), context: .init(event: ["answer": .number(42)], responses: operation == .measurement ? ["answer": .number(42)] : [:]))
        journey = JourneyRun(journeyId: "journey", generation: 0, reference: arm.reference, executionSnapshot: testJourneyExecutionSnapshot(), artifactSHA256s: [],
            reentry: .init(type: .everyMatch, window: nil), startedAt: .init(timeIntervalSince1970: 100), isEnrollment: true,
            startedEventId: "started", completedEventId: "completed", stepId: "wait", context: arm.context)
        let policy = try ExactJSONCodec.decode(Journey.Policy.self, from: Data(#"{"entry":{"trigger":{"type":"event","eventName":"go"},"frequency":{"type":"every_match"}},"goal":{"criterion":{"type":"event","eventName":"goal","condition":{"ir_version":1,"expr":{"type":"Compare","op":"==","left":{"type":"Response.Field","key":"answer"},"right":{"type":"Number","value":42}}}},"attribution":{"basis":"entry","window":{"amount":1,"unit":"minute"}}},"exitWhenAny":[]}"#.utf8))
        let watch: JourneyConversionWatch?
        if operation == .measurement { watch = try JourneyConversionWatch(run: journey, policy: policy, delivery: nil) }
        else { watch = nil }
        let admission = CustomerAdmission(journey: journey, pins: [], watch: watch, arm: .init(arm), sourceEventId: "trigger", targetKey: "admission", stateLatch: false)
        let started = try Self.record(JourneyReporter.started(journey, owner: owner.userId))
        let admit = CustomerExecutionCommand(owner: owner, epoch: 0, mutation: .admit(admission), events: [started])
        if operation == .admission { command = admit; return }
        _ = try await store.executeCustomerCommand(admit)
        let key = CustomerJourneyKey(owner: owner, journeyId: journey.journeyId, legGeneration: 0)
        let next = CustomerInputTransition(key: key, expectedRevision: 0, eventId: "trigger", targetKey: "input", stepId: "next", context: arm.context)
        switch operation {
        case .admission: command = admit
        case .renderer:
            let one = try StoredEvent(id: "one", name: "tap", timestamp: .init(timeIntervalSince1970: 101), distinctId: owner.userId)
            let two = try StoredEvent(id: "two", name: "tap_detail", timestamp: .init(timeIntervalSince1970: 101), distinctId: owner.userId)
            var transition = next
            transition.eventId = "one"
            transition.rendererInvocationId = "invocation"
            transition.presentationSource = .init(screenId: "screen", actionId: "tap", componentId: nil, instanceId: nil)
            command = .init(owner: owner, epoch: 0, mutation: .applyInput(transition), events: [one, two].map { .init(eventId: $0.id, event: $0, recordedAt: $0.timestamp) })
        case .purchase, .restore:
            _ = try await store.executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .claimEffect(key: key, revision: 0, stepId: "wait", effectId: "effect", kind: operation.rawValue)))
            _ = try await store.executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .retainCommerce(key: key, revision: 0, stepId: "wait", effectId: "effect", placementId: "placement")))
            _ = try await store.insert(StoredEvent(id: "effect", name: operation == .purchase ? SystemEventNames.purchaseCompleted : SystemEventNames.restoreCompleted,
                properties: ["placement_id": "placement"], timestamp: .init(timeIntervalSince1970: 101), distinctId: owner.userId), deliveryState: .pending)
            var resultTransition = next
            resultTransition.eventId = "effect"
            command = .init(owner: owner, epoch: 0, mutation: .settleEffect(resultTransition, effectId: "effect", stepId: "wait"))
        case .exposure:
            let exposure = JourneyRun.ExperimentExposure(experimentId: "experiment", variantId: "variant", isHoldout: false, kind: .assigned,
                eventId: "exposure", selectedAt: .init(timeIntervalSince1970: 100), presentationScreenId: nil, shownAt: nil)
            var selection = next
            selection.exposure = exposure
            _ = try await store.executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .applyInput(selection)))
            _ = try await store.executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .bindExposures(key: key, revision: 1, screenId: "screen")))
            let event = try Self.record(JourneyReporter.exposure(exposure, journey: journey, owner: owner.userId, at: .init(timeIntervalSince1970: 101)))
            command = .init(owner: owner, epoch: 0, mutation: .publishExposures(key: key, revision: 1, screenId: "screen", shownAt: 101_000), events: [event])
        case .measurement:
            _ = try await facade.transition(journey.id, stepId: "wait", context: .init(event: [:], responses: ["answer": .number(999)]))
            let event = try StoredEvent(id: "goal", name: "goal", timestamp: .init(timeIntervalSince1970: 120), distinctId: owner.userId)
            _ = try await store.insert(event, deliveryState: .pending, origin: .device, assigningCommitSequence: false, acceptedAt: event.timestamp)
            let watches = try await store.customerWatches(owner: owner)
            var projected = watches
            let digest = SHA256Provider.hexDigest(try ExactJSONCodec.canonicalize(ExactJSONCodec.encode(watches)))
            var matching = Set<String>()
            for watch in watches.values where await watch.matches(event.customerEvent) { matching.insert(watch.journeyId) }
            JourneyConversionWatch.apply(event: event.customerEvent, acceptedAt: event.timestamp, matching: matching, watches: &projected)
            command = .init(owner: owner, epoch: 0, mutation: .measure(eventId: event.id, watches: projected, expectedDigest: digest))
        case .response:
            command = .init(owner: owner, epoch: 0, mutation: .reserveResponse(key: key, formName: "feedback", answers: ["answer": .number(42)], queued: true))
        case .completion, .privacyCompletion:
            let event = try Self.record(JourneyReporter.completed(journey, owner: owner.userId, outcome: "done", at: .init(timeIntervalSince1970: 101), outputs: arm.context))
            command = .init(owner: owner, epoch: 0, mutation: .complete(key: key, revision: 0, at: 101_000, reportId: journey.completedEventId),
                events: [operation == .privacyCompletion ? .init(eventId: event.eventId, event: nil, recordedAt: event.recordedAt) : event])
        case .compaction:
            _ = try await store.executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .applyInput(next)))
            let event = try Self.record(JourneyReporter.completed(journey, owner: owner.userId, outcome: "done", at: .init(timeIntervalSince1970: 101), outputs: arm.context))
            _ = try await store.executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .complete(key: key, revision: 1, at: 101_000, reportId: journey.completedEventId), events: [event]))
            command = .init(owner: owner, epoch: 0, mutation: .compact(eventId: "trigger"))
        case .wait:
            _ = try await store.insert(StoredEvent(id: "matched", name: "go", timestamp: .init(timeIntervalSince1970: 101), distinctId: owner.userId), deliveryState: .delivered)
            var parked = next
            parked.checkpoint = .init(anchorAtMillis: 100_000, wakeAtMillis: 200_000)
            parked.nativeSnapshot = .init(fields: [.init(path: "answer", kind: 1, value: .integer(42))])
            _ = try await store.executeCustomerCommand(.init(owner: owner, epoch: 0, mutation: .applyInput(parked)))
            var resumed = CustomerInputTransition(key: key, expectedRevision: 1, eventId: "matched", targetKey: "wait:1", stepId: "next", context: arm.context)
            resumed.nativeSnapshot = parked.nativeSnapshot
            resumed.consumesWait = true
            command = .init(owner: owner, epoch: 0, mutation: .resolveWait(resumed))
        }
    }

    static func record(_ item: RoutedStableSystemEventBatchItem) throws -> StableEventCaptureRecord {
        .init(eventId: item.request.eventId, event: try StoredEvent(id: item.request.eventId, name: item.request.name,
            properties: item.request.properties ?? [:], timestamp: item.occurredAt, distinctId: item.request.distinctId, journeyOrigin: item.request.journeyOrigin), recordedAt: item.occurredAt)
    }

    func reopen() async {
        await store.setCustomerFaultInjector(nil)
        await store.close()
        let reopened = SQLiteEventStore()
        do {
            try await reopened.initialize(path: disk.root)
            store = reopened
            facade = try await CustomerJourneyStore(directory: disk.root, distinctId: owner.userId, store: reopened)
        }
        catch { XCTFail("Reopen failed: \(error)") }
    }

    func remove() async { await store.close(); try? disk.remove() }

    func databaseSnapshot() throws -> [String: [String]] {
        let tables = try disk.strings("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
        return try disk.withDatabase { db in
            var snapshot: [String: [String]] = [:]
            for table in tables {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT * FROM \(table);", -1, &statement, nil) == SQLITE_OK else { throw CustomerStoreError.invalidRow }
                defer { sqlite3_finalize(statement) }
                var rows: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    var cells: [String] = []
                    for index in 0..<sqlite3_column_count(statement) {
                        if sqlite3_column_type(statement, index) == SQLITE_NULL { cells.append("null") }
                        else if let bytes = sqlite3_column_blob(statement, index) { cells.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))).base64EncodedString()) }
                    }
                    rows.append(cells.joined(separator: ":"))
                }
                snapshot[table] = rows.sorted()
            }
            return snapshot
        }
    }
}
