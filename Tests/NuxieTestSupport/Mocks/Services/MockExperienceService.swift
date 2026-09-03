import Foundation
@testable import Nuxie

final class MockExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var latestProfileGeneration: UInt64 = 0
    private var productAuthorityResolution:
        ActiveProductEvidenceAuthorityResolution = .unavailable
    private var deliverProductAuthorityOnHandlerRegistration = false
    private var productAuthorityChangeHandler: (@Sendable () async -> Void)?

    var journeyArtifactPreparationFailuresRemaining = 0
    private(set) var preparedJourneyReleaseCounts: [Int?] = []
    private(set) var committedJourneyReleaseCounts: [Int?] = []
    var optimisticAllowancesByStoreProductId:
        [String: [OptimisticEntitlementAllowance]] = [:]

    var shouldFailExperienceDisplay = false
    var failureError: Error?
    var mockViewControllers: [String: ExperienceViewController] = [:]
    var defaultMockViewController: ExperienceViewController?
    var viewControllerHandler: (@Sendable () async -> Void)?

    func prepareJourneyProfile(
        _ snapshot: JourneyProfileCatalog.Snapshot?
    ) async throws -> PreparedJourneyProfileArtifacts {
        let count = snapshot?.releasesByDigest.count
        let shouldFail = withLock { () -> Bool in
            preparedJourneyReleaseCounts.append(count)
            guard snapshot != nil,
                  journeyArtifactPreparationFailuresRemaining > 0 else {
                return false
            }
            journeyArtifactPreparationFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return PreparedJourneyProfileArtifacts(snapshot: snapshot)
    }

    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool {
        withLock {
            guard generation >= latestProfileGeneration,
                  admission?() != false else { return false }
            latestProfileGeneration = generation
            committedJourneyReleaseCounts.append(
                prepared.snapshot?.releasesByDigest.count
            )
            return true
        }
    }

    @MainActor
    func viewController(
        forJourney release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController {
        _ = delivery
        _ = pinnedArtifacts
        let versionID = release.descriptor.identity.experienceVersionId
        let state = withLock {
            (
                shouldFailExperienceDisplay,
                failureError,
                mockViewControllers[versionID],
                defaultMockViewController,
                viewControllerHandler
            )
        }
        await state.4?()
        if state.0 {
            throw state.1 ?? MockExperienceServiceError.experienceNotFound(
                versionID
            )
        }
        let controller = state.2 ?? state.3
            ?? MockExperienceViewController(
                mockExperienceVersionId: versionID
            )
        controller.runtimeDelegate = runtimeDelegate
        controller.colorSchemeMode = colorSchemeMode
        return controller
    }

    func clearCache() async {
        withLock {
            mockViewControllers.removeAll()
            defaultMockViewController = nil
        }
    }

    func configureEagerProductAuthorityAdmission(
        _ resolution: ActiveProductEvidenceAuthorityResolution
    ) {
        withLock {
            productAuthorityResolution = resolution
            deliverProductAuthorityOnHandlerRegistration = true
        }
    }

    func purchaseEvidenceAuthority(
        storeProductId: String
    ) async -> ActiveProductEvidenceAuthorityResolution {
        _ = storeProductId
        return withLock { productAuthorityResolution }
    }

    func optimisticEntitlementAllowances(
        releaseDescriptorSHA256: String?,
        productId: String?,
        storeProductId: String
    ) async -> [OptimisticEntitlementAllowance]? {
        _ = releaseDescriptorSHA256
        _ = productId
        return withLock {
            optimisticAllowancesByStoreProductId[storeProductId]
        }
    }

    func setProductAuthorityChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        let deliver = withLock {
            productAuthorityChangeHandler = handler
            return deliverProductAuthorityOnHandlerRegistration
        }
        if deliver { Task { await handler() } }
    }

    func notifyProductAuthorityChanged() async {
        let handler = withLock { productAuthorityChangeHandler }
        await handler?()
    }

    func reset() {
        withLock {
            latestProfileGeneration = 0
            productAuthorityResolution = .unavailable
            deliverProductAuthorityOnHandlerRegistration = false
            productAuthorityChangeHandler = nil
            journeyArtifactPreparationFailuresRemaining = 0
            preparedJourneyReleaseCounts = []
            committedJourneyReleaseCounts = []
            optimisticAllowancesByStoreProductId = [:]
            shouldFailExperienceDisplay = false
            failureError = nil
            mockViewControllers = [:]
            defaultMockViewController = nil
            viewControllerHandler = nil
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum MockExperienceServiceError: Error {
    case experienceNotFound(String)
}
