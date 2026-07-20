#if NUXIE_RUNTIME_ADAPTER_TESTS && !canImport(NuxieRuntime)
#error("native result seam tests require the packaged NuxieRuntime Clang module")
#endif

#if canImport(NuxieRuntime)
import CryptoKit
import Foundation
import Nimble
import NuxieRuntime
import Quick
import XCTest

@testable import Nuxie

/// End-to-end coverage for values that must survive Rust's owned ABI 1.4
/// result, the public C accessors, and Swift's detached result decoder.
final class NuxieRuntimeNativeResultSeamTests: AsyncSpec {
    override class func spec() {
        describe("the native result seam") {
            it("preserves the full finite f64 host domain") { @MainActor in
                let fixture = try await Self.makeFixture()
                defer { fixture.context.dispose() }
                defer { fixture.session.dispose() }

                let payload = try Self.commandPayload(
                    named: "seam_values",
                    in: fixture.creationResult
                )
                guard case .number(let value) = payload["precise"] else {
                    fail("native seam_values payload omitted its precise number")
                    return
                }

                let expected = Double(Float.greatestFiniteMagnitude) * 2
                expect(value.bitPattern).to(equal(expected.bitPattern))
                expect(value).to(beGreaterThan(Double(Float.greatestFiniteMagnitude)))
            }

            it("preserves Unicode object keys by exact UTF-8 identity") { @MainActor in
                let fixture = try await Self.makeFixture()
                defer { fixture.context.dispose() }
                defer { fixture.session.dispose() }

                let payload = try Self.commandPayload(
                    named: "seam_values",
                    in: fixture.creationResult
                )
                let composed = "\u{00e9}"
                let decomposed = "e\u{0301}"

                expect(payload[composed]).to(equal(.string("composed")))
                expect(payload[decomposed]).to(equal(.string("decomposed")))
                expect(payload.fields.map { Data($0.name.utf8) }).to(equal([
                    Data(decomposed.utf8),
                    Data("precise".utf8),
                    Data(composed.utf8),
                ]))
                expect(
                    payload.fields.map { Data($0.name.utf8) }.filter {
                        $0 == Data(composed.utf8) || $0 == Data(decomposed.utf8)
                    }.count
                ).to(equal(2))
            }

            it("keeps a script resource failure's stable status and diagnostic code") { @MainActor in
                let fixture = try await Self.makeFixture()
                defer { fixture.context.dispose() }
                defer { fixture.session.dispose() }

                do {
                    _ = try await fixture.session.perform(
                        .advance(FlowRuntimeFrameTime(timestamp: 1, delta: 1)),
                        drawable: nil
                    )
                    fail("257 host commands should exceed the per-cycle script budget")
                } catch NuxieRuntimeAdapterError.callFailed(let status, let diagnostic) {
                    expect(status).to(equal(.runtimeError))
                    expect(diagnostic.severity).to(equal(.fatal))
                    expect(diagnostic.code).to(equal("nux_runtime.script_resource_exceeded"))
                    expect(diagnostic.message).notTo(beEmpty())
                } catch {
                    fail("unexpected native result decoding error: \(String(reflecting: error))")
                }
            }
        }
    }

    private struct Fixture {
        let context: any FlowRuntimeContextDriver
        let session: any FlowRenderSessionDriver
        let creationResult: FlowRuntimeOperationResult
    }

    private enum FixtureError: Error {
        case malformedBytecode
        case missingCommand(String)
        case nonObjectCommand(String)
    }

    @MainActor
    private static func makeFixture() async throws -> Fixture {
        guard nux_runtime_abi_major() == NuxieRuntimeABI.major,
              nux_runtime_abi_minor() >= NuxieRuntimeABI.sessionMinimumMinor else {
            throw XCTSkip(
                "native result seam requires NuxieRuntime ABI 1.4; linked "
                    + "\(nux_runtime_abi_major()).\(nux_runtime_abi_minor())"
            )
        }

        let contextAttachment = try await NuxieRuntimeAdapter().makeContext(
            for: try authenticatedRequest()
        )
        do {
            expect(contextAttachment.importResult.scriptAuthorization)
                .to(equal(.authorized(keyId: signingKeyID)))
            let sessionAttachment = try await contextAttachment.driver.makeSession(
                descriptor: FlowRenderSessionDescriptor()
            )
            return Fixture(
                context: contextAttachment.driver,
                session: sessionAttachment.driver,
                creationResult: sessionAttachment.creationResult
            )
        } catch {
            contextAttachment.driver.dispose()
            throw error
        }
    }

    private static func commandPayload(
        named expectedName: String,
        in result: FlowRuntimeOperationResult
    ) throws -> FlowRuntimeHostObject {
        for output in result.orderedOutputs {
            guard case .hostCommand(let name, let payload) = output.payload,
                  name == expectedName else {
                continue
            }
            guard case .object(let object) = payload else {
                throw FixtureError.nonObjectCommand(expectedName)
            }
            return object
        }
        throw FixtureError.missingCommand(expectedName)
    }

    private static let signingKeyID = "swift-native-result-seam-key"

