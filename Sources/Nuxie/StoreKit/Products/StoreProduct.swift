import Foundation
import StoreKit

// MARK: - Product Type

public enum StoreProductType: String, Equatable, Sendable {
    case consumable
    case nonConsumable
    case autoRenewable
    case nonRenewable
}

// MARK: - Subscription Period

public struct SubscriptionPeriod: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, Equatable, Sendable {
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

public enum StoreOfferType: String, Codable, Equatable, Sendable {
    case introductory
    case promotional
    case winBack
    case offerCode
}

/// StoreKit metadata for an offer that can be bound into a Nuxie paywall and
/// selected by the host's purchase implementation.
public struct StoreOffer: Codable, Equatable, Sendable {
    public static let introductoryOfferId = "introductory"

    public let id: String
    public let type: StoreOfferType
    public let price: Decimal?
    public let displayPrice: String
    public let period: SubscriptionPeriod
    public let periodCount: Int

    public init(
        id: String,
        type: StoreOfferType,
        price: Decimal? = nil,
        displayPrice: String,
        period: SubscriptionPeriod,
        periodCount: Int
    ) {
        self.id = id
        self.type = type
        self.price = price
        self.displayPrice = displayPrice
        self.period = period
        self.periodCount = periodCount
    }
}

// MARK: - Store Product Protocol

/// Protocol for StoreKit products that allows for testing and abstraction
public protocol StoreProductProtocol: Sendable {
    var id: String { get }
    var displayName: String { get }
    var description: String { get }
    var price: Decimal { get }
    var displayPrice: String { get }
    var isFamilyShareable: Bool { get }
    var productType: StoreProductType { get }
    var subscriptionPeriod: SubscriptionPeriod? { get }
    var storeOffers: [StoreOffer] { get }
    func applicableStoreOffers() async -> [StoreOffer]
}

public extension StoreProductProtocol {
    var storeOffers: [StoreOffer] { [] }
    func applicableStoreOffers() async -> [StoreOffer] { storeOffers }
}

// MARK: - StoreKit.Product Extension

extension Product: StoreProductProtocol {
    public var productType: StoreProductType {
        switch self.type {
        case .consumable:
            return .consumable
        case .nonConsumable:
            return .nonConsumable
        case .autoRenewable:
            return .autoRenewable
        case .nonRenewable:
            return .nonRenewable
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


    public var storeOffers: [StoreOffer] {
        guard let subscription else { return [] }
        var offers = subscription.promotionalOffers.compactMap {
            StoreOffer(storeKitOffer: $0, type: .promotional)
        }
        if let introductoryOffer = subscription.introductoryOffer,
           let offer = StoreOffer(storeKitOffer: introductoryOffer, type: .introductory) {
            offers.insert(offer, at: 0)
        }
        if #available(iOS 18.0, macOS 15.0, *) {
            offers.append(contentsOf: subscription.winBackOffers.compactMap {
                StoreOffer(storeKitOffer: $0, type: .winBack)
            })
        }
        return offers
    }

    public func applicableStoreOffers() async -> [StoreOffer] {
        guard let subscription else { return [] }
        var offers = subscription.promotionalOffers.compactMap {
            StoreOffer(storeKitOffer: $0, type: .promotional)
        }
        if await subscription.isEligibleForIntroOffer,
           let introductoryOffer = subscription.introductoryOffer,
           let offer = StoreOffer(storeKitOffer: introductoryOffer, type: .introductory) {
            offers.insert(offer, at: 0)
        }
        if #available(iOS 18.0, macOS 15.0, *) {
            let eligibleIDs = (try? await subscription.status) ?? []
            let eligibleWinBackIDs = Set(eligibleIDs.flatMap { status -> [String] in
                guard case .verified(let renewalInfo) = status.renewalInfo else { return [] }
                return Array(renewalInfo.eligibleWinBackOfferIDs)
            })
            let winBackOffers = subscription.winBackOffers.compactMap { offer -> StoreOffer? in
                guard let id = offer.id, eligibleWinBackIDs.contains(id) else { return nil }
                return StoreOffer(storeKitOffer: offer, type: .winBack)
            }
            offers.insert(contentsOf: winBackOffers, at: 0)
        }
        return offers
    }
}

private extension StoreOffer {
    init?(storeKitOffer: Product.SubscriptionOffer, type: StoreOfferType) {
        let id: String
        if let storeKitId = storeKitOffer.id {
            id = storeKitId
        } else if type == .introductory {
            id = StoreOffer.introductoryOfferId
        } else {
            return nil
        }
        let period = storeKitOffer.period
        let unit: SubscriptionPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        self.init(
            id: id,
            type: type,
            price: storeKitOffer.price,
            displayPrice: storeKitOffer.displayPrice,
            period: SubscriptionPeriod(value: period.value, unit: unit),
            periodCount: storeKitOffer.periodCount
        )
    }
}
