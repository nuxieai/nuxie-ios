import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol ExperienceServiceProtocol: AnyObject, Sendable {
    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV2?
    ) async throws -> [ExperienceReference]?

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
}

extension ExperienceServiceProtocol {
    func waitForWarmLoadsToSettle() async {}
    func suspendWarmLoads() async {}
    func onAppDidEnterBackground() async {}
    func onAppBecameActive() async {}
    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV2?
    ) async throws -> [ExperienceReference]? { nil }
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
        warmLoadsInitiallySuspended: Bool = false,
        testStoreEnabled: Bool = false
    ) {
        self.eventLog = eventLog
        self.transactionServiceProvider = transactionServiceProvider
        self.productService = productService
        self.systemEventSink = systemEventSink
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

    func replaceReleaseProfile(
        _ profile: ExperienceReleaseProfileV2?
    ) async throws -> [ExperienceReference]? {
        try await experienceLoader.replaceReleaseProfile(profile)
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
