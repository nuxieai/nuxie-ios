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
}
