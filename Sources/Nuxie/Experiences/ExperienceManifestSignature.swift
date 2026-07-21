import Foundation

/// Detached Nuxie signature over the exact `nuxie-manifest.json` bytes,
/// shipped as `nuxie-manifest.sig.json` in the flow artifact. The manifest
/// carries `flow.riv`'s sha256, so a valid signature transitively covers
/// every embedded script.
///
/// Swift retains this transport DTO only to select candidate validation
/// material. Rust validates the envelope shape, signature, signed bytes, and
/// key binding and is the sole authority that can enable script execution.
struct ExperienceManifestSignature: Codable, Equatable {
    static let artifactPath = "nuxie-manifest.sig.json"

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

    /// Test-only construction seam for custom validation keys.
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
        // Decoding selects candidate key material only. Unsupported envelope
        // metadata and invalid signatures deliberately still reach Rust, which
        // owns every authorization decision.
        let envelope = signatureEnvelopeBytes.flatMap {
            try? JSONDecoder().decode(ExperienceManifestSignature.self, from: $0)
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
