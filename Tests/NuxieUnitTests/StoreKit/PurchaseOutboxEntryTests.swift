import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Outbox entries written by the previous SDK keep what they knew.
final class PurchaseOutboxEntryTests: XCTestCase {
    /// The previous SDK stored the server's acknowledgement as
    /// `backendSyncedAt` and dropped the signed receipt once answered. Such an
    /// entry reads as answered, so recovery finishes its bookkeeping and
    /// retires it without sending anything.
    func testEntryTheServerAnsweredBeforeTheOutboxReadsAsAnsweredAndRetires() async throws {
        let mocks = MockFactory.shared
        // Whole seconds: the store writes ISO 8601 dates.
        let answeredAt = Date(
            timeIntervalSince1970: (mocks.dateProvider.now().timeIntervalSince1970 - 60).rounded(.down)
        )
        let legacy = try Self.legacyEntry(answeredAt: answeredAt, recordedAt: answeredAt)

        XCTAssertEqual(legacy.answeredAt, answeredAt)
        XCTAssertFalse(legacy.isUnsent)

        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = InMemoryTransactionEvidenceStore()
        XCTAssertTrue(store.save([legacy.transactionId: legacy]))
        let api = RecoverySyncAPI(succeeds: true)
        let observer = TransactionObserver(
            api: api,
            features: FeatureService(
                api: mocks.nuxieApi,
                identity: identity,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: FeatureInfo(),
                cacheTTL: 300
            ),
            identity: identity,
            settings: NuxieRuntimeSettings(configuration: NuxieConfiguration(apiKey: "legacy-entry")),
            eventSink: RecoveryEventSink(),
            transactionServiceProvider: { fatalError("unused") },
            evidenceStore: store,
            dateProvider: mocks.dateProvider
        )
        addTeardownBlock { await observer.stopListening() }

        await observer.retryStoredEvidence()

        XCTAssertNil(store.load().valueTreatingAbsentAsEmpty([:])?[legacy.transactionId])
        XCTAssertTrue(api.recordedCustomers.isEmpty, "an answered entry is never sent again")
    }

    /// An entry as the previous SDK wrote it: the acknowledgement under
    /// `backendSyncedAt`, no outbox fields, and the receipt already dropped.
    private static func legacyEntry(answeredAt: Date, recordedAt: Date) throws -> StoredTransactionEvidence {
        let current = StoredTransactionEvidence(
            transactionJws: "",
            transactionId: "legacy-transaction",
            originalTransactionId: "legacy-original",
            productId: "legacy-product",
            distinctId: "customer",
            recordedAt: recordedAt,
            isRevoked: false,
            answeredAt: answeredAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(current)) as? [String: Any]
        )
        object["backendSyncedAt"] = object.removeValue(forKey: "answeredAt")
        for key in ["reason", "customerKind", "sendAttempts", "appAccountToken"] {
            object.removeValue(forKey: key)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            StoredTransactionEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
