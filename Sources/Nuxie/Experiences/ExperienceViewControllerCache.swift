import Foundation

/// Manages creation and caching of experience view controllers
@MainActor
final class ExperienceViewControllerCache {
    
    // MARK: - Properties
    
    // Cache of view controllers by immutable experience version ID.
    // MainActor-isolated so no need for dispatch queues
    private var cache: [String: ExperienceViewController] = [:]
    
    private let packageStore: ExperiencePackageStore
    private let eventLog: EventCapturing
    private let transactionServiceProvider: () -> TransactionService
    private let productService: ProductService
    private let systemEventSink: SystemEventSink
    private let artifactLoader: ExperienceArtifactLoader
    
    // MARK: - Initialization
    
    init(
        packageStore: ExperiencePackageStore,
        eventLog: EventCapturing,
        transactionServiceProvider: @escaping () -> TransactionService,
        productService: ProductService,
        systemEventSink: SystemEventSink,
        artifactLoader: @escaping ExperienceArtifactLoader
    ) {
        self.packageStore = packageStore
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productService = productService
        self.systemEventSink = systemEventSink
        self.artifactLoader = artifactLoader
        LogDebug("ExperienceViewControllerCache initialized")
    }
    
    // MARK: - Public Methods
    
    /// 1. Get view controller from cache (returns nil if not cached)
    func getCachedViewController(for experienceVersionId: String) -> ExperienceViewController? {
        return cache[experienceVersionId]
    }

    /// Update a cached view controller with the correct renderer-normalized experience.
    func updateCachedViewControllerIfNeeded(for experience: Experience) -> ExperienceViewController? {
        guard let cached = cache[experience.versionId] else {
            return nil
        }

        cached.updateExperienceIfNeeded(experience)
        cached.updateArtifactTelemetryContext(.from(experience: experience))
        return cached
    }
    
    /// 2. Create view controller and insert into cache
    func createViewController(for experience: Experience) -> ExperienceViewController {
        let viewController = ExperienceViewController(
            experience: experience,
            packageStore: packageStore,
            artifactLoader: artifactLoader,
            eventLog: eventLog,
            transactionService: transactionServiceProvider(),
            productService: productService,
            systemEventSink: systemEventSink
        )
        viewController.updateArtifactTelemetryContext(.from(experience: experience))
        cache[experience.versionId] = viewController
        return viewController
    }
    
    /// 3. Remove a specific view controller from cache
    func removeViewController(for experienceVersionId: String) {
        cache.removeValue(forKey: experienceVersionId)
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
