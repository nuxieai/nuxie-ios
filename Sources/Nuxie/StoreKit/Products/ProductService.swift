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
    
    public func fetchProducts(for identifiers: Set<String>) async throws -> [any StoreProductProtocol] {
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

    // Experience-based helpers removed (JourneyDocument no longer carries explicit product lists)
}

private actor ProductRequestCoordinator {
    private struct PendingRequest {
        let id: UUID
        let identifiers: Set<String>
        let task: Task<[any StoreProductProtocol], Error>
    }

    private var cachedProducts: [String: any StoreProductProtocol] = [:]
    private var cachedProductOrder: [String] = []
    private var resolvedIdentifiers: Set<String> = []
    private var pendingByIdentifier: [String: PendingRequest] = [:]

    func products(
        for identifiers: Set<String>,
        provider: StoreKitProductProvider
    ) async throws -> [any StoreProductProtocol] {
        let missing = identifiers.subtracting(resolvedIdentifiers).filter {
            pendingByIdentifier[$0] == nil
        }
        if !missing.isEmpty {
            let requested = Set(missing)
            let pending = PendingRequest(
                id: UUID(),
                identifiers: requested,
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

        do {
            for pending in pendingRequests.values {
                let products = try await pending.task.value
                finish(pending, products: products)
            }
        } catch {
            for pending in pendingRequests.values {
                discard(pending)
            }
            throw error
        }

        try Task.checkCancellation()
        return cachedProductOrder.compactMap { identifier in
            guard identifiers.contains(identifier) else { return nil }
            return cachedProducts[identifier]
        }
    }

    private func finish(
        _ pending: PendingRequest,
        products: [any StoreProductProtocol]
    ) {
        guard pending.identifiers.contains(where: {
            pendingByIdentifier[$0]?.id == pending.id
        }) else { return }
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
