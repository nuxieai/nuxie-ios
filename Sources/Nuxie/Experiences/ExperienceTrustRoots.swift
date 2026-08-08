import Foundation
import NuxieRuntimeSupport

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
/// Slots must never inherit the deterministic dev key. Pre-GA, staging,
/// preproduction, and production publishers share one Nuxie keypair; moving to
/// per-environment keys later is additive (add the new keys here, republish,
/// then drop the shared key).
enum ExperienceTrustRoots {
    private static let testOnlyDevKeyId = "TEST_ONLY_DEV_KEYPAIR"
    // TEST-ONLY: Ed25519 public key derived from the crate's [0x42; 32] seed.
    private static let testOnlyDevPublicKeyBase64 =
        "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI="

    private static let nuxieSharedKeyId = "nuxie-experience-2026-07"
    // Public half of the shared Nuxie publisher signing keypair (see
    // docs runbook: experience-manifest-signing). Staging/preproduction
    // publishes are signed with the same key pre-GA.
    private static let nuxieSharedPublicKeyBase64 =
        "tcoCFOAFJLj7A5LJ+T/jWfnvpgvmP7vhDoaHZitBpiY="

    static func keys(for environment: Environment) throws -> [ExperienceRuntimeAuthorizationKey] {
        switch environment {
        case .development:
            return [
                try key(id: testOnlyDevKeyId, base64: testOnlyDevPublicKeyBase64, environment: environment)
            ]
        case .staging, .production:
            return [
                try key(id: nuxieSharedKeyId, base64: nuxieSharedPublicKeyBase64, environment: environment)
            ]
        case .custom:
            // No provisioned trust roots for custom endpoints. Intentionally fatal.
            throw ExperienceTrustRootError.unprovisioned(environment)
        }
    }

    private static func key(
        id: String,
        base64: String,
        environment: Environment
    ) throws -> ExperienceRuntimeAuthorizationKey {
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else {
            throw ExperienceTrustRootError.malformed(environment)
        }
        return ExperienceRuntimeAuthorizationKey(
            keyId: id,
            ed25519PublicKeyBytes: bytes
        )
    }
}
