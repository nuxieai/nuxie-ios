import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class RecordingPurchaseFlowViewController: MockFlowViewController {
    private(set) var emittedSystemEvents: [(name: String, properties: [String: Any])] = []

    override func emitSystemEvent(_ name: String, properties: [String: Any]) {
        emittedSystemEvents.append((name, properties))
    }
}

final class TransactionServiceTests: AsyncSpec {
    override class func spec() {
        describe("TransactionService") {
            var transactionService: TransactionService!
            var mocks: MockFactory!
            var mockPurchaseDelegate: MockPurchaseDelegate!
            var mockProduct: MockStoreProduct!
            var mockTransactionObserver: MockTransactionObserver!
            var pendingStorageURL: URL!
            var dateProvider: MockDateProvider!

            /// A TransactionService over the durable pending-purchase store in
            /// `pendingStorageURL` — building a second one models a process
            /// relaunch over the same storage.
            func makeTransactionService() -> TransactionService {
                TransactionService(
                    productService: mocks.productService,
                    transactionObserver: mockTransactionObserver,
                    pendingPurchaseStore: PendingPurchaseStore(customStoragePath: pendingStorageURL),
                    dateProvider: dateProvider,
                    configurationProvider: {
                        NuxieSDK.shared.configuration ?? NuxieConfiguration(apiKey: "test-api-key")
                    }
                )
            }

            beforeEach {
                mocks = MockFactory.shared

                // Keep StoreKit's real transaction observer out of unit tests
                mockTransactionObserver = MockTransactionObserver()

                // Create mock purchase delegate
                mockPurchaseDelegate = MockPurchaseDelegate()

                // Create a test configuration with the purchase delegate
                let config = NuxieConfiguration(apiKey: "test-api-key")
                config.purchaseDelegate = mockPurchaseDelegate

                // Setup SDK with mock overrides (required for the flow
                // controller purchase path to see the current configuration)
                var overrides = mocks.unitTestOverrides()
                overrides.transactionObserver = mockTransactionObserver
                try? NuxieSDK.shared.setup(with: config, overrides: overrides)

                pendingStorageURL = URL(
                    fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
                ).appendingPathComponent("nuxie-txn-\(UUID().uuidString)", isDirectory: true)
                dateProvider = MockDateProvider()

                // Create transaction service with explicit collaborators
                transactionService = makeTransactionService()

                // Create mock product
                mockProduct = MockStoreProduct(
                    id: "com.test.product",
                    displayName: "Test Product",
                    description: "Test Description",
                    price: 9.99,
                    displayPrice: "$9.99"
                )
            }

            afterEach {
                // Clean up
                mockPurchaseDelegate.reset()
                if let pendingStorageURL {
                    try? FileManager.default.removeItem(at: pendingStorageURL)
                }
            }
            
            describe("purchase") {
                context("with purchase delegate configured") {
                    it("should successfully complete a purchase") {
                        mockPurchaseDelegate.configureForSuccess()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                        expect(mockPurchaseDelegate.lastPurchasedProduct?.id).to(equal(mockProduct.id))
                    }
                    
                    it("should throw purchaseCancelled when user cancels") {
                        mockPurchaseDelegate.configureForCancellation()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchaseCancelled))
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }
                    
                    it("should throw purchaseFailed when purchase fails") {
                        let error = StoreKitError.networkUnavailable
                        mockPurchaseDelegate.configureForFailure(error: error)
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError())
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }
                    
                    it("should throw purchasePending when purchase is pending") {
                        mockPurchaseDelegate.configureForPending()
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        
                        expect(mockPurchaseDelegate.purchaseCalled).to(beTrue())
                    }

                    it("should not emit purchase_failed from native purchase when purchase is pending") {
                        mockPurchaseDelegate.simulatedDelay = 0
                        mockPurchaseDelegate.configureForPending()
                        mocks.productService.mockProducts = [mockProduct]
                        let controller = await MainActor.run {
                            RecordingPurchaseFlowViewController(mockFlowId: "flow-purchase-pending")
                        }

                        let pendingProductId = mockProduct.id
                        await MainActor.run {
                            controller.performPurchase(productId: pendingProductId)
                        }

                        await expect(mockPurchaseDelegate.purchaseCalled).toEventually(beTrue(), timeout: .seconds(2))
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        let emittedNames = await MainActor.run {
                            controller.emittedSystemEvents.map(\.name)
                        }
                        expect(emittedNames).toNot(contain(SystemEventNames.purchaseFailed))
                    }
                }
                
