import Combine
import Foundation

struct FeatureBalanceAuthority: Codable, Equatable, Sendable {
    let epoch: UUID
    let generation: UInt64
}

/// Observable object for reactive feature access in SwiftUI
///
/// Use this in SwiftUI views to reactively update when features change:
/// ```swift
/// struct MyView: View {
///     @ObservedObject var features = NuxieSDK.shared.features
///
///     var body: some View {
///         if features.isAllowed("premium_feature") {
///             PremiumContent()
///         } else {
///             UpgradePrompt()
///         }
///     }
/// }
/// ```
@MainActor
public final class FeatureInfo: ObservableObject {

    /// Readiness of the current customer-scoped Feature snapshot.
    public enum State: Equatable, Sendable {
        /// No profile snapshot has been admitted for the current customer.
        case unknown
        /// A profile is admitted, but visible access includes a purchase overlay.
        case reconciling
        /// A profile is admitted and visible access is fully authoritative.
        case ready
    }

    internal struct CommandBalanceEmission {
        fileprivate let featureId: String
        fileprivate let oldAccess: FeatureAccess
        fileprivate let newAccess: FeatureAccess
        fileprivate let projectionIdentityGeneration: UInt64
    }

    internal struct VisibleBalanceEmission {
        fileprivate let featureId: String
        fileprivate let newAccess: FeatureAccess
        fileprivate let projectionIdentityGeneration: UInt64
    }

    // MARK: - Published Properties

    /// All currently cached features keyed by feature ID
    @Published public private(set) var all: [String: FeatureAccess] = [:]

    /// Readiness of `all` for the current customer.
    @Published public private(set) var state: State = .unknown

    // MARK: - Internal Properties

    /// Callback for delegate notifications (set by NuxieSDK)
    internal var onFeatureChange: ((_ featureId: String, _ oldValue: FeatureAccess?, _ newValue: FeatureAccess) -> Void)?

    /// Per-feature authority fence shared by profiles, real-time checks, and
    /// purchase/authoritative-use updates. The epoch distinguishes process
    /// lifetimes and the generation never resets while this projection lives,
    /// so neither clock rollback nor identity cycling can make a replay fresh.
    private let balanceAuthorityEpoch = UUID()
    private var balanceAuthorityGenerations: [String: UInt64] = [:]
    /// Server/profile/command state. Optimistic purchase values never enter
    /// this dictionary and therefore cannot advance the authority fence.
    private var authoritative: [String: FeatureAccess] = [:]
    private var hasAdmittedProfile = false
    private var projectionEvidence: [OptimisticPurchaseEvidence]?
    private var projectionDescriptorAllowances:
        [String: [OptimisticEntitlementAllowance]]?
    private var projectionDistinctId = ""
    private var projectionPublicationEpoch: UUID?
    private var projectionPublicationGeneration: UInt64?
    private var visiblePublicationGeneration: UInt64 = 0
    private var projectionIdentityGeneration: UInt64 = 0

    /// One generation token gates every synchronous user-observable step. A
    /// nested publication invalidates the outer token; storage setters repair
    /// after invalidation because `@Published` notifies before committing the
    /// outer value, while callbacks only abandon their stale continuation.
    private struct VisiblePublicationToken {
        let generation: UInt64
    }

    private enum StalePublicationDisposition: Equatable {
        case repairCommittedStorage
        case abandon
    }

    // MARK: - Init

    /// Nonisolated so the composition root can construct the instance from
    /// any thread; all state access stays MainActor-isolated.
    public nonisolated init() {}

    // MARK: - Public Methods

    /// Check if a specific feature is allowed
    /// - Parameter featureId: The feature identifier
    /// - Returns: True if the feature exists and is allowed, false otherwise
    public func isAllowed(_ featureId: String) -> Bool {
        all[featureId]?.allowed ?? false
    }

    /// Check if a specific feature has remaining balance
    /// - Parameter featureId: The feature identifier
    /// - Returns: True if the feature is unlimited or has balance > 0
    public func hasBalance(_ featureId: String) -> Bool {
        all[featureId]?.hasBalance ?? false
    }

    /// Get access info for a specific feature
    /// - Parameter featureId: The feature identifier
    /// - Returns: FeatureAccess if cached, nil otherwise
    public func feature(_ featureId: String) -> FeatureAccess? {
        all[featureId]
    }

