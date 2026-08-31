import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct PreparedExperienceReleaseProfile: Sendable {
    let profile: ExperienceReleaseProfile?
    let catalog: AuthenticatedExperienceReleaseCatalog?
    let references: [ExperienceReference]?

    init(
        profile: ExperienceReleaseProfile?,
        catalog: AuthenticatedExperienceReleaseCatalog?,
        references: [ExperienceReference]? = nil
    ) {
        self.profile = profile
        self.catalog = catalog
        self.references = references ?? catalog?.references
    }
}

/// Immutable authenticated behavior for one admitted profile generation.
/// Routing keeps this value for the whole operation, so a newer profile can
/// replace the loader's live catalog without invalidating in-flight lookups.
struct ExperienceRoutingCatalog: Sendable {
    let generation: UInt64
    let references: [ExperienceReference]
    private let resolve: @Sendable (String, String) async throws -> Experience

    init(
        generation: UInt64,
        references: [ExperienceReference],
        resolve: @escaping @Sendable (String, String) async throws -> Experience
    ) {
        self.generation = generation
        self.references = references
        self.resolve = resolve
    }

    func experience(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        try await resolve(experienceId, versionId)
    }
}

protocol ExperienceServiceProtocol: AnyObject, Sendable {
    /// Legacy low-level test/qualification entry point. ProfileService uses
    /// the generation-stamped prepare/commit pair below.
    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> [ExperienceReference]?

    func prepareReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> PreparedExperienceReleaseProfile

    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64
    ) async throws -> ExperienceRoutingCatalog?
    /// Commits a prepared release profile, additionally evaluating the
    /// supplied admission at the mutation points so an invalidated admission
    /// (identity or locale change) cannot install stale release authority.
    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async throws -> ExperienceRoutingCatalog?

    func fetchExperience(id: String) async throws -> Experience

    func fetchExperience(
        experienceId: String,
        versionId: String
    ) async throws -> Experience

    func fetchExperience(
        experienceId: String,
        versionId: String,
        presentationTraceContext: ExperiencePresentationTraceContext?
    ) async throws -> Experience

    /// Authenticated descriptor behavior used by journey routing before any
    /// render object or StoreKit work is allowed to begin.
    func experienceForJourneyControl(
        experienceId: String,
        versionId: String
    ) async throws -> Experience

    func validatesPresentationCommit(
        _ commit: JourneyPendingPresentation
    ) async -> Bool

    func isPresentationMemoryWarm(
        _ commit: JourneyPendingPresentation
    ) async -> Bool

    func isPresentationMemoryWarm(
        for experience: Experience
    ) async -> Bool

    func reserveMemoryWarmPresentation(
        for experience: Experience
    ) async -> ExperiencePresentationWarmReservation?

    func presentationArtifact(
        for experience: Experience,
        initialScreenID: String
    ) async throws -> AcquiredExperienceArtifact

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

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        presentationTraceContext: ExperiencePresentationTraceContext?,
        initialScreenID: String?
    ) async throws -> ExperienceViewController

    func clearCache() async

    /// Internal qualification boundary for observing a genuinely memory-warm
    /// profile without exposing preload task implementation details.
    func waitForWarmLoadsToSettle() async

    /// Internal qualification boundary that disables speculative release
    /// preparation before profile admission.
    func suspendWarmLoads() async

    func onAppDidEnterBackground() async
    func onAppBecameActive() async

    /// Receipt authority derived only from authenticated active release Products.
    func purchaseEvidenceAuthority(
        storeProductId: String
    ) async -> ActiveProductEvidenceAuthorityResolution

    /// Signed descriptor allowances used with retained StoreKit evidence to
    /// derive the optimistic Feature overlay.
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
    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> [ExperienceReference]? {
        let prepared = try await prepareReleaseProfile(profile)
        let committed = try await commitReleaseProfile(prepared, generation: 0)
        return profile == nil ? nil : committed?.references
    }
    func waitForWarmLoadsToSettle() async {}
    func suspendWarmLoads() async {}
    func onAppDidEnterBackground() async {}
    func onAppBecameActive() async {}
    func purchaseEvidenceAuthority(
        storeProductId: String
    ) async -> ActiveProductEvidenceAuthorityResolution { .unavailable }
    func optimisticEntitlementAllowances(
        releaseDescriptorSHA256: String?,
        productId: String?,
        storeProductId: String
    ) async -> [OptimisticEntitlementAllowance]? {
        _ = releaseDescriptorSHA256
        _ = productId
        _ = storeProductId
        return nil
    }
    func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) { _ = handler }
    func prepareReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> PreparedExperienceReleaseProfile {
        PreparedExperienceReleaseProfile(profile: profile, catalog: nil)
    }
    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async throws -> ExperienceRoutingCatalog? {
        if let admission, !admission() { return nil }
        return try await commitReleaseProfile(prepared, generation: generation)
    }

    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64
    ) async throws -> ExperienceRoutingCatalog? {
        let references = prepared.references ?? []
        return ExperienceRoutingCatalog(
            generation: generation,
            references: references
        ) { [self] experienceId, versionId in
            try await experienceForJourneyControl(
                experienceId: experienceId,
                versionId: versionId
            )
        }
    }
    func fetchExperience(
        experienceId: String,
        versionId: String,
        presentationTraceContext: ExperiencePresentationTraceContext?
    ) async throws -> Experience {
        try await fetchExperience(
            experienceId: experienceId,
            versionId: versionId
        )
    }
    func experienceForJourneyControl(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        try await fetchExperience(experienceId: experienceId, versionId: versionId)
    }
    func validatesPresentationCommit(
        _ commit: JourneyPendingPresentation
    ) async -> Bool { false }
    func isPresentationMemoryWarm(
        _ commit: JourneyPendingPresentation
    ) async -> Bool { false }
    func isPresentationMemoryWarm(
        for experience: Experience
    ) async -> Bool {
        _ = experience
        return false
    }
    func reserveMemoryWarmPresentation(
        for experience: Experience
    ) async -> ExperiencePresentationWarmReservation? {
        _ = experience
        return nil
    }
    func presentationArtifact(
        for experience: Experience,
        initialScreenID: String
    ) async throws -> AcquiredExperienceArtifact {
        _ = experience
        _ = initialScreenID
        throw ExperienceReleaseAcquisitionError.invalidProfileEntry
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        presentationTraceContext: ExperiencePresentationTraceContext?
    ) async throws -> ExperienceViewController {
        try await viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode
        )
    }
}

