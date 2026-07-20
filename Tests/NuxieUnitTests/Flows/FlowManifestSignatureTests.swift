import CryptoKit
import Foundation
import Nimble
import Quick
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

    private func verify(
        manifestData: Data,
        signatureData: Data,
        keyring: [String: String]
    ) -> Bool {
        let evidence = FlowScriptTrustPolicy.ephemeral(
            publicKeysBase64ByKeyId: keyring
        ).evidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: signatureData
        )
        return FlowManifestSignatureVerifier.verify(evidence: evidence)
    }

    func testVerifiesValidSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)

        XCTAssertTrue(
            verify(
                manifestData: manifestData,
                signatureData: signatureData,
                keyring: keyring(for: key)
            )
        )
    }

    func testRejectsTamperedManifestBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)
        let tampered = Data("{\"version\":1,\"riv\":{\"sha256\":\"def\"}}".utf8)

        XCTAssertFalse(
            verify(
                manifestData: tampered,
                signatureData: signatureData,
                keyring: keyring(for: key)
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
            verify(
                manifestData: manifestData,
                signatureData: signatureData,
                keyring: keyring(for: key)
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
            verify(
                manifestData: manifestData,
                signatureData: signatureData,
                keyring: keyring(for: pinnedKey)
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
                verify(
                    manifestData: manifestData,
                    signatureData: signatureData,
                    keyring: keyring(for: key)
                )
            )
        }
    }

    func testDefaultsToNoPinnedKeys() throws {
        // Until the production keypair is provisioned the keyring is empty:
        // every artifact verifies false and device scripts stay disabled.
        let key = Curve25519.Signing.PrivateKey()
        let signatureData = try makeSignature(privateKey: key, over: manifestData)

        let evidence = FlowScriptTrustPolicy.production.evidence(
            signedContentBytes: manifestData,
            signatureEnvelopeBytes: signatureData
        )
        XCTAssertFalse(FlowManifestSignatureVerifier.verify(evidence: evidence))
    }
}

final class FlowScriptTrustPolicyTests: QuickSpec {
    override class func spec() {
        let manifestData = Data(
            "{\"version\":1,\"riv\":{\"sha256\":\"abc\"}}".utf8
        )

        func makeSignature(
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

        func keyring(
            for privateKey: Curve25519.Signing.PrivateKey,
            keyId: String = "test-key-1"
        ) -> [String: String] {
            [keyId: privateKey.publicKey.rawRepresentation.base64EncodedString()]
        }

        describe("FlowScriptTrustPolicy") {
            it("preserves exact evidence and selects a known Nuxie key") {
                let key = Curve25519.Signing.PrivateKey()
                let signatureData = try makeSignature(privateKey: key, over: manifestData)
                let trustPolicy = FlowScriptTrustPolicy.ephemeral(
                    publicKeysBase64ByKeyId: keyring(for: key)
                )

                let evidence = trustPolicy.evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: signatureData
                )

                expect(evidence.signedContentBytes).to(equal(manifestData))
                expect(evidence.signatureEnvelopeBytes).to(equal(signatureData))
                expect(evidence.selectedKey?.keyId).to(equal("test-key-1"))
                expect(evidence.selectedKey?.ed25519PublicKeyBytes)
                    .to(equal(key.publicKey.rawRepresentation))
            }

            it("uses the preserved evidence for legacy verification") {
                let key = Curve25519.Signing.PrivateKey()
                let signatureData = try makeSignature(privateKey: key, over: manifestData)
                let evidence = FlowScriptTrustPolicy.ephemeral(
                    publicKeysBase64ByKeyId: keyring(for: key)
                ).evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: signatureData
                )

                expect(FlowManifestSignatureVerifier.verify(evidence: evidence)).to(beTrue())
            }

            it("selects a known key without preauthorizing the envelope shape") {
                let key = Curve25519.Signing.PrivateKey()
                let unsupportedEnvelope = try makeSignature(
                    privateKey: key,
                    over: manifestData,
                    version: 99,
                    signs: "different-content",
                    algorithm: "different-algorithm"
                )
                let evidence = FlowScriptTrustPolicy.ephemeral(
                    publicKeysBase64ByKeyId: keyring(for: key)
                ).evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: unsupportedEnvelope
                )

                expect(evidence.selectedKey?.keyId).to(equal("test-key-1"))
                expect(FlowManifestSignatureVerifier.verify(evidence: evidence)).to(beFalse())
            }

            it("preserves a malformed envelope without selecting a key") {
                let malformedEnvelope = Data("{not-json".utf8)
                let evidence = FlowScriptTrustPolicy.ephemeral(
                    publicKeysBase64ByKeyId: [
                        "test-key-1": Data(repeating: 7, count: 32).base64EncodedString()
                    ]
                ).evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: malformedEnvelope
                )

                expect(evidence.signatureEnvelopeBytes).to(equal(malformedEnvelope))
                expect(evidence.selectedKey).to(beNil())
                expect(FlowManifestSignatureVerifier.verify(evidence: evidence)).to(beFalse())
            }

            it("does not select invalid configured keys") {
                let signingKey = Curve25519.Signing.PrivateKey()
                let signatureData = try makeSignature(
                    privateKey: signingKey,
                    over: manifestData
                )
                for invalidKey in [
                    "not-base64",
                    Data(repeating: 1, count: 31).base64EncodedString(),
                ] {
                    let evidence = FlowScriptTrustPolicy.ephemeral(
                        publicKeysBase64ByKeyId: ["test-key-1": invalidKey]
                    ).evidence(
                        signedContentBytes: manifestData,
                        signatureEnvelopeBytes: signatureData
                    )

                    expect(evidence.selectedKey).to(beNil())
                    expect(FlowManifestSignatureVerifier.verify(evidence: evidence)).to(beFalse())
                }
            }
        }
    }
}
