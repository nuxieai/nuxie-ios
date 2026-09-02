import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class DeviceLegPresentationLifecycleTests: DeviceLegTestCase {
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
}
