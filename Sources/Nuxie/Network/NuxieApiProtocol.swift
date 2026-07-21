import Foundation

/// Protocol defining the API interface for Nuxie SDK
public protocol NuxieApiProtocol: AnyObject {
    /// Send batch of events
    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse

    /// Fetch user profile with optional locale for server-side content resolution
    func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse

    /// Fetch user profile with custom timeout
    func fetchProfileWithTimeout(for distinctId: String, locale: String?, timeout: TimeInterval) async throws -> ProfileResponse

    /// Fetch flow description by ID
    func fetchExperience(flowId: String) async throws -> RemoteFlow

    /// Track a single event
    func trackEvent(
        event: String,
        distinctId: String,
        properties: [String: Any]?,
        value: Double?,
        entityId: String?
    ) async throws -> EventResponse

    /// Check feature access for a customer
    func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async throws -> FeatureCheckResult

    /// Sync an App Store transaction with the backend
    /// - Parameters:
    ///   - transactionJwt: The signed transaction JWT from StoreKit 2
    ///   - distinctId: The user's distinct ID
    /// - Returns: PurchaseResponse with updated features
    func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse

    func setResponseField(
        distinctId: String,
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: Any
    ) async throws -> ResponseWriteResponse

    func submitResponse(
        distinctId: String,
        journeySessionId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    ) async throws -> ResponseSubmitResponse

    func abandonResponses(
        distinctId: String,
        journeySessionId: String
    ) async throws -> ResponseAbandonResponse
}
