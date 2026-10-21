import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// A Restore moves the purchase (UNIV-5196). The server lets only a Restore or
/// the customer's own purchase move a purchase another customer owns, and only
/// to a customer who signed in. The SDK therefore says why it sends each
/// purchase and whether its customer signed in, never grants access the server
/// has not given for someone else's purchase, stops granting from a purchase
/// the server refuses, and reports a Restore only once the server grants it.
final class PurchaseOwnershipClaimTests: XCTestCase {
    private let scope = PurchaseStorageScope.testFixture
    private let storeProductId = "claim-store-product"

    // MARK: - Wire

    func testPurchaseRequestCarriesReasonAndCustomerKind() throws {
        let identified = try encodedObject(PurchaseRequest(
            transactionJwt: "signed-jws",
            distinctId: "customer",
            reason: .restore,
            customerKind: .identified
        ))
        XCTAssertEqual(identified["type"] as? String, "appstore")
        XCTAssertEqual(identified["transaction_jwt"] as? String, "signed-jws")
        XCTAssertEqual(identified["distinct_id"] as? String, "customer")
        XCTAssertEqual(identified["reason"] as? String, "restore")
        XCTAssertEqual(identified["customer_kind"] as? String, "identified")

        let anonymous = try encodedObject(PurchaseRequest(
            transactionJwt: "signed-jws",
            distinctId: "customer",
            reason: .sync,
            customerKind: .anonymous
        ))
        XCTAssertEqual(anonymous["reason"] as? String, "sync")
        XCTAssertEqual(anonymous["customer_kind"] as? String, "anonymous")
    }

    func testDepartedCustomerWithNoRecordedKindIsSentAsIdentified() async {
        let harness = await makeHarness(customer: "current-customer")
        let departed = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "departed-jws",
            transactionId: "departed-transaction",
            originalTransactionId: "departed-original",
            productId: storeProductId,
            distinctId: "departed-customer",
            recordedAt: Date(),
            isRevoked: false,
            appAccountToken: token("departed-customer")
        )
        _ = harness.store.save([departed.transactionId: departed])

        await harness.observer.retryStoredEvidence()

