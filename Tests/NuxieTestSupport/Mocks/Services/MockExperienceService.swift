import Foundation
@testable import Nuxie

final class MockExperienceService: ExperienceServiceProtocol, @unchecked Sendable {
    /// One call into the prepared-release surface, in call order.
    enum PreparationCall: Equatable, Sendable {
        case commit(ownerDistinctId: String?, generation: UInt64)
        case reserve(descriptorSHA256: String?)
        case enterBackground
        case memoryWarning
        case becameActive
        case withdraw(ownerDistinctId: String?, generation: UInt64)
        case discard(departingDistinctId: String?)
        case transfer(from: String, to: String)
        case shutdown
        case waitForIdle
    }

    private let lock = NSRecursiveLock()
    private var recordedPreparationCalls: [PreparationCall] = []
    private var recordedReservationReleases: [String] = []
    /// Readiness returned for a reserved descriptor SHA-256. A descriptor
    /// without an entry reserves nothing and reports `.cold`.
    var readinessByDescriptorSHA256: [String: ExperiencePresentationReadiness] = [:]
    /// Observes every recorded preparation call, synchronously, so a test can
    /// merge it into one ordered log with other collaborators.
    var preparationCallObserver: (@Sendable (PreparationCall) -> Void)?
    /// Observes a reservation's release closure.
    var reservationReleaseObserver: (@Sendable (String) -> Void)?

    var preparationCalls: [PreparationCall] {
        withLock { recordedPreparationCalls }
    }

    var reservationReleases: [String] {
        withLock { recordedReservationReleases }
    }
    private var latestProfileGeneration: UInt64 = 0
    private var productAuthorityResolution:
        ActiveProductEvidenceAuthorityResolution = .unavailable
    private var deliverProductAuthorityOnHandlerRegistration = false
    private var productAuthorityChangeHandler: (@Sendable () async -> Void)?

    var journeyArtifactPreparationHandler: (@Sendable (JourneyProfileCatalog.Snapshot?) async throws -> PreparedJourneyProfileArtifacts)?
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
        if let handler = withLock({ journeyArtifactPreparationHandler }) {
            return try await handler(snapshot)
        }
        return PreparedJourneyProfileArtifacts(snapshot: snapshot)
    }

    @discardableResult
    func commitJourneyProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        ownerDistinctId: String?,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async -> Bool {
        let committed = withLock { () -> Bool in
            guard generation >= latestProfileGeneration,
                  admission?() != false else { return false }
            latestProfileGeneration = generation
            committedJourneyReleaseCounts.append(
                prepared.snapshot?.releasesByDigest.count
            )
            return true
        }
        if committed {
            record(.commit(ownerDistinctId: ownerDistinctId, generation: generation))
        }
        return committed
    }

    func reservePreparedRelease(
        for experience: Experience
    ) async -> ExperiencePreparedReleaseReservation {
        let descriptorSHA256 = experience.authenticatedReleaseID?.descriptorSHA256
        record(.reserve(descriptorSHA256: descriptorSHA256))
        guard let descriptorSHA256,
              let readiness = withLock({ readinessByDescriptorSHA256[descriptorSHA256] }) else {
            return ExperiencePreparedReleaseReservation(
                reservation: nil,
                readiness: .cold
            )
        }
        let reservation = ExperiencePresentationWarmReservation { [weak self] in
            guard let self else { return }
            let observer = self.withLock { () -> (@Sendable (String) -> Void)? in
                self.recordedReservationReleases.append(descriptorSHA256)
                return self.reservationReleaseObserver
            }
            observer?(descriptorSHA256)
        }
        return ExperiencePreparedReleaseReservation(
            reservation: reservation,
            readiness: readiness
        )
    }

    func onAppDidEnterBackground() {
        record(.enterBackground)
    }

    func didReceiveMemoryWarning() {
        record(.memoryWarning)
    }

    func onAppBecameActive() async {
        record(.becameActive)
    }

    func withdrawPreparedReleases(
        ownerDistinctId: String?,
        generation: UInt64
    ) async {
        record(.withdraw(ownerDistinctId: ownerDistinctId, generation: generation))
    }

    func discardPreparedReleases(departingDistinctId: String?) async {
        record(.discard(departingDistinctId: departingDistinctId))
    }

    func transferPreparedReleases(
        from departingDistinctId: String,
        to arrivingDistinctId: String
    ) async {
        record(.transfer(from: departingDistinctId, to: arrivingDistinctId))
    }

    func shutdownPreparation() async {
        record(.shutdown)
    }

    func waitForPreparationIdle() async {
        record(.waitForIdle)
    }

    private func record(_ call: PreparationCall) {
        let observer = withLock { () -> (@Sendable (PreparationCall) -> Void)? in
            recordedPreparationCalls.append(call)
            return preparationCallObserver
        }
        observer?(call)
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
            journeyArtifactPreparationHandler = nil
            preparedJourneyReleaseCounts = []
            committedJourneyReleaseCounts = []
            optimisticAllowancesByStoreProductId = [:]
            shouldFailExperienceDisplay = false
            failureError = nil
            mockViewControllers = [:]
            defaultMockViewController = nil
            viewControllerHandler = nil
            recordedPreparationCalls = []
            recordedReservationReleases = []
            readinessByDescriptorSHA256 = [:]
            preparationCallObserver = nil
            reservationReleaseObserver = nil
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
