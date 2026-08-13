import CryptoKit
import Foundation
import XCTest
@testable import Nuxie

final class ExperienceReleaseDescriptorAuthenticationTests: XCTestCase {
    private let signingKey = try! Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(repeating: 0x42, count: 32)
    )

    func testAuthenticatesDomainSeparatedExactDescriptorBytes() throws {
        let descriptor = validDescriptorBytes()
        let envelope = try signedEnvelope(descriptorBytes: descriptor)
        let expectation = expectedIdentity

        let authenticated = try ExperienceReleaseDescriptorVerifier().authenticate(
            envelopeBytes: envelope,
            authorizationKeys: [authorizationKey],
            expectedIdentity: expectation,
            supportedCompatibility: supportedCompatibility,
            replayPolicy: .active(minimumPublishedAtSeq: 42)
        )

        XCTAssertEqual(authenticated.exactDescriptorBytes, descriptor)
        XCTAssertEqual(authenticated.descriptor.identity, expectation.identity)
        XCTAssertEqual(authenticated.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR")
        XCTAssertEqual(authenticated.publishedAtSeqToPromote, 42)
    }

    func testAuthenticatesSharedPublisherGoldenEnvelope() throws {
        let envelope = try fixtureData("envelope.json")
        let expectedEnvelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV1.self,
            from: envelope
        )
        let expectedIdentity = try JSONDecoder().decode(
            ExperienceReleaseIdentityV1.self,
            from: fixtureData("expected-identity.json")
        )
        let capabilities = try JSONDecoder().decode(
            [String].self,
            from: fixtureData("supported-capabilities.json")
        )
        let publicKeys = try JSONDecoder().decode(
            [String: String].self,
            from: fixtureData("trusted-public-keys.json")
        )
        let authorizationKeys = try publicKeys.map { keyID, base64 in
            ExperiencePackageAuthorizationKey(
                keyID: keyID,
                ed25519PublicKeyBytes: try XCTUnwrap(Data(base64Encoded: base64))
            )
        }

        let authenticated: AuthenticatedExperienceReleaseDescriptor
        do {
            authenticated = try ExperienceReleaseDescriptorVerifier().authenticate(
                envelopeBytes: envelope,
            authorizationKeys: authorizationKeys,
                expectedIdentity: ExperienceReleaseIdentityExpectation(
                    appId: expectedIdentity.appId,
                    environment: expectedIdentity.environment,
                    experienceId: expectedIdentity.experienceId,
                    experienceVersionId: expectedIdentity.experienceVersionId,
                    buildId: expectedIdentity.buildId,
                    versionNumber: expectedIdentity.versionNumber,
                    publishedAt: expectedIdentity.publishedAt,
                    publishedAtSeq: expectedIdentity.publishedAtSeq
                ),
            supportedCompatibility: supportedCompatibility(
                capabilities: Set(capabilities)
            ),
            replayPolicy: .active(minimumPublishedAtSeq: 42)
            )
        } catch {
            XCTFail("golden envelope failed: \(error)")
            return
        }

        XCTAssertEqual(authenticated.descriptor.identity, expectedIdentity)
        XCTAssertEqual(authenticated.descriptorSHA256, expectedEnvelope.descriptorSha256)
        XCTAssertFalse(authenticated.exactDescriptorBytes.isEmpty)
    }

    func testRejectsTamperedInvalidJSONAsBadSignatureBeforeDescriptorDecode() throws {
        let signed = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let tamperedBytes = Data("{".utf8)
        let tampered = ExperienceReleaseDescriptorEnvelopeV1(
            mediaType: signed.mediaType,
            encoding: signed.encoding,
            descriptorSha256: SHA256Provider.hexDigest(tamperedBytes),
            descriptorSizeBytes: tamperedBytes.count,
            descriptorBytesBase64: tamperedBytes.base64EncodedString(),
            signature: signed.signature
        )
        let envelope = try JSONEncoder().encode(tampered)

        XCTAssertThrowsError(
            try ExperienceReleaseDescriptorVerifier().authenticate(
                envelopeBytes: envelope,
                authorizationKeys: [authorizationKey],
                expectedIdentity: expectedIdentity,
                supportedCompatibility: supportedCompatibility(capabilities: []),
                replayPolicy: .active(minimumPublishedAtSeq: 0)
            )
        ) {
            XCTAssertEqual(
                ($0 as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.signature.bad_signature"
            )
        }
    }

    func testAcceptsExactly128KiBAndRejectsOneAdditionalDecodedByte() throws {
        let original = validDescriptorBytes()
        let exact = original + Data(
            repeating: 0x20,
            count: ExperienceReleaseDescriptorLimits.descriptorBytes - original.count
        )
        XCTAssertNoThrow(try authenticate(descriptorBytes: exact))

        let overLimit = exact + Data([0x20])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: overLimit),
            is: "experience_release.envelope.invalid"
        )
    }

    func testRejectsUnpaddedBase64() throws {
        var descriptor = validDescriptorBytes()
        while descriptor.count.isMultiple(of: 3) {
            descriptor.append(0x20)
        }
        var envelope = try signedEnvelopeValue(descriptorBytes: descriptor)
        envelope.descriptorBytesBase64.removeAll(where: { $0 == "=" })

        assertAuthenticationError(
            try JSONEncoder().encode(envelope),
            is: "experience_release.envelope.invalid"
        )
    }

    func testRejectsDescriptorDigestMismatch() throws {
        let signed = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let envelope = ExperienceReleaseDescriptorEnvelopeV1(
            mediaType: signed.mediaType,
            encoding: signed.encoding,
            descriptorSha256: String(repeating: "0", count: 64),
            descriptorSizeBytes: signed.descriptorSizeBytes,
            descriptorBytesBase64: signed.descriptorBytesBase64,
            signature: signed.signature
        )

        assertAuthenticationError(
            try JSONEncoder().encode(envelope),
            is: "experience_release.descriptor.digest_mismatch"
        )
    }

    func testBindsEveryIdentityField() throws {
        let mismatched = ExperienceReleaseIdentityExpectation(
            appId: expectedIdentity.appId,
            environment: expectedIdentity.environment,
            experienceId: expectedIdentity.experienceId,
            experienceVersionId: expectedIdentity.experienceVersionId,
            buildId: expectedIdentity.buildId,
            versionNumber: expectedIdentity.versionNumber + 1,
            publishedAt: expectedIdentity.publishedAt,
            publishedAtSeq: expectedIdentity.publishedAtSeq
        )

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: validDescriptorBytes()),
            expectedIdentity: mismatched,
            is: "experience_release.identity.mismatch"
        )
    }

    func testRejectsUnsupportedRequiredCapability() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var compatibility = try XCTUnwrap(root["compatibility"] as? [String: Any])
            compatibility["requiredCapabilities"] = ["future_feature"]
            root["compatibility"] = compatibility
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.capability.unsupported"
        )
    }

    func testRejectsDuplicateRequiredCapabilitiesAsMalformedBounds() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var compatibility = try XCTUnwrap(root["compatibility"] as? [String: Any])
            compatibility["requiredCapabilities"] = ["rive", "rive"]
            root["compatibility"] = compatibility
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            supportedCompatibility: supportedCompatibility(capabilities: ["rive"]),
            is: "experience_release.descriptor.malformed_bounds"
        )
    }

    func testRejectsUnknownNestedPresentationBehavior() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
            presentation["futureBehavior"] = true
            root["presentation"] = presentation
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testAcceptsDrawerPresentationVariant() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
            presentation["style"] = "drawer"
            presentation["drawer"] = [
                "edge": "bottom",
                "extentRatio": 0.75,
                "cornerRadius": 24,
                "dismissible": true,
            ]
            root["presentation"] = presentation
        }

        XCTAssertNoThrow(try authenticate(descriptorBytes: descriptor))
    }

    func testRejectsCrossVariantPresentationFields() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
            presentation["sheet"] = ["detent": "large", "dismissible": true]
            root["presentation"] = presentation
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsInvalidPresentationValuesAndRanges() throws {
        let mutations: [(inout [String: Any]) throws -> Void] = [
            { $0["orientation"] = "upside_down" },
            { $0["backgroundColor"] = "#FFF" },
            {
                var loading = try XCTUnwrap($0["loading"] as? [String: Any])
                loading["style"] = "spinner"
                $0["loading"] = loading
            },
            {
                $0["style"] = "drawer"
                $0["drawer"] = [
                    "edge": "center", "extentRatio": 1.1,
                    "cornerRadius": -1, "dismissible": "yes",
                ]
            },
        ]
        for mutation in mutations {
            let descriptor = try mutatedValidDescriptor { root in
                var presentation = try XCTUnwrap(root["presentation"] as? [String: Any])
                try mutation(&presentation)
                root["presentation"] = presentation
            }
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.descriptor.invalid"
            )
        }
    }

    func testRejectsInvalidEnrollmentLifecycleAndRendererValues() throws {
        let mutations: [(inout [String: Any]) throws -> Void] = [
            { root in
                var enrollment = try XCTUnwrap(root["enrollment"] as? [String: Any])
                enrollment["requiredPropertyKeys"] = ["z", "a"]
                root["enrollment"] = enrollment
            },
            { root in
                var lifecycle = try XCTUnwrap(root["lifecycle"] as? [String: Any])
                lifecycle["exitPolicy"] = "sometime"
                root["lifecycle"] = lifecycle
            },
            { root in
                var render = try XCTUnwrap(root["render"] as? [String: Any])
                render["renderer"] = "future_renderer"
                root["render"] = render
            },
            { root in
                var journey = try XCTUnwrap(root["journey"] as? [String: Any])
                journey["schemaVersion"] = 0
                root["journey"] = journey
            },
        ]
        for mutation in mutations {
            let descriptor = try mutatedValidDescriptor(mutation)
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.descriptor.invalid"
            )
        }
    }

    func testRejectsInvalidRenderAndJourneyScalarValues() throws {
        let mutations: [(inout [String: Any]) throws -> Void] = [
            { root in
                var render = try XCTUnwrap(root["render"] as? [String: Any])
                var screens = try XCTUnwrap(render["screens"] as? [[String: Any]])
                screens[0]["width"] = 0
                render["screens"] = screens
                root["render"] = render
            },
            { root in
                var render = try XCTUnwrap(root["render"] as? [String: Any])
                var transitions = try XCTUnwrap(render["transitions"] as? [[String: Any]])
                transitions[0]["kind"] = "future"
                render["transitions"] = transitions
                root["render"] = render
            },
            { root in
                var render = try XCTUnwrap(root["render"] as? [String: Any])
                var inputs = try XCTUnwrap(render["textInputs"] as? [[String: Any]])
                inputs[0]["editable"] = "true"
                render["textInputs"] = inputs
                root["render"] = render
            },
            { root in
                var journey = try XCTUnwrap(root["journey"] as? [String: Any])
                var handlers = try XCTUnwrap(journey["handlers"] as? [String: Any])
                let key = try XCTUnwrap(handlers.keys.first)
                var values = try XCTUnwrap(handlers[key] as? [[String: Any]])
                values[0]["order"] = -1
                handlers[key] = values
                journey["handlers"] = handlers
                root["journey"] = journey
            },
        ]
        for mutation in mutations {
            let descriptor = try mutatedValidDescriptor(mutation)
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.descriptor.invalid"
            )
        }
    }

    func testRejectsMalformedJsonRecordKeys() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var enrollment = try XCTUnwrap(root["enrollment"] as? [String: Any])
            var trigger = try XCTUnwrap(enrollment["trigger"] as? [String: Any])
            trigger["condition"] = ["": true]
            enrollment["trigger"] = trigger
            root["enrollment"] = enrollment
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsInvalidRenderAssetScalarFields() throws {
        let mutations: [(inout [String: Any]) throws -> Void] = [
            { asset in asset["riveAssetId"] = -1 },
            { asset in asset["riveUniqueName"] = "" },
            { asset in asset["width"] = 0 },
            { asset in asset["height"] = 65_536 },
            { asset in asset["required"] = "true" },
        ]
        for mutation in mutations {
            let descriptor = try mutatedValidDescriptor { root in
                var render = try XCTUnwrap(root["render"] as? [String: Any])
                var assets = try XCTUnwrap(render["assets"] as? [[String: Any]])
                try mutation(&assets[0])
                render["assets"] = assets
                root["render"] = render
            }
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.descriptor.invalid"
            )
        }

        let badFont = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            let digest = String(repeating: "d", count: 64)
            render["assets"] = [[
                "kind": "font", "key": "assets/sha256/\(digest).ttf",
                "sha256": digest, "sizeBytes": 1024, "contentType": "font/ttf",
                "riveAssetId": 1, "riveUniqueName": "font", "family": "Inter",
                "weight": "400", "style": "oblique", "format": "ttf",
                "required": true,
            ]]
            root["render"] = render
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: badFont),
            is: "experience_release.descriptor.invalid"
        )

        let badScript = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            let digest = String(repeating: "e", count: 64)
            render["assets"] = [[
                "kind": "script", "key": "assets/sha256/\(digest).bin",
                "sha256": digest, "sizeBytes": 1024,
                "contentType": "application/octet-stream", "required": 1,
            ]]
            root["render"] = render
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: badScript),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsInvalidOrOversizedJourneyRecord() throws {
        let invalidKey = try mutatedValidDescriptor { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            journey["events"] = ["": []]
            root["journey"] = journey
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalidKey),
            is: "experience_release.descriptor.invalid"
        )

        let oversized = try mutatedValidDescriptor { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var events = try XCTUnwrap(journey["events"] as? [String: Any])
            let first = try XCTUnwrap((events.values.first as? [Any])?.first)
            events["screen_welcome"] = Array(repeating: first, count: 257)
            journey["events"] = events
            root["journey"] = journey
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: oversized),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsOversizedActionLabels() throws {
        for action in [
            ["type": "milestone", "milestoneId": "done", "label": String(repeating: "x", count: 257)],
            ["type": "condition", "branches": [
                ["id": "branch", "label": String(repeating: "x", count: 257), "actions": []],
            ]],
            ["type": "experiment", "experimentId": "exp", "name": String(repeating: "x", count: 257), "variants": [
                ["id": "a", "percentage": 50, "actions": []],
                ["id": "b", "percentage": 50, "actions": []],
            ]],
            ["type": "experiment", "experimentId": "exp", "hypothesis": String(repeating: "x", count: 2_049), "variants": [
                ["id": "a", "percentage": 50, "actions": []],
                ["id": "b", "percentage": 50, "actions": []],
            ]],
            ["type": "experiment", "experimentId": "exp", "variants": [
                ["id": "a", "name": String(repeating: "x", count: 257), "percentage": 50, "actions": []],
                ["id": "b", "percentage": 50, "actions": []],
            ]],
        ] as [[String: Any]] {
            let descriptor = try descriptorWithFirstHandlerAction(action)
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.descriptor.invalid"
            )
        }
    }

    func testRejectsIdentityIntegersAboveJavaScriptSafeMaximum() throws {
        for field in ["versionNumber", "publishedAtSeq"] {
            let descriptor = try mutatedValidDescriptor { root in
                var identity = try XCTUnwrap(root["identity"] as? [String: Any])
                identity[field] = Int64(9_007_199_254_740_992)
                root["identity"] = identity
            }
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.descriptor.invalid"
            )
        }
    }

    func testPublishedAtMatchesZodOffsetDatetimeGrammar() throws {
        for publishedAt in [
            "2026-08-12 12:00:00Z",
            "2026-08-12T12:00:00z",
            "2026-08-12T12:00:00",
            "2026-08-12T12:00:00+0000",
            "2026-02-29T12:00:00Z",
            "2026-08-12T24:00:00Z",
        ] {
            let descriptor = try mutatedValidDescriptor { root in
                var identity = try XCTUnwrap(root["identity"] as? [String: Any])
                identity["publishedAt"] = publishedAt
                root["identity"] = identity
            }
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.descriptor.invalid"
            )
        }
    }

    func testRejectsViewModelMemberPathOver512UTF16CodeUnits() throws {
        let descriptor = try descriptorWithFirstHandlerAction([
            "type": "set_view_model",
            "path": [
                "kind": "path",
                "path": String(repeating: "😀", count: 257),
            ],
            "value": "value",
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsCollectionsAboveFrozenMaximums() throws {
        let root = try validDescriptorJSONObject()

        var oversizedViewModels = root
        var journey = try XCTUnwrap(oversizedViewModels["journey"] as? [String: Any])
        let viewModel = try XCTUnwrap((journey["viewModelValues"] as? [Any])?.first)
        journey["viewModelValues"] = Array(repeating: viewModel, count: 2_049)
        oversizedViewModels["journey"] = journey
        XCTAssertThrowsError(try ExperienceReleaseDescriptorSchemaValidator.validate(oversizedViewModels))

        var oversizedSchemas = root
        journey = try XCTUnwrap(oversizedSchemas["journey"] as? [String: Any])
        let schema = try XCTUnwrap((journey["responseSchemas"] as? [Any])?.first)
        journey["responseSchemas"] = Array(repeating: schema, count: 257)
        oversizedSchemas["journey"] = journey
        XCTAssertThrowsError(try ExperienceReleaseDescriptorSchemaValidator.validate(oversizedSchemas))

        var oversizedAssets = root
        var render = try XCTUnwrap(oversizedAssets["render"] as? [String: Any])
        let asset = try XCTUnwrap((render["assets"] as? [Any])?.first)
        render["assets"] = Array(repeating: asset, count: 1_025)
        oversizedAssets["render"] = render
        XCTAssertThrowsError(try ExperienceReleaseDescriptorSchemaValidator.validate(oversizedAssets))
    }

    func testActiveReplayPolicyRejectsReleaseBelowHighWaterMark() throws {
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: validDescriptorBytes()),
            replayPolicy: .active(minimumPublishedAtSeq: 43),
            is: "experience_release.replay.rejected"
        )
    }

    func testPinnedReplayPolicyPermitsExactRollbackWithoutPromotion() throws {
        let envelope = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let authenticated = try ExperienceReleaseDescriptorVerifier().authenticate(
            envelopeBytes: try JSONEncoder().encode(envelope),
            authorizationKeys: [authorizationKey],
            expectedIdentity: expectedIdentity,
            supportedCompatibility: supportedCompatibility,
            replayPolicy: .pinned(
                experienceVersionId: expectedIdentity.experienceVersionId,
                buildId: expectedIdentity.buildId,
                descriptorSHA256: envelope.descriptorSha256
            )
        )

        XCTAssertNil(authenticated.publishedAtSeqToPromote)
    }

    func testPinnedReplayPolicyRejectsNonExactDigest() throws {
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: validDescriptorBytes()),
            replayPolicy: .pinned(
                experienceVersionId: expectedIdentity.experienceVersionId,
                buildId: expectedIdentity.buildId,
                descriptorSHA256: String(repeating: "0", count: 64)
            ),
            is: "experience_release.replay.rejected"
        )
    }

    func testAcceptsValidDelayActionAndRejectsMissingRequiredDuration() throws {
        let valid = try descriptorWithFirstHandlerAction([
            "type": "delay", "nodeId": "delay_node", "durationMs": 250,
        ])
        XCTAssertNoThrow(try authenticate(descriptorBytes: valid))

        let invalid = try descriptorWithFirstHandlerAction([
            "type": "delay", "nodeId": "delay_node",
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalid),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsNavigateWithBothScreenAndArtboard() throws {
        let descriptor = try descriptorWithFirstHandlerAction([
            "type": "navigate", "nodeId": "navigate_node",
            "screenId": "screen_welcome", "artboardId": "artboard_welcome",
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsActionRefinementViolations() throws {
        let negativeDelay = try descriptorWithFirstHandlerAction([
            "type": "delay", "durationMs": -1,
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: negativeDelay),
            is: "experience_release.descriptor.invalid"
        )

        let missingCustomTransitionID = try descriptorWithFirstHandlerAction([
            "type": "back", "transition": ["type": "custom"],
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: missingCustomTransitionID),
            is: "experience_release.descriptor.invalid"
        )

        let emptyGrant = try descriptorWithFirstHandlerAction([
            "type": "grant_entitlement", "featureId": "premium",
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: emptyGrant),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsInvalidOrUnsortedProducts() throws {
        let invalidPlatform = try mutatedValidDescriptor { root in
            root["products"] = [["id": "monthly", "platform": "future_store"]]
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalidPlatform),
            is: "experience_release.descriptor.invalid"
        )

        let unsorted = try mutatedValidDescriptor { root in
            root["products"] = [
                ["id": "yearly", "platform": "apple_app_store"],
                ["id": "monthly", "platform": "apple_app_store"],
            ]
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: unsorted),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testAcceptsPublisherUTF16ProductOrdering() throws {
        let descriptor = try mutatedValidDescriptor { root in
            root["products"] = [
                ["id": "\u{10000}", "platform": "apple_app_store"],
                ["id": "\u{E000}", "platform": "apple_app_store"],
            ]
        }
        XCTAssertNoThrow(try authenticate(descriptorBytes: descriptor))
    }

    func testAcceptsScriptAndShaderRenderAssets() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            render["assets"] = ["script", "shader"].enumerated().map { index, kind in
                let digest = String(format: "%064x", index + 100)
                return [
                    "kind": kind,
                    "key": "assets/sha256/\(digest).bin",
                    "sha256": digest,
                    "sizeBytes": 1024,
                    "contentType": "application/octet-stream",
                    "required": true,
                ] as [String: Any]
            }
            root["render"] = render
        }
        XCTAssertNoThrow(try authenticate(descriptorBytes: descriptor))
    }

    func testRejectsUnsortedOrUnknownLuauCompatibility() throws {
        let unsorted = try mutatedValidDescriptor { root in
            var compatibility = try XCTUnwrap(root["compatibility"] as? [String: Any])
            compatibility["luau"] = ["revision": "luau-1", "bytecodeVersions": [2, 1]]
            root["compatibility"] = compatibility
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: unsorted),
            is: "experience_release.descriptor.invalid"
        )

        let unknown = try mutatedValidDescriptor { root in
            var compatibility = try XCTUnwrap(root["compatibility"] as? [String: Any])
            var luau = try XCTUnwrap(compatibility["luau"] as? [String: Any])
            luau["futureBytecodePolicy"] = true
            compatibility["luau"] = luau
            root["compatibility"] = compatibility
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: unknown),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testCompatibilityFailsClosedForUnsupportedSdkRuntimeLuauAndScene() throws {
        let cases: [ExperienceReleaseSupportedCompatibility] = [
            supportedCompatibility(currentSdkVersion: "1.1.9"),
            supportedCompatibility(runtimeRevisions: []),
            supportedCompatibility(luauRevisions: [:]),
            supportedCompatibility(luauRevisions: ["luau-1": [1]]),
            supportedCompatibility(sceneFormatMajor: 2),
            supportedCompatibility(sceneFormatMinor: -1),
        ]
        for compatibility in cases {
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: validDescriptorBytes()),
                supportedCompatibility: compatibility,
                is: "experience_release.compatibility.unsupported"
            )
        }
    }

    func testRejectsFutureSceneMajorAndMinor() throws {
        for scene in [["major": 2, "minor": 0], ["major": 1, "minor": 1]] {
            let descriptor = try mutatedValidDescriptor { root in
                var compatibility = try XCTUnwrap(root["compatibility"] as? [String: Any])
                compatibility["sceneFormat"] = scene
                root["compatibility"] = compatibility
            }
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.compatibility.unsupported"
            )
        }
    }

    func testAcceptsJSONActionValueLargerThanGenericFieldBounds() throws {
        let descriptor = try descriptorWithFirstHandlerAction([
            "type": "set_response_field",
            "responseSchemaId": "response_plan",
            "key": "notes",
            "value": String(repeating: "x", count: 5_000),
        ])

        XCTAssertNoThrow(try authenticate(descriptorBytes: descriptor))
    }

    func testRejectsActionIntegerAboveJavaScriptSafeRange() throws {
        let descriptor = try descriptorWithFirstHandlerAction([
            "type": "list_remove",
            "path": ["kind": "path", "path": "items"],
            "index": 9_007_199_254_740_992,
        ])

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsNULDelimitedIdentityCollision() throws {
        let descriptor = try descriptorWithIdentity(
            experienceId: "experience\u{0}live\u{0}other",
            publishedAtSeq: 42
        )
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsUntrustedJSONNestingBeyondParserCeiling() throws {
        let nested = String(repeating: "[", count: 129)
            + "null"
            + String(repeating: "]", count: 129)
        XCTAssertThrowsError(
            try StrictJSONDuplicateKeyValidator.validate(Data(nested.utf8))
        )
    }

    func testAdmissionRejectsDowngradeAndIsolatesHighWaterKeys() async throws {
        let store = InMemoryExperienceReleaseHighWaterStore()
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(
            admission,
            descriptor: try descriptorWithIdentity(publishedAtSeq: 43)
        )

        do {
            _ = try await self.admit(
                admission,
                descriptor: self.validDescriptorBytes()
            )
            XCTFail("expected downgrade rejection")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.replay.rejected"
            )
        }

        let isolated = try descriptorWithIdentity(
            experienceId: "experience_isolated",
            publishedAtSeq: 1
        )
        _ = try await admit(admission, descriptor: isolated)
    }

    func testAdmissionAtomicallyRejectsConcurrentDowngrade() async throws {
        let store = InMemoryExperienceReleaseHighWaterStore()
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(
            admission,
            descriptor: try descriptorWithIdentity(publishedAtSeq: 43)
        )
        let results = await withTaskGroup(of: Result<Int, Error>.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        let admitted = try await self.admit(
                            admission,
                            descriptor: self.validDescriptorBytes()
                        )
                        return .success(admitted.descriptor.identity.publishedAtSeq)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var values: [Result<Int, Error>] = []
            for await value in group { values.append(value) }
            return values
        }
        let key = ExperienceReleaseHighWaterKey(
            appId: expectedIdentity.appId,
            environment: expectedIdentity.environment,
            experienceId: expectedIdentity.experienceId
        )
        let highWater = await store.highWater(for: key)
        XCTAssertEqual(highWater, 43)
        XCTAssertTrue(results.allSatisfy { result in
            guard case .failure(let error) = result else { return false }
            return (error as? ExperienceReleaseDescriptorAuthenticationError)
                == .replayRejected
        })
    }

    func testPersistentAdmissionRejectsDowngradeAfterStoreRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )
        try await admit(
            first,
            descriptor: try descriptorWithIdentity(publishedAtSeq: 43)
        )

        let afterRestart = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )
        do {
            _ = try await self.admit(
                afterRestart,
                descriptor: self.validDescriptorBytes()
            )
            XCTFail("expected persisted downgrade rejection")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.replay.rejected"
            )
        }
    }

    func testPersistentAdmissionFailsClosedOnCorruptHighWater() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistentExperienceReleaseHighWaterStore(directory: directory)
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(admission, descriptor: validDescriptorBytes())
        let stateFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "seq" })
        )
        try Data("not-a-sequence".utf8).write(to: stateFile, options: .atomic)

        let afterRestart = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )
        do {
            _ = try await admit(afterRestart, descriptor: validDescriptorBytes())
            XCTFail("expected corrupt replay state to fail closed")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.replay.rejected"
            )
        }
    }

    func testAdmissionPinnedRollbackDoesNotPromoteHighWater() async throws {
        let store = InMemoryExperienceReleaseHighWaterStore()
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(
            admission,
            descriptor: try descriptorWithIdentity(publishedAtSeq: 43)
        )
        let pinnedEnvelope = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let pinned = try await admission.authenticateAndAdmit(
            envelopeBytes: try JSONEncoder().encode(pinnedEnvelope),
            authorizationKeys: [authorizationKey],
            expectedIdentity: expectedIdentity,
            supportedCompatibility: supportedCompatibility,
            mode: .pinned(
                experienceVersionId: expectedIdentity.experienceVersionId,
                buildId: expectedIdentity.buildId,
                descriptorSHA256: pinnedEnvelope.descriptorSha256
            )
        )
        XCTAssertNil(pinned.publishedAtSeqToPromote)
        let key = ExperienceReleaseHighWaterKey(
            appId: expectedIdentity.appId,
            environment: expectedIdentity.environment,
            experienceId: expectedIdentity.experienceId
        )
        let highWater = await store.highWater(for: key)
        XCTAssertEqual(highWater, 43)
    }

    func testRejectsMoreThan256Screens() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            let screen = try XCTUnwrap((render["screens"] as? [Any])?.first)
            render["screens"] = Array(repeating: screen, count: 257)
            root["render"] = render
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsUnsafeRenderArtifactKey() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var riv = try XCTUnwrap(render["riv"] as? [String: Any])
            riv["key"] = "../renders/unsafe.riv"
            render["riv"] = riv
            root["render"] = render
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.artifact.unsafe_key"
        )
    }

    func testRejectsRivOver64MiB() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var riv = try XCTUnwrap(render["riv"] as? [String: Any])
            riv["sizeBytes"] = 67_108_865
            render["riv"] = riv
            root["render"] = render
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.malformed_bounds"
        )
    }

    func testRejectsExternalAssetOver32MiB() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var asset = try XCTUnwrap((render["assets"] as? [[String: Any]])?.first)
            asset["sizeBytes"] = 33_554_433
            render["assets"] = [asset]
            root["render"] = render
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.malformed_bounds"
        )
    }

    func testRejectsUniqueArtifactAggregateOver128MiB() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            let original = try XCTUnwrap((render["assets"] as? [[String: Any]])?.first)
            render["assets"] = (1...5).map { index in
                var asset = original
                let digest = String(format: "%064x", index)
                asset["key"] = "assets/sha256/\(digest).png"
                asset["sha256"] = digest
                asset["sizeBytes"] = 33_554_432
                return asset
            }
            root["render"] = render
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.malformed_bounds"
        )
    }

    private var authorizationKey: ExperiencePackageAuthorizationKey {
        ExperiencePackageAuthorizationKey(
            keyID: "TEST_ONLY_DEV_KEYPAIR",
            ed25519PublicKeyBytes: signingKey.publicKey.rawRepresentation
        )
    }

    private var expectedIdentity: ExperienceReleaseIdentityExpectation {
        ExperienceReleaseIdentityExpectation(
            appId: "app_golden",
            environment: "live",
            experienceId: "experience_golden",
            experienceVersionId: "version_golden",
            buildId: "build_golden",
            versionNumber: 7,
            publishedAt: "2026-08-12T12:00:00.000Z",
            publishedAtSeq: 42
        )
    }

    private var supportedCompatibility: ExperienceReleaseSupportedCompatibility {
        supportedCompatibility()
    }

    private func supportedCompatibility(
        capabilities: Set<String> = ["rive", "text-input"],
        currentSdkVersion: String = "1.2.0",
        runtimeRevisions: Set<String> = ["runtime-1"],
        luauRevisions: [String: Set<Int>] = ["luau-1": [1, 2]],
        sceneFormatMajor: Int = 1,
        sceneFormatMinor: Int = 0
    ) -> ExperienceReleaseSupportedCompatibility {
        ExperienceReleaseSupportedCompatibility(
            currentSdkVersion: currentSdkVersion,
            supportedRuntimeRevisions: runtimeRevisions,
            supportedLuauRevisions: luauRevisions,
            sceneFormat: .init(major: sceneFormatMajor, minor: sceneFormatMinor),
            supportedCapabilities: capabilities
        )
    }

    private func validDescriptorBytes() -> Data {
        let envelope = try! JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV1.self,
            from: fixtureData("envelope.json")
        )
        return Data(base64Encoded: envelope.descriptorBytesBase64)!
    }

    private func validDescriptorJSONObject() throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: validDescriptorBytes()) as? [String: Any]
        )
    }

    private func signedEnvelope(descriptorBytes: Data) throws -> Data {
        try JSONEncoder().encode(signedEnvelopeValue(descriptorBytes: descriptorBytes))
    }

    private func authenticate(
        descriptorBytes: Data,
        expectedIdentity: ExperienceReleaseIdentityExpectation? = nil,
        supportedCompatibility: ExperienceReleaseSupportedCompatibility? = nil
    ) throws -> AuthenticatedExperienceReleaseDescriptor {
        try ExperienceReleaseDescriptorVerifier().authenticate(
            envelopeBytes: signedEnvelope(descriptorBytes: descriptorBytes),
            authorizationKeys: [authorizationKey],
            expectedIdentity: expectedIdentity ?? self.expectedIdentity,
            supportedCompatibility: supportedCompatibility ?? self.supportedCompatibility,
            replayPolicy: .active(minimumPublishedAtSeq: 0)
        )
    }

    private func assertAuthenticationError(
        _ envelope: @autoclosure () throws -> Data,
        expectedIdentity: ExperienceReleaseIdentityExpectation? = nil,
        supportedCompatibility: ExperienceReleaseSupportedCompatibility? = nil,
        replayPolicy: ExperienceReleaseReplayPolicy = .active(minimumPublishedAtSeq: 0),
        is expectedCode: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ExperienceReleaseDescriptorVerifier().authenticate(
                envelopeBytes: envelope(),
                authorizationKeys: [authorizationKey],
                expectedIdentity: expectedIdentity ?? self.expectedIdentity,
                supportedCompatibility: supportedCompatibility ?? self.supportedCompatibility,
                replayPolicy: replayPolicy
            ),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                ($0 as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                expectedCode,
                file: file,
                line: line
            )
        }
    }

    private func replacing(_ target: String, with replacement: String) -> Data {
        let source = String(decoding: validDescriptorBytes(), as: UTF8.self)
        return Data(source.replacingOccurrences(of: target, with: replacement).utf8)
    }

    private func mutatedValidDescriptor(
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var root = try validDescriptorJSONObject()
        try mutation(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func descriptorWithFirstHandlerAction(
        _ action: [String: Any]
    ) throws -> Data {
        try mutatedValidDescriptor { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var handlers = try XCTUnwrap(journey["handlers"] as? [String: Any])
            let key = try XCTUnwrap(handlers.keys.sorted().first)
            var values = try XCTUnwrap(handlers[key] as? [[String: Any]])
            values[0]["actions"] = [action]
            handlers[key] = values
            journey["handlers"] = handlers
            root["journey"] = journey
        }
    }

    private func descriptorWithIdentity(
        experienceId: String? = nil,
        publishedAtSeq: Int
    ) throws -> Data {
        try mutatedValidDescriptor { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            if let experienceId { identity["experienceId"] = experienceId }
            identity["publishedAtSeq"] = publishedAtSeq
            root["identity"] = identity
        }
    }

    @discardableResult
    private func admit(
        _ admission: ExperienceReleaseAdmission,
        descriptor: Data
    ) async throws -> AuthenticatedExperienceReleaseDescriptor {
        let identity = try JSONDecoder().decode(
            ExperienceReleaseDescriptorV1.self,
            from: descriptor
        ).identity
        return try await admission.authenticateAndAdmit(
            envelopeBytes: signedEnvelope(descriptorBytes: descriptor),
            authorizationKeys: [authorizationKey],
            expectedIdentity: ExperienceReleaseIdentityExpectation(
                appId: identity.appId,
                environment: identity.environment,
                experienceId: identity.experienceId,
                experienceVersionId: identity.experienceVersionId,
                buildId: identity.buildId,
                versionNumber: identity.versionNumber,
                publishedAt: identity.publishedAt,
                publishedAtSeq: identity.publishedAtSeq
            ),
            supportedCompatibility: supportedCompatibility,
            mode: .active
        )
    }

    private func fixtureData(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(
            contentsOf: root
                .appendingPathComponent("fixtures/experience-release-descriptor-v1")
                .appendingPathComponent(name)
        )
    }

    private func signedEnvelopeValue(
        descriptorBytes: Data
    ) throws -> ExperienceReleaseDescriptorEnvelopeV1 {
        let signedBytes = Data(ExperienceReleaseDescriptorLimits.signatureDomain.utf8)
            + descriptorBytes
        let signature = try signingKey.signature(for: signedBytes)
        return ExperienceReleaseDescriptorEnvelopeV1(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: SHA256Provider.hexDigest(descriptorBytes),
            descriptorSizeBytes: descriptorBytes.count,
            descriptorBytesBase64: descriptorBytes.base64EncodedString(),
            signature: ExperienceReleaseDescriptorSignatureV1(
                version: 1,
                algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR",
                signatureBase64: signature.base64EncodedString()
            )
        )
    }
}
