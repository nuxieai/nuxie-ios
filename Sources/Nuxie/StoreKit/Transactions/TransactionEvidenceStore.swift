import Foundation

struct StoredLocalEntitlementGrant: Codable, Equatable, Sendable {
    let featureId: String
    let featureExternalId: String?
    let allowanceType: String?
    let allowance: Double?
}

/// One customer's consume admissions. Nil kinds retain the undeclared
/// operations reconstructed from that customer's legacy evidence.
struct StoredFeatureUseDeclarations: Codable, Equatable, Sendable {
    var customerKinds: [String: PurchaseCustomerKind]?
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
    /// Customer id, then stable operation id. Claims retain all customers'
    /// histories; a customer's first use never borrows another's admission.
    /// New rows start empty. Missing on legacy evidence: reconstructed uses
    /// remain undeclared for the row's recorded customer only.
    var featureUseDeclarations: [String: StoredFeatureUseDeclarations]?
    /// The StoreKit environment the signed transaction names ("Production",
    /// "Sandbox" or "Xcode"), read when the entry is written. It outlives the
    /// signed transaction, which is dropped once the send is answered.
    let storeKitEnvironment: String?
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
        featureUseDeclarations: [String: StoredFeatureUseDeclarations]? = [:],
        storeKitEnvironment: String? = nil,
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
        self.featureUseDeclarations = featureUseDeclarations
        self.storeKitEnvironment = storeKitEnvironment
        self.sendAttempts = sendAttempts
        self.retryDueAt = retryDueAt
        self.admissionId = admissionId
    }

    /// Attach legacy absence to its original customer before an ownership
    /// move. Other customers can admit their own declared uses.
    var retainedFeatureUseDeclarations: [String: StoredFeatureUseDeclarations] {
        featureUseDeclarations ?? [
            distinctId: StoredFeatureUseDeclarations(customerKinds: nil),
        ]
    }

    func featureUseCustomerKinds(for customerId: String) -> [String: PurchaseCustomerKind]? {
        guard let declarations = retainedFeatureUseDeclarations[customerId] else { return [:] }
        return declarations.customerKinds
    }

    mutating func admitFeatureUse(
        customerId: String,
        operationId: String,
        customerKind: PurchaseCustomerKind
    ) {
        var history = retainedFeatureUseDeclarations
        var declarations = history[customerId] ?? StoredFeatureUseDeclarations(customerKinds: [:])
        if var kinds = declarations.customerKinds, kinds[operationId] == nil {
            kinds[operationId] = customerKind
            declarations.customerKinds = kinds
        }
        history[customerId] = declarations
        featureUseDeclarations = history
    }

    /// This entry as a new admission, whatever it sends: an explicit
    /// Restore or purchase claim is always one.
    func newlyAdmitted() -> Self {
        var written = self
        written.admissionId = UUID()
        return written
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

    /// Whether this entry is newer than a store read of its purchase that saw
    /// it as `readRevoked`: the entry holds a revocation the read did not
    /// carry. StoreKit never takes a refund back, so such a read came before
    /// the refund, and a send or admission built from it would downgrade the
    /// entry.
    func isNewerThanStoreRead(revoked readRevoked: Bool) -> Bool {
        isRevoked && !readRevoked
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
            featureUseDeclarations: featureUseDeclarations,
            storeKitEnvironment: storeKitEnvironment,
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
            featureUseDeclarations: featureUseDeclarations,
            storeKitEnvironment: storeKitEnvironment,
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
/// state. The file uses iOS data protection when available. A corrupt file is
/// set aside and an empty outbox takes its place (see `PurchaseStoreFile`).
final class TransactionEvidenceStore: TransactionEvidenceStoreProtocol {
    private let file: PurchaseStoreFile
    private var fileURL: URL { file.url }

    init(
        customStoragePath: URL? = nil,
        scope: PurchaseStorageScope = .testFixture,
        logger: NuxieLogger = .shared
    ) {
        let base = scope.storageDirectory(customStoragePath: customStoragePath)
        file = PurchaseStoreFile(
            url: base.appendingPathComponent("transaction-evidence.json"),
            storeName: "TransactionEvidenceStore",
            logger: logger
        )
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
    }

    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> {
        file.read { data in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // One current-format entry that cannot be read makes the whole
            // file corrupt, as a malformed file is: it is set aside whole.
            let decoded = try decoder.decode([String: DecodedEntry].self, from: data)
            let entries = decoded.compactMapValues(\.entry)
            let dropped = decoded.count - entries.count
            if dropped > 0 {
                LogWarning(
                    "TransactionEvidenceStore: Dropped \(dropped, privacy: .publicValue) entries in a previous format"
                )
            }
            return entries
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

/// One stored entry, or nothing for an entry in a previous SDK's format,
/// which is recognised by having no admission id. That is pre-GA local
/// state, dropped rather than read: StoreKit redelivers unfinished
/// transactions, which then go through the outbox normally. A
/// current-format entry that cannot be read makes the whole file corrupt.
private struct DecodedEntry: Decodable {
    let entry: StoredTransactionEvidence?

    private enum FormatKey: String, CodingKey {
        case admissionId
    }

    init(from decoder: Decoder) throws {
        let format = try decoder.container(keyedBy: FormatKey.self)
        guard format.contains(.admissionId) else {
            entry = nil
            return
        }
        do {
            entry = try StoredTransactionEvidence(from: decoder)
        } catch let error as DecodingError {
            throw StoreEntryDecodingFailure(
                entryId: decoder.codingPath.last?.stringValue ?? "unknown",
                field: error.failingKeyPath.dropFirst()
                    .map(\.stringValue).joined(separator: ".")
            )
        }
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
