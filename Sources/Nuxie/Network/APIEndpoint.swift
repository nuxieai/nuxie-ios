import Foundation

enum APIEndpoint {
    case profile(ProfileRequest)
    case event(EventRequest)
    case batch(BatchRequest)
    case checkFeature(FeatureCheckRequest)
    case responseSave
    case consumeFeature
    case purchase(PurchaseRequest)
    case appStoreIntroEligibility(AppStoreIntroEligibilityRequest)

    var path: String {
        switch self {
        case .responseSave:
            return "/responses/save"
        case .profile:
            return "/profile"
        case .event:
            return "/event"
        case .batch:
            return "/batch"
        case .checkFeature:
            return "/entitled"
        case .consumeFeature:
            return "/feature/consume"
        case .purchase:
            return "/purchase"
        case .appStoreIntroEligibility:
            return "/app-store/intro-eligibility"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .responseSave, .profile, .event, .batch, .checkFeature, .purchase, .appStoreIntroEligibility, .consumeFeature:
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
