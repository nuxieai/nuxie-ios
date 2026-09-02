import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class DeviceLegRunJournalTests: XCTestCase {
    func testStorageScopeSurvivesCredentialRotationAndIsolatesAppAuthority() {
        let authority = ProfileDeliveryAuthority(
            appId: "app-a",
            environment: "production"
        )
        // A replacement publishable key authenticating the same authority
        // produces the same durable address because credentials never enter
        // the scope constructor.
        let beforeRotation = DeviceLegStorageScope(authority: authority)
        let afterRotation = DeviceLegStorageScope(authority: authority)
        XCTAssertEqual(
            beforeRotation.customerDigest(distinctId: "customer"),
            afterRotation.customerDigest(distinctId: "customer")
        )
        XCTAssertNotEqual(
            beforeRotation.customerDigest(distinctId: "customer"),
            DeviceLegStorageScope(authority: .init(
                appId: "app-b",
                environment: "production"
            )).customerDigest(distinctId: "customer")
        )
        XCTAssertNotEqual(
            beforeRotation.customerDigest(distinctId: "customer"),
            DeviceLegStorageScope(authority: .init(
                appId: "app-a",
                environment: "development"
            )).customerDigest(distinctId: "customer")
        )
    }

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
                                       eventOutputs: vector.outputs.event,
                                       responseOutputs: vector.outputs.responses)
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

    func testStateArmReceiptIsAtomicAcrossInstancesUntilLatchResetOrArmRetirement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let second = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let candidate = arm()
        let receipt = DeviceLegStateArmReceipt(candidate)
        let retainedRelease = release(for: candidate.reference)
        let policy = DeviceLeg.Reentry(type: .everyTime, windowSeconds: nil)

        async let left = first.admit(
            arm: candidate,
            release: retainedRelease,
            reentry: policy,
            entryStepId: "step",
            at: date(100),
            stateArmReceipt: receipt
        )
        async let right = second.admit(
            arm: candidate,
            release: retainedRelease,
            reentry: policy,
            entryStepId: "step",
            at: date(100),
            stateArmReceipt: receipt
        )
        let admitted = try await [left, right].compactMap { $0 }

        XCTAssertEqual(admitted.count, 1)
        try await first.clearStateArmReceipts(entryKind: receipt.entryKind)
        let readmittedAfterLatchReset = try await first.admit(
            arm: candidate,
            release: retainedRelease,
            reentry: policy,
            entryStepId: "step",
            at: date(200),
            stateArmReceipt: receipt
        )
        XCTAssertNotNil(readmittedAfterLatchReset)

        try await first.retainStateArmReceipts([])
        let readmittedAfterArmRetirement = try await first.admit(
            arm: candidate,
            release: retainedRelease,
            reentry: policy,
            entryStepId: "step",
            at: date(300),
            stateArmReceipt: receipt
        )
        XCTAssertNotNil(readmittedAfterArmRetirement)
    }

    func testAdmissionRecreatesAPinDirectoryRemovedBeforeItsRootTransaction() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-a"
        )
        let pinRoot = directory
            .appendingPathComponent("device-leg-journal-v1", isDirectory: true)
            .appendingPathComponent("release-pins", isDirectory: true)
        let firstPinDirectory = pinRoot.appendingPathComponent(
            DeviceLegStorageScope.testFixture.customerDigest(
                distinctId: "customer-a"
            ),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstPinDirectory,
            withIntermediateDirectories: true
        )
        let second = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-b"
        )
        let secondRun = try await second.admit(
            arm: arm(),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "step",
            at: date(100)
        )
        XCTAssertNotNil(secondRun)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstPinDirectory.path),
            "The other admission should remove the simulated orphan"
        )

        let firstRun = try await first.admit(
            arm: arm(),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "step",
            at: date(101)
        )
        XCTAssertNotNil(firstRun)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstPinDirectory.path)
        )
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
                try await journal.complete(
                    run.id,
                    outcome: "done",
                    at: date(200),
                    responseOutputs: vector.responses
                )
            }
            let reopened = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
            let resumable = try await reopened.recover(at: date(suite.reopenedAtMillis / 1000))
            let rows = try await reopened.runs()
            let recovered = try XCTUnwrap(rows.first)
            XCTAssertEqual(recovered.generation, vector.expectedGeneration, vector.name)
            XCTAssertEqual(recovered.completion?.outcome, vector.expectedOutcome, vector.name)
            XCTAssertEqual(recovered.completion?.at, vector.expectedCompletedAtMillis.map { date($0 / 1000) }, vector.name)
            let expected = try JSONEncoder().encode(vector.responses)
            let retainedResponses = recovered.completion == nil
                ? recovered.context.responses
                : recovered.outputs.responses
            let actual = try JSONEncoder().encode(retainedResponses)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: expected) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: actual) as? NSDictionary, vector.name)
            if vector.beforeDeath == "parked" {
                XCTAssertEqual(resumable.map(\.id), [run.id], vector.name)
                XCTAssertEqual(resumable.first?.park?.wakeAt, date(300))
                let fence = DeviceLegProfileFence()
                _ = try await reopened.resumeParked(
                    run.id,
                    profileFence: fence,
                    profileFenceToken: fence.token()
                )
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

    func testAuthorityRevocationSurvivesRelaunchAndBlocksAdmissionUntilReportingRetiresRuns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let candidate = arm()
        let admitted = try await journal.admit(
            arm: candidate,
            reentry: .init(type: .everyTime, windowSeconds: nil),
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

        let reopened = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let resumable = try await reopened.recover(at: date(250))
        let rows = try await reopened.runs()
        let abandoned = try XCTUnwrap(rows.first)
        XCTAssertTrue(resumable.isEmpty)
        XCTAssertEqual(abandoned.completion?.outcome, "abandoned")
        let finalizedBeforeReporting = try await reopened.finalizeRevocation()
        XCTAssertFalse(finalizedBeforeReporting)
        let blocked = try await reopened.admit(
            arm: candidate,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "wait",
            at: date(260)
        )
        XCTAssertNil(blocked)

        try await reopened.markCompletionQueued(abandoned)
        let finalizedAfterReporting = try await reopened.finalizeRevocation()
        XCTAssertTrue(finalizedAfterReporting)
        let admittedAfterRetirement = try await reopened.admit(
            arm: candidate,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "wait",
            at: date(270)
        )
        XCTAssertNotNil(admittedAfterRetirement)
    }

    func testCheckmarksRetireAfterDeliveryAndTheAuthoredReentryWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let once = DeviceLeg.Reentry(type: .oneTime, windowSeconds: nil)
        let admittedOnce = try await journal.admit(
            arm: arm(),
            reentry: once,
            entryStepId: "step",
            at: date(100)
        )
        let onceRun = try XCTUnwrap(admittedOnce)
        try await finish(journal, run: onceRun, at: 110)
        try await journal.retainCheckmarks(
            liveExperiences: ["experience": once],
            at: date(200)
        )
        try await journal.retainCheckmarks(
            liveExperiences: [:],
            at: date(201)
        )
        let retiredOnceCheckmark = try await journal.checkmark(
            experienceId: "experience"
        )
        XCTAssertNil(retiredOnceCheckmark)
        let onceReadmitted = try await journal.admit(
            arm: arm(),
            reentry: once,
            entryStepId: "step",
            at: date(202)
        )
        XCTAssertNotNil(onceReadmitted)

        let windowArm = ArmedDeviceLeg(
            reference: .init(
                experienceId: "window-experience",
                versionId: "version",
                legId: String(repeating: "c", count: 64),
                descriptorSha256: String(repeating: "d", count: 64)
            ),
            binding: .init(type: .new, journeyId: nil, generation: nil),
            entryCondition: arm().entryCondition,
            context: .init(event: [:], responses: [:])
        )
        let window = DeviceLeg.Reentry(
            type: .oncePerWindow,
            windowSeconds: 100
        )
        let admittedWindow = try await journal.admit(
            arm: windowArm,
            reentry: window,
            entryStepId: "step",
            at: date(300)
        )
        let windowRun = try XCTUnwrap(admittedWindow)
        try await finish(journal, run: windowRun, at: 310)
        try await journal.retainCheckmarks(
            liveExperiences: ["window-experience": window],
            at: date(400)
        )
        try await journal.retainCheckmarks(
            liveExperiences: [:],
            at: date(499)
        )
        let retainedWindowCheckmark = try await journal.checkmark(
            experienceId: "window-experience"
        )
        XCTAssertNotNil(retainedWindowCheckmark)
        try await journal.retainCheckmarks(
            liveExperiences: [:],
            at: date(500)
        )
        let retiredWindowCheckmark = try await journal.checkmark(
            experienceId: "window-experience"
        )
        XCTAssertNil(retiredWindowCheckmark)
    }

    func testProfileReplacementCannotConsumeAParkWithAStaleToken() async throws {
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
            entryStepId: "wait",
            at: date(100)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)
        try await journal.park(run.id, stepId: "wait", until: date(200))
        let fence = DeviceLegProfileFence()
        let stale = fence.token()
        _ = fence.advance()

        let resumed = try await journal.resumeParked(
            run.id,
            profileFence: fence,
            profileFenceToken: stale
        )

        XCTAssertNil(resumed)
        let retainedPark = try await journal.runs().first?.park
        XCTAssertNotNil(retainedPark)
    }

    func testAdmissionPublishesItsStateReceiptInsideTheProfileFence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let fence = DeviceLegProfileFence()
        let token = fence.token()
        let releaseReceipt = DispatchSemaphore(value: 0)
        let receipt = LockedBoolean()
        let advanceFinished = AsyncBoolean()
        let candidate = arm()

        let admission = Task {
            try await journal.admit(
                arm: candidate,
                release: release(for: candidate.reference),
                reentry: .init(type: .everyTime, windowSeconds: nil),
                entryStepId: "wait",
                at: date(100),
                profileFence: fence,
                profileFenceToken: token,
                onAdmitted: {
                    receipt.setTrue()
                    releaseReceipt.wait()
                }
            )
        }
        for _ in 0..<200 where !receipt.value {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(receipt.value)
        let replacement = Task {
            _ = fence.advance()
            await advanceFinished.setTrue()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let advancedWhilePublishing = await advanceFinished.value()
        XCTAssertFalse(advancedWhilePublishing)

        releaseReceipt.signal()
        let admitted = try await admission.value
        XCTAssertNotNil(admitted)
        await replacement.value
        XCTAssertTrue(receipt.value)
    }

    func testAdmissionPinsReleaseUntilTheLastReferencingRunRetires() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let enrollmentArm = arm()
        let pin = release(for: enrollmentArm.reference)
        let admittedFirst = try await journal.admit(
            arm: enrollmentArm,
            release: pin,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "step",
            at: date(100)
        )
        let first = try XCTUnwrap(admittedFirst)
        let continuationArm = arm(binding: .init(
            type: .continuation,
            journeyId: first.journeyId,
            generation: 1
        ))
        let conflictingPin = DeviceLegReleaseProfileEntry(
            locator: .init(
                appId: pin.locator.appId,
                environment: pin.locator.environment,
                experienceId: pin.locator.experienceId,
                experienceVersionId: pin.locator.experienceVersionId,
                versionNumber: pin.locator.versionNumber,
                buildId: "other-build",
                publishedAt: pin.locator.publishedAt,
                publishedAtSeq: pin.locator.publishedAtSeq,
                legId: pin.locator.legId
            ),
            envelope: pin.envelope
        )
        do {
            _ = try await journal.admit(
                arm: continuationArm,
                release: conflictingPin,
                reentry: .init(type: .everyTime, windowSeconds: nil),
                entryStepId: "step",
                at: date(105)
            )
            XCTFail("Expected one digest to retain exactly one release")
        } catch DeviceLegJournalError.invalidState {
        } catch {
            XCTFail("Unexpected release conflict error: \(error)")
        }
        let admittedSecond = try await journal.admit(
            arm: continuationArm,
            release: pin,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "step",
            at: date(110)
        )
        let second = try XCTUnwrap(admittedSecond)

        let persistedPin = try await journal.releasePin(
            descriptorSHA256: enrollmentArm.reference.descriptorSha256
        )
        let persisted = try XCTUnwrap(persistedPin)
        XCTAssertEqual(
            try ExactJSONCodec.encode(persisted),
            try ExactJSONCodec.encode(pin)
        )

        try await finish(journal, run: first, at: 120)
        let retainedAfterFirst = try await journal.releasePin(
            descriptorSHA256: enrollmentArm.reference.descriptorSha256
        )
        XCTAssertNotNil(retainedAfterFirst)

        try await finish(journal, run: second, at: 130)
        let retainedAfterSecond = try await journal.releasePin(
            descriptorSHA256: enrollmentArm.reference.descriptorSha256
        )
        XCTAssertNil(retainedAfterSecond)
    }

    func testAdmissionPinsArtifactsUntilTheLastReferencingRunRetires() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheDirectory = directory.appendingPathComponent(
            "release-cache",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let artifactBytes = Data("durable-render-artifact".utf8)
        let artifactSHA256 = SHA256Provider.hexDigest(artifactBytes)
        try artifactBytes.write(
            to: cacheDirectory.appendingPathComponent(artifactSHA256)
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let enrollmentArm = arm()
        let source = DeviceLegReleaseArtifactSource(
            descriptorSHA256: enrollmentArm.reference.descriptorSha256,
            objects: [.init(
                sha256: artifactSHA256,
                sizeBytes: artifactBytes.count,
                required: true
            )],
            cacheRoot: cacheDirectory
        )
        let admittedFirst = try await journal.admit(
            arm: enrollmentArm,
            release: release(for: enrollmentArm.reference),
            artifactSource: source,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "step",
            at: date(100)
        )
        let first = try XCTUnwrap(admittedFirst)
        let firstPins = try await journal.pinnedArtifacts(forRunId: first.id)
        let artifactPin = try XCTUnwrap(
            firstPins?.objectURLsBySHA256[artifactSHA256]
        )
        try FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent(artifactSHA256)
        )
        XCTAssertEqual(try Data(contentsOf: artifactPin), artifactBytes)

        let continuationArm = arm(binding: .init(
            type: .continuation,
            journeyId: first.journeyId,
            generation: 1
        ))
        let admittedSecond = try await journal.admit(
            arm: continuationArm,
            release: release(for: continuationArm.reference),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "step",
            at: date(110)
        )
        let second = try XCTUnwrap(admittedSecond)
        let secondPins = try await journal.pinnedArtifacts(forRunId: second.id)
        XCTAssertEqual(
            secondPins?.objectURLsBySHA256[artifactSHA256],
            artifactPin
        )

        try await finish(journal, run: first, at: 120)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactPin.path))

        try await finish(journal, run: second, at: 130)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactPin.path))
    }

    func testRequiredArtifactPinFailureRollsBackAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheDirectory = directory.appendingPathComponent(
            "empty-release-cache",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let candidate = arm()
        let source = DeviceLegReleaseArtifactSource(
            descriptorSHA256: candidate.reference.descriptorSha256,
            objects: [.init(
                sha256: String(repeating: "c", count: 64),
                sizeBytes: 16,
                required: true
            )],
            cacheRoot: cacheDirectory
        )

        do {
            _ = try await journal.admit(
                arm: candidate,
                release: release(for: candidate.reference),
                artifactSource: source,
                reentry: .init(type: .everyTime, windowSeconds: nil),
                entryStepId: "step",
                at: date(100)
            )
            XCTFail("Expected missing required artifact rejection")
        } catch DeviceLegJournalError.invalidState {
        } catch {
            XCTFail("Unexpected artifact pin error: \(error)")
        }

        let runs = try await journal.runs()
        let retainedRelease = try await journal.releasePin(
            descriptorSHA256: candidate.reference.descriptorSha256
        )
        XCTAssertTrue(runs.isEmpty)
        XCTAssertNil(retainedRelease)
        let pinDirectory = directory
            .appendingPathComponent("device-leg-journal-v1/release-pins")
            .appendingPathComponent(
                DeviceLegStorageScope.testFixture.customerDigest(
                    distinctId: "customer"
                )
            )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: pinDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testArtifactManifestAggregateLimitRollsBackAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = arm()
        let source = DeviceLegReleaseArtifactSource(
            descriptorSHA256: candidate.reference.descriptorSha256,
            objects: [
                .init(
                    sha256: String(repeating: "c", count: 64),
                    sizeBytes: 64 * 1_024 * 1_024,
                    required: false
                ),
                .init(
                    sha256: String(repeating: "d", count: 64),
                    sizeBytes: 64 * 1_024 * 1_024,
                    required: false
                ),
                .init(
                    sha256: String(repeating: "e", count: 64),
                    sizeBytes: 1,
                    required: false
                ),
            ],
            cacheRoot: directory
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )

        do {
            _ = try await journal.admit(
                arm: candidate,
                release: release(for: candidate.reference),
                artifactSource: source,
                reentry: .init(type: .everyTime, windowSeconds: nil),
                entryStepId: "step",
                at: date(100)
            )
            XCTFail("Expected artifact aggregate limit rejection")
        } catch DeviceLegJournalError.storageLimit {
        } catch {
            XCTFail("Unexpected artifact aggregate error: \(error)")
        }

        let runs = try await journal.runs()
        let retainedRelease = try await journal.releasePin(
            descriptorSHA256: candidate.reference.descriptorSha256
        )
        XCTAssertTrue(runs.isEmpty)
        XCTAssertNil(retainedRelease)
    }

    func testAdmissionRetainsTheMaximumProfileDescriptorBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let descriptorSize = ExperienceReleaseDescriptorLimits.descriptorBytes

        for index in 0..<4 {
            let descriptorBytes = Data(
                repeating: UInt8(index + 1),
                count: descriptorSize
            )
            let reference = ArmedDeviceLeg.Reference(
                experienceId: "experience-\(index)",
                versionId: "version-\(index)",
                legId: String(repeating: String(format: "%x", index + 10), count: 64),
                descriptorSha256: SHA256Provider.hexDigest(descriptorBytes)
            )
            let candidate = ArmedDeviceLeg(
                reference: reference,
                binding: .init(type: .new, journeyId: nil, generation: nil),
                entryCondition: .init(
                    type: .appForegrounded,
                    eventName: nil,
                    segmentId: nil,
                    member: nil,
                    condition: nil
                ),
                context: .init(event: [:], responses: [:])
            )
            let fixture = release(for: reference)
            let retainedRelease = DeviceLegReleaseProfileEntry(
                locator: fixture.locator,
                envelope: .init(
                    mediaType: fixture.envelope.mediaType,
                    encoding: fixture.envelope.encoding,
                    descriptorSha256: reference.descriptorSha256,
                    descriptorSizeBytes: descriptorBytes.count,
                    descriptorBytesBase64: descriptorBytes.base64EncodedString(),
                    signature: fixture.envelope.signature
                )
            )

            let admitted = try await journal.admit(
                arm: candidate,
                release: retainedRelease,
                reentry: .init(type: .everyTime, windowSeconds: nil),
                entryStepId: "wait",
                at: date(Double(100 + index))
            )
            XCTAssertNotNil(admitted)
        }

        let retainedRuns = try await journal.runs()
        XCTAssertEqual(retainedRuns.count, 4)
    }

    func testAdmissionRetainsAContextLargerThanTheLegacyJournalBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let fixture = arm()
        let candidate = ArmedDeviceLeg(
            reference: fixture.reference,
            binding: fixture.binding,
            entryCondition: fixture.entryCondition,
            context: .init(
                event: [
                    "payload": .string(String(
                        repeating: "x",
                        count: 17 * 1_024 * 1_024
                    )),
                ],
                responses: [:]
            )
        )

        let admitted = try await journal.admit(
            arm: candidate,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "wait",
            at: date(100)
        )

        XCTAssertNotNil(admitted)
    }

    func testCompletionMovesMaximumSizeOutputsOutOfExecutionContext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let fixture = arm()
        let payload = String(repeating: "x", count: 21 * 1_024 * 1_024)
        let candidate = ArmedDeviceLeg(
            reference: fixture.reference,
            binding: fixture.binding,
            entryCondition: fixture.entryCondition,
            context: .init(event: ["payload": .string(payload)], responses: [:])
        )
        let admitted = try await journal.admit(
            arm: candidate,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "complete",
            at: date(100)
        )
        let run = try XCTUnwrap(admitted)

        try await journal.complete(
            run.id,
            outcome: "done",
            at: date(200),
            eventOutputs: ["payload": .string(payload)]
        )

        let completedRuns = try await journal.runs()
        let completed = try XCTUnwrap(completedRuns.first)
        XCTAssertTrue(completed.context.event.isEmpty)
        guard case .string(let retainedPayload)? = completed.outputs.event["payload"] else {
            return XCTFail("Expected retained terminal event output")
        }
        XCTAssertEqual(retainedPayload, payload)
    }

    func testLargeCollectedResponsesAreNotDuplicatedBeforeCompletion() async throws {
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
            entryStepId: "survey",
            at: date(100)
        )
        let run = try XCTUnwrap(admitted)
        let answer = String(repeating: "y", count: 21 * 1_024 * 1_024)

        try await journal.recordResponses(
            run.id,
            values: ["answer": .string(answer)]
        )
        let pendingRuns = try await journal.runs()
        let pending = try XCTUnwrap(pendingRuns.first)
        guard case .string(let pendingAnswer)? = pending.context.responses["answer"] else {
            return XCTFail("Expected retained pending response")
        }
        XCTAssertEqual(pendingAnswer, answer)
        XCTAssertTrue(pending.outputs.responses.isEmpty)

        try await journal.complete(
            run.id,
            outcome: "done",
            at: date(200),
            responseOutputs: ["answer": .string(answer)]
        )
        let completedRuns = try await journal.runs()
        let completed = try XCTUnwrap(completedRuns.first)
        XCTAssertTrue(completed.context.responses.isEmpty)
        guard case .string(let completedAnswer)? = completed.outputs.responses["answer"] else {
            return XCTFail("Expected retained terminal response output")
        }
        XCTAssertEqual(completedAnswer, answer)
    }

    func testCompletionPublishesOnlyDeclaredResponseOutputs() async throws {
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
            entryStepId: "survey",
            at: date(100)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.recordResponses(
            run.id,
            values: [
                "declared": .string("publish"),
                "private": .string("do-not-publish"),
            ]
        )

        try await journal.complete(
            run.id,
            outcome: "done",
            at: date(200),
            responseOutputs: ["declared": .string("publish")]
        )

        let completedRuns = try await journal.runs()
        let completed = try XCTUnwrap(completedRuns.first)
        XCTAssertTrue(completed.context.responses.isEmpty)
        XCTAssertEqual(
            try ExactJSONCodec.encode(completed.outputs.responses),
            try ExactJSONCodec.encode([
                "declared": ExperienceReleaseJSONValue.string("publish"),
            ])
        )
    }

    func testReleasePinCleanupIsIsolatedByCustomer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-a"
        )
        let second = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-b"
        )
        let candidate = arm()
        let policy = DeviceLeg.Reentry(
            type: .everyTime,
            windowSeconds: nil
        )
        let admittedFirst = try await first.admit(
            arm: candidate,
            reentry: policy,
            entryStepId: "wait",
            at: date(100)
        )
        let firstRun = try XCTUnwrap(admittedFirst)
        let admittedSecond = try await second.admit(
            arm: candidate,
            reentry: policy,
            entryStepId: "wait",
            at: date(100)
        )
        let secondRun = try XCTUnwrap(admittedSecond)

        try await finish(first, run: firstRun, at: 110)

        let retiredPin = try await first.releasePin(
            descriptorSHA256: candidate.reference.descriptorSha256
        )
        let retainedPin = try await second.releasePin(
            descriptorSHA256: candidate.reference.descriptorSha256
        )
        XCTAssertNil(retiredPin)
        XCTAssertNotNil(retainedPin)

        try await finish(second, run: secondRun, at: 120)
    }

    func testJournalAndReleasePinsAreIsolatedBySetupScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer",
            storageScope: .init(
                authority: .init(
                    appId: "app-first",
                    environment: "production"
                )
            )
        )
        let second = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer",
            storageScope: .init(
                authority: .init(
                    appId: "app-second",
                    environment: "production"
                )
            )
        )
        let candidate = arm()

        let firstRun = try await first.admit(
            arm: candidate,
            reentry: .init(type: .oneTime, windowSeconds: nil),
            entryStepId: "wait",
            at: date(100)
        )

        XCTAssertNotNil(firstRun)
        let secondRunsBeforeAdmission = try await second.runs()
        XCTAssertTrue(secondRunsBeforeAdmission.isEmpty)
        let secondRun = try await second.admit(
            arm: candidate,
            reentry: .init(type: .oneTime, windowSeconds: nil),
            entryStepId: "wait",
            at: date(100)
        )
        XCTAssertNotNil(secondRun)
        let firstRuns = try await first.runs()
        let secondRuns = try await second.runs()
        XCTAssertEqual(firstRuns.count, 1)
        XCTAssertEqual(secondRuns.count, 1)
    }

    func testAdmissionBoundsAggregateReleasePinBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstArm = arm()
        let secondArm = ArmedDeviceLeg(
            reference: .init(
                experienceId: "experience-two",
                versionId: "version-two",
                legId: String(repeating: "c", count: 64),
                descriptorSha256: String(repeating: "d", count: 64)
            ),
            binding: .init(type: .new, journeyId: nil, generation: nil),
            entryCondition: firstArm.entryCondition,
            context: firstArm.context
        )
        let firstRelease = release(for: firstArm.reference)
        let secondRelease = release(for: secondArm.reference)
        let aggregateBytes = try ExactJSONCodec.encode(firstRelease).count
            + ExactJSONCodec.encode(secondRelease).count
        let firstJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-a",
            releasePinBudgetBytes: aggregateBytes - 1
        )
        let secondJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-b",
            releasePinBudgetBytes: aggregateBytes - 1
        )

        let first = try await firstJournal.admit(
            arm: firstArm,
            release: firstRelease,
            reentry: .init(type: .everyTime, windowSeconds: nil),
            entryStepId: "wait",
            at: date(100)
        )
        XCTAssertNotNil(first)
        do {
            _ = try await secondJournal.admit(
                arm: secondArm,
                release: secondRelease,
                reentry: .init(type: .everyTime, windowSeconds: nil),
                entryStepId: "wait",
                at: date(101)
            )
            XCTFail("Expected aggregate release-pin budget rejection")
        } catch DeviceLegJournalError.storageLimit {
        } catch {
            XCTFail("Unexpected aggregate release-pin error: \(error)")
        }
        let firstRuns = try await firstJournal.runs()
        let secondRuns = try await secondJournal.runs()
        XCTAssertEqual(firstRuns.count, 1)
        XCTAssertTrue(secondRuns.isEmpty)
    }

    func testRecoveryAbandonsAParkedRunWhoseReleasePinIsMissing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let candidate = arm()
        let admitted = try await journal.admit(
            arm: candidate,
            release: release(for: candidate.reference),
            reentry: .init(type: .everyTime, windowSeconds: nil),
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

        let pinFile = directory
            .appendingPathComponent("device-leg-journal-v1", isDirectory: true)
            .appendingPathComponent("release-pins", isDirectory: true)
            .appendingPathComponent(
                DeviceLegStorageScope.testFixture.customerDigest(
                    distinctId: "customer"
                ),
                isDirectory: true
            )
            .appendingPathComponent(
                "\(candidate.reference.descriptorSha256).json"
            )
        try FileManager.default.removeItem(at: pinFile)

        let reopened = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let resumable = try await reopened.recover(at: date(200))
        let recoveredRuns = try await reopened.runs()
        let recovered = try XCTUnwrap(recoveredRuns.first)
        XCTAssertTrue(resumable.isEmpty)
        XCTAssertEqual(recovered.completion?.outcome, "abandoned")
        XCTAssertEqual(recovered.completion?.at, date(200))
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

    func testParkedEventPersistsWithItsCheckpointAcrossRelaunch() async throws {
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
            entryStepId: "wait",
            at: date(1)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)
        let checkpoint = DeviceLegControlExecutor.Checkpoint(
            anchorAtMillis: 2_000,
            wakeAtMillis: 12_000
        )
        try await journal.transition(
            run.id,
            stepId: "wait",
            context: run.context,
            checkpoint: checkpoint
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(
            identity.performWithCurrentIdentityFence("customer", { _ in () })
        )
        let executionFence = DeviceLegProfileFence()
        let admission = DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFence.token()
        )
        let event = DeviceLegControlExecutor.Event(
            name: "unlock",
            occurredAtMillis: 3_000,
            properties: ["allowed": .bool(true)]
        )

        let staged = try await journal.stageParkedEvent(
            run.id,
            expectedStepId: "wait",
            expectedCheckpoint: checkpoint,
            event: event,
            admission: admission
        )
        XCTAssertTrue(staged)

        let reopened = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let reopenedRuns = try await reopened.runs()
        let persisted = try XCTUnwrap(reopenedRuns.first?.park)
        XCTAssertEqual(persisted.anchorAt, date(2))
        XCTAssertEqual(persisted.wakeAt, date(12))
        XCTAssertEqual(persisted.pendingEvent, event)
    }

    func testTransitionAdmissionRejectsRevokedExecutionAuthority() async throws {
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
            entryStepId: "present",
            at: date(1)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(
            identity.performWithCurrentIdentityFence("customer", { _ in () })
        )
        let executionFence = DeviceLegProfileFence()
        let executionToken = executionFence.token()
        let admission = DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionToken
        )
        _ = executionFence.advance()

        let committed = try await journal.transition(
            run.id,
            stepId: "late-route",
            context: .init(event: ["late": .bool(true)], responses: [:]),
            admission: admission
        )

        XCTAssertFalse(committed)
        let retainedRuns = try await journal.runs()
        let retained = try XCTUnwrap(retainedRuns.first)
        XCTAssertEqual(retained.stepId, "present")
        XCTAssertTrue(retained.context.event.dictionary.isEmpty)
    }

    func testCompletionAdmissionRejectsRevokedIdentityAuthority() async throws {
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
            entryStepId: "present",
            at: date(1)
        )
        let run = try XCTUnwrap(admitted)
        try await journal.markStartedQueued(run)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(
            identity.performWithCurrentIdentityFence("customer", { _ in () })
        )
        let executionFence = DeviceLegProfileFence()
        let admission = DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFence.token()
        )
        identity.setDistinctId("replacement-customer")

        let committed = try await journal.complete(
            run.id,
            outcome: "host_dismissed",
            at: date(2),
            admission: admission
        )

        XCTAssertFalse(committed)
        let retainedRuns = try await journal.runs()
        let retained = try XCTUnwrap(retainedRuns.first)
        XCTAssertNil(retained.completion)
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
            ).first { $0.pathExtension == "json" }
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
        try await journal.complete(
            run.id,
            outcome: "done",
            at: date(200),
            responseOutputs: ["answer": .string("yes")]
        )
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

    func testLifecycleCaptureReplayDoesNotRedeliverCommittedSubscribersAfterCrashWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try await eventLog(directory: directory, store: SQLiteEventStore(), api: MockNuxieApiForQueue())
        let routes = LegRouteRecorder()
        await log.subscribeCommitted { event in await routes.record(event) }
        let journal = try DeviceLegRunJournal(directory: directory, distinctId: "customer")
        let admitted = try await journal.admit(arm: arm(), reentry: .init(type: .everyTime, windowSeconds: nil),
                                               entryStepId: "screen", at: date(100))
        let run = try XCTUnwrap(admitted)

        // Simulate termination after the stable event reached subscribers but
        // before the journal acknowledged that capture.
        let startedAttempt = await log.captureAndRouteSystemEvent(
            .init(
                name: JourneyEvents.journeyLegStarted,
                properties: ["journey_id": run.journeyId],
                eventId: run.startedEventId,
                distinctId: "customer"
            )
        )
        _ = try XCTUnwrap(startedAttempt)
        await log.drain()

        try await DeviceLegReporter(journal: journal, events: log).flushPending()
        await log.drain()
        let startedRoutes = await routes.names()
        XCTAssertEqual(startedRoutes, [JourneyEvents.journeyLegStarted])

        try await journal.complete(run.id, outcome: "done", at: date(200))
        let completedAttempt = await log.captureAndRouteSystemEvent(
            .init(
                name: JourneyEvents.journeyLegCompleted,
                properties: ["journey_id": run.journeyId],
                eventId: run.completedEventId,
                distinctId: "customer"
            )
        )
        _ = try XCTUnwrap(completedAttempt)
        await log.drain()

        try await DeviceLegReporter(journal: journal, events: log).flushPending()
        await log.drain()
        let completedRoutes = await routes.names()
        XCTAssertEqual(completedRoutes, [
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
        ])
        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        await log.close()
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

    private func release(
        for reference: ArmedDeviceLeg.Reference
    ) -> DeviceLegReleaseProfileEntry {
        testDeviceLegRelease(for: reference)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
}

