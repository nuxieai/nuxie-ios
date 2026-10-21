import CryptoKit
import Foundation

struct StoredLocalEntitlementGrant: Codable, Equatable, Sendable {
    let featureId: String
    let featureExternalId: String?
    let allowanceType: String?
    let allowance: Double?
}

/// One purchase's durable outbox entry, keyed by its StoreKit transaction id.
///
/// The entry holds what the SDK sends to `POST /purchase`: the signed
/// transaction, why it is sent (`reason`), the customer it is sent for
/// (`distinctId`, the requester) and whether that customer had signed in
/// (`customerKind`), all recorded when the send was admitted so a retry never
/// works them out again. The server's 200 or refusal (409/400) answers the
/// send; a transport or 5xx failure keeps it for a retry with backoff, across
/// restarts. Each write that changes what the entry sends is a new admission
/// (`admissionId`), and an answer applies only to the admission its send
/// carried. The entry is not purchase authority: who owns the purchase is
/// what the server last said, and access comes from the server profile, so
/// the entry only lets the buyer's own unanswered purchase unlock early.
///
/// The rest is local bookkeeping that can outlive the send: finishing the
/// StoreKit transaction and delivering the checkout's completion event. See
/// `docs/purchase-outbox.md` and `fixtures/purchases/purchase-outbox.json`.
struct StoredTransactionEvidence: Codable, Equatable, Sendable {
    let scope: PurchaseStorageScope
    /// The signed StoreKit transaction to send; empty once answered.
    let transactionJws: String
    let transactionId: String
    let originalTransactionId: String
    let productId: String
    /// The requester: the customer this purchase is sent for.
    let distinctId: String
    let recordedAt: Date
    /// Internal and external Feature identifiers from the signed Product.
    /// This is selection metadata for the server command, not entitlement state.
    let productFeatureIds: [String]
    /// StoreKit reports the signed transaction as revoked (refunded). A
    /// revoked purchase never unlocks early; the server decides access.
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
    /// When the server answered the send, by accepting (200) or refusing
    /// (409/400) it. An answered entry is no longer sent; it stays only while
    /// its finish or completion delivery is outstanding.
    let answeredAt: Date?
    /// The account token StoreKit reports on the transaction. Only a
    /// transaction whose token is the one Nuxie derives for the current
    /// customer is their own purchase, and only it unlocks before the server
    /// answers.
    let appAccountToken: UUID?
    /// Why the SDK sends this purchase, recorded at admission.
    let reason: PurchaseSyncReason
    /// Whether the requester had signed in, recorded at admission
    /// ("identified" when the SDK could not tell).
    let customerKind: PurchaseCustomerKind
    /// Sends that failed without an answer; the retry backoff grows with it.
    let sendAttempts: Int
    /// When a failed send is due again: the time it failed plus the backoff
    /// for its attempt count. Nil until a send fails, and once answered.
    let retryDueAt: Date?
    /// The admission that wrote what this entry sends. A write that changes
    /// what is sent (the signed transaction, requester, reason or customer
    /// kind), or opens an answered entry again, is a new admission with a
    /// fresh id; other writes keep it. Each send carries the id of the
    /// admission it sent, and its answer applies to the entry only while the
    /// id still matches.
    private(set) var admissionId: UUID

    init(
        scope: PurchaseStorageScope = .testFixture,
        transactionJws: String,
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        distinctId: String,
        recordedAt: Date,
        productFeatureIds: [String] = [],
        isRevoked: Bool,
        finishRequired: Bool = false,
        commercialContext: PurchaseCommercialContext? = nil,
        checkoutCompletionEventId: String? = nil,
        completionDeliveredAt: Date? = nil,
        answeredAt: Date? = nil,
        appAccountToken: UUID? = nil,
        reason: PurchaseSyncReason = .sync,
        customerKind: PurchaseCustomerKind = .identified,
        sendAttempts: Int = 0,
        retryDueAt: Date? = nil,
        admissionId: UUID = UUID()
    ) {
        self.scope = scope
        self.transactionJws = transactionJws
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.distinctId = distinctId
        self.recordedAt = recordedAt
        self.productFeatureIds = productFeatureIds
        self.isRevoked = isRevoked
        self.finishRequired = finishRequired
        self.commercialContext = commercialContext
        self.checkoutCompletionEventId = checkoutCompletionEventId
        self.completionDeliveredAt = completionDeliveredAt
        self.answeredAt = answeredAt
        self.appAccountToken = appAccountToken
        self.reason = reason
        self.customerKind = customerKind
        self.sendAttempts = sendAttempts
        self.retryDueAt = retryDueAt
        self.admissionId = admissionId
    }

    /// The previous SDK's name for `answeredAt`.
    private enum PreviousCodingKeys: String, CodingKey {
        case backendSyncedAt
    }

