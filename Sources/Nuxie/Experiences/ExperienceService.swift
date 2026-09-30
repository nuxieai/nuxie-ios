import Foundation

/// One show's hold on its prepared release, and how ready that release was.
struct ExperiencePreparedReleaseReservation: Sendable {
    /// Keeps the release prepared until the show ends. Nil when the
    /// Experience has no authenticated release to reserve.
    let reservation: ExperiencePresentationWarmReservation?
    let readiness: ExperiencePresentationReadiness
}

protocol ExperienceServiceProtocol: AnyObject, Sendable {
    func prepareJourneyProfile(
        _ snapshot: JourneyProfileCatalog.Snapshot?
    ) async throws -> PreparedJourneyProfileArtifacts

    /// Commits a prepared profile. When the catalog accepts it, the armed
    /// releases are handed to the prepared-release store, which prepares
    /// them in the background. The hand-off is bookkeeping only and never
    /// waits for preparation. A different `owner` drops what was prepared
    /// for the previous one, unless it is that owner's first sign-in.
    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        owner: PreparedReleaseOwner?,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool

    /// Reserves the Experience's prepared release for one show.
    func reservePreparedRelease(
        for experience: Experience
    ) async -> ExperiencePreparedReleaseReservation

    /// Pauses background preparation. Synchronous so a main-queue lifecycle
    /// observer can call it without waiting behind other lifecycle work.
    func onAppDidEnterBackground()

    /// Notes a system memory warning. Prepared releases are kept.
    func didReceiveMemoryWarning()

    /// Resumes background preparation once profile authority is current.
    func onAppBecameActive() async

    /// The profile was withdrawn without a replacement; nothing stays armed.
    func withdrawPreparedReleases(
        ownerDistinctId: String?,
        generation: UInt64
    ) async

    /// Drops everything prepared, queued, and in flight for the departing
    /// user. A nil id drops unconditionally.
    func discardPreparedReleases(departingDistinctId: String?) async

    /// Keeps prepared releases across a first sign-in by handing them to the
    /// arriving user. See `PreparedReleaseUserSwitchPolicy`.
    func transferPreparedReleases(from departingDistinctId: String, to arrivingDistinctId: String) async

    /// Stops background preparation and drops everything prepared.
    func shutdownPreparation() async

    /// Returns once background preparation is not running.
    func waitForPreparationIdle() async

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

extension ExperienceServiceProtocol {
    /// Commits without an owner. A nil owner never triggers the owner-change
    /// drop, so only tests and owner-less hosts use this form.
    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool {
        await commitJourneyProfile(
            prepared,
            owner: nil,
            generation: generation,
            admission: admission
        )
    }
}

final class ExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    /// Background preparation runs by default where the SDK presents
    /// Experiences (UIKit). Elsewhere a test must turn it on.
    #if canImport(UIKit)
    static let defaultAutomaticPreparation = true
    #else
    static let defaultAutomaticPreparation = false
    #endif

    private let catalog: JourneyReleaseCatalog
    private let releaseStore: any JourneyReleaseAcquiring
    private let preparedReleases: JourneyPreparedReleaseStore
    private let eventLog: EventCapturing
    private let transactionServiceProvider: @Sendable () -> TransactionService
    private let productService: ProductService
    private let systemEventSink: SystemEventSink
    private let presentationDiagnosticsEnabled: Bool
    private let videoDecoderPoolProvider: @MainActor @Sendable () -> ExperienceVideoDecoderPool?

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
        testStoreEnabled: Bool = false,
        automaticPreparation: Bool = ExperienceService.defaultAutomaticPreparation,
        preparationCache: ExperienceInteractivePreparationCache = .init(),
        videoDecoderPoolProvider: @escaping @MainActor @Sendable () -> ExperienceVideoDecoderPool? = { nil }
    ) {
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productService = productService
        self.systemEventSink = systemEventSink
        self.releaseStore = releaseStore
        self.presentationDiagnosticsEnabled = presentationDiagnosticsEnabled
        self.videoDecoderPoolProvider = videoDecoderPoolProvider
        catalog = JourneyReleaseCatalog(
            productService: productService,
            introEligibilityTokenProvider: introEligibilityTokenProvider,
            introEligibilityOverrideHealth: introEligibilityOverrideHealth,
            releaseStore: releaseStore,
            testStoreEnabled: testStoreEnabled
        )
        preparedReleases = JourneyPreparedReleaseStore(
            acquirer: releaseStore,
            cache: preparationCache,
            gate: ExperiencePreparationGate(),
            automaticPreparation: automaticPreparation
        )
    }

    /// The shared prepared-release store. Internal for tests.
    var preparedReleaseStore: JourneyPreparedReleaseStore { preparedReleases }

    func prepareJourneyProfile(
        _ snapshot: JourneyProfileCatalog.Snapshot?
    ) async throws -> PreparedJourneyProfileArtifacts {
        try await catalog.prepareJourneyProfile(snapshot)
    }

    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        owner: PreparedReleaseOwner?,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool {
        guard await catalog.commitJourneyProfile(
            prepared,
            generation: generation,
            admission: admission
        ) else { return false }
        await preparedReleases.replaceProfile(
            prepared,
            owner: owner,
            generation: generation,
            admission: admission
        )
        return true
    }

    func reservePreparedRelease(
        for experience: Experience
    ) async -> ExperiencePreparedReleaseReservation {
        guard let descriptorSHA256 = experience.authenticatedReleaseID?
            .descriptorSHA256 else {
            return ExperiencePreparedReleaseReservation(
                reservation: nil,
                readiness: .cold
            )
        }
        let (reservation, readiness) = await preparedReleases.reserve(
            descriptorSHA256: descriptorSHA256
        )
        return ExperiencePreparedReleaseReservation(
            reservation: reservation,
            readiness: readiness
        )
    }

    func onAppDidEnterBackground() {
        preparedReleases.gate.enterBackground()
    }

    func didReceiveMemoryWarning() {
        preparedReleases.gate.noteMemoryWarning()
    }

    func onAppBecameActive() async {
        await preparedReleases.onAppBecameActive()
    }

    func withdrawPreparedReleases(
        ownerDistinctId: String?,
        generation: UInt64
    ) async {
        await preparedReleases.withdrawProfile(
            ownerDistinctId: ownerDistinctId,
            generation: generation
        )
    }

    func discardPreparedReleases(departingDistinctId: String?) async {
        await preparedReleases.discard(departingDistinctId: departingDistinctId)
    }

    func transferPreparedReleases(
        from departingDistinctId: String,
        to arrivingDistinctId: String
    ) async {
        await preparedReleases.transferOwner(
            from: departingDistinctId,
            to: arrivingDistinctId
        )
    }

    func shutdownPreparation() async {
        await preparedReleases.shutdown()
    }

    func waitForPreparationIdle() async {
        await preparedReleases.waitForIdle()
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
            preparedReleases: preparedReleases,
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
            videoDecoderPool: videoDecoderPoolProvider(),
            transactionService: transactionServiceProvider(),
            productService: productService,
            systemEventSink: systemEventSink
        )
        controller.colorSchemeMode = colorSchemeMode
        controller.runtimeDelegate = runtimeDelegate
        // The show's trace context carries artifact acquisition and runtime
        // preparation spans, including readiness and prepared_release.
        controller.presentationTraceContext = (
            runtimeDelegate as? any ExperiencePresentationTraceContextProviding
        )?.presentationTraceContext
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