private extension DeviceLegRunJournal {
    func admit(
        arm: ArmedDeviceLeg,
        reentry: DeviceLeg.Reentry,
        entryStepId: String,
        at: Date
    ) async throws -> DeviceLegRun? {
        try await admit(
            arm: arm,
            release: testDeviceLegRelease(for: arm.reference),
            reentry: reentry,
            entryStepId: entryStepId,
            at: at
        )
    }
}

private func testDeviceLegRelease(
    for reference: ArmedDeviceLeg.Reference
) -> DeviceLegReleaseProfileEntry {
    .init(
        locator: .init(
            appId: "app",
            environment: "test",
            experienceId: reference.experienceId,
            experienceVersionId: reference.versionId,
            versionNumber: 1,
            buildId: "build",
            publishedAt: "2026-08-31T00:00:00.000Z",
            publishedAtSeq: 1,
            legId: reference.legId
        ),
        envelope: .init(
            mediaType: DeviceLegReleaseDescriptor.mediaType,
            encoding: "base64",
            descriptorSha256: reference.descriptorSha256,
            descriptorSizeBytes: 2,
            descriptorBytesBase64: "e30=",
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "test",
                signatureBase64: String(repeating: "A", count: 88)
            )
        )
    )
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }
    func setTrue() { lock.withLock { stored = true } }
}

