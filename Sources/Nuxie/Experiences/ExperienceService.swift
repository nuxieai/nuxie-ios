import Foundation

protocol ExperienceServiceProtocol: AnyObject, Sendable {
    func registerExperiences(
        _ remotes: [RemoteExperience],
        assetBaseURL: String
    ) async

    func prefetchExperiences(
        _ remotes: [RemoteExperience],
        assetBaseURL: String
    ) async

    func removeExperiences(_ versionIds: [String]) async

    func retainPackages(for remotes: [RemoteExperience]) async

    func fetchExperience(id: String) async throws -> Experience

    func fetchExperience(
        experienceId: String,
        versionId: String
    ) async throws -> Experience

    @MainActor
    func viewController(for versionId: String) async throws -> ExperienceViewController

    @MainActor
    func viewController(
        for versionId: String,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController

    func clearCache() async
}

final class ExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    private let experienceStore: ExperienceStore
    private let packageStore: ExperiencePackageStore
    private let eventLog: EventCapturing
    private let transactionServiceProvider: @Sendable () -> TransactionService
    private let productService: ProductService
    private let systemEventSink: SystemEventSink

    @MainActor
    private lazy var viewControllerCache = ExperienceViewControllerCache(
        packageStore: packageStore,
        eventLog: eventLog,
        transactionServiceProvider: transactionServiceProvider,
        productService: productService,
        systemEventSink: systemEventSink
    )

    internal init(
        api: ExperienceFetching,
        productService: ProductService,
        eventLog: EventCapturing,
        transactionServiceProvider: @escaping @Sendable () -> TransactionService,
        systemEventSink: SystemEventSink,
        packageStore: ExperiencePackageStore? = nil
    ) {
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productService = productService
        self.systemEventSink = systemEventSink
        let packageStore = packageStore ?? ExperiencePackageStore()
        self.packageStore = packageStore
        experienceStore = ExperienceStore(
            api: api,
            productService: productService,
            packageStore: packageStore
        )
    }

    func prefetchExperiences(
        _ remotes: [RemoteExperience],
        assetBaseURL: String
    ) async {
        guard let baseURL = URL(string: assetBaseURL) else {
            LogError("Profile returned an invalid assetBaseUrl: \(assetBaseURL)")
            return
        }
        await experienceStore.preloadPackages(
            remotes,
            assetBaseURL: baseURL
        )
    }

    func registerExperiences(
        _ remotes: [RemoteExperience],
        assetBaseURL: String
    ) async {
        guard let baseURL = URL(string: assetBaseURL) else {
            LogError("Profile returned an invalid assetBaseUrl: \(assetBaseURL)")
            return
        }
        await experienceStore.registerExperiences(
            remotes,
            assetBaseURL: baseURL
        )
    }

    func removeExperiences(_ versionIds: [String]) async {
        for versionId in versionIds {
            await experienceStore.removeExperience(versionId: versionId)
        }
        await MainActor.run {
            for versionId in versionIds {
                viewControllerCache.removeViewController(for: versionId)
            }
        }
    }

    func retainPackages(for remotes: [RemoteExperience]) async {
        await experienceStore.evictPackages(retaining: remotes)
    }

    func fetchExperience(id: String) async throws -> Experience {
        try await experienceStore.experience(versionId: id)
    }

    func fetchExperience(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        try await experienceStore.experience(
            experienceId: experienceId,
            versionId: versionId
        )
    }

    @MainActor
    func viewController(for experience: Experience) -> ExperienceViewController {
        if let cached = viewControllerCache.updateCachedViewControllerIfNeeded(
            for: experience
        ) {
            return cached
        }
        return viewControllerCache.createViewController(for: experience)
    }

    @MainActor
    func viewController(for versionId: String) async throws -> ExperienceViewController {
        try await viewController(for: versionId, colorSchemeMode: .light)
    }

    @MainActor
    func viewController(
        for versionId: String,
        colorSchemeMode: ExperienceColorSchemeMode = .light
    ) async throws -> ExperienceViewController {
        let experience = try await fetchExperience(id: versionId)
        let controller = viewController(for: experience)
        if controller.colorSchemeMode != colorSchemeMode {
            controller.colorSchemeMode = colorSchemeMode
        }
        return controller
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        try await viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .light
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .light
    ) async throws -> ExperienceViewController {
        let controller = try await viewController(
            for: versionId,
            colorSchemeMode: colorSchemeMode
        )
        controller.runtimeDelegate = runtimeDelegate
        controller.notificationPermissionEventReceiver =
            runtimeDelegate as? NotificationPermissionEventReceiver
        controller.trackingPermissionEventReceiver =
            runtimeDelegate as? TrackingPermissionEventReceiver
        return controller
    }

    func clearCache() async {
        await experienceStore.clearCache()
        await packageStore.clearCache()
        await MainActor.run {
            viewControllerCache.clearCache()
        }
    }

    @MainActor
    func clearViewControllerCache() {
        viewControllerCache.clearCache()
    }
}

enum ExperienceError: LocalizedError {
    case notFound(String)
    case invalidManifest
    case downloadFailed
    case noProductsConfigured
    case productsUnavailable
    case configurationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            "Experience not found: \(id)"
        case .invalidManifest:
            "Invalid experience package manifest"
        case .downloadFailed:
            "Failed to download experience package"
        case .noProductsConfigured:
            "No products configured for experience"
        case .productsUnavailable:
            "Products unavailable from StoreKit"
        case .configurationFailed(let error):
            "Experience configuration failed: \(error.localizedDescription)"
        }
    }
}
