import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyAdmissionRecoveryTests: JourneyTestCase {
    func testRenderedArmWaitsForActiveForegroundBeforeAdmission() async throws {
        let context = try await makeRenderedJourneyTestContext()
        defer { removeTemporaryDirectoryIfPresent(context.directory) }
        await context.service.onAppDidEnterBackground()

        await context.service.profileDidCommit(
            context.snapshot,
            distinctId: "customer"
        )

        XCTAssertTrue(context.events.routedEvents.isEmpty)
        let backgroundRequest = await MainActor.run {
            context.presenter.request
        }
        XCTAssertNil(backgroundRequest)

        await context.service.onAppWillEnterForeground()
        await context.service.onAppBecameActive()

        XCTAssertEqual(context.events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
        ])
        let foregroundRequest = await MainActor.run {
            context.presenter.request
        }
        XCTAssertEqual(foregroundRequest?.screenId, "screen_welcome")
    }

    func testEveryTimeForegroundArmReopensOnEachForegroundAndLaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
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
                    $0 == JourneyEvents.journeyStarted
                        || $0 == JourneyEvents.journeyCompleted
                }.count,
                2
            )

            await service.onAppDidEnterBackground()
            await service.onAppWillEnterForeground()
            await service.onAppBecameActive()
            XCTAssertEqual(
                events.routedEvents.map(\.name).filter {
                    $0 == JourneyEvents.journeyStarted
                        || $0 == JourneyEvents.journeyCompleted
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
                $0 == JourneyEvents.journeyStarted
                    || $0 == JourneyEvents.journeyCompleted
            }.count,
            6
        )
    }

    func testProfileWithdrawalReopensStateArmAdmissionForRedelivery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
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
        await service.profileDidWithdraw(
            authority: nil,
            distinctId: "customer"
        )
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyStarted
                    || $0 == JourneyEvents.journeyCompleted
            }.count,
            4
        )
    }

    func testStaleSameCustomerWithdrawalCannotRevokeANewerProfile() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "new-profile-event",
                segmentId: nil,
                member: nil,
                condition: nil
            )
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
            snapshot,
            artifacts: nil,
            authority: fixture.deliveryAuthority,
            admissionGeneration: 2,
            distinctId: "customer"
        )
        await service.profileDidWithdraw(
            authority: fixture.deliveryAuthority,
            admissionGeneration: 1,
            distinctId: "customer"
        )
        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000090",
            name: "new-profile-event",
            distinctId: "customer"
        ))

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
            JourneyEvents.journeyCompleted,
        ])
    }

    func testDepartingCustomerWithdrawalCannotRevokeTheCurrentCustomer() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "current-customer-event",
                segmentId: nil,
                member: nil,
                condition: nil
            )
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        identity.setDistinctId("customer-b")
        await service.handleUserChange(
            from: "customer-a",
            to: "customer-b"
        )
        await service.profileDidCommit(
            snapshot,
            artifacts: nil,
            authority: fixture.deliveryAuthority,
            admissionGeneration: 3,
            distinctId: "customer-b"
        )
        // Even a numerically newer token cannot authorize a callback for an
        // identity that has already departed.
        await service.profileDidWithdraw(
            authority: fixture.deliveryAuthority,
            admissionGeneration: 4,
            distinctId: "customer-a"
        )
        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000091",
            name: "current-customer-event",
            distinctId: "customer-b"
        ))

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
            JourneyEvents.journeyCompleted,
        ])
        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.distinctId == "customer-b"
        })
    }

    func testDepartingClearAndReplacementProfileCanShareOneTransportGeneration() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "replacement-profile-event",
                segmentId: nil,
                member: nil,
                condition: nil
            )
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        identity.setDistinctId("customer-b")
        await service.profileDidClear(
            distinctId: "customer-a",
            admissionGeneration: 5
        )
        await service.profileDidCommit(
            snapshot,
            artifacts: nil,
            authority: fixture.deliveryAuthority,
            admissionGeneration: 5,
            distinctId: "customer-b"
        )
        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000092",
            name: "replacement-profile-event",
            distinctId: "customer-b"
        ))

        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyStarted,
            JourneyEvents.journeyCompleted,
        ])
        XCTAssertTrue(events.routedEvents.allSatisfy {
            $0.distinctId == "customer-b"
        })
    }

    func testEventArmsAreEdgesAndProjectOnlyDeclaredEventFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let eventField: [String: JourneyReleaseJSONValue] = [
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
            $0.name == JourneyEvents.journeyStarted
                || $0.name == JourneyEvents.journeyCompleted
        }
        XCTAssertEqual(lifecycle.map(\.name), [
            JourneyEvents.journeyStarted,
            JourneyEvents.journeyCompleted,
            JourneyEvents.journeyStarted,
            JourneyEvents.journeyCompleted,
        ])
        let completionOutputs = try lifecycle
            .filter { $0.name == JourneyEvents.journeyCompleted }
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
        let fixture = try JourneyPlaneProfileTestFixture.load()
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
                $0 == JourneyEvents.journeyStarted
                    || $0 == JourneyEvents.journeyCompleted
            },
            [JourneyEvents.journeyStarted, JourneyEvents.journeyCompleted]
        )
    }

    func testStartRechecksEntryConditionAfterSuspendingGates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
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
        let journal = try JourneyRunJournal(
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
        let fixture = try JourneyPlaneProfileTestFixture.load()
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

    func testEntitlementGateWaitsForStoreKitAndSuppressesAnOwnedGrant() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entitlementGate: .init(enabled: true, products: [
                .init(productId: "pro", featureIds: ["premium"])
            ]),
            products: [
                releaseProductDocument(
                    id: "pro",
                    storeProductId: "com.example.pro",
                    featureIds: ["premium"]
                ),
                releaseProductDocument(
                    id: "pro-plus",
                    storeProductId: "com.example.pro-plus",
                    featureIds: ["premium", "plus"]
                ),
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let lookupGate = JourneyScreenCommitGate()
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            storeEntitlements: {
                await lookupGate.suspend()
                return ["com.example.pro-plus"]
            }
        )

        await service.initialize()
        let commit = Task {
            await service.profileDidCommit(snapshot, distinctId: "customer")
        }
        await lookupGate.waitUntilEntered()
        XCTAssertTrue(events.routedEvents.isEmpty)

        await lookupGate.release()
        await commit.value

        XCTAssertTrue(events.routedEvents.isEmpty)
    }

    func testProfileWithdrawalKeepsAParkedRunAcrossRelaunchUntilItsPinnedContinuationCompletes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let delay = Journey.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
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
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000))
        let journal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        do {
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                dateProvider: now,
                pinnedReleaseAuthenticator: { _, _ in retained }
            )

            await service.initialize()
            await service.profileDidCommit(snapshot, distinctId: "customer")

            let parked = try await journal.runs()
            XCTAssertEqual(parked.count, 1)
            XCTAssertNotNil(parked.first?.park)
            XCTAssertEqual(events.routedEvents.map(\.name), [
                JourneyEvents.journeyStarted,
            ])

            await service.profileDidWithdraw(
                authority: nil,
                distinctId: "customer"
            )

            let retainedRuns = try await journal.runs()
            XCTAssertEqual(retainedRuns.count, 1)
            XCTAssertNotNil(retainedRuns.first?.park)
            XCTAssertEqual(events.routedEvents.count, 1)
        }

        now.advance(by: 61)
        let relaunched = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: now,
            pinnedReleaseAuthenticator: { _, _ in retained }
        )
        await relaunched.initialize()

        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "continue")
    }

    func testNewUserProfileRetiresTheOldJournalBeforeQueuedTransitionWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let delay = Journey.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
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
        let oldJournal = try JourneyRunJournal(
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
                && $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            oldCompletion.properties["outcome"] as? String,
            "abandoned"
        )
        let newJournal = try JourneyRunJournal(
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
        let fixture = try JourneyPlaneProfileTestFixture.load()
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
        let oldJournal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer-a"
        )
        let initialRuns = try await oldJournal.runs()
        XCTAssertEqual(initialRuns.count, 1)

        let root = directory.appendingPathComponent(
            "journey-journal-v1",
            isDirectory: true
        )
        let customerDigest = JourneyStorageScope.testFixture.customerDigest(
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
                && $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            abandoned.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testIdentitySwitchRetainsRevokedJournalUntilAbandonmentCaptureIsDurable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
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
        let oldJournal = try JourneyRunJournal(
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
                && $0.name == JourneyEvents.journeyCompleted
        })

        // A later profile callback is the ordinary retry boundary. Once the
        // old completion is in EventLog, the new customer's journal may open.
        await service.profileDidCommit(snapshot, distinctId: "customer-b")

        let retiredRuns = try await oldJournal.runs()
        XCTAssertTrue(retiredRuns.isEmpty)
        let abandonments = events.routedEvents.filter {
            $0.distinctId == "customer-a"
                && $0.name == JourneyEvents.journeyCompleted
        }
        XCTAssertEqual(abandonments.count, 1)
        XCTAssertEqual(
            abandonments.first?.properties["outcome"] as? String,
            "abandoned"
        )
    }

    func testWithdrawnFirstProfileOpensScopedJournalAndResumesDueParkedRun() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [
                .init(
                    kind: .action,
                    id: "wait",
                    action: [
                        "type": .string("delay"),
                        "durationMs": .number(1_000),
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
        let retainedRelease = try XCTUnwrap(
            snapshot.releasesByDigest.values.first
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let storageScope = JourneyStorageScope(
            authority: fixture.deliveryAuthority
        )
        let journal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer",
            storageScope: storageScope
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let releasePin = try XCTUnwrap(snapshot.profile.releases.first)
        let admitted = try await journal.admit(
            arm: arm,
            release: releasePin,
            executionSnapshot: .init(
                delivery: snapshot.profile.delivery,
                assignments: snapshot.profile.facts.assignments
            ),
            reentry: .init(type: .oneTime, windowSeconds: nil),
            entryStepId: "wait",
            at: Date(timeIntervalSince1970: 1_000)
        )
        let run = try XCTUnwrap(admitted)
        try await JourneyReporter(journal: journal, events: events)
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
            storageScope: nil,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 1_002)
            ),
            pinnedReleaseAuthenticator: { _, _ in retainedRelease }
        )

        await service.initialize()
        let beforeAuthority = try await journal.runs()
        XCTAssertEqual(beforeAuthority.count, 1)

        await service.profileDidWithdraw(
            authority: fixture.deliveryAuthority,
            admissionGeneration: 1,
            distinctId: "customer"
        )

        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last {
            $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(completion.properties["outcome"] as? String, "continue")
    }

    func testRecoveryResumesOnlyThePersistedDueParkPoint() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let delay = Journey.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(1_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
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
        let journal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let releasePin = try XCTUnwrap(snapshot.profile.releases.first)
        let admitted = try await journal.admit(
            arm: arm,
            release: releasePin,
            executionSnapshot: .init(
                delivery: snapshot.profile.delivery,
                assignments: snapshot.profile.facts.assignments
            ),
            reentry: .init(type: .oneTime, windowSeconds: nil),
            entryStepId: "wait",
            at: Date(timeIntervalSince1970: 1_000)
        )
        let run = try XCTUnwrap(admitted)
        try await JourneyReporter(journal: journal, events: events)
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
            $0 == JourneyEvents.journeyStarted
                || $0 == JourneyEvents.journeyCompleted
        }, [JourneyEvents.journeyStarted, JourneyEvents.journeyCompleted])
    }

    func testProfileReplacementResumesADueRunFromItsAuthenticatedReleasePin() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let delay = Journey.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(1_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
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
        let journal = try JourneyRunJournal(
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
        XCTAssertEqual(completion.name, JourneyEvents.journeyCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "continue")
    }

    func testDueRenderedRunCompletesWithoutPresentationCapacity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [
                .init(
                    kind: .action,
                    id: "wait",
                    action: [
                        "type": .string("delay"),
                        "durationMs": .number(1_000),
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
        let now = MockDateProvider(
            initialDate: Date(timeIntervalSince1970: 1_000)
        )
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: now,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let journal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let parkedRuns = try await journal.runs()
        XCTAssertNotNil(parkedRuns.first?.park)

        await MainActor.run { presenter.available = false }
        now.advance(by: 2)
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let completedRuns = try await journal.runs()
        XCTAssertTrue(completedRuns.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "continue")
        let requests = await MainActor.run { presenter.presentationRequests }
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnsupportedInjectedEffectAbandonsInsteadOfCreatingResumePoint() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let unsupported = Journey.Step(
            kind: .action,
            id: "future",
            action: ["type": .string("future_action")],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
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
        let journal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer"
        )

        let remainingRuns = try await journal.runs()
        XCTAssertTrue(remainingRuns.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "abandoned")
    }

    func testDueRunAbandonsWhenItsReleasePinCannotAuthenticateAfterProfileReplacement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let delay = Journey.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = Journey.Step(
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
                throw JourneyReleaseAuthenticationError.invalidSignature
            }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let journal = try JourneyRunJournal(
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
        XCTAssertEqual(completion.name, JourneyEvents.journeyCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "abandoned")
        let outputs = try XCTUnwrap(
            completion.properties["outputs"] as? [String: Any]
        )
        let responses = try XCTUnwrap(outputs["responses"] as? [String: Any])
        XCTAssertEqual(responses["answer"] as? String, "retained")
    }
}
