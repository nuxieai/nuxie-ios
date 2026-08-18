//
//  StoreKitManager.swift
//  MoodLog
//
//  Handles StoreKit 2 purchases and implements NuxiePurchaseDelegate.
//  This demonstrates how to integrate Nuxie SDK with your IAP flow.
//
//  **SwiftUI Adaptation:**
//  This class is an ObservableObject with @Published availableProducts,
//  allowing SwiftUI views to reactively display product information.
//

import Foundation
import StoreKit
import Nuxie
import Combine

/// Manages StoreKit 2 purchases and implements Nuxie's purchase delegate
/// **ObservableObject** for reactive SwiftUI updates
final class StoreKitManager: ObservableObject, NuxiePurchaseDelegate {

    // MARK: - Singleton

    static let shared = StoreKitManager()

    // MARK: - Published Properties

    /// Available products fetched from App Store
    /// Published so SwiftUI views can display product info
    @Published private(set) var availableProducts: [Product] = []

    // MARK: - Private Properties

    /// Active transaction listener task
    private var transactionListener: Task<Void, Error>?

    // MARK: - Initialization

    private init() {
        // Start listening for transactions
        startTransactionListener()

        // Fetch products on init
        Task {
            await fetchProducts()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Product Fetching

    /// Fetches available products from App Store Connect
    ///
    /// **Setup Required:**
    /// 1. Create products in App Store Connect
    /// 2. Update product IDs in Constants.swift
    /// 3. Add StoreKit configuration file for testing
    func fetchProducts() async {
        do {
            let products = try await Product.products(for: Constants.allProductIds)

            // Update on main thread since this is @Published
            await MainActor.run {
                self.availableProducts = products.sorted { $0.price < $1.price }
            }

            print("[StoreKitManager] Fetched \(products.count) products")
            for product in products {
                print("  - \(product.displayName): \(product.displayPrice)")
            }
        } catch {
            print("[StoreKitManager] Failed to fetch products: \(error)")
        }
    }

    /// Gets a product by ID
    /// - Parameter productId: Product identifier
    /// - Returns: Product if available
    func product(withId productId: String) -> Product? {
        return availableProducts.first { $0.id == productId }
    }

    // MARK: - NuxiePurchaseDelegate Implementation

    /// Purchase a product (implements NuxiePurchaseDelegate)
    /// - Parameter product: The product to purchase
    /// - Returns: Result of the purchase
    ///
    /// **Nuxie Integration:**
    /// The Nuxie SDK automatically tracks these events:
    /// - "purchase_completed" on success
    /// - "purchase_failed" on failure
    func purchase(product: Nuxie.StoreProduct) async -> PurchaseResult {
        // Buy the exact StoreKit product that Nuxie retained for presentation.
        guard let skProduct = product.rawProduct else {
            print("[StoreKitManager] Product not found: \(product.storeProductId)")
            return .failed(StoreKitManagerError.productNotFound)
        }

        do {
            // Attempt purchase
            let result = try await skProduct.purchase(
                options: product.storeKitPurchaseOptions
            )

            // Handle purchase result
            switch result {
            case .success(let verification):
                // Verify the transaction
                let transaction = try await verifyTransaction(verification)

                // Unlock Pro features
                await MainActor.run {
                    EntitlementManager.shared.unlockPro()
                }

                // Finish the transaction
                await transaction.finish()

                print("[StoreKitManager] Purchase successful: \(product.storeProductId)")
                return .purchased

            case .userCancelled:
                print("[StoreKitManager] Purchase cancelled by user")
                return .cancelled

            case .pending:
                print("[StoreKitManager] Purchase pending (e.g., Ask to Buy)")
                return .pending

            @unknown default:
                print("[StoreKitManager] Unknown purchase result")
                return .failed(StoreKitManagerError.unknownError)
            }
        } catch {
            print("[StoreKitManager] Purchase failed: \(error)")
            return .failed(error)
        }
    }

    /// Restore previous purchases (implements NuxiePurchaseDelegate)
    /// - Returns: Result of the restore operation
    ///
    /// **Nuxie Integration:**
    /// The Nuxie SDK automatically tracks "restore_completed" event
    func restorePurchases() async -> RestoreResult {
        var restoredCount = 0

        do {
            // Sync with App Store
            try await AppStore.sync()

            // Check all transactions
            for await result in Transaction.currentEntitlements {
                do {
                    let transaction = try await verifyTransaction(result)

                    // Check if transaction grants Pro access
                    if Constants.allProductIds.contains(transaction.productID) {
                        await MainActor.run {
                            EntitlementManager.shared.unlockPro()
                        }
                        restoredCount += 1
                    }

                    // No need to finish - these are current entitlements
                } catch {
                    print("[StoreKitManager] Verification failed for transaction: \(error)")
                }
            }

            if restoredCount > 0 {
                print("[StoreKitManager] Restored \(restoredCount) purchase(s)")
                return .restored
            } else {
                print("[StoreKitManager] No purchases to restore")
                return .noPurchases
            }
        } catch {
            print("[StoreKitManager] Restore failed: \(error)")
            return .failed(error)
        }
    }

    // MARK: - Transaction Handling

    /// Starts listening for transaction updates
    private func startTransactionListener() {
        transactionListener = Task.detached { [weak self] in
            for await result in Transaction.updates {
                do {
                    let transaction = try await self?.verifyTransaction(result)

                    guard let transaction = transaction else { continue }

                    // Grant entitlement if needed
                    if Constants.allProductIds.contains(transaction.productID) {
                        await MainActor.run {
                            EntitlementManager.shared.unlockPro()
                        }
                    }

                    // Finish transaction
                    await transaction.finish()

                    print("[StoreKitManager] Transaction updated: \(transaction.productID)")
                } catch {
                    print("[StoreKitManager] Transaction verification failed: \(error)")
                }
            }
        }
    }

    /// Verifies a transaction
    /// - Parameter result: Verification result from StoreKit
    /// - Returns: Verified transaction
    /// - Throws: Error if verification fails
    private func verifyTransaction(_ result: VerificationResult<Transaction>) async throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(let transaction, let error):
            // Verification failed - this could be a jailbroken device or tampered receipt
            print("[StoreKitManager] Transaction verification failed: \(error)")
            throw StoreKitManagerError.verificationFailed(error)
        }
    }

    /// Checks for existing entitlements on app launch
    ///
    /// Call this from App init to restore Pro status on launch
    func checkForExistingEntitlements() async {
        var hasProEntitlement = false

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try await verifyTransaction(result)

                if Constants.allProductIds.contains(transaction.productID) {
                    hasProEntitlement = true
                    break
                }
            } catch {
                print("[StoreKitManager] Entitlement check failed: \(error)")
            }
        }

        if hasProEntitlement {
            await MainActor.run {
                EntitlementManager.shared.unlockPro()
            }
            print("[StoreKitManager] Existing Pro entitlement found")
        } else {
            print("[StoreKitManager] No existing entitlements")
        }
    }
}

// MARK: - Errors

enum StoreKitManagerError: LocalizedError {
    case productNotFound
    case verificationFailed(Error)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "Product not available"
        case .verificationFailed(let error):
            return "Transaction verification failed: \(error.localizedDescription)"
        case .unknownError:
            return "An unknown error occurred"
        }
    }
}
