import CryptoKit
import Foundation
import XCTest

@testable import Nuxie

final class FlowManifestSignatureTests: XCTestCase {
    private let manifestData = Data(
        "{\"version\":1,\"riv\":{\"sha256\":\"abc\"}}".utf8
    )

    private func makeSignature(
        privateKey: Curve25519.Signing.PrivateKey,
        over data: Data,
        keyId: String = "test-key-1",
        version: Int = 1,
        signs: String = "nuxie-manifest.json",
        algorithm: String = "ed25519"
    ) throws -> Data {
        let signature = try privateKey.signature(for: data)
        return try JSONEncoder().encode(
            FlowManifestSignature(
                version: version,
                signs: signs,
                algorithm: algorithm,
                keyId: keyId,
                signatureBase64: signature.base64EncodedString()
            )
        )
    }

    private func keyring(
        for privateKey: Curve25519.Signing.PrivateKey,
        keyId: String = "test-key-1"
    ) -> [String: String] {
        [keyId: privateKey.publicKey.rawRepresentation.base64EncodedString()]
    }

    func testPreservesExactEvidenceAndSelectsKnownNuxieKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)
        let trustStore = FlowScriptTrustStore(
            publicKeysBase64ByKeyId: keyring(for: key)
        )

        let evidence = trustStore.evidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: signatureData
        )

        XCTAssertEqual(evidence.signedContentBytes, manifestData)
        XCTAssertEqual(evidence.signatureEnvelopeBytes, signatureData)
        XCTAssertEqual(evidence.selectedKey?.keyId, "test-key-1")
        XCTAssertEqual(
            evidence.selectedKey?.ed25519PublicKeyBytes,
            key.publicKey.rawRepresentation
        )
    }

    func testLegacyVerificationConsumesThePreservedEvidence() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)
        let evidence = FlowScriptTrustStore(
            publicKeysBase64ByKeyId: keyring(for: key)
        ).evidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: signatureData
        )

        XCTAssertTrue(FlowManifestSignatureVerifier.verify(evidence: evidence))
    }

    func testSelectsKnownKeyWithoutPreauthorizingEnvelopeShape() throws {
        let key = Curve25519.Signing.PrivateKey()
        let unsupportedEnvelope = try makeSignature(
            privateKey: key,
            over: manifestData,
            version: 99,
            signs: "different-content",
            algorithm: "different-algorithm"
        )
        let evidence = FlowScriptTrustStore(
            publicKeysBase64ByKeyId: keyring(for: key)
        ).evidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: unsupportedEnvelope
        )

        XCTAssertEqual(evidence.selectedKey?.keyId, "test-key-1")
        XCTAssertFalse(FlowManifestSignatureVerifier.verify(evidence: evidence))
    }

    func testPreservesMalformedEnvelopeWithoutSelectingAKey() {
        let malformedEnvelope = Data("{not-json".utf8)
        let evidence = FlowScriptTrustStore(
            publicKeysBase64ByKeyId: [
                "test-key-1": Data(repeating: 7, count: 32).base64EncodedString()
            ]
        ).evidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: malformedEnvelope
        )

        XCTAssertEqual(evidence.signatureEnvelopeBytes, malformedEnvelope)
        XCTAssertNil(evidence.selectedKey)
        XCTAssertFalse(FlowManifestSignatureVerifier.verify(evidence: evidence))
    }

    func testInvalidConfiguredKeysCannotBeSelected() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(
            privateKey: signingKey,
            over: manifestData
        )
        for invalidKey in [
            "not-base64",
            Data(repeating: 1, count: 31).base64EncodedString(),
        ] {
            let evidence = FlowScriptTrustStore(
                publicKeysBase64ByKeyId: ["test-key-1": invalidKey]
            ).evidence(
                signedContentBytes: manifestData,
                signatureEnvelopeBytes: signatureData
            )

            XCTAssertNil(evidence.selectedKey)
            XCTAssertFalse(FlowManifestSignatureVerifier.verify(evidence: evidence))
        }
    }

    func testVerifiesValidSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)

        XCTAssertTrue(
            FlowManifestSignatureVerifier.verify(
                manifestData: manifestData,
                signatureData: signatureData,
                publicKeysBase64ByKeyId: keyring(for: key)
            )
        )
    }

    func testRejectsTamperedManifestBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)
        let tampered = Data("{\"version\":1,\"riv\":{\"sha256\":\"def\"}}".utf8)

        XCTAssertFalse(
            FlowManifestSignatureVerifier.verify(
                manifestData: tampered,
                signatureData: signatureData,
                publicKeysBase64ByKeyId: keyring(for: key)
            )
        )
    }

    func testRejectsUnpinnedKeyId() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(
            privateKey: key,
            over: manifestData,
            keyId: "rogue-key"
        )

        XCTAssertFalse(
            FlowManifestSignatureVerifier.verify(
                manifestData: manifestData,
                signatureData: signatureData,
                publicKeysBase64ByKeyId: keyring(for: key)
            )
        )
    }

    func testRejectsWrongKeySignature() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let pinnedKey = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(
            privateKey: signingKey,
            over: manifestData
        )

        XCTAssertFalse(
            FlowManifestSignatureVerifier.verify(
                manifestData: manifestData,
                signatureData: signatureData,
                publicKeysBase64ByKeyId: keyring(for: pinnedKey)
            )
        )
    }

    func testRejectsUnsupportedShape() throws {
        let key = Curve25519.Signing.PrivateKey()
        for signatureData in [
            try makeSignature(privateKey: key, over: manifestData, version: 2),
            try makeSignature(
                privateKey: key,
                over: manifestData,
                signs: "flow.riv"
            ),
            try makeSignature(
                privateKey: key,
                over: manifestData,
                algorithm: "hmac"
            ),
            Data("not json".utf8),
        ] {
            XCTAssertFalse(
                FlowManifestSignatureVerifier.verify(
                    manifestData: manifestData,
                    signatureData: signatureData,
                    publicKeysBase64ByKeyId: keyring(for: key)
                )
            )
        }
    }

    func testDefaultsToNoPinnedKeys() throws {
        // Until the production keypair is provisioned the keyring is empty:
        // every artifact verifies false and device scripts stay disabled.
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)

        XCTAssertFalse(
            FlowManifestSignatureVerifier.verify(
                manifestData: manifestData,
                signatureData: signatureData
            )
        )
    }
}
