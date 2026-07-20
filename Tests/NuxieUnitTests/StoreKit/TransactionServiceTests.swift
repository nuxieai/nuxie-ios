import Foundation
import Quick
import Nimble
import FactoryKit
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

            beforeEach {
                // Register mocks using MockFactory
                mocks = MockFactory.shared
                mocks.registerAll()

                // Keep StoreKit's real transaction observer out of unit tests
                mockTransactionObserver = MockTransactionObserver()
                Container.shared.transactionObserver.register { mockTransactionObserver }
                
                // Create mock purchase delegate
                mockPurchaseDelegate = MockPurchaseDelegate()
                
                // Create a test configuration with the purchase delegate
                let config = NuxieConfiguration(apiKey: "test-api-key")
                config.purchaseDelegate = mockPurchaseDelegate
                
                // Setup SDK with configuration (required for TransactionService to access controller)
                try? NuxieSDK.shared.setup(with: config)
                
                // Create transaction service which will use @Injected
                transactionService = TransactionService()
                
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

                        await MainActor.run {
                            controller.performPurchase(productId: mockProduct.id)
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
                        try? NuxieSDK.shared.setup(with: config)
                        
                        await expect {
                            try await transactionService.purchase(mockProduct)
                        }.to(throwError(StoreKitError.notConfigured))
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
                        try? NuxieSDK.shared.setup(with: config)
                        
                        await expect {
                            try await transactionService.restore()
                        }.to(throwError(StoreKitError.notConfigured))
                    }
                }
            }
        }
    }
}
