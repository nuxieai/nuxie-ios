import Foundation

protocol EventTransport: AnyObject, Sendable {
    func sendBatch(events: [BatchEventItem]) async throws -> BatchResponse

    func trackEvent(
        event: String,
        distinctId: String,
        properties: sending [String: Any]?,
        value: Double?,
        entityId: String?
    ) async throws -> EventResponse

    func trackEvent(_ event: NuxieEvent) async throws -> EventResponse
}

protocol ProfileFetching: AnyObject, Sendable {
    func fetchProfile(for distinctId: String, locale: String?) async throws -> ProfileResponse
    func fetchProfileWithTimeout(for distinctId: String, locale: String?, timeout: TimeInterval) async throws -> ProfileResponse
}

protocol FeatureChecking: AnyObject, Sendable {
    func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Int?,
        entityId: String?
    ) async throws -> FeatureCheckResult
}

protocol PurchaseSynchronizing: AnyObject, Sendable {
    func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse
}

protocol IntroEligibilityTokenRequesting: AnyObject, Sendable {
    func appStoreIntroEligibilityToken(
        distinctId: String,
        journeyId: String,
        experienceVersionId: String,
        placementId: String,
        transactionId: String
    ) async throws -> String
}

extension IntroEligibilityTokenRequesting {
    func appStoreIntroEligibilityToken(
        distinctId: String,
        journeyId: String,
        experienceVersionId: String,
        placementId: String,
        transactionId: String
    ) async throws -> String {
        throw StoreKitError.apiMisuse(
            reason: "App Store introductory eligibility signing is unavailable"
        )
    }
}

protocol ResponseWriting: AnyObject, Sendable {
    func setResponseField(
        distinctId: String,
        journeyId: String,
        responseSchemaId: String,
        schemaVersion: Int?,
        key: String,
        value: sending Any
    ) async throws -> ResponseWriteResponse

    func submitResponse(
        distinctId: String,
        journeyId: String,
        responseSchemaId: String,
        schemaVersion: Int?
    ) async throws -> ResponseSubmitResponse

    func abandonResponses(
        distinctId: String,
        journeyId: String
    ) async throws -> ResponseAbandonResponse
}

/// Composition-root convenience. Feature modules depend on the narrower
/// capability they use, while the concrete client implements every port.
protocol NuxieApiProtocol:
    EventTransport,
    ProfileFetching,
    FeatureChecking,
    PurchaseSynchronizing,
    IntroEligibilityTokenRequesting,
    ResponseWriting
{}
