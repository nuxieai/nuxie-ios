import CryptoKit
import Foundation

/// Opaque durable namespace for one configured Nuxie app environment. The
/// publishable credential is never written to disk. Changing credentials or
/// environment intentionally fails closed instead of replaying another
/// setup's retained device-leg authority.
struct DeviceLegStorageScope: Equatable, Hashable, Sendable {
    private static let domain = "nuxie.device-leg-storage.v1\u{0}"

    private let namespaceHash: String

    init(apiKey: String, environment: Environment) {
        namespaceHash = Self.digest(
            Self.domain + environment.rawValue + "\u{0}" + apiKey
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
