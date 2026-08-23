import Foundation
import StoreKit
import StoreKitTest
import XCTest
@testable import Nuxie

enum NativeStoreKitTestProduct: String, CaseIterable, Sendable {
    case consumable = "com.nuxie.storekit.consumable"
    case lifetime = "com.nuxie.storekit.lifetime"
}

enum NativeStoreKitTestError: Error {
    case missingConfiguration
    case missingProduct(String)
    case unavailableStoreKitTestDaemon(storefront: String)
    case missingAskToBuyTransaction(String)
    case transactionStateDidNotConverge(String)
}

/// Owns the StoreKitTest process state shared by one native-commerce test.
/// Tests express scenarios through this seam while product lookup, reset,
/// unfinished-transaction polling, and cleanup remain deterministic here.
final class NativeStoreKitTestHarness: @unchecked Sendable {
    private let session: SKTestSession

    init() throws {
        guard let configurationURL = Bundle(for: NativeStoreKitTestHarness.self).url(
            forResource: "NuxieNativeCommerce",
            withExtension: "storekit"
        ) else {
            throw NativeStoreKitTestError.missingConfiguration
        }
        session = try SKTestSession(contentsOf: configurationURL)
    }

    func reset() async throws {
        guard !session.storefront.isEmpty else {
            throw NativeStoreKitTestError.unavailableStoreKitTestDaemon(
                storefront: session.storefront
            )
        }
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        session.askToBuyEnabled = false
        session.interruptedPurchasesEnabled = false
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        try await session.setSimulatedError(nil, forAPI: .verification)
        try await session.setSimulatedError(nil, forAPI: .appStoreSync)
        try await session.setSimulatedError(nil, forAPI: .subscriptionStatus)
        try await session.setSimulatedError(nil, forAPI: .appTransaction)
    }

    @discardableResult
    func buyExternally(
        _ id: NativeStoreKitTestProduct,
        options: Set<Product.PurchaseOption> = []
    ) async throws -> Transaction {
        try await session.buyProduct(identifier: id.rawValue, options: options)
    }

    func simulateUserCancellation() async throws {
        try await session.setSimulatedError(
            .generic(.userCancelled),
            forAPI: .purchase
        )
    }

    func enableAskToBuy() {
        session.askToBuyEnabled = true
    }

    func approveAskToBuy(for id: NativeStoreKitTestProduct) throws -> UInt {
        guard let transaction = session.allTransactions().first(where: {
            $0.productIdentifier == id.rawValue && $0.pendingAskToBuyConfirmation
        }) else {
            throw NativeStoreKitTestError.missingAskToBuyTransaction(id.rawValue)
        }
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        return transaction.identifier
    }

    func refund(transactionId: UInt64) throws {
        try session.refundTransaction(identifier: UInt(transactionId))
    }

    func transactionCount(for id: NativeStoreKitTestProduct) -> Int {
        session.allTransactions().filter { $0.productIdentifier == id.rawValue }.count
    }

    func product(id: NativeStoreKitTestProduct) async throws -> StoreProduct {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var rawProduct: Product?
        repeat {
            rawProduct = try await Product.products(for: [id.rawValue]).first
            if rawProduct == nil {
                try await Task.sleep(for: .milliseconds(25))
            }
        } while rawProduct == nil && clock.now < deadline

        guard let rawProduct else {
            throw NativeStoreKitTestError.missingProduct(id.rawValue)
        }
        return StoreProduct(
            productId: "nuxie-\(id.rawValue)",
            storeProductId: rawProduct.id,
            placementId: "storekit-test:0",
            name: rawProduct.displayName,
            description: rawProduct.description,
            price: rawProduct.displayPrice,
            period: nil,
            productType: rawProduct.productType,
            appStoreProduct: rawProduct
        )
    }

    func assertEventuallyUnfinished(
        transactionId: String,
        exists: Bool,
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            let ids = await unfinishedTransactionIDs()
            if ids.contains(transactionId) == exists {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline

        XCTFail(
            "Transaction \(transactionId) unfinished state did not become \(exists)",
            file: file,
            line: line
        )
        throw NativeStoreKitTestError.transactionStateDidNotConverge(transactionId)
    }

    func assertEventuallyRevoked(
        productId: NativeStoreKitTestProduct,
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if let result = await Transaction.latest(for: productId.rawValue),
               case .verified(let transaction) = result,
               transaction.revocationDate != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < deadline

        XCTFail(
            "Product \(productId.rawValue) did not become revoked",
            file: file,
            line: line
        )
        throw NativeStoreKitTestError.transactionStateDidNotConverge(
            productId.rawValue
        )
    }

    func finishAllTransactions() async {
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result {
                await transaction.finish()
            }
        }
        session.clearTransactions()
    }

    private func unfinishedTransactionIDs() async -> Set<String> {
        var ids: Set<String> = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result {
                ids.insert(String(transaction.id))
            }
        }
        return ids
    }
}

extension NativePurchaseResult {
    var purchasedEvidence: StoreTransactionEvidence? {
        guard case .purchased(let evidence) = self else { return nil }
        return evidence
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    var isAlreadyOwned: Bool {
        if case .alreadyOwned = self { return true }
        return false
    }
}

extension NativeRestoreResult {
    var isRestored: Bool {
        if case .restored = self { return true }
        return false
    }

    var isNoPurchases: Bool {
        if case .noPurchases = self { return true }
        return false
    }
}
