import Foundation

/// The small internal result returned by the isolated Test Store adapter.
/// Test Store purchases intentionally carry no StoreKit transaction evidence.
struct NuxieTestStorePurchaseResponse: Sendable {
    let result: NativePurchaseResult
    let transactionId: String?

    init(result: NativePurchaseResult, transactionId: String? = nil) {
        self.result = result
        self.transactionId = transactionId
    }
}

struct NuxieTestStoreRestoreResponse: Sendable {
    let result: RestoreResult
    let products: [StoreProduct]

    init(result: RestoreResult, products: [StoreProduct] = []) {
        self.result = result
        self.products = products
    }
}

protocol NuxieTestStorePurchasing: Sendable {
    func setActiveDistinctId(_ distinctId: String) async
    func purchase(product: StoreProduct) async -> NuxieTestStorePurchaseResponse
    func restorePurchases() async -> NuxieTestStoreRestoreResponse
}

/// A deliberately unmistakable, local-only checkout surface for qualifying
/// Experiences and Journey branches before App Store commerce is configured.
/// It never creates a StoreKit transaction or calls a host purchase delegate.
actor NuxieTestStore: NuxieTestStorePurchasing {
    private var activeDistinctId = "anonymous"
    private var purchasedProductsByDistinctId: [String: [String: StoreProduct]] = [:]

    func setActiveDistinctId(_ distinctId: String) async {
        activeDistinctId = distinctId
    }

    func purchase(product: StoreProduct) async -> NuxieTestStorePurchaseResponse {
        let choice = await Self.presentPurchaseSheet(for: product)
        switch choice {
        case .purchased:
            var products = purchasedProductsByDistinctId[activeDistinctId, default: [:]]
            products[product.productId] = product
            purchasedProductsByDistinctId[activeDistinctId] = products
            return NuxieTestStorePurchaseResponse(
                result: .purchased(nil),
                transactionId: "nuxie-test-\(UUID().uuidString)"
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

    func restorePurchases() async -> NuxieTestStoreRestoreResponse {
        let choice = await Self.presentRestoreSheet()
        switch choice {
        case .restored:
            let purchasedProducts = purchasedProductsByDistinctId[activeDistinctId, default: [:]]
            return NuxieTestStoreRestoreResponse(
                result: purchasedProducts.isEmpty ? .noPurchases : .restored,
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

private enum TestStorePurchaseChoice: Sendable {
    case purchased
    case pending
    case cancelled
    case failed
}

private enum TestStoreRestoreChoice: Sendable {
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
