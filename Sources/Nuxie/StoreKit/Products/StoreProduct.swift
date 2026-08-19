import Foundation
import StoreKit

// MARK: - Product Type

/// The App Store product category used to render and purchase a product.
public enum StoreProductType: String, Codable, Equatable, Sendable {
    /// A consumable product that can be purchased more than once.
    case consumable
    /// A durable, one-time purchase.
    case nonConsumable
    /// A subscription that renews automatically until cancelled.
    case autoRenewable
    /// A subscription with a fixed duration that does not renew automatically.
    case nonRenewing
}

// MARK: - Subscription Period

public struct SubscriptionPeriod: Equatable, Sendable {
    public enum Unit: String, Equatable, Sendable {
        case day
        case week
        case month
        case year
    }
    
    public let value: Int
    public let unit: Unit
    
    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }
}

// MARK: - Store Product

/// The Nuxie Product and Placement combined with live App Store details.
///
/// The same value renders the paywall and is retained for checkout. The native
/// StoreKit product is intentionally excluded from serialization.
public struct StoreProduct: Equatable, Codable, Sendable {
    /// The signed release mapping used for immediate local access after a
    /// verified purchase. This is internal because the server remains the
    /// authority for durable balances.
    struct LocalEntitlementGrant: Equatable, Sendable {
        let featureId: String
        let featureExternalId: String?
        let allowanceType: String?
        let allowance: Double?
    }
    /// The StoreKit billing plan selected for this purchase.
    public enum BillingPlan: String, Codable, Equatable, Sendable {
        /// StoreKit's ordinary plan selection.
        case `default`
        /// The customer pays the full commitment at purchase.
        case upFront
        /// The customer pays the commitment in monthly installments.
        case monthly
    }

    /// One introductory phase returned by StoreKit for the selected plan.
    public struct IntroductoryTerms: Equatable, Codable, Sendable {
        /// How StoreKit charges the introductory phase.
        public enum PaymentMode: String, Codable, Equatable, Sendable {
            /// No charge during the introductory phase.
            case freeTrial
            /// The introductory price is charged once per period.
            case payAsYouGo
            /// The introductory price is charged once for the full phase.
            case payUpFront
        }

        /// StoreKit's localized introductory price.
        public let price: String
        /// The normalized unit for one introductory billing period.
        public let period: ProductPeriod
        /// The number of units in one introductory billing period.
        public let periodCount: Int
        /// The number of introductory billing periods.
        public let cycles: Int
        /// How StoreKit charges the introductory phase.
        public let paymentMode: PaymentMode
        /// StoreKit's localized total introductory duration.
        public let trialPeriodText: String

        /// Whether this phase is a free trial.
        public var isFree: Bool { paymentMode == .freeTrial }

        /// Creates exact introductory terms resolved from StoreKit.
        ///
        /// - Parameters:
        ///   - price: StoreKit's localized introductory price.
        ///   - period: The normalized introductory period unit.
        ///   - periodCount: The number of units in one period.
        ///   - cycles: The number of introductory periods.
        ///   - paymentMode: How StoreKit charges the introductory phase.
        ///   - trialPeriodText: The localized total introductory duration.
        public init(
            price: String,
            period: ProductPeriod,
            periodCount: Int,
            cycles: Int,
            paymentMode: PaymentMode,
            trialPeriodText: String
        ) {
            self.price = price
            self.period = period
            self.periodCount = periodCount
            self.cycles = cycles
            self.paymentMode = paymentMode
            self.trialPeriodText = trialPeriodText
        }
    }