        XCTAssertEqual(harness.api.requests, [PurchaseRequest(
            transactionJwt: "departed-jws",
            distinctId: "departed-customer",
            reason: .sync,
            customerKind: .identified
        )])
    }

    // MARK: - Reasons

    func testCheckoutSendsItsReceiptAsTheSignedInCustomersPurchase() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "checkout-jws",
            transactionId: "checkout-transaction",
            originalTransactionId: "checkout-original",
            productId: storeProductId
        )

        let result = try await harness.service.purchase(product())
        let synced = await result.syncTask?.value

        XCTAssertEqual(synced, true)
        XCTAssertEqual(harness.api.requests, [PurchaseRequest(
            transactionJwt: "checkout-jws",
            distinctId: "buyer",
            reason: .purchase,
            customerKind: .identified
        )])
    }

    func testAnonymousCheckoutSaysItsCustomerIsAnonymous() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.identity.reset(keepAnonymousId: true)
        let anonymousId = harness.identity.getDistinctId()
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "anonymous-jws",
            transactionId: "anonymous-transaction",
            originalTransactionId: "anonymous-original",
            productId: storeProductId
        )

        let result = try await harness.service.purchase(product())
        _ = await result.syncTask?.value

        XCTAssertEqual(harness.api.requests, [PurchaseRequest(
            transactionJwt: "anonymous-jws",
            distinctId: anonymousId,
            reason: .purchase,
            customerKind: .anonymous
        )])
    }

    func testAlreadyOwnedProductIsSentAsThePurchaseAndOtherEntitlementsAsSyncs() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.entitlements.set([
            entitlement("owned", productId: storeProductId, token: token("buyer")),
            entitlement("other", productId: "other-store-product", token: token("buyer")),
        ])
        harness.adapter.configureAlreadyOwned()

        _ = try await harness.service.purchase(product())

        let reasons = Dictionary(uniqueKeysWithValues: harness.api.requests.map {
            ($0.transactionJwt, $0.reason)
        })
        XCTAssertEqual(reasons, ["owned-jws": .purchase, "other-jws": .sync])
        XCTAssertEqual(harness.api.requests.count, 2)
        XCTAssertTrue(harness.api.requests.allSatisfy { $0.customerKind == .identified })
    }

    func testRestoreSendsEveryEntitlementAsTheCustomersRestore() async throws {
        let harness = await makeHarness(customer: "restorer")
        harness.entitlements.set([
            entitlement("outside", productId: storeProductId, token: nil),
            entitlement("previous", productId: "other-store-product", token: token("previous-owner")),
        ])
        harness.adapter.restoreResult = .restored

        let result = try await harness.service.restore()

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(
            Set(harness.api.requests.map { "\($0.transactionJwt)|\($0.distinctId)|\($0.reason.rawValue)|\($0.customerKind.rawValue)" }),
            ["outside-jws|restorer|restore|identified", "previous-jws|restorer|restore|identified"]
        )
    }

    func testStoreUpdatesAndLaunchScansSendSyncs() async {
        let harness = await makeHarness(customer: "customer")
        let update = entitlement("update", productId: storeProductId, token: token("customer"))
        let streamed = await harness.observer.handleVerifiedTransaction(
            update.update,
            jwsRepresentation: update.jwsRepresentation,
            source: .transactionStream
        )
        _ = await streamed.syncTask?.value

        harness.entitlements.set([
            entitlement("scanned", productId: "other-store-product", token: nil),
        ])
        await harness.observer.retryAfterProfileReady()

        XCTAssertEqual(harness.api.requests.map(\.transactionJwt), ["update-jws", "scanned-jws"])
        XCTAssertEqual(harness.api.requests.map(\.reason), [.sync, .sync])
        XCTAssertEqual(harness.api.requests.map(\.customerKind), [.identified, .identified])
    }

    func testRetriedPurchaseKeepsItsReasonAndItsCustomersKindAfterReset() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.api.answer(.fail)
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "retry-jws",
            transactionId: "retry-transaction",
            originalTransactionId: "retry-original",
            productId: storeProductId
        )
        let result = try await harness.service.purchase(product())
        let firstSync = await result.syncTask?.value
        XCTAssertEqual(firstSync, false)

        harness.identity.reset(keepAnonymousId: false)
        harness.api.answer(.accept)
        await harness.observer.retryStoredEvidence()

        XCTAssertEqual(harness.api.requests.count, 2)
        XCTAssertEqual(harness.api.requests.last, PurchaseRequest(
            transactionJwt: "retry-jws",
            distinctId: "buyer",
            reason: .purchase,
            customerKind: .identified
        ))
    }

    // MARK: - Optimistic access

    func testPassiveScanDoesNotProjectAnotherCustomersPurchase() async {
        let harness = await makeHarness(customer: "customer-b")
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.entitlements.set([
            entitlement("other-customer", productId: storeProductId, token: token("customer-a")),
            entitlement("outside-nuxie", productId: "other-store-product", token: nil),
        ])

        let scan = Task { await harness.observer.retryAfterProfileReady() }
        await gate.waitForArrival(count: 2)

        let visible = await harness.visiblePremium()
        XCTAssertEqual(
            visible?.allowed, false,
            "a purchase whose account token is not this customer's waits for the server"
        )
        await gate.open()
        await scan.value
    }

    func testBuyersOwnPurchaseUnlocksBeforeTheServerAnswers() async throws {
        let harness = await makeHarness(customer: "buyer")
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "own-jws",
            transactionId: "own-transaction",
            originalTransactionId: "own-original",
            productId: storeProductId
        )

        let result = try await harness.service.purchase(product())
        await gate.waitForArrival()

        let visible = await harness.visiblePremium()
        XCTAssertEqual(visible?.allowed, true)
        await gate.open()
        _ = await result.syncTask?.value
    }

    func testConflictStopsThePurchaseGrantingAtOnce() async throws {
        try await assertRefusalStopsGranting(status: 409)
    }

    func testInvalidPurchaseStopsThePurchaseGrantingAtOnce() async throws {
        try await assertRefusalStopsGranting(status: 400)
    }

    private func assertRefusalStopsGranting(
        status: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let harness = await makeHarness(customer: "previous-owner")
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.api.answer(.refuse(status))
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "moved-jws",
            transactionId: "moved-transaction",
            originalTransactionId: "moved-original",
            productId: storeProductId
        )

        let result = try await harness.service.purchase(product())
        await gate.waitForArrival()
        let beforeAnswer = await harness.visiblePremium()
        XCTAssertEqual(beforeAnswer?.allowed, true, file: file, line: line)
        await gate.open()
        let synced = await result.syncTask?.value

        XCTAssertEqual(synced, false, file: file, line: line)
        let afterAnswer = await harness.visiblePremium()
        XCTAssertNotEqual(afterAnswer?.allowed, true, "a refusal drops the early unlock at once", file: file, line: line)
        let entry = harness.store.load().valueTreatingAbsentAsEmpty([:])?["moved-transaction"]
        XCTAssertFalse(entry?.isUnsent ?? false, "a refusal answers the send", file: file, line: line)
        XCTAssertEqual(harness.profileRefreshes.requests, ["previous-owner"], "the profile decides access after the answer", file: file, line: line)

        // An answered send is never sent again on its own.
        let sent = harness.api.requests.count
        await harness.observer.retryStoredEvidence()
        XCTAssertEqual(harness.api.requests.count, sent, file: file, line: line)
    }

    // MARK: - Outbox

    func testAcceptedSendClearsTheEntryAndRefreshesTheProfile() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "accepted-jws",
            transactionId: "accepted-transaction",
            originalTransactionId: "accepted-original",
            productId: storeProductId
        )

        let result = try await harness.service.purchase(product())
        let synced = await result.syncTask?.value

        XCTAssertEqual(synced, true)
        let entry = harness.store.load().valueTreatingAbsentAsEmpty([:])?["accepted-transaction"]
        XCTAssertFalse(entry?.isUnsent ?? false)
        XCTAssertEqual(harness.profileRefreshes.requests, ["buyer"])
    }

    // MARK: - A full disk

    /// When the outbox cannot save, it is off for the session. The purchase
    /// is sent once and the refreshed profile gives access, with no early
    /// unlock, no timer and its transaction left unfinished. The next launch
    /// finds it unfinished, saves its entry, sends it and finishes it, and
    /// does not report the checkout's completion a second time.
    func testFullDiskSendsThePurchaseOnceAndTheNextLaunchSavesAndFinishesIt() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.store.refusesWrites = true
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "full-disk-jws",
            transactionId: "full-disk-transaction",
            originalTransactionId: "full-disk-original",
            productId: storeProductId
        )

        let result = try await harness.service.purchase(product())
        await gate.waitForArrival()
        let beforeAnswer = await harness.visiblePremium()
        XCTAssertNotEqual(beforeAnswer?.allowed, true, "nothing unlocks early while the outbox is off")
        await gate.open()
        let synced = await result.syncTask?.value

        XCTAssertEqual(synced, true)
        XCTAssertEqual(harness.api.requests.map(\.transactionJwt), ["full-disk-jws"])
        XCTAssertEqual(harness.profileRefreshes.requests, ["buyer"])
        let access = await harness.visiblePremium()
        XCTAssertEqual(access?.allowed, true, "the refreshed profile gives access")
        XCTAssertEqual(harness.adapter.finishCallCount, 0, "the transaction is left unfinished")
        let timerSet = await harness.observer.hasScheduledOutboxRetry
        XCTAssertFalse(timerSet)
        XCTAssertEqual(harness.events(named: SystemEventNames.purchaseCompleted), 1)
        XCTAssertEqual(harness.store.load().valueTreatingAbsentAsEmpty([:])?.isEmpty, true)

        // The next launch, with room on the disk: StoreKit still holds the
        // transaction unfinished.
        await harness.observer.stopListening()
        let finished = FinishRecorder()
        let relaunchedStore = WriteSwitchEvidenceStore()
        let box = LateBound<TransactionService>()
        let relaunched = TransactionObserver(
            api: harness.api,
            features: harness.features,
            identity: harness.identity,
            settings: harness.settings,
            eventSink: harness.sink,
            transactionServiceProvider: { box.get() },
            evidenceStore: relaunchedStore,
            purchaseStorageScope: scope,
            dateProvider: MockFactory.shared.dateProvider,
            unfinishedRecoveryTransactions: { [scope] in
                [StoreTransactionRecoveryItem(update: VerifiedStoreTransactionUpdate(
                    transactionId: "full-disk-transaction",
                    originalTransactionId: "full-disk-original",
                    productId: "claim-store-product",
                    appAccountToken: scope.appAccountToken(distinctId: "buyer"),
                    isRevoked: false,
                    isUpgraded: false,
                    finish: { finished.record() }
                ), jwsRepresentation: "full-disk-jws")]
            },
            currentEntitlementRecoveryTransactions: { [] },
            refreshProfile: { distinctId in harness.profileRefreshes.record(distinctId) }
        )
        box.set(TransactionService(
            productService: MockFactory.shared.productService,
            transactionObserver: relaunched,
            pendingPurchaseStore: harness.pending,
            accountOwnershipStore: harness.ownership,
            dateProvider: MockFactory.shared.dateProvider,
            settings: harness.settings,
            eventSink: harness.sink,
            purchaseStorageScope: scope,
            identityService: harness.identity,
            featureService: harness.features
        ))
        addTeardownBlock { await relaunched.stopListening() }
        await relaunched.retryStoredEvidence()

        let saved = relaunchedStore.load().valueTreatingAbsentAsEmpty([:])?["full-disk-transaction"]
        XCTAssertNotNil(saved?.answeredAt, "the next launch saves the entry and sends it")
        XCTAssertEqual(harness.api.requests.map(\.transactionJwt), ["full-disk-jws", "full-disk-jws"])
        XCTAssertEqual(finished.count, 1, "and finishes the transaction")
        XCTAssertEqual(
            harness.events(named: SystemEventNames.purchaseCompleted), 1,
            "the checkout's completion is reported once"
        )
    }

    /// A checkout whose binding cannot be saved turns the outbox off for the
    /// session and carries on with its in-memory context: it still completes
    /// and sends its purchase, and saves and finishes nothing.
    func testCheckoutWhoseBindingCannotBeSavedCarriesOnWithTheOutboxOff() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.pending.refusesWrites = true
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "unbound-jws",
            transactionId: "unbound-transaction",
            originalTransactionId: "unbound-original",
            productId: storeProductId
        )

        let result = try await harness.service.purchase(product())
        let synced = await result.syncTask?.value

        XCTAssertEqual(synced, true)
        XCTAssertEqual(harness.api.requests.map(\.transactionJwt), ["unbound-jws"])
        XCTAssertEqual(harness.events(named: SystemEventNames.purchaseCompleted), 1, "the checkout still completes")
        XCTAssertEqual(harness.adapter.finishCallCount, 0, "the transaction is left unfinished")
        XCTAssertEqual(harness.store.load().valueTreatingAbsentAsEmpty([:])?.isEmpty, true, "nothing is saved while off")
        let timerSet = await harness.observer.hasScheduledOutboxRetry
        XCTAssertFalse(timerSet)
    }

    /// While the outbox is off, no timer pass sends anything.
    func testNoTimerPassSendsWhileTheOutboxIsOff() async throws {
        let harness = await makeHarness(customer: "buyer")
        let overdue = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "overdue-jws",
            transactionId: "overdue-transaction",
            originalTransactionId: "overdue-original",
            productId: storeProductId,
            distinctId: "buyer",
            recordedAt: MockFactory.shared.dateProvider.now(),
            isRevoked: false,
            reason: .purchase,
            sendAttempts: 1,
            retryDueAt: MockFactory.shared.dateProvider.now().addingTimeInterval(-1)
        )
        _ = harness.store.save([overdue.transactionId: overdue])
        harness.store.refusesWrites = true
        harness.api.answer(.fail)

        // The send fails and its attempt cannot be saved: the outbox is off.
        await harness.observer.retryDueOutboxEntries()
        XCTAssertEqual(harness.api.requests.count, 1)
        await harness.observer.retryDueOutboxEntries()
        await harness.observer.retryDueOutboxEntries()

        XCTAssertEqual(harness.api.requests.count, 1, "no timer pass sends while the outbox is off")
        let timerSet = await harness.observer.hasScheduledOutboxRetry
        XCTAssertFalse(timerSet)
    }

    func testFailedSendStaysQueuedWithItsRecordedFieldsAndBacksOff() async throws {
        let harness = await makeHarness(customer: "buyer")
        harness.api.answer(.fail)
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "queued-jws",
            transactionId: "queued-transaction",
            originalTransactionId: "queued-original",
            productId: storeProductId
        )
        let result = try await harness.service.purchase(product())
        _ = await result.syncTask?.value

        let queued = try XCTUnwrap(harness.store.load().valueTreatingAbsentAsEmpty([:])?["queued-transaction"])
        XCTAssertTrue(queued.isUnsent)
        XCTAssertEqual(queued.reason, .purchase)
        XCTAssertEqual(queued.customerKind, .identified)
        XCTAssertEqual(queued.distinctId, "buyer")
        XCTAssertEqual(queued.sendAttempts, 1)
        XCTAssertTrue(harness.profileRefreshes.requests.isEmpty, "no answer, no refresh")

        // A 5xx is no answer either.
        harness.api.answer(.unavailable)
        await harness.observer.retryStoredEvidence()
        let retried = try XCTUnwrap(harness.store.load().valueTreatingAbsentAsEmpty([:])?["queued-transaction"])
        XCTAssertTrue(retried.isUnsent)
        XCTAssertEqual(retried.sendAttempts, 2)
        XCTAssertEqual(harness.api.requests.map(\.reason), [.purchase, .purchase])

        harness.api.answer(.accept)
        await harness.observer.retryStoredEvidence()
        XCTAssertNotNil(harness.store.load().valueTreatingAbsentAsEmpty([:])?["queued-transaction"]?.answeredAt)
    }

    func testOutboxRetryBackoffGrowsAndIsCapped() {
        XCTAssertEqual(TransactionObserver.outboxRetryDelay(afterAttempts: 1), 30)
        XCTAssertEqual(TransactionObserver.outboxRetryDelay(afterAttempts: 2), 60)
        XCTAssertEqual(TransactionObserver.outboxRetryDelay(afterAttempts: 3), 120)
        XCTAssertEqual(TransactionObserver.outboxRetryDelay(afterAttempts: 8), 3600)
        XCTAssertEqual(TransactionObserver.outboxRetryDelay(afterAttempts: 40), 3600)
    }

    func testRefusalLetsTheRefreshedProfileEndAccessAnEarlierServerGrantCached() async throws {
        let profile = MockProfileService()
        profile.setProfileResponse(TestJourneyProfile.response(features: [premiumFeature]))
        let harness = await makeHarness(customer: "previous-owner", profile: profile)
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "granted-jws",
            transactionId: "granted-transaction",
            originalTransactionId: "granted-original",
            productId: storeProductId
        )
        let result = try await harness.service.purchase(product())
        _ = await result.syncTask?.value
        let granted = await harness.features.getCached(featureId: "premium", entityId: nil)
        XCTAssertEqual(granted?.allowed, true)

        // Someone else took the purchase: the server's profile no longer
        // grants it, and this device's next send is refused.
        profile.setProfileResponse(TestJourneyProfile.response())
        harness.api.answer(.refuse(409))
        let renewal = entitlement("renewal", productId: storeProductId, token: token("previous-owner"),
            transactionId: "renewal-transaction", originalTransactionId: "granted-original")
        let refused = await harness.observer.handleVerifiedTransaction(
            renewal.update,
            jwsRepresentation: renewal.jwsRepresentation,
            source: .transactionStream
        )
        _ = await refused.syncTask?.value

        let cached = await harness.features.getCached(featureId: "premium", entityId: nil)
        XCTAssertNotEqual(cached?.allowed, true, "the earlier answer's Features step aside for the refreshed profile")
        let visible = await harness.visiblePremium()
        XCTAssertNotEqual(visible?.allowed, true)
    }

    func testAPurchaseAnswerHoldsOnlyUntilTheProfileRequestedAfterItLands() async throws {
        let profile = MockProfileService()
        profile.setProfileResponse(TestJourneyProfile.response(features: [premiumFeature]))
        let harness = await makeHarness(customer: "buyer", profile: profile)
        _ = try await profile.refetchProfile(distinctId: "buyer")
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "answer-jws",
            transactionId: "answer-transaction",
            originalTransactionId: "answer-original",
            productId: storeProductId
        )
        // The server's profile after the purchase says the customer holds no
        // premium (for instance it was refunded at once); the profile wins.
        profile.setProfileResponse(TestJourneyProfile.response())
        let result = try await harness.service.purchase(product())
        _ = await result.syncTask?.value

        let access = await harness.features.getCached(featureId: "premium", entityId: nil)
        XCTAssertNotEqual(access?.allowed, true)
    }

    // MARK: - Restore outcome

    func testRestoreRefusedByTheServerIsNotRestored() async {
        let harness = await makeHarness(customer: "restorer")
        harness.api.answer(.refuse(409))
        harness.entitlements.set([
            entitlement("signed-in-owners", productId: storeProductId, token: token("signed-in-owner")),
        ])
        harness.adapter.restoreResult = .restored

        do {
            _ = try await harness.service.restore()
            XCTFail("A refused Restore must not report restored")
        } catch StoreKitError.restoreFailed(let underlying) {
            XCTAssertEqual(underlying as? RestoreClaimError, .ownedByAnotherAccount)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(harness.events(named: SystemEventNames.restoreCompleted), 0)
        XCTAssertEqual(harness.events(named: SystemEventNames.restoreFailed), 1)
        let access = await harness.features.getCached(featureId: "premium", entityId: nil)
        XCTAssertNotEqual(access?.allowed, true)
    }

    func testRestoreWithoutAServerAnswerIsNotRestored() async {
        let harness = await makeHarness(customer: "restorer")
        harness.api.answer(.fail)
        harness.entitlements.set([
            entitlement("offline", productId: storeProductId, token: token("restorer")),
        ])
        harness.adapter.restoreResult = .restored

        do {
            _ = try await harness.service.restore()
            XCTFail("A Restore the server has not granted must not report restored")
        } catch StoreKitError.restoreFailed(let underlying) {
            XCTAssertEqual(underlying as? RestoreClaimError, .unconfirmed)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(harness.events(named: SystemEventNames.restoreCompleted), 0)
    }

    func testRestoreGrantedByTheServerIsRestored() async throws {
        let harness = await makeHarness(customer: "restorer")
        harness.entitlements.set([
            entitlement("granted", productId: storeProductId, token: nil),
        ])
        harness.adapter.restoreResult = .restored

        let result = try await harness.service.restore()

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(harness.events(named: SystemEventNames.restoreCompleted), 1)
        let access = await harness.features.getCached(featureId: "premium", entityId: nil)
        XCTAssertEqual(access?.allowed, true)
    }

    func testRestoreWithNothingToClaimReportsNoPurchases() async throws {
        let harness = await makeHarness(customer: "restorer")
        harness.entitlements.set([])
        harness.adapter.restoreResult = .restored

        let result = try await harness.service.restore()

        XCTAssertEqual(result, .noPurchases)
        XCTAssertEqual(harness.events(named: SystemEventNames.restoreNoPurchases), 1)
        XCTAssertTrue(harness.api.requests.isEmpty)
    }

    func testRestoreClaimsAPurchaseTheServerRefusedAsASync() async throws {
        let harness = await makeHarness(customer: "restorer")
        // The server moves a purchase only for a Restore or purchase.
        harness.api.answer(.refuse(409), for: .sync)
        let item = entitlement("elsewhere", productId: storeProductId, token: token("earlier-owner"))
        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, false)

        harness.entitlements.set([item])
        harness.adapter.restoreResult = .restored
        let result = try await harness.service.restore()

        XCTAssertEqual(result, .restored)
        XCTAssertEqual(harness.api.requests.map(\.reason), [.sync, .restore])
        let access = await harness.features.getCached(featureId: "premium", entityId: nil)
        XCTAssertEqual(access?.allowed, true)
        let entry = harness.store.load().valueTreatingAbsentAsEmpty([:])?["elsewhere-transaction"]
        XCTAssertFalse(entry?.isUnsent ?? false)
    }

    func testRestoreClaimTakesTheOutboxEntryOfAnotherCustomer() async throws {
        let harness = await makeHarness(customer: "restorer")
        let earlier = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "earlier-owner-jws",
            transactionId: "shared-transaction",
            originalTransactionId: "shared-original",
            productId: storeProductId,
            distinctId: "earlier-owner",
            recordedAt: Date(),
            isRevoked: false,
            appAccountToken: token("earlier-owner"),
            reason: .purchase,
            customerKind: .identified
        )
        _ = harness.store.save([earlier.transactionId: earlier])
        harness.entitlements.set([
            entitlement("shared", productId: storeProductId, token: token("earlier-owner"),
                transactionId: "shared-transaction", originalTransactionId: "shared-original"),
        ])
        harness.adapter.restoreResult = .restored

        let result = try await harness.service.restore()
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(harness.api.requests, [PurchaseRequest(
            transactionJwt: "shared-jws",
            distinctId: "restorer",
            reason: .restore,
            customerKind: .identified
        )])

        // One entry per purchase: the Restore claim was the newer intent and
        // took the earlier customer's entry, so once answered nothing is left
        // to send for them. The server decides who owns the purchase.
        XCTAssertNotNil(harness.store.load().valueTreatingAbsentAsEmpty([:])?["shared-transaction"]?.answeredAt)
        await harness.observer.retryStoredEvidence()
        XCTAssertEqual(harness.api.requests.count, 1)
    }

    func testRestoreClaimOnAnotherCustomersEntryStaysQueuedWithoutAnAnswer() async throws {
        let harness = await makeHarness(customer: "restorer")
        let earlier = StoredTransactionEvidence(
            scope: scope,
            transactionJws: "earlier-owner-jws",
            transactionId: "shared-transaction",
            originalTransactionId: "shared-original",
            productId: storeProductId,
            distinctId: "earlier-owner",
            recordedAt: Date(),
            isRevoked: false,
            appAccountToken: token("earlier-owner"),
            reason: .purchase,
            customerKind: .identified
        )
        _ = harness.store.save([earlier.transactionId: earlier])
        harness.entitlements.set([
            entitlement("shared", productId: storeProductId, token: token("earlier-owner"),
                transactionId: "shared-transaction", originalTransactionId: "shared-original"),
        ])
        harness.adapter.restoreResult = .restored
        harness.api.answer(.fail)

        try await assertRestoreGetsNoAnswer(harness)
        try assertRestoreClaimQueued("shared-transaction", jws: "shared-jws", in: harness)

        harness.api.answer(.accept)
        await harness.observer.retryStoredEvidence()
        XCTAssertEqual(harness.api.requests.last, PurchaseRequest(
            transactionJwt: "shared-jws",
            distinctId: "restorer",
            reason: .restore,
            customerKind: .identified
        ))
        XCTAssertNotNil(harness.store.load().valueTreatingAbsentAsEmpty([:])?["shared-transaction"]?.answeredAt)
    }

    func testRestoreClaimOnAnAcceptedPurchaseStaysQueuedWithoutAnAnswer() async throws {
        let harness = await makeHarness(customer: "restorer")
        let item = entitlement("own", productId: storeProductId, token: token("restorer"))
        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, true)
        XCTAssertNotNil(harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]?.answeredAt)

        harness.entitlements.set([item])
        harness.adapter.restoreResult = .restored
        harness.api.answer(.fail)
        try await assertRestoreGetsNoAnswer(harness)
        try assertRestoreClaimQueued("own-transaction", jws: "own-jws", in: harness)

        harness.api.answer(.accept)
        await harness.observer.retryStoredEvidence()
        XCTAssertEqual(harness.api.requests.last?.reason, .restore)
        XCTAssertEqual(harness.api.requests.last?.distinctId, "restorer")
        XCTAssertNotNil(harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]?.answeredAt)
    }

    /// The A to B to A case: another customer's Restore takes the entry, then
    /// the first customer restores and takes it back while their own earlier
    /// send is still in flight. Their claim is a new admission, so the
    /// earlier send's refusal answers only what it sent, and the claim stays
    /// queued for its own answer.
    func testEarlierSendsRefusalDoesNotAnswerTheRestoreClaimThatReplacedIt() async throws {
        let harness = await makeHarness(customer: "restorer")
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.api.answer(.refuse(409), for: .sync)
        harness.api.answer(.fail, for: .restore)
        let item = entitlement("own", productId: storeProductId, token: token("restorer"))
        harness.entitlements.set([item])
        harness.adapter.restoreResult = .restored
        func entry() -> StoredTransactionEvidence? {
            harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]
        }

        // The store update's send for the restorer waits at the server.
        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        await gate.waitForArrival()

        // Another customer on the device restores and takes the entry.
        harness.identity.setDistinctId("other")
        let otherRestore = Task { try await harness.service.restore() }
        await gate.waitForArrival(count: 2)
        XCTAssertEqual(entry()?.distinctId, "other")

        // The restorer comes back and restores, taking the entry back while
        // their first send is still waiting.
        harness.identity.setDistinctId("restorer")
        let restore = Task { try await harness.service.restore() }
        for _ in 0..<500 {
            if entry()?.distinctId == "restorer" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(entry()?.distinctId, "restorer")
        XCTAssertEqual(entry()?.reason, .restore)

        await gate.open()
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, false)
        _ = try? await otherRestore.value
        do {
            _ = try await restore.value
            XCTFail("A Restore the server has not answered must not report restored")
        } catch StoreKitError.restoreFailed(let underlying) {
            XCTAssertEqual(underlying as? RestoreClaimError, .unconfirmed)
        }

        XCTAssertEqual(harness.api.requests.map(\.distinctId), ["restorer", "other", "restorer"])
        try assertRestoreClaimQueued("own-transaction", jws: "own-jws", in: harness)
    }

    /// The A to B to A case once more, with the first customer's earlier send
    /// accepted while their Restore claim waits. The claim's own send fails,
    /// and its retry sends the claim: an acceptance earlier in the session
    /// never clears an entry; only the answer to a send of its own
    /// admission does.
    func testRetryOfARestoreClaimSendsItAfterAnEarlierSendWasAccepted() async throws {
        let harness = await makeHarness(customer: "restorer")
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.api.answer(.accept, for: .sync)
        harness.api.answer(.fail, for: .restore)
        let item = entitlement("own", productId: storeProductId, token: token("restorer"))
        harness.entitlements.set([item])
        harness.adapter.restoreResult = .restored
        func entry() -> StoredTransactionEvidence? {
            harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]
        }

        // The store update's send for the restorer waits at the server.
        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        await gate.waitForArrival()

        // Another customer restores and takes the entry, then the restorer
        // restores and takes it back while their first send still waits.
        harness.identity.setDistinctId("other")
        let otherRestore = Task { try await harness.service.restore() }
        await gate.waitForArrival(count: 2)
        harness.identity.setDistinctId("restorer")
        let restore = Task { try await harness.service.restore() }
        for _ in 0..<500 {
            if entry()?.distinctId == "restorer" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(entry()?.reason, .restore)

        // The first send is accepted; the Restore claim's own send fails.
        await gate.open()
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, true)
        _ = try? await otherRestore.value
        _ = try? await restore.value
        try assertRestoreClaimQueued("own-transaction", jws: "own-jws", in: harness)

        // The retry sends the claim and only its answer clears the entry.
        let sent = harness.api.requests.count
        harness.api.answer(.accept, for: .restore)
        await harness.observer.retryStoredEvidence()
        XCTAssertEqual(harness.api.requests.count, sent + 1, "the retry sends the claim")
        XCTAssertEqual(harness.api.requests.last?.reason, .restore)
        XCTAssertEqual(harness.api.requests.last?.distinctId, "restorer")
        XCTAssertNotNil(entry()?.answeredAt, "only its own answer answers the entry")
    }

    /// Each explicit Restore is a new admission and sends its own claim, even
    /// when the queued claim it finds has the same fields: an earlier
    /// Restore's send never answers it.
    func testEachRestoreSendsItsOwnClaim() async throws {
        let harness = await makeHarness(customer: "restorer")
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.api.answer(.accept, for: .restore)
        harness.entitlements.set([entitlement("own", productId: storeProductId, token: token("restorer"))])
        harness.adapter.restoreResult = .restored

        let first = Task { try await harness.service.restore() }
        await gate.waitForArrival()
        let firstAdmission = harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]?.admissionId
        let second = Task { try await harness.service.restore() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let secondAdmission = harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]?.admissionId
        XCTAssertNotEqual(firstAdmission, secondAdmission, "the second Restore is a new admission")

        await gate.open()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .restored)
        XCTAssertEqual(secondResult, .restored)
        XCTAssertEqual(
            harness.api.requests.filter { $0.reason == .restore }.count, 2,
            "each Restore sends its own claim"
        )
    }

    /// Every write to an entry checks, in the same step, the admission it was
    /// based on. An outbox retry that read the buyer's entry, then waited
    /// while another customer's Restore took the entry, is dropped: it never
    /// merges the old purchase into the Restore's claim.
    func testStaleOutboxRetryNeverOverwritesARestoreClaim() async throws {
        let revisions = ClaimGate()
        let harness = await makeHarness(customer: "buyer", revisionGate: revisions)
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.api.answer(.accept, for: .purchase)
        harness.api.answer(.fail, for: .restore)
        harness.adapter.configureVerifiedPurchase(
            transactionJws: "bought-jws",
            transactionId: "bought-transaction",
            originalTransactionId: "bought-original",
            productId: storeProductId
        )
        harness.entitlements.set([entitlement("bought", productId: storeProductId, token: token("buyer"))])
        harness.adapter.restoreResult = .restored
        func entry() -> StoredTransactionEvidence? {
            harness.store.load().valueTreatingAbsentAsEmpty([:])?["bought-transaction"]
        }

        let purchase = try await harness.service.purchase(product())
        await gate.waitForArrival()
        XCTAssertEqual(entry()?.reason, .purchase)

        // The checkout's send is accepted; applying its answer waits.
        harness.revisionGated?.arm()
        await gate.open()
        await revisions.waitForArrival()

        // Another customer's Restore waits to admit its claim, and then an
        // outbox retry of the buyer's entry waits to write.
        harness.identity.setDistinctId("other")
        let restore = Task { try await harness.service.restore() }
        try await Task.sleep(nanoseconds: 150_000_000)
        let retry = Task { await harness.observer.retryStoredEvidence() }
        try await Task.sleep(nanoseconds: 150_000_000)

        await revisions.open()
        _ = await purchase.syncTask?.value
        _ = try? await restore.value
        await retry.value

        XCTAssertEqual(entry()?.distinctId, "other")
        XCTAssertEqual(entry()?.reason, .restore, "the stale retry never overwrites the claim")
        XCTAssertFalse(
            harness.api.requests.contains { $0.distinctId == "other" && $0.reason == .purchase },
            "nothing sends the old purchase for the restoring customer"
        )
    }

    /// Everything that changes one purchase runs one at a time. While a 200
    /// is being applied (its admission checked and its Features published),
    /// a Restore's new admission for the same purchase waits, so the check
    /// and the publication are never split by it.
    func testRestoreWaitsWhileAnAnswerForThePurchaseIsApplied() async throws {
        let revisions = ClaimGate()
        let harness = await makeHarness(customer: "restorer", revisionGate: revisions)
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.api.answer(.accept)
        let item = entitlement("own", productId: storeProductId, token: token("restorer"))
        harness.entitlements.set([item])
        harness.adapter.restoreResult = .restored
        func entry() -> StoredTransactionEvidence? {
            harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]
        }

        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        await gate.waitForArrival()
        XCTAssertEqual(entry()?.reason, .sync)

        // The first send is accepted; publishing its Features waits.
        harness.revisionGated?.arm()
        await gate.open()
        await revisions.waitForArrival()

        // A Restore starts while that answer is being applied.
        let restore = Task { try await harness.service.restore() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(entry()?.reason, .sync, "no new admission while the answer is applied")
        XCTAssertNil(entry()?.answeredAt)

        await revisions.open()
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, true)
        let restored = try await restore.value
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(harness.api.requests.map(\.reason), [.sync, .restore])
        XCTAssertNotNil(entry()?.answeredAt)
    }

    /// Another customer's Restore replaces the entry while the first
    /// customer's send is in flight, and the first customer comes back. The
    /// old 200 answers an admission its entry no longer holds, so it is
    /// superseded: it asks for the profile again but publishes no Features,
    /// even when that profile fetch fails, and leaves the entry alone.
    func testSupersededAnswerPublishesNoFeatures() async throws {
        let profile = MockProfileService()
        profile.shouldThrow = true
        let harness = await makeHarness(customer: "restorer", profile: profile)
        let gate = ClaimGate()
        harness.api.hold(gate)
        harness.api.answer(.accept, for: .sync)
        harness.api.answer(.fail, for: .restore)
        let item = entitlement("own", productId: storeProductId, token: token("restorer"))
        harness.entitlements.set([item])
        harness.adapter.restoreResult = .restored
        func entry() -> StoredTransactionEvidence? {
            harness.store.load().valueTreatingAbsentAsEmpty([:])?["own-transaction"]
        }

        // The store update's send for the restorer waits at the server.
        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        await gate.waitForArrival()

        // Another customer restores and takes the entry; then the restorer
        // comes back before the first send is answered.
        harness.identity.setDistinctId("other")
        let otherRestore = Task { try await harness.service.restore() }
        await gate.waitForArrival(count: 2)
        XCTAssertEqual(entry()?.distinctId, "other")
        harness.identity.setDistinctId("restorer")

        await gate.open()
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, true)
        _ = try? await otherRestore.value

        let visible = await harness.visiblePremium()
        XCTAssertNotEqual(visible?.allowed, true, "a superseded answer publishes no Features")
        XCTAssertTrue(harness.profileRefreshes.requests.contains("restorer"), "it still asks for the profile")
        XCTAssertEqual(entry()?.distinctId, "other")
        XCTAssertEqual(entry()?.reason, .restore)
        XCTAssertTrue(entry()?.isUnsent ?? false)
    }

    /// A Restore reports owned by another account only when every claim was
    /// refused. With one claim refused and another unanswered, the
    /// unanswered one may be the customer's, so the Restore is unconfirmed
    /// (try again), not a reason to switch accounts.
    func testRestoreWithARefusalAndAnUnansweredClaimIsUnconfirmed() async throws {
        let harness = await makeHarness(customer: "restorer")
        let refused = entitlement("refused", productId: "store-product-refused", token: nil)
        let unanswered = entitlement("unanswered", productId: "store-product-unanswered", token: nil)
        harness.api.answer(.refuse(409), forJwt: refused.jwsRepresentation)
        harness.api.answer(.fail, forJwt: unanswered.jwsRepresentation)
        harness.entitlements.set([refused, unanswered])
        harness.adapter.restoreResult = .restored

        do {
            _ = try await harness.service.restore()
            XCTFail("No claim was accepted")
        } catch StoreKitError.restoreFailed(let underlying) {
            XCTAssertEqual(underlying as? RestoreClaimError, .unconfirmed)
        }
        let queued = harness.store.load().valueTreatingAbsentAsEmpty([:])?["unanswered-transaction"]
        XCTAssertTrue(queued?.isUnsent ?? false, "the unanswered claim waits for its own answer")
    }

    /// A Restore never takes an acceptance from earlier in the session as
    /// its answer, least of all another customer's. After the first
    /// customer's purchase was accepted and its entry cleared, the restoring
    /// customer's Restore sends its own claim, and only that answer decides.
    func testRestoreSendsItsOwnClaimAfterAnotherCustomersAcceptance() async throws {
        let harness = await makeHarness(customer: "first")
        let item = entitlement("shared", productId: storeProductId, token: token("first"))
        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, true)
        XCTAssertNotNil(harness.store.load().valueTreatingAbsentAsEmpty([:])?["shared-transaction"]?.answeredAt)

        harness.identity.setDistinctId("restorer")
        harness.entitlements.set([item])
        harness.adapter.restoreResult = .restored
        harness.api.answer(.refuse(409), for: .restore)
        do {
            _ = try await harness.service.restore()
            XCTFail("The restorer's claim was refused; the first customer's acceptance must not count for it")
        } catch StoreKitError.restoreFailed(let underlying) {
            XCTAssertEqual(underlying as? RestoreClaimError, .ownedByAnotherAccount)
        }
        XCTAssertEqual(harness.api.requests.map(\.distinctId), ["first", "restorer"])
        XCTAssertEqual(harness.api.requests.last?.reason, .restore)
    }

    /// Reusing a commit the SDK already made for a purchase is keyed by the
    /// customer too: after the first customer's purchase was accepted, the
    /// next customer's ordinary scan sends the purchase for that customer.
    func testScanAfterAnotherCustomersAcceptanceSendsForTheCurrentCustomer() async throws {
        let harness = await makeHarness(customer: "first")
        let item = entitlement("shared", productId: storeProductId, token: token("first"))
        let streamed = await harness.observer.handleVerifiedTransaction(
            item.update,
            jwsRepresentation: item.jwsRepresentation,
            source: .transactionStream
        )
        let synced = await streamed.syncTask?.value
        XCTAssertEqual(synced, true)

        harness.identity.setDistinctId("second")
        harness.entitlements.set([item])
        harness.api.answer(.refuse(409))
        await harness.observer.retryAfterProfileReady()

        XCTAssertEqual(harness.api.requests.map(\.distinctId), ["first", "second"])
        XCTAssertEqual(harness.api.requests.last?.reason, .sync)
    }

    private func assertRestoreGetsNoAnswer(
        _ harness: Harness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await harness.service.restore()
            XCTFail("A Restore the server has not answered must not report restored", file: file, line: line)
        } catch StoreKitError.restoreFailed(let underlying) {
            XCTAssertEqual(underlying as? RestoreClaimError, .unconfirmed, file: file, line: line)
        }
    }

    /// The unanswered claim waits in the outbox as the restoring customer's
    /// own entry, so a retry or relaunch sends it again.
    private func assertRestoreClaimQueued(
        _ transactionId: String,
        jws: String,
        in harness: Harness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let queued = try XCTUnwrap(
            harness.store.load().valueTreatingAbsentAsEmpty([:])?[transactionId],
            file: file, line: line
        )
        XCTAssertTrue(queued.isUnsent, file: file, line: line)
        XCTAssertEqual(queued.transactionJws, jws, file: file, line: line)
        XCTAssertEqual(queued.distinctId, "restorer", file: file, line: line)
        XCTAssertEqual(queued.reason, .restore, file: file, line: line)
        XCTAssertEqual(queued.customerKind, .identified, file: file, line: line)
        XCTAssertEqual(queued.sendAttempts, 1, file: file, line: line)
        XCTAssertFalse(queued.unlocksEarly(for: "restorer"), "a Restore waits for the server", file: file, line: line)
    }

    // MARK: - Shared outbox fixture

    private struct OutboxFixture: Decodable {
        struct Delay: Decodable { let attempts: Int; let delaySeconds: Double }
        struct Retry: Decodable { let delayAfterAttempts: [Delay] }
        struct Customer: Decodable { let distinctId: String; let identified: Bool }
        struct Send: Decodable {
            let name: String
            let producer: String
            let customer: Customer
            let expectedRequest: [String: String]
        }
        struct Answer: Decodable {
            let name: String
            let status: Int?
            let entry: String
            let sendAttempts: Int
            let profileRefreshes: Int
        }
        struct Restore: Decodable {
            let name: String
            let answers: [String]
            let result: String
            let error: String?
            let queuedClaims: Int
        }
        let suite: String
        let retry: Retry
        let sends: [Send]
        let answers: [Answer]
        let restore: [Restore]

        static func load() throws -> OutboxFixture {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("fixtures/purchases/purchase-outbox.json")
            return try JSONDecoder().decode(OutboxFixture.self, from: Data(contentsOf: url))
        }
    }

    func testSharedOutboxRetryDelays() throws {
        let fixture = try OutboxFixture.load()
        XCTAssertEqual(fixture.suite, "purchases/purchase-outbox")
        for delay in fixture.retry.delayAfterAttempts {
            XCTAssertEqual(
                TransactionObserver.outboxRetryDelay(afterAttempts: delay.attempts),
                delay.delaySeconds,
                "after \(delay.attempts) attempts"
            )
        }
    }

    func testSharedOutboxSends() async throws {
        for vector in try OutboxFixture.load().sends {
            let harness = await makeHarness(customer: vector.customer.distinctId)
            if !vector.customer.identified {
                harness.identity.reset(keepAnonymousId: true)
            }
            let request = try await send(vector.producer, in: harness)
            var expected = vector.expectedRequest
            if expected["distinct_id"] == "<anonymousId>" {
                expected["distinct_id"] = harness.identity.getAnonymousId()
            }
            XCTAssertEqual(request?.distinctId, expected["distinct_id"], vector.name)
            XCTAssertEqual(request?.reason.rawValue, expected["reason"], vector.name)
            XCTAssertEqual(request?.customerKind.rawValue, expected["customer_kind"], vector.name)
        }
    }

    func testSharedOutboxAnswers() async throws {
        for vector in try OutboxFixture.load().answers {
            let harness = await makeHarness(customer: "buyer")
            harness.api.answer(Self.answer(named: vector.name))
            harness.adapter.configureVerifiedPurchase(
                transactionJws: "answer-jws",
                transactionId: "answer-transaction",
                originalTransactionId: "answer-original",
                productId: storeProductId
            )
            let result = try await harness.service.purchase(product())
            _ = await result.syncTask?.value

            let entry = harness.store.load().valueTreatingAbsentAsEmpty([:])?["answer-transaction"]
            XCTAssertEqual(entry?.isUnsent == true ? "kept" : "cleared", vector.entry, vector.name)
            XCTAssertEqual(entry?.sendAttempts ?? 0, vector.sendAttempts, vector.name)
            XCTAssertEqual(harness.profileRefreshes.requests.count, vector.profileRefreshes, vector.name)
        }
    }

    func testSharedOutboxRestoreOutcomes() async throws {
        for vector in try OutboxFixture.load().restore {
            let harness = await makeHarness(customer: "restorer")
            let items = vector.answers.enumerated().map { index, _ in
                entitlement("restored-\(index)", productId: "store-product-\(index)", token: nil)
            }
            for (item, answer) in zip(items, vector.answers) {
                harness.api.answer(Self.answer(named: answer), forJwt: item.jwsRepresentation)
            }
            harness.entitlements.set(items)
            harness.adapter.restoreResult = .restored

            let outcome: String
            var error: String?
            do {
                switch try await harness.service.restore() {
                case .restored: outcome = "restored"
                case .noPurchases: outcome = "no_purchases"
                case .failed: outcome = "failed"
                }
            } catch StoreKitError.restoreFailed(let underlying) {
                outcome = "failed"
                switch underlying as? RestoreClaimError {
                case .ownedByAnotherAccount: error = "owned_by_another_account"
                case .unconfirmed: error = "unconfirmed"
                case nil: error = nil
                }
            }
            XCTAssertEqual(outcome, vector.result, vector.name)
            XCTAssertEqual(error, vector.error, vector.name)
            let queued = harness.store.load().valueTreatingAbsentAsEmpty([:])?.values.filter {
                $0.isUnsent && $0.reason == .restore && $0.distinctId == "restorer"
            }
            XCTAssertEqual(queued?.count, vector.queuedClaims, vector.name)
        }
    }

    private static func answer(named name: String) -> ClaimAPI.Answer {
        switch name {
        case "accepted": return .accept
        case "conflict": return .refuse(409)
        case "invalid": return .refuse(400)
        case "unavailable": return .unavailable
        default: return .fail
        }
    }

    /// Drives one production producer and returns the last request it sent.
    private func send(_ producer: String, in harness: Harness) async throws -> PurchaseRequest? {
        let customer = harness.identity.getDistinctId()
        switch producer {
        case "checkout":
            harness.adapter.configureVerifiedPurchase(
                transactionJws: "checkout-jws", transactionId: "checkout-transaction",
                originalTransactionId: "checkout-original", productId: storeProductId
            )
            let result = try await harness.service.purchase(product())
            _ = await result.syncTask?.value
        case "already_owned":
            harness.entitlements.set([entitlement("owned", productId: storeProductId, token: token(customer))])
            harness.adapter.configureAlreadyOwned()
            _ = try await harness.service.purchase(product())
        case "restore":
            harness.entitlements.set([entitlement("restored", productId: storeProductId, token: nil)])
            harness.adapter.restoreResult = .restored
            _ = try await harness.service.restore()
        case "transaction_stream":
            let update = entitlement("update", productId: storeProductId, token: token(customer))
            let result = await harness.observer.handleVerifiedTransaction(
                update.update, jwsRepresentation: update.jwsRepresentation, source: .transactionStream
            )
            _ = await result.syncTask?.value
        case "launch_scan":
            harness.entitlements.set([entitlement("scanned", productId: storeProductId, token: nil)])
            await harness.observer.retryAfterProfileReady()
        case "retry_after_reset":
            harness.api.answer(.fail)
            harness.adapter.configureVerifiedPurchase(
                transactionJws: "retry-jws", transactionId: "retry-transaction",
                originalTransactionId: "retry-original", productId: storeProductId
            )
            let result = try await harness.service.purchase(product())
            _ = await result.syncTask?.value
            harness.identity.reset(keepAnonymousId: false)
            harness.api.answer(.accept)
            await harness.observer.retryStoredEvidence()
        default:
            XCTFail("Unknown producer \(producer)")
        }
        return harness.api.requests.last
    }

    // MARK: - Harness

    private struct Harness {
        let identity: MockIdentityService
        let api: ClaimAPI
        let store: WriteSwitchEvidenceStore
        let pending: WriteSwitchPendingStore
        let ownership: InMemoryPurchaseAccountOwnershipStore
        let settings: NuxieRuntimeSettings
        let featureInfo: FeatureInfo
        let features: FeatureService
        let observer: TransactionObserver
        let service: TransactionService
        let adapter: MockNativeStoreKitPurchaseAdapter
        let sink: RecoveryEventSink
        let entitlements: EntitlementBox
        let profileRefreshes: ProfileRefreshRecorder
        let revisionGated: RevisionGatedProfileService?

        func visiblePremium() async -> FeatureAccess? {
            await MainActor.run { featureInfo.feature("premium") }
        }

        func events(named name: String) -> Int {
            sink.events.filter { $0.name == name }.count
        }
    }

    private let premiumFeature = Feature(
        id: "premium", type: .boolean, balance: nil, unlimited: false,
        nextResetAt: nil, interval: nil, entities: nil
    )

    /// With no `profile`, the server's profile follows its last purchase
    /// answer: an acceptance grants premium, a refusal does not.
    private func makeHarness(
        customer: String,
        profile: MockProfileService? = nil,
        revisionGate: ClaimGate? = nil
    ) async -> Harness {
        let mocks = MockFactory.shared
        let identity = MockIdentityService()
        identity.setDistinctId(customer)
        let epoch = UUID()
        let featureInfo = await MainActor.run { () -> FeatureInfo in
            let info = FeatureInfo()
            info.beginOptimisticProjectionPublication(epoch: epoch, distinctId: customer)
            info.admitProfileSnapshot([
                "premium": FeatureAccess(allowed: false, unlimited: false, balance: nil, type: .boolean),
            ], admittedAt: Date())
            return info
        }
        let serverProfile = profile ?? MockProfileService()
        let profileFollowsAnswers = profile == nil
        let revisionGated = revisionGate.map {
            RevisionGatedProfileService(base: serverProfile, gate: $0)
        }
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: identity,
            profile: revisionGated ?? serverProfile,
            dateProvider: mocks.dateProvider,
            featureInfo: featureInfo,
            cacheTTL: 300
        )
        let api = ClaimAPI()
        let profileRefreshes = ProfileRefreshRecorder()
        let grantedProfile = TestJourneyProfile.response(features: [premiumFeature])
        let store = WriteSwitchEvidenceStore()
        let pending = WriteSwitchPendingStore()
        let ownership = InMemoryPurchaseAccountOwnershipStore()
        let sink = RecoveryEventSink()
        let settings = NuxieRuntimeSettings(configuration: NuxieConfiguration(apiKey: "claim-test"))
        let entitlements = EntitlementBox()
        let adapter = MockNativeStoreKitPurchaseAdapter()
        let box = LateBound<TransactionService>()
        let observer = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            settings: settings,
            eventSink: sink,
            transactionServiceProvider: { box.get() },
            evidenceStore: store,
            descriptorAllowanceProvider: { _ in
                [OptimisticEntitlementAllowance(
                    featureId: "premium", kind: .boolean, unlimited: false, allowance: nil
                )]
            },
            projectionPublisher: { evidence, allowances, distinctId, generation in
                await MainActor.run {
                    featureInfo.replaceOptimisticProjection(
                        evidence: evidence,
                        descriptorAllowances: allowances,
                        distinctId: distinctId,
                        publicationEpoch: epoch,
                        publicationGeneration: generation
                    )
                }
            },
            purchaseStorageScope: scope,
            dateProvider: mocks.dateProvider,
            unfinishedRecoveryTransactions: { [] },
            currentEntitlementRecoveryTransactions: { entitlements.get() },
            refreshProfile: { distinctId in
                profileRefreshes.record(distinctId)
                if profileFollowsAnswers {
                    serverProfile.setProfileResponse(
                        api.lastAnswerGranted ? grantedProfile : TestJourneyProfile.response()
                    )
                }
                _ = try? await serverProfile.refetchProfile(distinctId: distinctId)
                await features.syncFeatureInfo()
            }
        )
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: observer,
            pendingPurchaseStore: pending,
            accountOwnershipStore: ownership,
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: sink,
            purchaseStorageScope: scope,
            identityService: identity,
            nativePurchaseAdapter: adapter,
            featureService: features
        )
        box.set(service)
        addTeardownBlock { await observer.stopListening() }
        return Harness(
            identity: identity, api: api, store: store, pending: pending,
            ownership: ownership, settings: settings, featureInfo: featureInfo,
            features: features, observer: observer, service: service, adapter: adapter,
            sink: sink, entitlements: entitlements, profileRefreshes: profileRefreshes,
            revisionGated: revisionGated
        )
    }

    private func token(_ distinctId: String) -> UUID {
        scope.appAccountToken(distinctId: distinctId)
    }

    private func entitlement(
        _ name: String,
        productId: String,
        token: UUID?,
        transactionId: String? = nil,
        originalTransactionId: String? = nil
    ) -> StoreTransactionRecoveryItem {
        StoreTransactionRecoveryItem(
            update: VerifiedStoreTransactionUpdate(
                transactionId: transactionId ?? "\(name)-transaction",
                originalTransactionId: originalTransactionId ?? "\(name)-original",
                productId: productId,
                appAccountToken: token,
                isRevoked: false,
                isUpgraded: false,
                finish: {}
            ),
            jwsRepresentation: "\(name)-jws"
        )
    }

    private func product() -> StoreProduct {
        var product = StoreProduct(
            productId: "claim-product",
            storeProductId: storeProductId,
            placementId: "claim-placement",
            name: "Claim Product",
            price: "$1.00",
            period: nil
        )
        product.localEntitlementGrants = [StoreProduct.LocalEntitlementGrant(
            featureId: "feature-premium",
            featureExternalId: "premium",
            allowanceType: nil,
            allowance: nil
        )]
        product.purchaseContext = PurchaseCommercialContext(
            release: AuthenticatedJourneyReleaseID(
                identity: JourneyReleaseIdentity(
                    appId: "claim-app",
                    environment: "live",
                    experienceId: "claim-experience",
                    experienceVersionId: "claim-version",
                    buildId: "claim-build",
                    versionNumber: 1,
                    publishedAt: "2026-10-20T00:00:00Z",
                    publishedAtSeq: 1
                ),
                descriptorSHA256: String(repeating: "c", count: 64)
            ),
            placementId: product.placementId,
            productId: product.productId,
            storeProductId: product.storeProductId
        )
        return product
    }

    private func encodedObject(_ request: PurchaseRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// An evidence store whose writes the test can make fail, as a full disk
/// would.
private final class WriteSwitchEvidenceStore: TransactionEvidenceStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: StoredTransactionEvidence] = [:]
    private var refusesWritesStorage = false

    var refusesWrites: Bool {
        get { lock.withLock { refusesWritesStorage } }
        set { lock.withLock { refusesWritesStorage = newValue } }
    }

    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> {
        lock.withLock { .value(entries) }
    }

    @discardableResult
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        lock.withLock {
            guard !refusesWritesStorage else { return false }
            self.entries = entries
            return true
        }
    }
}

