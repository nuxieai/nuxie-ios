import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor ArtifactLoadCancellationProbe {
    private var cancellationObserved = false
    private var completionObserved = false

    func recordCancellation() {
        cancellationObserved = true
    }

    func recordCompletion() {
        completionObserved = true
    }

    func wasCancelled() -> Bool {
        cancellationObserved
    }

    func didComplete() -> Bool {
        completionObserved
    }
}

private actor InteractiveDismissalSuspension {
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class ExperienceArtifactTelemetryTests: XCTestCase {
    #if canImport(UIKit)
    @MainActor
    func testSignedShimmerCoversTheShellAndReduceMotionKeepsItStatic() {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-shaped-shimmer"
        )
        controller.configurePresentationShell(
            ExperienceShellContract(
                presentation: .init(
                    style: .fullScreen,
                    orientation: .any,
                    backgroundColor: "#102030FF",
                    sheet: nil,
                    drawer: nil
                ),
                screen: .init(width: 390, height: 844)
            )
        )

        _ = controller.view

        XCTAssertFalse(controller.loadingShimmerView.isHidden)
        XCTAssertTrue(controller.loadingShimmerView.isAnimating)

        controller.configurePresentationShell(
            controller.presentationShellContract,
            suppressLoadingTreatment: true
        )
        XCTAssertTrue(controller.loadingShimmerView.isHidden)
        XCTAssertFalse(controller.loadingShimmerView.isAnimating)

        controller.loadingShimmerView.configure(
            backgroundColor: .black,
            palette: ExperienceShellPalette(prefersLightContent: true),
            reduceMotion: true
        )
        XCTAssertFalse(controller.loadingShimmerView.isHidden)
        XCTAssertFalse(controller.loadingShimmerView.isAnimating)
    }

    @MainActor
    func testSignedShellAppliesOrientationAndAuthoredColor() {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-shell-appearance"
        )
        controller.configurePresentationShell(
            ExperienceShellContract(
                presentation: .init(
                    style: .sheet,
                    orientation: .landscape,
                    backgroundColor: "#102030FF",
                    sheet: .init(detent: .large, dismissible: true),
                    drawer: nil
                ),
                screen: .init(width: 844, height: 390)
            )
        )

        _ = controller.view

        XCTAssertEqual(controller.supportedInterfaceOrientations, .landscape)
        XCTAssertTrue(
            controller.loadingView.backgroundColor?.isEqual(
                UIColor(red: 16 / 255, green: 32 / 255, blue: 48 / 255, alpha: 1)
            ) == true
        )
        XCTAssertFalse(controller.loadingShimmerView.isHidden)
        XCTAssertTrue(controller.loadingShimmerView.isAnimating)
    }

    @MainActor
    func testLegacyEmbeddedControllerKeepsItsActivityIndicatorRunning() {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-legacy-loading-indicator"
        )

        _ = controller.view

        XCTAssertNil(controller.presentationShellContract)
        XCTAssertTrue(controller.activityIndicator.isAnimating)
    }

    @MainActor
    func testNewLoadingStateCancelsAStaleRevealCompletion() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-stale-reveal"
        )
        controller.configurePresentationShell(
            ExperienceShellContract(
                presentation: .fullScreenDefault,
                screen: .init(width: 390, height: 844)
            )
        )
        _ = controller.view
        controller.loadingView.isHidden = false
        controller.platformRevealPresentationContent()

        controller.retryFromErrorView()
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(controller.loadingView.isHidden)
        XCTAssertEqual(controller.loadingView.alpha, 1)
        await controller.shutdownRuntime()
    }

    @MainActor
    func testLoadingTimeoutKeepsRuntimeDrawableProductionVisible() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-timeout-keeps-rendering",
            loadingTimeoutSeconds: 0.01,
            recoveryAffordanceDelay: 1
        )
        controller.configurePresentationShell(
            ExperienceShellContract(
                presentation: .fullScreenDefault,
                screen: .init(width: 390, height: 844)
            )
        )

        _ = controller.view
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(controller.experienceContentIsHidden)
        await controller.shutdownRuntime()
    }
    #endif

    @MainActor
    func testRecoveryAffordancesAppearOnTheShellDeadlineWhileLoadingContinues() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-recovery-shell",
            loadingTimeoutSeconds: 0.04,
            recoveryAffordanceDelay: 0.01
        )
        let shell = ExperienceShellContract(
            presentation: .init(
                style: .drawer,
                orientation: .portrait,
                backgroundColor: "#102030FF",
                sheet: nil,
                drawer: .init(
                    edge: .bottom,
                    extentRatio: 0.6,
                    cornerRadius: 24,
                    dismissible: true
                )
            ),
            screen: .init(width: 390, height: 640)
        )
        controller.configurePresentationShell(shell)

        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)
        XCTAssertTrue(controller.errorView.isHidden)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(controller.errorView.isHidden)
        XCTAssertFalse(controller.refreshButton.isHidden)
        #if canImport(UIKit)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, false)
        #endif
        XCTAssertEqual(controller.presentationShellContract, shell)
        #if canImport(UIKit)
        XCTAssertFalse(controller.loadingShimmerView.isAnimating)
        #endif
        try? await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertFalse(controller.errorView.isHidden)
        await controller.shutdownRuntime()
    }

    @MainActor
    func testRecoveryDeadlineDoesNotLoadOrTouchAnUnloadedView() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-unloaded-recovery-shell",
            recoveryAffordanceDelay: 0.01
        )

        XCTAssertFalse(controller.isViewLoaded)
        controller.markPresentationShellPresented(traceToken: nil)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(controller.isViewLoaded)
        await controller.shutdownRuntime()
    }

    @MainActor
    func testEmbeddedControllerShowsRecoveryControlsWithoutDedicatedShellMarker() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-embedded-recovery",
            recoveryAffordanceDelay: 0.01
        )

        _ = controller.view
        XCTAssertNil(controller.presentationShellContract)
        XCTAssertTrue(controller.errorView.isHidden)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(controller.errorView.isHidden)
        XCTAssertFalse(controller.refreshButton.isHidden)
        #if canImport(UIKit)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, false)
        #endif
        await controller.shutdownRuntime()
    }

    @MainActor
    func testInteractiveDismissalPerformsRuntimeCleanupAndClosesOnce() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-interactive-dismissal"
        )
        var closeReasons: [CloseReason] = []
        controller.onClose = { closeReasons.append($0) }

        controller.performInteractiveDismissal(reason: .userDismissed)
        controller.performInteractiveDismissal(reason: .userDismissed)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(controller.prepareForDismissalCallCount, 1)
        XCTAssertEqual(closeReasons, [.userDismissed])
    }

    @MainActor
    func testStaleInteractiveDismissalCannotCloseANewerPresentation() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-stale-interactive-dismissal"
        )
        let suspension = InteractiveDismissalSuspension()
        var closeOwners: [String] = []
        controller.prepareForDismissalHandler = { await suspension.suspend() }
        controller.onClose = { _ in closeOwners.append("old") }

        controller.performInteractiveDismissal(reason: .userDismissed)
        await suspension.waitUntilEntered()
        _ = controller.beginPresentationScope(traceToken: nil)
        controller.onClose = { _ in closeOwners.append("new") }
        await suspension.resume()
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(closeOwners.isEmpty)
    }

    func testPersistedExperienceRequiresCanonicalPresentationContract() throws {
        let experience = Experience(
            id: "experience-legacy-codable",
            versionId: "version-legacy-codable",
            name: "Legacy Codable",
            reentry: .everyTime,
            publishedAt: "2026-08-15T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
        let encoded = try JSONEncoder().encode(experience)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "behaviorPresentation")
        object.removeValue(forKey: "behaviorPresentationScreens")
        object["behaviorPresentationStyle"] = "full_screen"

        XCTAssertThrowsError(try JSONDecoder().decode(
            Experience.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testPresentationScopeCarriesCurrentAuthorityWithoutMutatingRelease() {
        let release = Experience(
            id: "experience-authority",
            versionId: "version-authority",
            name: "Authority",
            reentry: .everyTime,
            publishedAt: "2026-08-17T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
        let authorization = IntroEligibilityAuthorizationContext(
            distinctId: "customer-a",
            journeyId: "journey-a"
        )

        let presentation = release.scopedForPresentation(
            introEligibilityAuthorization: authorization
        )

        XCTAssertNil(release.introEligibilityAuthorization)
        XCTAssertEqual(presentation.introEligibilityAuthorization, authorization)
        XCTAssertTrue(release.products.isEmpty)
        XCTAssertTrue(presentation.products.isEmpty)
    }

    @MainActor
    func testLoadingDeadlineDoesNotCancelOrMisreportAnInFlightArtifactAcquisition() async {
        let behavior = ExperienceBehaviorDefinition(
            reference: ExperienceReference(
                experienceId: "experience-slow-artifact",
                versionId: "version-slow-artifact"
            ),
            buildId: "build-slow-artifact",
            artifactContentHash: String(repeating: "a", count: 64),
            name: "Slow artifact",
            reentry: .everyTime,
            publishedAt: "2026-08-14T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            timeLimitSeconds: nil,
            experienceType: nil,
            presentationStyle: .fullScreen
        )
        let experience = Experience(
            behavior: behavior,
            journey: JourneyDocument(
                screens: [JourneyScreen(id: "screen-1")]
            ),
            assetBaseURL: URL(string: "https://assets.nuxie.test/")!
        )
        let cancellationProbe = ArtifactLoadCancellationProbe()
        let eventLog = MockEventLog()
        let viewModel = ExperienceViewModel(
            experience: experience,
            loadingTimeoutSeconds: 0.01,
            artifactLoader: { _, _, _ in
                do {
                    try await Task.sleep(nanoseconds: 30_000_000)
                    await cancellationProbe.recordCompletion()
                    throw NuxieError.invalidConfiguration("expected test completion")
                } catch is CancellationError {
                    await cancellationProbe.recordCancellation()
                    throw CancellationError()
                }
            },
            eventLog: eventLog
        )

        viewModel.loadExperience()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.currentState, .error)
        let wasCancelled = await cancellationProbe.wasCancelled()
        let didComplete = await cancellationProbe.didComplete()
        XCTAssertFalse(wasCancelled)
        XCTAssertTrue(didComplete)
        let artifactEvents = eventLog.trackedEvents.filter {
            $0.name == JourneyEvents.experienceArtifactLoadSucceeded
                || $0.name == JourneyEvents.experienceArtifactLoadFailed
        }
        XCTAssertEqual(artifactEvents.count, 1)
        XCTAssertEqual(
            artifactEvents.first?.name,
            JourneyEvents.experienceArtifactLoadFailed
        )
        XCTAssertTrue(
            (artifactEvents.first?.properties?["error_message"] as? String)?
                .contains("expected test completion") == true
        )

        viewModel.cancelLoading()
    }

    @MainActor
    func testFailedArtifactTracePreservesMeasuredRequiredAcquisitionWork() async {
        let behavior = ExperienceBehaviorDefinition(
            reference: ExperienceReference(
                experienceId: "experience-resource-failure",
                versionId: "version-resource-failure"
            ),
            buildId: "build-resource-failure",
            artifactContentHash: String(repeating: "c", count: 64),
            name: "Resource failure",
            reentry: .everyTime,
            publishedAt: "2026-08-14T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            timeLimitSeconds: nil,
            experienceType: nil,
            presentationStyle: .fullScreen
        )
        let experience = Experience(
            behavior: behavior,
            journey: JourneyDocument(screens: [JourneyScreen(id: "screen-1")]),
            assetBaseURL: URL(string: "https://assets.nuxie.test/")!
        )
        let measured = ExperienceReleaseResourceMetrics(
            readBytes: 17,
            hashedBytes: 17,
            parsedBytes: 0,
            duplicateReadBytes: 0,
            duplicateHashBytes: 0,
            duplicateParseBytes: 0,
            preloadBytes: 0,
            unusedPreloadBytes: 0
        )
        let recorder = InMemoryExperiencePresentationTrace()
        let context = ExperiencePresentationTraceContext(
            attempt: .make(triggerEvent: "resource_failure", startedAt: Date()),
            recorder: recorder
        )
        let viewModel = ExperienceViewModel(
            experience: experience,
            artifactLoader: { _, _, _ in
                throw ExperienceReleaseResourceFailure(
                    underlying: ExperienceReleaseAcquisitionError.objectDigestMismatch(
                        key: "renders/sha256/expected.riv",
                        expected: String(repeating: "c", count: 64),
                        actual: String(repeating: "d", count: 64)
                    ),
                    resourceMetrics: measured
                )
            },
            eventLog: MockEventLog()
        )
        viewModel.updatePresentationTraceContext(context)

        viewModel.loadExperience()
        for _ in 0..<100 {
            if viewModel.currentState == .error { break }
            await Task.yield()
        }

        let failureAttributes = recorder.events().compactMap {
            event -> [String: String]? in
            guard case .workFailed(_, .artifactAcquisition, _, _, let attributes) =
                event.stage else { return nil }
            return attributes
        }
        XCTAssertEqual(viewModel.currentState, .error)
        XCTAssertEqual(failureAttributes.count, 1)
        XCTAssertEqual(failureAttributes[0]["read_bytes"], "17")
        XCTAssertEqual(failureAttributes[0]["hashed_bytes"], "17")
    }

    @MainActor
    func testDescriptorTelemetryUsesExactVersionAndSignedRIVDigestForSuccessAndFailure() {
        let versionID = "version-telemetry-exact"
        let rivDigest = String(repeating: "b", count: 64)
        let behavior = ExperienceBehaviorDefinition(
            reference: ExperienceReference(
                experienceId: "experience-telemetry",
                versionId: versionID
            ),
            buildId: "build-is-not-a-content-hash",
            artifactContentHash: rivDigest,
            name: "Telemetry",
            reentry: .everyTime,
            publishedAt: "2026-08-13T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            timeLimitSeconds: nil,
            experienceType: nil,
            presentationStyle: .fullScreen
        )
        let experience = Experience(
            behavior: behavior,
            journey: JourneyDocument(
                screens: [JourneyScreen(id: "screen-1")]
            ),
            assetBaseURL: URL(string: "https://assets.nuxie.test/")!
        )

        let successLog = MockEventLog()
        let success = ExperienceViewModel(
            experience: experience,
            artifactLoader: { _, _, _ in throw CancellationError() },
            eventLog: successLog
        )
        success.handleLoadingFinished()

        let failureLog = MockEventLog()
        let failure = ExperienceViewModel(
            experience: experience,
            artifactLoader: { _, _, _ in throw CancellationError() },
            eventLog: failureLog
        )
        failure.handleLoadingFailed(NuxieError.invalidConfiguration("expected"))

        for event in [
            successLog.trackedEvents.first {
                $0.name == JourneyEvents.experienceArtifactLoadSucceeded
            },
            failureLog.trackedEvents.first {
                $0.name == JourneyEvents.experienceArtifactLoadFailed
            },
        ] {
            XCTAssertEqual(event?.properties?["experience_version"] as? String, versionID)
            XCTAssertEqual(event?.properties?["artifact_content_hash"] as? String, rivDigest)
            XCTAssertEqual(
                event?.properties?["artifact_build_id"] as? String,
                "build-is-not-a-content-hash"
            )
        }
    }

    @MainActor
    func testRepeatedPresentationReplacesCheckoutAuthorityWhenVisibleTermsMatch() {
        func product(journeyId: String) -> StoreProduct {
            StoreProduct(
                productId: "premium",
                placementId: "paywall:0",
                name: "Premium",
                price: "$9.99",
                period: .month,
                productType: .autoRenewable,
                introEligibilityTokenRequest: .init(
                    experienceVersionId: "version-1",
                    placementId: "paywall:0",
                    authorization: .init(
                        distinctId: "customer-1",
                        journeyId: journeyId
                    )
                ),
                appStoreProduct: MockStoreProduct(
                    id: "premium.monthly",
                    displayName: "Premium",
                    price: 9.99,
                    displayPrice: "$9.99",
                    productType: .autoRenewable
                )
            )
        }
        func experience(product: StoreProduct) -> Experience {
            Experience(
                id: "experience-1",
                versionId: "version-1",
                name: "Paywall",
                reentry: .everyTime,
                publishedAt: "2026-08-17T00:00:00Z",
                trigger: nil,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil,
                products: [product]
            )
        }

        let viewModel = ExperienceViewModel(
            experience: experience(product: product(journeyId: "journey-a")),
            artifactLoader: { _, _, _ in throw CancellationError() },
            eventLog: MockEventLog()
        )
        viewModel.updateExperienceIfNeeded(
            experience(product: product(journeyId: "journey-b"))
        )

        XCTAssertEqual(
            viewModel.products.first?.introEligibilityTokenRequest?.authorization.journeyId,
            "journey-b"
        )
    }

}
