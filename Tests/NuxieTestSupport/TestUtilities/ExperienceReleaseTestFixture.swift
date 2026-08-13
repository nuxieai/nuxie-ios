import CryptoKit
import Foundation
@testable import Nuxie
@testable import NuxieRuntime

struct ExperienceReleaseTestFixture {
    let entry: ExperienceReleaseProfileEntryV1
    let delivery: ExperienceReleaseDeliveryV1
    let riv: Data
    let image: Data
    let script: Data

    static func make(
        selectSecondScreen: Bool? = nil,
        entryActionsOverride: [[String: Any]]? = nil
    ) throws -> Self {
        let riv = Data("RIVE integration release".utf8)
        let image = Data([1, 3, 3, 7])
        let script = Data("compiled luau integration".utf8)
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV1.self,
            from: Data(contentsOf: rootURL.appendingPathComponent(
                "fixtures/experience-release-descriptor-v1/envelope.json"
            ))
        )
        guard let descriptorBytes = Data(base64Encoded: envelope.descriptorBytesBase64),
              var root = try JSONSerialization.jsonObject(with: descriptorBytes) as? [String: Any],
              var render = root["render"] as? [String: Any],
              var rivArtifact = render["riv"] as? [String: Any],
              var renderScreens = render["screens"] as? [[String: Any]],
              var asset = (render["assets"] as? [[String: Any]])?.first,
              var journey = root["journey"] as? [String: Any],
              var journeyScreens = journey["screens"] as? [[String: Any]],
              var scripts = journey["scripts"] as? [String: [[String: Any]]],
              var refs = scripts["screen_welcome"],
              var ref = refs.first,
              var scriptArtifact = ref["artifact"] as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }

        var identity = root["identity"] as! [String: Any]
        identity["appId"] = "orchestration-app"
        identity["environment"] = "test"
        identity["experienceId"] = "release-only-experience"
        identity["experienceVersionId"] = "release-only-version"
        identity["buildId"] = "release-only-build"
        identity["versionNumber"] = 1
        identity["publishedAt"] = "2026-08-12T00:00:00.000Z"
        identity["publishedAtSeq"] = 11
        root["identity"] = identity

        let rivDigest = SHA256Provider.hexDigest(riv)
        rivArtifact["key"] = "renders/sha256/\(rivDigest).riv"
        rivArtifact["sha256"] = rivDigest
        rivArtifact["sizeBytes"] = riv.count
        render["riv"] = rivArtifact
        let imageDigest = SHA256Provider.hexDigest(image)
        asset["key"] = "assets/sha256/\(imageDigest).jpg"
        asset["sha256"] = imageDigest
        asset["sizeBytes"] = image.count
        asset["contentType"] = "image/jpeg"
        render["assets"] = [asset]
        root["render"] = render

        let entryActions: [[String: Any]]
        if let entryActionsOverride {
            entryActions = entryActionsOverride
        } else if let selectSecondScreen {
            var secondRenderScreen = renderScreens[0]
            secondRenderScreen["id"] = "screen_offer"
            secondRenderScreen["artboardId"] = "artboard_offer"
            secondRenderScreen["artboardName"] = "Offer"
            renderScreens.append(secondRenderScreen)
            render["screens"] = renderScreens

            var secondJourneyScreen = journeyScreens[0]
            secondJourneyScreen["id"] = "screen_offer"
            journeyScreens.append(secondJourneyScreen)
            journey["screens"] = journeyScreens
            scripts["screen_offer"] = []

            let condition = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    IREnvelope(
                        ir_version: 1,
                        engine_min: "1.0.0",
                        compiled_at: 0,
                        expr: .bool(selectSecondScreen)
                    )
                )
            )
            entryActions = [[
                "type": "condition",
                "nodeId": "node_entry_condition",
                "branches": [[
                    "id": "select_offer",
                    "condition": condition,
                    "actions": [[
                        "type": "navigate",
                        "screenId": "screen_offer",
                        "nodeId": "node_offer"
                    ]]
                ]],
                "defaultActions": [[
                    "type": "navigate",
                    "screenId": "screen_welcome",
                    "nodeId": "node_welcome"
                ]]
            ]]
        } else {
            entryActions = [[
                "type": "navigate",
                "screenId": "screen_welcome",
                "nodeId": "node_entry"
            ]]
        }
        journey["handlers"] = [
            JourneyDocument.journeyEventHostKey: [[
                "id": "handler_journey_started",
                "eventName": SystemEventNames.journeyStarted,
                "actions": entryActions
            ]]
        ]
        root["render"] = render
        let scriptDigest = SHA256Provider.hexDigest(script)
        scriptArtifact["key"] = "assets/sha256/\(scriptDigest).bin"
        scriptArtifact["sha256"] = scriptDigest
        scriptArtifact["sizeBytes"] = script.count
        ref["artifact"] = scriptArtifact
        refs[0] = ref
        scripts["screen_welcome"] = refs
        journey["scripts"] = scripts
        root["journey"] = journey
        root["compatibility"] = [
            "minimumSdkVersion": SDKVersion.current,
            "runtimeRevision": NuxieEmbeddedRuntimeCompatibility.sourceRevision,
            "luau": [
                "revision": NuxieEmbeddedRuntimeCompatibility.luauRevision,
                "bytecodeVersions": NuxieEmbeddedRuntimeCompatibility.luauBytecodeVersions.sorted()
            ],
            "sceneFormat": [
                "major": NuxieEmbeddedRuntimeCompatibility.sceneFormatMajor,
                "minor": NuxieEmbeddedRuntimeCompatibility.sceneFormatMinor
            ],
            "requiredCapabilities": NuxieEmbeddedRuntimeCompatibility.capabilities.sorted()
        ]

        let exactDescriptor = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
        let signingKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x42, count: 32)
        )
        let signature = try signingKey.signature(
            for: Data(ExperienceReleaseDescriptorLimits.signatureDomain.utf8) + exactDescriptor
        )
        let digest = SHA256Provider.hexDigest(exactDescriptor)
        let exactEnvelope = try ExperienceReleaseDescriptorEnvelopeV1(
                mediaType: ExperienceReleaseDescriptorLimits.mediaType,
                encoding: "base64",
                descriptorSha256: digest,
                descriptorSizeBytes: exactDescriptor.count,
                descriptorBytesBase64: exactDescriptor.base64EncodedString(),
                signature: .init(
                    version: 1,
                    algorithm: "ed25519",
                    keyId: "TEST_ONLY_DEV_KEYPAIR",
                    signatureBase64: signature.base64EncodedString()
                )
            ).canonicalBytes()
        let authenticatedIdentity = try JSONDecoder().decode(
            ExperienceReleaseDescriptorV1.self,
            from: exactDescriptor
        ).identity
        return Self(
            entry: .init(
                locator: authenticatedIdentity,
                descriptorSha256: digest,
                envelopeBytes: exactEnvelope
            ),
            delivery: .init(
                renderBaseUrl: "https://cdn.nuxie.test/renders/",
                assetBaseUrl: "https://cdn.nuxie.test/assets/"
            ),
            riv: riv,
            image: image,
            script: script
        )
    }
}
