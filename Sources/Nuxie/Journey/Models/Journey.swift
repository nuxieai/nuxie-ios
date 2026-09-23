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

    struct Duration: Codable, Sendable {
        enum Unit: String, Codable, Sendable {
            case minute, hour, day, week
            var seconds: Int {
                switch self {
                case .minute: return 60
                case .hour: return 3_600
                case .day: return 86_400
                case .week: return 604_800
                }
            }
        }
        let amount: Int
        let unit: Unit
        var seconds: Int? {
            let result = amount.multipliedReportingOverflow(by: unit.seconds)
            return amount > 0 && !result.overflow ? result.partialValue : nil
        }
    }

    struct Frequency: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case oneTime = "one_time", everyMatch = "every_match", oncePerWindow = "once_per_window"
        }
        let type: Kind
        let window: Duration?
        var windowSeconds: Int? { window?.seconds }
    }

    struct Policy: Codable, Sendable {
        struct Entry: Codable, Sendable {
            let trigger: [String: JourneyReleaseJSONValue]
            let eligibility: [String: JourneyReleaseJSONValue]?
            let frequency: Frequency
        }
        let entry: Entry
        let goal: [String: JourneyReleaseJSONValue]?
        let exitWhenAny: [[String: JourneyReleaseJSONValue]]
    }

    struct Offer: Codable, Sendable {
        static let alreadyEntitledEvent = "$offer_already_entitled"
        static let accessUnknownEvent = "$offer_access_unknown"
        let screenId: String
        let placementIds: [String]
        let alreadyEntitledStepId: String
        let unknownStepId: String
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
    let policy: Policy
    let offers: [Offer]
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
extension Journey.Boundary: Codable, Sendable {}
extension JourneyReleaseDescriptor: Codable, Sendable {}
extension AuthenticatedJourneyRelease: Sendable {}
