import Foundation
import StoreKit

public protocol StoreKitProductProvider: Sendable {
    func products(for identifiers: Set<String>) async throws -> [any StoreProductProtocol]
}

public final class DefaultStoreKitProductProvider: StoreKitProductProvider {
    public init() {}
    
    public func products(for identifiers: Set<String>) async throws -> [any StoreProductProtocol] {
        let products = try await Product.products(for: identifiers)
        // Products already conform to StoreProductProtocol via our extension
        return products
    }
}