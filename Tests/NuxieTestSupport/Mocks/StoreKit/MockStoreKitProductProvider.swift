import Foundation
import StoreKit
@testable import Nuxie

/// Mock StoreKit Product Provider for testing
public actor MockStoreKitProductProvider {
    public var shouldThrowError = false
    public var errorToThrow: Error?
    public var productsToReturn: [any AppStoreProduct] = []
    public var requestedIdentifiers: Set<String>?
    public var fetchProductsCallCount = 0
    
    public func products(for identifiers: Set<String>) async throws -> [any AppStoreProduct] {
        fetchProductsCallCount += 1
        requestedIdentifiers = identifiers
        
        if shouldThrowError {
            throw errorToThrow ?? StoreKitError.networkUnavailable
        }
        
        return productsToReturn
    }
    
    public func setError(_ error: Error?) {
        shouldThrowError = error != nil
        errorToThrow = error
    }
    
    public func setProducts(_ products: [any AppStoreProduct]) {
        productsToReturn = products
    }
    
    public func reset() {
        shouldThrowError = false
        errorToThrow = nil
        productsToReturn = []
        requestedIdentifiers = nil
        fetchProductsCallCount = 0
    }
}

extension MockStoreKitProductProvider: StoreKitProductProvider {}
