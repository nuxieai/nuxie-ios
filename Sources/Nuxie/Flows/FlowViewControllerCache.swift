import Foundation

/// Manages creation and caching of flow view controllers
@MainActor
final class FlowViewControllerCache {
    
    // MARK: - Properties
    
    // Cache of view controllers by flow ID
    // MainActor-isolated so no need for dispatch queues
    private var cache: [String: FlowViewController] = [:]
    
    private let flowArtifactStore: FlowArtifactStore
    
    // MARK: - Initialization
    
    init(
        flowArtifactStore: FlowArtifactStore
    ) {
        self.flowArtifactStore = flowArtifactStore
        LogDebug("FlowViewControllerCache initialized")
    }
    
    // MARK: - Public Methods
    
    /// 1. Get view controller from cache (returns nil if not cached)
    func getCachedViewController(for flowId: String) -> FlowViewController? {
        return cache[flowId]
    }

    /// Update a cached view controller with the correct renderer-normalized flow.
    func updateCachedViewControllerIfNeeded(for flow: Flow) -> FlowViewController? {
        guard let cached = cache[flow.id] else {
            return nil
        }

        cached.updateFlowIfNeeded(flow)
        cached.updateArtifactTelemetryContext(.from(flow: flow))
        return cached
    }
    
    /// 2. Create view controller and insert into cache
    func createViewController(for flow: Flow) -> FlowViewController {
        let viewController = FlowViewController(
            flow: flow,
            artifactStore: flowArtifactStore
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
