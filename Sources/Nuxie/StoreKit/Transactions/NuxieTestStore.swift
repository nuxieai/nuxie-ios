import Foundation

/// The small internal result returned by the isolated Test Store adapter.
/// Test Store purchases intentionally carry no StoreKit transaction evidence;
/// a purchase carries the Customer's access after the server's grant.
struct NuxieTestStorePurchaseResponse: Sendable {
    let result: NativePurchaseResult
    let transactionId: String?
    let features: [PurchaseFeature]?

    init(
        result: NativePurchaseResult,
        transactionId: String? = nil,
        features: [PurchaseFeature]? = nil
    ) {
        self.result = result
        self.transactionId = transactionId
        self.features = features
    }
}

struct NuxieTestStoreRestoreResponse: Sendable {
    let result: TestStoreRestoreResult
    let products: [StoreProduct]

    init(result: TestStoreRestoreResult, products: [StoreProduct] = []) {
        self.result = result
        self.products = products
    }
}

enum TestStoreRestoreResult: Sendable {
    case restored
    case failed(Error)
    case noPurchases
}

protocol NuxieTestStorePurchasing: Sendable {
    func purchase(
        product: StoreProduct,
        distinctId: String
    ) async -> NuxieTestStorePurchaseResponse
    func restorePurchases(distinctId: String) async -> NuxieTestStoreRestoreResponse
}

/// A deliberately unmistakable checkout surface for qualifying Experiences
/// and Journey branches in a debug build before App Store purchases are
/// configured. It never creates a StoreKit transaction or calls a host
/// purchase delegate. A purchase asks the server to grant the Product's
/// Features, as RevenueCat's Test Store does; without that grant it fails.
actor NuxieTestStore: NuxieTestStorePurchasing {
    private let granting: any TestStoreGranting
    private var purchasedProductsByDistinctId: [String: [String: StoreProduct]] = [:]
    /// A grant whose outcome is unknown (the server may have committed it)
    /// keeps its transaction ID, so the customer's next Purchased of the same
    /// Product replays that grant instead of granting again. A purchase takes
    /// the ID while it runs, so one that overlaps it is a purchase of its own.
    private var unsettledTransactionIds: [String: String] = [:]

    init(granting: any TestStoreGranting) {
        self.granting = granting
    }

    func purchase(
        product: StoreProduct,
        distinctId: String
    ) async -> NuxieTestStorePurchaseResponse {
        let choice = await Self.presentPurchaseSheet(for: product)
        return await complete(choice, product: product, distinctId: distinctId)
    }

    /// The outcome of the tester's choice. Purchased asks the server to grant
    /// the Product's Features; without that grant the purchase fails.
    func complete(
        _ choice: TestStorePurchaseChoice,
        product: StoreProduct,
        distinctId: String
    ) async -> NuxieTestStorePurchaseResponse {
        guard case .purchased = choice else {
            return purchaseResponse(for: choice, product: product, distinctId: distinctId)
        }
        let attempt = "\(distinctId)\u{0}\(product.productId)"
        let transactionId = unsettledTransactionIds.removeValue(forKey: attempt)
            ?? "nuxie-test-\(UUID().uuidString)"
        do {
            guard let productId = product.purchaseContext?.productId else {
                throw StoreKitError.apiMisuse(
                    reason: "Test Store purchases need a published Product"
                )
            }
            let response: PurchaseResponse
            do {
                response = try await granting.grantTestStorePurchase(
                    productId: productId,
                    transactionId: transactionId,
                    distinctId: distinctId
                )
            } catch {
                if !Self.refusesGrant(error) {
                    unsettledTransactionIds[attempt] = transactionId
                }
                throw error
            }
            guard response.success else {
                throw StoreKitError.purchaseFailed(nil)
            }
            return purchaseResponse(
                for: .purchased,
                product: product,
                distinctId: distinctId,
                transactionId: transactionId,
                features: response.features
            )
        } catch {
            LogWarning("NuxieTestStore: grant failed: \(error)")
            return NuxieTestStorePurchaseResponse(
                result: .failed(StoreKitError.purchaseFailed(error))
            )
        }
    }

    /// The server answered and granted nothing; any other failure may have
    /// committed the grant.
    private static func refusesGrant(_ error: Error) -> Bool {
        guard let status = (error as? NuxieNetworkError)?.httpStatusCode else {
            return false
        }
        return (400..<500).contains(status) && status != 408 && status != 429
    }

    func purchaseResponse(
        for choice: TestStorePurchaseChoice,
        product: StoreProduct,
        distinctId: String,
        transactionId: String? = nil,
        features: [PurchaseFeature]? = nil
    ) -> NuxieTestStorePurchaseResponse {
        switch choice {
        case .purchased:
            var products = purchasedProductsByDistinctId[distinctId, default: [:]]
            products[product.productId] = product
            purchasedProductsByDistinctId[distinctId] = products
            return NuxieTestStorePurchaseResponse(
                result: .purchased(nil),
                transactionId: transactionId ?? "nuxie-test-\(UUID().uuidString)",
                features: features
            )
        case .pending:
            return NuxieTestStorePurchaseResponse(result: .pending)
        case .cancelled:
            return NuxieTestStorePurchaseResponse(result: .cancelled)
        case .failed:
            return NuxieTestStorePurchaseResponse(
                result: .failed(StoreKitError.purchaseFailed(nil))
            )
        }
    }

    func restorePurchases(distinctId: String) async -> NuxieTestStoreRestoreResponse {
        let choice = await Self.presentRestoreSheet()
        return restoreResponse(for: choice, distinctId: distinctId)
    }

    func restoreResponse(
        for choice: TestStoreRestoreChoice,
        distinctId: String
    ) -> NuxieTestStoreRestoreResponse {
        switch choice {
        case .restored:
            let purchasedProducts = purchasedProductsByDistinctId[distinctId, default: [:]]
            return NuxieTestStoreRestoreResponse(
                result: .restored,
                products: Array(purchasedProducts.values)
            )
        case .noPurchases:
            return NuxieTestStoreRestoreResponse(result: .noPurchases)
        case .failed:
            return NuxieTestStoreRestoreResponse(
                result: .failed(StoreKitError.restoreFailed(nil))
            )
        }
    }
}

