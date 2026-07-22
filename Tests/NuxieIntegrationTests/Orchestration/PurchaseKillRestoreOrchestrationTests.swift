import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// P6 orchestration: kill-mid-purchase restore (Ask-to-Buy / SCA deferred
/// purchases).
///
/// Two layers of pending-purchase state exist:
///
///   1. `TransactionService`'s deferred-purchase marker — consumed by the
///      transaction observer when the deferred transaction later arrives via
///      `Transaction.updates`, emitting `$purchase_completed`
///      (source: deferred_transaction). Durable via `PendingPurchaseStore`
///      (30-day TTL), so it survives a process kill.
///   2. `FlowJourneyState.pendingPurchaseOutlets` — the purchase node's wired
///      onCompleted/onFailed/onCancelled chains, persisted with the journey
///      (PR #155) so a kill between performPurchase and the outcome event
///      doesn't drop them. On relaunch, `JourneyService` rebuilds the runner
///      on demand when an event reaches the restored journey, so the
///      persisted chains actually execute.
///
/// These tests pin both layers across a process kill end-to-end.
final class PurchaseKillRestoreOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("kill-mid-purchase restore (orchestration)") {
            let user = "orchestration-user"
            let productId = "orch.pro.monthly"

            var storageURL: URL!
            var api: MockNuxieApi!
            var dateProvider: MockDateProvider!
            var sleepProvider: MockSleepProvider!
            var delegate: MockPurchaseDelegate!
            var products: MockProductService!
            var stack: OrchestrationStack!

