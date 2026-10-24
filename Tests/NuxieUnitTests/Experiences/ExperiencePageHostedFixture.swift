#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import Foundation
import CryptoKit
import XCTest
@testable import NuxieRuntime
@testable import NuxieTestSupport
@_spi(Testing) @testable import Nuxie

/// Signs current V1-V4 metadata; the exporter-specific runtime contract is applied
/// only after normal release authentication and artifact acquisition in this test file.
extension JourneyTestCase {
    func hostedLiveMoveFixture() throws -> JourneyPlaneProfileTestFixture {
        let base = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        var root = base.root
        var entry = try XCTUnwrap((root["releases"] as? [[String: Any]])?.first)
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["descriptorBytesBase64"] as? String)))
        var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var leg = try XCTUnwrap(descriptor["leg"] as? [String: Any])
        leg["screens"] = [
            ["id": "A", "defaultViewModelName": "Screen0", "defaultInstanceId": "row-a", "responseCaptures": []],
            ["id": "B", "defaultViewModelName": "Screen1", "defaultInstanceId": "row-b", "responseCaptures": []]
        ]
        leg["steps"] = [["id": "present", "kind": "action", "action": ["type": "navigate", "screenId": "A"], "outlets": [:]]]
        leg["entryStepId"] = "present"
        leg["routes"] = []
        descriptor["leg"] = leg
        descriptor["viewModelValues"] = []
        descriptor["screenBehaviors"] = ["A", "B"].map { ["screenId": $0, "controls": []] as [String: Any] }
        let scene = try Data(contentsOf: experiencePreparationRepositoryRoot().appendingPathComponent("fixtures/runtime/page-host-live-moves/page2.riv"))
        let hash = SHA256Provider.hexDigest(scene)
        struct Lifecycle: Decodable {
            struct Step: Decodable { let durationMs: Int }
            let steps: [String: Step]
        }
        let lifecycle = try JSONDecoder().decode(Lifecycle.self, from: Data(contentsOf:
            experiencePreparationRepositoryRoot().appendingPathComponent("fixtures/runtime/page-host-live-moves/lifecycle2.json")))
        descriptor["render"] = [
            "renderer": "nux", "nux": ["key": "renders/sha256/\(hash).nux", "sha256": hash,
                "sizeBytes": scene.count, "contentType": "application/vnd.nuxie.scene"],
            "assets": [], "textInputs": [],
            "screens": ["A", "B"].map { ["id": $0, "artboardId": $0, "artboardName": $0, "width": 800, "height": 600] as [String: Any] },
            "transitions": [["id": "t1", "kind": "page", "sourceScreenId": "A", "destinationScreenId": "B",
                "durationMs": try XCTUnwrap(lifecycle.steps["t1"]).durationMs,
                "source": ["completeEventName": "nx_exit_done:t1"],
                "destination": ["completeEventName": "nx_enter_done:t1"],
                "reverse": ["durationMs": try XCTUnwrap(lifecycle.steps["back"]).durationMs,
                    "source": ["completeEventName": "nx_exit_done:t1.reverse"],
                    "destination": ["completeEventName": "nx_enter_done:t1.reverse"]]]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: descriptor, options: .sortedKeys)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let signed = JourneyReleaseEnvelope(mediaType: JourneyReleaseDescriptor.mediaType, encoding: "base64",
            descriptorSha256: SHA256Provider.hexDigest(bytes), descriptorSizeBytes: bytes.count,
            descriptorBytesBase64: bytes.base64EncodedString(), signature: .init(version: 1, algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR", signatureBase64: try key.signature(for:
                    Data(JourneyReleaseDescriptor.signatureDomain.utf8) + bytes).base64EncodedString()))
        entry["envelope"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(signed))
        root["releases"] = [entry]
        var arms = try XCTUnwrap(root["armedLegs"] as? [[String: Any]])
        var reference = try XCTUnwrap(arms[0]["reference"] as? [String: Any])
        reference["descriptorSha256"] = signed.descriptorSha256
        arms[0]["reference"] = reference
        root["armedLegs"] = arms
        let profileData = try JSONSerialization.data(withJSONObject: root)
        return .init(data: profileData, profile: try JourneyPlaneProfile.decode(profileData),
            publicKey: key.publicKey.rawRepresentation, root: root)
    }

    func hostedLiveMovePayload() async throws -> AuthenticatedRuntimePayload {
        let snapshot = try await authenticatedRenderedSnapshot(hostedLiveMoveFixture())
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let scene = try Data(contentsOf: experiencePreparationRepositoryRoot().appendingPathComponent("fixtures/runtime/page-host-live-moves/page2.riv"))
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let hash = SHA256Provider.hexDigest(scene)
        StubURLProtocol.register(matcher: { $0.url?.path.hasSuffix("\(hash).nux") == true }) { request in
            let url = try XCTUnwrap(request.url)
            return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/vnd.nuxie.scene"])), scene)
        }
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let store = JourneyReleaseAcquisitionStore(cacheDirectory: directory, urlSession: TestURLSessionProvider.createTestSession())
        let presentation = try await store.preparePresentation(release: release, delivery: snapshot.profile.delivery,
            pinnedArtifacts: nil, productResolver: { _ in [] })
        let acquired = try await presentation.artifactLoader(presentation.experience, nil, "A")
        let base = acquired.payload
        let old = base.renderPlan
        struct Lifecycle: Decodable {
            struct Step: Decodable {
                struct Side: Decodable { let completeEventName: String? }
                let durationMs: Int
                let incoming: Side
                let outgoing: Side
            }
            let steps: [String: Step]
        }
        let lifecycle = try JSONDecoder().decode(Lifecycle.self, from: Data(contentsOf:
            experiencePreparationRepositoryRoot().appendingPathComponent("fixtures/runtime/page-host-live-moves/lifecycle2.json")))
        let forward = try XCTUnwrap(lifecycle.steps["t1"])
        let reverse = try XCTUnwrap(lifecycle.steps["back"])
        let plan = NativeExperienceRenderPlan(identity: old.identity, scene: old.scene, entry: old.entry,
            pageHost: .init(artboardName: "Page", listPath: "screens", machineName: "run", modelName: "Page",
                hasLiveMoves: true, initialRows: .clearBeforePlayer, stepNames: ["t1.reverse": "back"]),
            screens: old.screens, transitions: [.init(id: "t1", kind: .page, sourceScreenId: "A", destinationScreenId: "B",
                durationMs: forward.durationMs, incomingOnTop: true,
                source: .init(completeEventName: forward.outgoing.completeEventName ?? ""),
                destination: .init(completeEventName: try XCTUnwrap(forward.incoming.completeEventName)),
                reverse: .init(durationMs: reverse.durationMs, incomingOnTop: false,
                    source: .init(completeEventName: reverse.outgoing.completeEventName ?? ""),
                    destination: .init(completeEventName: try XCTUnwrap(reverse.incoming.completeEventName))))],
            textInputs: [], images: [], fonts: [])
        return .init(valuePolicy: base.valuePolicy, authenticatedKeyID: base.authenticatedKeyID,
            requiredCapabilities: base.requiredCapabilities, renderPlan: plan, journey: base.journey,
            definition: base.definition, sceneBytes: base.sceneBytes, assets: base.assets)
    }
}

func hostedLiveMovePreparationCache() -> ExperienceInteractivePreparationCache {
    ExperienceInteractivePreparationCache(preparePayload: { payload, catalog in
        let assets = catalog
        let file = try await NuxieNativePreparedFile.prepare(bytes: payload.sceneBytes,
            importMode: .configured(moduleName: "nuxie", expectedAssets: assets, externalAssets: [:], videoEnabled: true),
            valuePolicy: payload.valuePolicy.native)
        // The exporter has video slots but no media file. These tests qualify navigation,
        // not signed video admission or decoding, exactly like the native live-move probes.
        return ExperienceInteractivePreparation(payload: payload, preparedFile: file, hasPageHost: true,
            generatedInteractionStateMachineByArtboard: [:], imageIDsByName: [:], inspectionCount: 1,
            systemFontCache: .shared, systemFontLeases: [])
    })
}
#endif
