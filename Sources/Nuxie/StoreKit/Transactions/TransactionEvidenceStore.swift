import Foundation

struct StoredLocalEntitlementGrant: Codable, Equatable, Sendable {
    let featureId: String
    let featureExternalId: String?
    let allowanceType: String?
    let allowance: Double?
}

struct StoredTransactionEvidence: Codable, Equatable, Sendable {
    let scope: PurchaseStorageScope
    let transactionJws: String
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    let distinctId: String
    let recordedAt: Date
    /// Internal and external Feature identifiers from the signed Product.
    /// This is selection metadata for the server command, not local access.
    let productFeatureIds: [String]
    let localEntitlementGrants: [StoredLocalEntitlementGrant]
    let isRevoked: Bool
    let finishRequired: Bool
    let commercialContext: PurchaseCommercialContext?
    /// Checkout-scoped stable event identity, when evidence was correlated to
    /// a durable pre-delegate marker.
    let checkoutCompletionEventId: String?
    /// Durable stable-event delivery claim. It remains with retry evidence
    /// while receipt sync is offline, preventing a cold relaunch from
    /// replaying or rerouting the same commercial success transition.
    let completionDeliveredAt: Date?
    /// Backend receipt acknowledgement retained independently from commercial
    /// completion delivery when the purchasing customer is not active.
    let backendSyncedAt: Date?

    init(
        scope: PurchaseStorageScope = .testFixture,
        transactionJws: String,
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        distinctId: String,
        recordedAt: Date,
        productFeatureIds: [String] = [],
        localEntitlementGrants: [StoredLocalEntitlementGrant],
        isRevoked: Bool,
        finishRequired: Bool = false,
        commercialContext: PurchaseCommercialContext? = nil,
        checkoutCompletionEventId: String? = nil,
        completionDeliveredAt: Date? = nil,
        backendSyncedAt: Date? = nil
    ) {
        self.scope = scope
        self.transactionJws = transactionJws
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.distinctId = distinctId
        self.recordedAt = recordedAt
        self.productFeatureIds = productFeatureIds
        self.localEntitlementGrants = localEntitlementGrants
        self.isRevoked = isRevoked
        self.finishRequired = finishRequired
        self.commercialContext = commercialContext
        self.checkoutCompletionEventId = checkoutCompletionEventId
        self.completionDeliveredAt = completionDeliveredAt
        self.backendSyncedAt = backendSyncedAt
    }

    func replacing(backendSyncedAt: Date?) -> Self {
        Self(
            scope: scope,
            // Once the backend accepts the signed receipt, only the bounded
            // commercial completion context needs to survive for an inactive
            // customer. Do not retain accepted receipt material for 90 days.
            transactionJws: backendSyncedAt == nil ? transactionJws : "",
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            distinctId: distinctId,
            recordedAt: recordedAt,
            productFeatureIds: productFeatureIds,
            localEntitlementGrants: localEntitlementGrants,
            isRevoked: isRevoked,
            finishRequired: finishRequired,
            commercialContext: commercialContext,
            checkoutCompletionEventId: checkoutCompletionEventId,
            completionDeliveredAt: completionDeliveredAt,
            backendSyncedAt: backendSyncedAt
        )
    }
}

protocol TransactionEvidenceStoreProtocol: Sendable {
    func load() -> StoreReadResult<[String: StoredTransactionEvidence]>
    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool
}

/// Protected, minimal transaction evidence retained until the backend accepts
/// it. This is deliberately separate from preferences, analytics, and Journey
/// state. The file uses iOS data protection when available.
final class TransactionEvidenceStore: TransactionEvidenceStoreProtocol {
    private let fileURL: URL
    private let readFailureLogger = StoreReadFailureLogger()

    init(
        customStoragePath: URL? = nil,
        scope: PurchaseStorageScope = .testFixture
    ) {
        let base = scope.storageDirectory(customStoragePath: customStoragePath)
        fileURL = base.appendingPathComponent("transaction-evidence.json")
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
    }

    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .absent
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: fileURL)
            return .value(try decoder.decode(
                [String: StoredTransactionEvidence].self,
                from: data
            ))
        } catch {
            if readFailureLogger.shouldLog() {
                LogError("TransactionEvidenceStore: evidence is unreadable: \(error)")
            }
            return .unreadable
        }
    }

    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        guard !load().isUnreadable else { return false }
        if entries.isEmpty {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {
                // There is nothing to remove; the empty store is durable.
            } catch {
                LogError("TransactionEvidenceStore: failed to clear evidence")
                return false
            }
            return true
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            LogError("TransactionEvidenceStore: failed to encode evidence")
            return false
        }
        do {
            try data.write(
                to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            LogError("TransactionEvidenceStore: failed to persist evidence")
            return false
        }
        return true
    }
}

final class InMemoryTransactionEvidenceStore:
    TransactionEvidenceStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var entries: [String: StoredTransactionEvidence] = [:]

    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> {
        lock.lock()
        defer { lock.unlock() }
        return .value(entries)
    }

    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        lock.lock()
        self.entries = entries
        lock.unlock()
        return true
    }
}