    /// Get the balance for a metered feature
    /// - Parameter featureId: The feature identifier
    /// - Returns: Current balance, nil if feature not found or is boolean type
    public func balance(_ featureId: String) -> Double? {
        all[featureId]?.balance
    }

    // MARK: - Internal Methods

    /// Update all features (called internally when profile/features refresh)
    /// - Parameter features: Dictionary of feature ID to FeatureAccess
    internal func update(_ features: [String: FeatureAccess]) {
        let invalidatedFeatureIds = Set(features.keys)
            .union(authoritative.keys)
            .union(all.keys)
            .union(balanceAuthorityGenerations.keys)
        for featureId in invalidatedFeatureIds {
            advanceAuthority(for: featureId)
        }
        authoritative = features
        publishVisibleProjection()
    }

    private func publish(_ features: [String: FeatureAccess], state: State) {
        let publication = beginVisiblePublication()
        let oldFeatures = all
        let capturedOnFeatureChange = onFeatureChange
        let delegateEmissions: [(
            featureId: String,
            oldAccess: FeatureAccess?,
            newAccess: FeatureAccess
        )] = Set(oldFeatures.keys).union(features.keys).sorted().compactMap { featureId in
            let oldAccess = oldFeatures[featureId]
            let newAccess = features[featureId] ?? .notFound
            guard oldAccess.map({ areEqual($0, newAccess) }) != true else {
                return nil
            }
            return (featureId, oldAccess, newAccess)
        }

        // Publish readiness first so synchronous `$all` observers see the
        // state that describes the values being delivered.
        guard publishObservableStep(
            publication,
            staleAfterEmission: .repairCommittedStorage,
            { self.state = state }
        ) else { return }
        guard publishObservableStep(
            publication,
            staleAfterEmission: .repairCommittedStorage,
            { self.all = features }
        ) else { return }

        guard let capturedOnFeatureChange else { return }
        for (featureId, oldAccess, newAccess) in delegateEmissions {
            guard publishObservableStep(
                publication,
                staleAfterEmission: .abandon,
                { capturedOnFeatureChange(featureId, oldAccess, newAccess) }
            ) else { return }
        }
    }

    internal func admitProfileSnapshot(
        _ features: [String: FeatureAccess],
        admittedAt: Date
    ) {
        _ = admittedAt
        hasAdmittedProfile = true
        update(features)
    }

    internal func balanceAuthority(for featureId: String) -> FeatureBalanceAuthority {
        FeatureBalanceAuthority(
            epoch: balanceAuthorityEpoch,
            generation: balanceAuthorityGenerations[featureId] ?? 0
        )
    }

    internal func commitCommandBalanceIfFresh(
        _ featureId: String,
        balance: Double,
        responseAuthority: FeatureBalanceAuthority
    ) -> CommandBalanceEmission? {
        let currentGeneration = balanceAuthorityGenerations[featureId] ?? 0
        let oldAccess: FeatureAccess
        if responseAuthority.epoch == balanceAuthorityEpoch {
            guard currentGeneration <= responseAuthority.generation else { return nil }
            guard let visibleAccess = all[featureId] else { return nil }
            oldAccess = visibleAccess
        } else {
            // A response from an earlier process may apply only while NOTHING
            // authoritative has been admitted for the key this process (the
            // Orchestration contract: an admitted profile balance always
            // outranks a recovered prior-process response, because the
            // response's server-side effect is already durable and the newer
            // profile reflects it). An overlay is never enough: a complete
            // profile that omitted the key must keep a recovered response
            // from resurrecting it.
            guard currentGeneration == 0,
                  let authoritativeAccess = authoritative[featureId] else { return nil }
            oldAccess = authoritativeAccess
        }
        let authoritativeAccess = authoritative[featureId]

        let newAccess = FeatureAccess.withBalance(
            balance,
            unlimited: authoritativeAccess?.unlimited ?? false,
            type: authoritativeAccess?.type ?? oldAccess.type
        )
        return CommandBalanceEmission(
            featureId: featureId,
            oldAccess: oldAccess,
            newAccess: newAccess,
            projectionIdentityGeneration: projectionIdentityGeneration
        )
    }

    internal func emitCommandBalance(_ emission: CommandBalanceEmission) {
        guard emission.projectionIdentityGeneration == projectionIdentityGeneration else {
            return
        }
        authoritative[emission.featureId] = emission.newAccess
        publishVisibleProjection()
    }

