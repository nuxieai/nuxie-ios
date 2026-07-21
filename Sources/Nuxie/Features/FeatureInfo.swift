import Combine
import Foundation

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

    // MARK: - Published Properties

    /// All currently cached features keyed by feature ID
    @Published public private(set) var all: [String: FeatureAccess] = [:]

    // MARK: - Internal Properties

    /// Callback for delegate notifications (set by NuxieSDK)
    internal var onFeatureChange: ((_ featureId: String, _ oldValue: FeatureAccess?, _ newValue: FeatureAccess) -> Void)?

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
    public func balance(_ featureId: String) -> Int? {
        all[featureId]?.balance
    }

    // MARK: - Internal Methods

    /// Update all features (called internally when profile/features refresh)
    /// - Parameter features: Dictionary of feature ID to FeatureAccess
    internal func update(_ features: [String: FeatureAccess]) {
        let oldFeatures = all

        // Notify delegate for each changed feature
        if let onFeatureChange = onFeatureChange {
            // Check for new or changed features
            for (featureId, newAccess) in features {
                let oldAccess = oldFeatures[featureId]
                if oldAccess == nil || !areEqual(oldAccess!, newAccess) {
                    onFeatureChange(featureId, oldAccess, newAccess)
                }
            }
        }

        self.all = features
    }

    /// Update a single feature (called internally after real-time checks)
    /// - Parameters:
    ///   - featureId: The feature identifier
    ///   - access: The updated feature access
    internal func update(_ featureId: String, access: FeatureAccess) {
        let oldAccess = all[featureId]

        // Notify delegate if changed
        if let onFeatureChange = onFeatureChange {
            if oldAccess == nil || !areEqual(oldAccess!, access) {
                onFeatureChange(featureId, oldAccess, access)
            }
        }

        var updated = all
        updated[featureId] = access
        self.all = updated
    }

    /// Clear all cached features
    internal func clear() {
        all = [:]
    }

    /// Decrement the balance for a feature (for local UI feedback after usage)
    /// - Parameters:
    ///   - featureId: The feature identifier
    ///   - amount: The amount to decrement
    internal func decrementBalance(_ featureId: String, amount: Int) {
        guard let access = all[featureId], !access.unlimited else { return }

        let currentBalance = access.balance ?? 0
        let newBalance = max(0, currentBalance - amount)

        let newAccess = FeatureAccess.withBalance(
            newBalance,
            unlimited: false,
            type: access.type
        )

        update(featureId, access: newAccess)
    }

    /// Set the balance for a feature (after server confirmation)
    /// - Parameters:
    ///   - featureId: The feature identifier
    ///   - balance: The new balance from server
    internal func setBalance(_ featureId: String, balance: Int) {
        guard let access = all[featureId] else { return }

        let newAccess = FeatureAccess.withBalance(
            balance,
            unlimited: access.unlimited,
            type: access.type
        )

        update(featureId, access: newAccess)
    }

    // MARK: - Private Methods

    /// Compare two FeatureAccess values for equality
    private func areEqual(_ lhs: FeatureAccess, _ rhs: FeatureAccess) -> Bool {
        lhs.allowed == rhs.allowed &&
        lhs.unlimited == rhs.unlimited &&
        lhs.balance == rhs.balance &&
        lhs.type == rhs.type
    }
}
