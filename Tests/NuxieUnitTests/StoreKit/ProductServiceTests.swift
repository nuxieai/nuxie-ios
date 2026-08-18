import Foundation
import Quick
import Nimble
import StoreKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ProductServiceSpec: AsyncSpec {
    override class func spec() {
        describe("ProductService") {
            var productService: ProductService!
            var mockProvider: MockStoreKitProductProvider!

            beforeEach {
                mockProvider = MockStoreKitProductProvider()
                productService = ProductService(productProvider: mockProvider)
            }

            afterEach {
                await mockProvider?.reset()
                productService = nil
                mockProvider = nil
            }

            describe("fetchProducts") {
                it("fetches products successfully") {
                    let identifiers = Set(["com.example.product1", "com.example.product2"])
                    let mockProducts: [any AppStoreProduct] = [
                        MockStoreProduct(
                            id: "com.example.product1",
                            displayName: "Product 1",
                            description: "Test product 1",
                            price: Decimal(0.99),
                            displayPrice: "$0.99",
                            productType: .consumable
                        ),
                        MockStoreProduct(
                            id: "com.example.product2",
                            displayName: "Product 2",
                            description: "Test product 2",
                            price: Decimal(1.99),
                            displayPrice: "$1.99",
                            productType: .nonConsumable
                        )
                    ]

                    await mockProvider.setProducts(mockProducts)

                    let products = try await productService.fetchProducts(for: identifiers)

                    expect(products).to(haveCount(2))
                    expect(products.map { $0.id }).to(contain("com.example.product1", "com.example.product2"))
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                    await expect { await mockProvider.requestedIdentifiers }.to(equal(identifiers))
                }

                it("handles partial product availability") {
                    let identifiers = Set(["com.example.product1", "com.example.product2"])
                    let mockProducts: [any AppStoreProduct] = [
                        MockStoreProduct(
                            id: "com.example.product1",
                            displayName: "Product 1",
                            description: "Test product 1",
                            price: Decimal(0.99),
                            displayPrice: "$0.99",
                            productType: .consumable
                        )
                    ]

                    await mockProvider.setProducts(mockProducts)

                    let products = try await productService.fetchProducts(for: identifiers)

                    expect(products).to(haveCount(1))
                    expect(products.first?.id).to(equal("com.example.product1"))
                }

                it("throws on empty identifiers") {
                    let identifiers: Set<String> = []

                    await expect {
                        try await productService.fetchProducts(for: identifiers)
                    }.to(throwError(StoreKitError.apiMisuse(reason: "Product identifiers cannot be empty")))

                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(0))
                }

                it("propagates StoreKit errors") {
                    let identifiers = Set(["com.example.product1"])
                    await mockProvider.setError(StoreKitError.networkUnavailable)

                    await expect {
                        try await productService.fetchProducts(for: identifiers)
                    }.to(throwError(StoreKitError.networkUnavailable))

                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(1))
                }

                it("coalesces overlapping concurrent identifiers and reuses the result") {
                    let provider = SuspendedStoreKitProductProvider(products: [
                        MockStoreProduct(
                            id: "com.example.shared",
                            displayName: "Shared",
                            description: "Shared product",
                            price: Decimal(1.99),
                            displayPrice: "$1.99",
                            productType: .nonConsumable
                        ),
                        MockStoreProduct(
                            id: "com.example.first",
                            displayName: "First",
                            description: "First product",
                            price: Decimal(0.99),
                            displayPrice: "$0.99",
                            productType: .consumable
                        )
                    ])
                    let service = ProductService(productProvider: provider)

                    let first = Task {
                        try await service.fetchProducts(for: [
                            "com.example.first",
                            "com.example.shared"
                        ])
                    }
                    await provider.waitUntilRequested()
                    let overlapping = Task {
                        try await service.fetchProducts(for: ["com.example.shared"])
                    }
                    await Task.yield()
                    await Task.yield()

                    let inFlightCount = await provider.requestCount
                    expect(inFlightCount).to(equal(1))

                    await provider.resume()
                    let firstIDs = try await first.value.map(\.id)
                    let overlappingIDs = try await overlapping.value.map(\.id)
                    expect(firstIDs).to(contain(
                        "com.example.first",
                        "com.example.shared"
                    ))
                    expect(overlappingIDs).to(equal([
                        "com.example.shared"
                    ]))

                    let cached = try await service.fetchProducts(for: ["com.example.shared"])
                    expect(cached.map(\.id)).to(equal(["com.example.shared"]))
                    let finalCount = await provider.requestCount
                    expect(finalCount).to(equal(1))
                }

                it("refetches invalidated product details before the next presentation") {
                    let identifier = "com.example.product1"
                    await mockProvider.setProducts([
                        MockStoreProduct(
                            id: identifier,
                            displayName: "Product",
                            price: 9.99,
                            displayPrice: "$9.99"
                        )
                    ])
                    _ = try await productService.fetchProducts(for: [identifier])

                    await productService.invalidate([identifier])
                    await mockProvider.setProducts([
                        MockStoreProduct(
                            id: identifier,
                            displayName: "Product",
                            price: 12.99,
                            displayPrice: "$12.99"
                        )
                    ])
                    let refreshed = try await productService.fetchProducts(for: [identifier])

                    expect(refreshed.first?.displayPrice) == "$12.99"
                    await expect { await mockProvider.fetchProductsCallCount }.to(equal(2))
                }

                it("wraps generic errors") {
                    let identifiers = Set(["com.example.product1"])
                    let genericError = NSError(domain: "TestError", code: 123, userInfo: nil)
                    await mockProvider.setError(genericError)

                    await expect {
                        try await productService.fetchProducts(for: identifiers)
                    }.to(throwError())
                }
            }

            describe("product properties") {
                it("preserves product properties") {
                    let identifiers = Set(["com.example.product1"])

                    let mockProducts: [any AppStoreProduct] = [
                        MockStoreProduct(
                            id: "com.example.product1",
                            displayName: "Test Product",
                            description: "A test product description",
                            price: Decimal(9.99),
                            displayPrice: "$9.99",
                            isFamilyShareable: true,
                            productType: .nonConsumable
                        )
                    ]

                    await mockProvider.setProducts(mockProducts)

                    let products = try await productService.fetchProducts(for: identifiers)

                    expect(products).to(haveCount(1))
                    guard let product = products.first else {
                        fail("Expected to find a product")
                        return
                    }

                    expect(product.id).to(equal("com.example.product1"))
                    expect(product.displayName).to(equal("Test Product"))
                    expect(product.description).to(equal("A test product description"))
                    expect(product.price).to(equal(Decimal(9.99)))
                    expect(product.displayPrice).to(equal("$9.99"))
                    expect(product.isFamilyShareable).to(beTrue())
                    expect(product.productType).to(equal(.nonConsumable))
                }
            }
        }
    }
}

private actor SuspendedStoreKitProductProvider: StoreKitProductProvider {
    private let availableProducts: [any AppStoreProduct]
    private var requests: [Set<String>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var isResumed = false

    init(products: [any AppStoreProduct]) {
        availableProducts = products
    }

    func products(for identifiers: Set<String>) async throws -> [any AppStoreProduct] {
        requests.append(identifiers)
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        if !isResumed {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        return availableProducts.filter { identifiers.contains($0.id) }
    }

    func waitUntilRequested() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resume() {
        isResumed = true
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
    }

    var requestCount: Int { requests.count }
}
