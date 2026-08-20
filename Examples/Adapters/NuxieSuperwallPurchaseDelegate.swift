import Foundation
import Nuxie
import StoreKit
#if canImport(SuperwallKit)
@preconcurrency import SuperwallKit
#endif

enum NuxieSuperwallBridgeError: LocalizedError {
    case unknownRestoreFailure
    case storeKitProductUnavailable(identifier: String)
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .unknownRestoreFailure:
            return "Restore failed without an underlying error from Superwall."
        case .storeKitProductUnavailable(let identifier):
            return "StoreKit product unavailable for identifier \(identifier)."
        case .unsupportedPlatform:
            return "Superwall checkout is available only when SuperwallKit can be imported."
        }
    }
}

#if canImport(SuperwallKit)
/// Nuxie's concrete Superwall checkout adapter. Superwall observes the exact
/// StoreKit purchase while signed Connector state bounds immediate access.
final class NuxieSuperwallPurchaseDelegate:
    NuxiePurchaseDelegate, @unchecked Sendable
{
    private let superwall: Superwall

    init(superwall: Superwall = .shared) {
        self.superwall = superwall
    }

    func purchase(product: Nuxie.StoreProduct) async -> Nuxie.PurchaseResult {
        guard let rawProduct = product.rawProduct else {
            return .failed(NuxieSuperwallBridgeError.storeKitProductUnavailable(
                identifier: product.storeProductId
            ))
        }
        do {
            switch try await rawProduct.purchase(options: product.storeKitPurchaseOptions) {
            case .success(let verification):
                switch verification {
                case .verified:
                    // Superwall observes, syncs, and finishes this transaction.
                    // Nuxie consumes the checkout result. Before Connector
                    // cutover, its observer can still sync the separately
                    // verified update; signed authority suppresses that path.
                    return .purchased
                case .unverified(_, let error): return .failed(error)
                }
            case .userCancelled: return .cancelled
            case .pending: return .pending
            @unknown default:
                return .failed(NuxieSuperwallBridgeError.storeKitProductUnavailable(
                    identifier: product.storeProductId
                ))
            }
        } catch {
            return .failed(error)
        }
    }

    func restorePurchases() async -> Nuxie.RestoreResult {
        switch await superwall.restorePurchases() {
        case .restored:
            let active = await MainActor.run {
                if case let .active(entitlements) = superwall.subscriptionStatus {
                    return !entitlements.isEmpty
                }
                return false
            }
            return active ? .restored : .noPurchases
        case .failed(let error):
            return .failed(error ?? NuxieSuperwallBridgeError.unknownRestoreFailure)
        }
    }
}
#else
final class NuxieSuperwallPurchaseDelegate:
    NuxiePurchaseDelegate, @unchecked Sendable
{

    init() {}

    func purchase(product: Nuxie.StoreProduct) async -> Nuxie.PurchaseResult {
        .failed(NuxieSuperwallBridgeError.unsupportedPlatform)
    }

    func restorePurchases() async -> Nuxie.RestoreResult {
        .failed(NuxieSuperwallBridgeError.unsupportedPlatform)
    }
}
#endif