    private static func authenticatedRequest() throws -> FlowRuntimeImportRequest {
        let artifact = try scriptedArtifact()
        let flowID = "swift-native-result-seam-flow"
        let buildID = "swift-native-result-seam-build"
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "flowId": flowID,
                "buildId": buildID,
                "renderer": "rive",
                "riv": [
                    "path": "flow.riv",
                    "sha256": FlowArtifactStore.sha256Hex(artifact),
                    "sizeBytes": artifact.count,
                ],
                "assets": ["images": [], "fonts": []],
            ],
            options: [.sortedKeys]
        )
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 14, count: 32)
        )
        let signature = try privateKey.signature(for: manifest)
        let envelope = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "signs": "nuxie-manifest.json",
                "algorithm": "ed25519",
                "keyId": signingKeyID,
                "signatureBase64": signature.base64EncodedString(),
            ],
            options: [.sortedKeys]
        )
        return FlowRuntimeImportRequest(
            artifactBytes: artifact,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: flowID,
                buildId: buildID
            ),
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: manifest,
                signatureEnvelopeBytes: envelope,
                selectedKey: FlowRuntimeAuthorizationKey(
                    keyId: signingKeyID,
                    ed25519PublicKeyBytes: privateKey.publicKey.rawRepresentation
                )
            )
        )
    }

    /// Compiled with the runtime workspace's pinned luaur-compiler 0.1.8
    /// after enabling the default Luau flags. The source emits one typed host
    /// command at module load and 257 commands when advanced by one second.
    private static let scriptedBytecodeBase64 =
        "CwMMBGluaXQHdHJpZ2dlcglvdmVyZmxvd18HYWR2YW5jZQdyZXF1aXJlBW51eGll"
        + "C3NlYW1fdmFsdWVzB3ByZWNpc2UIY29tcG9zZWQCw6kKZGVjb21wb3NlZANlzIEA"
        + "BAIBAAAIAAIDAQEAFgECAAAADAEBGAAADQAAAAAACQIBAAAAEgQCAQAfAg4AAQAA"
        + "AAQEAQAEAgEBBAMBADgCCQAJBQAADwUF1AAAAAAFBwEABggEADEGBwhXBQIBAAAA"
        + "ADkC9/8DAgAAFgICAAIDAgMDAA8EARgAAAABAAAAAQAAAAAAAAD/BAAQAAAAAAEA"
        + "DQMBAQAAAAk2AQIAQAIDABACARMAAAAAQAIEAEYCAAAQAgHSAQAAABYBAgAFAwED"
        + "BAUCAAEGAAYBAgABCgABGAABAAADAAAAAAsAAAAAAAUAAAECABdBAAAADAABAAAA"
        + "AEAFAQIAFQACAg8BANQDAAAABQIEADUDAwAAAAAABQQFABAEA+IGAAAABQQHABAE"
        + "A7YIAAAABQQJABAEAygKAAAAFQEDAUABCwBGAAAAFgECAAwDBQQAAABAAwYDAgMH"
        + "AgAAAOD///9HAwgDCQMKAwsDDAYCAQIBAAEYAAEAAAACAAAAAAEAAAEAAAEAAP0G"
        + "AAABAAAAAAAD"

    private static func scriptedArtifact() throws -> Data {
        guard let bytecode = Data(base64Encoded: scriptedBytecodeBase64) else {
            throw FixtureError.malformedBytecode
        }
        var protocolPayload = Data([0])
        protocolPayload.append(bytecode)

        var writer = RiveFixtureWriter(prefix: Data("RIVE".utf8))
        writer.appendVarUInt(7)
        writer.appendVarUInt(0)
        writer.appendVarUInt(9_403)
        writer.appendVarUInt(0)
        writer.appendObject(typeKey: 23) { _ in }
        writer.appendObject(typeKey: 529) { writer in
            writer.appendUInt(propertyKey: 204, value: 0)
            writer.appendBlob(
                propertyKey: 203,
                value: Data("SwiftNativeResultSeam".utf8)
            )
        }
        writer.appendObject(typeKey: 106) { writer in
            writer.appendBlob(propertyKey: 212, value: protocolPayload)
        }
        writer.appendObject(typeKey: 1) { writer in
            writer.appendFloat(propertyKey: 7, value: 100)
            writer.appendFloat(propertyKey: 8, value: 100)
        }
        writer.appendObject(typeKey: 603) { writer in
            writer.appendUInt(propertyKey: 5, value: 0)
            writer.appendUInt(propertyKey: 848, value: 0)
        }
        return writer.data
    }
}

private struct RiveFixtureWriter {
    private(set) var data: Data

    init(prefix: Data) {
        data = prefix
    }

    mutating func appendVarUInt(_ initialValue: UInt64) {
        var value = initialValue
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while value != 0
    }

    mutating func appendObject(
        typeKey: UInt64,
        properties: (inout Self) -> Void
    ) {
        appendVarUInt(typeKey)
        properties(&self)
        appendVarUInt(0)
    }

    mutating func appendUInt(propertyKey: UInt64, value: UInt64) {
        appendVarUInt(propertyKey)
        appendVarUInt(value)
    }

    mutating func appendFloat(propertyKey: UInt64, value: Float) {
        appendVarUInt(propertyKey)
        var bits = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    mutating func appendBlob(propertyKey: UInt64, value: Data) {
        appendVarUInt(propertyKey)
        appendVarUInt(UInt64(value.count))
        data.append(value)
    }
}
#endif
