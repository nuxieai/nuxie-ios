import Foundation
@testable import Nuxie

/// Mock ExperienceViewController for testing purposes
class MockFlowViewController: ExperienceViewController {
    private(set) var prepareForPresentationCallCount = 0
    private(set) var shutdownRuntimeCallCount = 0
    private(set) var runtimeLifecycleEvents: [String] = []
    var prepareForPresentationHandler: (@MainActor () async -> Void)?
    var shutdownRuntimeHandler: (@MainActor () async -> Void)?
    var onRuntimeLifecycleEvent: ((String) -> Void)?
    
    // MARK: - Initialization
    
    /// Create a mock flow view controller with test data
    init(
        mockFlowId: String = "test-flow",
        eventLog: EventLogProtocol = MockFactory.shared.eventLog,
        transactionService: TransactionService? = nil,
        productService: ProductService = MockFactory.shared.productService
    ) {
        let description = RemoteFlow(
            id: mockFlowId,
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow/\(mockFlowId)",
                manifest: BuildManifest(
                    totalFiles: 1,
                    totalSize: 100,
                    contentHash: "test-hash",
                    files: [
                        BuildFile(path: "flow.riv", size: 100, contentType: "application/octet-stream")
                    ]
                )
            ),
            screens: [
                RemoteFlowScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )
            ],
            viewModelValues: nil
        )

        let flow = Experience(screens: description, products: [])
        let resolvedTransactionService = transactionService ?? TransactionService(
            productService: productService,
            transactionObserver: MockTransactionObserver(),
            // Prefer the live SDK configuration so purchase flows observe the
            // configured purchase delegate, mirroring production wiring.
            configurationProvider: {
                NuxieSDK.shared.configuration ?? NuxieConfiguration(apiKey: "test-api-key")
            }
        )
        super.init(
            flow: flow,
            artifactStore: ExperienceArtifactStore(),
            eventLog: eventLog,
            transactionService: resolvedTransactionService,
            productService: productService
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
