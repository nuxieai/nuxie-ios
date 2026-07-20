import Foundation
import FactoryKit

/// Manages fetching and coordinating flow information with products
actor FlowStore {
    
    // MARK: - Properties
    
    // Client-side flow models keyed by composite hash
    // Contains both RemoteFlow data and enriched product data
    private var flowModels: [FlowCacheKey: Flow] = [:]
    
    // Deduplication of concurrent requests
    private var pendingFetches: [FlowCacheKey: Task<Flow, Error>] = [:]
    
    @Injected(\.nuxieApi) private var api: NuxieApiProtocol
    @Injected(\.productService) private var productService: ProductService
    
    // MARK: - Initialization
    
    init() {
        LogDebug("FlowStore initialized")
    }
    
    // MARK: - Cache Management
    
    /// Preload multiple flows with RemoteFlow data (typically from warm caches)
    /// This enriches the RemoteFlows with products and caches them
    func preloadFlows(_ remoteFlows: [RemoteFlow]) async {
        LogDebug("Preloading \(remoteFlows.count) flows")
        
        // Process flows concurrently for better performance
        await withTaskGroup(of: Void.self) { group in
            for remoteFlow in remoteFlows {
                group.addTask { [weak self] in
                    guard let self else { return }
                    
                    let key = FlowCacheKey(id: remoteFlow.id)
                    
                    // Check if already cached and valid
                    if let cached = await self.flowModels[key] {
                        LogDebug("Flow already cached and valid: \(remoteFlow.id)")
                        return
                    }
                    
                    // Enrich and cache the flow
                    do {
                        LogDebug("Preloading flow: \(remoteFlow.id)")
                        let flow = try await self.enrichFlow(remoteFlow)
                        await self.setFlow(flow, for: key)
                    } catch {
                        LogError("Failed to preload flow \(remoteFlow.id): \(error)")
                    }
                }
            }
        }
        
        LogDebug("Completed preloading flows")
    }
    
    /// Remove flow from all caches
    func removeFlow(id: String) {
        // Remove all variants of this flow
        flowModels = flowModels.filter { $0.key.id != id }
        LogDebug("Removed flow from cache: \(id)")
    }
    
    /// Invalidate cached Flow model
    func invalidateFlow(id: String) {
        // Remove all variants of this flow
        flowModels = flowModels.filter { $0.key.id != id }
        LogDebug("Invalidated flow model: \(id)")
    }
    
    /// Clear all caches
    func clearCache() {
        flowModels.removeAll()
        pendingFetches.removeAll()
        LogDebug("Cleared all flow info caches")
    }
    
    // MARK: - Cache Access (Synchronous)
    
    /// Get cached Flow if available (synchronous, thread-safe)
    func getCachedFlow(id: String) -> Flow? {
        let key = FlowCacheKey(id: id)
        let cached = flowModels[key]
        return cached
    }
    
    // MARK: - Flow Fetching
    
    /// Get flow with products
    /// Checks cache first, then fetches from API if needed
    func flow(with id: String) async throws -> Flow {
        let key = FlowCacheKey(id: id)
        
        // Check for pending fetch - await existing task
        if let pendingTask = pendingFetches[key] {
            LogDebug("Awaiting pending fetch for flow: \(id)")
            return try await pendingTask.value
        }
        
        // Check cached model
        if let cached = flowModels[key] {
            LogDebug("Returning cached flow model: \(id)")
            return cached
        }
        
        // Start new fetch with deduplication
        LogDebug("Starting new fetch for flow: \(id)")
        
        let task = Task<Flow, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            
            do {
                // Fetch from API
                LogInfo("Fetching flow from API: \(id)")
                let remoteFlow = try await self.api.fetchFlow(flowId: id)
                
                // Enrich and cache
                let flow = try await self.enrichFlow(remoteFlow)
                await self.setFlow(flow, for: key)
                
                // Clear pending after successful completion
                await self.clearPending(for: key)
                return flow
            } catch {
                // Clear pending on error as well
                await self.clearPending(for: key)
                throw error
            }
        }
        
        pendingFetches[key] = task
        return try await task.value
    }
    
    // MARK: - Private Methods
    
    private func clearPending(for key: FlowCacheKey) {
        pendingFetches[key] = nil
    }
    
    private func setFlow(_ flow: Flow, for key: FlowCacheKey) {
        flowModels[key] = flow
    }
    
    private func enrichFlow(_ remoteFlow: RemoteFlow) async throws -> Flow {
        // Fetch products if the flow references any
        let products = try await fetchProducts(for: remoteFlow)
        
        // Create and return the flow with fetched products
        let flow = Flow(
            remoteFlow: remoteFlow,
            products: products
        )
        
        LogDebug("Created flow with \(products.count) products: \(remoteFlow.id)")
        return flow
    }
    
    private func fetchProducts(for remoteFlow: RemoteFlow) async throws -> [FlowProduct] {
        let productIds = extractProductIds(from: remoteFlow)
        guard !productIds.isEmpty else {
            LogDebug("No products referenced in flow: \(remoteFlow.id)")
            return []
        }
        
        let storeProducts = try await productService.fetchProducts(for: Set(productIds))
        
        let flowProducts = storeProducts.map { storeProduct in
            FlowProduct(
                id: storeProduct.id,
                name: storeProduct.displayName,
                price: storeProduct.displayPrice,
                period: mapSubscriptionPeriod(storeProduct.subscriptionPeriod)
            )
        }
        
        return flowProducts
    }
    
    private func extractProductIds(from remoteFlow: RemoteFlow) -> [String] {
        var ids = Set<String>()
        for value in remoteFlow.viewModelValues ?? [] {
            if value.path.split(separator: "/").last == "productId",
               let productId = extractProductId(from: value.value.value) {
                ids.insert(productId)
            }
        }

        return Array(ids)
    }
    
    private func extractProductId(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let dict = value as? [String: Any] {
            if let productId = dict["productId"] as? String {
                return productId
            }
            if let productId = dict["id"] as? String {
                return productId
            }
        }
        if let dict = value as? [String: AnyCodable] {
            if let productId = dict["productId"]?.value as? String {
                return productId
            }
            if let productId = dict["id"]?.value as? String {
                return productId
            }
        }
        return nil
    }
    
    private func mapSubscriptionPeriod(_ subscriptionPeriod: SubscriptionPeriod?) -> ProductPeriod? {
        guard let period = subscriptionPeriod else { return nil }
        
        // Map from StoreKit subscription period to our ProductPeriod enum
        switch period.unit {
        case .week where period.value == 1:
            return .week
        case .month where period.value == 1:
            return .month
        case .year where period.value == 1:
            return .year
        default:
            // For non-standard periods, we'll need to decide how to handle them
            // For now, map to closest standard period
            switch period.unit {
            case .week:
                return .week
            case .month:
                return .month
            case .year:
                return .year
            case .day:
                // No daily period in our enum, treat as weekly
                return .week
            }
        }
    }
}
