import CryptoKit
import Foundation
@testable import Nuxie
@testable import NuxieRuntime

struct ExperienceReleaseTestFixture {
    let entry: ExperienceReleaseProfileEntryV2
    let delivery: ExperienceReleaseDeliveryV2
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
            ExperienceReleaseDescriptorEnvelopeV2.self,
            from: Data(contentsOf: rootURL.appendingPathComponent(
                "fixtures/experience-release-descriptor-v2/envelope.json"
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
              var routes = journey["routes"] as? [[String: Any]],
              var plans = journey["executionPlans"] as? [[String: Any]],
              var screenBehaviors = root["screenBehaviors"] as? [[String: Any]],
              var welcomeBehavior = screenBehaviors.first else {
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
            screenBehaviors.append([
                "screenId": "screen_offer",
                "controls": [],
            ])
            entryActions = [[
                "type": "condition",
                "branches": [[
                    "id": "select_offer",
                    "condition": [
                        "type": "Truthy",
                        "value": ["type": "Boolean", "value": selectSecondScreen],
                    ],
                    "program": [[
                        "type": "navigate",
                        "screenId": "screen_offer"
                    ]]
                ]],
                "defaultProgram": [[
                    "type": "navigate",
                    "screenId": "screen_welcome"
                ]]
            ]]
        } else {
            entryActions = [[
                "type": "navigate",
                "screenId": "screen_welcome"
            ]]
        }
        guard let entryRouteIndex = routes.firstIndex(where: { route in
            guard let host = route["host"] as? [String: Any] else { return false }
            return host["kind"] as? String == "journey"
        }) else {
            throw CocoaError(.coderInvalidValue)
        }
        let revision = String(repeating: "a", count: 64)
        routes[entryRouteIndex]["program"] = entryActions
        routes[entryRouteIndex]["revisionSha256"] = revision
        for index in plans.indices {
            guard var route = plans[index]["route"] as? [String: Any],
                  let host = route["host"] as? [String: Any],
                  host["kind"] as? String == "journey" else { continue }
            route["revisionSha256"] = revision
            plans[index]["route"] = route
            if selectSecondScreen != nil,
               var deviceRegions = plans[index]["deviceRegions"] as? [[String: Any]] {
                for regionIndex in deviceRegions.indices {
                    deviceRegions[regionIndex]["actionPaths"] = [
                        "/program/0",
                        "/program/0/branches/0/program/0",
                        "/program/0/defaultProgram/0",
                    ]
                }
                plans[index]["deviceRegions"] = deviceRegions
            }
        }
        journey["routes"] = routes
        journey["executionPlans"] = plans
        root["render"] = render
        welcomeBehavior["controls"] = [[
            "actionId": "continue",
            "behavior": [
                "kind": "declarative",
                "program": [[
                    "type": "emit",
                    "eventName": "continue",
                    "payload": [:],
                ]],
            ],
        ]]
        welcomeBehavior.removeValue(forKey: "script")
        screenBehaviors[0] = welcomeBehavior
        screenBehaviors.sort { ($0["screenId"] as? String ?? "") < ($1["screenId"] as? String ?? "") }
        root["screenBehaviors"] = screenBehaviors
        root["journey"] = journey
        var requirements = root["requirements"] as! [String: Any]
        requirements["minimumSdkVersion"] = SDKVersion.current
        requirements["runtimeRevision"] = NuxieEmbeddedRuntimeCompatibility.sourceRevision
        requirements["luau"] = [
            "revision": NuxieEmbeddedRuntimeCompatibility.luauRevision,
            "bytecodeVersions": NuxieEmbeddedRuntimeCompatibility.luauBytecodeVersions.sorted(),
        ]
        requirements["sceneFormat"] = [
            "major": NuxieEmbeddedRuntimeCompatibility.sceneFormatMajor,
            "minor": NuxieEmbeddedRuntimeCompatibility.sceneFormatMinor,
        ]
        requirements["requiredCapabilities"] = NuxieEmbeddedRuntimeCompatibility.capabilities.sorted()
        root["requirements"] = requirements

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
        let exactEnvelope = try ExperienceReleaseDescriptorEnvelopeV2(
                mediaType: ExperienceReleaseDescriptorLimits.mediaType,
                encoding: "base64",
                descriptorSha256: digest,
                descriptorSizeBytes: exactDescriptor.count,
                descriptorBytesBase64: exactDescriptor.base64EncodedString(),
                signature: .init(
                    version: 2,
                    algorithm: "ed25519",
                    keyId: "TEST_ONLY_DEV_KEYPAIR",
                    signatureBase64: signature.base64EncodedString()
                )
            ).canonicalBytes()
        let authenticatedIdentity = try JSONDecoder().decode(
            ExperienceReleaseDescriptorV2.self,
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