/// A binding store whose writes the test can make fail.
private final class WriteSwitchPendingStore: PendingPurchaseStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: PendingPurchaseRecord] = [:]
    private var refusesWritesStorage = false

    var refusesWrites: Bool {
        get { lock.withLock { refusesWritesStorage } }
        set { lock.withLock { refusesWritesStorage = newValue } }
    }

    func load() -> StoreReadResult<[String: PendingPurchaseRecord]> {
        lock.withLock { .value(entries) }
    }

    @discardableResult
    func save(_ entries: [String: PendingPurchaseRecord]) -> Bool {
        lock.withLock {
            guard !refusesWritesStorage else { return false }
            self.entries = entries
            return true
        }
    }
}

private final class FinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() { lock.withLock { calls += 1 } }
    var count: Int { lock.withLock { calls } }
}

private final class ProfileRefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ distinctId: String) { lock.withLock { storage.append(distinctId) } }
    var requests: [String] { lock.withLock { storage } }
}

private final class EntitlementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StoreTransactionRecoveryItem] = []

    func set(_ items: [StoreTransactionRecoveryItem]) { lock.withLock { self.items = items } }
    func get() -> [StoreTransactionRecoveryItem] { lock.withLock { items } }
}

/// The server profile, except that reading the latest request revision (which
/// publishing a 200's Features does) waits at `gate` while it is armed.
private final class RevisionGatedProfileService: ProfileServiceProtocol, @unchecked Sendable {
    private let base: MockProfileService
    private let gate: ClaimGate
    private let lock = NSLock()
    private var armed = false

