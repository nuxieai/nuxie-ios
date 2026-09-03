import CryptoKit
import Foundation

/// Opaque durable namespace for one transport-authenticated Nuxie app
/// environment. A rotatable publishable credential is not app identity and
/// never participates in the retained Journey address.
struct JourneyStorageScope: Equatable, Hashable, Sendable {
    private static let domain = "nuxie.journey-storage.v1\u{0}"

    private let namespaceHash: String

    init(authority: ProfileDeliveryAuthority) {
        namespaceHash = Self.digest(
            Self.domain + authority.environment + "\u{0}" + authority.appId
        )
    }

    init(namespaceHash: String) {
        self.namespaceHash = namespaceHash
    }

    static let testFixture = Self(namespaceHash: "test-fixture")

    func customerDigest(distinctId: String) -> String {
        Self.digest(Self.domain + namespaceHash + "\u{0}" + distinctId)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
