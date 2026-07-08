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