    /// Update a single feature (called internally after real-time checks)
    /// - Parameters:
    ///   - featureId: The feature identifier
    ///   - access: The updated feature access
    internal func update(
        _ featureId: String,
        access: FeatureAccess
    ) {
        advanceAuthority(for: featureId)
        authoritative[featureId] = access
        publishVisibleProjection()
    }

    /// Replaces the complete pure-projection input snapshot. Evidence and
    /// descriptor allowances remain separate so either missing input produces
    /// absence rather than an authoritative empty overlay.
    internal func replaceOptimisticProjection(
        evidence: [OptimisticPurchaseEvidence]?,
        descriptorAllowances: [String: [OptimisticEntitlementAllowance]]?,
        distinctId: String,
        publicationEpoch: UUID? = nil,
        publicationGeneration: UInt64? = nil
    ) {
        if let publicationEpoch {
            guard publicationEpoch == projectionPublicationEpoch else { return }
        }
        if let publicationGeneration {
            guard projectionPublicationGeneration.map({
                publicationGeneration >= $0
            }) ?? true else { return }
            projectionPublicationGeneration = publicationGeneration
        }
        projectionEvidence = evidence
        projectionDescriptorAllowances = descriptorAllowances
        // Explicit identity changes own this scope after initialization. A
        // delayed refresh for the previous customer may update retained pure
        // inputs, but it cannot switch which customer is viewing them.
        if projectionDistinctId.isEmpty {
            projectionDistinctId = distinctId
        }
        publishVisibleProjection()
    }

    /// Starts a customer-unknown composition root and installs its sole
    /// projection publisher. A draining observer from an old setup lifecycle
    /// cannot overwrite the new observer's snapshot.
    internal func beginOptimisticProjectionPublication(
        epoch: UUID,
        distinctId: String
    ) {
        projectionPublicationEpoch = epoch
        projectionPublicationGeneration = nil
        authoritative.removeAll()
        hasAdmittedProfile = false
        projectionEvidence = nil
        projectionDescriptorAllowances = nil
        projectionDistinctId = distinctId
        projectionIdentityGeneration &+= 1
        publishVisibleProjection()
    }

    /// Changes only the customer through which retained projection inputs are
    /// viewed. Evidence remains retained and becomes visible again if its
    /// pinned identity returns before reconciliation.
    internal func setProjectionDistinctId(_ distinctId: String) {
        guard projectionDistinctId != distinctId else { return }
        projectionDistinctId = distinctId
        projectionIdentityGeneration &+= 1
        authoritative.removeAll()
        hasAdmittedProfile = false
        publishVisibleProjection()
    }

    /// Whether the current identity has a complete, active optimistic overlay.
    /// This remains independent of readiness because `unknown` can still have
    /// an overlay before profile admission.
    internal var hasActiveOptimisticProjection: Bool {
        OptimisticEntitlementProjection.derive(
            evidence: projectionEvidence,
            descriptorAllowances: projectionDescriptorAllowances,
            distinctId: projectionDistinctId
        ) != nil
    }

    /// Clear all cached features
    internal func clear() {
        authoritative.removeAll()
        hasAdmittedProfile = false
        publishVisibleProjection()
    }

    /// Decrement the balance for a feature (for local UI feedback after usage)
    /// - Parameters:
    ///   - featureId: The feature identifier
    ///   - amount: The amount to decrement
    internal func prepareBalanceDecrement(
        _ featureId: String,
        amount: Double
    ) -> VisibleBalanceEmission? {
        guard let access = all[featureId], !access.unlimited else { return nil }

        let currentBalance = access.balance ?? 0
        let newBalance = max(0, currentBalance - amount)

        let newAccess = FeatureAccess.withBalance(
            newBalance,
            unlimited: false,
            type: access.type
        )

        return VisibleBalanceEmission(
            featureId: featureId,
            newAccess: newAccess,
            projectionIdentityGeneration: projectionIdentityGeneration
        )
    }

    internal func emitBalanceDecrement(_ emission: VisibleBalanceEmission) {
        guard emission.projectionIdentityGeneration == projectionIdentityGeneration else {
            return
        }
        var visible = all
        visible[emission.featureId] = emission.newAccess
        // This is provisional UI feedback, not an authoritative Feature
        // transition. Publishing it through `onFeatureChange` would expose an
        // intermediate value and let a reentrant identity change race the
        // command queue's decide-then-notify commit.
        let publication = beginVisiblePublication()
        _ = publishObservableStep(
            publication,
            staleAfterEmission: .repairCommittedStorage,
            { all = visible }
        )
    }