            func bootStack() async throws -> OrchestrationStack {
                try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: api,
                    dateProvider: dateProvider,
                    sleepProvider: sleepProvider,
                    distinctId: user,
                    productService: products,
                    configure: { config in
                        config.purchaseDelegate = delegate
                    }
                )
            }

            beforeEach {
                storageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-orch-purchase-\(UUID().uuidString)", isDirectory: true)
                api = MockNuxieApi()
                dateProvider = MockDateProvider()
                sleepProvider = MockSleepProvider()

                delegate = MockPurchaseDelegate()
                delegate.configureForPending()  // Ask-to-Buy: purchase defers
                delegate.simulatedDelay = 0

                products = MockProductService()
                products.mockProducts = [
                    MockStoreProduct(
                        id: productId,
                        displayName: "Orchestration Pro",
                        price: 9.99,
                        displayPrice: "$9.99"
                    )
                ]

                stack = try await bootStack()
            }

            afterEach {
                await stack?.shutdownForCleanup()
                stack = nil
                sleepProvider?.reset()
                if let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            // MARK: - TransactionService deferred-purchase marker

            it("resolves an Ask-to-Buy pending purchase marker exactly once within a session") {
                let product = MockStoreProduct(
                    id: productId,
                    displayName: "Orchestration Pro",
                    price: 9.99,
                    displayPrice: "$9.99"
                )

                do {
                    _ = try await stack.core.transactionService.purchase(product)
                    fail("expected StoreKitError.purchasePending")
                } catch StoreKitError.purchasePending {
                    // expected: Ask-to-Buy defers the transaction
                } catch {
                    fail("unexpected error: \(error)")
                }

                // The deferred transaction's arrival (Transaction.updates)
                // consumes the marker exactly once — a duplicate update can
                // never double-emit $purchase_completed.
                let first = await stack.core.transactionService
                    .consumePendingPurchase(productId: productId)
                expect(first).to(beTrue())
                let second = await stack.core.transactionService
                    .consumePendingPurchase(productId: productId)
                expect(second).to(beFalse())
            }

            it("resolves the pending-purchase marker exactly once across a process kill") {
                // Session 1: purchase defers (Ask-to-Buy) and the marker is
                // recorded durably.
                let product = MockStoreProduct(
                    id: productId,
                    displayName: "Orchestration Pro",
                    price: 9.99,
                    displayPrice: "$9.99"
                )
                do {
                    _ = try await stack.core.transactionService.purchase(product)
                    fail("expected StoreKitError.purchasePending")
                } catch StoreKitError.purchasePending {
                } catch {
                    fail("unexpected error: \(error)")
                }

                // Kill mid-pending, relaunch over the same storage.
                await stack.kill()
                stack = try await bootStack()

                // The marker survived the kill: the deferred transaction that
                // arrives via Transaction.updates in the new process consumes
                // it exactly once, so `$purchase_completed`
                // (source: deferred_transaction) is emitted once — never
                // twice, even if a duplicate update lands.
                let consumedAfterRelaunch = await stack.core.transactionService
                    .consumePendingPurchase(productId: productId)
                expect(consumedAfterRelaunch).to(beTrue())
                let consumedAgain = await stack.core.transactionService
                    .consumePendingPurchase(productId: productId)
                expect(consumedAgain).to(beFalse())
            }

            it("expires a pending-purchase marker that never resolved within the 30-day TTL") {
                let product = MockStoreProduct(
                    id: productId,
                    displayName: "Orchestration Pro",
                    price: 9.99,
                    displayPrice: "$9.99"
                )
                do {
                    _ = try await stack.core.transactionService.purchase(product)
                    fail("expected StoreKitError.purchasePending")
                } catch StoreKitError.purchasePending {
                } catch {
                    fail("unexpected error: \(error)")
                }

                await stack.kill()
                // Relaunch long after the Ask-to-Buy window could possibly
                // resolve: the stale marker must not label a much later
                // organic purchase as the deferred one.
                dateProvider.advance(by: TransactionService.pendingPurchaseTTL + 1)
                stack = try await bootStack()

                let consumedAfterExpiry = await stack.core.transactionService
                    .consumePendingPurchase(productId: productId)
                expect(consumedAfterExpiry).to(beFalse())
            }

            // MARK: - Journey purchase outlet chains

            context("journey purchase node with wired outcome outlets") {
                func installPurchaseCampaign() async throws {
                    try await stack.installProfile(
                        campaigns: [
                            OrchestrationFixtures.campaign(
                                id: "camp-buy",
                                flowId: "flow-buy",
                                eventName: "buy_trigger",
                                reentry: .everyTime
                            )
                        ],
                        flows: [
                            try OrchestrationFixtures.purchaseFlow(
                                id: "flow-buy",
                                trigger: "buy_trigger",
                                productId: productId,
                                effect: "purchase_effect"
                            )
                        ]
                    )
                    // The runner only executes purchase actions with an
                    // attached view controller; wire a mock VC to THIS
                    // stack's real event log / transaction service.
                    // (Snapshot into lets: capturing the spec's vars in the
                    // MainActor closure is a Swift 6 concurrency violation.)
                    let eventLog = stack.core.eventLog
                    let transactionService = stack.core.transactionService
                    let productService: MockProductService = products
                    let controller = await MainActor.run {
                        MockFlowViewController(
                            mockFlowId: "flow-buy",
                            eventLog: eventLog,
                            transactionService: transactionService,
                            productService: productService
                        )
                    }
                    stack.presentation.mockViewControllers["flow-buy"] = controller
                }

                /// Enroll and drive the purchase to its deferred (pending)
                /// state: outlets recorded, StoreKit purchase attempted once.
                func reachPendingPurchase() async throws {
                    await stack.trackAndDrain("buy_trigger")
                    await expect { await stack.journeys.getActiveJourneys(for: user).count }
                        .toEventually(equal(1), timeout: .seconds(5))
                    // The purchase node recorded its outlet chains before
                    // starting the purchase.
                    await expect {
                        await stack.journeys.getActiveJourneys(for: user)
                            .first?.flowState.pendingPurchaseOutlets != nil
                    }.toEventually(beTrue(), timeout: .seconds(5))
                    // The StoreKit purchase ran (and deferred).
                    await expect { delegate.purchaseCallCount }
                        .toEventually(equal(1), timeout: .seconds(5))
                }

                it("runs the persisted onCompleted chain exactly once when the deferred outcome arrives in the same session") {
                    try await installPurchaseCampaign()
                    try await reachPendingPurchase()

                    // Deferred outcome arrives (in production: the observer
                    // consumes the marker and emits $purchase_completed).
                    await stack.trackAndDrain(
                        "$purchase_completed", properties: ["product_id": productId]
                    )

                    await expect { await stack.eventCount("purchase_effect") }
                        .toEventually(equal(1), timeout: .seconds(5))
                    await expect { await stack.journeys.getActiveJourneys(for: user).count }
                        .toEventually(equal(0), timeout: .seconds(5))
                    await expect { await stack.lastJourneyExitReason() }
                        .toEventually(equal("completed"), timeout: .seconds(5))

                    // A duplicate outcome event must not run the chain again.
                    await stack.trackAndDrain(
                        "$purchase_completed", properties: ["product_id": productId]
                    )
                    await expect { await stack.eventCount("purchase_effect") }.to(equal(1))
                }

                it("runs the persisted onCompleted chain exactly once when the deferred outcome arrives after a process kill") {
                    try await installPurchaseCampaign()
                    try await reachPendingPurchase()

                    // The pre-kill background snapshot (how nearly every real
                    // kill happens: backgrounded, then reaped) persists the
                    // journey including its recorded outlet chains.
                    await expect {
                        await stack.journeys.onAppDidEnterBackground()
                        return stack.journeyStoreOnDisk().loadActiveJourneys()
                            .first?.flowState.pendingPurchaseOutlets != nil
                    }.toEventually(beTrue(), timeout: .seconds(5))

                    await stack.kill()
                    stack = try await bootStack()
                    try await installPurchaseCampaign()

                    // The journey is restored with its outlet chains intact —
                    // the PR #155 persistence works.
                    await expect { await stack.journeys.getActiveJourneys(for: user).count }
                        .toEventually(equal(1), timeout: .seconds(5))
                    let restored = await stack.journeys.getActiveJourneys(for: user).first
                    expect(restored?.flowState.pendingPurchaseOutlets).toNot(beNil())
                    expect(restored?.flowState.pendingPurchaseOutlets?.first).toNot(beNil())

                    // The durable marker survived the kill, so the deferred
                    // transaction resolves in this process too (same as the
                    // marker tests above). Here we deliver the outcome event
                    // the observer would emit: the restored journey has no
                    // runner yet, JourneyService rebuilds one on demand from
                    // the cached campaign/flow, and the PERSISTED onCompleted
                    // chain runs exactly once, completing the journey.
                    await stack.trackAndDrain(
                        "$purchase_completed", properties: ["product_id": productId]
                    )
                    await expect { await stack.eventCount("purchase_effect") }
                        .toEventually(equal(1), timeout: .seconds(5))
                    await expect { await stack.journeys.getActiveJourneys(for: user).count }
                        .toEventually(equal(0), timeout: .seconds(5))
                    await expect { await stack.lastJourneyExitReason() }
                        .toEventually(equal("completed"), timeout: .seconds(5))

                    // A duplicate outcome event must not run the chain again.
                    await stack.trackAndDrain(
                        "$purchase_completed", properties: ["product_id": productId]
                    )
                    await expect { await stack.eventCount("purchase_effect") }.to(equal(1))
                }
            }
        }
    }
}