    init(base: MockProfileService, gate: ClaimGate) {
        self.base = base
        self.gate = gate
    }

    func arm() { lock.withLock { armed = true } }

    func latestRequestRevision() async -> UInt64 {
        if lock.withLock({ armed }) { await gate.pass() }
        return await base.latestRequestRevision()
    }
    func getCachedProfile(distinctId: String) async -> ProfileResponse? {
        await base.getCachedProfile(distinctId: distinctId)
    }
    func localeDidChange() async { await base.localeDidChange() }
    func clearCache(distinctId: String) async { await base.clearCache(distinctId: distinctId) }
    func clearAllCache() async { await base.clearAllCache() }
    func cleanupExpired() async -> Int { await base.cleanupExpired() }
    func refetchProfile(distinctId: String?) async throws -> ProfileResponse {
        try await base.refetchProfile(distinctId: distinctId)
    }
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        await base.handleUserChange(from: oldDistinctId, to: newDistinctId)
    }
    func onAppBecameActive() async { await base.onAppBecameActive() }
}

/// Holds purchase requests until the test opens it.
private actor ClaimGate {
    private var opened = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrivals += 1
        let arrived = arrivalWaiters
        arrivalWaiters.removeAll()
        arrived.forEach { $0.resume() }
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrival(count: Int = 1) async {
        while arrivals < count {
            await withCheckedContinuation { arrivalWaiters.append($0) }
        }
    }

    func open() {
        opened = true
        let held = waiters
        waiters.removeAll()
        held.forEach { $0.resume() }
    }
}

