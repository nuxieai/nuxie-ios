import Foundation
@testable import Nuxie

/// Mock implementation of ProductService for testing
// @unchecked Sendable (restated from ProductService): all mutable state is
// serialized through `lock`.
public final class MockProductService: ProductService, @unchecked Sendable {
    private let lock = NSLock()
    private var _fetchProductsCalled = false
    private var _requestedProductIds: Set<String> = []
    private var _mockProducts: [any StoreProductProtocol] = []
    private var _shouldThrowError = false

    public var fetchProductsCalled: Bool {
        get { lock.withLock { _fetchProductsCalled } }
        set { lock.withLock { _fetchProductsCalled = newValue } }
    }
    public var requestedProductIds: Set<String> {
        get { lock.withLock { _requestedProductIds } }
        set { lock.withLock { _requestedProductIds = newValue } }
    }
    public var mockProducts: [any StoreProductProtocol] {
        get { lock.withLock { _mockProducts } }
        set { lock.withLock { _mockProducts = newValue } }
    }
    public var shouldThrowError: Bool {
        get { lock.withLock { _shouldThrowError } }
        set { lock.withLock { _shouldThrowError = newValue } }
    }

    public override func fetchProducts(for identifiers: Set<String>) async throws -> [any StoreProductProtocol] {
        let (shouldThrow, products): (Bool, [any StoreProductProtocol]) = lock.withLock {
            _fetchProductsCalled = true
            _requestedProductIds = identifiers
            return (_shouldThrowError, _mockProducts)
        }
        if shouldThrow {
            throw StoreKitError.networkUnavailable
        }
        return products
    }

    public func reset() {
        lock.withLock {
            _fetchProductsCalled = false
            _requestedProductIds = []
            _mockProducts = []
            _shouldThrowError = false
        }
    }
}
