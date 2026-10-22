import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// The outbox reads only entries in its own format.
final class PurchaseOutboxEntryTests: XCTestCase {
    func testFeatureUseDeclarationSurvivesBookkeepingAndOlderEvidenceStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("consume-kind-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransactionEvidenceStore(customStoragePath: root, scope: .testFixture)
        let admitted = StoredTransactionEvidence(
            transactionJws: "signed-jws", transactionId: "transaction", originalTransactionId: "original",
            productId: "product", distinctId: "customer", recordedAt: Date(timeIntervalSince1970: 100),
            isRevoked: false, customerKind: .identified
        )
        var consumed = admitted
        consumed.featureUseCustomerKinds = ["purchase-use": .anonymous]
        let written = consumed.admitted(over: admitted)
        XCTAssertEqual(written.admissionId, admitted.admissionId, "Consume admission must not readmit /purchase")
        XCTAssertEqual(written.customerKind, .identified)
        XCTAssertTrue(store.save(["transaction": written.replacingAfterFailedSend(at: Date())]))
        let loaded = try XCTUnwrap(store.load().readableValue?["transaction"])
        XCTAssertEqual(loaded.featureUseCustomerKinds, ["purchase-use": .anonymous])
        XCTAssertEqual(loaded.replacing(answeredAt: Date()).featureUseCustomerKinds, loaded.featureUseCustomerKinds)

        // The current purchase outbox format predates consume declarations.
        // Its existing rows must still load with no per-consume declarations.
        let file = PurchaseStorageScope.testFixture.storageDirectory(customStoragePath: root)
            .appendingPathComponent("transaction-evidence.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var legacy = try XCTUnwrap(object["transaction"] as? [String: Any])
        legacy.removeValue(forKey: "featureUseCustomerKinds")
        object["transaction"] = legacy
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let old = try XCTUnwrap(store.load().readableValue?["transaction"])
        XCTAssertNil(old.featureUseCustomerKinds)
        XCTAssertEqual(old.customerKind, .identified)
        XCTAssertEqual(old.admissionId, admitted.admissionId)
    }

    /// An entry in the previous SDK's format (its answer under
    /// `backendSyncedAt`, with no reason, customer kind, attempt count or
    /// admission) is dropped when the outbox is read: pre-GA local state,
    /// with no compatibility handling. The rest of the outbox still loads,
    /// and the next write leaves the old entry out.
    func testEntryInThePreviousFormatIsDroppedWhenTheOutboxIsRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-format-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = TransactionEvidenceStore(customStoragePath: root, scope: .testFixture)
        let current = StoredTransactionEvidence(
            transactionJws: "current-jws",
            transactionId: "current-transaction",
            originalTransactionId: "current-original",
            productId: "product",
            distinctId: "customer",
            recordedAt: Date(timeIntervalSince1970: 1_000_000_000),
            isRevoked: false
        )
        XCTAssertTrue(store.save([current.transactionId: current]))

        // Add an entry as the previous SDK wrote it.
        let file = PurchaseStorageScope.testFixture
            .storageDirectory(customStoragePath: root)
            .appendingPathComponent("transaction-evidence.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var previous = try XCTUnwrap(object[current.transactionId] as? [String: Any])
        previous["transactionId"] = "previous-transaction"
        previous["transactionJws"] = ""
        previous["backendSyncedAt"] = "2001-09-09T01:46:40Z"
        for key in ["reason", "customerKind", "sendAttempts", "admissionId", "retryDueAt"] {
            previous.removeValue(forKey: key)
        }
        object["previous-transaction"] = previous
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let loaded = try XCTUnwrap(store.load().valueTreatingAbsentAsEmpty([:]))
        XCTAssertEqual(Set(loaded.keys), ["current-transaction"])
        XCTAssertEqual(loaded["current-transaction"], current)

        XCTAssertTrue(store.save(loaded))
        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(Set(rewritten.keys), ["current-transaction"])
    }

    /// Only an entry with no admission id is from the previous SDK. A
    /// current-format entry that cannot be read (here a malformed admission
    /// id) makes the outbox file corrupt, as a malformed file is: it is
    /// renamed aside and never read again, an empty outbox takes its place,
    /// and the outbox is on. StoreKit's unfinished transaction is then saved,
    /// sent and finished as usual.
    func testCorruptOutboxIsSetAsideAndAnUnfinishedPurchaseIsSavedSentAndFinished() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-format-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = TransactionEvidenceStore(customStoragePath: root, scope: .testFixture)
        let valid = StoredTransactionEvidence(
            transactionJws: "valid-jws",
            transactionId: "valid-transaction",
            originalTransactionId: "valid-original",
            productId: "product",
            distinctId: "customer",
            recordedAt: Date(timeIntervalSince1970: 1_000_000_000),
            isRevoked: false
        )
        XCTAssertTrue(store.save([valid.transactionId: valid]))

        let file = PurchaseStorageScope.testFixture
            .storageDirectory(customStoragePath: root)
            .appendingPathComponent("transaction-evidence.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var broken = try XCTUnwrap(object[valid.transactionId] as? [String: Any])
        broken["transactionId"] = "broken-transaction"
        broken["admissionId"] = "not-a-uuid"
        object["broken-transaction"] = broken
        let contents = try JSONSerialization.data(withJSONObject: object)
        try contents.write(to: file)

        let finished = OutboxFinishRecorder()
        let harness = makeObserver(store: store, unfinished: [StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: "unfinished-transaction",
                originalTransactionId: "unfinished-original",
                productId: "product",
                appAccountToken: PurchaseStorageScope.testFixture
                    .appAccountToken(distinctId: "customer"),
                isRevoked: false,
                isUpgraded: false,
                finish: { finished.record() }
            ),
            jwsRepresentation: "unfinished-jws"
        )])
        await harness.observer.retryStoredEvidence()

