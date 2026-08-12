import Foundation
@testable import Nuxie

/// Mock ExperienceViewController for testing purposes
class MockExperienceViewController: ExperienceViewController {
    private(set) var prepareForPresentationCallCount = 0
    private(set) var shutdownRuntimeCallCount = 0
    private(set) var runtimeLifecycleEvents: [String] = []
    var prepareForPresentationHandler: (@MainActor () async -> Void)?
    var shutdownRuntimeHandler: (@MainActor () async -> Void)?
    var onRuntimeLifecycleEvent: ((String) -> Void)?
    
    // MARK: - Initialization
    
    /// Create a mock flow view controller with test data
    init(
        mockExperienceVersionId: String = "test-flow",
        eventLog: EventLogProtocol = MockFactory.shared.eventLog,
        transactionService: TransactionService? = nil,
        productService: ProductService = MockFactory.shared.productService,
        systemEventSink: SystemEventSink = DiscardingSystemEventSink()
    ) {
        let description = JourneyDocument(
            screens: [
                JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )
            ],
            viewModelValues: nil
        )

        let flow = Experience(
            id: "test-experience",
            versionId: mockExperienceVersionId,
            name: "Test Experience",
            reentry: .everyTime,
            publishedAt: "2024-01-01T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil,
            journey: description
        )
        let resolvedTransactionService = transactionService ?? TransactionService(
            productService: productService,
            transactionObserver: MockTransactionObserver(),
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: MockFactory.shared.dateProvider,
            // Prefer the live SDK configuration so purchase flows observe the
            // configured purchase delegate, mirroring production wiring.
            settings: ConfigurationPurchaseSettingsProvider(configuration: {
                NuxieSDK.shared.configuration ?? NuxieConfiguration(apiKey: "test-api-key")
            }),
            eventSink: systemEventSink
        )
        super.init(
            experience: flow,
            packageStore: ExperiencePackageStore(),
            eventLog: eventLog,
            transactionService: resolvedTransactionService,
            productService: productService,
            systemEventSink: systemEventSink
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForPresentation() async {
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
    
    // MARK: - Test Helper Methods
    
    /// Simulate the onClose callback being triggered
    func simulateClose(with reason: CloseReason) {
        onClose?(reason)
    }
}
