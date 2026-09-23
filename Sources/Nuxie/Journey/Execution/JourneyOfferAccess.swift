import Foundation

/// Reads existing access evidence; it never records a purchase or grants access.
enum JourneyOfferAccess {
    enum Decision: Equatable, Sendable { case eligible, alreadyEntitled, unknown }

    static func evaluate(
        placementIds: [String],
        products: [JourneyReleaseProductDocument],
        placements: [JourneyReleasePlacementDocument],
        ownedStoreProductIds: Set<String>,
        featureAccess: @Sendable (String) async -> FeatureAccess?
    ) async -> Decision {
        guard !placementIds.isEmpty else { return .unknown }
        let ownedProducts = products.filter {
            $0.store.platform == "apple_app_store" && ownedStoreProductIds.contains($0.store.productId)
        }
        let ownedFeatures = Set(ownedProducts.flatMap { product in
            product.entitlements.flatMap { [$0.featureId, $0.featureExternalId].compactMap { $0 } }
        })
        var unresolved = false
        for placementId in placementIds {
            guard let placement = placements.first(where: { $0.id == placementId }),
                  let product = products.first(where: { $0.id == placement.productId }) else {
                unresolved = true
                continue
            }
            // Consumable access balances do not represent ownership.
            if product.type == "consumable" { return .eligible }
            if ownedProducts.contains(where: { $0.id == product.id }) { continue }
            let features = Set(product.entitlements.compactMap { $0.featureExternalId ?? $0.featureId })
            guard !features.isEmpty else { unresolved = true; continue }
            var missing = false
            var unknown = false
            for feature in features where !ownedFeatures.contains(feature) {
                if let access = await featureAccess(feature) {
                    missing = missing || !access.allowed
                } else {
                    unknown = true
                }
            }
            if missing { return .eligible }
            unresolved = unresolved || unknown
        }
        return unresolved ? .unknown : .alreadyEntitled
    }

    /// Compiler step identities retain their route ownership across nested branches.
    static func offer(forPurchaseStep stepId: String, in leg: Journey) -> Journey.Offer? {
        let steps = Dictionary(uniqueKeysWithValues: leg.steps.map { ($0.id, $0) })
        for route in leg.routes where route.host.kind == .screen {
            var pending = [route.entryStepId]
            var visited = Set<String>()
            while let current = pending.popLast() {
                guard visited.insert(current).inserted else { continue }
                if current == stepId {
                    return leg.offers.first { $0.screenId == route.host.screenId }
                }
                guard let step = steps[current], step.kind == .action,
                      let action = step.action, let type = JourneyActionType(action: action),
                      ![.navigate, .back, .dismiss, .exit].contains(type) else { continue }
                pending.append(contentsOf: (step.outlets ?? [:]).values)
            }
        }
        return nil
    }
}
