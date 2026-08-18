import Foundation
import Nuxie

#if canImport(SuperwallKit)
import SuperwallKit
#endif

/// Errors thrown by the Superwall bridge.
public enum NuxieSuperwallBridgeError: LocalizedError {
    /// Superwall reported a restore failure without an underlying error.
    case unknownRestoreFailure
    /// SuperwallKit is not available on the current platform.
    case unsupportedPlatform
    /// StoreKit checkout was required, but the retained native product was unavailable.
    case storeKitProductUnavailable(identifier: String)

    public var errorDescription: String? {
        switch self {
        case .unknownRestoreFailure:
            return "Restore failed without an underlying error from Superwall."
        case .unsupportedPlatform:
            return "Superwall bridge is unavailable on this platform."
        case .storeKitProductUnavailable(let identifier):
            return "StoreKit product unavailable for identifier \(identifier)."
        }
    }
}

#if canImport(SuperwallKit)
/// Concrete implementation of ``NuxiePurchaseDelegate`` that performs Nuxie's
/// exact StoreKit checkout while Superwall observes transactions, and routes
/// restores through Superwall.
public final class NuxieSuperwallPurchaseDelegate: NuxiePurchaseDelegate {
    private let superwall: Superwall

    /// Creates a new delegate that forwards work to the provided `Superwall` facade.
    /// - Parameter superwall: The Superwall instance to use, defaults to `Superwall.shared`.
    public init(superwall: Superwall = .shared) {
        self.superwall = superwall
    }

    public func purchase(product: Nuxie.StoreProduct) async -> Nuxie.PurchaseResult {
        do {
            switch superwallCheckoutRoute() {
            case .storeKit:
                return await purchaseExactStoreKitTerms(product)
            case .provider:
                preconditionFailure("Superwall observes Nuxie's StoreKit checkout")
            }
        } catch {
            return .failed(error)
        }
    }

    private func purchaseExactStoreKitTerms(
        _ product: Nuxie.StoreProduct
    ) async -> Nuxie.PurchaseResult {
        guard let rawProduct = product.rawProduct else {
            return .failed(NuxieSuperwallBridgeError.storeKitProductUnavailable(
                identifier: product.storeProductId
            ))
        }
        do {
            switch try await rawProduct.purchase(options: product.storeKitPurchaseOptions) {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    return .purchased
                case .unverified(_, let error): return .failed(error)
                }
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default: return .failed(NuxieSuperwallBridgeError.storeKitProductUnavailable(
                identifier: product.storeProductId
            ))
            }
        } catch {
            return .failed(error)
        }
    }

    public func restorePurchases() async -> RestoreResult {
        let result = await superwall.restorePurchases()
        switch result {
        case .restored:
            let activeCount = await activeEntitlementCount()
            if activeCount > 0 {
                return .restored
            }
            return .noPurchases
        case .failed(let error):
            return .failed(error ?? NuxieSuperwallBridgeError.unknownRestoreFailure)
        }
    }

    private func activeEntitlementCount() async -> Int {
        await MainActor.run {
            if case let .active(entitlements) = superwall.subscriptionStatus {
                return entitlements.count
            }
            return 0
        }
    }
}
#else
/// macOS fallback implementation when SuperwallKit isn't available for import.
public final class NuxieSuperwallPurchaseDelegate: NuxiePurchaseDelegate {
    public init() {}

    public func purchase(product: Nuxie.StoreProduct) async -> Nuxie.PurchaseResult {
        return .failed(NuxieSuperwallBridgeError.unsupportedPlatform)
    }

    public func restorePurchases() async -> RestoreResult {
        return .failed(NuxieSuperwallBridgeError.unsupportedPlatform)
    }
}
#endif
