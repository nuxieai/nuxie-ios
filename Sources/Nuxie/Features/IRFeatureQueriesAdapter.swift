import Foundation

/// Adapter that bridges FeatureServiceProtocol to IRFeatureQueries for IR evaluation
struct IRFeatureQueriesAdapter: IRFeatureQueries {
    private let featureService: FeatureServiceProtocol

    public init(featureService: FeatureServiceProtocol) {
        self.featureService = featureService
    }

    public func has(_ featureId: String) async -> Bool {
        guard let access = await featureService.getCached(featureId: featureId, entityId: nil) else {
            return false
        }
        return access.allowed
    }

    public func isUnlimited(_ featureId: String) async -> Bool {
        guard let access = await featureService.getCached(featureId: featureId, entityId: nil) else {
            return false
        }
        return access.unlimited
    }

    public func getBalance(_ featureId: String) async -> Double? {
        guard let access = await featureService.getCached(featureId: featureId, entityId: nil) else {
            return nil
        }
        return access.balance
    }
}
