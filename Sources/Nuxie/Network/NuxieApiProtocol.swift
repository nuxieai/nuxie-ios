import Foundation

struct ProfileCacheValidator: Codable, Equatable, Sendable {
    let rawValue: String
    let resourceScope: String?
    let authority: ProfileDeliveryAuthority?

    init(
        rawValue: String,
        resourceScope: String? = nil,
        authority: ProfileDeliveryAuthority? = nil
    ) {
        self.rawValue = rawValue
        self.resourceScope = resourceScope
        self.authority = authority
    }
}

enum ProfileFetchResult: Sendable {
    case modified(ProfileResponse, validator: ProfileCacheValidator?)
    case notModified
}

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
    func fetchProfile(
        for distinctId: String,
        locale: String?,
        revalidating validator: ProfileCacheValidator?
    ) async throws -> ProfileFetchResult
    func fetchProfileWithTimeout(for distinctId: String, locale: String?, timeout: TimeInterval) async throws -> ProfileResponse
}

extension ProfileFetching {
    func fetchProfile(
        for distinctId: String,
        locale: String?,
        revalidating validator: ProfileCacheValidator?
    ) async throws -> ProfileFetchResult {
        .modified(
            try await fetchProfile(for: distinctId, locale: locale),
            validator: nil
        )
    }
}

protocol FeatureChecking: AnyObject, Sendable {
    func checkFeature(
        customerId: String,
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult
}

protocol PurchaseSynchronizing: AnyObject, Sendable {
    func syncTransaction(
        transactionJwt: String,
        distinctId: String
    ) async throws -> PurchaseResponse
}

/// The atomic server command used when a verified App Store purchase has not
/// yet been reconciled and the customer immediately spends a metered grant.
protocol PurchaseBackedFeatureUsing: AnyObject, Sendable {
    func useFeatureWithPurchase(
        _ request: PurchaseBackedFeatureUseRequest
    ) async throws -> PurchaseBackedFeatureUseResponse
}

extension PurchaseBackedFeatureUsing {
    func useFeatureWithPurchase(
        _ request: PurchaseBackedFeatureUseRequest
    ) async throws -> PurchaseBackedFeatureUseResponse {
        _ = request
        throw NuxieNetworkError.invalidResponse
    }
}

protocol IntroEligibilityTokenRequesting: AnyObject, Sendable {
    func appStoreIntroEligibilityToken(
        distinctId: String,
        journeyId: String,
        experienceVersionId: String,
        legId: String,
        descriptorSha256: String,
        placementId: String,
        transactionId: String
    ) async throws -> String
}

extension IntroEligibilityTokenRequesting {
    func appStoreIntroEligibilityToken(
        distinctId: String,
        journeyId: String,
        experienceVersionId: String,
        legId: String,
        descriptorSha256: String,
        placementId: String,
        transactionId: String
    ) async throws -> String {
        throw StoreKitError.apiMisuse(
            reason: "App Store introductory eligibility signing is unavailable"
        )
    }
}

/// Composition-root convenience. Feature modules depend on the narrower
/// capability they use, while the concrete client implements every port.
protocol NuxieApiProtocol:
    EventTransport,
    ProfileFetching,
    FeatureChecking,
    PurchaseSynchronizing,
    PurchaseBackedFeatureUsing,
    IntroEligibilityTokenRequesting
{}
