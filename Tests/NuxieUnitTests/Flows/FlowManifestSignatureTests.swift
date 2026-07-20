import Foundation
import Nimble
import Quick

@testable import Nuxie

private let manifestData = Data(
    "{\"version\":1,\"riv\":{\"sha256\":\"abc\"}}".utf8
)
private let customKeyID = "custom-key-1"
private let customKeyBytes = Data(repeating: 0xA5, count: 32)

private func makeEnvelope(
    version: Int = 1,
    signs: String = "nuxie-manifest.json",
    algorithm: String = "ed25519",
    keyId: String = customKeyID,
    signatureBase64: String = "opaque-signature-for-rust"
) throws -> Data {
    try JSONEncoder().encode(
        FlowManifestSignature(
            version: version,
            signs: signs,
            algorithm: algorithm,
            keyId: keyId,
            signatureBase64: signatureBase64
        )
    )
}

private func customTrustPolicy(
    keyId: String = customKeyID,
    keyBytes: Data = customKeyBytes
) -> FlowScriptTrustPolicy {
    FlowScriptTrustPolicy.ephemeral(
        publicKeysBase64ByKeyId: [
            keyId: keyBytes.base64EncodedString()
        ]
    )
}

final class FlowManifestSignatureTests: QuickSpec {
    override class func spec() {
        describe("FlowManifestSignature transport") {
            it("decodes the detached-signature DTO without interpreting its signature") {
                let envelopeBytes = try makeEnvelope(
                    signatureBase64: "deliberately-not-base64"
                )

                let envelope = try JSONDecoder().decode(
                    FlowManifestSignature.self,
                    from: envelopeBytes
                )

                expect(FlowManifestSignature.artifactPath)
                    .to(equal("nuxie-manifest.sig.json"))
                expect(envelope).to(
                    equal(
                        FlowManifestSignature(
                            version: 1,
                            signs: "nuxie-manifest.json",
                            algorithm: "ed25519",
                            keyId: customKeyID,
                            signatureBase64: "deliberately-not-base64"
                        )
                    )
                )
            }
        }
    }
}

final class FlowScriptTrustPolicyTests: QuickSpec {
    override class func spec() {
        describe("FlowScriptTrustPolicy") {
            it("preserves exact evidence and selects a configured custom key") {
                let signatureEnvelopeBytes = try makeEnvelope()

                let evidence = customTrustPolicy().evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: signatureEnvelopeBytes
                )

                expect(evidence.signedContentBytes).to(equal(manifestData))
                expect(evidence.signatureEnvelopeBytes)
                    .to(equal(signatureEnvelopeBytes))
                expect(evidence.selectedKey?.keyId).to(equal(customKeyID))
                expect(evidence.selectedKey?.ed25519PublicKeyBytes)
                    .to(equal(customKeyBytes))
            }

            it("selects key material without preauthorizing envelope metadata") {
                let unsupportedEnvelope = try makeEnvelope(
                    version: 99,
                    signs: "different-content",
                    algorithm: "different-algorithm",
                    signatureBase64: "not-validated-by-swift"
                )

                let evidence = customTrustPolicy().evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: unsupportedEnvelope
                )

                expect(evidence.signatureEnvelopeBytes)
                    .to(equal(unsupportedEnvelope))
                expect(evidence.selectedKey?.keyId).to(equal(customKeyID))
                expect(evidence.selectedKey?.ed25519PublicKeyBytes)
                    .to(equal(customKeyBytes))
            }

            it("preserves a malformed envelope without selecting a key") {
                let malformedEnvelope = Data("{not-json".utf8)

                let evidence = customTrustPolicy().evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: malformedEnvelope
                )

                expect(evidence.signedContentBytes).to(equal(manifestData))
                expect(evidence.signatureEnvelopeBytes)
                    .to(equal(malformedEnvelope))
                expect(evidence.selectedKey).to(beNil())
            }

            it("preserves an unknown-key envelope without selecting key material") {
                let unknownKeyEnvelope = try makeEnvelope(keyId: "unknown-key")

                let evidence = customTrustPolicy().evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: unknownKeyEnvelope
                )

                expect(evidence.signatureEnvelopeBytes)
                    .to(equal(unknownKeyEnvelope))
                expect(evidence.selectedKey).to(beNil())
            }

            it("preserves signed content when the signature envelope is absent") {
                let evidence = customTrustPolicy().evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: nil
                )

                expect(evidence.signedContentBytes).to(equal(manifestData))
                expect(evidence.signatureEnvelopeBytes).to(beNil())
                expect(evidence.selectedKey).to(beNil())
            }

            it("does not select malformed configured keys") {
                let signatureEnvelopeBytes = try makeEnvelope()
                for invalidKey in [
                    "not-base64",
                    Data(repeating: 1, count: 31).base64EncodedString(),
                ] {
                    let evidence = FlowScriptTrustPolicy.ephemeral(
                        publicKeysBase64ByKeyId: [customKeyID: invalidKey]
                    ).evidence(
                        signedContentBytes: manifestData,
                        signatureEnvelopeBytes: signatureEnvelopeBytes
                    )

                    expect(evidence.signatureEnvelopeBytes)
                        .to(equal(signatureEnvelopeBytes))
                    expect(evidence.selectedKey).to(beNil())
                }
            }

            it("does not register configured keys with an empty identifier") {
                let emptyIdentifierEnvelope = try makeEnvelope(keyId: "")

                let evidence = customTrustPolicy(keyId: "").evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: emptyIdentifierEnvelope
                )

                expect(evidence.signatureEnvelopeBytes)
                    .to(equal(emptyIdentifierEnvelope))
                expect(evidence.selectedKey).to(beNil())
            }

            it("keeps production fail-closed until trust roots are provisioned") {
                let signatureEnvelopeBytes = try makeEnvelope()

                let evidence = FlowScriptTrustPolicy.production.evidence(
                    signedContentBytes: manifestData,
                    signatureEnvelopeBytes: signatureEnvelopeBytes
                )

                expect(evidence.signedContentBytes).to(equal(manifestData))
                expect(evidence.signatureEnvelopeBytes)
                    .to(equal(signatureEnvelopeBytes))
                expect(evidence.selectedKey).to(beNil())
            }
        }
    }
}
