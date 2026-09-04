import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyRuntimeDelegateTests: JourneyTestCase {
    func testRuntimeDelegateForwardsScopedPresentationTraceMilestones() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let recorder = InMemoryExperiencePresentationTrace()
        let attempt = ExperiencePresentationAttempt(
            id: "journey-presentation",
            triggerEvent: "upgrade_tapped",
            startedAt: Date(timeIntervalSince1970: 10),
            startedAtMonotonicTime: 100
        )
        let request = JourneyPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-trace",
                distinctId: "customer-trace"
            ),
            reservation: nil,
            presentationTraceContext: .init(
                attempt: attempt,
                recorder: recorder
            ),
            onEmissionBatch: { _ in true },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let token = try await MainActor.run {
            try XCTUnwrap(delegate.activePresentationTraceToken)
        }

        await MainActor.run {
            delegate.experienceViewControllerDidBecomeReady(
                controller,
                traceToken: .init(id: UUID())
            )
            delegate.experienceViewControllerDidBecomeReady(
                controller,
                traceToken: token
            )
            delegate.experienceViewControllerDidPresentShell(
                controller,
                traceToken: token
            )
        }
        await delegate.experienceViewControllerDidReveal(
            controller,
            traceToken: token
        )
        await MainActor.run {
            delegate.experienceViewController(
                controller,
                didPresentDrawable: .init(
                    presentedTime: 101,
                    frameNumber: 7,
                    pixelWidth: 20,
                    pixelHeight: 30,
                    drawCalls: 4,
                    provenance: .injectedTestObserver
                ),
                screenId: "screen_welcome",
                frameNumber: 7,
                traceToken: token
            )
            delegate.experienceViewController(
                controller,
                didAcceptPointerInput: .init(eventCount: 2),
                screenId: "screen_welcome",
                traceToken: token
            )
            delegate.experienceViewControllerDidFinishPresentation(
                controller,
                traceToken: token
            )
        }

        XCTAssertEqual(recorder.events(for: attempt.id).map(\.stage), [
            .runtimeReady,
            .shellPresented,
            .revealed,
            .firstPresentedDrawable(
                screenId: "screen_welcome",
                frameNumber: 7,
                pixels: 600,
                drawCalls: 4,
                provenance: .injectedTestObserver
            ),
            .firstAcceptedInput(screenId: "screen_welcome", eventCount: 2),
            .presentationCleanupCompleted,
        ])
    }

    func testRuntimeDelegateProvidesIntroEligibilityAuthorizationForItsOwner() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
        }
        let provider = delegate as any IntroEligibilityAuthorizationContextProviding

        XCTAssertEqual(
            provider.introEligibilityAuthorizationContext,
            IntroEligibilityAuthorizationContext(
                distinctId: "customer-authority",
                journeyId: "journey-authority",
                legId: release.descriptor.leg.id,
                descriptorSha256: release.descriptorSHA256
            )
        )
    }

    func testRuntimeDelegateReportsInitialRevealAndLaterVisibleScreenChanges() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let reveals = JourneyRevealRecorder()
        let request = JourneyPresentationRequest(
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
            onPresentationRevealed: { _ in
                await reveals.record()
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(
            entryKey: "renderedEntry"
        )
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = JourneyScreenCommitGate()
        let request = JourneyPresentationRequest(
            release: release,
            delivery: snapshot.profile.delivery,
            screenId: "screen_welcome",
            owner: .init(
                journeyId: "journey-reveal-join",
                distinctId: "customer-reveal-join"
            ),
            reservation: nil,
            onEmissionBatch: { _ in true },
            onPresentationRevealed: { _ in
                await gate.suspend()
            },
            onOutcome: { _, _ in true }
        )
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let completion = JourneyCompletionFlag()

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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
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
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
        }
        let controller = await MainActor.run {
            MockExperienceViewController(mockExperienceVersionId: "version_golden")
        }
        let placementReference = JourneyReleaseJSONValue.object([
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let screenDismissals = JourneyOutcomeCallRecorder()
        let outcomes = JourneyOutcomeCallRecorder()
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = JourneyScreenCommitGate()
        let calls = JourneyOutcomeCallRecorder()
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let screenDismissals = JourneyOutcomeCallRecorder()
        let outcomes = JourneyOutcomeCallRecorder()
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let gate = JourneyScreenCommitGate()
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let recorder = JourneyEmissionBatchRecorder()
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let request = JourneyPresentationRequest(
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
            JourneyRuntimeDelegate(request: request)
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
        let completionCommitted = expectation(description: "product failure completed")
        events.addEventHandler(pattern: JourneyEvents.journeyCompleted) { _ in
            completionCommitted.fulfill()
        }
        let delegate = await MainActor.run {
            JourneyRuntimeDelegate(request: request)
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
            JourneyEvents.journeyStarted,
            SystemEventNames.productsUnavailable,
            JourneyEvents.journeyCompleted,
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
}
