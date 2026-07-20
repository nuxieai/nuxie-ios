import Foundation
import Nuxie

#if canImport(SuperwallKit)
import SuperwallKit
#endif

/// Errors thrown by the Superwall bridge.
public enum NuxieSuperwallBridgeError: LocalizedError {
    case productNotFound(identifier: String)
    case unknownRestoreFailure
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .productNotFound(let identifier):
            return "Superwall product not found for identifier \(identifier)."
        case .unknownRestoreFailure:
            return "Restore failed without an underlying error from Superwall."
        case .unsupportedPlatform:
            return "Superwall bridge is unavailable on this platform."
        }
    }
}

#if canImport(SuperwallKit)
/// Concrete implementation of ``NuxiePurchaseDelegate`` that routes purchase and
/// restore calls through Superwall's purchasing APIs.
public final class NuxieSuperwallPurchaseDelegate: NuxiePurchaseDelegate {
    private let superwall: Superwall

    /// Creates a new delegate that forwards work to the provided `Superwall` facade.
    /// - Parameter superwall: The Superwall instance to use, defaults to `Superwall.shared`.
    public init(superwall: Superwall = .shared) {
        self.superwall = superwall
    }

    public func purchase(_ product: any StoreProductProtocol) async -> Nuxie.PurchaseResult {
        do {
            let storeProduct = try await fetchProduct(withIdentifier: product.id)
            let result = await superwall.purchase(storeProduct)
            return mapPurchaseResult(result)
        } catch {
            return .failed(error)
        }
    }

    public func restore() async -> RestoreResult {
        let result = await superwall.restorePurchases()
        switch result {
        case .restored:
            let activeCount = await activeEntitlementCount()
            if activeCount > 0 {
                return .success(restoredCount: activeCount)
            }
            return .noPurchases
        case .failed(let error):
            return .failed(error ?? NuxieSuperwallBridgeError.unknownRestoreFailure)
        }
    }

    private func fetchProduct(withIdentifier identifier: String) async throws -> StoreProduct {
        let products = await superwall.products(for: [identifier])
        if let product = products.first(where: { $0.productIdentifier == identifier }) {
            return product
        }
        throw NuxieSuperwallBridgeError.productNotFound(identifier: identifier)
    }

    private func mapPurchaseResult(_ result: SuperwallKit.PurchaseResult) -> Nuxie.PurchaseResult {
        switch result {
        case .purchased:
            return .success
        case .cancelled:
            return .cancelled
        case .pending:
            return .pending
        case .failed(let error):
            return .failed(error)
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

    public func purchase(_ product: any StoreProductProtocol) async -> Nuxie.PurchaseResult {
        return .failed(NuxieSuperwallBridgeError.unsupportedPlatform)
    }

    public func restore() async -> RestoreResult {
        return .failed(NuxieSuperwallBridgeError.unsupportedPlatform)
    }
}
#endif
