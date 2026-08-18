import Foundation
import StoreKit
@testable import Nuxie

// MARK: - Mock Implementation for Testing

/// Mock product for testing
public struct MockStoreProduct {
    public let id: String
    public let displayName: String
    public let description: String
    public let price: Decimal
    public let displayPrice: String
    public let priceLocale: Locale
    public let isFamilyShareable: Bool
    public let productType: StoreProductType
    public let subscriptionPeriod: Nuxie.SubscriptionPeriod?

    public init(
        id: String,
        displayName: String,
        description: String = "",
        price: Decimal,
        displayPrice: String,
        priceLocale: Locale = Locale(identifier: "en_US"),
        isFamilyShareable: Bool = false,
        productType: StoreProductType = .nonConsumable,
        subscriptionPeriod: Nuxie.SubscriptionPeriod? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.price = price
        self.displayPrice = displayPrice
        self.priceLocale = priceLocale
        self.isFamilyShareable = isFamilyShareable
        self.productType = productType
        self.subscriptionPeriod = subscriptionPeriod
    }
}

extension MockStoreProduct: AppStoreProduct {}
