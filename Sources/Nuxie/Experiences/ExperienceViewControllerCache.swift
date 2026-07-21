import Foundation

/// Manages creation and caching of flow view controllers
@MainActor
final class ExperienceViewControllerCache {
    
    // MARK: - Properties
    
    // Cache of view controllers by flow ID
    // MainActor-isolated so no need for dispatch queues
    private var cache: [String: ExperienceViewController] = [:]
    
    private let flowArtifactStore: ExperienceArtifactStore
    private let eventLog: EventLogProtocol
    private let transactionServiceProvider: () -> TransactionService
    private let productService: ProductService
    
    // MARK: - Initialization
    
    init(
        flowArtifactStore: ExperienceArtifactStore,
        eventLog: EventLogProtocol,
        transactionServiceProvider: @escaping () -> TransactionService,
        productService: ProductService
    ) {
        self.flowArtifactStore = flowArtifactStore
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productService = productService
        LogDebug("ExperienceViewControllerCache initialized")
    }
    
    // MARK: - Public Methods
    
    /// 1. Get view controller from cache (returns nil if not cached)
    func getCachedViewController(for flowId: String) -> ExperienceViewController? {
        return cache[flowId]
    }

    /// Update a cached view controller with the correct renderer-normalized flow.
    func updateCachedViewControllerIfNeeded(for flow: Experience) -> ExperienceViewController? {
        guard let cached = cache[flow.id] else {
            return nil
        }

        cached.updateFlowIfNeeded(flow)
        cached.updateArtifactTelemetryContext(.from(flow: flow))
        return cached
    }
    
    /// 2. Create view controller and insert into cache
    func createViewController(for flow: Experience) -> ExperienceViewController {
        let viewController = ExperienceViewController(
            flow: flow,
            artifactStore: flowArtifactStore,
            eventLog: eventLog,
            transactionService: transactionServiceProvider(),
            productService: productService
        )
        viewController.updateArtifactTelemetryContext(.from(flow: flow))
        cache[flow.id] = viewController
        return viewController
    }
    
    /// 3. Remove a specific view controller from cache
    func removeViewController(for flowId: String) {
        cache.removeValue(forKey: flowId)
    }
    
    /// 4. Clear all cached view controllers
    func clearCache() {
        cache.removeAll()
    }
    
    // MARK: - Cache Statistics (for debugging)
    
    /// Get current cache size
    var cacheSize: Int {
        return cache.count
    }

}
