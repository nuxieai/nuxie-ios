import Foundation
@testable import Nuxie

/// Mock ExperienceViewController for testing purposes
class MockExperienceViewController: ExperienceViewController {
    private(set) var prepareForPresentationCallCount = 0
    private(set) var shutdownRuntimeCallCount = 0
    private(set) var prepareForDismissalCallCount = 0
    private(set) var navigationScreenIds: [String] = []
    private(set) var navigationTransitions: [Any?] = []
    private(set) var performDismissReasons: [CloseReason] = []
    private(set) var performedOpenLinks: [(urlString: String, target: String?)] = []
    private(set) var notificationPermissionResolutionCount = 0
    private(set) var requestPermissionResolutionTypes: [String] = []
    private(set) var trackingPermissionResolutionCount = 0
    private(set) var runtimeLifecycleEvents: [String] = []
    private var didPrepareForCurrentDismissal = false
    var prepareForPresentationHandler: (@MainActor () async -> Void)?
    var shutdownRuntimeHandler: (@MainActor () async -> Void)?
    var prepareForDismissalHandler: (@MainActor () async -> Void)?
    var navigationResult = ExperienceScreenNavigationResult.navigated
    var notificationPermissionEvent = JourneyPresentationPermissionEvent(
        name: SystemEventNames.notificationsEnabled,
        properties: [:]
    )
    var requestPermissionEvent = JourneyPresentationPermissionEvent(
        name: SystemEventNames.permissionGranted,
        properties: ["type": "camera"]
    )
    var trackingPermissionEvent = JourneyPresentationPermissionEvent(
        name: SystemEventNames.trackingAuthorized,
        properties: [:]
    )
    var onRuntimeLifecycleEvent: ((String) -> Void)?
    
    // MARK: - Initialization
    
    /// Create a mock flow view controller with test data
    init(
        mockExperienceVersionId: String = "test-flow",
        mockScreenId: String = "screen-1",
        mockExperience: Experience? = nil,
        eventLog: EventLogProtocol = MockFactory.shared.eventLog,
        loadingTimeoutSeconds: TimeInterval = 15.0,
        recoveryAffordanceDelay: TimeInterval = 5.0,
        /// Failure the artifact loader raises, so tests can drive the exact
        /// recovery classification an acquisition would produce. Defaults to
        /// cancellation, which never reaches the recovery surface.
        artifactLoadError: (any Error)? = nil,
        products: [StoreProduct] = [],
        transactionService: TransactionService? = nil,
        productService: ProductService = MockFactory.shared.productService,
        systemEventSink: SystemEventSink = DiscardingSystemEventSink()
    ) {
        let description = JourneyDocument(
            screens: [
                JourneyScreen(
                    id: mockScreenId,
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )
            ],
            viewModelValues: nil
        )

        let flow = mockExperience ?? Experience(
            id: "test-experience",
            versionId: mockExperienceVersionId,
            buildId: "test-build",
            artifactContentHash: nil,
            authenticatedReleaseID: nil,
            behaviorPresentation: .fullScreenDefault,
            behaviorPresentationScreens: [
                mockScreenId: .init(width: 390, height: 844)
            ],
            assetBaseURL: URL(string: "https://assets.example.com/")!,
            journey: description,
            definition: nil,
            products: products
        )
        let resolvedTransactionService = transactionService ?? TransactionService(
            productService: productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: MockFactory.shared.dateProvider,
            // Prefer the live synchronized settings so purchase flows observe
            // the configured purchase delegate, mirroring production wiring.
            settings: NuxieSDK.shared.core?.runtimeSettings
                ?? NuxieRuntimeSettings(
                    configuration: NuxieConfiguration(apiKey: "test-api-key")
                ),
            eventSink: systemEventSink
        )
        super.init(
            experience: flow,
            artifactLoader: { _, _, _ in throw artifactLoadError ?? CancellationError() },
            eventLog: eventLog,
            loadingTimeoutSeconds: loadingTimeoutSeconds,
            recoveryAffordanceDelay: recoveryAffordanceDelay,
            transactionService: resolvedTransactionService,
            productService: productService,
            systemEventSink: systemEventSink
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForPresentation(
        traceToken: ExperiencePresentationTraceToken?,
        initialScreenID: String? = nil
    ) async {
        _ = initialScreenID
        beginPresentationScope(traceToken: traceToken)
        didPrepareForCurrentDismissal = false
        prepareForPresentationCallCount += 1
        runtimeLifecycleEvents.append("prepare")
        onRuntimeLifecycleEvent?("prepare")
        await prepareForPresentationHandler?()
    }

    override func shutdownRuntime() async {
        shutdownRuntimeCallCount += 1
        runtimeLifecycleEvents.append("shutdown")
        onRuntimeLifecycleEvent?("shutdown")
        await shutdownRuntimeHandler?()
    }

    override func prepareForDismissal(reason: CloseReason? = nil) async {
        guard !didPrepareForCurrentDismissal else { return }
        didPrepareForCurrentDismissal = true
        prepareForDismissalCallCount += 1
        runtimeLifecycleEvents.append("prepare-dismissal")
        onRuntimeLifecycleEvent?("prepare-dismissal")
        await prepareForDismissalHandler?()
        await runtimeDelegate?.experienceViewController(
            self,
            didDismissScreen: "screen-1",
            revealingScreenId: nil,
            method: reason.map { ExperienceScreenDismissalMethod.value(for: $0) }
                ?? "experience"
        )
    }

    override func navigateAndWait(
        to screenId: String,
        transition: Any? = nil
    ) async -> Bool {
        (await navigateAndWaitResult(
            to: screenId,
            transition: transition
        )).reachedTarget
    }

    override func navigateAndWaitResult(
        to screenId: String,
        transition: Any? = nil
    ) async -> ExperienceScreenNavigationResult {
        navigationScreenIds.append(screenId)
        navigationTransitions.append(transition)
        return navigationResult
    }

    override func resolveJourneyNotificationPermissionEvent(
        journeyId: String
    ) async -> JourneyPresentationPermissionEvent {
        _ = journeyId
        notificationPermissionResolutionCount += 1
        return notificationPermissionEvent
    }

    override func resolveJourneyRequestPermissionEvent(
        permissionType: String,
        journeyId: String
    ) async -> JourneyPresentationPermissionEvent {
        _ = journeyId
        requestPermissionResolutionTypes.append(permissionType)
        return requestPermissionEvent
    }

    override func resolveJourneyTrackingPermissionEvent(
        journeyId: String
    ) async -> JourneyPresentationPermissionEvent {
        _ = journeyId
        trackingPermissionResolutionCount += 1
        return trackingPermissionEvent
    }

    override func performDismiss(reason: CloseReason = .userDismissed) {
        performDismissReasons.append(reason)
        super.performDismiss(reason: reason)
    }

    override func performOpenLink(urlString: String, target: String? = nil) {
        performedOpenLinks.append((urlString, target))
    }
    
    // MARK: - Test Helper Methods
    
    /// Simulate the onClose callback being triggered
    func simulateClose(with reason: CloseReason) {
        onClose?(reason)
    }
}