    internal func decrementBalance(_ featureId: String, amount: Double) {
        guard let emission = prepareBalanceDecrement(featureId, amount: amount) else {
            return
        }
        emitBalanceDecrement(emission)
    }

    /// Discards visual-only usage feedback and recomposes from the two owned
    /// inputs. Used when a newly journaled command is rejected terminally.
    internal func restoreVisibleProjection() {
        publishVisibleProjection()
    }

    // MARK: - Private Methods

    /// Compare two FeatureAccess values for equality
    private func areEqual(_ lhs: FeatureAccess, _ rhs: FeatureAccess) -> Bool {
        lhs.allowed == rhs.allowed &&
        lhs.unlimited == rhs.unlimited &&
        lhs.balance == rhs.balance &&
        lhs.type == rhs.type
    }

    private func advanceAuthority(for featureId: String) {
        balanceAuthorityGenerations[featureId, default: 0] &+= 1
    }

    private func beginVisiblePublication() -> VisiblePublicationToken {
        visiblePublicationGeneration &+= 1
        return VisiblePublicationToken(generation: visiblePublicationGeneration)
    }

    /// Executes one synchronous observable step only while its publication is
    /// current. The checks deliberately surround the step: Combine and delegate
    /// callbacks can reenter identity/projection mutation before the step
    /// returns to its caller.
    @discardableResult
    private func publishObservableStep(
        _ publication: VisiblePublicationToken,
        staleAfterEmission: StalePublicationDisposition,
        _ emission: () -> Void
    ) -> Bool {
        guard visiblePublicationGeneration == publication.generation else {
            return false
        }
        emission()
        guard visiblePublicationGeneration == publication.generation else {
            if staleAfterEmission == .repairCommittedStorage {
                repairVisibleProjectionStorage()
            }
            return false
        }
        return true
    }

    private func publishVisibleProjection() {
        let projection = visibleProjection()
        publish(projection.features, state: projection.state)
    }

    /// A nested publication already emitted the coherent delegate transition.
    /// This path only repairs values that an outer `@Published` setter commits
    /// after returning from that nested publication.
    private func repairVisibleProjectionStorage() {
        let projection = visibleProjection()
        let publication = beginVisiblePublication()
        guard publishObservableStep(
            publication,
            staleAfterEmission: .repairCommittedStorage,
            { state = projection.state }
        ) else { return }
        _ = publishObservableStep(
            publication,
            staleAfterEmission: .repairCommittedStorage,
            { all = projection.features }
        )
    }

    private func visibleProjection() -> (
        features: [String: FeatureAccess],
        state: State
    ) {
        let overlay = OptimisticEntitlementProjection.derive(
            evidence: projectionEvidence,
            descriptorAllowances: projectionDescriptorAllowances,
            distinctId: projectionDistinctId
        )
        var visible = authoritative
        for (featureId, projected) in overlay ?? [:] {
            visible[featureId] = wideningJoin(
                authoritative: authoritative[featureId],
                overlay: projected
            )
        }
        let readiness: State
        if !hasAdmittedProfile {
            readiness = .unknown
        } else if overlay == nil {
            readiness = .ready
        } else {
            readiness = .reconciling
        }
        return (visible, readiness)
    }

    private func wideningJoin(
        authoritative: FeatureAccess?,
        overlay: OptimisticEntitlementOverlay
    ) -> FeatureAccess {
        let overlayType: FeatureType = switch overlay.kind {
        case .boolean: .boolean
        case .metered: .metered
        case .creditSystem: .creditSystem
        }
        let type = authoritative?.type ?? overlayType
        if type == .boolean || overlay.kind == .boolean {
            return FeatureAccess(
                allowed: true,
                unlimited: authoritative?.unlimited == true || overlay.unlimited,
                balance: authoritative?.balance,
                type: type
            )
        }
        let unlimited = authoritative?.unlimited == true || overlay.unlimited
        let balance = unlimited
            ? authoritative?.balance
            : (authoritative?.balance ?? 0) + (overlay.allowance ?? 0)
        return FeatureAccess(
            allowed: authoritative?.allowed == true || unlimited || (balance ?? 0) > 0,
            unlimited: unlimited,
            balance: balance,
            type: type
        )
    }
}