private final class ClaimAPI: PurchaseSynchronizing, @unchecked Sendable {
    enum Answer {
        case accept
        case refuse(Int)
        case unavailable
        case fail
    }

    private let lock = NSLock()
    private var storage: [PurchaseRequest] = []
    private var nextAnswer: Answer = .accept
    private var answersByReason: [PurchaseSyncReason: Answer] = [:]
    private var answersByJwt: [String: Answer] = [:]
    private var gate: ClaimGate?

    var requests: [PurchaseRequest] { lock.withLock { storage } }
    private var granted = false
    /// Whether the last answered send was accepted.
    var lastAnswerGranted: Bool { lock.withLock { granted } }

    func answer(_ answer: Answer) { lock.withLock { nextAnswer = answer } }

    /// Answers sends made for `reason` with `answer`, whatever the default.
    /// Answers sends of one signed transaction with `answer`.
    func answer(_ answer: Answer, forJwt jwt: String) {
        lock.withLock { answersByJwt[jwt] = answer }
    }

    func answer(_ answer: Answer, for reason: PurchaseSyncReason) {
        lock.withLock { answersByReason[reason] = answer }
    }

    /// Holds every later request at `gate` until the test opens it.
    func hold(_ gate: ClaimGate) { lock.withLock { self.gate = gate } }

    func syncTransaction(_ request: PurchaseRequest) async throws -> PurchaseResponse {
        let (answer, gate) = lock.withLock { () -> (Answer, ClaimGate?) in
            storage.append(request)
            return (
                answersByJwt[request.transactionJwt]
                    ?? answersByReason[request.reason]
                    ?? nextAnswer,
                self.gate
            )
        }
        await gate?.pass()
        switch answer {
        case .accept:
            lock.withLock { granted = true }
            return PurchaseResponse(
                success: true,
                customerId: request.distinctId,
                features: [PurchaseFeature(
                    id: "feature-premium", extId: "premium", type: .boolean,
                    allowed: true, balance: nil, unlimited: false
                )],
                error: nil
            )
        case .refuse(let status):
            lock.withLock { granted = false }
            throw NuxieNetworkError.httpError(
                statusCode: status,
                message: "App Store purchase conflicts with retained ownership",
                code: "app_store_purchase_conflict"
            )
        case .unavailable:
            throw NuxieNetworkError.httpError(
                statusCode: 503,
                message: "App Store purchase processing is unavailable",
                code: "app_store_purchase_unavailable"
            )
        case .fail:
            throw URLError(.notConnectedToInternet)
        }
    }
}
