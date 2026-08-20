import Foundation
import Nuxie
import StoreKit
@preconcurrency import RevenueCat

enum NuxieRevenueCatBridgeError: LocalizedError {
    case productNotFound(identifier: String)

    var errorDescription: String? {
        switch self {
        case .productNotFound(let identifier):
            return "RevenueCat product not found for identifier \(identifier)."
        }
    }
}

/// Nuxie's concrete RevenueCat checkout adapter.
final class NuxieRevenueCatPurchaseDelegate:
    NuxiePurchaseDelegate, @unchecked Sendable
{
    private enum Constants { static let errorDomain = "RevenueCat.ErrorCode" }
    private let purchases: PurchasesType

    init() {
        purchases = Purchases.shared
    }

    init(purchases: PurchasesType) {
        self.purchases = purchases
    }

    func purchase(product: Nuxie.StoreProduct) async -> PurchaseResult {
        // RevenueCat derives StoreKit's appAccountToken from its own app user
        // ID and does not forward the exact token Nuxie attached to this
        // checkout. Open StoreKit with Nuxie's retained Product/options so an
        // Ask-to-Buy or SCA transaction can be correlated after relaunch;
        // RevenueCat's transaction observer still receives and syncs it.
        await purchaseExactStoreKitTerms(product)
    }

    func restorePurchases() async -> RestoreResult {
        do {
            let info = try await purchases.restorePurchases()
            return info.entitlements.active.isEmpty ? .noPurchases : .restored
        } catch {
            return .failed(extractErrorCode(from: error) ?? error)
        }
    }

    private func purchaseExactStoreKitTerms(
        _ product: Nuxie.StoreProduct
    ) async -> PurchaseResult {
        guard let rawProduct = product.rawProduct else {
            return .failed(NuxieRevenueCatBridgeError.productNotFound(
                identifier: product.storeProductId
            ))
        }
        do {
            switch try await rawProduct.purchase(options: product.storeKitPurchaseOptions) {
            case .success(let verification):
                switch verification {
                case .verified:
                    // RevenueCat observes, syncs, and finishes this transaction.
                    // Nuxie consumes only the checkout result and signed local
                    // Feature mapping; it never assumes receipt ownership.
                    return .purchased
                case .unverified(_, let error): return .failed(error)
                }
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default:
                return .failed(NuxieRevenueCatBridgeError.productNotFound(
                    identifier: product.storeProductId
                ))
            }
        } catch {
            return .failed(error)
        }
    }

    private func extractErrorCode(from error: Error) -> ErrorCode? {
        if let errorCode = error as? ErrorCode { return errorCode }
        let nsError = error as NSError
        guard nsError.domain == Constants.errorDomain else { return nil }
        return ErrorCode(rawValue: nsError.code)
    }
}