enum TestStorePurchaseChoice: Sendable {
    case purchased
    case pending
    case cancelled
    case failed
}

enum TestStoreRestoreChoice: Sendable {
    case restored
    case noPurchases
    case failed
}

#if canImport(UIKit)
import UIKit

private extension NuxieTestStore {
    @MainActor
    static func presentPurchaseSheet(for product: StoreProduct) async -> TestStorePurchaseChoice {
        await withCheckedContinuation { continuation in
            presentAlert(
                title: "Nuxie Test Store",
                message: "TEST PURCHASE — no charge, no App Store transaction.\n\n\(product.name)\n\(product.price)",
                actions: [
                    ("Purchased", .purchased),
                    ("Pending", .pending),
                    ("Cancelled", .cancelled),
                    ("Failed", .failed),
                ],
                continuation: continuation
            )
        }
    }

    @MainActor
    static func presentRestoreSheet() async -> TestStoreRestoreChoice {
        await withCheckedContinuation { continuation in
            presentAlert(
                title: "Nuxie Test Store — Restore",
                message: "TEST RESTORE — no App Store account is contacted.",
                actions: [
                    ("Restored", .restored),
                    ("No Purchases", .noPurchases),
                    ("Failed", .failed),
                ],
                continuation: continuation
            )
        }
    }

    @MainActor
    static func presentAlert<Choice: Sendable>(
        title: String,
        message: String,
        actions: [(String, Choice)],
        continuation: CheckedContinuation<Choice, Never>
    ) {
        guard #available(iOS 15.0, *),
              let root = UIApplication.shared.activeWindow?.rootViewController else {
            continuation.resume(returning: actions.last!.1)
            return
        }
        let presenter = topViewController(from: root)
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        for (title, choice) in actions {
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                continuation.resume(returning: choice)
            })
        }
        presenter.present(alert, animated: true)
    }

    @MainActor
    static func topViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tab = root as? UITabBarController,
           let selected = tab.selectedViewController {
            return topViewController(from: selected)
        }
        return root
    }
}
#else
private extension NuxieTestStore {
    static func presentPurchaseSheet(for _: StoreProduct) async -> TestStorePurchaseChoice {
        .failed
    }

    static func presentRestoreSheet() async -> TestStoreRestoreChoice {
        .failed
    }
}
#endif
