import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

private final class SupersedingProfileAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        lock.withLock { reads }
    }

    func isCurrent() -> Bool {
        lock.withLock {
            reads += 1
            return reads == 1
        }
    }
}

private final class DeviceLegJournalPersistenceFailures: @unchecked Sendable {
    private enum InjectedFailure: Error {
        case persist
    }

    private let lock = NSLock()
    private var remaining = 0

    func failNext(_ count: Int) {
        lock.withLock { remaining = max(count, 0) }
    }

    func beforePersist() throws {
        let shouldFail = lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if shouldFail {
            throw InjectedFailure.persist
        }
    }
}

private final class DeviceLegBeforeSendCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int { lock.withLock { count } }

    func record() {
        lock.withLock { count += 1 }
    }
}

private actor DeviceLegNthRoutedCaptureGate {
    private let eventName: String
    private let suspendedCall: Int
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(eventName: String, suspendedCall: Int) {
        self.eventName = eventName
        self.suspendedCall = suspendedCall
    }

    func intercept(event: String) async {
        guard event == eventName else { return }
        count += 1
        guard count == suspendedCall else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func observationCount() -> Int { count }
    func isSuspended() -> Bool { continuation != nil }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class DeviceLegCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool { lock.withLock { completed } }

    func finish() {
        lock.withLock { completed = true }
    }
}

final class DeviceLegServiceTests: XCTestCase {
    func testSendEventRoutesTheDurableCaptureToCommittedSubscribers() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(identity.performWithCurrentIdentityFence(
            "customer",
            { _ in () }
        ))
        let executionFence = DeviceLegProfileFence()
        let executionGeneration = executionFence.advance()
        let executionFenceToken = try XCTUnwrap(executionFence.token(
            ifCurrent: executionGeneration
        ))
        let events = CaptureOnlyDeviceLegEvents()
        let dispatcher = DeviceLegEffectDispatcher(
            identity: identity,
            events: events
        )

        let result = await dispatcher.dispatch(.init(
            runId: "journey:0",
            journeyId: "journey",
            generation: 0,
            reference: arm.reference,
            release: release,
            stepId: "send",
            action: [
                "type": .string("send_event"),
                "eventName": .string("inventory_checked"),
            ],
            context: .init(event: [:], responses: [:]),
            effectId: "00000000-0000-7000-8000-000000000203",
            distinctId: "customer",
            identityFence: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        ))

        XCTAssertEqual(result, .outlet("next"))
        let routedNames = await events.routedNames()
        XCTAssertEqual(routedNames, ["inventory_checked"])
    }

    func testDurableEventEffectsDoNotCommitAcrossExecutionRevocation() async throws {
        let cases: [(action: [String: ExperienceReleaseJSONValue], id: String)] = [
            (
                action: [
                    "type": .string("send_event"),
                    "eventName": .string("inventory_checked"),
                ],
                id: "00000000-0000-7000-8000-000000000211"
            ),
            (
                action: [
                    "type": .string("milestone"),
                    "milestoneId": .string("inventory_checked"),
                ],
                id: "00000000-0000-7000-8000-000000000212"
            ),
            (
                action: [
                    "type": .string("app_action"),
                    "name": .string("open_inventory"),
                ],
                id: "00000000-0000-7000-8000-000000000213"
            ),
        ]

        for fixture in cases {
            try await assertDurableEventCommitIsRejected(
                action: fixture.action,
                effectId: fixture.id,
                revocation: .execution
            )
        }
    }

    func testDurableEventEffectDoesNotCommitAcrossIdentityRevocation() async throws {
        try await assertDurableEventCommitIsRejected(
            action: [
                "type": .string("send_event"),
                "eventName": .string("inventory_checked"),
            ],
            effectId: "00000000-0000-7000-8000-000000000214",
            revocation: .identity
        )
    }

    func testLocalEffectIsClaimedBeforeDispatchAndAdvancesItsSelectedOutlet() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let effect = DeviceLeg.Step(
            kind: .action,
            id: "effect",
            action: ["type": .string("submit_response")],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "effect",
            steps: [effect, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let dispatcher = InspectingDeviceLegDispatcher(
            directory: directory,
            distinctId: "customer"
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: dispatcher
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let dispatchedRequest = await dispatcher.onlyRequest()
        let request = try XCTUnwrap(dispatchedRequest)
        XCTAssertEqual(request.stepId, "effect")
        XCTAssertFalse(request.effectId.isEmpty)
        let observedDurableClaim = await dispatcher.observedDurableClaim()
        XCTAssertTrue(observedDurableClaim)
        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            },
            [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted]
        )
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "continue"
        )
    }

    func testSendEventResolvesLegContextAndCompletesAfterDurableCapture() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let eventField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("sku"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let send = DeviceLeg.Step(
            kind: .action,
            id: "send",
            action: [
                "type": .string("send_event"),
                "eventName": .string("inventory_checked"),
                "payload": .object([
                    "sku": .object([
                        "type": .string("Event.Field"),
                        "key": .string("sku"),
                    ]),
                ]),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "check_inventory",
                segmentId: nil,
                member: nil,
                condition: nil
            ),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            inputs: .init(eventFields: [eventField], responseFields: []),
            entryStepId: "send",
            steps: [send, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000201",
            name: "check_inventory",
            distinctId: "customer",
            properties: ["sku": "pro", "ignored": true],
            timestamp: Date(timeIntervalSince1970: 1_001)
        ))

        let authored = try XCTUnwrap(events.routedEvents.first {
            $0.name == "inventory_checked"
        })
        XCTAssertEqual(authored.properties["sku"] as? String, "pro")
        XCTAssertNil(authored.properties["ignored"])
        XCTAssertNotNil(authored.properties["journey_id"] as? String)
        XCTAssertEqual(
            authored.properties["experience_id"] as? String,
            "experience_golden"
        )
        XCTAssertEqual(
            authored.properties["leg_id"] as? String,
            snapshot.profile.armedLegs[0].reference.legId
        )
        XCTAssertEqual(authored.properties["leg_generation"] as? Int, 0)
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "continue"
        )
    }

    func testExitCompletesWithTheAuthoredOutcomeWithoutAnOutlet() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let exit = DeviceLeg.Step(
            kind: .action,
            id: "exit",
            action: [
                "type": .string("exit"),
                "reason": .string("opted_out"),
            ],
            outlets: [:],
            outcome: nil
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            completionOutputs: [:],
            entryStepId: "exit",
            steps: [exit]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "opted_out"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
    }

    func testExitWithAnEmptyReasonUsesTheDefaultCompletedOutcome() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let exit = DeviceLeg.Step(
            kind: .action,
            id: "exit",
            action: [
                "type": .string("exit"),
                "reason": .string(""),
            ],
            outlets: [:],
            outcome: nil
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            completionOutputs: [:],
            entryStepId: "exit",
            steps: [exit]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "completed"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
    }

    func testLocalEffectsResolveContextWithoutResponseSessionSynchronization() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let eventField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("sku"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let eventValue: ExperienceReleaseJSONValue = .object([
            "type": .string("Event.Field"),
            "key": .string("sku"),
        ])
        let steps = [
            DeviceLeg.Step(
                kind: .action,
                id: "update",
                action: [
                    "type": .string("update_customer"),
                    "attributes": .object(["plan": eventValue]),
                ],
                outlets: ["next": "milestone"],
                outcome: nil
            ),
            DeviceLeg.Step(
                kind: .action,
                id: "milestone",
                action: [
                    "type": .string("milestone"),
                    "milestoneId": .string("inventory_checked"),
                ],
                outlets: ["next": "submit"],
                outcome: nil
            ),
            DeviceLeg.Step(
                kind: .action,
                id: "submit",
                action: ["type": .string("submit_response")],
                outlets: ["next": "app-action"],
                outcome: nil
            ),
            DeviceLeg.Step(
                kind: .action,
                id: "app-action",
                action: [
                    "type": .string("app_action"),
                    "name": .string("open_inventory"),
                    "payload": .object(["sku": eventValue]),
                ],
                outlets: ["next": "report"],
                outcome: nil
            ),
            DeviceLeg.Step(
                kind: .complete,
                id: "report",
                action: nil,
                outlets: nil,
                outcome: "continue"
            ),
        ]
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "check_inventory",
                segmentId: nil,
                member: nil,
                condition: nil
            ),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            inputs: .init(eventFields: [eventField], responseFields: []),
            entryStepId: "update",
            steps: steps
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let appActions = await MainActor.run { DeviceLegAppActionRecorder() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: DeviceLegEffectDispatcher(
                identity: identity,
                events: events,
                appActionHandler: { action in appActions.record(action) }
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000202",
            name: "check_inventory",
            distinctId: "customer",
            properties: ["sku": "pro"],
            timestamp: Date(timeIntervalSince1970: 1_002)
        ))

        XCTAssertEqual(identity.getUserProperties()["plan"] as? String, "pro")
        XCTAssertEqual(
            events.routedEvents.map(\.name),
            [
                JourneyEvents.journeyLegStarted,
                JourneyEvents.customerUpdated,
                JourneyEvents.journeyMilestone,
                JourneyEvents.appActionRequested,
                JourneyEvents.journeyLegCompleted,
            ],
            "submit_response must remain a local cursor advance"
        )
        let customerUpdated = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.customerUpdated
        })
        XCTAssertEqual(
            customerUpdated.properties["attributes_updated"] as? [String],
            ["plan"]
        )
        XCTAssertEqual(
            customerUpdated.properties["leg_id"] as? String,
            snapshot.profile.armedLegs[0].reference.legId
        )
        let milestone = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyMilestone
        })
        XCTAssertEqual(milestone.properties["milestone_id"] as? String, "inventory_checked")
        XCTAssertEqual(milestone.properties["experience_version_id"] as? String, snapshot.profile.armedLegs[0].reference.versionId)
        XCTAssertEqual(milestone.properties["leg_id"] as? String, snapshot.profile.armedLegs[0].reference.legId)
        XCTAssertEqual(milestone.properties["leg_generation"] as? Int, 0)

        let deliveredAction = await MainActor.run { appActions.onlyAction() }
        let action = try XCTUnwrap(deliveredAction)
        XCTAssertEqual(action.name, "open_inventory")
        XCTAssertEqual(action.payload?["sku"], .string("pro"))
        XCTAssertEqual(action.experience.experienceId, "experience_golden")
        XCTAssertEqual(action.experience.experienceVersion, snapshot.profile.armedLegs[0].reference.versionId)
        XCTAssertEqual(
            action.experience.journeyId,
            milestone.properties["journey_id"] as? String
        )
        let appActionRequested = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.appActionRequested
        })
        XCTAssertEqual(appActionRequested.properties["name"] as? String, "open_inventory")
        XCTAssertEqual(
            (appActionRequested.properties["payload"] as? [String: String])?["sku"],
            "pro"
        )
        XCTAssertEqual(
            appActionRequested.properties["leg_generation"] as? Int,
            0
        )
    }

    func testAppActionDoesNotPublishAcrossAnIdentityFenceChange() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let action = DeviceLeg.Step(
            kind: .action,
            id: "app-action",
            action: [
                "type": .string("app_action"),
                "name": .string("open_inventory"),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let report = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "app-action",
            steps: [action, report]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        identity.changeDistinctIdAfterNextFencedWork(to: "replacement")
        let events = MockEventLog()
        events.identity = identity
        let appActions = await MainActor.run { DeviceLegAppActionRecorder() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: DeviceLegEffectDispatcher(
                identity: identity,
                events: events,
                appActionHandler: { value in appActions.record(value) }
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let delivered = await MainActor.run { appActions.onlyAction() }
        XCTAssertNil(delivered)
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.appActionRequested
        })
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testAdmittedAppActionCompletesAcrossProfileRevalidation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let action = DeviceLeg.Step(
            kind: .action,
            id: "app-action",
            action: [
                "type": .string("app_action"),
                "name": .string("open_inventory"),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let report = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "app-action",
            steps: [action, report]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let appActions = await MainActor.run { DeviceLegAppActionRecorder() }
        let suspended = SuspendedDeviceLegDispatcher(
            underlying: DeviceLegEffectDispatcher(
                identity: identity,
                events: events,
                appActionHandler: { value in appActions.record(value) }
            )
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dispatcher: suspended
        )

        await service.initialize()
        let firstCommit = Task {
            await service.profileDidCommit(snapshot, distinctId: "customer")
        }
        await suspended.waitUntilEntered()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await suspended.resume()
        await firstCommit.value

        let delivered = await MainActor.run { appActions.onlyAction() }
        XCTAssertEqual(delivered?.name, "open_inventory")
        XCTAssertTrue(events.routedEvents.contains {
            $0.name == JourneyEvents.appActionRequested
        })
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "continue"
        )
    }

    func testCanonicalForegroundArmCompletesOnceAcrossProfileRevalidation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            reentry: .init(type: .everyTime, windowSeconds: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000))
        let service = DeviceLegService(
            identity: identity,
            events: events,
            dateProvider: now,
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: { _ in nil },
            dispatcher: DeviceLegEffectDispatcher(
                identity: identity,
                events: events
            ),
            pinnedReleaseAuthenticator: {
                _, _ in throw DeviceLegJournalError.invalidState
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            },
            [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted]
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
        let mark = try await journal.checkmark(experienceId: "experience_golden")
        XCTAssertEqual(mark?.outcome, "continue")
    }

    func testProfileArmedInBackgroundStartsWhenForegroundLatchOpens() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = DeviceLegService(
            identity: identity,
            events: events,
            dateProvider: MockDateProvider(),
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: { _ in nil },
            dispatcher: DeviceLegEffectDispatcher(
                identity: identity,
                events: events
            ),
            pinnedReleaseAuthenticator: {
                _, _ in throw DeviceLegJournalError.invalidState
            },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
        )

        await service.initialize()
        await service.onAppDidEnterBackground()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.onAppWillEnterForeground()
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.onAppBecameActive()

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            },
            [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted]
        )
    }

    func testRenderedArmPresentsItsAuthenticatedScreenWithoutParking() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let request = await MainActor.run { presenter.request }
        XCTAssertEqual(request?.screenId, "screen_welcome")
        XCTAssertEqual(request?.owner.distinctId, "customer")
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let activeRuns = try await journal.runs()
        let run = try XCTUnwrap(activeRuns.first)
        XCTAssertNil(run.park)
        XCTAssertNil(run.completion)
    }

    func testRenderedEmissionCommitsBeforeCompletionAndFinishesItsOwnedSurface() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completionCommitted = expectation(description: "completion committed")
        let presentationFinished = expectation(description: "presentation finished")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        await MainActor.run {
            presenter.onFinish = { presentationFinished.fulfill() }
        }
        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "continue-invocation",
            source: .init(
                screenId: request.screenId,
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000301",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: ["source": .string("button")]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(
            of: [completionCommitted, presentationFinished],
            timeout: 2
        )
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            "continue",
            JourneyEvents.journeyLegCompleted,
        ])
        let emitted = try XCTUnwrap(events.routedEvents.first { $0.name == "continue" })
        XCTAssertEqual(emitted.properties["source"] as? String, "button")
        XCTAssertEqual(emitted.properties["screen_id"] as? String, "screen_welcome")
        XCTAssertEqual(emitted.properties["journey_id"] as? String, request.owner.journeyId)
        let finished = await MainActor.run { presenter.finishedOwners }
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.journeyId, request.owner.journeyId)
        XCTAssertEqual(finished.first?.ownerDistinctId, "customer")
    }

    func testRenderedEmissionBatchPublishesAllEventsOrNoneBeforeRetry() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            inputs: .init(
                eventFields: [],
                responseFields: [[
                    "key": .string("plan"),
                    "type": .string("string"),
                    "required": .bool(false),
                ]]
            ),
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["plan"]
            )]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let initialRuns = try await journal.runs()
        let initialStep = try XCTUnwrap(initialRuns.first?.stepId)
        let batch = ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "atomic-invocation",
            source: .init(
                screenId: request.screenId,
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [
                .init(
                    id: "00000000-0000-7000-8000-000000000320",
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00.122Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("yearly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000321",
                    sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.123Z",
                    name: "button_tapped",
                    payload: ["source": .string("primary")]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000322",
                    sequence: 2,
                    occurredAt: "2026-08-29T12:00:00.124Z",
                    name: "continue",
                    payload: ["source": .string("primary")]
                ),
            ]
        )

        events.stableCaptureBatchFailureIndex = 1
        let firstAccepted = await request.onEmissionBatch(batch)
        XCTAssertFalse(firstAccepted)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let runsAfterFailure = try await journal.runs()
        let runAfterFailure = try XCTUnwrap(runsAfterFailure.first)
        XCTAssertEqual(runAfterFailure.stepId, initialStep)
        guard case .string(let stagedResponse)? =
            runAfterFailure.context.responses["plan"] else {
            return XCTFail("Expected the response to be staged before event publication")
        }
        XCTAssertEqual(stagedResponse, "yearly")
        XCTAssertEqual(
            runAfterFailure.pendingPresentationPublication?.invocationId,
            batch.invocationId
        )

        events.stableCaptureBatchFailureIndex = nil
        let completionCommitted = expectation(description: "completion committed")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        let retryAccepted = await request.onEmissionBatch(batch)
        XCTAssertTrue(retryAccepted)
        await fulfillment(of: [completionCommitted], timeout: 2)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            "button_tapped",
            "continue",
            JourneyEvents.journeyLegCompleted,
        ])
    }

    func testPendingRendererPublicationReplaysAfterRestartBeforeAbandonment() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            inputs: .init(
                eventFields: [],
                responseFields: [[
                    "key": .string("plan"),
                    "type": .string("string"),
                    "required": .bool(false),
                ]]
            ),
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["plan"]
            )]
        )
        do {
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let presenter = await MainActor.run {
                RecordingDeviceLegPresenter()
            }
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                presenter: presenter
            )

            await service.initialize()
            await service.profileDidCommit(snapshot, distinctId: "customer")
            let presentedRequest = await MainActor.run { presenter.request }
            let request = try XCTUnwrap(presentedRequest)
            events.stableCaptureBatchFailureIndex = 0

            let accepted = await request.onEmissionBatch(presentationBatch(
                request: request,
                invocationId: "restart-publication",
                emissions: [
                    .init(
                        id: "00000000-0000-7000-8000-000000000337",
                        sequence: 0,
                        occurredAt: "2026-08-29T12:00:00.120Z",
                        name: SystemEventNames.responseSet,
                        payload: [
                            "field": .string("plan"),
                            "value": .string("yearly"),
                        ]
                    ),
                    .init(
                        id: "00000000-0000-7000-8000-000000000338",
                        sequence: 1,
                        occurredAt: "2026-08-29T12:00:00.121Z",
                        name: "button_tapped",
                        payload: [:]
                    ),
                ]
            ))

            XCTAssertFalse(accepted)
            let journal = try DeviceLegRunJournal(
                directory: directory,
                distinctId: "customer"
            )
            let persistedRuns = try await journal.runs()
            let run = try XCTUnwrap(persistedRuns.first)
            XCTAssertEqual(
                run.pendingPresentationPublication?.invocationId,
                "restart-publication"
            )
            guard case .string(let response)? =
                run.context.responses["plan"] else {
                return XCTFail("Expected the staged response to survive capture failure")
            }
            XCTAssertEqual(response, "yearly")
            XCTAssertFalse(events.routedEvents.contains {
                $0.name == "button_tapped"
            })
        }

        let recoveryIdentity = MockIdentityService()
        recoveryIdentity.setDistinctId("customer")
        let recoveryEvents = MockEventLog()
        recoveryEvents.identity = recoveryIdentity
        let recoveryService = makeService(
            identity: recoveryIdentity,
            events: recoveryEvents,
            directory: directory
        )

        await recoveryService.initialize()

        let replayed = recoveryEvents.routedEvents.filter {
            $0.name == "button_tapped"
        }
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(
            replayed.first?.id,
            "00000000-0000-7000-8000-000000000338"
        )
        let completion = try XCTUnwrap(recoveryEvents.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(completion.properties["outcome"] as? String, "abandoned")
        let outputs = try XCTUnwrap(
            completion.properties["outputs"] as? [String: Any]
        )
        let responses = try XCTUnwrap(outputs["responses"] as? [String: Any])
        XCTAssertEqual(responses["plan"] as? String, "yearly")
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let remainingRuns = try await journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
        await recoveryService.shutdown()
    }

    func testRendererBatchRemainsRejectedWhenPublicationCannotStage() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            inputs: .init(
                eventFields: [],
                responseFields: [[
                    "key": .string("plan"),
                    "type": .string("string"),
                    "required": .bool(false),
                ]]
            ),
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["plan"]
            )]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let beforeSendCalls = DeviceLegBeforeSendCallRecorder()
        events.preparedTriggerBeforeSend = { event in
            if event.id == "00000000-0000-7000-8000-000000000340" {
                beforeSendCalls.record()
            }
            return event
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let persistenceFailures = DeviceLegJournalPersistenceFailures()
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter,
            journalBeforePersist: { try persistenceFailures.beforePersist() }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        // The outbox record owns the response and stable event IDs together.
        // If that write fails, the renderer keeps the batch and no event may
        // become visible.
        persistenceFailures.failNext(1)

        let batch = presentationBatch(
            request: request,
            invocationId: "response-abandonment-rejected",
            emissions: [
                .init(
                    id: "00000000-0000-7000-8000-000000000339",
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00.120Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("yearly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000340",
                    sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.121Z",
                    name: "button_tapped",
                    payload: [:]
                ),
            ]
        )
        let accepted = await request.onEmissionBatch(batch)

        XCTAssertFalse(accepted)
        let persistedRuns = try await journal.runs()
        let run = try XCTUnwrap(persistedRuns.first)
        XCTAssertNil(run.completion)
        XCTAssertNil(run.context.responses["plan"])
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let finishedOwners = await MainActor.run { presenter.finishedOwners }
        XCTAssertTrue(finishedOwners.isEmpty)

        let retryAccepted = await request.onEmissionBatch(batch)
        XCTAssertTrue(retryAccepted)
        XCTAssertEqual(
            beforeSendCalls.callCount,
            1,
            "beforeSend must run only after the outbox owns the batch"
        )
        let runsAfterRetry = try await journal.runs()
        let persistedAfterRetry = try XCTUnwrap(runsAfterRetry.first)
        guard case .string(let response)? =
            persistedAfterRetry.context.responses["plan"] else {
            return XCTFail("Expected the retried response to be durable")
        }
        XCTAssertEqual(response, "yearly")
        XCTAssertNil(persistedAfterRetry.pendingPresentationPublication)
    }

    func testBeforeSendDroppedRenderedEventDoesNotAdvanceItsScreenRoute() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            event.name == "continue" ? nil : event
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let initialRuns = try await journal.runs()
        let initialRun = try XCTUnwrap(initialRuns.first)

        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "dropped-screen-route",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000323",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        XCTAssertFalse(events.routedEvents.contains { $0.name == "continue" })
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        let currentRuns = try await journal.runs()
        let currentRun = try XCTUnwrap(currentRuns.first)
        XCTAssertEqual(currentRun.stepId, initialRun.stepId)
        XCTAssertNil(currentRun.completion)
        let finishedOwners = await MainActor.run { presenter.finishedOwners }
        XCTAssertTrue(finishedOwners.isEmpty)
    }

    func testBeforeSendRenameAwayFromRenderedRouteDoesNotAdvance() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            guard event.name == "continue" else { return event }
            return NuxieEvent(
                id: event.id,
                name: "continue_redacted",
                distinctId: event.distinctId,
                properties: event.properties,
                timestamp: event.timestamp
            )
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "renamed-away-screen-route",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000324",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        XCTAssertTrue(events.routedEvents.contains {
            $0.name == "continue_redacted"
        })
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        let run = try XCTUnwrap(runs.first)
        XCTAssertNil(run.completion)
    }

    func testBeforeSendRenameIntoRenderedRouteAdvances() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            guard event.name == "primary_tapped" else { return event }
            return NuxieEvent(
                id: event.id,
                name: "continue",
                distinctId: event.distinctId,
                properties: event.properties,
                timestamp: event.timestamp
            )
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completed = expectation(description: "renamed route completed")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completed.fulfill()
        }
        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "renamed-into-screen-route",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000325",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "primary_tapped",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(events.routedEvents.contains { $0.name == "continue" })
    }

    func testBeforeSendRenderedPropertyRewriteDrivesRoutedControl() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = renderedEventPropertyBranchSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            eventName: "continue"
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            guard event.name == "continue" else { return event }
            var properties = event.properties
            properties["allow"] = true
            return NuxieEvent(
                id: event.id,
                name: event.name,
                distinctId: event.distinctId,
                properties: properties,
                timestamp: event.timestamp
            )
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completed = expectation(description: "transformed event completed")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completed.fulfill()
        }

        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "transformed-event-properties",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000326",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00.123Z",
                name: "continue",
                payload: ["allow": .bool(false)]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [completed], timeout: 2)
        let routed = try XCTUnwrap(events.routedEvents.first {
            $0.name == "continue"
        })
        XCTAssertEqual(routed.properties["allow"] as? Bool, true)
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "transformed"
        )
    }

    func testRenderedBatchDurablyStagesResponsesBeforePublishingAllEventsAndUsesFirstRoute() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let responseField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("plan"),
            "type": .string("string"),
            "required": .bool(false),
        ]
        let snapshot = replacing(
            base,
            inputs: .init(eventFields: [], responseFields: [responseField]),
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "show_details",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_details"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "show_details"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: ["plan"]
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let persistence = DeviceLegResponsePersistenceProbe()
        events.prepareTriggerPropertiesHandler = {
            let runs = try? await journal.runs()
            let durableResponse: String?
            if let run = runs?.first,
               case .string(let value)? = run.context.responses["plan"] {
                durableResponse = value
            } else {
                durableResponse = nil
            }
            await persistence.record(durableResponse)
        }

        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "response-route-invocation",
            source: .init(
                screenId: "screen_welcome",
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [
                .init(
                    id: "00000000-0000-7000-8000-000000000331",
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00.120Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("yearly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000332",
                    sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.121Z",
                    name: "before_route",
                    payload: [:]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000333",
                    sequence: 2,
                    occurredAt: "2026-08-29T12:00:00.122Z",
                    name: "continue",
                    payload: [:]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000334",
                    sequence: 3,
                    occurredAt: "2026-08-29T12:00:00.123Z",
                    name: "tail_event",
                    payload: [:]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000335",
                    sequence: 4,
                    occurredAt: "2026-08-29T12:00:00.124Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("plan"),
                        "value": .string("monthly"),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000336",
                    sequence: 5,
                    occurredAt: "2026-08-29T12:00:00.125Z",
                    name: "continue",
                    payload: [:]
                ),
            ]
        ))
        events.prepareTriggerPropertiesHandler = nil

        XCTAssertTrue(accepted)
        let persistenceObservations = await persistence.observations()
        XCTAssertEqual(persistenceObservations, [
            "monthly",
            "monthly",
            "monthly",
            "monthly",
        ])
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            "before_route",
            "continue",
            "tail_event",
            "continue",
        ])
        let runs = try await journal.runs()
        let run = try XCTUnwrap(runs.first)
        guard case .string(let response)? = run.context.responses["plan"] else {
            return XCTFail("Expected the response to remain durable")
        }
        XCTAssertEqual(response, "monthly")
    }

    func testRenderedScreenLifecycleEventsAreDurablyRoutedWithJourneyAttribution() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)

        _ = await request.onScreenChanged("screen_welcome")
        _ = await request.onScreenDismissed(
            "screen_welcome",
            "screen_details",
            "navigate"
        )

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            SystemEventNames.screenShown,
            SystemEventNames.screenDismissed,
        ])
        let shown = try XCTUnwrap(events.routedEvents.first {
            $0.name == SystemEventNames.screenShown
        })
        XCTAssertEqual(shown.properties["screen_id"] as? String, "screen_welcome")
        XCTAssertEqual(shown.properties["journey_id"] as? String, request.owner.journeyId)
        XCTAssertEqual(shown.properties["experience_version"] as? String, "version_golden")
        XCTAssertNil(shown.properties["experience_version_id"])
        XCTAssertEqual(shown.properties["leg_generation"] as? Int, 0)
        let dismissed = try XCTUnwrap(events.routedEvents.first {
            $0.name == SystemEventNames.screenDismissed
        })
        XCTAssertEqual(dismissed.properties["screen_id"] as? String, "screen_welcome")
        XCTAssertEqual(dismissed.properties["method"] as? String, "navigate")
        XCTAssertEqual(
            dismissed.properties["revealing_screen_id"] as? String,
            "screen_details"
        )
        XCTAssertEqual(dismissed.properties["journey_id"] as? String, request.owner.journeyId)
        XCTAssertEqual(
            dismissed.properties["experience_version"] as? String,
            "version_golden"
        )
    }

    func testTerminalScreenDismissalCompletesWithoutReenteringPresentationTeardown() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedDismissalCompletionSnapshot(base)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)

        let result = await request.onScreenDismissed(
            "screen_welcome",
            nil,
            "host"
        )

        XCTAssertEqual(result, .completed)
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "screen_dismissed"
        )
        let finishedOwners = await MainActor.run { presenter.finishedOwners }
        XCTAssertTrue(finishedOwners.isEmpty)
    }

    func testBeforeSendDroppedScreenDismissalFallsBackWithoutAdvancingItsRoute() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedDismissalCompletionSnapshot(base)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            event.name == SystemEventNames.screenDismissed ? nil : event
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)

        let result = await request.onScreenDismissed(
            "screen_welcome",
            nil,
            "user"
        )

        XCTAssertEqual(result, .completed)
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == SystemEventNames.screenDismissed
        })
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "host_dismissed"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
        let finishedOwners = await MainActor.run { presenter.finishedOwners }
        XCTAssertTrue(finishedOwners.isEmpty)
    }

    func testBeforeSendRenameAwayFromScreenDismissalRouteUsesFallback() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedDismissalCompletionSnapshot(base)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            guard event.name == SystemEventNames.screenDismissed else { return event }
            return NuxieEvent(
                id: event.id,
                name: "screen_dismissed_redacted",
                distinctId: event.distinctId,
                properties: event.properties,
                timestamp: event.timestamp
            )
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)

        let result = await request.onScreenDismissed(
            "screen_welcome",
            nil,
            "user"
        )

        XCTAssertEqual(result, .completed)
        XCTAssertTrue(events.routedEvents.contains {
            $0.name == "screen_dismissed_redacted"
        })
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "host_dismissed"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
    }

    func testBeforeSendRenameIntoScreenDismissalRouteAdvances() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedDismissalCompletionSnapshot(
            base,
            eventName: "screen_dismissed_routed"
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            guard event.name == SystemEventNames.screenDismissed else { return event }
            return NuxieEvent(
                id: event.id,
                name: "screen_dismissed_routed",
                distinctId: event.distinctId,
                properties: event.properties,
                timestamp: event.timestamp
            )
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)

        let result = await request.onScreenDismissed(
            "screen_welcome",
            nil,
            "host"
        )

        XCTAssertEqual(result, .completed)
        XCTAssertTrue(events.routedEvents.contains {
            $0.name == "screen_dismissed_routed"
        })
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "screen_dismissed"
        )
    }

    func testBeforeSendLifecyclePropertyRewriteDrivesRoutedControl() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = renderedEventPropertyBranchSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            eventName: SystemEventNames.screenDismissed
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            guard event.name == SystemEventNames.screenDismissed else {
                return event
            }
            var properties = event.properties
            properties["allow"] = true
            return NuxieEvent(
                id: event.id,
                name: event.name,
                distinctId: event.distinctId,
                properties: properties,
                timestamp: event.timestamp
            )
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)

        let result = await request.onScreenDismissed(
            "screen_welcome",
            nil,
            "user"
        )

        XCTAssertEqual(result, .completed)
        let routed = try XCTUnwrap(events.routedEvents.first {
            $0.name == SystemEventNames.screenDismissed
        })
        XCTAssertEqual(routed.properties["allow"] as? Bool, true)
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "transformed"
        )
    }

    func testRuntimeDelegateProvidesIntroEligibilityAuthorizationForItsOwner() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-authority",
                distinctId: "customer-authority"
            ),
            reservation: nil,
            onEmissionBatch: { _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let provider = delegate as any IntroEligibilityAuthorizationContextProviding

        XCTAssertEqual(
            provider.introEligibilityAuthorizationContext,
            IntroEligibilityAuthorizationContext(
                distinctId: "customer-authority",
                journeyId: "journey-authority"
            )
        )
    }

    func testRuntimeDelegateReportsInitialRevealAndLaterVisibleScreenChanges() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let reveals = DeviceLegRevealRecorder()
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-reveal",
                distinctId: "customer-reveal"
            ),
            reservation: nil,
            onScreenChanged: { _ in true },
            onEmissionBatch: { _ in true },
            onPresentationRevealed: {
                await reveals.record()
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        let revealsBeforePresentation = await reveals.count()
        XCTAssertEqual(revealsBeforePresentation, 0)

        await delegate.experienceViewControllerDidReveal(controller)
        for _ in 0..<100 {
            if await reveals.count() == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let revealsAfterPresentation = await reveals.count()
        XCTAssertEqual(revealsAfterPresentation, 1)

        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: "screen_details",
            method: "navigate"
        )
        let revealsAfterSourceDismissal = await reveals.count()
        XCTAssertEqual(revealsAfterSourceDismissal, 1)

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )
        let revealsAfterNavigation = await reveals.count()
        XCTAssertEqual(revealsAfterNavigation, 2)

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )
        let revealsAfterRepeatedCallback = await reveals.count()
        XCTAssertEqual(revealsAfterRepeatedCallback, 2)
    }

    func testRuntimeDelegateJoinsInitialRevealCallback() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = DeviceLegScreenCommitGate()
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-reveal-join",
                distinctId: "customer-reveal-join"
            ),
            reservation: nil,
            onEmissionBatch: { _ in true },
            onPresentationRevealed: {
                await gate.suspend()
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let completion = DeviceLegCompletionFlag()

        let reveal = Task {
            await delegate.experienceViewControllerDidReveal(controller)
            completion.finish()
        }
        await gate.waitUntilEntered()

        XCTAssertFalse(completion.isCompleted)
        await gate.release()
        await reveal.value
        XCTAssertTrue(completion.isCompleted)
    }

    func testRuntimeDelegateResolvesDynamicPurchasePlacementFromActiveScreenState() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            viewModelValues: [
                [
                    "viewModelName": .string("WelcomeModel"),
                    "instanceId": .string("welcome"),
                    "path": .string("product"),
                    "value": .object([
                        "placementId": .string("golden:yearly")
                    ]),
                ],
                [
                    "viewModelName": .string("WelcomeModel"),
                    "instanceId": .string("secondary"),
                    "path": .string("product"),
                    "value": .object([
                        "placementId": .string("golden:secondary")
                    ]),
                ],
            ]
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onEmissionBatch: { _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let placementReference = ExperienceReleaseJSONValue.object([
            "ref": .object([
                "kind": .string("path"),
                "path": .string("product.placementId"),
            ])
        ])

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        let initialPlacement = await delegate.resolvePresentationString(
            placementReference
        )
        await delegate.experienceViewController(
            controller,
            didEmitViewModelChange: ExperienceRendererViewModelChange(
                path: VmPathRef(path: "product.placementId"),
                value: "golden:monthly",
                source: "runtime",
                screenId: "screen_welcome",
                instanceId: "welcome",
                isTrigger: false
            )
        )
        let changedPlacement = await delegate.resolvePresentationString(
            placementReference
        )
        let secondaryPlacement = await delegate.resolvePresentationString(
            placementReference,
            source: ScreenEmissionSource(
                screenId: "screen_welcome",
                actionId: "purchase-secondary",
                componentId: "secondary-button",
                instanceId: "secondary"
            )
        )

        XCTAssertEqual(initialPlacement, "golden:yearly")
        XCTAssertEqual(changedPlacement, "golden:monthly")
        XCTAssertEqual(secondaryPlacement, "golden:secondary")
    }

    func testRuntimeDelegateForwardsRendererOpenLinksFromTheActiveScreen() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onEmissionBatch: { _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewController(
            controller,
            didRequestOpenLink: ExperienceRendererOpenLinkRequest(
                urlString: "https://example.com/account",
                target: "in_app",
                screenId: "screen_welcome",
                instanceId: "secondary"
            )
        )
        await delegate.experienceViewController(
            controller,
            didRequestOpenLink: ExperienceRendererOpenLinkRequest(
                urlString: "https://example.com/stale",
                target: "external",
                screenId: "screen_details",
                instanceId: nil
            )
        )

        let links = await MainActor.run { controller.performedOpenLinks }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.urlString, "https://example.com/account")
        XCTAssertEqual(links.first?.target, "in_app")
    }

    func testRuntimeDelegateRoutesPermissionResultsWithTheCapturedOwnerAfterDismissal() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let hostDismissed = await delegate
            .experienceViewControllerDidRequestHostDismiss(controller)
        XCTAssertTrue(hostDismissed)

        let captured = expectation(description: "permission events captured")
        captured.expectedFulfillmentCount = 4
        let expectedNames: Set<String> = [
            SystemEventNames.notificationsEnabled,
            SystemEventNames.permissionGranted,
            SystemEventNames.trackingAuthorized,
            SystemEventNames.permissionDenied,
        ]
        events.addEventHandler(pattern: "*") { event in
            if expectedNames.contains(event.name) {
                captured.fulfill()
            }
        }

        await MainActor.run {
            delegate.experienceViewController(
                controller,
                didResolveNotificationPermissionEvent:
                    SystemEventNames.notificationsEnabled,
                properties: ["journey_id": "spoofed"],
                journeyId: request.owner.journeyId
            )
            delegate.experienceViewController(
                controller,
                didResolveRequestPermissionEvent:
                    SystemEventNames.permissionGranted,
                properties: ["type": "camera"],
                journeyId: request.owner.journeyId
            )
            delegate.experienceViewController(
                controller,
                didResolveTrackingPermissionEvent:
                    SystemEventNames.trackingAuthorized,
                properties: [:],
                journeyId: request.owner.journeyId
            )
            delegate.experienceViewController(
                controller,
                didIgnoreUnsupportedRequestPermissionType: "unsupported-sensor",
                journeyId: request.owner.journeyId
            )
        }
        await fulfillment(of: [captured], timeout: 2)

        let permissionEvents = events.routedEvents.filter {
            expectedNames.contains($0.name)
        }
        XCTAssertEqual(permissionEvents.count, 4)
        for event in permissionEvents {
            XCTAssertEqual(event.distinctId, "customer")
            XCTAssertEqual(event.properties["journey_id"] as? String, request.owner.journeyId)
            XCTAssertEqual(event.properties["experience_id"] as? String, "experience_golden")
            XCTAssertEqual(event.properties["experience_version"] as? String, "version_golden")
        }
        let unsupported = try XCTUnwrap(permissionEvents.first {
            $0.name == SystemEventNames.permissionDenied
        })
        XCTAssertEqual(unsupported.properties["type"] as? String, "unsupported-sensor")

        let misattributed = expectation(
            description: "departing-owner permission is not reassigned"
        )
        misattributed.isInverted = true
        events.addEventHandler(pattern: SystemEventNames.trackingDenied) { _ in
            misattributed.fulfill()
        }
        identity.setDistinctId("other-customer")
        identity.setDistinctId("customer")
        await MainActor.run {
            delegate.experienceViewController(
                controller,
                didResolveTrackingPermissionEvent:
                    SystemEventNames.trackingDenied,
                properties: [:],
                journeyId: request.owner.journeyId
            )
        }
        await fulfillment(of: [misattributed], timeout: 0.2)
    }

    func testRuntimeDelegatePreservesForwardNavigationForAuthoredBack() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onEmissionBatch: { _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: "screen_details",
            method: "navigate"
        )
        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )

        let backTarget = await MainActor.run {
            delegate.prepareBackNavigation(steps: 1)
        }
        XCTAssertEqual(backTarget, "screen_welcome")
    }

    func testRuntimeDelegateGivesHostDismissalPrecedenceOverTopLevelScreenDismissal() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let screenDismissals = DeviceLegOutcomeCallRecorder()
        let outcomes = DeviceLegOutcomeCallRecorder()
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenDismissed: { screenId, _, _ in
                await screenDismissals.record(
                    outcome: .dismissed,
                    screenId: screenId
                )
                return .completed
            },
            onEmissionBatch: { _ in true },
            onOutcome: { outcome, screenId in
                await outcomes.record(outcome: outcome, screenId: screenId)
                return true
            }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewControllerWillRequestHostDismiss(controller)
        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: nil,
            method: "host"
        )

        let screenDismissalCount = await screenDismissals.count()
        XCTAssertEqual(screenDismissalCount, 0)
        let accepted = await delegate
            .experienceViewControllerDidRequestHostDismiss(controller)
        XCTAssertTrue(accepted)
        let hostOutcome = await outcomes.onlyCall()
        XCTAssertEqual(hostOutcome?.outcome, .dismissed)
        XCTAssertEqual(hostOutcome?.screenId, "screen_welcome")
    }

    func testRuntimeDelegateCoalescesConcurrentSurfaceResolution() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = DeviceLegScreenCommitGate()
        let calls = DeviceLegOutcomeCallRecorder()
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onEmissionBatch: { _ in true },
            onOutcome: { outcome, screenId in
                await calls.record(outcome: outcome, screenId: screenId)
                await gate.suspend()
                return true
            }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let firstHostDismissal = Task { @MainActor in
            await delegate.experienceViewControllerDidRequestHostDismiss(controller)
        }

        await gate.waitUntilEntered()
        let secondHostDismissal = Task { @MainActor in
            await delegate.experienceViewControllerDidRequestHostDismiss(controller)
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        let callsBeforeRelease = await calls.count()
        XCTAssertEqual(callsBeforeRelease, 1)

        await gate.release()
        let firstAccepted = await firstHostDismissal.value
        let secondAccepted = await secondHostDismissal.value
        let finalCallCount = await calls.count()

        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        XCTAssertEqual(finalCallCount, 1)
    }

    func testRuntimeDelegateAcknowledgesOrdinaryCloseWithoutHostOutcome() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let screenDismissals = DeviceLegOutcomeCallRecorder()
        let outcomes = DeviceLegOutcomeCallRecorder()
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenDismissed: { screenId, _, _ in
                await screenDismissals.record(
                    outcome: .dismissed,
                    screenId: screenId
                )
                return .handled
            },
            onEmissionBatch: { _ in true },
            onOutcome: { outcome, screenId in
                await outcomes.record(outcome: outcome, screenId: screenId)
                return true
            }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        await delegate.experienceViewController(
            controller,
            didDismissScreen: "screen_welcome",
            revealingScreenId: nil,
            method: "user"
        )
        let accepted = await delegate.experienceViewControllerDidRequestDismiss(
            controller,
            reason: .userDismissed
        )

        XCTAssertTrue(accepted)
        let screenDismissalCount = await screenDismissals.count()
        let outcomeCount = await outcomes.count()
        XCTAssertEqual(screenDismissalCount, 1)
        XCTAssertEqual(outcomeCount, 0)
    }

    func testRuntimeDelegateEnablesScreenEmissionsOnlyAfterLifecycleCommit() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = DeviceLegScreenCommitGate()
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenChanged: { _ in
                await gate.suspend()
                return true
            },
            onEmissionBatch: { _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let activation = Task { @MainActor in
            await delegate.experienceViewController(
                controller,
                didChangeScreen: "screen_welcome"
            )
        }

        await gate.waitUntilEntered()
        let scopeBeforeCommit = await MainActor.run {
            controller.captureScreenEmissionRun()
        }
        XCTAssertNil(scopeBeforeCommit)

        await gate.release()
        await activation.value

        let scopeAfterCommit = await MainActor.run {
            controller.captureScreenEmissionRun()
        }
        XCTAssertEqual(scopeAfterCommit?.journeyId, "journey")
        XCTAssertEqual(scopeAfterCommit?.presentationEpoch, 1)
    }

    func testRuntimeDelegateRejectsABatchFromAnEarlierVisitToTheSameScreen() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let recorder = DeviceLegEmissionBatchRecorder()
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenChanged: { _ in true },
            onEmissionBatch: { batch in
                await recorder.accept(batch)
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )
        let staleBatch = presentationBatch(
            request: request,
            presentationEpoch: 1,
            invocationId: "stale-return",
            emissions: []
        )
        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_details"
        )
        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )

        let staleAccepted = await delegate.experienceViewController(
            controller,
            didEmitScreenEmissionBatch: staleBatch
        )
        let currentAccepted = await delegate.experienceViewController(
            controller,
            didEmitScreenEmissionBatch: presentationBatch(
                request: request,
                presentationEpoch: 3,
                invocationId: "current-return",
                emissions: []
            )
        )

        XCTAssertFalse(staleAccepted)
        XCTAssertTrue(currentAccepted)
        let invocationIds = await recorder.invocationIds()
        XCTAssertEqual(invocationIds, ["current-return"])
    }

    func testRuntimeDelegateClosesSurfaceWhenInitialLifecycleCommitIsRejected() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onScreenChanged: { _ in false },
            onEmissionBatch: { _ in true },
            onOutcome: { outcome, _ in outcome == .abandoned }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didChangeScreen: "screen_welcome"
        )

        let reasons = await MainActor.run { controller.performDismissReasons }
        XCTAssertEqual(reasons.count, 1)
        guard case .error(ExperienceError.invalidManifest)? = reasons.first else {
            return XCTFail("Expected invalid-manifest dismissal")
        }
    }

    func testRuntimeDelegateClosesSurfaceWhenProductFailureCannotBeCommitted() async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = DeviceLegPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey",
                distinctId: "customer"
            ),
            reservation: nil,
            onProductsUnavailable: { _ in .rejected },
            onEmissionBatch: { _ in true },
            onOutcome: { outcome, _ in outcome == .abandoned }
        )
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didFailToResolveProductsFor: "screen_welcome"
        )

        let reasons = await MainActor.run { controller.performDismissReasons }
        XCTAssertEqual(reasons.count, 1)
        guard case .error(ExperienceError.productsUnavailable)? = reasons.first else {
            return XCTFail("Expected products-unavailable dismissal")
        }
    }

    func testProductResolutionFailureRoutesThroughTheRuntimeDelegateAndCompletes() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completionCommitted = expectation(description: "product failure completed")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        let delegate = await MainActor.run {
            DeviceLegRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }

        await delegate.experienceViewController(
            controller,
            didFailToResolveProductsFor: "screen_welcome"
        )
        await fulfillment(of: [completionCommitted], timeout: 2)

        let dismissalReasons = await MainActor.run {
            controller.performDismissReasons
        }
        let finishedOwners = await MainActor.run {
            presenter.finishedOwners
        }
        XCTAssertEqual(dismissalReasons.count, 1)
        if let reason = dismissalReasons.first, case .error = reason {
            // Expected: teardown is queued only after the product callback
            // returns to the navigation drain.
        } else {
            XCTFail("Expected product failure to request error dismissal")
        }
        XCTAssertTrue(finishedOwners.isEmpty)

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            SystemEventNames.productsUnavailable,
            JourneyEvents.journeyLegCompleted,
        ])
        let unavailable = try XCTUnwrap(events.routedEvents.first {
            $0.name == SystemEventNames.productsUnavailable
        })
        XCTAssertEqual(
            Set(unavailable.properties["product_ids"] as? [String] ?? []),
            ["monthly", "yearly"]
        )
        XCTAssertEqual(
            unavailable.properties["experience_version"] as? String,
            "version_golden"
        )
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "products_unavailable"
        )
    }

    func testRenderedProductBoundScreenResolvesItsAuthenticatedStoreKitPlacements() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            viewModelValues: [[
                "viewModelName": .string("WelcomeModel"),
                "instanceId": .string("welcome"),
                "path": .string("products"),
                "value": .array([
                    .object(["placementId": .string("golden:monthly")]),
                    .object(["placementId": .string("golden:yearly")]),
                ]),
            ]]
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let productService = MockProductService()
        productService.mockProducts = [
            MockStoreProduct(
                id: "monthly",
                displayName: "Monthly",
                price: 9.99,
                displayPrice: "$9.99",
                productType: .autoRenewable
            ),
            MockStoreProduct(
                id: "yearly",
                displayName: "Yearly",
                price: 79.99,
                displayPrice: "$79.99",
                productType: .autoRenewable
            ),
        ]
        let releaseStore = ExperienceReleaseAcquisitionStore(
            cacheDirectory: directory,
            authorizationKeys: [],
            supportedRuntime: ExperienceReleaseRuntime.current,
            admission: ExperienceReleaseAdmission(
                store: InMemoryExperienceReleaseHighWaterStore()
            )
        )
        let loader = ExperienceLoader(
            productService: productService,
            releaseStore: releaseStore,
            warmLoadsInitiallySuspended: true
        )

        let products = try await loader.productsForDeviceLegPresentation(
            release: release,
            screenID: "screen_welcome"
        )

        XCTAssertEqual(productService.requestedProductIds, ["monthly", "yearly"])
        XCTAssertEqual(Set(products.map(\.productId)), ["monthly", "yearly"])
        XCTAssertEqual(
            Set(products.map(\.placementId)),
            ["golden:monthly", "golden:yearly"]
        )
    }

    func testCanonicalProfileRegistersDeviceJourneyProductsForRecovery() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = try replacingWithHeadlessArtifacts(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let loader = ExperienceLoader(
            productService: ProductService(),
            releaseStore: ExperienceReleaseAcquisitionStore(
                cacheDirectory: directory,
                authorizationKeys: [],
                supportedRuntime: ExperienceReleaseRuntime.current,
                admission: ExperienceReleaseAdmission(
                    store: InMemoryExperienceReleaseHighWaterStore()
                )
            ),
            warmLoadsInitiallySuspended: true
        )

        let preparedProfile = try await loader.prepareReleaseProfile(
            nil,
            deviceLegSnapshot: snapshot
        )
        let admitted = try await loader.commitReleaseProfile(
            preparedProfile,
            generation: 1
        )
        XCTAssertNotNil(admitted)
        let activeAuthority = await loader.purchaseEvidenceAuthority(
            storeProductId: "monthly"
        )
        XCTAssertEqual(
            activeAuthority,
            .nativeStoreKit
        )
        let exactAllowances = await loader.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: release.descriptorSHA256,
            productId: "monthly",
            storeProductId: "monthly"
        )
        XCTAssertEqual(
            exactAllowances,
            []
        )

        _ = try await loader.commitReleaseProfile(
            PreparedExperienceReleaseProfile(profile: nil, catalog: nil),
            generation: 2
        )
        let clearedAuthority = await loader.purchaseEvidenceAuthority(
            storeProductId: "monthly"
        )
        XCTAssertEqual(
            clearedAuthority,
            .readyNoMatch
        )
        let clearedAllowances = await loader.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: release.descriptorSHA256,
            productId: "monthly",
            storeProductId: "monthly"
        )
        XCTAssertNil(clearedAllowances)
    }

    func testSupersededProfileDoesNotPublishDeviceJourneyProductAuthority() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = try replacingWithHeadlessArtifacts(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let loader = ExperienceLoader(
            productService: ProductService(),
            releaseStore: ExperienceReleaseAcquisitionStore(
                cacheDirectory: directory,
                authorizationKeys: [],
                supportedRuntime: ExperienceReleaseRuntime.current,
                admission: ExperienceReleaseAdmission(
                    store: InMemoryExperienceReleaseHighWaterStore()
                )
            ),
            warmLoadsInitiallySuspended: true
        )
        let admission = SupersedingProfileAdmission()

        let preparedProfile = try await loader.prepareReleaseProfile(
            nil,
            deviceLegSnapshot: snapshot
        )
        let committed = try await loader.commitReleaseProfile(
            preparedProfile,
            generation: 1,
            admission: ProfileSideEffectAdmission {
                admission.isCurrent()
            }
        )

        XCTAssertNil(committed)
        XCTAssertEqual(admission.readCount, 2)
        let authority = await loader.purchaseEvidenceAuthority(
            storeProductId: "monthly"
        )
        XCTAssertEqual(authority, .unavailable)
        let allowances = await loader.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: release.descriptorSHA256,
            productId: "monthly",
            storeProductId: "monthly"
        )
        XCTAssertNil(allowances)
    }

    func testRenderedScreenDoesNotLoadPurchasesReachableOnlyFromAnotherScreen() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "buy_monthly",
                    action: [
                        "type": .string("purchase"),
                        "placementId": .object([
                            "literal": .string("golden:monthly")
                        ]),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "buy_yearly",
                    action: [
                        "type": .string("purchase"),
                        "placementId": .object([
                            "literal": .string("golden:yearly")
                        ]),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: "buy",
                    entryStepId: "buy_monthly"
                ),
                .init(
                    host: .init(kind: .screen, screenId: "screen_details"),
                    eventName: "buy",
                    entryStepId: "buy_yearly"
                ),
            ],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ],
            viewModelValues: [[
                "viewModelName": .string("WelcomeModel"),
                "instanceId": .string("welcome"),
                "path": .string("product"),
                "value": .object([
                    "placementId": .string("golden:monthly")
                ]),
            ]]
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let productService = MockProductService()
        productService.mockProducts = [MockStoreProduct(
            id: "monthly",
            displayName: "Monthly",
            price: 9.99,
            displayPrice: "$9.99",
            productType: .autoRenewable
        )]
        let loader = ExperienceLoader(
            productService: productService,
            releaseStore: ExperienceReleaseAcquisitionStore(
                cacheDirectory: directory,
                authorizationKeys: [],
                supportedRuntime: ExperienceReleaseRuntime.current,
                admission: ExperienceReleaseAdmission(
                    store: InMemoryExperienceReleaseHighWaterStore()
                )
            ),
            warmLoadsInitiallySuspended: true
        )

        let products = try await loader.productsForDeviceLegPresentation(
            release: release,
            screenID: "screen_welcome"
        )

        XCTAssertEqual(productService.requestedProductIds, ["monthly"])
        XCTAssertEqual(products.map(\.productId), ["monthly"])
        XCTAssertEqual(products.map(\.placementId), ["golden:monthly"])
    }

    func testCanonicalProfileAcquiresRenderedArtifactsBeforePublishingAuthority() async throws {
        let directory = temporaryDirectory()
        defer {
            StubURLProtocol.reset()
            removeTemporaryDirectoryIfPresent(directory)
        }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let sceneBytes = Data("offline-ready-device-leg-scene".utf8)
        let snapshot = try replacingRenderedArtifact(
            try await authenticatedRenderedSnapshot(fixture),
            sceneBytes: sceneBytes
        )
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let requests = DeviceLegArtifactRequestCounter()
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests.increment()
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": String(sceneBytes.count),
                        "Content-Type": "application/vnd.rive",
                    ]
                )!,
                sceneBytes
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let store = ExperienceReleaseAcquisitionStore(
            cacheDirectory: directory,
            urlSession: URLSession(configuration: configuration),
            authorizationKeys: [],
            supportedRuntime: ExperienceReleaseRuntime.current,
            admission: ExperienceReleaseAdmission(
                store: InMemoryExperienceReleaseHighWaterStore()
            )
        )
        let loader = ExperienceLoader(
            productService: ProductService(),
            releaseStore: store,
            warmLoadsInitiallySuspended: true
        )

        let preparedProfile = try await loader.prepareReleaseProfile(
            nil,
            deviceLegSnapshot: snapshot
        )
        XCTAssertEqual(requests.value, 1)
        let committed = try await loader.commitReleaseProfile(
            preparedProfile,
            generation: 1
        )
        XCTAssertNotNil(committed)

        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: { _ in true }) { _ in
            requests.increment()
            throw URLError(.notConnectedToInternet)
        }
        let preparedPresentation = try await store.preparePresentation(
            release: release,
            delivery: snapshot.profile.delivery,
            productResolver: { _ in [] }
        )
        let artifact = try await preparedPresentation.artifactLoader(
            preparedPresentation.experience,
            nil,
            "screen_welcome"
        )

        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(artifact.sceneBytes, sceneBytes)
    }

    func testLiveRunRetainsRenderedArtifactsAcrossProfileReplacementAndRelaunch() async throws {
        let root = temporaryDirectory()
        let cacheDirectory = root.appendingPathComponent("cache")
        let journalDirectory = root.appendingPathComponent("journal")
        defer {
            StubURLProtocol.reset()
            removeTemporaryDirectoryIfPresent(root)
        }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let sceneBytes = Data("durably-pinned-device-leg-scene".utf8)
        let snapshot = try replacingRenderedArtifact(
            try await authenticatedRenderedSnapshot(fixture),
            sceneBytes: sceneBytes
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let requests = DeviceLegArtifactRequestCounter()
        StubURLProtocol.register(matcher: { _ in true }) { request in
            requests.increment()
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": String(sceneBytes.count),
                        "Content-Type": "application/vnd.rive",
                    ]
                )!,
                sceneBytes
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let store = ExperienceReleaseAcquisitionStore(
            cacheDirectory: cacheDirectory,
            urlSession: URLSession(configuration: configuration),
            authorizationKeys: [],
            supportedRuntime: ExperienceReleaseRuntime.current,
            admission: ExperienceReleaseAdmission(
                store: InMemoryExperienceReleaseHighWaterStore()
            )
        )
        let loader = ExperienceLoader(
            productService: ProductService(),
            releaseStore: store,
            warmLoadsInitiallySuspended: true
        )
        var preparedProfile: PreparedExperienceReleaseProfile? =
            try await loader.prepareReleaseProfile(
                nil,
                deviceLegSnapshot: snapshot
            )
        let artifactSource = try XCTUnwrap(
            preparedProfile?.deviceLegArtifacts?.source(
                for: release.descriptorSHA256
            )
        )
        let originalPin = try XCTUnwrap(snapshot.profile.releases.first)
        let releasePin = DeviceLegReleaseProfileEntry(
            locator: originalPin.locator,
            envelope: .init(
                mediaType: originalPin.envelope.mediaType,
                encoding: originalPin.envelope.encoding,
                descriptorSha256: release.descriptorSHA256,
                descriptorSizeBytes: release.exactDescriptorBytes.count,
                descriptorBytesBase64:
                    release.exactDescriptorBytes.base64EncodedString(),
                signature: originalPin.envelope.signature
            )
        )
        let journal = try DeviceLegRunJournal(
            directory: journalDirectory,
            distinctId: "customer"
        )
        let admitted = try await journal.admit(
            arm: arm,
            release: releasePin,
            artifactSource: artifactSource,
            reentry: release.descriptor.leg.reentry,
            entryStepId: release.descriptor.leg.entryStepId,
            at: Date(timeIntervalSince1970: 1_000)
        )
        let run = try XCTUnwrap(admitted)
        preparedProfile = nil
        for object in artifactSource.objects {
            let cached = cacheDirectory.appendingPathComponent(object.sha256)
            if FileManager.default.fileExists(atPath: cached.path) {
                try FileManager.default.removeItem(at: cached)
            }
        }

        StubURLProtocol.reset()
        StubURLProtocol.register(matcher: { _ in true }) { _ in
            requests.increment()
            throw URLError(.notConnectedToInternet)
        }
        let relaunched = try DeviceLegRunJournal(
            directory: journalDirectory,
            distinctId: "customer"
        )
        let retainedArtifacts = try await relaunched.pinnedArtifacts(
            forRunId: run.id
        )
        let pinnedArtifacts = try XCTUnwrap(retainedArtifacts)
        let preparedPresentation = try await store.preparePresentation(
            release: release,
            delivery: snapshot.profile.delivery,
            pinnedArtifacts: pinnedArtifacts,
            productResolver: { _ in [] }
        )
        let artifact = try await preparedPresentation.artifactLoader(
            preparedPresentation.experience,
            nil,
            "screen_welcome"
        )

        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(artifact.sceneBytes, sceneBytes)
    }

    func testRenderedRouteNavigatesWithinTheOwnedSurfaceWithoutPresentingAgain() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedNavigationSnapshot(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let navigated = expectation(description: "owned surface navigated")
        await MainActor.run {
            presenter.onNavigate = { screenId in
                if screenId == "screen_details" {
                    navigated.fulfill()
                }
            }
        }
        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "show-details-invocation",
            source: .init(
                screenId: "screen_welcome",
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000302",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [navigated], timeout: 2)
        let presentationCount = await MainActor.run {
            presenter.presentationRequests.count
        }
        let navigationScreenIds = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(navigationScreenIds, ["screen_welcome", "screen_details"])
    }

    func testSameScreenNavigationSynthesizesScreenShownContinuation() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "show_same_screen",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "done",
                    action: nil,
                    outlets: nil,
                    outcome: "same_screen_complete"
                ),
            ],
            routes: [
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: "continue",
                    entryStepId: "show_same_screen"
                ),
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: SystemEventNames.screenShown,
                    entryStepId: "done"
                ),
            ],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.navigationResult = .alreadyActive
            return value
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completed = expectation(description: "same-screen navigation continued")
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completed.fulfill()
        }

        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "same-screen-navigation",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000303",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [completed], timeout: 2)
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "same_screen_complete"
        )
        let navigationScreenIds = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationScreenIds, ["screen_welcome", "screen_welcome"])
    }

    func testProductUnavailableNavigationLeavesRecoveryToTheRuntimeDelegate() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedNavigationSnapshot(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run {
            presenter.navigationResult = .productsUnavailable
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "products-unavailable-navigation",
            source: .init(
                screenId: "screen_welcome",
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000304",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        for _ in 0..<100 {
            let attempted = await MainActor.run {
                presenter.navigationScreenIds.contains("screen_details")
            }
            if attempted { break }
            await Task.yield()
        }
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        let finishedOwners = await MainActor.run { presenter.finishedOwners }

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.stepId, "show_details")
        XCTAssertNil(runs.first?.completion)
        XCTAssertTrue(finishedOwners.isEmpty)
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.journeyLegCompleted
        })
    }

    func testRenderedNativeActionsBypassTheGenericDispatcher() async throws {
        let fixtures: [(
            type: String,
            action: [String: ExperienceReleaseJSONValue]
        )] = [
            ("back", [
                "type": .string("back"),
                "steps": .number(1),
            ]),
            ("purchase", [
                "type": .string("purchase"),
                "placementId": .object(["literal": .string("golden")]),
            ]),
            ("restore", ["type": .string("restore")]),
            ("request_notifications", [
                "type": .string("request_notifications"),
            ]),
            ("request_permission", [
                "type": .string("request_permission"),
                "permissionType": .string("camera"),
            ]),
            ("request_tracking", [
                "type": .string("request_tracking"),
            ]),
            ("open_link", [
                "type": .string("open_link"),
                "url": .object([
                    "type": .string("String"),
                    "value": .string("https://example.com/account"),
                ]),
                "target": .string("external"),
            ]),
            ("dismiss", [
                "type": .string("dismiss"),
                "reason": .string("completed"),
            ]),
        ]
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)

        for (index, actionFixture) in fixtures.enumerated() {
            let directory = temporaryDirectory()
            defer { removeTemporaryDirectoryIfPresent(directory) }
            let actionStep = DeviceLeg.Step(
                kind: .action,
                id: "native_action",
                action: actionFixture.action,
                outlets: ["next": "done"],
                outcome: nil
            )
            let snapshot = replacing(
                base,
                steps: [
                    .init(
                        kind: .action,
                        id: "present",
                        action: [
                            "type": .string("navigate"),
                            "screenId": .string("screen_welcome"),
                        ],
                        outlets: [:],
                        outcome: nil
                    ),
                    actionStep,
                ],
                routes: [.init(
                    host: .init(
                        kind: .screen,
                        screenId: "screen_welcome"
                    ),
                    eventName: "continue",
                    entryStepId: actionStep.id
                )],
                screens: [.init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                )]
            )
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let dispatcher = InspectingDeviceLegDispatcher(
                directory: directory,
                distinctId: "customer"
            )
            let presenter = await MainActor.run {
                RecordingDeviceLegPresenter()
            }
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                dispatcher: dispatcher,
                presenter: presenter
            )

            await service.initialize()
            await service.profileDidCommit(snapshot, distinctId: "customer")
            let presentedRequest = await MainActor.run { presenter.request }
            let request = try XCTUnwrap(presentedRequest)
            let accepted = await request.onEmissionBatch(presentationBatch(
                request: request,
                invocationId: "native-action-\(index)",
                emissions: [.init(
                    id: String(
                        format: "00000000-0000-7000-8000-%012d",
                        401 + index
                    ),
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00Z",
                    name: "continue",
                    payload: [:]
                )]
            ))

            XCTAssertTrue(accepted, actionFixture.type)
            await waitForPresentationActions(1, presenter: presenter)
            let recordedActions = await MainActor.run {
                presenter.presentationActions
            }
            let recorded = try XCTUnwrap(
                recordedActions.first,
                actionFixture.type
            )
            guard case .string(let recordedType)? = recorded.action["type"] else {
                return XCTFail("Expected a recorded native action type")
            }
            XCTAssertEqual(recordedType, actionFixture.type)
            XCTAssertEqual(recorded.ownerDistinctId, "customer")
            XCTAssertFalse(recorded.effectId.isEmpty)
            if actionFixture.type == "open_link" {
                guard case .string(let recordedURL)? = recorded.action["url"] else {
                    return XCTFail("Expected a resolved open-link URL")
                }
                XCTAssertEqual(recordedURL, "https://example.com/account")
            }
            let genericRequest = await dispatcher.onlyRequest()
            XCTAssertNil(genericRequest, actionFixture.type)
        }
    }

    func testScreenlessPresentationActionIsRejectedBeforeAdmission() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)
        let actionStep = DeviceLeg.Step(
            kind: .action,
            id: "open_link",
            action: [
                "type": .string("open_link"),
                "url": .string("https://example.com/account"),
                "target": .string("external"),
            ],
            outlets: ["next": "done"],
            outcome: nil
        )
        let snapshot = replacing(
            base,
            entryStepId: actionStep.id,
            steps: [actionStep],
            routes: [],
            screens: []
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
        let presentationActions = await MainActor.run {
            presenter.presentationActions
        }
        XCTAssertTrue(presentationActions.isEmpty)
    }

    func testImmediatePermissionResolutionFeedsTheClaimedCursorAfterTransition() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "permission",
                    action: [
                        "type": .string("request_permission"),
                        "permissionType": .string("camera"),
                    ],
                    outlets: ["next": "permission_wait"],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "permission_wait",
                    action: [
                        "type": .string("wait_until"),
                        "trigger": .object([
                            "kind": .string("event"),
                            "eventName": .string(SystemEventNames.permissionGranted),
                        ]),
                        "condition": .object([
                            "type": .string("Truthy"),
                            "value": .object([
                                "type": .string("Boolean"),
                                "value": .bool(true),
                            ]),
                        ]),
                        "maxTimeMs": .number(10_000),
                    ],
                    outlets: [
                        "satisfied": "done",
                        "timeout": "timed_out",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "done",
                    action: nil,
                    outlets: nil,
                    outcome: "permission_granted"
                ),
                .init(
                    kind: .complete,
                    id: "timed_out",
                    action: nil,
                    outlets: nil,
                    outcome: "permission_timeout"
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "permission"
            )],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run {
            presenter.actionResult = .permissionResolved(
                outlet: "next",
                event: .init(
                    name: SystemEventNames.permissionGranted,
                    properties: ["type": "camera"]
                )
            )
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completionCommitted = expectation(
            description: "permission result completes its claimed cursor"
        )
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }

        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "immediate-permission-resolution",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000409",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        await waitForPresentationActions(1, presenter: presenter)
        await fulfillment(of: [completionCommitted], timeout: 2)
        let permissionEvent = try XCTUnwrap(events.routedEvents.first {
            $0.name == SystemEventNames.permissionGranted
        })
        XCTAssertEqual(permissionEvent.properties["type"] as? String, "camera")
        XCTAssertEqual(
            permissionEvent.properties["journey_id"] as? String,
            request.owner.journeyId
        )
        XCTAssertEqual(
            permissionEvent.properties["experience_version"] as? String,
            "version_golden"
        )
        let completion = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "permission_granted"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertFalse(runs.contains {
            $0.completion == nil && $0.park != nil
        })
    }

    func testPurchaseAndRestoreOutcomesAdvanceOnlyTheirClaimedPresentationAction() async throws {
        let fixtures: [(
            type: String,
            action: [String: ExperienceReleaseJSONValue],
            eventName: String,
            eventProperties: [String: Any],
            outlet: String,
            outcome: String
        )] = [
            (
                "purchase",
                [
                    "type": .string("purchase"),
                    "placementId": .object([
                        "ref": .object([
                            "kind": .string("path"),
                            "path": .string("product.placementId"),
                        ])
                    ]),
                ],
                SystemEventNames.purchaseCompleted,
                ["placement_id": "golden"],
                "completed",
                "purchased"
            ),
            (
                "purchase",
                [
                    "type": .string("purchase"),
                    "placementId": .object([
                        "ref": .object([
                            "kind": .string("path"),
                            "path": .string("product.placementId"),
                        ])
                    ]),
                ],
                SystemEventNames.purchaseFailed,
                ["placement_id": "golden"],
                "failed",
                "purchase_failed"
            ),
            (
                "purchase",
                [
                    "type": .string("purchase"),
                    "placementId": .object([
                        "ref": .object([
                            "kind": .string("path"),
                            "path": .string("product.placementId"),
                        ])
                    ]),
                ],
                SystemEventNames.purchaseCancelled,
                ["placement_id": "golden"],
                "cancelled",
                "purchase_cancelled"
            ),
            (
                "restore",
                ["type": .string("restore")],
                SystemEventNames.restoreCompleted,
                [:],
                "restored",
                "restored"
            ),
            (
                "restore",
                ["type": .string("restore")],
                SystemEventNames.restoreFailed,
                [:],
                "failed",
                "restore_failed"
            ),
            (
                "restore",
                ["type": .string("restore")],
                SystemEventNames.restoreNoPurchases,
                [:],
                "noPurchases",
                "restore_no_purchases"
            ),
        ]
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)

        for (index, actionFixture) in fixtures.enumerated() {
            let directory = temporaryDirectory()
            defer { removeTemporaryDirectoryIfPresent(directory) }
            let actionStep = DeviceLeg.Step(
                kind: .action,
                id: "commerce",
                action: actionFixture.action,
                outlets: [actionFixture.outlet: "done"],
                outcome: nil
            )
            let snapshot = replacing(
                base,
                steps: [
                    .init(
                        kind: .action,
                        id: "present",
                        action: [
                            "type": .string("navigate"),
                            "screenId": .string("screen_welcome"),
                        ],
                        outlets: [:],
                        outcome: nil
                    ),
                    actionStep,
                    .init(
                        kind: .complete,
                        id: "done",
                        action: nil,
                        outlets: nil,
                        outcome: actionFixture.outcome
                    ),
                ],
                routes: [.init(
                    host: .init(
                        kind: .screen,
                        screenId: "screen_welcome"
                    ),
                    eventName: "continue",
                    entryStepId: actionStep.id
                )],
                screens: [.init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                )]
            )
            let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
            let release = try XCTUnwrap(snapshot.releasesByDigest[
                arm.reference.descriptorSha256
            ])
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let dispatcher = InspectingDeviceLegDispatcher(
                directory: directory,
                distinctId: "customer"
            )
            let presenter = await MainActor.run {
                let value = RecordingDeviceLegPresenter()
                value.actionResult = .awaitingOutcome
                if actionFixture.type == "purchase" {
                    value.resolvedPurchasePlacementId = "golden"
                }
                return value
            }
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                dispatcher: dispatcher,
                presenter: presenter
            )

            await service.initialize()
            await service.profileDidCommit(snapshot, distinctId: "customer")
            let presentedRequest = await MainActor.run { presenter.request }
            let request = try XCTUnwrap(presentedRequest)
            let batchAccepted = await request.onEmissionBatch(presentationBatch(
                request: request,
                sourceComponentId: "commerce-button-\(index)",
                sourceInstanceId: "commerce-instance-\(index)",
                invocationId: "commerce-action-\(index)",
                emissions: [.init(
                    id: String(
                        format: "00000000-0000-7000-8000-%012d",
                        421 + index
                    ),
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00Z",
                    name: "continue",
                    payload: [:]
                )]
            ))
            XCTAssertTrue(batchAccepted)
            await waitForPresentationActions(1, presenter: presenter)
            let resolvedSource = await MainActor.run {
                presenter.resolvedActionSources.first ?? nil
            }
            XCTAssertEqual(
                resolvedSource?.componentId,
                "commerce-button-\(index)"
            )
            XCTAssertEqual(
                resolvedSource?.instanceId,
                "commerce-instance-\(index)"
            )
            let journal = try DeviceLegRunJournal(
                directory: directory,
                distinctId: "customer"
            )
            let claimedRuns = try await journal.runs()
            let claimedRun = try XCTUnwrap(claimedRuns.first)
            XCTAssertEqual(claimedRun.stepId, actionStep.id)
            let claimedEffectId = try XCTUnwrap(
                claimedRun.effectReceipts[actionStep.id]
            )
            let genericRequest = await dispatcher.onlyRequest()
            XCTAssertNil(genericRequest)

            // While StoreKit owns the claimed cursor, another renderer input
            // must not clear its receipt or dispatch the commerce action again.
            // The rejected batch remains the unpublished tail and can be
            // rolled back by the renderer's sequence lane.
            let repeatedInputAccepted = await request.onEmissionBatch(
                presentationBatch(
                    request: request,
                    batchSequence: 1,
                    previousCommittedBatchSequence: 0,
                    invocationId: "commerce-action-repeated-\(index)",
                    emissions: [.init(
                        id: String(
                            format: "00000000-0000-7000-8000-%012d",
                            621 + index
                        ),
                        sequence: 1,
                        occurredAt: "2026-08-29T12:00:00.001Z",
                        name: "continue",
                        payload: [:]
                    )]
                )
            )
            XCTAssertFalse(repeatedInputAccepted)
            let actionsAfterRepeatedInput = await MainActor.run {
                presenter.presentationActions
            }
            XCTAssertEqual(actionsAfterRepeatedInput.count, 1)
            XCTAssertEqual(actionsAfterRepeatedInput.first?.effectId, claimedEffectId)
            let runsAfterRepeatedInput = try await journal.runs()
            XCTAssertEqual(
                runsAfterRepeatedInput.first?.effectReceipts[actionStep.id],
                claimedEffectId
            )

            if actionFixture.type == "purchase" {
                let recordedActions = await MainActor.run {
                    presenter.presentationActions
                }
                guard case .string(let resolvedPlacement)? =
                    recordedActions.first?.action["placementId"] else {
                    return XCTFail("Expected the resolved purchase placement")
                }
                XCTAssertEqual(resolvedPlacement, "golden")
                await service.handleEvent(NuxieEvent(
                    name: actionFixture.eventName,
                    distinctId: "customer",
                    properties: [
                        "experience_id": release.descriptor.identity.experienceId,
                        "placement_id": "different-placement",
                    ]
                ))
                let runsAfterMismatch = try await journal.runs()
                XCTAssertEqual(
                    runsAfterMismatch.first?.stepId,
                    actionStep.id
                )
                await service.handleEvent(NuxieEvent(
                    name: actionFixture.eventName,
                    distinctId: "customer",
                    properties: [
                        "experience_id": "another-experience",
                        "placement_id": "golden",
                    ]
                ))
                let runsAfterExperienceMismatch = try await journal.runs()
                XCTAssertEqual(
                    runsAfterExperienceMismatch.first?.stepId,
                    actionStep.id
                )
            }

            let staleOutcomeEventId = String(
                format: "00000000-0000-7000-8000-%012d",
                521 + index
            )
            await service.handleEvent(NuxieEvent(
                id: staleOutcomeEventId,
                name: actionFixture.eventName,
                distinctId: "customer",
                properties: actionFixture.eventProperties
            ))
            let runsAfterStaleOutcome = try await journal.runs()
            XCTAssertEqual(
                runsAfterStaleOutcome.first?.stepId,
                actionStep.id,
                "A prior commerce outcome must not satisfy a new claimed effect"
            )

            let outcomeEventId = claimedEffectId
            let outcomeEvent = NuxieEvent(
                id: outcomeEventId,
                name: actionFixture.eventName,
                distinctId: "customer",
                properties: actionFixture.eventProperties
            )
            if index == 0 {
                events.stableCaptureBatchFailureIndex = 0
                let failedBatchAccepted = await request.onEmissionBatch(
                    presentationBatch(
                        request: request,
                        batchSequence: 1,
                        previousCommittedBatchSequence: 0,
                        invocationId: "failed-commerce-outcome-publication",
                        emissions: [.init(
                            id: outcomeEventId,
                            sequence: 1,
                            occurredAt: "2026-08-29T12:00:00.001Z",
                            name: actionFixture.eventName,
                            payload: ["placement_id": .string("golden")]
                        )]
                    )
                )
                XCTAssertFalse(failedBatchAccepted)
                events.stableCaptureBatchFailureIndex = nil

                // The same durable commerce event can arrive from StoreKit
                // after renderer publication failed. It must still reach its
                // claimed action rather than being excluded by stale routing
                // bookkeeping from the failed batch.
                await MainActor.run {
                    presenter.dropPresentationOwnershipForRelaunch()
                }
                await service.handleEvent(outcomeEvent)
            } else {
                let outcomeAdmissionGeneration = service.eventAdmissionGeneration()
                await service.profileDidCommit(snapshot, distinctId: "customer")
                await service.handleEvent(
                    outcomeEvent,
                    admittedProfileGeneration: outcomeAdmissionGeneration
                )
                await MainActor.run {
                    presenter.dropPresentationOwnershipForRelaunch()
                }
                await service.handleEvent(outcomeEvent)
            }

            let completionEvents = events.routedEvents.filter {
                $0.name == JourneyEvents.journeyLegCompleted
            }
            XCTAssertEqual(completionEvents.count, 1, actionFixture.type)
            XCTAssertEqual(
                completionEvents.first?.properties["outcome"] as? String,
                actionFixture.outcome
            )
        }
    }

    func testSameBatchResponseChangeSatisfiesTheRoutedWait() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedResponseWaitSnapshot(base)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let completionCommitted = expectation(
            description: "same-batch response wait completed"
        )
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "same-batch-response-wait",
            emissions: [
                .init(
                    id: "00000000-0000-7000-8000-000000000431",
                    sequence: 0,
                    occurredAt: "2026-08-29T12:00:00Z",
                    name: SystemEventNames.responseSet,
                    payload: [
                        "field": .string("consent"),
                        "value": .bool(true),
                    ]
                ),
                .init(
                    id: "00000000-0000-7000-8000-000000000432",
                    sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.001Z",
                    name: "continue",
                    payload: [:]
                ),
            ]
        ))
        XCTAssertTrue(accepted)
        await fulfillment(of: [completionCommitted], timeout: 2)
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "responded"
        )
    }

    func testDirectScreenRouteWinsItsCommittedSubscriberRace() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "wait",
                    action: [
                        "type": .string("wait_until"),
                        "trigger": .object([
                            "kind": .string("event"),
                            "eventName": .string("finish"),
                        ]),
                        "condition": .object([
                            "type": .string("Truthy"),
                            "value": .object([
                                "type": .string("Boolean"),
                                "value": .bool(true),
                            ]),
                        ]),
                        "maxTimeMs": .number(10_000),
                    ],
                    outlets: [
                        "satisfied": "subscriber_done",
                        "timeout": "timed_out",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "subscriber_done",
                    action: nil,
                    outlets: nil,
                    outcome: "subscriber_resumed"
                ),
                .init(
                    kind: .complete,
                    id: "routed_done",
                    action: nil,
                    outlets: nil,
                    outcome: "screen_routed"
                ),
                .init(
                    kind: .complete,
                    id: "timed_out",
                    action: nil,
                    outlets: nil,
                    outcome: "timed_out"
                ),
            ],
            routes: [
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: "continue",
                    entryStepId: "wait"
                ),
                .init(
                    host: .init(kind: .screen, screenId: "screen_welcome"),
                    eventName: "finish",
                    entryStepId: "routed_done"
                ),
            ],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
        let eventDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z")
        )
        let dateProvider = MockDateProvider(initialDate: eventDate)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: dateProvider,
            presenter: presenter
        )
        let admission = events.reserveCommittedAdmission {
            service.eventAdmissionGeneration()
        }
        await events.subscribeCommitted(
            where: nil,
            reservation: admission
        ) { event, generation in
            await service.handleEvent(
                event,
                admittedProfileGeneration: generation
            )
        }

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let waitAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "enter-event-wait",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000435",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))
        XCTAssertTrue(waitAccepted)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.park != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let parkedRuns = try await journal.runs()
        let parked = try XCTUnwrap(parkedRuns.first)
        XCTAssertEqual(parked.stepId, "wait")
        XCTAssertNotNil(parked.park)

        let completionCommitted = expectation(
            description: "direct screen route completed"
        )
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        let routeAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            batchSequence: 1,
            previousCommittedBatchSequence: 0,
            invocationId: "route-before-subscriber",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000436",
                sequence: 1,
                occurredAt: "2026-08-29T12:00:00.001Z",
                name: "finish",
                payload: [:]
            )]
        ))
        XCTAssertTrue(routeAccepted)
        await fulfillment(of: [completionCommitted], timeout: 2)

        let completion = try XCTUnwrap(events.routedEvents.last {
            $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "screen_routed"
        )
    }

    func testLaterResponseOnlyBatchesWakeTheParkedWaitWithoutMovingItsDeadline() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedResponseWaitSnapshot(base)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let dateProvider = MockDateProvider()
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: dateProvider,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let routeAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "enter-response-wait",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000441",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))
        XCTAssertTrue(routeAccepted)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.park != nil { break }
            await Task.yield()
        }
        let initiallyParkedRuns = try await journal.runs()
        let initialPark = try XCTUnwrap(initiallyParkedRuns.first?.park)

        let falseResponseAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            batchSequence: 1,
            previousCommittedBatchSequence: 0,
            invocationId: "false-response-update",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000442",
                sequence: 1,
                occurredAt: "2026-08-29T12:00:00.001Z",
                name: SystemEventNames.responseSet,
                payload: [
                    "field": .string("consent"),
                    "value": .bool(false),
                ]
            )]
        ))
        XCTAssertTrue(falseResponseAccepted)
        for _ in 0..<100 {
            let run = try await journal.runs().first
            if run?.park != nil,
               case .bool(false)? = run?.context.responses["consent"] {
                break
            }
            await Task.yield()
        }
        let reparkedRuns = try await journal.runs()
        let reparking = try XCTUnwrap(reparkedRuns.first)
        XCTAssertEqual(reparking.park?.anchorAt, initialPark.anchorAt)
        XCTAssertEqual(reparking.park?.wakeAt, initialPark.wakeAt)

        let completionCommitted = expectation(
            description: "later response wait completed"
        )
        events.addEventHandler(pattern: JourneyEvents.journeyLegCompleted) { _ in
            completionCommitted.fulfill()
        }
        let trueResponseAccepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            batchSequence: 2,
            previousCommittedBatchSequence: 1,
            invocationId: "true-response-update",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000443",
                sequence: 2,
                occurredAt: "2026-08-29T12:00:00.002Z",
                name: SystemEventNames.responseSet,
                payload: [
                    "field": .string("consent"),
                    "value": .bool(true),
                ]
            )]
        ))
        XCTAssertTrue(trueResponseAccepted)
        await fulfillment(of: [completionCommitted], timeout: 2)
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "responded"
        )
    }

    func testForegroundProfileCommitDefersDuePresentedRunUntilBecameActive() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = replacing(
            base,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "delay",
                    action: [
                        "type": .string("delay"),
                        "durationMs": .number(1_000),
                    ],
                    outlets: ["next": "show_details"],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "show_details",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_details"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "delay"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let dateProvider = MockDateProvider()
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: dateProvider,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let accepted = await request.onEmissionBatch(ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 1,
            batchSequence: 0,
            previousCommittedBatchSequence: nil,
            invocationId: "park-invocation",
            source: .init(
                screenId: "screen_welcome",
                actionId: "continue",
                componentId: nil,
                instanceId: nil
            ),
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000303",
                sequence: 0,
                occurredAt: "2001-09-09T01:46:40Z",
                name: "continue",
                payload: [:]
            )]
        ))
        XCTAssertTrue(accepted)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.park != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let parkedRun = try await journal.runs().first
        XCTAssertNotNil(parkedRun?.park)

        await service.onAppDidEnterBackground()
        await service.onAppWillEnterForeground()
        dateProvider.advance(by: 2)
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let navigationBeforeActive = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationBeforeActive, ["screen_welcome"])

        await service.onAppBecameActive()

        let navigationScreenIds = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationScreenIds, ["screen_welcome", "screen_details"])
        let presentationCount = await MainActor.run {
            presenter.presentationRequests.count
        }
        XCTAssertEqual(presentationCount, 1)
    }

    func testBusyPresentationLeavesRenderedArmUnconsumedForRevalidation() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run { presenter.available = false }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.isEmpty)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let declinedRuns = try await journal.runs()
        XCTAssertTrue(declinedRuns.isEmpty)

        let started = expectation(description: "state arm retried when capacity opened")
        events.addEventHandler(pattern: JourneyEvents.journeyLegStarted) { _ in
            started.fulfill()
        }
        await MainActor.run { presenter.available = true }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<100 {
            let presented = await MainActor.run { presenter.request != nil }
            if presented { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let request = await MainActor.run { presenter.request }
        XCTAssertEqual(request?.screenId, "screen_welcome")
    }

    func testDeclinedEventArmWaitsForTheNextMatchingEventWithoutQueuing() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let eventEntry = DeviceLegEntryCondition(
            type: .event,
            eventName: "hello",
            segmentId: nil,
            member: nil,
            condition: nil
        )
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            entry: eventEntry
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run { presenter.available = false }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleEvent(NuxieEvent(
            name: "hello",
            distinctId: "customer",
            properties: [:]
        ))
        XCTAssertTrue(events.routedEvents.isEmpty)

        await MainActor.run { presenter.available = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.handleEvent(NuxieEvent(
            name: "hello",
            distinctId: "customer",
            properties: [:]
        ))

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let request = await MainActor.run { presenter.request }
        XCTAssertEqual(request?.screenId, "screen_welcome")
    }

    func testExperimentExposureWaitsForTheSelectedVariantToBeShown() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: true)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let gate = DeviceLegScreenCommitGate()
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run {
            presenter.automaticallyRevealsShownPresentation = false
            presenter.presentHandler = { _ in
                await gate.suspend()
                return .shown
            }
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )
        await service.initialize()

        let profileCommit = Task {
            await service.profileDidCommit(snapshot, distinctId: "customer")
        }
        await gate.waitUntilEntered()

        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let selectedRuns = try await journal.runs()
        let selectedRun = try XCTUnwrap(selectedRuns.first)
        let selectedExposure = try XCTUnwrap(
            selectedRun.experimentExposures.first
        )
        XCTAssertEqual(selectedExposure.experimentId, "experiment_checkout")
        XCTAssertEqual(selectedExposure.variantId, "variant_b")
        XCTAssertEqual(selectedExposure.kind, .assigned)
        XCTAssertNil(selectedExposure.shownAt)
        XCTAssertFalse(selectedExposure.queued)
        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })

        await gate.release()
        await profileCommit.value

        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })
        let capturedRequest = await MainActor.run { presenter.request }
        let presentedRequest = try XCTUnwrap(capturedRequest)
        await presentedRequest.onPresentationRevealed()

        let exposures = events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }
        XCTAssertEqual(exposures.count, 1)
        XCTAssertEqual(
            exposures.first?.properties["experiment_key"] as? String,
            "experiment_checkout"
        )
        XCTAssertEqual(
            exposures.first?.properties["variant_key"] as? String,
            "variant_b"
        )
        XCTAssertEqual(
            exposures.first?.properties["assignment_source"] as? String,
            "profile"
        )
        XCTAssertEqual(exposures.first?.properties["is_holdout"] as? Bool, true)
        let shownRuns = try await journal.runs()
        let shownRun = try XCTUnwrap(shownRuns.first)
        let shownExposure = try XCTUnwrap(shownRun.experimentExposures.first)
        XCTAssertNotNil(shownExposure.shownAt)
        XCTAssertTrue(shownExposure.queued)
        XCTAssertEqual(exposures.first?.id, shownExposure.eventId)

        _ = try await DeviceLegExperimentExposureReporter(
            journal: journal,
            events: events
        ).flushPending()
        XCTAssertEqual(events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }.count, 1)
    }

    func testShutdownJoinsAnInFlightExperimentExposureRetry() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let captureGate = DeviceLegNthRoutedCaptureGate(
            eventName: JourneyEvents.experimentExposure,
            suspendedCall: 2
        )
        events.routedCaptureHandler = { event, _ in
            await captureGate.intercept(event: event)
        }
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.automaticallyRevealsShownPresentation = false
            return value
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        events.routedCaptureFailuresRemaining = 1
        await request.onPresentationRevealed()
        for _ in 0..<200 {
            if await captureGate.isSuspended() { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let retryIsSuspended = await captureGate.isSuspended()
        XCTAssertTrue(retryIsSuspended)

        let completion = DeviceLegCompletionFlag()
        let shutdown = Task {
            await service.shutdown()
            completion.finish()
        }
        // Profile teardown makes its own flush attempt before shutdown reaches
        // the retry-task join. Wait for that attempt so this assertion cannot
        // pass merely because the shutdown task has not started yet.
        for _ in 0..<100 {
            if await captureGate.observationCount() >= 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let captureCount = await captureGate.observationCount()
        XCTAssertGreaterThanOrEqual(captureCount, 3)
        XCTAssertFalse(completion.isCompleted)

        await captureGate.release()
        await shutdown.value
        XCTAssertTrue(completion.isCompleted)
    }

    func testExperimentExposureIsReportedForSameScreenAlreadyActiveNavigation() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedVisibleExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false),
            targetScreenId: "screen_welcome"
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.navigationResult = .alreadyActive
            return value
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.experimentExposure
        })
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let exposureCaptured = expectation(description: "selected variant exposed")
        events.addEventHandler(pattern: JourneyEvents.experimentExposure) { _ in
            exposureCaptured.fulfill()
        }

        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "select-visible-experiment",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000305",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        await fulfillment(of: [exposureCaptured], timeout: 2)
        let exposures = events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }
        XCTAssertEqual(exposures.count, 1)
        XCTAssertEqual(
            exposures.first?.properties["experiment_key"] as? String,
            "experiment_checkout"
        )
        XCTAssertEqual(
            exposures.first?.properties["variant_key"] as? String,
            "variant_b"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        var exposureWasQueued = false
        for _ in 0..<100 {
            let runs = try await journal.runs()
            exposureWasQueued = runs.first?.experimentExposures.first?.queued
                == true
            if exposureWasQueued { break }
            await Task.yield()
        }
        XCTAssertTrue(exposureWasQueued)
        let navigationScreenIds = await MainActor.run {
            presenter.navigationScreenIds
        }
        XCTAssertEqual(navigationScreenIds, ["screen_welcome", "screen_welcome"])
        await service.shutdown()
    }

    func testNavigatedExperimentExposureWaitsForTheVisibleScreenCallback() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedVisibleExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run {
            let value = RecordingDeviceLegPresenter()
            value.navigationResult = .navigated
            return value
        }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let accepted = await request.onEmissionBatch(presentationBatch(
            request: request,
            invocationId: "select-navigated-experiment",
            emissions: [.init(
                id: "00000000-0000-7000-8000-000000000306",
                sequence: 0,
                occurredAt: "2026-08-29T12:00:00Z",
                name: "continue",
                payload: [:]
            )]
        ))

        XCTAssertTrue(accepted)
        for _ in 0..<100 {
            let navigationCount = await MainActor.run {
                presenter.navigationScreenIds.count
            }
            if navigationCount == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(events.routedEvents.contains {
            $0.name == JourneyEvents.experimentExposure
        })

        // Production invokes this callback from the target screen's active
        // lifecycle boundary. Merely returning `.navigated` above must not
        // count as an impression.
        await request.onPresentationRevealed()
        for _ in 0..<100 {
            let exposureCount = events.routedEvents.filter {
                $0.name == JourneyEvents.experimentExposure
            }.count
            if exposureCount == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let exposureCount = events.routedEvents.filter {
            $0.name == JourneyEvents.experimentExposure
        }.count
        XCTAssertEqual(exposureCount, 1)
    }

    func testUnfetchedExperimentReportsFallbackOnlyAfterDefaultVariantIsShown() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: nil
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
        })
        let fallback = try XCTUnwrap(events.routedEvents.first {
            $0.name == JourneyEvents.experimentExposureFallback
        })
        XCTAssertEqual(fallback.properties["variant_key"] as? String, "variant_a")
        XCTAssertEqual(
            fallback.properties["assignment_source"] as? String,
            "no_assignment"
        )
    }

    func testDeclinedPresentationDoesNotReportExperimentExposure() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedExperimentSnapshot(
            try await authenticatedRenderedSnapshot(fixture),
            assignment: .init(variantId: "variant_b", isHoldout: false)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        await MainActor.run { presenter.result = .declined }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.name != JourneyEvents.experimentExposure
                && $0.name != JourneyEvents.experimentExposureFallback
                && $0.name != JourneyEvents.experimentExposureError
        })
    }

    func testUnhandledHostDismissalCompletesTheRenderedLeg() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)

        let accepted = await request.onOutcome(.dismissed, request.screenId)

        XCTAssertTrue(accepted)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
        ])
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "host_dismissed"
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let remainingRuns = try await journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
    }

    func testHostDismissalRetryFlushesAnAlreadyDurableCompletion() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        let run = try XCTUnwrap(runs.first)
        try await journal.complete(
            run.id,
            outcome: "host_dismissed",
            at: Date(timeIntervalSince1970: 2)
        )

        let accepted = await request.onOutcome(.dismissed, request.screenId)

        XCTAssertTrue(accepted)
        let remainingRuns = try await journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
        ])
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "host_dismissed"
        )
    }

    func testHandledHostDismissalClearsContextBeforeUnsupportedContinuationAbandons() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let eventField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("stale"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let snapshot = replacing(
            try await authenticatedRenderedSnapshot(fixture),
            inputs: .init(eventFields: [eventField], responseFields: []),
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "server_only",
                    action: ["type": .string("server_only")],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "host_dismissed",
                entryStepId: "server_only"
            )],
            armContext: .init(
                event: ["stale": .string("old-value")],
                responses: [:]
            )
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let accepted = await request.onOutcome(.dismissed, "screen_welcome")
        XCTAssertTrue(accepted)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        for _ in 0..<100 {
            if try await journal.runs().first?.stepId == "server_only" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recordedRun = try await journal.runs().first
        let run = try XCTUnwrap(recordedRun)

        XCTAssertEqual(run.stepId, "server_only")
        XCTAssertTrue(run.context.event.dictionary.isEmpty)
        XCTAssertNil(run.park)

        await MainActor.run {
            request.onPresentationFinished()
        }
        for _ in 0..<100 {
            if try await journal.runs().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let continuedRuns = try await journal.runs()
        XCTAssertTrue(continuedRuns.isEmpty)
        XCTAssertEqual(
            events.routedEvents.last?.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testProfileClearShutsDownTheRenderedLegSurface() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        await service.profileDidClear(distinctId: "customer")

        let shutdownOwners = await MainActor.run { presenter.shutdownOwners }
        XCTAssertEqual(shutdownOwners, ["customer"])
    }

    func testRenderedArmWaitsForActiveForegroundBeforeAdmission() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingDeviceLegPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )
        await service.initialize()
        await service.onAppDidEnterBackground()

        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.isEmpty)
        let backgroundRequest = await MainActor.run { presenter.request }
        XCTAssertNil(backgroundRequest)

        await service.onAppWillEnterForeground()
        await service.onAppBecameActive()

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])
        let foregroundRequest = await MainActor.run { presenter.request }
        XCTAssertEqual(foregroundRequest?.screenId, "screen_welcome")
    }

    func testEveryTimeForegroundArmReopensOnEachForegroundAndLaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            reentry: .init(type: .everyTime, windowSeconds: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity

        do {
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory
            )
            await service.initialize()
            await service.profileDidCommit(snapshot, distinctId: "customer")
            XCTAssertEqual(
                events.routedEvents.map(\.name).filter {
                    $0 == JourneyEvents.journeyLegStarted
                        || $0 == JourneyEvents.journeyLegCompleted
                }.count,
                2
            )

            await service.onAppDidEnterBackground()
            await service.onAppWillEnterForeground()
            await service.onAppBecameActive()
            XCTAssertEqual(
                events.routedEvents.map(\.name).filter {
                    $0 == JourneyEvents.journeyLegStarted
                        || $0 == JourneyEvents.journeyLegCompleted
                }.count,
                4
            )
        }

        let relaunched = makeService(
            identity: identity,
            events: events,
            directory: directory
        )
        await relaunched.initialize()
        await relaunched.profileDidCommit(snapshot, distinctId: "customer")
        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            }.count,
            6
        )
    }

    func testProfileClearReopensStateArmAdmissionForRedelivery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            reentry: .init(type: .everyTime, windowSeconds: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.profileDidClear(distinctId: "customer")
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            }.count,
            4
        )
    }

    func testEventArmsAreEdgesAndProjectOnlyDeclaredEventFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let eventField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("sku"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "purchase_intent",
                segmentId: nil,
                member: nil,
                condition: nil
            ),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            inputs: .init(eventFields: [eventField], responseFields: []),
            completionOutputs: [
                "continue": .init(
                    eventFields: [eventField],
                    responseFields: []
                )
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleEvent(NuxieEvent(
            name: "unrelated",
            distinctId: "customer"
        ))
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000101",
            name: "purchase_intent",
            distinctId: "customer",
            properties: ["sku": "pro", "ignored": "extra"],
            timestamp: Date(timeIntervalSince1970: 1_001)
        ))
        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000102",
            name: "purchase_intent",
            distinctId: "customer",
            properties: ["sku": "team"],
            timestamp: Date(timeIntervalSince1970: 1_002)
        ))

        let lifecycle = events.routedEvents.filter {
            $0.name == JourneyEvents.journeyLegStarted
                || $0.name == JourneyEvents.journeyLegCompleted
        }
        XCTAssertEqual(lifecycle.map(\.name), [
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
        ])
        let completionOutputs = try lifecycle
            .filter { $0.name == JourneyEvents.journeyLegCompleted }
            .map { event -> [String: Any] in
                try XCTUnwrap(event.properties["outputs"] as? [String: Any])
            }
        XCTAssertEqual(
            completionOutputs.compactMap {
                ($0["event"] as? [String: String])?["sku"]
            },
            ["pro", "team"]
        )
        XCTAssertTrue(completionOutputs.allSatisfy {
            ($0["event"] as? [String: Any])?["ignored"] == nil
        })
    }

    func testEventCapturedBeforeProfileReplacementCannotStartANewlyDeliveredArm() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let eventSnapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "profile_replacement_trigger",
                segmentId: nil,
                member: nil,
                condition: nil
            ),
            reentry: .init(type: .everyTime, windowSeconds: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(
            removingDeliveredReleases(from: eventSnapshot),
            distinctId: "customer"
        )
        let capturedGeneration = service.eventAdmissionGeneration()
        await service.profileDidCommit(eventSnapshot, distinctId: "customer")
        let capturedBeforeReplacement = NuxieEvent(
            id: "00000000-0000-7000-8000-000000000103",
            name: "profile_replacement_trigger",
            distinctId: "customer"
        )

        await service.handleEvent(
            capturedBeforeReplacement,
            admittedProfileGeneration: capturedGeneration
        )
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.handleEvent(
            NuxieEvent(
                id: "00000000-0000-7000-8000-000000000104",
                name: "profile_replacement_trigger",
                distinctId: "customer"
            ),
            admittedProfileGeneration: service.eventAdmissionGeneration()
        )
        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            },
            [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted]
        )
    }

    func testStartRechecksEntryConditionAfterSuspendingGates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let condition = IREnvelope(
            ir_version: 1,
            engine_min: nil,
            compiled_at: nil,
            expr: .feature(op: "has", id: "entry", value: nil)
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .appForegrounded,
                eventName: nil,
                segmentId: nil,
                member: nil,
                condition: condition
            )
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let access = SequencedFeatureAccess([true, false])
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            featureAccess: { featureId in
                guard featureId == "entry" else { return nil }
                return await access.next()
            }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.isEmpty)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
        let accessCount = await access.readCount()
        XCTAssertEqual(accessCount, 2)
    }

    func testEntitlementGateSuppressesAProductWhoseFullGrantIsPresent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entitlementGate: .init(enabled: true, products: [
                .init(productId: "pro", featureIds: ["premium"])
            ])
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            featureAccess: { featureId in
                guard featureId == "premium" else { return nil }
                return FeatureAccess(
                    allowed: true,
                    unlimited: true,
                    balance: nil,
                    type: .boolean
                )
            }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.isEmpty)
    }

    func testProfileClearAbandonsAParkedRun() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000))
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: now
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let parked = try await journal.runs()
        XCTAssertEqual(parked.count, 1)
        XCTAssertNotNil(parked.first?.park)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])

        await service.profileDidClear(distinctId: "customer")

        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyLegCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "abandoned")
    }

    func testNewUserProfileRetiresTheOldJournalBeforeQueuedTransitionWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 1_000)
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer-a")
        await service.onAppDidEnterBackground()
        let oldJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-a"
        )
        let parkedOldRuns = try await oldJournal.runs()
        XCTAssertEqual(parkedOldRuns.count, 1)

        identity.setDistinctId("customer-b")
        await service.profileDidCommit(snapshot, distinctId: "customer-b")

        let oldRuns = try await oldJournal.runs()
        XCTAssertTrue(oldRuns.isEmpty)
        let oldCompletion = try XCTUnwrap(events.routedEvents.first {
            $0.distinctId == "customer-a"
                && $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            oldCompletion.properties["outcome"] as? String,
            "abandoned"
        )
        let newJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-b"
        )
        let newRuns = try await newJournal.runs()
        XCTAssertTrue(newRuns.isEmpty)

        await service.handleUserChange(
            from: "customer-a",
            to: "customer-b"
        )
        let oldRunsAfterTransition = try await oldJournal.runs()
        XCTAssertTrue(oldRunsAfterTransition.isEmpty)
        await service.onAppWillEnterForeground()
        await service.onAppBecameActive()
        let newRunsAfterTransition = try await newJournal.runs()
        XCTAssertEqual(newRunsAfterTransition.count, 1)
        XCTAssertNotNil(
            newRunsAfterTransition.first?.park,
            "Queued A→B teardown must preserve the B profile and journal that outran it"
        )
    }

    func testIdentitySwitchRetriesFailedJournalRevocationBeforeReopeningCustomer() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [
                .init(
                    kind: .action,
                    id: "wait",
                    action: [
                        "type": .string("delay"),
                        "durationMs": .number(60_000),
                    ],
                    outlets: ["next": "report"],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "report",
                    action: nil,
                    outlets: nil,
                    outcome: "continue"
                ),
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 1_000)
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer-a")
        let oldJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-a"
        )
        let initialRuns = try await oldJournal.runs()
        XCTAssertEqual(initialRuns.count, 1)

        let root = directory.appendingPathComponent(
            "device-leg-journal-v1",
            isDirectory: true
        )
        let customerDigest = DeviceLegStorageScope.testFixture.customerDigest(
            distinctId: "customer-a"
        )
        let blockedRevocationFile = root.appendingPathComponent(
            "\(customerDigest).revoked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: blockedRevocationFile,
            withIntermediateDirectories: true
        )

        identity.setDistinctId("customer-b")
        await service.handleUserChange(
            from: "customer-a",
            to: "customer-b"
        )
        let runsAfterFailedRevocation = try await oldJournal.runs()
        XCTAssertEqual(
            runsAfterFailedRevocation.count,
            1,
            "A failed tombstone write must leave the old journal blocked in memory"
        )

        try FileManager.default.removeItem(at: blockedRevocationFile)
        identity.setDistinctId("customer-a")
        await service.handleUserChange(
            from: "customer-b",
            to: "customer-a"
        )

        let runsAfterRetriedRevocation = try await oldJournal.runs()
        XCTAssertTrue(runsAfterRetriedRevocation.isEmpty)
        let abandoned = try XCTUnwrap(events.routedEvents.last {
            $0.distinctId == "customer-a"
                && $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            abandoned.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testIdentitySwitchRetainsRevokedJournalUntilAbandonmentCaptureIsDurable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [
                .init(
                    kind: .action,
                    id: "wait",
                    action: [
                        "type": .string("delay"),
                        "durationMs": .number(60_000),
                    ],
                    outlets: ["next": "report"],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "report",
                    action: nil,
                    outlets: nil,
                    outcome: "continue"
                ),
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 1_000)
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer-a")
        let oldJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-a"
        )
        let initialRuns = try await oldJournal.runs()
        XCTAssertEqual(initialRuns.count, 1)

        // handleUserChange retries the displaced journal once through
        // ensureJournal. Fail both attempts so the service must retain that
        // journal rather than orphaning its unqueued completion.
        events.routedCaptureFailuresRemaining = 2
        identity.setDistinctId("customer-b")
        await service.handleUserChange(
            from: "customer-a",
            to: "customer-b"
        )

        let pendingRuns = try await oldJournal.runs()
        let pending = try XCTUnwrap(pendingRuns.first)
        XCTAssertEqual(pending.completion?.outcome, "abandoned")
        XCTAssertTrue(pending.startedQueued)
        XCTAssertFalse(events.routedEvents.contains {
            $0.distinctId == "customer-a"
                && $0.name == JourneyEvents.journeyLegCompleted
        })

        // A later profile callback is the ordinary retry boundary. Once the
        // old completion is in EventLog, the new customer's journal may open.
        await service.profileDidCommit(snapshot, distinctId: "customer-b")

        let retiredRuns = try await oldJournal.runs()
        XCTAssertTrue(retiredRuns.isEmpty)
        let abandonments = events.routedEvents.filter {
            $0.distinctId == "customer-a"
                && $0.name == JourneyEvents.journeyLegCompleted
        }
        XCTAssertEqual(abandonments.count, 1)
        XCTAssertEqual(
            abandonments.first?.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testRecoveryResumesOnlyThePersistedDueParkPoint() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(1_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_002))
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let releasePin = try XCTUnwrap(snapshot.profile.releases.first)
        let admitted = try await journal.admit(
            arm: arm,
            release: releasePin,
            reentry: .init(type: .oneTime, windowSeconds: nil),
            entryStepId: "wait",
            at: Date(timeIntervalSince1970: 1_000)
        )
        let run = try XCTUnwrap(admitted)
        try await DeviceLegReporter(journal: journal, events: events)
            .flushPending()
        try await journal.transition(
            run.id,
            stepId: "wait",
            context: run.context,
            checkpoint: .init(
                anchorAtMillis: 1_000_000,
                wakeAtMillis: 1_001_000
            )
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: now
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(events.routedEvents.map(\.name).filter {
            $0 == JourneyEvents.journeyLegStarted
                || $0 == JourneyEvents.journeyLegCompleted
        }, [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted])
    }

    func testProfileReplacementResumesADueRunFromItsAuthenticatedReleasePin() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(1_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let retained = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(
            initialDate: Date(timeIntervalSince1970: 1_000)
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: now,
            pinnedReleaseAuthenticator: { _, _ in retained }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let parked = try await journal.runs()
        XCTAssertEqual(parked.count, 1)
        now.advance(by: 2)

        await service.profileDidCommit(
            removingDeliveredReleases(from: snapshot),
            distinctId: "customer"
        )

        let completed = try await journal.runs()
        XCTAssertTrue(completed.isEmpty)
        let releasedPin = try await journal.releasePin(
            descriptorSHA256: retained.descriptorSHA256
        )
        XCTAssertNil(releasedPin)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyLegCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "continue")
    }

    func testUnsupportedInjectedEffectAbandonsInsteadOfCreatingResumePoint() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let unsupported = DeviceLeg.Step(
            kind: .action,
            id: "future",
            action: ["type": .string("future_action")],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "future",
            steps: [unsupported, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )

        let remainingRuns = try await journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyLegCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "abandoned")
    }

    func testDueRunAbandonsWhenItsReleasePinCannotAuthenticateAfterProfileReplacement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let dateProvider = MockDateProvider(
            initialDate: Date(timeIntervalSince1970: 1_000)
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: dateProvider,
            pinnedReleaseAuthenticator: { _, _ in
                throw ExperienceReleaseDescriptorAuthenticationError.invalidSignature
            }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let parked = try await journal.runs()
        XCTAssertEqual(parked.count, 1)
        try await journal.recordResponses(
            try XCTUnwrap(parked.first).id,
            values: ["answer": .string("retained")]
        )

        await service.profileDidCommit(
            removingDeliveredReleases(from: snapshot),
            distinctId: "customer"
        )
        dateProvider.advance(by: 61)
        await service.onAppBecameActive()

        let completed = try await journal.runs()
        XCTAssertTrue(completed.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyLegCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "abandoned")
        let outputs = try XCTUnwrap(
            completion.properties["outputs"] as? [String: Any]
        )
        let responses = try XCTUnwrap(outputs["responses"] as? [String: Any])
        XCTAssertEqual(responses["answer"] as? String, "retained")
    }

    private func authenticatedSnapshot(
        _ fixture: DeviceLegPlaneProfileTestFixture,
        supportedRuntime: ExperienceReleaseSupportedRuntime = ExperienceReleaseRuntime.current
    ) async throws -> DeviceLegProfileCatalog.Snapshot {
        let catalog = DeviceLegProfileCatalog(
            authorizationKeys: [ExperiencePackageAuthorizationKey(
                keyID: "TEST_ONLY_DEV_KEYPAIR",
                ed25519PublicKeyBytes: fixture.publicKey
            )],
            supportedRuntime: supportedRuntime,
            highWaterStore: InMemoryExperienceReleaseHighWaterStore()
        )
        let prepared = try await catalog.prepare(
            fixture.profile,
            authority: fixture.deliveryAuthority
        )
        _ = try await catalog.commit(prepared, distinctId: "customer")
        let snapshot = await catalog.snapshot(distinctId: "customer")
        return try XCTUnwrap(snapshot)
    }

    private func authenticatedRenderedSnapshot(
        _ fixture: DeviceLegPlaneProfileTestFixture
    ) async throws -> DeviceLegProfileCatalog.Snapshot {
        let entry = try XCTUnwrap(fixture.profile.releases.first)
        let descriptorBytes = try XCTUnwrap(Data(
            base64Encoded: entry.envelope.descriptorBytesBase64
        ))
        let descriptor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: descriptorBytes)
                as? [String: Any]
        )
        let requirements = try XCTUnwrap(
            descriptor["requirements"] as? [String: Any]
        )
        let luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
        let scene = try XCTUnwrap(
            requirements["sceneFormat"] as? [String: Any]
        )
        let timezone = try XCTUnwrap(
            requirements["timezoneData"] as? [String: Any]
        )
        let supportedRuntime = ExperienceReleaseSupportedRuntime(
            currentSdkVersion: try XCTUnwrap(
                requirements["minimumSdkVersion"] as? String
            ),
            supportedRuntimeRevisions: [try XCTUnwrap(
                requirements["runtimeRevision"] as? String
            )],
            supportedLuauRevisions: [
                try XCTUnwrap(luau["revision"] as? String): Set(
                    try XCTUnwrap(luau["bytecodeVersions"] as? [Int])
                ),
            ],
            sceneFormat: .init(
                major: try XCTUnwrap(scene["major"] as? Int),
                minor: try XCTUnwrap(scene["minor"] as? Int)
            ),
            timezoneDataRevision: try XCTUnwrap(
                timezone["revision"] as? String
            ),
            timezoneDataSHA256: try XCTUnwrap(
                timezone["sha256"] as? String
            ),
            supportedCapabilities: Set(try XCTUnwrap(
                requirements["requiredCapabilities"] as? [String]
            ))
        )
        return try await authenticatedSnapshot(
            fixture,
            supportedRuntime: supportedRuntime
        )
    }

    private func renderedNavigationSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot
    ) -> DeviceLegProfileCatalog.Snapshot {
        replacing(
            snapshot,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "show_details",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_details"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "show_details"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ]
        )
    }

    private func renderedExperimentSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        assignment: DeviceLegFactTable.Assignment?
    ) -> DeviceLegProfileCatalog.Snapshot {
        var assignments: ExactJSONObject<DeviceLegFactTable.Assignment?> = [:]
        if let assignment {
            assignments["experiment_checkout"] = assignment
        }
        let facts = DeviceLegFactTable(
            properties: snapshot.profile.facts.properties,
            memberships: snapshot.profile.facts.memberships,
            assignments: assignments
        )
        return replacing(
            snapshot,
            entryStepId: "experiment",
            steps: [
                .init(
                    kind: .action,
                    id: "experiment",
                    action: [
                        "type": .string("experiment"),
                        "experimentId": .string("experiment_checkout"),
                        "variants": .array([
                            .object(["id": .string("variant_a")]),
                            .object(["id": .string("variant_b")]),
                        ]),
                    ],
                    outlets: [
                        "variant_a": "present_a",
                        "variant_b": "present_b",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "present_a",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "present_b",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            factReferences: .init(
                propertyKeys: [],
                segmentIds: [],
                experimentIds: ["experiment_checkout"]
            ),
            facts: facts
        )
    }

    private func renderedVisibleExperimentSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        assignment: DeviceLegFactTable.Assignment?,
        targetScreenId: String = "screen_details"
    ) -> DeviceLegProfileCatalog.Snapshot {
        var assignments: ExactJSONObject<DeviceLegFactTable.Assignment?> = [:]
        if let assignment {
            assignments["experiment_checkout"] = assignment
        }
        let facts = DeviceLegFactTable(
            properties: snapshot.profile.facts.properties,
            memberships: snapshot.profile.facts.memberships,
            assignments: assignments
        )
        return replacing(
            snapshot,
            entryStepId: "present",
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "experiment",
                    action: [
                        "type": .string("experiment"),
                        "experimentId": .string("experiment_checkout"),
                        "variants": .array([
                            .object(["id": .string("variant_a")]),
                            .object(["id": .string("variant_b")]),
                        ]),
                    ],
                    outlets: [
                        "variant_a": "present_variant",
                        "variant_b": "present_variant",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "present_variant",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string(targetScreenId),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "experiment"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ],
            factReferences: .init(
                propertyKeys: [],
                segmentIds: [],
                experimentIds: ["experiment_checkout"]
            ),
            facts: facts
        )
    }

    private func renderedDismissalCompletionSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        eventName: String = SystemEventNames.screenDismissed
    ) -> DeviceLegProfileCatalog.Snapshot {
        replacing(
            snapshot,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "dismissed",
                    action: nil,
                    outlets: nil,
                    outcome: "screen_dismissed"
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: eventName,
                entryStepId: "dismissed"
            )],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
    }

    private func renderedEventPropertyBranchSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        eventName: String
    ) -> DeviceLegProfileCatalog.Snapshot {
        replacing(
            snapshot,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "branch_on_event",
                    action: [
                        "type": .string("condition"),
                        "branches": .array([.object([
                            "id": .string("allowed"),
                            "condition": .object([
                                "type": .string("Truthy"),
                                "value": .object([
                                    "type": .string("Event.Field"),
                                    "key": .string("allow"),
                                ]),
                            ]),
                        ])]),
                    ],
                    outlets: [
                        "allowed": "accepted",
                        "default": "rejected",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "accepted",
                    action: nil,
                    outlets: nil,
                    outcome: "transformed"
                ),
                .init(
                    kind: .complete,
                    id: "rejected",
                    action: nil,
                    outlets: nil,
                    outcome: "original"
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: eventName,
                entryStepId: "branch_on_event"
            )],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
    }

    private func renderedResponseWaitSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot
    ) -> DeviceLegProfileCatalog.Snapshot {
        let responseField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("consent"),
            "type": .string("boolean"),
            "required": .bool(false),
        ]
        return replacing(
            snapshot,
            inputs: .init(
                eventFields: [],
                responseFields: [responseField]
            ),
            completionOutputs: [
                "responded": .init(
                    eventFields: [],
                    responseFields: [responseField]
                ),
                "timeout": .init(
                    eventFields: [],
                    responseFields: [responseField]
                ),
            ],
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "wait",
                    action: [
                        "type": .string("wait_until"),
                        "trigger": .object([
                            "kind": .string("response_change")
                        ]),
                        "condition": .object([
                            "type": .string("Truthy"),
                            "value": .object([
                                "type": .string("Response.Field"),
                                "key": .string("consent"),
                            ]),
                        ]),
                        "maxTimeMs": .number(10_000),
                    ],
                    outlets: [
                        "satisfied": "done",
                        "timeout": "timed_out",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "done",
                    action: nil,
                    outlets: nil,
                    outcome: "responded"
                ),
                .init(
                    kind: .complete,
                    id: "timed_out",
                    action: nil,
                    outlets: nil,
                    outcome: "timeout"
                ),
            ],
            routes: [.init(
                host: .init(
                    kind: .screen,
                    screenId: "screen_welcome"
                ),
                eventName: "continue",
                entryStepId: "wait"
            )],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["consent"]
            )]
        )
    }

    private func presentationBatch(
        request: DeviceLegPresentationRequest,
        presentationEpoch: UInt64 = 1,
        batchSequence: UInt64 = 0,
        previousCommittedBatchSequence: UInt64? = nil,
        sourceComponentId: String? = nil,
        sourceInstanceId: String? = nil,
        invocationId: String,
        emissions: [ScreenEmission]
    ) -> ScreenEmissionBatch {
        ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: presentationEpoch,
            batchSequence: batchSequence,
            previousCommittedBatchSequence: previousCommittedBatchSequence,
            invocationId: invocationId,
            source: .init(
                screenId: request.screenId,
                actionId: "continue",
                componentId: sourceComponentId,
                instanceId: sourceInstanceId
            ),
            emissions: emissions
        )
    }

    private func assertDurableEventCommitIsRejected(
        action: [String: ExperienceReleaseJSONValue],
        effectId: String,
        revocation: DeviceLegCommitRevocation
    ) async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(identity.performWithCurrentIdentityFence(
            "customer",
            { _ in () }
        ))
        let executionFence = DeviceLegProfileFence()
        let executionFenceToken = executionFence.token()
        let store = MockEventStore()
        let log = EventLog(
            identity: identity,
            dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(),
            store: store
        )
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.flushAt = 100
        try await log.configure(configuration: configuration)
        let historyCoverageBeforeCapture = try await store
            .historyCoverageStartingAt()
        store.suspendStableCaptureBeforeCommit(id: effectId)
        let dispatcher = DeviceLegEffectDispatcher(
            identity: identity,
            events: log
        )
        let dispatch = Task {
            await dispatcher.dispatch(.init(
                runId: "journey:0",
                journeyId: "journey",
                generation: 0,
                reference: arm.reference,
                release: release,
                stepId: "effect",
                action: action,
                context: .init(event: [:], responses: [:]),
                effectId: effectId,
                distinctId: "customer",
                identityFence: identityFence.token,
                executionFence: executionFence,
                executionFenceToken: executionFenceToken
            ))
        }
        for _ in 0..<1_000
        where !store.isStableCaptureBeforeCommitWaiting(id: effectId) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard store.isStableCaptureBeforeCommitWaiting(id: effectId) else {
            store.resumeStableCaptureBeforeCommit(id: effectId)
            _ = await dispatch.value
            await log.close()
            return XCTFail("Expected stable capture to pause before commit")
        }

        switch revocation {
        case .execution:
            _ = executionFence.advance()
        case .identity:
            identity.setDistinctId("replacement-customer")
        }
        store.resumeStableCaptureBeforeCommit(id: effectId)
        let result = await dispatch.value
        let historyCoverageAfterCapture = try await store
            .historyCoverageStartingAt()
        await log.close()

        XCTAssertEqual(result, .failed)
        XCTAssertFalse(store.storedEvents.contains { $0.id == effectId })
        XCTAssertEqual(
            historyCoverageAfterCapture,
            historyCoverageBeforeCapture,
            "Expected fence rejection must not manufacture a history gap"
        )
    }

    private func makeService(
        identity: MockIdentityService,
        events: MockEventLog,
        directory: URL,
        dateProvider: DateProviderProtocol = MockDateProvider(),
        featureAccess: @escaping DeviceLegService.FeatureAccessLookup = { _ in nil },
        dispatcher: (any DeviceLegDispatching)? = nil,
        presenter: (any DeviceLegPresenting)? = nil,
        pinnedReleaseAuthenticator: @escaping DeviceLegService.PinnedReleaseAuthenticator = {
            _, _ in throw DeviceLegJournalError.invalidState
        },
        journalBeforePersist: (@Sendable () throws -> Void)? = nil
    ) -> DeviceLegService {
        DeviceLegService(
            identity: identity,
            events: events,
            dateProvider: dateProvider,
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: featureAccess,
            dispatcher: dispatcher ?? DeviceLegEffectDispatcher(
                identity: identity,
                events: events
            ),
            presenter: presenter,
            pinnedReleaseAuthenticator: pinnedReleaseAuthenticator,
            timezones: SignedTimezoneBundle.installed!,
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!,
            journalBeforePersist: journalBeforePersist
        )
    }

    private func removingDeliveredReleases(
        from snapshot: DeviceLegProfileCatalog.Snapshot
    ) -> DeviceLegProfileCatalog.Snapshot {
        .init(
            profile: .init(
                schemaVersion: snapshot.profile.schemaVersion,
                status: snapshot.profile.status,
                delivery: snapshot.profile.delivery,
                features: snapshot.profile.features,
                facts: snapshot.profile.facts,
                armedLegs: [],
                releases: []
            ),
            releasesByDigest: [:]
        )
    }

    private func replacing(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        entry: DeviceLegEntryCondition? = nil,
        reentry: DeviceLeg.Reentry? = nil,
        entitlementGate: DeviceLeg.EntitlementGate? = nil,
        inputs: DeviceLeg.Boundary? = nil,
        completionOutputs: [String: DeviceLeg.Boundary]? = nil,
        entryStepId: String? = nil,
        steps: [DeviceLeg.Step]? = nil,
        routes: [DeviceLeg.Route]? = nil,
        screens: [DeviceLeg.Screen]? = nil,
        factReferences: DeviceLegFactReferences? = nil,
        facts: DeviceLegFactTable? = nil,
        viewModelValues: [[String: ExperienceReleaseJSONValue]]? = nil,
        armContext: ArmedDeviceLeg.Context? = nil
    ) -> DeviceLegProfileCatalog.Snapshot {
        let originalArm = snapshot.profile.armedLegs[0]
        let originalRelease = snapshot.releasesByDigest[
            originalArm.reference.descriptorSha256
        ]!
        let originalDescriptor = originalRelease.descriptor
        let originalLeg = originalDescriptor.leg
        let nextEntry = entry ?? originalArm.entryCondition
        let nextLeg = DeviceLeg(
            schemaVersion: originalLeg.schemaVersion,
            id: originalLeg.id,
            entryCondition: nextEntry,
            entryStepId: entryStepId ?? originalLeg.entryStepId,
            steps: steps ?? originalLeg.steps,
            routes: routes ?? originalLeg.routes,
            screens: screens ?? originalLeg.screens,
            reentry: reentry ?? originalLeg.reentry,
            entitlementGate: entitlementGate ?? originalLeg.entitlementGate,
            facts: factReferences ?? originalLeg.facts,
            inputs: inputs ?? originalLeg.inputs,
            outputs: originalLeg.outputs,
            completionOutputs: completionOutputs ?? originalLeg.completionOutputs
        )
        let descriptor = DeviceLegReleaseDescriptor(
            schemaVersion: originalDescriptor.schemaVersion,
            identity: originalDescriptor.identity,
            metadata: originalDescriptor.metadata,
            presentation: originalDescriptor.presentation,
            leg: nextLeg,
            products: originalDescriptor.products,
            placements: originalDescriptor.placements,
            viewModelValues: viewModelValues ?? originalDescriptor.viewModelValues,
            screenBehaviors: originalDescriptor.screenBehaviors,
            render: originalDescriptor.render,
            requirements: originalDescriptor.requirements,
            provenance: originalDescriptor.provenance
        )
        let release = AuthenticatedDeviceLegRelease(
            authenticatedKeyID: originalRelease.authenticatedKeyID,
            exactDescriptorBytes: originalRelease.exactDescriptorBytes,
            descriptorSHA256: originalRelease.descriptorSHA256,
            descriptor: descriptor,
            publishedAtSeqToPromote: originalRelease.publishedAtSeqToPromote
        )
        var releases = snapshot.releasesByDigest
        releases[originalRelease.descriptorSHA256] = release
        let arm = ArmedDeviceLeg(
            reference: originalArm.reference,
            binding: originalArm.binding,
            entryCondition: nextEntry,
            context: armContext ?? originalArm.context
        )
        let profile = JourneyPlaneProfile(
            schemaVersion: snapshot.profile.schemaVersion,
            status: snapshot.profile.status,
            delivery: snapshot.profile.delivery,
            features: snapshot.profile.features,
            facts: facts ?? snapshot.profile.facts,
            armedLegs: [arm],
            releases: snapshot.profile.releases
        )
        return .init(profile: profile, releasesByDigest: releases)
    }

    private func replacingRenderedArtifact(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        sceneBytes: Data
    ) throws -> DeviceLegProfileCatalog.Snapshot {
        let originalArm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let originalRelease = try XCTUnwrap(snapshot.releasesByDigest[
            originalArm.reference.descriptorSha256
        ])
        let originalDescriptor = originalRelease.descriptor
        var render = try XCTUnwrap(originalDescriptor.render)
        let sceneSHA256 = SHA256Provider.hexDigest(sceneBytes)
        render["riv"] = .object([
            "contentType": .string("application/vnd.rive"),
            "key": .string("renders/sha256/\(sceneSHA256).riv"),
            "sha256": .string(sceneSHA256),
            "sizeBytes": .number(Double(sceneBytes.count)),
        ])
        render["assets"] = .array([])
        let descriptor = DeviceLegReleaseDescriptor(
            schemaVersion: originalDescriptor.schemaVersion,
            identity: originalDescriptor.identity,
            metadata: originalDescriptor.metadata,
            presentation: originalDescriptor.presentation,
            leg: originalDescriptor.leg,
            products: originalDescriptor.products,
            placements: originalDescriptor.placements,
            viewModelValues: originalDescriptor.viewModelValues,
            screenBehaviors: originalDescriptor.screenBehaviors,
            render: render,
            requirements: originalDescriptor.requirements,
            provenance: originalDescriptor.provenance
        )
        let exactDescriptorBytes = try JSONEncoder().encode(descriptor)
        let descriptorSHA256 = SHA256Provider.hexDigest(exactDescriptorBytes)
        let release = AuthenticatedDeviceLegRelease(
            authenticatedKeyID: originalRelease.authenticatedKeyID,
            exactDescriptorBytes: exactDescriptorBytes,
            descriptorSHA256: descriptorSHA256,
            descriptor: descriptor,
            publishedAtSeqToPromote: originalRelease.publishedAtSeqToPromote
        )
        let arm = ArmedDeviceLeg(
            reference: .init(
                experienceId: originalArm.reference.experienceId,
                versionId: originalArm.reference.versionId,
                legId: originalArm.reference.legId,
                descriptorSha256: descriptorSHA256
            ),
            binding: originalArm.binding,
            entryCondition: originalArm.entryCondition,
            context: originalArm.context
        )
        let profile = JourneyPlaneProfile(
            schemaVersion: snapshot.profile.schemaVersion,
            status: snapshot.profile.status,
            delivery: snapshot.profile.delivery,
            features: snapshot.profile.features,
            facts: snapshot.profile.facts,
            armedLegs: [arm],
            releases: snapshot.profile.releases
        )
        return .init(
            profile: profile,
            releasesByDigest: [descriptorSHA256: release]
        )
    }

    private func replacingWithHeadlessArtifacts(
        _ snapshot: DeviceLegProfileCatalog.Snapshot
    ) throws -> DeviceLegProfileCatalog.Snapshot {
        let originalArm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let originalRelease = try XCTUnwrap(snapshot.releasesByDigest[
            originalArm.reference.descriptorSha256
        ])
        let originalDescriptor = originalRelease.descriptor
        let originalLeg = originalDescriptor.leg
        let leg = DeviceLeg(
            schemaVersion: originalLeg.schemaVersion,
            id: originalLeg.id,
            entryCondition: originalLeg.entryCondition,
            entryStepId: originalLeg.entryStepId,
            steps: originalLeg.steps,
            routes: originalLeg.routes,
            screens: [],
            reentry: originalLeg.reentry,
            entitlementGate: originalLeg.entitlementGate,
            facts: originalLeg.facts,
            inputs: originalLeg.inputs,
            outputs: originalLeg.outputs,
            completionOutputs: originalLeg.completionOutputs
        )
        let descriptor = DeviceLegReleaseDescriptor(
            schemaVersion: originalDescriptor.schemaVersion,
            identity: originalDescriptor.identity,
            metadata: originalDescriptor.metadata,
            presentation: originalDescriptor.presentation,
            leg: leg,
            products: originalDescriptor.products,
            placements: originalDescriptor.placements,
            viewModelValues: originalDescriptor.viewModelValues,
            screenBehaviors: [],
            render: nil,
            requirements: originalDescriptor.requirements,
            provenance: originalDescriptor.provenance
        )
        let exactDescriptorBytes = try JSONEncoder().encode(descriptor)
        let descriptorSHA256 = SHA256Provider.hexDigest(exactDescriptorBytes)
        let release = AuthenticatedDeviceLegRelease(
            authenticatedKeyID: originalRelease.authenticatedKeyID,
            exactDescriptorBytes: exactDescriptorBytes,
            descriptorSHA256: descriptorSHA256,
            descriptor: descriptor,
            publishedAtSeqToPromote: originalRelease.publishedAtSeqToPromote
        )
        let arm = ArmedDeviceLeg(
            reference: .init(
                experienceId: originalArm.reference.experienceId,
                versionId: originalArm.reference.versionId,
                legId: originalArm.reference.legId,
                descriptorSha256: descriptorSHA256
            ),
            binding: originalArm.binding,
            entryCondition: originalArm.entryCondition,
            context: originalArm.context
        )
        let profile = JourneyPlaneProfile(
            schemaVersion: snapshot.profile.schemaVersion,
            status: snapshot.profile.status,
            delivery: snapshot.profile.delivery,
            features: snapshot.profile.features,
            facts: snapshot.profile.facts,
            armedLegs: [arm],
            releases: snapshot.profile.releases
        )
        return .init(
            profile: profile,
            releasesByDigest: [descriptorSHA256: release]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitForPresentationActions(
        _ expectedCount: Int,
        presenter: RecordingDeviceLegPresenter
    ) async {
        for _ in 0..<100 {
            let count = await MainActor.run {
                presenter.presentationActions.count
            }
            if count >= expectedCount { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func removeTemporaryDirectoryIfPresent(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class DeviceLegArtifactRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private enum DeviceLegCommitRevocation {
    case execution
    case identity
}

private actor InspectingDeviceLegDispatcher: DeviceLegDispatching {
    private let directory: URL
    private let distinctId: String
    private var requests: [DeviceLegDispatchRequest] = []
    private var durableClaim = false

    init(directory: URL, distinctId: String) {
        self.directory = directory
        self.distinctId = distinctId
    }

    func dispatch(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        requests.append(request)
        if let journal = try? DeviceLegRunJournal(
            directory: directory,
            distinctId: distinctId
        ), let run = try? await journal.runs().first(where: {
            $0.id == request.runId
        }) {
            durableClaim = run.park == nil
                && run.effectReceipts[request.stepId] == request.effectId
        }
        return .outlet("next")
    }

    func onlyRequest() -> DeviceLegDispatchRequest? {
        requests.count == 1 ? requests[0] : nil
    }

    func observedDurableClaim() -> Bool { durableClaim }
}

private actor CaptureOnlyDeviceLegEvents: RoutedStableSystemEventCapturing {
    private var routed: [NuxieEvent] = []

    func captureSystemEvent(
        _ event: String,
        properties: sending [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> DurableTriggerCapture? {
        DurableTriggerCapture(event: NuxieEvent(
            id: eventId,
            name: event,
            distinctId: distinctId,
            properties: properties ?? [:]
        ))
    }

    func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest
    ) async -> DurableTriggerCapture? {
        let capture = DurableTriggerCapture(event: NuxieEvent(
            id: request.eventId,
            name: request.name,
            distinctId: request.distinctId,
            properties: request.properties ?? [:]
        ))
        routed.append(capture.event)
        return capture
    }

    func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest,
        admission: any StableEventCaptureCommitAdmission
    ) async -> DurableTriggerCapture? {
        let capture = DurableTriggerCapture(event: NuxieEvent(
            id: request.eventId,
            name: request.name,
            distinctId: request.distinctId,
            properties: request.properties ?? [:]
        ))
        let admitted = admission.commitIfCurrent {
            routed.append(capture.event)
            return StableEventCaptureCommit(
                outcome: .dropped,
                commitSequence: nil
            )
        }
        return admitted == nil ? nil : capture
    }

    func captureAndRouteSystemEventBatch(
        _ items: [RoutedStableSystemEventBatchItem],
        admission: any StableEventCaptureBatchCommitAdmission
    ) async -> [String: DurableTriggerCapture]? {
        let events = items.map { item in
            NuxieEvent(
                id: item.request.eventId,
                name: item.request.name,
                distinctId: item.request.distinctId,
                properties: item.request.properties ?? [:],
                timestamp: item.occurredAt
            )
        }
        let admitted = admission.commitBatchIfCurrent {
            routed.append(contentsOf: events)
            return []
        }
        guard admitted != nil else { return nil }
        return Dictionary(uniqueKeysWithValues: events.map {
            ($0.id, DurableTriggerCapture(event: $0))
        })
    }

    func routedNames() -> [String] {
        routed.map(\.name)
    }
}

private actor SuspendedDeviceLegDispatcher: DeviceLegDispatching {
    private let underlying: any DeviceLegDispatching
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(underlying: any DeviceLegDispatching) {
        self.underlying = underlying
    }

    func dispatch(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
        return await underlying.dispatch(request)
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor DeviceLegEmissionBatchRecorder {
    private var batches: [ScreenEmissionBatch] = []

    func accept(_ batch: ScreenEmissionBatch) -> Bool {
        batches.append(batch)
        return true
    }

    func invocationIds() -> [String] {
        batches.map(\.invocationId)
    }
}

@MainActor
private final class DeviceLegAppActionRecorder {
    private var actions: [AppAction] = []

    func record(_ action: AppAction) {
        actions.append(action)
    }

    func onlyAction() -> AppAction? {
        actions.count == 1 ? actions[0] : nil
    }
}

private actor SequencedFeatureAccess {
    private var values: [Bool]
    private var count = 0

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> FeatureAccess? {
        count += 1
        guard !values.isEmpty else { return nil }
        return FeatureAccess(
            allowed: values.removeFirst(),
            unlimited: true,
            balance: nil,
            type: .boolean
        )
    }

    func readCount() -> Int { count }
}

private actor PinnedReleaseAuthenticationRecorder {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int { value }
}

private actor DeviceLegScreenCommitGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private actor DeviceLegOutcomeCallRecorder {
    private var values: [(DeviceLegSurfaceOutcome, String?)] = []

    func record(outcome: DeviceLegSurfaceOutcome, screenId: String?) {
        values.append((outcome, screenId))
    }

    func count() -> Int {
        values.count
    }

    func onlyCall() -> (
        outcome: DeviceLegSurfaceOutcome,
        screenId: String?
    )? {
        guard values.count == 1 else { return nil }
        return values[0]
    }
}

private actor DeviceLegRevealRecorder {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int { value }
}

private actor DeviceLegResponsePersistenceProbe {
    private var values: [String?] = []

    func record(_ value: String?) {
        values.append(value)
    }

    func observations() -> [String?] {
        values
    }
}

@MainActor
private final class RecordingDeviceLegPresenter: DeviceLegPresenting {
    private final class Reservation:
        DeviceLegPresentationReservation,
        @unchecked Sendable {
        private weak var owner: RecordingDeviceLegPresenter?
        private var released = false

        init(owner: RecordingDeviceLegPresenter) {
            self.owner = owner
        }

        func release() {
            guard !released else { return }
            released = true
            owner?.releaseReservation()
        }
    }

    var available = true {
        didSet { refreshAvailability() }
    }
    var result = DeviceLegPresentationResult.shown
    var automaticallyRevealsShownPresentation = true
    var navigationResult = DeviceLegPresentationNavigationResult.navigated
    var actionResult = DeviceLegPresentationActionResult.handled
    var resolvedPurchasePlacementId: String?
    var presentHandler:
        ((DeviceLegPresentationRequest) async -> DeviceLegPresentationResult)?
    private(set) var request: DeviceLegPresentationRequest?
    private(set) var presentationRequests: [DeviceLegPresentationRequest] = []
    private(set) var navigationScreenIds: [String] = []
    private(set) var resolvedActionSources: [ScreenEmissionSource?] = []
    private(set) var presentationActions: [(
        journeyId: String,
        ownerDistinctId: String,
        action: [String: ExperienceReleaseJSONValue],
        effectId: String
    )] = []
    private(set) var finishedOwners: [(journeyId: String, ownerDistinctId: String)] = []
    private(set) var shutdownOwners: [String] = []
    var onFinish: (() -> Void)?
    var onNavigate: ((String) -> Void)?
    private var activeOwner: DeviceLegPresentationOwner?
    private var reservationPending = false
    private var availabilityWasOpen = true
    private var availabilityHandler: (@MainActor @Sendable () -> Void)?

    func setDeviceLegPresentationAvailabilityHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        availabilityHandler = handler
        availabilityWasOpen = capacityIsOpen
    }

    func reserveDeviceLegPresentation(
        ownerDistinctId: String
    ) -> (any DeviceLegPresentationReservation)? {
        _ = ownerDistinctId
        guard capacityIsOpen else { return nil }
        reservationPending = true
        refreshAvailability()
        return Reservation(owner: self)
    }

    func ownsDeviceLegPresentation(
        owner: DeviceLegPresentationOwner
    ) -> Bool {
        activeOwner == owner
    }

    func presentDeviceLeg(
        _ request: DeviceLegPresentationRequest
    ) async -> DeviceLegPresentationResult {
        self.request = request
        presentationRequests.append(request)
        let resolvedResult = if let presentHandler {
            await presentHandler(request)
        } else {
            result
        }
        if resolvedResult == .shown {
            activeOwner = request.owner
            if automaticallyRevealsShownPresentation {
                await request.onPresentationRevealed()
            }
        }
        return resolvedResult
    }

    func navigateDeviceLegPresentation(
        owner: DeviceLegPresentationOwner,
        screenId: String,
        transition: ExperienceReleaseJSONValue?
    ) async -> DeviceLegPresentationNavigationResult {
        _ = transition
        navigationScreenIds.append(screenId)
        onNavigate?(screenId)
        guard let activeOwner else {
            return .noPresentation
        }
        guard activeOwner == owner else {
            return .declined
        }
        return navigationResult
    }

    func resolveDeviceLegPresentationAction(
        owner: DeviceLegPresentationOwner,
        action: [String: ExperienceReleaseJSONValue],
        source: ScreenEmissionSource?
    ) -> [String: ExperienceReleaseJSONValue]? {
        resolvedActionSources.append(source)
        guard activeOwner == owner else {
            return nil
        }
        guard case .string("purchase")? = action["type"] else {
            return action
        }
        guard let placementId = resolvedPurchasePlacementId
                ?? deviceLegPresentationLiteralString(action["placementId"])
        else { return action }
        var resolved = action
        resolved["placementId"] = .string(placementId)
        return resolved
    }

    func dispatchDeviceLegPresentationAction(
        owner: DeviceLegPresentationOwner,
        action: [String: ExperienceReleaseJSONValue],
        effectId: String
    ) async -> DeviceLegPresentationActionResult {
        presentationActions.append((
            journeyId: owner.journeyId,
            ownerDistinctId: owner.distinctId,
            action: action,
            effectId: effectId
        ))
        guard let activeOwner else {
            return .noPresentation
        }
        guard activeOwner == owner else {
            return .declined
        }
        return actionResult
    }

    func finishDeviceLegPresentation(
        owner: DeviceLegPresentationOwner
    ) async {
        finishedOwners.append((owner.journeyId, owner.distinctId))
        onFinish?()
        guard activeOwner == owner else { return }
        activeOwner = nil
        refreshAvailability()
    }

    func shutdownDeviceLegPresentation(ownerDistinctId: String) async {
        shutdownOwners.append(ownerDistinctId)
        if activeOwner?.distinctId == ownerDistinctId {
            activeOwner = nil
            refreshAvailability()
        }
    }

    func dropPresentationOwnershipForRelaunch() {
        activeOwner = nil
        reservationPending = false
        availabilityWasOpen = capacityIsOpen
    }

    private var capacityIsOpen: Bool {
        available && !reservationPending && activeOwner == nil
    }

    private func releaseReservation() {
        reservationPending = false
        availabilityWasOpen = capacityIsOpen
    }

    private func refreshAvailability() {
        let isOpen = capacityIsOpen
        guard isOpen != availabilityWasOpen else { return }
        availabilityWasOpen = isOpen
        if isOpen {
            availabilityHandler?()
        }
    }
}
