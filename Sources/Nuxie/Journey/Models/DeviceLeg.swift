import Foundation

/// A local program has no next-leg pointer, server body, ownership epoch, or
/// handoff operation. Its only boundary is an outcome report.
struct DeviceLeg {
    struct Step {
        enum Kind: String { case action, complete }
        let kind: Kind
        let id: String
        let action: [String: ExperienceReleaseJSONValue]?
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
        let eventFields: [[String: ExperienceReleaseJSONValue]]
        let responseFields: [[String: ExperienceReleaseJSONValue]]
    }

    let schemaVersion: String
    let id: String
    let entryCondition: DeviceLegEntryCondition
    let entryStepId: String
    let steps: [Step]
    let routes: [Route]
    let screens: [Screen]
    let reentry: Reentry
    let entitlementGate: EntitlementGate
    let facts: DeviceLegFactReferences
    let inputs: Boundary
    let outputs: [[String: ExperienceReleaseJSONValue]]
    let completionOutputs: [String: Boundary]
}

struct DeviceLegReleaseDescriptor {
    static let wireSchemaVersion = "nuxie.device-leg-release.v1"
    static let mediaType = "application/vnd.nuxie.device-leg+json"
    static let signatureDomain = "nuxie.device-leg-release.v1\u{0}"

    let schemaVersion: String
    let identity: ExperienceReleaseIdentity
    let metadata: [String: ExperienceReleaseJSONValue]
    let presentation: [String: ExperienceReleaseJSONValue]
    let leg: DeviceLeg
    let products: [ExperienceReleaseJSONValue]
    let placements: [ExperienceReleaseJSONValue]
    let viewModelValues: [[String: ExperienceReleaseJSONValue]]
    let screenBehaviors: [[String: ExperienceReleaseJSONValue]]
    let render: [String: ExperienceReleaseJSONValue]?
    let requirements: [String: ExperienceReleaseJSONValue]?
    let provenance: [String: ExperienceReleaseJSONValue]
}

struct AuthenticatedDeviceLegRelease {
    let authenticatedKeyID: String
    let exactDescriptorBytes: Data
    let descriptorSHA256: String
    let descriptor: DeviceLegReleaseDescriptor
    let publishedAtSeqToPromote: Int?
}

extension DeviceLeg: Codable, Sendable {}
extension DeviceLeg.Step: Codable, Sendable {}
extension DeviceLeg.Step.Kind: Codable, Sendable {}
extension DeviceLeg.Route: Codable, Sendable {}
extension DeviceLeg.Route.Host: Codable, Sendable {}
extension DeviceLeg.Route.Host.Kind: Codable, Sendable {}
extension DeviceLeg.Screen: Codable, Sendable {}
extension DeviceLeg.Reentry: Codable, Sendable {}
extension DeviceLeg.Reentry.Kind: Codable, Sendable {}
extension DeviceLeg.EntitlementGate: Codable, Sendable {}
extension DeviceLeg.EntitlementGate.Product: Codable, Sendable {}
extension DeviceLeg.Boundary: Codable, Sendable {}
extension DeviceLegReleaseDescriptor: Codable, Sendable {}
extension AuthenticatedDeviceLegRelease: Sendable {}
