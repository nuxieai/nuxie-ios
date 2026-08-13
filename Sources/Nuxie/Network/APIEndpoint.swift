import Foundation

enum APIEndpoint {
    case profile(ProfileRequest)
    case event(EventRequest)
    case batch(BatchRequest)
    case experienceVersion(experienceId: String, versionId: String)
    case checkFeature(FeatureCheckRequest)
    case purchase(PurchaseRequest)
    case responseField(ResponseFieldRequest)
    case responseSubmit(ResponseSubmitRequest)
    case responseAbandon(ResponseAbandonRequest)

    var path: String {
        switch self {
        case .profile:
            return "/profile"
        case .event:
            return "/event"
        case .batch:
            return "/batch"
        case let .experienceVersion(experienceId, versionId):
            return "/experiences/\(experienceId)/versions/\(versionId)"
        case .checkFeature:
            return "/entitled"
        case .purchase:
            return "/purchase"
        case .responseField:
            return "/response/field"
        case .responseSubmit:
            return "/response/submit"
        case .responseAbandon:
            return "/response/abandon"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .profile, .event, .batch, .checkFeature, .purchase, .responseField, .responseSubmit, .responseAbandon:
            return .POST
        case .experienceVersion:
            return .GET
        }
    }

    var authMethod: AuthMethod {
        switch self {
        case .profile, .event, .batch, .checkFeature, .purchase, .responseField, .responseSubmit, .responseAbandon:
            return .apiKeyInBody
        case .experienceVersion:
            return .apiKeyInQuery
        }
    }

    var isProfile: Bool {
        if case .profile = self { return true }
        return false
    }
}

enum HTTPMethod: String {
    case GET = "GET"
    case POST = "POST"
}

enum AuthMethod {
    case apiKeyInBody
    case apiKeyInQuery
}
