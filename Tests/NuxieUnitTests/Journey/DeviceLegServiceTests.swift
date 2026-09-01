import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class DeviceLegServiceTests: XCTestCase {
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
        let admitted = try await journal.admit(
            arm: arm,
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

    private func authenticatedSnapshot(
        _ fixture: DeviceLegPlaneProfileTestFixture
    ) async throws -> DeviceLegProfileCatalog.Snapshot {
        let catalog = DeviceLegProfileCatalog(
            authorizationKeys: [ExperiencePackageAuthorizationKey(
                keyID: "TEST_ONLY_DEV_KEYPAIR",
                ed25519PublicKeyBytes: fixture.publicKey
            )],
            supportedRuntime: ExperienceReleaseRuntime.current,
            highWaterStore: InMemoryExperienceReleaseHighWaterStore()
        )
        let prepared = try await catalog.prepare(fixture.profile)
        _ = try await catalog.commit(prepared, distinctId: "customer")
        let snapshot = await catalog.snapshot(distinctId: "customer")
        return try XCTUnwrap(snapshot)
    }

    private func makeService(
        identity: MockIdentityService,
        events: MockEventLog,
        directory: URL,
        dateProvider: DateProviderProtocol = MockDateProvider(),
        featureAccess: @escaping DeviceLegService.FeatureAccessLookup = { _ in nil },
        dispatcher: (any DeviceLegDispatching)? = nil
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
            timezones: SignedTimezoneBundle.installed!,
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
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
        steps: [DeviceLeg.Step]? = nil
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
            routes: originalLeg.routes,
            screens: originalLeg.screens,
            reentry: reentry ?? originalLeg.reentry,
            entitlementGate: entitlementGate ?? originalLeg.entitlementGate,
            facts: originalLeg.facts,
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
            viewModelValues: originalDescriptor.viewModelValues,
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
        return .init(profile: profile, releasesByDigest: releases)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
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
