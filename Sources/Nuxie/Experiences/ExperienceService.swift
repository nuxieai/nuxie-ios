import Foundation

protocol ExperienceServiceProtocol: AnyObject, Sendable {
    func prepareJourneyProfile(
        _ snapshot: JourneyProfileCatalog.Snapshot?
    ) async throws -> PreparedJourneyProfileArtifacts

    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool

    @MainActor
    func viewController(
        forJourney release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController

    func clearCache() async

    func purchaseEvidenceAuthority(
        storeProductId: String
    ) async -> ActiveProductEvidenceAuthorityResolution

    func optimisticEntitlementAllowances(
        releaseDescriptorSHA256: String?,
        productId: String?,
        storeProductId: String
    ) async -> [OptimisticEntitlementAllowance]?

    func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    )
}

final class ExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    private let catalog: JourneyReleaseCatalog
    private let releaseStore: any JourneyReleaseAcquiring
    private let eventLog: EventCapturing
    private let transactionServiceProvider: @Sendable () -> TransactionService
    private let productService: ProductService
    private let systemEventSink: SystemEventSink
    private let presentationDiagnosticsEnabled: Bool

    init(
        productService: ProductService,
        introEligibilityTokenProvider: any IntroEligibilityTokenProviding =
            UnavailableIntroEligibilityTokenProvider(),
        introEligibilityOverrideHealth: IntroEligibilityOverrideHealth =
            IntroEligibilityOverrideHealth(),
        eventLog: EventCapturing,
        transactionServiceProvider: @escaping @Sendable () -> TransactionService,
        systemEventSink: SystemEventSink,
        releaseStore: any JourneyReleaseAcquiring,
        presentationDiagnosticsEnabled: Bool = false,
        testStoreEnabled: Bool = false
    ) {
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productService = productService
        self.systemEventSink = systemEventSink
        self.releaseStore = releaseStore
        self.presentationDiagnosticsEnabled = presentationDiagnosticsEnabled
        catalog = JourneyReleaseCatalog(
            productService: productService,
            introEligibilityTokenProvider: introEligibilityTokenProvider,
            introEligibilityOverrideHealth: introEligibilityOverrideHealth,
            releaseStore: releaseStore,
            testStoreEnabled: testStoreEnabled
        )
    }

    func prepareJourneyProfile(
        _ snapshot: JourneyProfileCatalog.Snapshot?
    ) async throws -> PreparedJourneyProfileArtifacts {
        try await catalog.prepareJourneyProfile(snapshot)
    }

    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool {
        await catalog.commitJourneyProfile(
            prepared,
            generation: generation,
            admission: admission
        )
    }

    func purchaseEvidenceAuthority(
        storeProductId: String
    ) async -> ActiveProductEvidenceAuthorityResolution {
        await catalog.purchaseEvidenceAuthority(
            storeProductId: storeProductId
        )
    }

    func optimisticEntitlementAllowances(
        releaseDescriptorSHA256: String?,
        productId: String?,
        storeProductId: String
    ) async -> [OptimisticEntitlementAllowance]? {
        await catalog.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: releaseDescriptorSHA256,
            productId: productId,
            storeProductId: storeProductId
        )
    }

    func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        Task { [catalog] in
            await catalog.setProductAuthorityChangeHandler(handler)
        }
    }

    @MainActor
    func viewController(
        forJourney release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .system
    ) async throws -> ExperienceViewController {
        let introEligibilityAuthorization = (
            runtimeDelegate as? any IntroEligibilityAuthorizationContextProviding
        )?.introEligibilityAuthorizationContext
        let prepared = try await releaseStore.preparePresentation(
            release: release,
            delivery: delivery,
            pinnedArtifacts: pinnedArtifacts,
            productResolver: { [catalog] screenID in
                try await catalog.productsForJourneyPresentation(
                    release: release,
                    screenID: screenID,
                    introEligibilityAuthorization: introEligibilityAuthorization
                )
            }
        )
        let controller = ExperienceViewController(
            experience: prepared.experience,
            artifactLoader: prepared.artifactLoader,
            eventLog: eventLog,
            presentationDiagnosticsEnabled: presentationDiagnosticsEnabled,
            transactionService: transactionServiceProvider(),
            productService: productService,
            systemEventSink: systemEventSink
        )
        controller.colorSchemeMode = colorSchemeMode
        controller.runtimeDelegate = runtimeDelegate
        controller.notificationPermissionEventReceiver =
            runtimeDelegate as? NotificationPermissionEventReceiver
        controller.requestPermissionEventReceiver =
            runtimeDelegate as? RequestPermissionEventReceiver
        controller.trackingPermissionEventReceiver =
            runtimeDelegate as? TrackingPermissionEventReceiver
        return controller
    }

    func clearCache() async {
        await catalog.clearCache()
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