    /// Nuxie's stable catalog product identity.
    public let productId: String
    /// The App Store product identifier resolved through StoreKit.
    public let storeProductId: String
    /// The exact signed placement shown to the customer.
    public let placementId: String
    /// The localized product name returned by StoreKit.
    public let name: String
    /// The localized product description returned by StoreKit.
    public let description: String
    /// The localized display price returned by StoreKit, such as `$9.99`.
    public let price: String
    /// The normalized renewal period, or `nil` for non-subscription products.
    public let period: ProductPeriod?
    /// The number of normalized period units in one renewal interval.
    public let periodCount: Int?
    /// The localized period label projected into the paywall view model.
    public let periodLabel: String
    /// The localized recurring renewal price.
    public let renewalPrice: String
    /// The localized recurring renewal period.
    public let renewalPeriod: String
    /// The App Store product category.
    public let productType: StoreProductType
    /// The billing plan StoreKit will apply to this checkout.
    public let billingPlan: BillingPlan
    /// Total commitment price, when Apple bills in installments.
    public let commitmentPrice: String
    /// Localized total commitment period, when present.
    public let commitmentPeriod: String
    /// The one live introductory phase available for this checkout.
    public let introductoryTerms: IntroductoryTerms?
    /// The live App Store product used internally. This value is not serialized.
    var appStoreProduct: (any AppStoreProduct)? = nil
    /// Internal marker for development-only Test Store products, which do not
    /// have a StoreKit product by design.
    var isTestStoreProduct = false
    /// The exact eligibility override that must be freshly signed at checkout.
    var introEligibilityTokenRequest: IntroEligibilityTokenRequest? = nil
    /// Exact signed commercial identity persisted before native checkout.
    var purchaseContext: PurchaseCommercialContext? = nil
    var localEntitlementGrants: [LocalEntitlementGrant] = []
    /// Authored preview copy used only by the isolated Test Store.
    var previewIntroOfferLabel: String? = nil
    /// A fresh, single-checkout token installed immediately before the delegate.
    private var checkoutIntroEligibilityToken: String? = nil
    /// Stable account correlation installed only for native StoreKit checkout.
    private var checkoutAppAccountToken: UUID? = nil
    /// The fresh eligibility JWS for this checkout, when Nuxie selected an
    /// explicit introductory-eligibility override.
    ///
    /// Provider delegates such as RevenueCat pass this value through their
    /// purchase-parameter API. The value is short-lived and absent from
    /// serialized products.
    public var introductoryOfferEligibilityJWS: String? {
        checkoutIntroEligibilityToken
    }
    /// The exact StoreKit product retained after presentation.
    public var rawProduct: Product? { appStoreProduct as? Product }
    /// Exact StoreKit options for the terms shown by Nuxie.
    ///
    /// Custom StoreKit delegates pass this set to `Product.purchase(options:)`.
    /// Provider delegates that cannot honor a non-empty set must fail checkout
    /// rather than silently purchase different terms.
    public var storeKitPurchaseOptions: Set<Product.PurchaseOption> {
        var options = Set<Product.PurchaseOption>()
        #if compiler(>=6.1)
        if let checkoutIntroEligibilityToken {
            options.insert(
                .introductoryOfferEligibility(compactJWS: checkoutIntroEligibilityToken)
            )
        }
        #endif
        if let checkoutAppAccountToken {
            options.insert(.appAccountToken(checkoutAppAccountToken))
        }
        #if compiler(>=6.3.2)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) {
            switch billingPlan {
            case .monthly:
                options.insert(.billingPlanType(.monthly))
            case .upFront:
                options.insert(.billingPlanType(.upFront))
            case .default:
                break
            }
        }
        #endif
        return options
    }

    /// Whether live introductory terms are available. Base products are not
    /// eligible until introductory terms are resolved in the dedicated flow.
    public var hasIntroductoryOffer: Bool { introductoryTerms != nil }
    /// Whether the current introductory phase is free.
    public var hasFreeTrial: Bool { introductoryTerms?.isFree == true }
    /// How StoreKit charges the current introductory phase.
    public var introductoryPaymentMode: IntroductoryTerms.PaymentMode? {
        introductoryTerms?.paymentMode
    }
    public var hasTrial: Bool { hasFreeTrial }
    /// The localized free-trial duration, empty for a base product.
    public var trialPeriodText: String { introductoryTerms?.trialPeriodText ?? "" }
    public var trialLabel: String { hasFreeTrial ? trialPeriodText : "" }
    /// The localized introductory-offer description, empty for a base product.
    public var introOfferLabel: String {
        if let previewIntroOfferLabel {
            return previewIntroOfferLabel
        }
        guard let terms = introductoryTerms else { return "" }
        // Paid offers can be pay-as-you-go or pay-up-front. A single combined
        // string cannot state both truthfully without retaining payment mode,
        // so Rive copy composes the typed price/period/cycle fields instead.
        return terms.isFree ? terms.trialPeriodText : ""
    }
    /// The localized recurring charge sentence, empty when the product does not renew.
    public var renewalLabel: String {
        guard !renewalPrice.isEmpty else { return "" }
        return renewalPeriod.isEmpty ? renewalPrice : "\(renewalPrice)/\(renewalPeriod)"
    }

    /// Creates the live product facts passed to a purchase delegate.
    ///
    /// - Parameters:
    ///   - productId: Nuxie's stable catalog product ID.
    ///   - storeProductId: The App Store product ID.
    ///   - placementId: The signed Placement shown to the customer.
    ///   - name: StoreKit's localized product name.
    ///   - description: StoreKit's localized product description.
    ///   - price: StoreKit's localized purchase price.
    ///   - period: The normalized renewal period.
    ///   - periodCount: The number of units in one renewal period.
    ///   - periodLabel: The localized renewal period label.
    ///   - renewalPrice: The localized recurring renewal price.
    ///   - renewalPeriod: The localized recurring renewal period.
    ///   - productType: The App Store product category.
    ///   - billingPlan: The billing plan selected for checkout.
    ///   - commitmentPrice: The localized total commitment price.
    ///   - commitmentPeriod: The localized total commitment period.
    ///   - introductoryTerms: The current introductory phase, when available.
    public init(
        productId: String,
        storeProductId: String? = nil,
        placementId: String,
        name: String,
        description: String = "",
        price: String,
        period: ProductPeriod?,
        periodCount: Int? = nil,
        periodLabel: String? = nil,
        renewalPrice: String? = nil,
        renewalPeriod: String? = nil,
        productType: StoreProductType = .nonConsumable,
        billingPlan: BillingPlan = .default,
        commitmentPrice: String = "",
        commitmentPeriod: String = "",
        introductoryTerms: IntroductoryTerms? = nil
    ) {
        self.init(
            productId: productId,
            storeProductId: storeProductId,
            placementId: placementId,
            name: name,
            description: description,
            price: price,
            period: period,
            periodCount: periodCount,
            periodLabel: periodLabel,
            renewalPrice: renewalPrice,
            renewalPeriod: renewalPeriod,
            productType: productType,
            billingPlan: billingPlan,
            commitmentPrice: commitmentPrice,
            commitmentPeriod: commitmentPeriod,
            introductoryTerms: introductoryTerms,
            introEligibilityTokenRequest: nil,
            retainedAppStoreProduct: nil
        )
    }

    init(
        productId: String,
        storeProductId: String? = nil,
        placementId: String,
        name: String,
        description: String = "",
        price: String,
        period: ProductPeriod?,
        periodCount: Int? = nil,
        periodLabel: String? = nil,
        renewalPrice: String? = nil,
        renewalPeriod: String? = nil,
        productType: StoreProductType = .nonConsumable,
        billingPlan: BillingPlan = .default,
        commitmentPrice: String = "",
        commitmentPeriod: String = "",
        introductoryTerms: IntroductoryTerms? = nil,
        introEligibilityTokenRequest: IntroEligibilityTokenRequest? = nil,
        localEntitlementGrants: [LocalEntitlementGrant] = [],
        appStoreProduct: any AppStoreProduct
    ) {
        self.init(
            productId: productId,
            storeProductId: storeProductId,
            placementId: placementId,
            name: name,
            description: description,
            price: price,
            period: period,
            periodCount: periodCount,
            periodLabel: periodLabel,
            renewalPrice: renewalPrice,
            renewalPeriod: renewalPeriod,
            productType: productType,
            billingPlan: billingPlan,
            commitmentPrice: commitmentPrice,
            commitmentPeriod: commitmentPeriod,
            introductoryTerms: introductoryTerms,
            introEligibilityTokenRequest: introEligibilityTokenRequest,
            localEntitlementGrants: localEntitlementGrants,
            retainedAppStoreProduct: appStoreProduct
        )
    }

    private init(
        productId: String,
        storeProductId: String?,
        placementId: String,
        name: String,
        description: String,
        price: String,
        period: ProductPeriod?,
        periodCount: Int?,
        periodLabel: String?,
        renewalPrice: String?,
        renewalPeriod: String?,
        productType: StoreProductType,
        billingPlan: BillingPlan,
        commitmentPrice: String,
        commitmentPeriod: String,
        introductoryTerms: IntroductoryTerms?,
        introEligibilityTokenRequest: IntroEligibilityTokenRequest?,
        localEntitlementGrants: [LocalEntitlementGrant] = [],
        retainedAppStoreProduct: (any AppStoreProduct)?
    ) {
        self.productId = productId
        self.storeProductId = storeProductId ?? productId
        self.placementId = placementId
        self.name = name
        self.description = description
        self.price = price
        self.period = period
        self.periodCount = periodCount
        self.periodLabel = periodLabel ?? period?.rawValue ?? "lifetime"
        self.renewalPrice = renewalPrice ?? ""
        self.renewalPeriod = renewalPeriod ?? ""
        self.productType = productType
        self.billingPlan = billingPlan
        self.commitmentPrice = commitmentPrice
        self.commitmentPeriod = commitmentPeriod
        self.introductoryTerms = introductoryTerms
        self.introEligibilityTokenRequest = introEligibilityTokenRequest
        self.localEntitlementGrants = localEntitlementGrants
        appStoreProduct = retainedAppStoreProduct
    }

    func preparedForCheckout(introEligibilityToken: String?) -> Self {
        var prepared = self
        prepared.checkoutIntroEligibilityToken = introEligibilityToken
        return prepared
    }

    func preparedForNativeCheckout(appAccountToken: UUID) -> Self {
        var prepared = self
        prepared.checkoutAppAccountToken = appAccountToken
        return prepared
    }

    var nativeCheckoutAppAccountToken: UUID? { checkoutAppAccountToken }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.productId == rhs.productId
            && lhs.storeProductId == rhs.storeProductId
            && lhs.placementId == rhs.placementId
            && lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.price == rhs.price
            && lhs.period == rhs.period
            && lhs.periodCount == rhs.periodCount
            && lhs.periodLabel == rhs.periodLabel
            && lhs.renewalPrice == rhs.renewalPrice
            && lhs.renewalPeriod == rhs.renewalPeriod
            && lhs.productType == rhs.productType
            && lhs.billingPlan == rhs.billingPlan
            && lhs.commitmentPrice == rhs.commitmentPrice
            && lhs.commitmentPeriod == rhs.commitmentPeriod
            && lhs.introductoryTerms == rhs.introductoryTerms
            && lhs.previewIntroOfferLabel == rhs.previewIntroOfferLabel
            && lhs.isTestStoreProduct == rhs.isTestStoreProduct
            && lhs.localEntitlementGrants == rhs.localEntitlementGrants
    }

    private enum CodingKeys: String, CodingKey {
        case productId, storeProductId, placementId, name, description, price, period
        case periodCount, periodLabel, renewalPrice, renewalPeriod, productType
        case billingPlan, commitmentPrice, commitmentPeriod, introductoryTerms
    }
}

