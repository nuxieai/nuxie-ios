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
    /// The live App Store product used internally. This value is not serialized.
    var appStoreProduct: (any AppStoreProduct)? = nil
    /// The exact StoreKit product retained after presentation.
    public var rawProduct: Product? { appStoreProduct as? Product }

    /// Whether live introductory terms are available. Base products are not
    /// eligible until introductory terms are resolved in the dedicated flow.
    public var hasTrial: Bool { false }
    /// The localized free-trial duration, empty for a base product.
    public var trialLabel: String { "" }
    /// The localized introductory-offer description, empty for a base product.
    public var introOfferLabel: String { "" }
    /// The localized recurring charge sentence, empty when the product does not renew.
    public var renewalLabel: String {
        guard !renewalPrice.isEmpty else { return "" }
        return renewalPeriod.isEmpty ? renewalPrice : "\(renewalPrice)/\(renewalPeriod)"
    }

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
        productType: StoreProductType = .nonConsumable
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
        appStoreProduct = retainedAppStoreProduct
    }

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
    }

    private enum CodingKeys: String, CodingKey {
        case productId, storeProductId, placementId, name, description, price, period
        case periodCount, periodLabel, renewalPrice, renewalPeriod, productType
    }
}

// MARK: - App Store Product

/// The live App Store product details retained by a StoreProduct.
public protocol AppStoreProduct: Sendable {
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
}

public extension AppStoreProduct {
    /// Test and custom products default to the customer's current locale.
    var priceLocale: Locale { .current }
}

// MARK: - StoreKit.Product Extension

extension Product: AppStoreProduct {
    public var priceLocale: Locale { priceFormatStyle.locale }

    public var productType: StoreProductType {
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
    
    public var subscriptionPeriod: Nuxie.SubscriptionPeriod? {
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
}
