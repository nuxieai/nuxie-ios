import Foundation
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class TransactionEvidencePersistenceOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("unreadable transaction evidence persistence") {
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

            it("keeps all three stores unknown until their files are readable") {
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
                    environment: .production,
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
                await api.setProfileResponse(ProfileResponse(
                    segments: [],
                    userProperties: nil,
                    experiments: nil,
                    features: []
                ))
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

                let receiptAccepted = await stack.core.transactionObserver.commit(
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
                ).committed
                expect(receiptAccepted).to(beFalse())

                let pendingOwnership = await stack.core.transactionService
                    .pendingPurchaseOwnership(productId: "corrupt-product")
                guard case .unavailable = pendingOwnership else {
                    fail("Expected pending state to remain unavailable")
                    return
                }
                let token = scope.appAccountToken(distinctId: distinctId)
                let accountOwner = await stack.core.transactionService
                    .purchaseAccountOwner(appAccountToken: token)
                guard case .unreadable = accountOwner else {
                    fail("Expected account ownership to remain unreadable")
                    return
                }
                for file in files.values {
                    expect(try Data(contentsOf: file)) == corruptContents
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
                let recorded = await stack.core.transactionObserver.commit(
                    .verified(
                        VerifiedPurchaseEvidence(
                            transactionJws: "signed-transaction",
                            transactionId: "transaction-1",
                            originalTransactionId: "original-1",
                            productId: "store-product-1",
                            attributedDistinctId: distinctId,
                            finishRequired: false,
                            resolvesPendingPurchase: false,
                            allowsDurableCheckoutAuthority: false,
                            requiresAuthorityResolution: false
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
