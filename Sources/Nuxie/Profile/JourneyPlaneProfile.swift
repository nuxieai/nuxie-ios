import Foundation

struct ArmedDeviceLeg {
    struct Reference {
        let experienceId: String
        let versionId: String
        let legId: String
        let descriptorSha256: String
    }
    struct Binding {
        enum Kind: String { case new; case continuation = "continue" }
        let type: Kind
        let journeyId: String?
        let generation: Int?
    }
    struct Context {
        let event: ExactJSONObject<ExperienceReleaseJSONValue>
        let responses: ExactJSONObject<ExperienceReleaseJSONValue>
    }
    let reference: Reference
    let binding: Binding
    let entryCondition: DeviceLegEntryCondition
    let context: Context
}

struct DeviceLegReleaseProfileEntry {
    struct Locator {
        let appId: String
        let environment: String
        let experienceId: String
        let experienceVersionId: String
        let versionNumber: Int
        let buildId: String
        let publishedAt: String
        let publishedAtSeq: Int
        let legId: String

        var identity: ExperienceReleaseIdentity {
            .init(appId: appId, environment: environment, experienceId: experienceId,
                  experienceVersionId: experienceVersionId, buildId: buildId,
                  versionNumber: versionNumber, publishedAt: publishedAt, publishedAtSeq: publishedAtSeq)
        }
    }
    let locator: Locator
    let envelope: ExperienceReleaseDescriptorEnvelope
}

/// Delivery state is separate from the immutable, authenticated local program.
/// Membership values are opaque facts; no segment definitions can be decoded.
struct JourneyPlaneProfile {
    fileprivate struct ArmKey { let reference: ArmedDeviceLeg.Reference; let binding: ArmedDeviceLeg.Binding }

