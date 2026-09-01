import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class DeviceLegRunJournalTests: XCTestCase {
    func testSharedReportVectorsPreserveOutputsAndForwardLifecycleWithStableRetries() async throws {
        struct Vector: Decodable {
            let binding: ArmedDeviceLeg.Binding
            let startedAtMillis: Double
            let completedAtMillis: Double
            let startedAt: String
            let completedAt: String
            let outcome: String
            let outputs: ArmedDeviceLeg.Context
            let captureModes: [String]
            let eventNames: [String]
            let forwardedNames: [String]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vector = try ExactJSONCodec.decode(Vector.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/reports.json")))
        for mode in vector.captureModes {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SQLiteEventStore()
            let log = try await eventLog(directory: directory, store: store, api: MockNuxieApiForQueue(), dropEvents: mode == "drop")
            let forwarding = LegForwardingRecorder()
            await log.subscribeForwarding { event in await forwarding.record(event.event) }
            let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
            let admitted = try await journal.admit(arm: arm(binding: vector.binding), reentry: .init(type: .everyTime, windowSeconds: nil),
                                                   entryStepId: "step", at: date(vector.startedAtMillis / 1000))
            let run = try XCTUnwrap(admitted)
            try await journal.recordResponses(run.id, values: vector.outputs.responses)
            try await journal.complete(run.id, outcome: vector.outcome, at: date(vector.completedAtMillis / 1000),
                                       eventOutputs: vector.outputs.event)
            if mode == "accept_then_lost_receipt" {
                try await DeviceLegReporter(journal: journal, events: LostCompletionAcknowledgement(events: log)).flushPending()
                let retained = try await journal.runs()
                XCTAssertEqual(retained.count, 1)
                try await journal.complete(run.id, outcome: "abandoned", at: date(900))
            }
            try await DeviceLegReporter(journal: journal, events: log).flushPending()
            await log.drain()
            let remaining = try await journal.runs()
            XCTAssertTrue(remaining.isEmpty, mode)
            let rows = try await store.queryEventsForUser("customer", limit: 10)
            let forwarded = await forwarding.names()
            if mode == "drop" {
                XCTAssertTrue(rows.isEmpty)
                XCTAssertTrue(forwarded.isEmpty)
            } else {
                XCTAssertEqual(Set(rows.map(\.id)), [run.startedEventId, run.completedEventId])
                XCTAssertEqual(Set(rows.map(\.name)), Set(vector.eventNames))
                XCTAssertEqual(forwarded, vector.forwardedNames)
                let timestamps = await forwarding.timestamps()
                XCTAssertEqual(timestamps, [date(vector.startedAtMillis / 1000), date(vector.completedAtMillis / 1000)])
                let completion = try XCTUnwrap(rows.first { $0.id == run.completedEventId }).getPropertiesDict()
                XCTAssertEqual(completion["journey_id"] as? String, vector.binding.journeyId)
                XCTAssertEqual(completion["leg_generation"] as? Int, vector.binding.generation)
                XCTAssertEqual(completion["outcome"] as? String, vector.outcome)
                XCTAssertEqual(completion["started_at"] as? String, vector.startedAt)
                XCTAssertEqual(completion["completed_at"] as? String, vector.completedAt)
                let expected = try JSONSerialization.jsonObject(with: ExactJSONCodec.encode(vector.outputs)) as? NSDictionary
                XCTAssertEqual(completion["outputs"] as? NSDictionary, expected)
                let event = NuxieEvent(id: run.completedEventId, name: JourneyEvents.journeyLegCompleted,
                                       distinctId: "customer", properties: completion, timestamp: date(200))
                let transport = try BatchRequest(events: [.init(event: event)]).encodedForTransport()
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport) as? [String: Any])
                let batch = try XCTUnwrap(body["batch"] as? [[String: Any]])
                let properties = try XCTUnwrap(batch.first?["properties"] as? [String: Any])
                XCTAssertEqual(properties["outputs"] as? NSDictionary, expected, "Batch bytes must retain both Unicode keys")
            }
            await log.close()
        }
    }

    func testAdmissionIsAtomicAcrossInstancesAndIsolatedByCustomer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DeviceLegRunJournal(directory: directory, distinctId: "../customer")
        let second = try DeviceLegRunJournal(directory: directory, distinctId: "../customer")
        let candidate = arm()
        let policy = DeviceLeg.Reentry(type: .oneTime, windowSeconds: nil)
        let at = date(100)
        async let left = first.admit(arm: candidate, reentry: policy, entryStepId: "step", at: at)
        async let right = second.admit(arm: candidate, reentry: policy, entryStepId: "step", at: at)
        let admitted = try await [left, right].compactMap { $0 }
        XCTAssertEqual(admitted.count, 1)
        let other = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let independent = try await other.admit(arm: candidate, reentry: policy, entryStepId: "step", at: at)
        XCTAssertNotNil(independent)
        let recovered = try DeviceLegRunJournal(directory: directory, distinctId: "../customer")
        let existing = try await recovered.runs()
        XCTAssertEqual(existing.map(\.id), admitted.map(\.id))
    }

    func testTerminalHostPrivacyDropStillFinishesTheRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteEventStore()
        let log = try await eventLog(directory: directory, store: store, api: MockNuxieApiForQueue(), dropEvents: true)
        let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let admitted = try await journal.admit(arm: arm(), reentry: .init(type: .oneTime, windowSeconds: nil),
                                               entryStepId: "step", at: date(100))
        let run = try XCTUnwrap(admitted)
        try await journal.complete(run.id, outcome: "done", at: date(200))
        try await DeviceLegReporter(journal: journal, events: log).flushPending()
        let rows = try await store.queryEventsForUser("customer", limit: 10)
        XCTAssertTrue(rows.isEmpty, "The host's privacy policy applies to ordinary leg reports")
        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        let mark = try await journal.checkmark(experienceId: "experience")
        XCTAssertEqual(mark?.outcome, "done")
        for id in [run.startedEventId, run.completedEventId] {
            guard case .dropped? = try await store.queryStableCapture(id: id) else {
                XCTFail("The event log must retain the terminal privacy decision"); continue
            }
        }
        await log.close()
    }

    func testContinuationsDoNotRestartReentryWindowOrRegressCompletedGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let policy = DeviceLeg.Reentry(type: .oncePerWindow, windowSeconds: 100)
        let enrolled = try await journal.admit(arm: arm(), reentry: policy, entryStepId: "step", at: date(100))
        let first = try XCTUnwrap(enrolled)
        try await finish(journal, run: first, at: 110)
        let earlier = try await journal.admit(arm: arm(binding: .init(type: .continuation, journeyId: first.journeyId, generation: 1)),
                                              reentry: policy, entryStepId: "step", at: date(150))
        let later = try await journal.admit(arm: arm(binding: .init(type: .continuation, journeyId: first.journeyId, generation: 2)),
                                            reentry: policy, entryStepId: "step", at: date(160))
        try await finish(journal, run: XCTUnwrap(later), at: 170)
        try await finish(journal, run: XCTUnwrap(earlier), at: 180)
        let mark = try await journal.checkmark(experienceId: "experience")
        XCTAssertEqual(mark?.generation, 2, "A late lower chapter cannot re-enable a consumed arm")
        XCTAssertEqual(mark?.lastEnrollmentAt, date(100))
        let early = try await journal.admit(arm: arm(), reentry: policy, entryStepId: "step", at: date(199))
        XCTAssertNil(early)
        let allowed = try await journal.admit(arm: arm(), reentry: policy, entryStepId: "step", at: date(200))
        XCTAssertNotNil(allowed, "The window counts from enrollment, not a continuation or completion")
    }

    private func finish(_ journal: DeviceLegRunJournal, run: DeviceLegRun, at: Double) async throws {
        try await journal.markStartedQueued(run)
        try await journal.complete(run.id, outcome: "done", at: date(at))
        try await journal.markCompletionQueued(run)
    }

    func testSharedRecoveryVectorsOnlyResumeParkPoints() async throws {
        struct Vector: Decodable {
            let name: String
            let binding: ArmedDeviceLeg.Binding
            let beforeDeath: String
            let responses: ExactJSONObject<ExperienceReleaseJSONValue>
            let wakeAtMillis: Double?
            let expectedOutcome: String?
            let expectedGeneration: Int
            let expectedCompletedAtMillis: Double?
        }
        struct Suite: Decodable {
            let startedAtMillis: Double
            let reopenedAtMillis: Double
            let cases: [Vector]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/run-recovery.json")))
        for vector in suite.cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
            let admitted = try await journal.admit(arm: arm(binding: vector.binding),
                reentry: .init(type: .everyTime, windowSeconds: nil), entryStepId: "step", at: date(suite.startedAtMillis / 1000))
            let run = try XCTUnwrap(admitted)
            try await journal.markStartedQueued(run)
            try await journal.recordResponses(run.id, values: vector.responses)
            if vector.beforeDeath == "parked" {
                try await journal.park(run.id, stepId: "wait", until: vector.wakeAtMillis.map { date($0 / 1000) })
            } else if vector.beforeDeath == "completed" {
                try await journal.complete(run.id, outcome: "done", at: date(200))
            }
            let reopened = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
            let resumable = try await reopened.recover(at: date(suite.reopenedAtMillis / 1000))
            let rows = try await reopened.runs()
            let recovered = try XCTUnwrap(rows.first)
            XCTAssertEqual(recovered.generation, vector.expectedGeneration, vector.name)
            XCTAssertEqual(recovered.completion?.outcome, vector.expectedOutcome, vector.name)
            XCTAssertEqual(recovered.completion?.at, vector.expectedCompletedAtMillis.map { date($0 / 1000) }, vector.name)
            let expected = try JSONEncoder().encode(vector.responses)
            let actual = try JSONEncoder().encode(recovered.outputs.responses)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: expected) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: actual) as? NSDictionary, vector.name)
            if vector.beforeDeath == "parked" {
                XCTAssertEqual(resumable.map(\.id), [run.id], vector.name)
                XCTAssertEqual(resumable.first?.park?.wakeAt, date(300))
                _ = try await reopened.resumeParked(run.id)
                // Consuming a park point is durable before the next action.
                // Death after consumption must never replay that action.
                let again = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
                let parked = try await again.recover(at: date(500))
                let abandoned = try await again.runs()
                XCTAssertTrue(parked.isEmpty)
                XCTAssertEqual(abandoned.first?.completion?.outcome, "abandoned")
            } else {
                XCTAssertTrue(resumable.isEmpty, vector.name)
            }
        }
    }

    func testAuthorityTeardownAbandonsParkedRunsToo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let admitted = try await journal.admit(
            arm: arm(),
            reentry: .init(type: .oneTime, windowSeconds: nil),
            entryStepId: "wait",
            at: date(100)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)
        try await journal.park(
            run.id,
            stepId: "wait",
            until: date(300)
        )

        try await journal.abandonAll(at: date(200))

        let remaining = try await journal.runs()
        let abandoned = try XCTUnwrap(remaining.first)
        XCTAssertEqual(abandoned.completion?.outcome, "abandoned")
        XCTAssertEqual(abandoned.completion?.at, date(200))
    }

    func testExecutorTransitionsAtomicallyPersistCursorContextAndFixedTimerAnchors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let admitted = try await journal.admit(arm: arm(), reentry: .init(type: .everyTime, windowSeconds: nil),
                                               entryStepId: "condition", at: date(1))
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)
        let changedContext = ArmedDeviceLeg.Context(event: ["ready": .bool(true)], responses: run.context.responses)
        try await journal.transition(run.id, stepId: "wait", context: changedContext,
                                     checkpoint: .init(anchorAtMillis: 2_000, wakeAtMillis: 12_000))

        let parkedRuns = try await DeviceLegRunJournal(directory: directory, distinctId: "customer").runs()
        let parked = try XCTUnwrap(parkedRuns.first)
        XCTAssertEqual(parked.stepId, "wait")
        XCTAssertEqual(try ExactJSONCodec.encode(parked.context), try ExactJSONCodec.encode(changedContext))
        XCTAssertEqual(parked.park?.anchorAt, date(2))
        XCTAssertEqual(parked.park?.wakeAt, date(12))

        try await journal.transition(run.id, stepId: "present", context: changedContext)
        let advancedRuns = try await DeviceLegRunJournal(directory: directory, distinctId: "customer").runs()
        let advanced = try XCTUnwrap(advancedRuns.first)
        XCTAssertEqual(advanced.stepId, "present")
        XCTAssertNil(advanced.park)
    }

    func testEffectClaimMigratesOldSnapshotAndBecomesAnAbandonmentBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let admitted = try await journal.admit(
            arm: arm(),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "effect",
            at: date(100)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)
        try await journal.park(run.id, stepId: "effect", until: nil)

        // Simulate the v1 snapshot shape written before effect receipts were
        // added. The schema version intentionally remains unchanged.
        let root = directory.appendingPathComponent(
            "device-leg-journal-v1",
            isDirectory: true
        )
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first
        )
        var snapshot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file))
                as? [String: Any]
        )
        var storedRuns = try XCTUnwrap(snapshot["runs"] as? [String: Any])
        var storedRun = try XCTUnwrap(storedRuns[run.id] as? [String: Any])
        storedRun.removeValue(forKey: "effectReceipts")
        storedRuns[run.id] = storedRun
        snapshot["runs"] = storedRuns
        try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            .write(to: file, options: .atomic)

        let reopened = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let effectId = try await reopened.claimEffect(run.id, stepId: "effect")
        let repeated = try await reopened.claimEffect(run.id, stepId: "effect")
        XCTAssertEqual(repeated, effectId)
        let claimedRuns = try await reopened.runs()
        let claimed = try XCTUnwrap(claimedRuns.first)
        XCTAssertNil(claimed.park)
        XCTAssertEqual(claimed.effectReceipts["effect"], effectId)

        let recovered = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let resumable = try await recovered.recover(at: date(200))
        XCTAssertTrue(resumable.isEmpty)
        let rows = try await recovered.runs()
        XCTAssertEqual(rows.first?.completion?.outcome, "abandoned")
    }

    func testEffectClaimExpiresAfterTheCursorAdvances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let admitted = try await journal.admit(
            arm: arm(),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "effect",
            at: date(100)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)

        let first = try await journal.claimEffect(run.id, stepId: "effect")
        try await journal.transition(
            run.id,
            stepId: "branch",
            context: run.context
        )
        try await journal.transition(
            run.id,
            stepId: "effect",
            context: run.context
        )
        let second = try await journal.claimEffect(run.id, stepId: "effect")

        XCTAssertNotEqual(
            second,
            first,
            "A later visit to the same authored action is a new effect occurrence"
        )
    }

    func testInterruptedCompletionCaptureReplaysTheSameEventAndBufferedAnswersAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = SQLiteEventStore()
        let firstLog = try await eventLog(directory: directory, store: firstStore, api: MockNuxieApiForQueue())
        let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let admitted = try await journal.admit(arm: arm(), reentry: .init(type: .everyTime, windowSeconds: nil),
                                               entryStepId: "survey", at: date(100))
        let run = try XCTUnwrap(admitted)
        try await journal.recordResponses(run.id, values: ["answer": .string("yes")])
        try await journal.complete(run.id, outcome: "done", at: date(200))
        let interrupted = DeviceLegReporter(journal: journal, events: LostCompletionAcknowledgement(events: firstLog))
        try await interrupted.flushPending()
        let pending = try await journal.runs()
        XCTAssertEqual(pending.count, 1, "Uncertain capture must retain the only retry record")
        let before = try await firstStore.queryEventsForUser("customer", limit: 10)
        XCTAssertEqual(before.count, 2, "The event was already durably captured")
        await firstLog.close()

        let secondStore = SQLiteEventStore()
        let secondLog = try await eventLog(directory: directory, store: secondStore, api: MockNuxieApiForQueue())
        let reopened = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        try await reopened.complete(run.id, outcome: "abandoned", at: date(500))
        do {
            try await reopened.recordResponses(run.id, values: ["answer": .string("changed")])
            XCTFail("A queued completion must freeze its outputs")
        } catch DeviceLegJournalError.invalidState { }
        try await DeviceLegReporter(journal: reopened, events: secondLog).flushPending()
        let after = try await secondStore.queryEventsForUser("customer", limit: 10)
        XCTAssertEqual(Set(after.map(\.id)), Set(before.map(\.id)))
        let completion = try XCTUnwrap(after.first { $0.name == JourneyEvents.journeyLegCompleted })
        let properties = completion.getPropertiesDict()
        XCTAssertEqual(properties["outcome"] as? String, "done")
        XCTAssertEqual(properties["completed_at"] as? String, "1970-01-01T00:03:20.000Z")
        let outputs = try XCTUnwrap(properties["outputs"] as? [String: Any])
        XCTAssertEqual((outputs["responses"] as? [String: String])?["answer"], "yes")
        let remaining = try await reopened.runs()
        XCTAssertTrue(remaining.isEmpty)
        await secondLog.close()
    }

    func testCompletionQueuesStableEventsAndForgetsRunBeforeNetworkAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteEventStore()
        let api = MockNuxieApiForQueue()
        let log = try await eventLog(directory: directory, store: store, api: api)
        let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let admitted = try await journal.admit(arm: arm(), reentry: .init(type: .oneTime, windowSeconds: nil),
                                               entryStepId: "screen", at: date(100))
        let run = try XCTUnwrap(admitted)
        let reporter = DeviceLegReporter(journal: journal, events: log)
        try await reporter.flushPending()
        try await journal.complete(run.id, outcome: "closed", at: date(200))
        try await reporter.flushPending()

        let reopened = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let runs = try await reopened.runs()
        let checklist = try await reopened.checkmark(experienceId: "experience")
        XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(checklist?.outcome, "closed")
        XCTAssertEqual(checklist?.lastEnrollmentAt, date(100))
        let second = try await reopened.admit(arm: arm(), reentry: .init(type: .oneTime, windowSeconds: nil),
                                              entryStepId: "screen", at: date(300))
        XCTAssertNil(second)
        let rows = try await store.queryEventsForUser("customer", limit: 10)
        XCTAssertEqual(Set(rows.map(\.id)), [run.startedEventId, run.completedEventId])
        XCTAssertEqual(Set(rows.map(\.name)), [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted])
        let completion = try XCTUnwrap(rows.first { $0.name == JourneyEvents.journeyLegCompleted })
        let properties = completion.getPropertiesDict()
        XCTAssertEqual(properties["journey_id"] as? String, run.journeyId)
        XCTAssertEqual(properties["leg_generation"] as? Int, 0)
        XCTAssertEqual(properties["outcome"] as? String, "closed")
        XCTAssertEqual(properties["started_at"] as? String, "1970-01-01T00:01:40.000Z")
        XCTAssertEqual(properties["completed_at"] as? String, "1970-01-01T00:03:20.000Z")
        let calls = await api.sendBatchCallCount
        XCTAssertEqual(calls, 0, "Report queuing must not wait for a transport round trip")
        await log.close()
    }

    private func eventLog(directory: URL, store: SQLiteEventStore, api: MockNuxieApiForQueue, dropEvents: Bool = false) async throws -> EventLog {
        let log = EventLog(identity: MockIdentityService(), dateProvider: MockDateProvider(initialDate: date(1000)),
                           apiClient: api, store: store)
        let config = NuxieConfiguration(apiKey: "test-key")
        config.testingOverrides.customStoragePath = directory
        config.testingOverrides.flushAt = 10_000
        config.testingOverrides.suppressBackgroundWork = true
        if dropEvents { config.beforeSend = { _ in nil } }
        try await log.configure(configuration: config)
        return log
    }

    private func arm(binding: ArmedDeviceLeg.Binding = .init(type: .new, journeyId: nil, generation: nil)) -> ArmedDeviceLeg {
        .init(reference: .init(experienceId: "experience", versionId: "version", legId: String(repeating: "a", count: 64),
                               descriptorSha256: String(repeating: "b", count: 64)), binding: binding,
              entryCondition: .init(type: .appForegrounded, eventName: nil, segmentId: nil, member: nil, condition: nil),
              context: .init(event: [:], responses: [:]))
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
}

private actor LostCompletionAcknowledgement: RoutedStableSystemEventCapturing {
    let events: EventLog
    init(events: EventLog) { self.events = events }

    func captureSystemEvent(_ event: String, properties: sending [String: Any]?, eventId: String,
                            distinctId: String) async -> DurableTriggerCapture? {
        let captured = await events.captureSystemEvent(event, properties: properties, eventId: eventId, distinctId: distinctId)
        return event == JourneyEvents.journeyLegCompleted ? nil : captured
    }

    func routeCapturedSystemEvent(_ capture: DurableTriggerCapture) async {
        await events.routeCapturedSystemEvent(capture)
    }
}

private actor LegForwardingRecorder {
    private var values: [String] = []
    private var times: [Date] = []
    func record(_ event: NuxieEvent) {
        if let activity = ActivityCuration.activity(internalName: event.forwardingName, properties: event.properties) {
            values.append(activity.wireName)
            times.append(ActivityCuration.timestamp(event))
        }
    }
    func names() -> [String] { values }
    func timestamps() -> [Date] { times }
}