private actor AsyncBoolean {
    private var stored = false
    func setTrue() { stored = true }
    func value() -> Bool { stored }
}

private actor LostCompletionAcknowledgement: RoutedStableSystemEventCapturing {
    let events: EventLog
    init(events: EventLog) { self.events = events }

    func captureSystemEvent(_ event: String, properties: sending [String: Any]?, eventId: String,
                            distinctId: String) async -> DurableTriggerCapture? {
        let captured = await events.captureSystemEvent(event, properties: properties, eventId: eventId, distinctId: distinctId)
        return event == JourneyEvents.journeyLegCompleted ? nil : captured
    }

    func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest
    ) async -> DurableTriggerCapture? {
        let captured = await events.captureAndRouteSystemEvent(request)
        return request.name == JourneyEvents.journeyLegCompleted ? nil : captured
    }

    func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest,
        admission: any StableEventCaptureCommitAdmission
    ) async -> DurableTriggerCapture? {
        let captured = await events.captureAndRouteSystemEvent(
            request,
            admission: admission
        )
        return request.name == JourneyEvents.journeyLegCompleted ? nil : captured
    }

    func captureAndRouteSystemEventBatch(
        _ items: [RoutedStableSystemEventBatchItem],
        admission: any StableEventCaptureBatchCommitAdmission
    ) async -> [String: DurableTriggerCapture]? {
        await events.captureAndRouteSystemEventBatch(
            items,
            admission: admission
        )
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

private actor LegRouteRecorder {
    private var values: [String] = []
    func record(_ event: NuxieEvent) { values.append(event.name) }
    func names() -> [String] { values }
}
