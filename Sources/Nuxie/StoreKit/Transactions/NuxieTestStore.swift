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

/// A deliberately unmistakable, local-only checkout surface for qualifying
/// Experiences and Journey branches before App Store commerce is configured.
/// It never creates a StoreKit transaction or calls a host purchase delegate.
actor NuxieTestStore: NuxieTestStorePurchasing {
    private var purchasedProductsByDistinctId: [String: [String: StoreProduct]] = [:]

    func purchase(
        product: StoreProduct,
        distinctId: String
    ) async -> NuxieTestStorePurchaseResponse {
        let choice = await Self.presentPurchaseSheet(for: product)
        switch choice {
        case .purchased:
            var products = purchasedProductsByDistinctId[distinctId, default: [:]]
            products[product.productId] = product
            purchasedProductsByDistinctId[distinctId] = products
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

private enum TestStorePurchaseChoice: Sendable {
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
