import CryptoKit
import Foundation

/// Detached Nuxie signature over the exact `nuxie-manifest.json` bytes,
/// shipped as `nuxie-manifest.sig.json` in the flow artifact. The manifest
/// carries `flow.riv`'s sha256, so a valid signature transitively covers
/// every embedded script. Device script execution is enabled only for
/// artifacts whose signature verifies against a pinned Nuxie public key —
/// `allowsUnverifiedScripts` on the Rive script runtime is just the
/// low-level escape hatch; this gate is what decides.
struct FlowManifestSignature: Codable, Equatable {
    let version: Int
    let signs: String
    let algorithm: String
    let keyId: String
    let signatureBase64: String
}

enum FlowManifestSignatureVerifier {
    static let signaturePath = "nuxie-manifest.sig.json"

    /// Pinned Nuxie manifest-signing public keys (raw 32-byte Ed25519,
    /// base64) by keyId. Rotation = ship a new SDK release with the new key
    /// added; old keys stay until every artifact signed by them is gone.
    ///
    /// Empty until the production keypair is provisioned
    /// (`NUXIE_FLOW_MANIFEST_SIGNING_KEY`/`_KEY_ID` on the publish worker);
    /// with no pinned keys every artifact verifies false and device scripts
    /// stay disabled — the safe default.
    static let productionPublicKeysBase64ByKeyId: [String: String] = [:]

    /// Verifies `signatureData` (the `nuxie-manifest.sig.json` bytes)
    /// against `manifestData` (the exact `nuxie-manifest.json` bytes).
    /// Any malformed input, unknown key, wrong algorithm, or signature
    /// mismatch verifies false — never throws, never crashes a paywall.
    static func verify(
        manifestData: Data,
        signatureData: Data,
        publicKeysBase64ByKeyId: [String: String] = productionPublicKeysBase64ByKeyId
    ) -> Bool {
        guard
            let signature = try? JSONDecoder().decode(
                FlowManifestSignature.self,
                from: signatureData
            )
        else {
            LogWarning("Flow manifest signature file failed to decode")
            return false
        }
        guard
            signature.version == 1,
            signature.signs == "nuxie-manifest.json",
            signature.algorithm == "ed25519"
        else {
            LogWarning(
                "Flow manifest signature has unsupported shape: version=\(signature.version) signs=\(signature.signs) algorithm=\(signature.algorithm)"
            )
            return false
        }
        guard let publicKeyBase64 = publicKeysBase64ByKeyId[signature.keyId] else {
            LogWarning("Flow manifest signature key \(signature.keyId) is not pinned")
            return false
        }
        guard
            let publicKeyData = Data(base64Encoded: publicKeyBase64),
            let signatureBytes = Data(base64Encoded: signature.signatureBase64),
            let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyData
            )
        else {
            LogWarning("Flow manifest signature key material failed to decode")
            return false
        }
        return publicKey.isValidSignature(signatureBytes, for: manifestData)
    }
}
