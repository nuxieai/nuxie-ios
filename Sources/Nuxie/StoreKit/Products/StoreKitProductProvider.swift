import Foundation
import StoreKit

protocol StoreKitProductProvider: Sendable {
    func products(for identifiers: Set<String>) async throws -> [any AppStoreProduct]
}

final class DefaultStoreKitProductProvider: StoreKitProductProvider {
    public init() {}
    
    public func products(for identifiers: Set<String>) async throws -> [any AppStoreProduct] {
        let products = try await Product.products(for: identifiers)
        // Products already conform to AppStoreProduct via our extension
        return products
    }
}
