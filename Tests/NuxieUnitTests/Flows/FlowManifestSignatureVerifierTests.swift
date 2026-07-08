import CryptoKit
import Foundation
@testable import Nuxie
import XCTest

final class FlowManifestSignatureVerifierTests: XCTestCase {
    private let keyId = "test-key"
    private let privateKeySeedBase64 = "uxhUz+nmwpT6r2IL8bdnFKZ4nVsJIytE9uLyCY3BXWg="
    private let publicKeyBase64 = "+5TuOXqeKWmx8j4UCqQhjA7oP9PYe6hp28AR+HVrQMw="

    func testVerifiesDetachedSignatureOverExactManifestBytes() throws {
        let fixture = try writeSignedManifest()
        let verifier = FlowManifestSignatureVerifier(
            keys: [
                FlowManifestSigningPublicKey(
                    keyId: keyId,
                    publicKeyBase64: publicKeyBase64
                )
            ]
        )

        XCTAssertEqual(
            verifier.verify(
                manifestURL: fixture.manifestURL,
                signatureURL: fixture.signatureURL
            ),
            .verified(keyId: keyId)
        )
    }

    func testUnsignedManifestDoesNotAllowScripts() throws {
        let fixture = try writeSignedManifest()
        let verifier = FlowManifestSignatureVerifier(
            keys: [
                FlowManifestSigningPublicKey(
                    keyId: keyId,
                    publicKeyBase64: publicKeyBase64
                )
            ]
        )

        XCTAssertEqual(
            verifier.verify(manifestURL: fixture.manifestURL, signatureURL: nil),
            .unsigned
        )
    }

    func testRejectsTamperedManifestBytes() throws {
        let fixture = try writeSignedManifest()
        try Data(#"{"version":1,"flowId":"tampered"}"#.utf8).write(to: fixture.manifestURL)
        let verifier = FlowManifestSignatureVerifier(
            keys: [
                FlowManifestSigningPublicKey(
                    keyId: keyId,
                    publicKeyBase64: publicKeyBase64
                )
            ]
        )

        XCTAssertEqual(
            verifier.verify(
                manifestURL: fixture.manifestURL,
                signatureURL: fixture.signatureURL
            ),
            .rejected(reason: "signature_mismatch")
        )
    }

    func testRejectsUnknownKey() throws {
        let fixture = try writeSignedManifest()
        let verifier = FlowManifestSignatureVerifier(keys: [])

        XCTAssertEqual(
            verifier.verify(
                manifestURL: fixture.manifestURL,
                signatureURL: fixture.signatureURL
            ),
            .rejected(reason: "unknown_key")
        )
    }

    private func writeSignedManifest() throws -> (manifestURL: URL, signatureURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuxie-flow-manifest-signature-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let manifestURL = root.appendingPathComponent(FlowArtifactStore.manifestPath)
        let signatureURL = root.appendingPathComponent(FlowArtifactStore.manifestSignaturePath)
        let manifestBytes = Data(
            """
            {
              "version": 1,
              "flowId": "flow-1",
              "buildId": "build-1"
            }
            """.utf8
        )
        try manifestBytes.write(to: manifestURL)

        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(base64Encoded: privateKeySeedBase64)!
        )
        let signature = try privateKey.signature(for: manifestBytes)
        let signatureJSON = """
        {
          "version": 1,
          "signs": "\(FlowArtifactStore.manifestPath)",
          "algorithm": "ed25519",
          "keyId": "\(keyId)",
          "signatureBase64": "\(signature.base64EncodedString())"
        }
        """
        try Data(signatureJSON.utf8).write(to: signatureURL)
        return (manifestURL, signatureURL)
    }
}