    let schemaVersion: String
    let status: String
    let delivery: ExperienceReleaseDelivery
    let features: [Feature]
    let facts: DeviceLegFactTable
    let armedLegs: [ArmedDeviceLeg]
    let releases: [DeviceLegReleaseProfileEntry]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= ExperienceReleaseDescriptorLimits.profileBytes else { throw invalid }
        try StrictJSONDuplicateKeyValidator.validate(data)
        let root = try exact(JSONSerialization.jsonObject(with: data), ["schemaVersion", "status", "delivery", "features", "facts", "armedLegs", "releases"])
        guard root["schemaVersion"] as? String == "nuxie.journey-plane-profile.v1", root["status"] as? String == "ok" else { throw invalid }
        let facts = try exact(root["facts"], ["properties", "memberships", "assignments"])
        for (key, value) in try record(facts["properties"]) {
            try id(key)
            let property = try record(value)
            guard let present = property["present"] as? Bool else { throw invalid }
            _ = try exact(property, present ? ["present", "value"] : ["present"])
        }
        for key in try record(facts["memberships"]).keys { try id(key) }
        for (key, value) in try record(facts["assignments"]) {
            try id(key)
            if value is NSNull { continue }
            let assignment = try exact(value, ["variantId", "isHoldout"])
            try id(assignment["variantId"])
        }
        for value in try list(root["armedLegs"]) {
            let arm = try exact(value, ["reference", "binding", "entryCondition", "context"])
            let reference = try exact(arm["reference"], ["experienceId", "versionId", "legId", "descriptorSha256"])
            try id(reference["experienceId"]); try id(reference["versionId"])
            try digest(reference["legId"]); try digest(reference["descriptorSha256"])
            let binding = try record(arm["binding"])
            switch binding["type"] as? String {
            case "new": _ = try exact(binding, ["type"])
            case "continue":
                _ = try exact(binding, ["type", "journeyId", "generation"])
                guard let journey = binding["journeyId"] as? String,
                      journey.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-7[0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil,
                      let generation = binding["generation"] as? NSNumber,
                      CFGetTypeID(generation) != CFBooleanGetTypeID(), generation.doubleValue.rounded() == generation.doubleValue,
                      (0...9_007_199_254_740_991).contains(generation.doubleValue) else { throw invalid }
            default: throw invalid
            }
            try DeviceLegSchemaValidator.validateEntry(arm["entryCondition"])
            let context = try exact(arm["context"], ["event", "responses"])
            for key in ["event", "responses"] { for name in try record(context[key]).keys { try id(name) } }
        }
        for value in try list(root["releases"]) {
            let release = try exact(value, ["locator", "envelope"])
            let locator = try exact(release["locator"], ["appId", "environment", "experienceId", "experienceVersionId", "versionNumber", "buildId", "publishedAt", "publishedAtSeq", "legId"])
            try digest(locator["legId"])
            let envelope = try exact(release["envelope"], ["mediaType", "encoding", "descriptorSha256", "descriptorSizeBytes", "descriptorBytesBase64", "signature"])
            try digest(envelope["descriptorSha256"])
            _ = try exact(envelope["signature"], ["version", "algorithm", "keyId", "signatureBase64"])
            guard envelope["mediaType"] as? String == DeviceLegReleaseDescriptor.mediaType else { throw invalid }
        }
        let profile = try ExactJSONCodec.decode(Self.self, from: data)
        guard profile.armedLegs.count <= 1024, profile.releases.count <= 1024 else { throw invalid }
        for base in [profile.delivery.renderBaseUrl, profile.delivery.assetBaseUrl] {
            guard let url = URLComponents(string: base), url.url != nil,
                  url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty,
                  (url.user ?? "").isEmpty, (url.password ?? "").isEmpty,
                  (url.query ?? "").isEmpty, (url.fragment ?? "").isEmpty,
                  url.path.isEmpty || url.path.hasSuffix("/") else { throw invalid }
        }
        let verifier = ExperienceReleaseDescriptorVerifier()
        var releases: [String: DeviceLegReleaseProfileEntry] = [:]
        for release in profile.releases {
            try verifier.validateIdentity(release.locator.identity)
            try verifier.validateDeviceLegEnvelope(JSONEncoder().encode(release.envelope))
            guard releases.updateValue(release, forKey: release.envelope.descriptorSha256) == nil else { throw invalid }
        }
        var armKeys = Set<ArmKey>(), referenced = Set<String>()
        for arm in profile.armedLegs {
            guard let release = releases[arm.reference.descriptorSha256],
                  release.locator.legId == arm.reference.legId,
                  release.locator.experienceId == arm.reference.experienceId,
                  release.locator.experienceVersionId == arm.reference.versionId,
                  armKeys.insert(.init(reference: arm.reference, binding: arm.binding)).inserted else { throw invalid }
            referenced.insert(arm.reference.descriptorSha256)
        }
        guard referenced == Set(releases.keys) else { throw invalid }
        return profile
    }

    private static var invalid: ExperienceReleaseDescriptorAuthenticationError { .invalidDescriptor }
    private static func record(_ value: Any?) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw invalid }; return value
    }
    private static func list(_ value: Any?) throws -> [Any] {
        guard let value = value as? [Any] else { throw invalid }; return value
    }
    private static func exact(_ value: Any?, _ keys: Set<String>) throws -> [String: Any] {
        let value = try record(value)
        guard Set(value.keys) == keys else { throw invalid }; return value
    }
    private static func id(_ value: Any?) throws {
        guard let value = value as? String, !value.isEmpty, value.utf16.count <= 256 else { throw invalid }
    }
    private static func digest(_ value: Any?) throws {
        guard let value = value as? String, value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid }
    }
}

extension ArmedDeviceLeg: Codable, Sendable {}
extension ArmedDeviceLeg.Reference: Codable, Equatable, Hashable, Sendable {}
extension ArmedDeviceLeg.Binding: Codable, Equatable, Hashable, Sendable {}
extension ArmedDeviceLeg.Binding.Kind: Codable, Sendable {}
extension ArmedDeviceLeg.Context: Codable, Sendable {}
extension DeviceLegReleaseProfileEntry: Codable, Sendable {}
extension DeviceLegReleaseProfileEntry.Locator: Codable, Sendable {}
extension JourneyPlaneProfile: Codable, Sendable {}
extension JourneyPlaneProfile.ArmKey: Hashable {}
