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

/// Sealed Nuxie-owned policy used only to select validation material.
///
/// Host apps cannot replace the production key ring. Deterministic tests use
/// the explicitly named ephemeral factory; production code has no generic
/// key-registration surface and no Boolean script bypass.
struct FlowScriptTrustPolicy: Sendable {
    static let production = FlowScriptTrustPolicy(
        publicKeysBase64ByKeyId: FlowScriptProductionTrustRoots.publicKeysBase64ByKeyId
    )

    private let publicKeyBytesByKeyId: [String: Data]

    private init(publicKeysBase64ByKeyId: [String: String]) {
        publicKeyBytesByKeyId = publicKeysBase64ByKeyId.reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty,
                  let bytes = Data(base64Encoded: entry.value),
                  bytes.count == 32 else {
                LogWarning("Ignored invalid Nuxie manifest-signing public key \(entry.key)")
                return
            }
            result[entry.key] = bytes
        }
    }

    /// Test-only construction seam for generated, process-local keypairs.
    ///
    /// This remains internal to the SDK module, so embedding applications
    /// cannot replace Nuxie's trust roots.
    static func ephemeral(
        publicKeysBase64ByKeyId: [String: String]
    ) -> Self {
        Self(publicKeysBase64ByKeyId: publicKeysBase64ByKeyId)
    }

    func evidence(
        signedContentBytes: Data,
        signatureEnvelopeBytes: Data?
    ) -> FlowRuntimeAuthorizationEvidence {
        let envelope = signatureEnvelopeBytes.flatMap {
            try? JSONDecoder().decode(FlowManifestSignature.self, from: $0)
        }
        let selectedKey = envelope.flatMap { envelope -> FlowRuntimeAuthorizationKey? in
            guard let bytes = publicKeyBytesByKeyId[envelope.keyId] else {
                return nil
            }
            return FlowRuntimeAuthorizationKey(
                keyId: envelope.keyId,
                ed25519PublicKeyBytes: bytes
            )
        }

        return FlowRuntimeAuthorizationEvidence(
            signedContentBytes: signedContentBytes,
            signatureEnvelopeBytes: signatureEnvelopeBytes,
            selectedKey: selectedKey
        )
    }
}

private enum FlowScriptProductionTrustRoots {
    /// Pinned Nuxie manifest-signing public keys (raw 32-byte Ed25519,
    /// base64) by key ID. Rotation is add-before-remove in an SDK release.
    ///
    /// Intentionally empty until the publisher keypair and client roots are
    /// provisioned. The safe production result is therefore visual-only.
    static let publicKeysBase64ByKeyId: [String: String] = [:]
}

enum FlowManifestSignatureVerifier {
    static let signaturePath = "nuxie-manifest.sig.json"

    /// Transitional verification for the Rive-backed reference path.
    ///
    /// Native import receives this evidence directly and independently
    /// validates it in Rust; this method must never become a trusted Boolean
    /// supplied to the native runtime.
    static func verify(evidence: FlowRuntimeAuthorizationEvidence) -> Bool {
        guard let signatureData = evidence.signatureEnvelopeBytes else {
            return false
        }
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
                "Flow manifest signature has unsupported shape: "
                    + "version=\(signature.version) signs=\(signature.signs) "
                    + "algorithm=\(signature.algorithm)"
            )
            return false
        }
        guard let selectedKey = evidence.selectedKey,
              selectedKey.keyId == signature.keyId else {
            LogWarning("Flow manifest signature key \(signature.keyId) is not pinned")
            return false
        }
        guard
            let signatureBytes = Data(base64Encoded: signature.signatureBase64),
            let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: selectedKey.ed25519PublicKeyBytes
            )
        else {
            LogWarning("Flow manifest signature key material failed to decode")
            return false
        }
        return publicKey.isValidSignature(
            signatureBytes,
            for: evidence.signedContentBytes
        )
    }
}
