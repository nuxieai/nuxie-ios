import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class DeviceLegEffectExecutionTests: DeviceLegTestCase {
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
}
