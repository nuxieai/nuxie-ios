import Foundation

struct JourneyPackageAuthorizationKey: Equatable, Sendable {
    let keyID: String
    let ed25519PublicKeyBytes: Data
}

enum JourneyTrustRootError: LocalizedError, Equatable {
    case malformed(Environment)

    var errorDescription: String? {
        switch self {
        case .malformed(let environment):
            "Nuxie package trust roots are malformed for \(environment.rawValue)"
        }
    }
}

/// Environment-scoped package authorization keys.
///
/// Slots must never inherit the deterministic dev key. Staging and production
/// trust their own publisher keys.
enum JourneyTrustRoots {
    private static let testOnlyDevKeyId = "TEST_ONLY_DEV_KEYPAIR"
    // TEST-ONLY: Ed25519 public key derived from the crate's [0x42; 32] seed.
    private static let testOnlyDevPublicKeyBase64 =
        "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI="

    private static let nuxieSharedKeyId = "nuxie-experience-2026-07"
    // Public half of the shared Nuxie publisher signing keypair (see
    // docs runbook: experience-manifest-signing).
    private static let nuxieSharedPublicKeyBase64 =
        "tcoCFOAFJLj7A5LJ+T/jWfnvpgvmP7vhDoaHZitBpiY="

    private static let stagingKeyId = "nuxie-staging-2026-10-31"
    private static let stagingPublicKeyBase64 =
        "vI27ZxKfAvvqhjRgU5U51sMVlXcIOBURtZTFRFPsFTU="

    static func keys(for environment: Environment) throws -> [JourneyPackageAuthorizationKey] {
        switch environment {
        case .development:
            return [
                try key(id: testOnlyDevKeyId, base64: testOnlyDevPublicKeyBase64, environment: environment)
            ]
        case .staging:
            return [
                try key(id: stagingKeyId, base64: stagingPublicKeyBase64, environment: environment)
            ]
        case .production:
            return [
                try key(id: nuxieSharedKeyId, base64: nuxieSharedPublicKeyBase64, environment: environment)
            ]
        }
    }

    private static func key(
        id: String,
        base64: String,
        environment: Environment
    ) throws -> JourneyPackageAuthorizationKey {
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else {
            throw JourneyTrustRootError.malformed(environment)
        }
        return JourneyPackageAuthorizationKey(
            keyID: id,
            ed25519PublicKeyBytes: bytes
        )
    }
}