    /// Entries written before the outbox fields existed read as syncs for a
    /// signed-in customer, the kind the server can move but never merge. The
    /// server's earlier acknowledgement (`backendSyncedAt`) still answers
    /// the send, so such an entry finishes its bookkeeping and expires.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let previous = try decoder.container(keyedBy: PreviousCodingKeys.self)
        let transactionJws = try container.decode(String.self, forKey: .transactionJws)
        let transactionId = try container.decode(String.self, forKey: .transactionId)
        let distinctId = try container.decode(String.self, forKey: .distinctId)
        self.init(
            scope: try container.decode(PurchaseStorageScope.self, forKey: .scope),
            transactionJws: transactionJws,
            transactionId: transactionId,
            originalTransactionId: try container.decode(String.self, forKey: .originalTransactionId),
            productId: try container.decode(String.self, forKey: .productId),
            distinctId: distinctId,
            recordedAt: try container.decode(Date.self, forKey: .recordedAt),
            productFeatureIds: try container.decode([String].self, forKey: .productFeatureIds),
            isRevoked: try container.decode(Bool.self, forKey: .isRevoked),
            finishRequired: try container.decode(Bool.self, forKey: .finishRequired),
            commercialContext: try container.decodeIfPresent(
                PurchaseCommercialContext.self, forKey: .commercialContext
            ),
            checkoutCompletionEventId: try container.decodeIfPresent(
                String.self, forKey: .checkoutCompletionEventId
            ),
            completionDeliveredAt: try container.decodeIfPresent(
                Date.self, forKey: .completionDeliveredAt
            ),
            answeredAt: try container.decodeIfPresent(Date.self, forKey: .answeredAt)
                ?? previous.decodeIfPresent(Date.self, forKey: .backendSyncedAt),
            appAccountToken: try container.decodeIfPresent(UUID.self, forKey: .appAccountToken),
            reason: try container.decodeIfPresent(PurchaseSyncReason.self, forKey: .reason) ?? .sync,
            customerKind: try container.decodeIfPresent(
                PurchaseCustomerKind.self, forKey: .customerKind
            ) ?? .identified,
            sendAttempts: try container.decodeIfPresent(Int.self, forKey: .sendAttempts) ?? 0,
            retryDueAt: try container.decodeIfPresent(Date.self, forKey: .retryDueAt),
            admissionId: try container.decodeIfPresent(UUID.self, forKey: .admissionId)
                ?? Self.previousAdmissionId(
                    transactionId: transactionId,
                    transactionJws: transactionJws,
                    distinctId: distinctId
                )
        )
    }

    /// An entry the previous SDK wrote has no admission id. It gets one
    /// derived from what it sends, so every read of it names the same
    /// admission until it is next written.
    private static func previousAdmissionId(
        transactionId: String,
        transactionJws: String,
        distinctId: String
    ) -> UUID {
        let material = ["previous-admission", transactionId, distinctId, transactionJws]
            .joined(separator: "\u{1f}")
        let d = Array(SHA256.hash(data: Data(material.utf8)))
        return UUID(uuid: (
            d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
            d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]
        ))
    }

    /// This entry as written over `current`. A write that changes what is
    /// sent, or opens an answered entry again, is a new admission; any other
    /// write keeps the current one.
    func admitted(over current: Self?) -> Self {
        var written = self
        if let current, !isUnsent || (current.isUnsent && sendsSame(as: current)) {
            written.admissionId = current.admissionId
        } else {
            written.admissionId = UUID()
        }
        return written
    }

    private func sendsSame(as other: Self) -> Bool {
        transactionJws == other.transactionJws
            && distinctId == other.distinctId
            && reason == other.reason
            && customerKind == other.customerKind
            && isRevoked == other.isRevoked
    }

    /// Whether this entry is still to be sent.
    var isUnsent: Bool {
        answeredAt == nil && !transactionJws.isEmpty
    }

    /// Whether this entry is only the purchase's record: answered, its
    /// StoreKit transaction finished and its checkout completion delivered.
    var isSettled: Bool {
        answeredAt != nil && !finishRequired
            && (commercialContext == nil || completionDeliveredAt != nil)
    }

    /// Whether this entry lets `distinctId` in before the server answers:
    /// their own unanswered, unrevoked purchase, by account token. A Restore
    /// claim waits for the server, as Restore itself does.
    func unlocksEarly(for distinctId: String) -> Bool {
        answeredAt == nil && !isRevoked && reason != .restore
            && self.distinctId == distinctId
            && appAccountToken == scope.appAccountToken(distinctId: distinctId)
    }

    func replacing(answeredAt: Date?) -> Self {
        Self(
            scope: scope,
            // Once the server answers the signed receipt, only the bounded
            // commercial completion context needs to survive for an inactive
            // customer. Do not retain answered receipt material for 90 days.
            transactionJws: answeredAt == nil ? transactionJws : "",
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            distinctId: distinctId,
            recordedAt: recordedAt,
            productFeatureIds: productFeatureIds,
            isRevoked: isRevoked,
            finishRequired: finishRequired,
            commercialContext: commercialContext,
            checkoutCompletionEventId: checkoutCompletionEventId,
            completionDeliveredAt: completionDeliveredAt,
            answeredAt: answeredAt,
            appAccountToken: appAccountToken,
            reason: reason,
            customerKind: customerKind,
            sendAttempts: answeredAt == nil ? sendAttempts : 0,
            retryDueAt: answeredAt == nil ? retryDueAt : nil,
            admissionId: admissionId
        )
    }

    /// The same entry after one more send failed without an answer at
    /// `failedAt`: it is due again after the backoff for its attempt count.
    func replacingAfterFailedSend(at failedAt: Date) -> Self {
        Self(
            scope: scope,
            transactionJws: transactionJws,
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            distinctId: distinctId,
            recordedAt: recordedAt,
            productFeatureIds: productFeatureIds,
            isRevoked: isRevoked,
            finishRequired: finishRequired,
            commercialContext: commercialContext,
            checkoutCompletionEventId: checkoutCompletionEventId,
            completionDeliveredAt: completionDeliveredAt,
            answeredAt: answeredAt,
            appAccountToken: appAccountToken,
            reason: reason,
            customerKind: customerKind,
            sendAttempts: sendAttempts + 1,
            retryDueAt: failedAt.addingTimeInterval(
                TransactionObserver.outboxRetryDelay(afterAttempts: sendAttempts + 1)
            ),
            admissionId: admissionId
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
