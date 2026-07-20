import Foundation

// MARK: - Client-Side Flow Model

/// Client-side flow model that enriches RemoteFlow with local state and product data
public struct Flow {
    // IMPORTANT: RemoteFlow is immutable server data - never modify
    public let remoteFlow: RemoteFlow              // Original data from API
    
    // Client-side enrichments
    public var products: [FlowProduct]         // Products fetched from StoreKit
    
    // Convenience accessors proxy to remoteFlow for common properties
    public var id: String { remoteFlow.id }
    public var name: String { remoteFlow.id }
    public var manifest: BuildManifest { remoteFlow.flowArtifact.manifest }
    public var url: String { remoteFlow.flowArtifact.url }
    
    public init(
        remoteFlow: RemoteFlow,
        products: [FlowProduct] = []
    ) {
        self.remoteFlow = remoteFlow
        self.products = products
    }
}

// MARK: - Close Reason

public enum CloseReason: Equatable {
    case userDismissed
    case goalMet
    case purchaseCompleted
    case timeout
    case error(Error)
    
    public static func == (lhs: CloseReason, rhs: CloseReason) -> Bool {
        switch (lhs, rhs) {
        case (.userDismissed, .userDismissed),
             (.goalMet, .goalMet),
             (.purchaseCompleted, .purchaseCompleted),
             (.timeout, .timeout):
            return true
        case let (.error(e1), .error(e2)):
            return (e1 as NSError) == (e2 as NSError)
        default:
            return false
        }
    }
}

// MARK: - Product Period

public enum ProductPeriod: String, Codable, Equatable {
    case week
    case month
    case year
    case lifetime
}

// MARK: - Flow Product

/// Product with StoreKit data and flow metadata
public struct FlowProduct: Equatable, Codable {
    public let id: String
    public let name: String
    public let price: String  // Formatted price string (e.g., "$9.99")
    public let period: ProductPeriod?
}

// MARK: - Flow Cache Key

/// Cache key for flows (plain id — variant/segment dimensions were never used)
public struct FlowCacheKey: Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}