final class ExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    private let experienceLoader: ExperienceLoader
    private let eventLog: EventCapturing
    private let transactionServiceProvider: @Sendable () -> TransactionService
    private let productService: ProductService
    private let systemEventSink: SystemEventSink
    private let presentationDiagnosticsEnabled: Bool
    private var memoryPressureObserver: NSObjectProtocol?

    @MainActor private var storedViewControllerCache: ExperienceViewControllerCache?

    @MainActor
    private var viewControllerCache: ExperienceViewControllerCache {
        if let storedViewControllerCache { return storedViewControllerCache }
        let experienceLoader = experienceLoader
        let created = ExperienceViewControllerCache(
            eventLog: eventLog,
            transactionServiceProvider: transactionServiceProvider,
            productService: productService,
            systemEventSink: systemEventSink,
            presentationDiagnosticsEnabled: presentationDiagnosticsEnabled,
            artifactLoader: { experience, traceContext, initialScreenID in
                try await experienceLoader.presentationArtifact(
                    for: experience,
                    initialScreenID: initialScreenID,
                    presentationTraceContext: traceContext
                )
            }
        )
        storedViewControllerCache = created
        return created
    }

    internal init(
        productService: ProductService,
        introEligibilityTokenProvider: any IntroEligibilityTokenProviding =
            UnavailableIntroEligibilityTokenProvider(),
        introEligibilityOverrideHealth: IntroEligibilityOverrideHealth =
            IntroEligibilityOverrideHealth(),
        eventLog: EventCapturing,
        transactionServiceProvider: @escaping @Sendable () -> TransactionService,
        systemEventSink: SystemEventSink,
        releaseStore: ExperienceReleaseAcquisitionStore,
        presentationDiagnosticsEnabled: Bool = false,
        warmLoadsInitiallySuspended: Bool = false,
        testStoreEnabled: Bool = false
    ) {
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productService = productService
        self.systemEventSink = systemEventSink
        self.presentationDiagnosticsEnabled = presentationDiagnosticsEnabled
        experienceLoader = ExperienceLoader(
            productService: productService,
            introEligibilityTokenProvider: introEligibilityTokenProvider,
            introEligibilityOverrideHealth: introEligibilityOverrideHealth,
            releaseStore: releaseStore,
            warmLoadsInitiallySuspended: warmLoadsInitiallySuspended,
            testStoreEnabled: testStoreEnabled
        )
#if canImport(UIKit)
        let experienceLoader = experienceLoader
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await experienceLoader.handleMemoryPressure() }
        }
