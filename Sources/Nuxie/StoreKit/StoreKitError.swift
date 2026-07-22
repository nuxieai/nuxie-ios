import Foundation
import StoreKit

/// Unified StoreKit error with comprehensive taxonomy
public enum StoreKitError: LocalizedError, Equatable, Sendable {
    // MARK: - Configuration Errors
    case apiMisuse(reason: String)
    case notConfigured
    case invalidProductIdentifier(String)
    
    // MARK: - Product Errors
    case productNotFound(String)
    case productsRequestFailed(Error?)
    case noProductsAvailable
    
    // MARK: - Purchase Errors
    case purchaseFailed(Error?)
    case purchaseCancelled
    case purchasePending
    case purchaseNotAllowed
    case invalidReceipt
    case verificationFailed(String)
    
    // MARK: - Network Errors
    case networkUnavailable
    case serverError(statusCode: Int)
    case timeout
    
    // MARK: - Transaction Errors
    case transactionFailed(Error?)
    case transactionNotFound
    case restoreFailed(Error?)
    
    // MARK: - System Errors
    case storeKitNotAvailable
    case unknown(underlying: Error?)
    
    public var errorDescription: String? {
        switch self {
        case .apiMisuse(let reason):
            return "API Misuse: \(reason)"
        case .notConfigured:
            return "StoreKit service is not properly configured"
        case .invalidProductIdentifier(let identifier):
            return "Invalid product identifier: \(identifier)"
            
        case .productNotFound(let identifier):
            return "Product not found: \(identifier)"
        case .productsRequestFailed(let error):
            if let error = error {
                return "Products request failed: \(error.localizedDescription)"
            }
            return "Products request failed"
        case .noProductsAvailable:
            return "No products are currently available"
            
        case .purchaseFailed(let error):
            if let error = error {
                return "Purchase failed: \(error.localizedDescription)"
            }
            return "Purchase failed"
        case .purchaseCancelled:
            return "Purchase was cancelled by the user"
        case .purchasePending:
            return "Purchase is pending approval"
        case .purchaseNotAllowed:
            return "Purchases are not allowed on this device"
        case .invalidReceipt:
            return "Receipt validation failed - invalid receipt"
        case .verificationFailed(let reason):
            return "Verification failed: \(reason)"
            
        case .networkUnavailable:
            return "Network connection is not available"
        case .serverError(let statusCode):
            return "Server error: HTTP \(statusCode)"
        case .timeout:
            return "Request timed out"
            
        case .transactionFailed(let error):
            if let error = error {
                return "Transaction failed: \(error.localizedDescription)"
            }
            return "Transaction failed"
        case .transactionNotFound:
            return "Transaction not found"
        case .restoreFailed(let error):
            if let error = error {
                return "Restore purchases failed: \(error.localizedDescription)"
            }
            return "Restore purchases failed"
            
        case .storeKitNotAvailable:
            return "In-app purchases are not available on this device"
        case .unknown(let underlying):
            if let underlying = underlying {
                return "Unknown error: \(underlying.localizedDescription)"
            } else {
                return "An unknown error occurred"
            }
        }
    }
    
    /// Convert from StoreKit 2 errors
    public static func from(storeKit2Error error: Error) -> StoreKitError {
        // Check for common network errors
        if let nsError = error as NSError? {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return .networkUnavailable
            default:
                break
            }
        }
        
        return .unknown(underlying: error)
    }
    
    public static func == (lhs: StoreKitError, rhs: StoreKitError) -> Bool {
        switch (lhs, rhs) {
        // Configuration
        case (.apiMisuse(let r1), .apiMisuse(let r2)):
            return r1 == r2
        case (.notConfigured, .notConfigured):
            return true
        case (.invalidProductIdentifier(let id1), .invalidProductIdentifier(let id2)):
            return id1 == id2
            
        // Products
        case (.productNotFound(let id1), .productNotFound(let id2)):
            return id1 == id2
        case (.productsRequestFailed, .productsRequestFailed):
            return true
        case (.noProductsAvailable, .noProductsAvailable):
            return true
            
        // Purchase
        case (.purchaseFailed, .purchaseFailed):
            return true
        case (.purchaseCancelled, .purchaseCancelled):
            return true
        case (.purchasePending, .purchasePending):
            return true
        case (.purchaseNotAllowed, .purchaseNotAllowed):
            return true
        case (.invalidReceipt, .invalidReceipt):
            return true
        case (.verificationFailed(let r1), .verificationFailed(let r2)):
            return r1 == r2
            
        // Network
        case (.networkUnavailable, .networkUnavailable):
            return true
        case (.serverError(let code1), .serverError(let code2)):
            return code1 == code2
        case (.timeout, .timeout):
            return true
            
        // Transaction
        case (.transactionFailed, .transactionFailed):
            return true
        case (.transactionNotFound, .transactionNotFound):
            return true
        case (.restoreFailed, .restoreFailed):
            return true
            
        // System
        case (.storeKitNotAvailable, .storeKitNotAvailable):
            return true
        case (.unknown, .unknown):
            return true
            
        default:
            return false
        }
    }
}
