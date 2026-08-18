import Foundation
import StoreKit

// @unchecked Sendable: request/cache mutation is isolated in
// `ProductRequestCoordinator`; subclassable test mocks guard their own state.
class ProductService: @unchecked Sendable {
    private let productProvider: StoreKitProductProvider
    private let requestCoordinator = ProductRequestCoordinator()
    
    public init(productProvider: StoreKitProductProvider = DefaultStoreKitProductProvider()) {
        self.productProvider = productProvider
    }
    
    func fetchProducts(for identifiers: Set<String>) async throws -> [any AppStoreProduct] {
        guard !identifiers.isEmpty else {
            throw StoreKitError.apiMisuse(reason: "Product identifiers cannot be empty")
        }
        
        do {
            let products = try await requestCoordinator.products(
                for: identifiers,
                provider: productProvider
            )
            
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

    /// Makes the next presentation resolve fresh StoreKit product details.
    func invalidate(_ identifiers: Set<String>) async {
        await requestCoordinator.invalidate(identifiers)
    }

    // Experience-based helpers removed (JourneyDocument no longer carries explicit product lists)
}

private actor ProductRequestCoordinator {
    private struct PendingRequest {
        let id: UUID
        let identifiers: Set<String>
        let generation: Int
        let task: Task<[any AppStoreProduct], Error>
    }

    private var cachedProducts: [String: any AppStoreProduct] = [:]
    private var cachedProductOrder: [String] = []
    private var resolvedIdentifiers: Set<String> = []
    private var pendingByIdentifier: [String: PendingRequest] = [:]
    private var generationByIdentifier: [String: Int] = [:]

    func invalidate(_ identifiers: Set<String>) {
        for identifier in identifiers {
            cachedProducts[identifier] = nil
            resolvedIdentifiers.remove(identifier)
            generationByIdentifier[identifier, default: 0] += 1
        }
        cachedProductOrder.removeAll { identifiers.contains($0) }
    }

    func products(
        for identifiers: Set<String>,
        provider: StoreKitProductProvider
    ) async throws -> [any AppStoreProduct] {
        let missing = identifiers.subtracting(resolvedIdentifiers).filter { identifier in
            guard let pending = pendingByIdentifier[identifier] else { return true }
            return pending.generation < generationByIdentifier[identifier, default: 0]
        }
        if !missing.isEmpty {
            let requested = Set(missing)
            let pending = PendingRequest(
                id: UUID(),
                identifiers: requested,
                generation: requested.map { generationByIdentifier[$0, default: 0] }.max() ?? 0,
                task: Task { try await provider.products(for: requested) }
            )
            for identifier in requested {
                pendingByIdentifier[identifier] = pending
            }
        }

        var pendingRequests: [UUID: PendingRequest] = [:]
        for identifier in identifiers {
            if let pending = pendingByIdentifier[identifier] {
                pendingRequests[pending.id] = pending
            }
        }

        var directProducts: [String: any AppStoreProduct] = [:]
        do {
            for pending in pendingRequests.values {
                let products = try await pending.task.value
                for product in products where identifiers.contains(product.id) {
                    directProducts[product.id] = product
                }
                finish(pending, products: products)
            }
        } catch {
            for pending in pendingRequests.values {
                discard(pending)
            }
            throw error
        }

        try Task.checkCancellation()
        let orderedIdentifiers = cachedProductOrder.filter(identifiers.contains)
            + identifiers.filter { !cachedProductOrder.contains($0) }.sorted()
        return orderedIdentifiers.compactMap { identifier in
            cachedProducts[identifier] ?? directProducts[identifier]
        }
    }

    private func finish(
        _ pending: PendingRequest,
        products: [any AppStoreProduct]
    ) {
        let isCurrent = pending.identifiers.allSatisfy {
            pending.generation == generationByIdentifier[$0, default: 0]
        }
        guard isCurrent else { return }
        for product in products where cachedProducts[product.id] == nil {
            cachedProducts[product.id] = product
            cachedProductOrder.append(product.id)
        }
        resolvedIdentifiers.formUnion(pending.identifiers)
        discard(pending)
    }

    private func discard(_ pending: PendingRequest) {
        for identifier in pending.identifiers
        where pendingByIdentifier[identifier]?.id == pending.id {
            pendingByIdentifier[identifier] = nil
        }
    }
}
