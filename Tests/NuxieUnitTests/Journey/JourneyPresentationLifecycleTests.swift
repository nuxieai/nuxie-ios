import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyPresentationLifecycleTests: JourneyTestCase {
    func testHostDismissalAcknowledgesAnAlreadyRetiredJourney() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity, events: events, directory: directory,
            presenter: presenter
        )
        await service.initialize()
        await service.profileDidCommit(
            renderedDismissalCompletionSnapshot(base), distinctId: "customer"
        )
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        let completed = await request.onScreenDismissed("screen_welcome", nil, "user")
        XCTAssertEqual(completed, .completed)
        let journal = try JourneyRunJournal(directory: directory, distinctId: "customer")
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)

        let acknowledged = await request.onOutcome(.dismissed, "screen_welcome")
        XCTAssertTrue(acknowledged, "Host teardown must settle after the Journey has retired")
        XCTAssertEqual(events.routedEvents.filter {
            $0.name == JourneyEvents.journeyCompleted
        }.count, 1)
    }

    func testRenderedScreenLifecycleEventsAreDurablyRoutedWithJourneyAttribution() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
            JourneyEvents.journeyStarted,
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedDismissalCompletionSnapshot(base)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
            $0.name == JourneyEvents.journeyCompleted
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let base = try await authenticatedRenderedSnapshot(fixture)
        let snapshot = renderedDismissalCompletionSnapshot(base)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        events.preparedTriggerBeforeSend = { event in
            event.name == SystemEventNames.screenDismissed ? nil : event
        }
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
            $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "host_dismissed"
        )
        let journal = try JourneyRunJournal(
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
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
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
            $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "host_dismissed"
        )
        let journal = try JourneyRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
    }

    func testBeforeSendRenameIntoScreenDismissalRouteAdvances() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
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
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
            $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "screen_dismissed"
        )
    }

    func testBeforeSendLifecyclePropertyRewriteDrivesRoutedControl() async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(
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
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
            $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "transformed"
        )
    }

    func testRenderedRouteNavigatesWithinTheOwnedSurfaceWithoutPresentingAgain() async throws {
        try await assertNavigationRemainsInteractive(policy: nil)
    }

    func testConversionKeepsTheVisibleDevicePortionInteractiveWithExitEnabled() async throws {
        try await assertNavigationAfterConversion(exitEnabled: true)
    }

    func testConversionKeepsTheVisibleDevicePortionInteractiveWithExitDisabled() async throws {
        try await assertNavigationAfterConversion(exitEnabled: false)
    }

    private func assertNavigationAfterConversion(exitEnabled: Bool) async throws {
        let exits = exitEnabled ? #"[{"type":"goal_met"}]"# : "[]"
        let policy = try ExactJSONCodec.decode(Journey.Policy.self, from: Data((
            #"{"entry":{"trigger":{"type":"event","eventName":"$app_opened"},"frequency":{"type":"one_time"}},"goal":{"criterion":{"type":"event","eventName":"reading_completed"},"attribution":{"basis":"first_shown","window":{"amount":1,"unit":"hour"}}},"exitWhenAny":"# + exits + "}"
        ).utf8))
        try await assertNavigationRemainsInteractive(policy: policy)
    }

    private func assertNavigationRemainsInteractive(policy: Journey.Policy?) async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(renderedNavigationSnapshot(
            try await authenticatedRenderedSnapshot(fixture)
        ), policy: policy)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: MockDateProvider(initialDate: Date()),
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let presentedRequest = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(presentedRequest)
        if policy != nil {
            // The real presenter captures this event after display. This presenter
            // records surface ownership only, so provide that boundary evidence.
            _ = await events.captureAndRouteSystemEvent(.init(
                name: JourneyEvents.experienceShown,
                properties: [
                    "journey_id": request.owner.journeyId,
                    "experience_id": "experience_golden",
                    "experience_version_id": "version_golden",
                ],
                eventId: "presentation-shown", distinctId: "customer"
            ))
            _ = await events.captureAndRouteSystemEvent(.init(
                name: "reading_completed", properties: nil,
                eventId: "reading-outcome", distinctId: "customer"
            ))
            let outcome = try XCTUnwrap(events.routedEvents.first { $0.id == "reading-outcome" })
            await service.handleEvent(outcome)
            let journal = try JourneyRunJournal(directory: directory, distinctId: "customer")
            let watches = try await journal.conversionWatches()
            XCTAssertEqual(watches[request.owner.journeyId]?.conversion?.eventId, "reading-outcome")
            let finished = await MainActor.run { presenter.finishedOwners.count }
            let shutdown = await MainActor.run { presenter.shutdownOwners.count }
            XCTAssertEqual(finished, 0)
            XCTAssertEqual(shutdown, 0)
        }
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
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
            let value = RecordingJourneyPresenter()
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
        events.addEventHandler(pattern: JourneyEvents.journeyCompleted) { _ in
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
            $0.name == JourneyEvents.journeyCompleted
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = renderedNavigationSnapshot(
            try await authenticatedRenderedSnapshot(fixture)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
        let journal = try JourneyRunJournal(
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
            $0.name == JourneyEvents.journeyCompleted
        })
    }

    func testRenderedNativeActionsBypassTheGenericDispatcher() async throws {
        let fixtures: [(
            type: String,
            action: [String: JourneyReleaseJSONValue]
        )] = [
            ("back", [
                "type": .string("back"),
                "steps": .number(1),
            ]),
            ("purchase", [
                "type": .string("purchase"),
                "placementId": .object(["literal": .string("golden:monthly")]),
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
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)

        for (index, actionFixture) in fixtures.enumerated() {
            let directory = temporaryDirectory()
            defer { removeTemporaryDirectoryIfPresent(directory) }
            let actionStep = Journey.Step(
                kind: .action,
                id: "native_action",
                action: actionFixture.action,
                outlets: ["next": "done"],
                outcome: nil
            )
            var snapshot = replacing(
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
            if actionFixture.type == "purchase" {
                snapshot = try addingPurchaseOffer(snapshot)
            }
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let dispatcher = InspectingJourneyDispatcher(
                directory: directory,
                distinctId: "customer"
            )
            let presenter = await MainActor.run {
                RecordingJourneyPresenter()
            }
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                featureAccess: { _ in .notFound },
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
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)
        let actionStep = Journey.Step(
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
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            presenter: presenter
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let journal = try JourneyRunJournal(
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
        let fixture = try JourneyPlaneProfileTestFixture.load(
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
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
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
        events.addEventHandler(pattern: JourneyEvents.journeyCompleted) { _ in
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
            $0.name == JourneyEvents.journeyCompleted
        })
        XCTAssertEqual(
            completion.properties["outcome"] as? String,
            "permission_granted"
        )
        let journal = try JourneyRunJournal(
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
            action: [String: JourneyReleaseJSONValue],
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
                ["placement_id": "golden:monthly"],
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
                ["placement_id": "golden:monthly"],
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
                ["placement_id": "golden:monthly"],
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
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let base = try await authenticatedRenderedSnapshot(fixture)

        for (index, actionFixture) in fixtures.enumerated() {
            let directory = temporaryDirectory()
            defer { removeTemporaryDirectoryIfPresent(directory) }
            let actionStep = Journey.Step(
                kind: .action,
                id: "commerce",
                action: actionFixture.action,
                outlets: [actionFixture.outlet: "done"],
                outcome: nil
            )
            var snapshot = replacing(
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
            if actionFixture.type == "purchase" {
                snapshot = try addingPurchaseOffer(snapshot)
            }
            let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
            let release = try XCTUnwrap(snapshot.releasesByDigest[
                arm.reference.descriptorSha256
            ])
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            let dispatcher = InspectingJourneyDispatcher(
                directory: directory,
                distinctId: "customer"
            )
            let presenter = await MainActor.run {
                let value = RecordingJourneyPresenter()
                value.actionResult = .awaitingOutcome
                if actionFixture.type == "purchase" {
                    value.resolvedPurchasePlacementId = "golden:monthly"
                }
                return value
            }
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                featureAccess: { _ in .notFound },
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
            let journal = try JourneyRunJournal(
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
                XCTAssertEqual(resolvedPlacement, "golden:monthly")
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
                        "placement_id": "golden:monthly",
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
                            payload: ["placement_id": .string("golden:monthly")]
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
                $0.name == JourneyEvents.journeyCompleted
            }
            XCTAssertEqual(completionEvents.count, 1, actionFixture.type)
            XCTAssertEqual(
                completionEvents.first?.properties["outcome"] as? String,
                actionFixture.outcome
            )
        }
    }

    func testBackNavigationRechecksOfferAccessBeforeRevealingTheTarget() async throws {
        for decision in ["owned", "unknown", "eligible"] {
            let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
            let base = try await authenticatedRenderedSnapshot(fixture)
            let leg = try XCTUnwrap(base.releasesByDigest.values.first).descriptor.leg
            let snapshot = replacing(
                base,
                offers: [.init(screenId: "screen_welcome", placementIds: ["golden:monthly"],
                               alreadyEntitledStepId: "owned", unknownStepId: "unknown")],
                products: [releaseProductDocument(id: "monthly", storeProductId: "com.example.pro", featureIds: ["premium"])],
                steps: leg.steps + [
                    .init(kind: .action, id: "back", action: ["type": .string("back")], outlets: [:], outcome: nil),
                    .init(kind: .complete, id: "owned", action: nil, outlets: nil, outcome: "owned"),
                    .init(kind: .complete, id: "unknown", action: nil, outlets: nil, outcome: "unknown"),
                ],
                routes: leg.routes + [
                    .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: "go_back", entryStepId: "back"),
                    .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.alreadyEntitledEvent, entryStepId: "owned"),
                    .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.accessUnknownEvent, entryStepId: "unknown"),
                ]
            )
            // The first check admits the offer. Access changes while the user
            // has a presentation open, before a back action targets that offer.
            let access = SequencedFeatureAccess(decision == "unknown" ? [false] : [false, decision == "owned"])
            let context = try await makeRenderedJourneyTestContext(snapshot: snapshot,
                featureAccess: { _ in await access.next() })
            defer { removeTemporaryDirectoryIfPresent(context.directory) }
            await context.service.profileDidCommit(snapshot, distinctId: "customer")
            let presented = await MainActor.run { context.presenter.request }
            let request = try XCTUnwrap(presented)
            let initialNavigations = await MainActor.run {
                context.presenter.actionResult = .navigate(screenId: "screen_welcome")
                return context.presenter.navigationScreenIds.count
            }
            let accepted = await request.onEmissionBatch(presentationBatch(
                request: request,
                invocationId: "back-offer-\(decision)",
                emissions: [.init(id: "00000000-0000-7000-8000-000000000901", sequence: 0,
                    occurredAt: "2026-08-29T12:00:00Z", name: "go_back", payload: [:])]
            ))
            XCTAssertTrue(accepted)
            for _ in 0..<200 {
                let settled = await MainActor.run {
                    context.presenter.cancelledBackNavigations > 0 ||
                        context.presenter.navigationScreenIds.count > initialNavigations
                }
                if settled { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let navigations = await MainActor.run { context.presenter.navigationScreenIds.count }
            let cancellations = await MainActor.run { context.presenter.cancelledBackNavigations }
            let checks = await access.readCount()
            XCTAssertEqual(checks, 2, decision)
            XCTAssertEqual(navigations - initialNavigations, decision == "eligible" ? 1 : 0, decision)
            XCTAssertEqual(cancellations, decision == "eligible" ? 0 : 1, decision)
            if decision != "eligible" {
                // Completed runs may already be retired after their reports
                // are queued. The durable checkmark owns the final outcome.
                let experienceId = snapshot.profile.armedLegs[0].reference.experienceId
                for _ in 0..<200 {
                    if try await context.journal.checkmark(experienceId: experienceId)?.outcome == decision { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let checkmark = try await context.journal.checkmark(experienceId: experienceId)
                XCTAssertEqual(checkmark?.outcome, decision)
            }
        }
    }

    private func addingPurchaseOffer(_ snapshot: JourneyProfileCatalog.Snapshot) throws -> JourneyProfileCatalog.Snapshot {
        let leg = try XCTUnwrap(snapshot.releasesByDigest.values.first).descriptor.leg
        return replacing(
            snapshot,
            offers: [.init(screenId: "screen_welcome", placementIds: ["golden:monthly"],
                           alreadyEntitledStepId: "skip_offer", unknownStepId: "skip_offer")],
            products: [releaseProductDocument(id: "monthly", storeProductId: "com.example.pro", featureIds: ["premium"])],
            steps: leg.steps + [
                .init(kind: .action, id: "skip_offer", action: ["type": .string("dismiss")], outlets: ["next": "offer_skipped"], outcome: nil),
                .init(kind: .complete, id: "offer_skipped", action: nil, outlets: nil, outcome: "skipped"),
            ],
            routes: leg.routes + [
                .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.alreadyEntitledEvent, entryStepId: "skip_offer"),
                .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.accessUnknownEvent, entryStepId: "skip_offer"),
            ]
        )
    }

}
