import Foundation
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class CommercePersistenceOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("unreadable commerce persistence") {
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

            it("keeps all four stores unknown until their files are readable") {
                let distinctId = "commerce-corruption-customer"
                let featureId = "commerce-corruption-feature"
                let storageURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "commerce-orchestration-\(UUID().uuidString)",
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
                    "local-purchase-access.json",
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
                    features: [Feature(
                        id: featureId,
                        type: .boolean,
                        balance: nil,
                        unlimited: true,
                        nextResetAt: nil,
                        interval: nil,
                        entities: nil
                    )]
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

                let receiptAccepted = await stack.core.transactionObserver
                    .syncTransaction(
                        transactionJws: "signed-corrupt-transaction",
                        transactionId: "corrupt-transaction",
                        productId: "corrupt-product",
                        originalTransactionId: "corrupt-original"
                    )
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
                let beforeRepair = await stack.core.features.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(beforeRepair?.allowed).to(beTrue())

                for file in files.values {
                    expect(try Data(contentsOf: file)) == corruptContents
                }

                let revoked = StoredLocalPurchaseAccess(
                    scope: scope,
                    transactionId: "repaired-revocation",
                    originalTransactionId: "repaired-revocation-original",
                    productId: "corrupt-product",
                    distinctId: distinctId,
                    grants: [StoredLocalEntitlementGrant(
                        featureId: featureId,
                        featureExternalId: nil,
                        allowanceType: "boolean",
                        allowance: nil
                    )],
                    state: .revoked
                )
                let repairedAccess = try JSONEncoder().encode([
                    revoked.transactionId: revoked,
                ])
                try repairedAccess.write(
                    to: files["local-purchase-access.json"]!,
                    options: .atomic
                )

                let afterRepair = await stack.core.features.getCached(
                    featureId: featureId,
                    entityId: nil
                )
                expect(afterRepair?.allowed).to(beFalse())
            }
        }
    }
}