// MARK: - App Store Product

/// The live App Store product details retained by a StoreProduct.
protocol AppStoreProduct: Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var price: Decimal { get }
    var displayPrice: String { get }
    /// Locale StoreKit used to format the product's commercial terms.
    var priceLocale: Locale { get }
    var isFamilyShareable: Bool { get }
    var productType: StoreProductType { get }
    var subscriptionPeriod: SubscriptionPeriod? { get }
    func introductoryTerms(for plan: StoreProduct.BillingPlan) -> StoreProduct.IntroductoryTerms?
    func billingDisplayPrice(for plan: StoreProduct.BillingPlan) -> String?
    func billingPeriod(for plan: StoreProduct.BillingPlan) -> SubscriptionPeriod?
    func commitmentDisplayPrice(for plan: StoreProduct.BillingPlan) -> String?
    func commitmentPeriod(for plan: StoreProduct.BillingPlan) -> SubscriptionPeriod?
    func supportsBillingPlan(_ plan: StoreProduct.BillingPlan) -> Bool
    func isEligibleForIntroOffer() async -> Bool
}

extension AppStoreProduct {
    /// Test and custom products default to the customer's current locale.
    var priceLocale: Locale { .current }
    func introductoryTerms(for plan: StoreProduct.BillingPlan) -> StoreProduct.IntroductoryTerms? {
        nil
    }
    func billingDisplayPrice(for plan: StoreProduct.BillingPlan) -> String? { nil }
    func billingPeriod(for plan: StoreProduct.BillingPlan) -> SubscriptionPeriod? { nil }
    func commitmentDisplayPrice(for plan: StoreProduct.BillingPlan) -> String? { nil }
    func commitmentPeriod(for plan: StoreProduct.BillingPlan) -> SubscriptionPeriod? { nil }
    func supportsBillingPlan(_ plan: StoreProduct.BillingPlan) -> Bool { plan == .default }
    func isEligibleForIntroOffer() async -> Bool { false }
}

