import CryptoKit
import Foundation

struct FlowManifestSigningPublicKey: Equatable {
    let keyId: String
    let publicKeyBase64: String
}

enum FlowManifestSignatureVerificationResult: Equatable {
    case verified(keyId: String)
    case unsigned
    case rejected(reason: String)

    var allowsScripts: Bool {
        if case .verified = self {
            return true
        }
        return false
    }
}

struct FlowManifestSignatureVerifier {
    static let production = FlowManifestSignatureVerifier(
        keys: productionSigningKeys
    )

    private static let productionSigningKeys: [FlowManifestSigningPublicKey] = {
        var keys: [FlowManifestSigningPublicKey] = []

        #if DEBUG
        keys.append(
            FlowManifestSigningPublicKey(
                keyId: "nuxie-flow-debug-2026-07",
                publicKeyBase64: "+5TuOXqeKWmx8j4UCqQhjA7oP9PYe6hp28AR+HVrQMw="
            )
        )
        #endif

        return keys
    }()

    private let publicKeysById: [String: String]

    init(keys: [FlowManifestSigningPublicKey]) {
        publicKeysById = keys.reduce(into: [:]) { result, key in
            result[key.keyId] = key.publicKeyBase64
        }
    }

    func verify(manifestURL: URL, signatureURL: URL?) -> FlowManifestSignatureVerificationResult {
        guard let signatureURL,
              FileManager.default.fileExists(atPath: signatureURL.path) else {
            return .unsigned
        }

        do {
            let manifestBytes = try Data(contentsOf: manifestURL)
            let signatureBytes = try Data(contentsOf: signatureURL)
            let payload = try JSONDecoder().decode(ManifestSignaturePayload.self, from: signatureBytes)
            guard payload.version == 1 else {
                return .rejected(reason: "unsupported_version")
            }
            guard payload.signs == FlowArtifactStore.manifestPath else {
                return .rejected(reason: "unexpected_signed_payload")
            }
            guard payload.algorithm == "ed25519" else {
                return .rejected(reason: "unsupported_algorithm")
            }
            guard let publicKeyBase64 = publicKeysById[payload.keyId] else {
                return .rejected(reason: "unknown_key")
            }
            guard let publicKeyBytes = Data(base64Encoded: publicKeyBase64) else {
                return .rejected(reason: "invalid_public_key_base64")
            }
            guard let signature = Data(base64Encoded: payload.signatureBase64) else {
                return .rejected(reason: "invalid_signature_base64")
            }

            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
            guard publicKey.isValidSignature(signature, for: manifestBytes) else {
                return .rejected(reason: "signature_mismatch")
            }

            return .verified(keyId: payload.keyId)
        } catch {
            return .rejected(reason: "verification_error:\(error.localizedDescription)")
        }
    }
}

private struct ManifestSignaturePayload: Decodable {
    let version: Int
    let signs: String
    let algorithm: String
    let keyId: String
    let signatureBase64: String
}
