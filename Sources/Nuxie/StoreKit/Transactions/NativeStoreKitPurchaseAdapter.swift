import Foundation
import StoreKit

struct StoreTransactionEvidence: Sendable {
    let transactionJws: String
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let finish: @Sendable () async -> Void
}

enum NativePurchaseResult: Sendable {
    case purchased(StoreTransactionEvidence?)
    case alreadyOwned
    case subscriptionChangeRequired
    case cancelled
    case pending
    case productTermsChanged
    case invalidEligibilityOverride(Error)
    case failed(Error)
}

protocol NativeStoreKitPurchasing: Sendable {
    func purchase(product: StoreProduct) async -> NativePurchaseResult
    func restorePurchases() async -> NativeRestoreResult
}

enum NativeRestoreResult: Sendable {
    case restored
    case failed(Error)
    case noPurchases
}

/// StoreKit checkout hidden behind the same small result model exposed to hosts.
struct NativeStoreKitPurchaseAdapter: NativeStoreKitPurchasing {
    func purchase(product: StoreProduct) async -> NativePurchaseResult {
        guard let rawProduct = product.rawProduct else {
            return .failed(StoreKitError.productNotFound(product.storeProductId))
        }
        guard rawProduct.id == product.storeProductId,
              rawProduct.productType == product.productType else {
            return .failed(StoreKitError.apiMisuse(
                reason: "The retained StoreProduct does not match its StoreKit product"
            ))
        }

        if let ownership = await currentOwnership(for: rawProduct) {
            return ownership
        }

        do {
            switch try await rawProduct.purchase(
                options: product.storeKitPurchaseOptions
            ) {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    let evidence = StoreTransactionEvidence(
                        transactionJws: verification.jwsRepresentation,
                        transactionId: String(transaction.id),
                        originalTransactionId: String(transaction.originalID),
                        productId: transaction.productID,
                        finish: { await transaction.finish() }
                    )
                    return .purchased(evidence)
                case .unverified(_, let error):
                    return .failed(StoreKitError.verificationFailed(
                        error.localizedDescription
                    ))
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(StoreKitError.unknown(underlying: nil))
            }
        } catch StoreKit.StoreKitError.userCancelled {
            // StoreKitTest and some system checkout paths surface cancellation
            // as a thrown StoreKitError rather than `.userCancelled`.
            return .cancelled
        } catch Product.PurchaseError.productUnavailable {
            return .productTermsChanged
        } catch let error where invalidatesIntroEligibilityOverride(error) {
            return .invalidEligibilityOverride(error)
        } catch {
            return .failed(StoreKitError.from(storeKit2Error: error))
        }
    }

    func restorePurchases() async -> NativeRestoreResult {
        do {
            try await AppStore.sync()
            for await result in Transaction.currentEntitlements {
                guard case .verified(let transaction) = result,
                      transaction.revocationDate == nil,
                      !transaction.isUpgraded else {
                    continue
                }
                return .restored
            }
            return .noPurchases
        } catch {
            return .failed(StoreKitError.from(storeKit2Error: error))
        }
    }

    private func currentOwnership(for product: Product) async -> NativePurchaseResult? {
        guard product.type != .consumable else { return nil }
        let targetGroupId = product.subscription?.subscriptionGroupID

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else {
                continue
            }
            if transaction.productID == product.id {
                return .alreadyOwned
            }
            if let targetGroupId,
               transaction.subscriptionGroupID == targetGroupId {
                return .subscriptionChangeRequired
            }
        }
        return nil
    }
}
