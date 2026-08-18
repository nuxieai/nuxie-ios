import Foundation
import StoreKit
@testable import Nuxie

// MARK: - Mock Implementation for Testing

/// Mock product for testing
public struct MockStoreProduct {
    public struct BillingTerms: Sendable {
        public let plan: StoreProduct.BillingPlan
        public let displayPrice: String
        public let period: Nuxie.SubscriptionPeriod
        public let commitmentPrice: String
        public let commitmentPeriod: Nuxie.SubscriptionPeriod
        public let introductoryTerms: StoreProduct.IntroductoryTerms?

        public init(
            plan: StoreProduct.BillingPlan,
            displayPrice: String,
            period: Nuxie.SubscriptionPeriod,
            commitmentPrice: String,
            commitmentPeriod: Nuxie.SubscriptionPeriod,
            introductoryTerms: StoreProduct.IntroductoryTerms? = nil
        ) {
            self.plan = plan
            self.displayPrice = displayPrice
            self.period = period
            self.commitmentPrice = commitmentPrice
            self.commitmentPeriod = commitmentPeriod
            self.introductoryTerms = introductoryTerms
        }
    }

    public let id: String
    public let displayName: String
    public let description: String
    public let price: Decimal
    public let displayPrice: String
    public let priceLocale: Locale
    public let isFamilyShareable: Bool
    public let productType: StoreProductType
    public let subscriptionPeriod: Nuxie.SubscriptionPeriod?
    private let mockIntroductoryTerms: StoreProduct.IntroductoryTerms?
    private let mockBillingTerms: [BillingTerms]
    private let eligibleForIntroOffer: Bool

    public init(
        id: String,
        displayName: String,
        description: String = "",
        price: Decimal,
        displayPrice: String,
        priceLocale: Locale = Locale(identifier: "en_US"),
        isFamilyShareable: Bool = false,
        productType: StoreProductType = .nonConsumable,
        subscriptionPeriod: Nuxie.SubscriptionPeriod? = nil,
        introductoryTerms: StoreProduct.IntroductoryTerms? = nil,
        billingTerms: [BillingTerms] = [],
        eligibleForIntroOffer: Bool = false
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
        self.mockIntroductoryTerms = introductoryTerms
        self.mockBillingTerms = billingTerms
        self.eligibleForIntroOffer = eligibleForIntroOffer
    }

    public func introductoryTerms(
        for plan: StoreProduct.BillingPlan
    ) -> StoreProduct.IntroductoryTerms? {
        plan == .default
            ? mockIntroductoryTerms
            : mockBillingTerms.first(where: { $0.plan == plan })?.introductoryTerms
    }

    public func billingDisplayPrice(for plan: StoreProduct.BillingPlan) -> String? {
        mockBillingTerms.first(where: { $0.plan == plan })?.displayPrice
    }

    public func billingPeriod(
        for plan: StoreProduct.BillingPlan
    ) -> Nuxie.SubscriptionPeriod? {
        mockBillingTerms.first(where: { $0.plan == plan })?.period
    }

    public func commitmentDisplayPrice(for plan: StoreProduct.BillingPlan) -> String? {
        mockBillingTerms.first(where: { $0.plan == plan })?.commitmentPrice
    }

    public func commitmentPeriod(
        for plan: StoreProduct.BillingPlan
    ) -> Nuxie.SubscriptionPeriod? {
        mockBillingTerms.first(where: { $0.plan == plan })?.commitmentPeriod
    }

    public func supportsBillingPlan(_ plan: StoreProduct.BillingPlan) -> Bool {
        plan == .default || mockBillingTerms.contains(where: { $0.plan == plan })
    }

    public func isEligibleForIntroOffer() async -> Bool { eligibleForIntroOffer }
}

extension MockStoreProduct: AppStoreProduct {}
