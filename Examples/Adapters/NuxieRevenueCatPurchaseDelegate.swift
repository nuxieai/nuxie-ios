import Foundation
import Nuxie
import StoreKit
@preconcurrency import RevenueCat

/// Errors thrown by the RevenueCat bridge.
public enum NuxieRevenueCatBridgeError: LocalizedError {
    /// RevenueCat did not return the requested App Store product.
    case productNotFound(identifier: String)

    public var errorDescription: String? {
        switch self {
        case .productNotFound(let identifier):
            return "RevenueCat product not found for identifier \(identifier)."
        }
    }
}

/// Concrete implementation of ``NuxiePurchaseDelegate`` that routes purchase and
/// restore calls through RevenueCat's `Purchases` SDK.
public final class NuxieRevenueCatPurchaseDelegate: NuxiePurchaseDelegate {
    private enum Constants {
        static let errorDomain = "RevenueCat.ErrorCode"
    }

    private let purchases: PurchasesType

    /// Creates a new delegate that forwards work to the provided `Purchases` instance.
    /// - Parameter purchases: The RevenueCat purchasing facade, defaults to `Purchases.shared`.
    public init(purchases: PurchasesType = Purchases.shared) {
        self.purchases = purchases
    }

    public func purchase(product: Nuxie.StoreProduct) async -> PurchaseResult {
        do {
            switch revenueCatCheckoutRoute(
                introEligibilityJWS: product.introductoryOfferEligibilityJWS,
                billingPlan: product.billingPlan
            ) {
            case .provider(let introEligibilityJWS):
                let rcProduct = try await fetchProduct(
                    withIdentifier: revenueCatProductIdentifier(
                        storeProductId: product.storeProductId,
                        billingPlan: product.billingPlan
                    )
                )
                let builder = PurchaseParams.Builder(product: rcProduct)
                #if compiler(>=6.1)
                if let introEligibilityJWS,
                   #available(iOS 15.0, macOS 15.4, tvOS 18.4, watchOS 11.4, *) {
                    _ = builder.with(
                        introductoryOfferEligibilityJWS: introEligibilityJWS
                    )
                }
                #endif
                let purchaseData = try await purchases.purchase(builder.build())
                return purchaseData.userCancelled ? .cancelled : .purchased
            case .storeKit:
                return await purchaseExactStoreKitTerms(product)
            }
        } catch {
            if let errorCode = extractErrorCode(from: error) {
                return mapPurchaseError(errorCode)
            }
            return .failed(error)
        }
    }

    private func purchaseExactStoreKitTerms(
        _ product: Nuxie.StoreProduct
    ) async -> Nuxie.PurchaseResult {
        guard let rawProduct = product.rawProduct else {
            return .failed(NuxieRevenueCatBridgeError.productNotFound(
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
                case .unverified(_, let error):
                    return .failed(error)
                }
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(NuxieRevenueCatBridgeError.productNotFound(
                    identifier: product.storeProductId
                ))
            }
        } catch {
            return .failed(error)
        }
    }

    public func restorePurchases() async -> RestoreResult {
        do {
            let customerInfo = try await purchases.restorePurchases()
            let activeCount = customerInfo.entitlements.active.count

            if activeCount > 0 {
                return .restored
            }

            return .noPurchases
        } catch {
            if let errorCode = extractErrorCode(from: error) {
                return mapRestoreError(errorCode)
            }
            return .failed(error)
        }
    }

    private func fetchProduct(withIdentifier identifier: String) async throws -> RevenueCat.StoreProduct {
        let products = await purchases.products([identifier])
        if let product = products.first {
            return product
        }
        throw NuxieRevenueCatBridgeError.productNotFound(identifier: identifier)
    }

    private func extractErrorCode(from error: Error) -> ErrorCode? {
        if let errorCode = error as? ErrorCode {
            return errorCode
        }

        let nsError = error as NSError
        guard nsError.domain == Constants.errorDomain else {
            return nil
        }

        return ErrorCode(rawValue: nsError.code)
    }

    private func mapPurchaseError(_ error: ErrorCode) -> PurchaseResult {
        switch error {
        case .purchaseCancelledError:
            return .cancelled
        case .paymentPendingError:
            return .pending
        default:
            return .failed(error)
        }
    }

    private func mapRestoreError(_ error: ErrorCode) -> RestoreResult {
        return .failed(error)
    }
}

/// RevenueCat uses the App Store product identifier as its product lookup key.
/// Nuxie billing-plan variants are routed through StoreKit directly because
/// RevenueCat's product lookup does not select Apple's billing-plan option.
private func revenueCatProductIdentifier(
    storeProductId: String,
    billingPlan: Nuxie.StoreProduct.BillingPlan
) -> String {
    _ = billingPlan
    return storeProductId
}