        let directory = file.deletingLastPathComponent()
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("transaction-evidence.unreadable-") }
        XCTAssertEqual(quarantined.count, 1, "the corrupt outbox is set aside")
        let aside = try XCTUnwrap(quarantined.first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(aside)), contents)
        let saved = try XCTUnwrap(store.load().readableValue)
        XCTAssertEqual(Set(saved.keys), ["unfinished-transaction"], "an empty outbox took its place")
        XCTAssertNotNil(saved["unfinished-transaction"]?.answeredAt, "the purchase is saved and sent")
        XCTAssertEqual(saved["unfinished-transaction"]?.finishRequired, false)
        XCTAssertEqual(finished.count, 1, "and finished")
        XCTAssertEqual(harness.api.recordedCustomers, ["customer"])
    }

    /// An outbox that cannot be read right now (its permissions deny reading,
    /// as data protection does before the first unlock) is not corrupt. It
    /// is not renamed, and the outbox is off for the session: a purchase is
    /// sent once and nothing is written, even once the file can be read
    /// again. The next launch reads it.
    func testOutboxThatCannotBeReadNowStaysOffForTheSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-locked-\(UUID().uuidString)")
        let file = PurchaseStorageScope.testFixture
            .storageDirectory(customStoragePath: root)
            .appendingPathComponent("transaction-evidence.json")
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = TransactionEvidenceStore(customStoragePath: root, scope: .testFixture)
        let kept = StoredTransactionEvidence(
            transactionJws: "kept-jws",
            transactionId: "kept-transaction",
            originalTransactionId: "kept-original",
            productId: "product",
            distinctId: "customer",
            recordedAt: Date(timeIntervalSince1970: 1_000_000_000),
            isRevoked: false,
            answeredAt: Date(timeIntervalSince1970: 1_000_000_100)
        )
        XCTAssertTrue(store.save([kept.transactionId: kept]))
        let contents = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        let harness = makeObserver(store: store, unfinished: [])
        await harness.observer.retryStoredEvidence()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let delivery = await harness.observer.commit(.verified(
            VerifiedPurchaseEvidence(
                transactionJws: "new-jws",
                transactionId: "new-transaction",
                originalTransactionId: "new-original",
                productId: "product",
                requester: .named("customer"),
                resolvesPendingPurchase: false,
                allowsDurableCheckoutAuthority: false,
                requiresAuthorityResolution: false
            ),
            source: .transactionStream
        ))
        XCTAssertTrue(delivery.committed)
        _ = await delivery.syncTask?.value

        XCTAssertEqual(harness.api.recordedCustomers, ["customer"], "the purchase is sent once")
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertFalse(names.contains { $0.contains(".unreadable-") }, "nothing is renamed")
        XCTAssertEqual(try Data(contentsOf: file), contents, "nothing is written for the rest of the session")

        // The next launch reads the store again.
        XCTAssertEqual(
            TransactionEvidenceStore(customStoragePath: root, scope: .testFixture).load().readableValue,
            [kept.transactionId: kept]
        )
    }

    private struct ObserverHarness {
        let observer: TransactionObserver
        let api: RecoverySyncAPI
    }

    private func makeObserver(
        store: TransactionEvidenceStore,
        unfinished: [StoreTransactionRecoveryItem]
    ) -> ObserverHarness {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let api = RecoverySyncAPI(succeeds: true)
        let settings = NuxieRuntimeSettings(configuration: NuxieConfiguration(apiKey: "outbox-store"))
        let sink = RecoveryEventSink()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: identity,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: 300
        )
        let box = LateBound<TransactionService>()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: sink,
            transactionServiceProvider: { box.get() },
            evidenceStore: store,
            dateProvider: mocks.dateProvider,
            unfinishedRecoveryTransactions: { unfinished },
            currentEntitlementRecoveryTransactions: { [] }
        )
        box.set(TransactionService(
            productService: mocks.productService,
            transactionObserver: observer,
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            accountOwnershipStore: InMemoryPurchaseAccountOwnershipStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: sink,
            purchaseStorageScope: .testFixture,
            identityService: identity,
            featureService: features
        ))
        addTeardownBlock { await observer.stopListening() }
        return ObserverHarness(observer: observer, api: api)
    }
}

private final class OutboxFinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}
