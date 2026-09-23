import XCTest
@testable import Nuxie

final class JourneyOfferAccessTests: XCTestCase {
    private func product(_ id: String, feature: String, type: String = "subscription") -> JourneyReleaseProductDocument {
        .init(
            id: id, type: type,
            store: .init(platform: "apple_app_store", productId: "store.\(id)", productType: type == "consumable" ? "consumable" : "autoRenewable", basePlanId: nil, purchaseOptionId: nil),
            preview: .init(name: id, description: "", price: "$1", period: "month", periodCount: 1, periodLabel: "month", hasTrial: false, trialLabel: "", introOfferLabel: "", renewalLabel: ""),
            entitlements: [.init(id: "grant.\(id)", featureId: "internal.\(feature)", featureExternalId: feature, purchaseUsageFeatureIds: [], allowanceType: nil, allowance: nil, interval: nil)]
        )
    }

    private func placement(_ id: String) -> JourneyReleasePlacementDocument {
        .init(id: "offer.\(id)", productId: id, appStore: nil, googlePlay: nil)
    }

    func testUnknownAccessIsNotTreatedAsDenied() async {
        let result = await JourneyOfferAccess.evaluate(placementIds: ["offer.pro"], products: [product("pro", feature: "pro")], placements: [placement("pro")], ownedStoreProductIds: [], featureAccess: { _ in nil })
        XCTAssertEqual(result, .unknown)
    }

    func testCurrentStoreOwnershipSuppressesOfferBeforeServerReconciliation() async {
        let result = await JourneyOfferAccess.evaluate(placementIds: ["offer.pro"], products: [product("pro", feature: "pro")], placements: [placement("pro")], ownedStoreProductIds: ["store.pro"], featureAccess: { _ in .notFound })
        XCTAssertEqual(result, .alreadyEntitled)
    }

    func testDifferentOwnedProductCanSupplyTheSameOfferedAccess() async {
        let result = await JourneyOfferAccess.evaluate(placementIds: ["offer.monthly"], products: [product("monthly", feature: "pro"), product("annual", feature: "pro")], placements: [placement("monthly")], ownedStoreProductIds: ["store.annual"], featureAccess: { _ in nil })
        XCTAssertEqual(result, .alreadyEntitled)
    }

    func testSupportedFeatureProjectionSuppressesAnOffer() async {
        let result = await JourneyOfferAccess.evaluate(placementIds: ["offer.pro"], products: [product("pro", feature: "pro")], placements: [placement("pro")], ownedStoreProductIds: [], featureAccess: { _ in FeatureAccess(allowed: true, unlimited: false, balance: nil, type: .boolean) })
        XCTAssertEqual(result, .alreadyEntitled)
    }

    func testOwnedLowerTierDoesNotSuppressAvailableUpgrade() async {
        let result = await JourneyOfferAccess.evaluate(placementIds: ["offer.basic", "offer.pro"], products: [product("basic", feature: "basic"), product("pro", feature: "pro")], placements: [placement("basic"), placement("pro")], ownedStoreProductIds: ["store.basic"], featureAccess: { _ in .notFound })
        XCTAssertEqual(result, .eligible)
    }

    func testAnUnknownUpgradeIsNotHiddenByOwnedLowerTier() async {
        let result = await JourneyOfferAccess.evaluate(placementIds: ["offer.basic", "offer.pro"], products: [product("basic", feature: "basic"), product("pro", feature: "pro")], placements: [placement("basic"), placement("pro")], ownedStoreProductIds: ["store.basic"], featureAccess: { _ in nil })
        XCTAssertEqual(result, .unknown)
    }

    func testConsumableBalanceDoesNotPreventRepeatPurchase() async {
        let result = await JourneyOfferAccess.evaluate(placementIds: ["offer.credits"], products: [product("credits", feature: "credits", type: "consumable")], placements: [placement("credits")], ownedStoreProductIds: ["store.credits"], featureAccess: { _ in FeatureAccess(allowed: true, unlimited: false, balance: 100, type: .metered) })
        XCTAssertEqual(result, .eligible)
    }
}
