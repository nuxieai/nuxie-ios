import Foundation
import Nuxie
import RevenueCat

/// Errors thrown by the RevenueCat bridge.
public enum NuxieRevenueCatBridgeError: LocalizedError {
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

    public func purchase(_ product: any StoreProductProtocol) async -> PurchaseResult {
        do {
            let rcProduct = try await fetchProduct(withIdentifier: product.id)
            let purchaseData = try await purchases.purchase(product: rcProduct)

            if purchaseData.userCancelled {
                return .cancelled
            }

            return .success
        } catch {
            if let errorCode = extractErrorCode(from: error) {
                return mapPurchaseError(errorCode)
            }
            return .failed(error)
        }
    }

    public func restore() async -> RestoreResult {
        do {
            let customerInfo = try await purchases.restorePurchases()
            let activeCount = customerInfo.entitlements.active.count

            if activeCount > 0 {
                return .success(restoredCount: activeCount)
            }

            return .noPurchases
        } catch {
            if let errorCode = extractErrorCode(from: error) {
                return mapRestoreError(errorCode)
            }
            return .failed(error)
        }
    }

    private func fetchProduct(withIdentifier identifier: String) async throws -> StoreProduct {
        let products = await purchases.products([identifier])
        if let product = products.first(where: { $0.productIdentifier == identifier }) {
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