#endif
    }

    deinit {
        if let memoryPressureObserver {
            NotificationCenter.default.removeObserver(memoryPressureObserver)
        }
    }

    func prepareReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> PreparedExperienceReleaseProfile {
        try await experienceLoader.prepareReleaseProfile(profile)
    }

    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64
    ) async throws -> ExperienceRoutingCatalog? {
        try await experienceLoader.commitReleaseProfile(prepared, generation: generation)
    }

    func commitReleaseProfile(
        _ prepared: PreparedExperienceReleaseProfile,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async throws -> ExperienceRoutingCatalog? {
        // Forward the admission to the loader so its mutation-point checks
        // run in production; the protocol default would swallow it.
        try await experienceLoader.commitReleaseProfile(
            prepared,
            generation: generation,
            admission: admission
        )
    }

    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfile?
    ) async throws -> [ExperienceReference]? {
        try await experienceLoader.replaceReleaseProfile(profile)
    }

    func purchaseEvidenceAuthority(
        storeProductId: String
    ) async -> ActiveProductEvidenceAuthorityResolution {
        await experienceLoader.purchaseEvidenceAuthority(
            storeProductId: storeProductId
        )
    }

    func optimisticEntitlementAllowances(
        releaseDescriptorSHA256: String?,
        productId: String?,
        storeProductId: String
    ) async -> [OptimisticEntitlementAllowance]? {
        await experienceLoader.optimisticEntitlementAllowances(
            releaseDescriptorSHA256: releaseDescriptorSHA256,
            productId: productId,
            storeProductId: storeProductId
        )
    }

    func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        Task {
            await experienceLoader.setProductAuthorityChangeHandler(handler)
        }
    }

    func waitForWarmLoadsToSettle() async {
        await experienceLoader.waitForWarmLoadsToSettle()
    }

    func suspendWarmLoads() async {
        await experienceLoader.suspendWarmLoads()
    }

    func onAppDidEnterBackground() async {
        await experienceLoader.onAppDidEnterBackground()
    }

    func onAppBecameActive() async {
        await experienceLoader.onAppBecameActive()
    }

    func fetchExperience(id: String) async throws -> Experience {
        try await experienceLoader.experience(versionId: id)
    }

    func fetchExperience(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        try await experienceLoader.experience(
            experienceId: experienceId,
            versionId: versionId
        )
    }

    func experienceForJourneyControl(
        experienceId: String,
        versionId: String
    ) async throws -> Experience {
        try await experienceLoader.experienceForJourneyControl(
            experienceId: experienceId,
            versionId: versionId
        )
    }

    func validatesPresentationCommit(
        _ commit: JourneyPendingPresentation
    ) async -> Bool {
        await experienceLoader.validatesPresentationCommit(commit)
    }

    func isPresentationMemoryWarm(
        _ commit: JourneyPendingPresentation
    ) async -> Bool {
        await experienceLoader.isPresentationMemoryWarm(commit)
    }

    func isPresentationMemoryWarm(
        for experience: Experience
    ) async -> Bool {
        await experienceLoader.isPresentationMemoryWarm(for: experience)
    }

    func reserveMemoryWarmPresentation(
        for experience: Experience
    ) async -> ExperiencePresentationWarmReservation? {
        await experienceLoader.reserveMemoryWarmPresentation(for: experience)
    }

    func presentationArtifact(
        for experience: Experience,
        initialScreenID: String
    ) async throws -> AcquiredExperienceArtifact {
        try await experienceLoader.presentationArtifact(
            for: experience,
            initialScreenID: initialScreenID
        )
    }

    func fetchExperience(
        experienceId: String,
        versionId: String,
        presentationTraceContext: ExperiencePresentationTraceContext?
    ) async throws -> Experience {
        try await experienceLoader.experience(
            experienceId: experienceId,
            versionId: versionId,
            presentationTraceContext: presentationTraceContext
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
        try await viewController(for: versionId, colorSchemeMode: .system)
    }

    @MainActor
    func viewController(
        for versionId: String,
        colorSchemeMode: ExperienceColorSchemeMode = .system
    ) async throws -> ExperienceViewController {
        try await viewController(
            for: versionId,
            runtimeDelegate: nil,
            colorSchemeMode: colorSchemeMode,
            presentationTraceContext: nil,
            initialScreenID: nil
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        try await viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .system
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .system
    ) async throws -> ExperienceViewController {
        try await viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            presentationTraceContext: nil,
            initialScreenID: nil
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        presentationTraceContext: ExperiencePresentationTraceContext?
    ) async throws -> ExperienceViewController {
        try await viewController(
            for: versionId,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            presentationTraceContext: presentationTraceContext,
            initialScreenID: nil
        )
    }

    @MainActor
    func viewController(
        for versionId: String,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        presentationTraceContext: ExperiencePresentationTraceContext?,
        initialScreenID: String?
    ) async throws -> ExperienceViewController {
        let introEligibilityAuthorization = (
            runtimeDelegate as? any IntroEligibilityAuthorizationContextProviding
        )?.introEligibilityAuthorizationContext
        let experience: Experience
        if let initialScreenID {
            experience = try await experienceLoader.experienceForPresentation(
                versionId: versionId,
                initialScreenID: initialScreenID,
                presentationTraceContext: presentationTraceContext,
                introEligibilityAuthorization: introEligibilityAuthorization
            )
        } else {
            experience = try await experienceLoader.experienceForPresentation(
                versionId: versionId,
                introEligibilityAuthorization: introEligibilityAuthorization
            )
        }
        // A presented controller contains customer- and Journey-specific
        // checkout authority. Keep it outside the version cache so a stale
        // concurrent presentation cannot overwrite a newer presentation.
        let controller = viewControllerCache.createUncachedViewController(
            for: experience
        )
        if controller.colorSchemeMode != colorSchemeMode {
            controller.colorSchemeMode = colorSchemeMode
        }
        controller.runtimeDelegate = runtimeDelegate
        controller.presentationTraceContext = presentationTraceContext
        controller.notificationPermissionEventReceiver =
            runtimeDelegate as? NotificationPermissionEventReceiver
        controller.trackingPermissionEventReceiver =
            runtimeDelegate as? TrackingPermissionEventReceiver
        return controller
    }

    func clearCache() async {
        await experienceLoader.clearCache()
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