                context("without purchase delegate configured") {
                    it("should throw notConfigured error") {
                        // Create new SDK instance without purchase delegate
                        await NuxieSDK.shared.shutdown()
                        let config = NuxieConfiguration(apiKey: "test-api-key")
                        // Don't set purchaseDelegate
                        var overrides = mocks.unitTestOverrides()
                        overrides.transactionObserver = mockTransactionObserver
                        try? NuxieSDK.shared.setup(with: config, overrides: overrides)

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.notConfigured))
                    }
                }

                context("when the purchase is deferred (Ask-to-Buy / SCA)") {
                    it("records the product so the observer can resolve it exactly once") {
                        mockPurchaseDelegate.purchaseResult = .pending

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        // The deferred transaction later lands via
                        // Transaction.updates; the observer consumes the entry
                        // (exactly once) and emits $purchase_completed.
                        await expect {
                            await transactionService.consumePendingPurchase(productId: mockProduct.id)
                        }.to(beTrue())
                        await expect {
                            await transactionService.consumePendingPurchase(productId: mockProduct.id)
                        }.to(beFalse())
                    }

                    it("persists the marker so it survives a store reload (process kill)") {
                        mockPurchaseDelegate.purchaseResult = .pending

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        // "Relaunch": a fresh service over the same storage
                        // still resolves the deferred purchase, exactly once.
                        let relaunched = makeTransactionService()
                        await expect {
                            await relaunched.consumePendingPurchase(productId: mockProduct.id)
                        }.to(beTrue())
                        await expect {
                            await relaunched.consumePendingPurchase(productId: mockProduct.id)
                        }.to(beFalse())

                        // Consumption is durable too: yet another relaunch
                        // must not see the already-consumed marker.
                        let relaunchedAgain = makeTransactionService()
                        await expect {
                            await relaunchedAgain.consumePendingPurchase(productId: mockProduct.id)
                        }.to(beFalse())
                    }

                    it("expires an unresolved marker after the 30-day TTL") {
                        mockPurchaseDelegate.purchaseResult = .pending

                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))

                        // Just inside the TTL: still resolvable.
                        dateProvider.advance(by: TransactionService.pendingPurchaseTTL - 1)
                        let insideTTL = makeTransactionService()
                        await expect {
                            await insideTTL.consumePendingPurchase(productId: mockProduct.id)
                        }.to(beTrue())

                        // Re-record, then jump past the TTL: the stale marker
                        // must not resolve (a much later organic purchase is
                        // not the deferred one).
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.purchasePending))
                        dateProvider.advance(by: TransactionService.pendingPurchaseTTL + 1)
                        let afterTTL = makeTransactionService()
                        await expect {
                            await afterTTL.consumePendingPurchase(productId: mockProduct.id)
                        }.to(beFalse())
                    }
                }
            }

            describe("restore") {
                context("with purchase delegate configured") {
                    it("syncs current entitlements to the backend after a successful restore") {
                        mockPurchaseDelegate.restoreResult = .success(restoredCount: 2)

                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())

                        await expect { await mockTransactionObserver.syncCurrentEntitlementsCalled }
                            .to(beTrue())
                    }

                    it("should successfully restore purchases") {
                        mockPurchaseDelegate.restoreResult = .success(restoredCount: 2)
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                    }
                    
                    it("should handle no purchases to restore") {
                        mockPurchaseDelegate.configureForNoPurchases()
                        
                        await expect {
                            try await transactionService.restore()
                        }.toNot(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                    }
                    
                    it("should throw restoreFailed when restore fails") {
                        let error = StoreKitError.networkUnavailable
                        mockPurchaseDelegate.restoreResult = .failed(error)
                        
                        await expect {
                            try await transactionService.restore()
                        }.to(throwError())
                        
                        expect(mockPurchaseDelegate.restoreCalled).to(beTrue())
                    }
                }
                
                context("without purchase delegate configured") {
                    it("should throw notConfigured error") {
                        // Create new SDK instance without purchase delegate
                        await NuxieSDK.shared.shutdown()
                        let config = NuxieConfiguration(apiKey: "test-api-key")
                        // Don't set purchaseDelegate
                        var overrides = mocks.unitTestOverrides()
                        overrides.transactionObserver = mockTransactionObserver
                        try? NuxieSDK.shared.setup(with: config, overrides: overrides)
                        
                        await expect {
                            try await transactionService.restore()
                        }.to(throwError(StoreKitError.notConfigured))
                    }
                }
            }
        }
    }
}
