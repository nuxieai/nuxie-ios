import Foundation

/// The authenticated Journey program executed on this device. Completion
/// produces an outcome report; continuation arrives in a later profile.
struct Journey {
    struct Step {
        enum Kind: String { case action, complete }
        let kind: Kind
        let id: String
        let action: [String: JourneyReleaseJSONValue]?
        let outlets: [String: String]?
        let outcome: String?
    }

    struct Route {
        struct Host {
            enum Kind: String { case journey, screen }
            let kind: Kind
            let screenId: String?
        }
        let host: Host
        let eventName: String
        let entryStepId: String
    }

    struct Screen {
        let id: String
        let defaultViewModelName: String?
        let defaultInstanceId: String?
        let responseCaptures: [String]
    }

    struct Reentry {
        enum Kind: String {
            case oneTime = "one_time", everyTime = "every_time", oncePerWindow = "once_per_window"
        }
        let type: Kind
        let windowSeconds: Int?
    }

    struct EntitlementGate {
        struct Product {
            let productId: String
            let featureIds: [String]
        }
        let enabled: Bool
        let products: [Product]
    }

    struct Boundary {
        let eventFields: [[String: JourneyReleaseJSONValue]]
        let responseFields: [[String: JourneyReleaseJSONValue]]
    }

    let schemaVersion: String
    let id: String
    let entryCondition: JourneyEntryCondition
    let entryStepId: String
    let steps: [Step]
    let routes: [Route]
    let screens: [Screen]
    let reentry: Reentry
    let entitlementGate: EntitlementGate
    let facts: JourneyFactReferences
    let inputs: Boundary
    let outputs: [[String: JourneyReleaseJSONValue]]
    let completionOutputs: [String: Boundary]
}

struct JourneyReleaseDescriptor {
    static let wireSchemaVersion = "nuxie.journey-release.v1"
    static let mediaType = "application/vnd.nuxie.journey+json"
    static let signatureDomain = "nuxie.journey-release.v1\u{0}"

    let schemaVersion: String
    let identity: JourneyReleaseIdentity
    let metadata: [String: JourneyReleaseJSONValue]
    let presentation: [String: JourneyReleaseJSONValue]
    let leg: Journey
    let products: [JourneyReleaseJSONValue]
    let placements: [JourneyReleaseJSONValue]
    let viewModelValues: [[String: JourneyReleaseJSONValue]]
    let screenBehaviors: [[String: JourneyReleaseJSONValue]]
    let render: [String: JourneyReleaseJSONValue]?
    let requirements: [String: JourneyReleaseJSONValue]?
    let provenance: [String: JourneyReleaseJSONValue]
}

struct AuthenticatedJourneyRelease {
    let authenticatedKeyID: String
    let exactDescriptorBytes: Data
    let descriptorSHA256: String
    let descriptor: JourneyReleaseDescriptor
    let publishedAtSeqToPromote: Int?
}

extension Journey: Codable, Sendable {}
extension Journey.Step: Codable, Sendable {}
extension Journey.Step.Kind: Codable, Sendable {}
extension Journey.Route: Codable, Sendable {}
extension Journey.Route.Host: Codable, Sendable {}
extension Journey.Route.Host.Kind: Codable, Sendable {}
extension Journey.Screen: Codable, Sendable {}
extension Journey.Reentry: Codable, Sendable {}
extension Journey.Reentry.Kind: Codable, Sendable {}
extension Journey.EntitlementGate: Codable, Sendable {}
extension Journey.EntitlementGate.Product: Codable, Sendable {}
extension Journey.Boundary: Codable, Sendable {}
extension JourneyReleaseDescriptor: Codable, Sendable {}
extension AuthenticatedJourneyRelease: Sendable {}
