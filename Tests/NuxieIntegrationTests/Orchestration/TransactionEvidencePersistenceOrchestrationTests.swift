import Foundation
import Nimble
import Quick
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class TransactionEvidencePersistenceOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("corrupt transaction evidence persistence") {
            var storageURLs: [URL] = []
            var stacks: [OrchestrationStack] = []

            afterEach {
                for stack in stacks {
                    await stack.shutdownForCleanup()
                }
                stacks.removeAll()
                for storageURL in storageURLs {
                    try? FileManager.default.removeItem(at: storageURL)
                }
                storageURLs.removeAll()
            }

            it("keeps the consume admission kind on the wire after identify and a store reload") {
                for legacy in [false, true] {
                    let storageURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("consume-kind-orchestration-\(UUID().uuidString)")
                    storageURLs.append(storageURL)
                    let stack = try await OrchestrationStack.boot(
                        storageURL: storageURL, api: MockNuxieApi(), dateProvider: MockDateProvider(),
                        sleepProvider: MockSleepProvider(), distinctId: "initial-customer"
                    )
                    stacks.append(stack)
                    stack.core.identity.reset(keepAnonymousId: true)
                    let customerId = stack.core.identity.getDistinctId()
                    let scope = PurchaseStorageScope(
                        appIdentifier: Bundle.main.bundleIdentifier ?? "nuxie.unidentified-host-app",
                        apiKey: "orchestration-suite-key", testStoreEnabled: false
                    )
                    let store = TransactionEvidenceStore(customStoragePath: storageURL, scope: scope)
                    expect(store.save(["transaction": StoredTransactionEvidence(
                        scope: scope, transactionJws: "signed-jws", transactionId: "transaction",
                        originalTransactionId: "original", productId: "product", distinctId: customerId,
                        recordedAt: Date(), productFeatureIds: ["credits"], isRevoked: false,
                        appAccountToken: scope.appAccountToken(distinctId: customerId),
                        reason: .purchase, customerKind: .identified
                    )])).to(beTrue())
                    if legacy {
                        let file = scope.storageDirectory(customStoragePath: storageURL)
                            .appendingPathComponent("transaction-evidence.json")
                        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                        var retained = try XCTUnwrap(rows["transaction"] as? [String: Any])
                        retained.removeValue(forKey: "featureUseDeclarations")
                        rows["transaction"] = retained
                        try JSONSerialization.data(withJSONObject: rows).write(to: file)
                    }
                    let expectedKind: String? = legacy ? nil : "anonymous"
                    StubURLProtocol.reset()
                    defer { StubURLProtocol.reset() }
                    let session = TestURLSessionProvider.createNuxieTestSession()
                    defer { session.invalidateAndCancel() }
                    let api = NuxieApi(
                        apiKey: "orchestration-suite-key", baseURL: URL(string: "https://consume.test")!,
                        urlSession: session
                    )
                    func observer(store: TransactionEvidenceStore) -> TransactionObserver {
                        TransactionObserver(
                            api: api, features: stack.core.features, identity: stack.core.identity,
                            settings: NuxieRuntimeSettings(configuration: NuxieConfiguration(apiKey: "orchestration-suite-key")),
                            eventSink: stack.core.systemEvents, transactionServiceProvider: { fatalError("unused") },
                            evidenceStore: store, purchaseStorageScope: scope,
                            activeStoreOriginalTransactionIDs: { [] }
                        )
                    }
                    StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
                        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                        XCTAssertEqual(body["customerKind"] as? String, expectedKind)
                        throw URLError(.timedOut)
                    })
                    let first = observer(store: store)
                    do {
                        _ = try await first.useFeatureWithPendingPurchase(
                            distinctId: customerId, featureId: "credits", amount: 1, entityId: nil, metadata: nil
                        )
                        XCTFail("Expected a timeout")
                    } catch NuxieNetworkError.timeout {}
                    await first.stopListening()
                    let admitted = try XCTUnwrap(store.load().readableValue?["transaction"])
                    let operationId = admitted.featureUseCustomerKinds(for: customerId)?.keys.first
                    if legacy {
                        XCTAssertNil(admitted.featureUseCustomerKinds(for: customerId))
                    } else {
                        XCTAssertNotNil(operationId)
                        XCTAssertEqual(admitted.featureUseCustomerKinds(for: customerId)?.values.first, .anonymous)
                    }
                    XCTAssertEqual(admitted.customerKind, .identified, "/purchase keeps its own admission")
                    stack.core.identity.setDistinctId(customerId)
                    XCTAssertTrue(stack.core.identity.isIdentified)

                    StubURLProtocol.reset()
                    StubURLProtocol.register(matcher: RequestMatchers.post("/feature/consume"), handler: { request in
                        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                        XCTAssertEqual(body["customerKind"] as? String, expectedKind)
                        XCTAssertNil(body["customer_kind"])
                        let retriedOperationId = try XCTUnwrap(body["operationId"] as? String)
                        if let operationId { XCTAssertEqual(retriedOperationId, operationId) }
                        XCTAssertEqual((body["purchase"] as? [String: String])?["signedTransaction"], "signed-jws")
                        let response: [String: Any] = [
                            "customerId": customerId, "featureId": "credits", "operationId": retriedOperationId,
                            "quantity": 1, "accepted": true, "code": "consumed", "balance": 0,
                            "unlimited": false, "active": false, "type": "metered", "idempotentReplay": true,
                        ]
                        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            try JSONSerialization.data(withJSONObject: response))
                    })
                    let reopened = observer(store: TransactionEvidenceStore(customStoragePath: storageURL, scope: scope))
                    let result = try await reopened.useFeatureWithPendingPurchase(
                        distinctId: customerId, featureId: "credits", amount: 1, entityId: nil, metadata: nil
                    )
                    XCTAssertEqual(result?.success, true)
                    await reopened.stopListening()
                    if legacy {
                        XCTAssertNil(store.load().readableValue?["transaction"]?.featureUseCustomerKinds(for: customerId))
                    }
                }
            }

            it("sets all three corrupt stores aside and saves, sends and answers the purchase") {
                let distinctId = "purchase-corruption-customer"
                let storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "purchase-orchestration-\(UUID().uuidString)",
                        isDirectory: true
                    )
                storageURLs.append(storageURL)
                let scope = PurchaseStorageScope(
                    appIdentifier: Bundle.main.bundleIdentifier
                        ?? "nuxie.unidentified-host-app",
                    apiKey: "orchestration-suite-key",
                    testStoreEnabled: false
                )
                let directory = scope.storageDirectory(
                    customStoragePath: storageURL
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let fileNames = [
                    "transaction-evidence.json",
                    "pending-purchases.json",
                    "account-ownership.json",
                ]
                let corruptContents = Data("{ unreadable".utf8)
                let files = Dictionary(uniqueKeysWithValues: fileNames.map {
                    ($0, directory.appendingPathComponent($0))
                })
                for file in files.values {
                    try corruptContents.write(to: file)
                }

                let api = MockNuxieApi()
                await api.setProfileResponse(TestJourneyProfile.response())
                let stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: MockDateProvider(),
                    sleepProvider: MockSleepProvider(),
                    distinctId: distinctId
                )
                stacks.append(stack)
                _ = try await stack.core.profile.refetchProfile(
                    distinctId: distinctId
                )

                // Each corrupt store is set aside and an empty one takes its
                // place, so the outbox is on: the purchase is saved and sent.
                let delivery = await stack.core.transactionObserver.commit(
                    .verified(
                        VerifiedPurchaseEvidence(
                            transactionJws: "signed-corrupt-transaction",
                            transactionId: "corrupt-transaction",
                            originalTransactionId: "corrupt-original",
                            productId: "corrupt-product",
                            resolvesPendingPurchase: false,
                            allowsDurableCheckoutAuthority: false,
                            requiresAuthorityResolution: false
                        ),
                        source: .startupRecovery
                    )
                )
                expect(delivery.committed).to(beTrue())
                _ = await delivery.syncTask?.value
                let sends = await api.syncTransactionRequests.count
                expect(sends) == 1

                let saved = TransactionEvidenceStore(
                    customStoragePath: storageURL,
                    scope: scope
                ).load().readableValue?["corrupt-transaction"]
                expect(saved).toNot(beNil())
                expect(saved?.answeredAt).toNot(beNil())

                let pendingOwnership = await stack.core.transactionService
                    .pendingPurchaseOwnership(productId: "corrupt-product")
                guard case .none = pendingOwnership else {
                    fail("Expected an empty pending store in place of the corrupt one")
                    return
                }
                let token = scope.appAccountToken(distinctId: distinctId)
                let accountAuthority = await stack.core.transactionService
                    .durablePurchaseEvidenceAuthority(
                        appAccountToken: token,
                        productId: "corrupt-product"
                    )
                if case .unreadable = accountAuthority {
                    fail("Expected an empty ownership store in place of the corrupt one")
                    return
                }
                let names = try FileManager.default.contentsOfDirectory(
                    atPath: directory.path
                )
                for fileName in fileNames {
                    let prefix = (fileName as NSString).deletingPathExtension
                        + ".unreadable-"
                    let quarantined = names.filter { $0.hasPrefix(prefix) }
                    expect(quarantined.count) == 1
                    if let name = quarantined.first {
                        let aside = directory.appendingPathComponent(name)
                        expect(try Data(contentsOf: aside)) == corruptContents
                    }
                    if let current = files[fileName],
                       FileManager.default.fileExists(atPath: current.path) {
                        expect(try Data(contentsOf: current)) != corruptContents
                    }
                }
            }

            it("projects durable evidence until backend acknowledgement") {
                let distinctId = "projection-customer"
                let storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "projection-orchestration-\(UUID().uuidString)",
                        isDirectory: true
                    )
                storageURLs.append(storageURL)
                let api = MockNuxieApi()
                let stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: MockDateProvider(),
                    sleepProvider: MockSleepProvider(),
                    distinctId: distinctId,
                    initialFeatureAccess: [
                        "premium": FeatureAccess(
                            allowed: false,
                            unlimited: false,
                            balance: nil,
                            type: .boolean
                        ),
                        "credits": .withBalance(
                            2,
                            unlimited: false,
                            type: .metered
                        ),
                    ]
                )
                stacks.append(stack)
                stack.experienceService.optimisticAllowancesByStoreProductId = [
                    "store-product-1": [
                        OptimisticEntitlementAllowance(
                            featureId: "premium",
                            kind: .boolean,
                            unlimited: false,
                            allowance: nil
                        ),
                        OptimisticEntitlementAllowance(
                            featureId: "credits",
                            kind: .metered,
                            unlimited: false,
                            allowance: 10
                        ),
                    ],
                ]
                // The committer schedules its receipt submission at commit
                // time; hold the backend unavailable so the unacknowledged
                // evidence window (and its overlay) is observable.
                await api.setSyncTransactionShouldSucceed(false)
                // A native checkout carries the buyer's account token, which
                // is what lets it unlock before the server answers.
                let scope = PurchaseStorageScope(
                    appIdentifier: Bundle.main.bundleIdentifier
                        ?? "nuxie.unidentified-host-app",
                    apiKey: "orchestration-suite-key",
                    testStoreEnabled: false
                )
                let recorded = await stack.core.transactionObserver.commit(
                    .verified(
                        VerifiedPurchaseEvidence(
                            transactionJws: "signed-transaction",
                            transactionId: "transaction-1",
                            originalTransactionId: "original-1",
                            productId: "store-product-1",
                            appAccountToken: scope.appAccountToken(
                                distinctId: distinctId
                            ),
                            requester: .named(distinctId),
                            finishRequired: false,
                            resolvesPendingPurchase: false,
                            allowsDurableCheckoutAuthority: false,
                            requiresAuthorityResolution: false,
                            syncReason: .purchase
                        ),
                        source: .checkout
                    )
                ).committed
                expect(recorded).to(beTrue())
                let featureInfo = stack.core.featureInfo
                let projected = await MainActor.run {
                    (
                        featureInfo.isAllowed("premium"),
                        featureInfo.balance("credits"),
                        featureInfo.state
                    )
                }
                expect(projected.0).to(beTrue())
                expect(projected.1) == 12
                expect(projected.2) == .reconciling

                await stack.core.features.updateFromPurchase([
                    PurchaseFeature(
                        id: "premium",
                        extId: nil,
                        type: .boolean,
                        allowed: false,
                        balance: nil,
                        unlimited: false
                    ),
                    PurchaseFeature(
                        id: "credits",
                        extId: nil,
                        type: .metered,
                        allowed: true,
                        balance: 1,
                        unlimited: false
                    ),
                ], distinctId: distinctId)
                let joined = await MainActor.run {
                    (
                        featureInfo.isAllowed("premium"),
                        featureInfo.balance("credits")
                    )
                }
                expect(joined.0).to(beTrue())
                expect(joined.1) == 11

                // Once the server accepts the purchase, its profile is the
                // customer's access: the SDK fetches it again after the answer.
                await api.setProfileResponse(TestJourneyProfile.response(features: [
                    Feature(id: "credits", type: .metered, balance: 1, unlimited: false,
                        nextResetAt: nil, interval: nil, entities: nil),
                ]))
                await api.setSyncTransactionShouldSucceed(true)
                await stack.core.transactionObserver.retryStoredEvidence()
                let reconciled = await MainActor.run {
                    (
                        featureInfo.isAllowed("premium"),
                        featureInfo.balance("credits"),
                        featureInfo.state
                    )
                }
                expect(reconciled.0).to(beFalse())
                expect(reconciled.1) == 1
                expect(reconciled.2) == .ready
            }
        }
    }
}