// MARK: - StoreKit.Product Extension

extension Product: AppStoreProduct {
    var priceLocale: Locale { priceFormatStyle.locale }

    var productType: StoreProductType {
        switch self.type {
        case .consumable:
            return .consumable
        case .nonConsumable:
            return .nonConsumable
        case .autoRenewable:
            return .autoRenewable
        case .nonRenewable:
            return .nonRenewing
        default:
            return .nonConsumable
        }
    }
    
    var subscriptionPeriod: Nuxie.SubscriptionPeriod? {
        guard let subscription = self.subscription else { return nil }
        
        let period = subscription.subscriptionPeriod
        let unit: Nuxie.SubscriptionPeriod.Unit
        
        switch period.unit {
        case .day:
            unit = .day
        case .week:
            unit = .week  
        case .month:
            unit = .month
        case .year:
            unit = .year
        @unknown default:
            return nil
        }
        
        return Nuxie.SubscriptionPeriod(value: period.value, unit: unit)
    }

    func introductoryTerms(for plan: StoreProduct.BillingPlan) -> StoreProduct.IntroductoryTerms? {
        if plan == .default {
            return subscription?.introductoryOffer.flatMap(mapIntroductoryTerms)
        }
        #if compiler(>=6.3.2)
        guard #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) else {
            return nil
        }
        return pricingTerms(for: plan)?.subscriptionOffers
            .first(where: { $0.type == .introductory })
            .flatMap(mapIntroductoryTerms)
        #else
        return nil
        #endif
    }

    func billingDisplayPrice(for plan: StoreProduct.BillingPlan) -> String? {
        #if compiler(>=6.3.2)
        guard #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) else {
            return nil
        }
        return pricingTerms(for: plan)?.billingDisplayPrice
        #else
        return nil
        #endif
    }

    func billingPeriod(for plan: StoreProduct.BillingPlan) -> Nuxie.SubscriptionPeriod? {
        #if compiler(>=6.3.2)
        guard #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) else {
            return nil
        }
        return pricingTerms(for: plan).flatMap { Self.mapPeriod($0.billingPeriod) }
        #else
        return nil
        #endif
    }

    func commitmentDisplayPrice(for plan: StoreProduct.BillingPlan) -> String? {
        #if compiler(>=6.3.2)
        guard #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) else {
            return nil
        }
        return pricingTerms(for: plan)?.commitmentInfo.displayPrice
        #else
        return nil
        #endif
    }

    func commitmentPeriod(for plan: StoreProduct.BillingPlan) -> Nuxie.SubscriptionPeriod? {
        #if compiler(>=6.3.2)
        guard #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) else {
            return nil
        }
        return pricingTerms(for: plan).flatMap {
            Self.mapPeriod($0.commitmentInfo.period)
        }
        #else
        return nil
        #endif
    }

    func supportsBillingPlan(_ plan: StoreProduct.BillingPlan) -> Bool {
        if plan == .default { return true }
        #if compiler(>=6.3.2)
        guard #available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *) else {
            return false
        }
        return pricingTerms(for: plan) != nil
        #else
        return false
        #endif
    }

    func isEligibleForIntroOffer() async -> Bool {
        await subscription?.isEligibleForIntroOffer == true
    }

    private func mapIntroductoryTerms(
        _ offer: Product.SubscriptionOffer
    ) -> StoreProduct.IntroductoryTerms? {
        guard let period = Self.mapPeriod(offer.period),
              let normalizedPeriod = Self.mapProductPeriod(period),
              let paymentMode = Self.mapPaymentMode(offer.paymentMode) else { return nil }
        return StoreProduct.IntroductoryTerms(
            price: offer.displayPrice,
            period: normalizedPeriod,
            periodCount: period.value,
            cycles: offer.periodCount,
            paymentMode: paymentMode,
            trialPeriodText: Self.formatPeriod(
                Nuxie.SubscriptionPeriod(
                    value: period.value * offer.periodCount,
                    unit: period.unit
                ),
                locale: priceLocale
            )
        )
    }

    private static func mapPaymentMode(
        _ mode: Product.SubscriptionOffer.PaymentMode
    ) -> StoreProduct.IntroductoryTerms.PaymentMode? {
        switch mode {
        case .freeTrial: return .freeTrial
        case .payAsYouGo: return .payAsYouGo
        case .payUpFront: return .payUpFront
        default: return nil
        }
    }

    #if compiler(>=6.3.2)
    @available(iOS 26.4, macOS 26.4, tvOS 26.4, watchOS 26.4, *)
    private func pricingTerms(
        for plan: StoreProduct.BillingPlan
    ) -> Product.SubscriptionInfo.PricingTerms? {
        subscription?.pricingTerms.first { terms in
            switch plan {
            case .monthly: terms.billingPlanType == .monthly
            case .upFront: terms.billingPlanType == .upFront
            case .default: false
            }
        }
    }
    #endif

    private static func mapPeriod(
        _ period: Product.SubscriptionPeriod
    ) -> Nuxie.SubscriptionPeriod? {
        let unit: Nuxie.SubscriptionPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return Nuxie.SubscriptionPeriod(value: period.value, unit: unit)
    }

    private static func mapProductPeriod(
        _ period: Nuxie.SubscriptionPeriod
    ) -> ProductPeriod? {
        switch period.unit {
        case .day: .day
        case .week: .week
        case .month: .month
        case .year: .year
        }
    }

    private static func formatPeriod(
        _ period: Nuxie.SubscriptionPeriod,
        locale: Locale
    ) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        let components: DateComponents
        switch period.unit {
        case .day:
            formatter.allowedUnits = [.day]
            components = DateComponents(day: period.value)
        case .week:
            formatter.allowedUnits = [.weekOfMonth]
            components = DateComponents(weekOfMonth: period.value)
        case .month:
            formatter.allowedUnits = [.month]
            components = DateComponents(month: period.value)
        case .year:
            formatter.allowedUnits = [.year]
            components = DateComponents(year: period.value)
        }
        return formatter.string(from: components) ?? ""
    }
}
