import Foundation

enum ExperienceTrustRootError: LocalizedError, Equatable {
    case unprovisioned(Environment)
    case malformed(Environment)

    var errorDescription: String? {
        switch self {
        case .unprovisioned(let environment):
            "No Nuxie package trust roots are provisioned for \(environment.rawValue)"
        case .malformed(let environment):
            "Nuxie package trust roots are malformed for \(environment.rawValue)"
        }
    }
}

/// Environment-scoped package authorization keys.
///
/// Production and staging slots deliberately fail closed until ops provisions
/// their public key material. They must never inherit the deterministic dev key.
enum ExperienceTrustRoots {
    private static let testOnlyDevKeyId = "TEST_ONLY_DEV_KEYPAIR"
    // TEST-ONLY: Ed25519 public key derived from the crate's [0x42; 32] seed.
    private static let testOnlyDevPublicKeyBase64 =
        "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI="

    static func keys(for environment: Environment) throws -> [ExperienceRuntimeAuthorizationKey] {
        switch environment {
        case .development:
            guard let bytes = Data(base64Encoded: testOnlyDevPublicKeyBase64),
                  bytes.count == 32 else {
                throw ExperienceTrustRootError.malformed(environment)
            }
            return [
                ExperienceRuntimeAuthorizationKey(
                    keyId: testOnlyDevKeyId,
                    ed25519PublicKeyBytes: bytes
                )
            ]
        case .staging:
            // Pending ops provisioning. A blank slot is intentionally fatal.
            throw ExperienceTrustRootError.unprovisioned(environment)
        case .production:
            // Pending ops provisioning. A blank slot is intentionally fatal.
            throw ExperienceTrustRootError.unprovisioned(environment)
        case .custom:
            throw ExperienceTrustRootError.unprovisioned(environment)
        }
    }
}
