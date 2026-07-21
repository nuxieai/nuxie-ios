import Foundation

/// Protocol defining the ExperienceService interface
protocol ExperienceServiceProtocol: AnyObject {
    /// Prefetch flows - triggers fetch of flow data and preloads flow artifacts.
    func prefetchFlows(_ remoteFlows: [RemoteFlow])
    
    /// Remove flows from cache
    func removeFlows(_ flowIds: [String]) async

    /// Fetch flow data with products - does not create UI
    func fetchExperience(id: String) async throws -> Experience
    
    /// Get a view controller for a flow by ID
    @MainActor
    func viewController(for flowId: String) async throws -> ExperienceViewController

    /// Get a view controller for a flow by ID
    @MainActor
    func viewController(
        for flowId: String,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController

    /// Get a view controller for a flow by ID with a runtime delegate
    @MainActor
    func viewController(for flowId: String, runtimeDelegate: FlowRuntimeDelegate?) async throws -> ExperienceViewController

    /// Get a view controller for a flow by ID with a runtime delegate
    @MainActor
    func viewController(
        for flowId: String,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController
    
    /// Clear all cached data.
    func clearCache() async
}

/// ExperienceService: Clean implementation following FLOW_REQUIREMENTS.md exactly
/// This is the umbrella container that orchestrates all flow subsystems
final class ExperienceService: ExperienceServiceProtocol {
    
    // MARK: - Subsystems
    
    private let flowStore: ExperienceStore
    private let flowArtifactStore: ExperienceArtifactStore
    private let eventLog: EventLogProtocol
    private let transactionServiceProvider: () -> TransactionService
    private let productServiceRef: ProductService
    
    // Lazy initialization ensures this is created on MainActor when first accessed
    @MainActor
    private lazy var viewControllerCache: ExperienceViewControllerCache = {
        ExperienceViewControllerCache(
            flowArtifactStore: self.flowArtifactStore,
            eventLog: self.eventLog,
            transactionServiceProvider: self.transactionServiceProvider,
            productService: self.productServiceRef
        )
    }()
    
    // MARK: - Initialization
    
    internal init(
        api: NuxieApiProtocol,
        productService: ProductService,
        eventLog: EventLogProtocol,
        transactionServiceProvider: @escaping () -> TransactionService,
        flowArtifactStore: ExperienceArtifactStore? = nil
    ) {
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productServiceRef = productService
        self.flowStore = ExperienceStore(api: api, productService: productService)
        self.flowArtifactStore = flowArtifactStore ?? ExperienceArtifactStore()
        
        LogInfo("ExperienceService initialized with native flow artifact delivery")
    }
    
    // MARK: - Experience Lifecycle Management (called by ProfileService)
    
    /// Prefetch flows - triggers fetch of flow data and preloads flow artifacts.
    func prefetchFlows(_ remoteFlows: [RemoteFlow]) {
        LogInfo("Prefetching \(remoteFlows.count) flows")
        
        Task {
            // Preload all flows with products into cache (concurrent)
            await flowStore.preloadFlows(remoteFlows)
            
            // Preload native flow artifacts for all flows.
            for screens in remoteFlows {
                let flow = Experience(screens: screens, products: [])
                await flowArtifactStore.preloadArtifact(for: flow)
            }
        }
    }
    
    /// Remove flows from cache
    func removeFlows(_ flowIds: [String]) async {
        LogInfo("Removing \(flowIds.count) flows")
        
        await withTaskGroup(of: Void.self) { group in
            for flowId in flowIds {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    // Remove from all caches
                    await self.flowStore.removeFlow(id: flowId)
                    await self.flowArtifactStore.removeArtifact(for: flowId)
                }
            }
        }
        
        // View controller cache is MainActor-isolated
        await MainActor.run {
            for flowId in flowIds {
                viewControllerCache.removeViewController(for: flowId)
            }
        }
    }
    
    // MARK: - Data Operations (can be called from any thread)
    
    /// Fetch flow data with products - does not create UI
    func fetchExperience(id: String) async throws -> Experience {
        // This can be called from any thread
        return try await flowStore.flow(with: id)
    }
        
    // MARK: - UI Operations (MUST be called from main thread)
    
    /// Get view controller for flow - dead simple
    /// Path A: Cache hit - update if needed and return
    /// Path B: Cache miss - create new one and return it
    /// Must be called from main thread as it creates UIViewController
    @MainActor
    func viewController(for flow: Experience) -> ExperienceViewController {
        // Path A: Check cache first
        if let cached = viewControllerCache.updateCachedViewControllerIfNeeded(for: flow) {
            LogDebug("Cache hit: returning cached view controller for flow: \(flow.id)")
            return cached
        }
        
        // Path B: Create new view controller and cache it
        LogDebug("Cache miss: creating new view controller for flow: \(flow.id)")
        let viewController = viewControllerCache.createViewController(for: flow)
        return viewController
    }
    
    /// Get view controller for flow by ID - fetches flow first then creates view controller
    @MainActor
    func viewController(for flowId: String) async throws -> ExperienceViewController {
        try await viewController(for: flowId, colorSchemeMode: .light)
    }

    @MainActor
    func viewController(
        for flowId: String,
        colorSchemeMode: ExperienceColorSchemeMode = .light
    ) async throws -> ExperienceViewController {
        // Fetch the flow data first
        let flow = try await fetchExperience(id: flowId)

        // Then get or create the view controller
        let controller = viewController(for: flow)
        if controller.colorSchemeMode != colorSchemeMode {
            controller.colorSchemeMode = colorSchemeMode
        }
        return controller
    }

    @MainActor
    func viewController(for flowId: String, runtimeDelegate: FlowRuntimeDelegate?) async throws -> ExperienceViewController {
        try await viewController(
            for: flowId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .light
        )
    }

    @MainActor
    func viewController(
        for flowId: String,
        runtimeDelegate: FlowRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .light
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(
            for: flowId,
            colorSchemeMode: colorSchemeMode
        )
        controller.runtimeDelegate = runtimeDelegate
        controller.notificationPermissionEventReceiver =
            runtimeDelegate as? NotificationPermissionEventReceiver
        controller.trackingPermissionEventReceiver =
            runtimeDelegate as? TrackingPermissionEventReceiver
        return controller
    }
    
    // MARK: - Cache Management
    
    /// Clear all cached data.
    func clearCache() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.flowStore.clearCache()
            }
            group.addTask { [weak self] in
                await self?.flowArtifactStore.clearAllArtifacts()
            }
        }
        
        // View controller cache is MainActor-isolated
        await MainActor.run {
            viewControllerCache.clearCache()
        }
        
        LogInfo("Cleared all flow caches")
    }
    
    /// Clear only view controller cache
    @MainActor
    func clearViewControllerCache() {
        viewControllerCache.clearCache()
        LogInfo("Cleared view controller cache")
    }
}

// MARK: - Experience Errors

enum FlowError: LocalizedError {
    case flowNotFound(String)
    case invalidManifest
    case downloadFailed
    case noProductsConfigured
    case productsUnavailable
    case configurationFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .flowNotFound(let id):
            return "Experience not found: \(id)"
        case .invalidManifest:
            return "Invalid manifest data"
        case .downloadFailed:
            return "Failed to download flow assets"
        case .noProductsConfigured:
            return "No products configured for flow"
        case .productsUnavailable:
            return "Products unavailable from StoreKit"
        case .configurationFailed(let error):
            return "Experience configuration failed: \(error.localizedDescription)"
        }
    }
}
