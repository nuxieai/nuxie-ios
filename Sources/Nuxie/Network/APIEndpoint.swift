import Foundation

enum APIEndpoint {
    case profile(ProfileRequest)
    case event(EventRequest)
    case batch(BatchRequest)
    case checkFeature(FeatureCheckRequest)
    case purchase(PurchaseRequest)
    case appStoreIntroEligibility(AppStoreIntroEligibilityRequest)

    var path: String {
        switch self {
        case .profile:
            return "/profile"
        case .event:
            return "/event"
        case .batch:
            return "/batch"
        case .checkFeature:
            return "/entitled"
        case .purchase:
            return "/purchase"
        case .appStoreIntroEligibility:
            return "/app-store/intro-eligibility"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .profile, .event, .batch, .checkFeature, .purchase, .appStoreIntroEligibility:
            return .POST
        }
    }

    var isProfile: Bool {
        if case .profile = self { return true }
        return false
    }
}

enum HTTPMethod: String {
    case POST = "POST"
}
