import Foundation
import StoreKit

public class ProductService {
    private let productProvider: StoreKitProductProvider
    
    public init(productProvider: StoreKitProductProvider = DefaultStoreKitProductProvider()) {
        self.productProvider = productProvider
    }
    
    public func fetchProducts(for identifiers: Set<String>) async throws -> [any StoreProductProtocol] {
        guard !identifiers.isEmpty else {
            throw StoreKitError.apiMisuse(reason: "Product identifiers cannot be empty")
        }
        
        do {
            let products = try await productProvider.products(for: identifiers)
            
            if products.isEmpty {
                LogError("No products found for identifiers: \(identifiers)")
            }
            
            let fetchedIds = Set(products.map { $0.id })
            let missingIds = identifiers.subtracting(fetchedIds)
            
            if !missingIds.isEmpty {
                LogWarning("Some products not found: \(missingIds)")
            }
            
            return products
        } catch let error as StoreKitError {
            throw error
        } catch {
            throw StoreKitError.from(storeKit2Error: error)
        }
    }
    
    // Experience-based helpers removed (RemoteFlow no longer carries explicit product lists)
}
