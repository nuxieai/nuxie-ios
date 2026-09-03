import CryptoKit
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

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
            supportedRuntime: supportedRuntime,
            replayPolicy: .active(minimumReleaseSequence: 42)
        )

        XCTAssertEqual(authenticated.exactDescriptorBytes, descriptor)
        XCTAssertEqual(authenticated.descriptor.identity, expectation.identity)
        XCTAssertEqual(authenticated.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR")
        XCTAssertEqual(authenticated.releaseSequenceToPromote, 42)
    }

    func testAuthenticatesSharedPublisherGoldenEnvelope() throws {
        let envelope = try fixtureData("envelope.json")
        let expectedEnvelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelope.self,
            from: envelope
        )
        let expectedIdentity = try JSONDecoder().decode(
            ExperienceReleaseIdentity.self,
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
                    releaseCreatedAt: expectedIdentity.releaseCreatedAt,
                    releaseSequence: expectedIdentity.releaseSequence
                ),
            supportedRuntime: supportedRuntime(
                capabilities: Set(capabilities)
            ),
            replayPolicy: .active(minimumReleaseSequence: 42)
            )
        } catch {
            XCTFail("golden envelope failed: \(error)")
            return
        }

        XCTAssertEqual(authenticated.descriptor.identity, expectedIdentity)
        XCTAssertEqual(authenticated.descriptorSHA256, expectedEnvelope.descriptorSha256)
        XCTAssertFalse(authenticated.exactDescriptorBytes.isEmpty)
        let definition = try ExperienceDefinition(
            descriptor: authenticated.descriptor
        )
        XCTAssertEqual(definition.entryRouteEventName, "$app_opened")
        XCTAssertNotNil(
            definition.route(host: .screen("screen_welcome"), eventName: "continue")
        )
        let purchaseRoute = try XCTUnwrap(
            definition.route(host: .screen("screen_welcome"), eventName: "purchase_tapped")
        )
        let purchaseProgram = try definition.compiledProgram(for: purchaseRoute)
        guard case .purchase(let purchase) = try XCTUnwrap(purchaseProgram.first) else {
            return XCTFail("root-published purchase route did not decode as a purchase")
        }
        let placementReference = try XCTUnwrap(
            purchase.placementId.value as? [String: Any]
        )
        let reference = try XCTUnwrap(placementReference["ref"] as? [String: Any])
        XCTAssertEqual(reference["kind"] as? String, "path")
        XCTAssertEqual(
            reference["path"] as? String,
            "paywall.selectedProduct.placementId"
        )
        XCTAssertNotNil(
            definition.control(screenId: "screen_welcome", actionId: "continue")
        )
        XCTAssertEqual(definition.responseSchema?.capturesByScreen["screen_welcome"], ["plan"])
    }

    func testRejectsTamperedInvalidJSONAsBadSignatureBeforeDescriptorDecode() throws {
        let signed = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let tamperedBytes = Data("{".utf8)
        let tampered = ExperienceReleaseDescriptorEnvelope(
            mediaType: signed.mediaType,
            encoding: signed.encoding,
            descriptorSha256: SHA256Provider.hexDigest(tamperedBytes),
            descriptorSizeBytes: tamperedBytes.count,
            descriptorBytesBase64: tamperedBytes.base64EncodedString(),
            signature: signed.signature
        )
        let envelope = try tampered.canonicalBytes()

        XCTAssertThrowsError(
            try ExperienceReleaseDescriptorVerifier().authenticate(
                envelopeBytes: envelope,
                authorizationKeys: [authorizationKey],
                expectedIdentity: expectedIdentity,
                supportedRuntime: supportedRuntime(capabilities: []),
                replayPolicy: .active(minimumReleaseSequence: 0)
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
            try envelope.canonicalBytes(),
            is: "experience_release.envelope.invalid"
        )
    }

    func testRejectsDescriptorDigestMismatch() throws {
        let signed = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let envelope = ExperienceReleaseDescriptorEnvelope(
            mediaType: signed.mediaType,
            encoding: signed.encoding,
            descriptorSha256: String(repeating: "0", count: 64),
            descriptorSizeBytes: signed.descriptorSizeBytes,
            descriptorBytesBase64: signed.descriptorBytesBase64,
            signature: signed.signature
        )

        assertAuthenticationError(
            try envelope.canonicalBytes(),
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
            releaseCreatedAt: expectedIdentity.releaseCreatedAt,
            releaseSequence: expectedIdentity.releaseSequence
        )

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: validDescriptorBytes()),
            expectedIdentity: mismatched,
            is: "experience_release.identity.mismatch"
        )
    }

    func testRejectsLegacyPublicationIdentityKeysWithoutFallback() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["publishedAt"] = identity.removeValue(forKey: "releaseCreatedAt")
            identity["publishedAtSeq"] = identity.removeValue(forKey: "releaseSequence")
            root["identity"] = identity
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsMixedCurrentAndLegacyPublicationIdentityKeys() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["publishedAt"] = identity["releaseCreatedAt"]
            identity["publishedAtSeq"] = identity["releaseSequence"]
            root["identity"] = identity
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsUnsupportedRequiredCapability() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
            requirements["requiredCapabilities"] = ["future_feature"]
            root["requirements"] = requirements
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.capability.unsupported"
        )
    }

    func testRejectsDuplicateRequiredCapabilitiesAsMalformedBounds() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
            requirements["requiredCapabilities"] = ["rive", "rive"]
            root["requirements"] = requirements
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            supportedRuntime: supportedRuntime(capabilities: ["rive"]),
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
            // The loading treatment left the contract; a descriptor that still
            // carries it is from a superseded grammar and must not authenticate.
            { $0["loading"] = ["style": "shimmer", "backgroundColor": "#000000FF"] },
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
                journey["entryRouteEventName"] = ""
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
            journey["entryRouteEventName"] = ""
            root["journey"] = journey
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalidKey),
            is: "experience_release.descriptor.invalid"
        )

        let oversized = try mutatedValidDescriptor { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            let first = try XCTUnwrap((journey["routes"] as? [Any])?.first)
            journey["routes"] = Array(repeating: first, count: 4_097)
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

    func testRejectsIDOnlyPurchasePlacementReference() throws {
        let descriptor = try descriptorWithFirstHandlerAction([
            "type": "purchase",
            "placementId": [
                "ref": [
                    "kind": "ids",
                    "pathIds": [0, 20, 17],
                ],
            ],
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testPurchaseLiteralMustNameSignedPlacement() throws {
        let descriptor = try descriptorWithFirstHandlerAction([
            "type": "purchase",
            "placementId": "missing:placement",
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testPurchasePathMustResolveCanonicalPlacementIDProperty() throws {
        let invalid = try descriptorWithFirstHandlerAction([
            "type": "purchase",
            "placementId": [
                "ref": [
                    "kind": "path",
                    "path": "paywall.selectedProduct.productId",
                ],
            ],
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalid),
            is: "experience_release.descriptor.invalid"
        )

        let canonical = try descriptorWithFirstHandlerAction([
            "type": "purchase",
            "placementId": [
                "ref": [
                    "kind": "path",
                    "path": "paywall.selectedProduct.placementId",
                ],
            ],
        ])
        XCTAssertNoThrow(try authenticate(descriptorBytes: canonical))
    }

    func testRejectsIdentityIntegersAboveJavaScriptSafeMaximum() throws {
        for field in ["versionNumber", "releaseSequence"] {
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

    func testReleaseCreatedAtMatchesZodOffsetDatetimeGrammar() throws {
        for releaseCreatedAt in [
            "2026-08-12 12:00:00Z",
            "2026-08-12T12:00:00z",
            "2026-08-12T12:00:00",
            "2026-08-12T12:00:00+0000",
            "2026-02-29T12:00:00Z",
            "2026-08-12T24:00:00Z",
        ] {
            let descriptor = try mutatedValidDescriptor { root in
                var identity = try XCTUnwrap(root["identity"] as? [String: Any])
                identity["releaseCreatedAt"] = releaseCreatedAt
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
        var responseSchema = try XCTUnwrap(oversizedSchemas["responseSchema"] as? [String: Any])
        let field = try XCTUnwrap((responseSchema["fields"] as? [Any])?.first)
        responseSchema["fields"] = Array(repeating: field, count: 257)
        oversizedSchemas["responseSchema"] = responseSchema
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
            replayPolicy: .active(minimumReleaseSequence: 43),
            is: "experience_release.replay.rejected"
        )
    }

    func testPinnedReplayPolicyPermitsExactRollbackWithoutPromotion() throws {
        let envelope = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let authenticated = try ExperienceReleaseDescriptorVerifier().authenticate(
            envelopeBytes: try envelope.canonicalBytes(),
            authorizationKeys: [authorizationKey],
            expectedIdentity: expectedIdentity,
            supportedRuntime: supportedRuntime,
            replayPolicy: .pinned(
                experienceVersionId: expectedIdentity.experienceVersionId,
                buildId: expectedIdentity.buildId,
                descriptorSHA256: envelope.descriptorSha256
            )
        )

        XCTAssertNil(authenticated.releaseSequenceToPromote)
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
            "type": "delay", "durationMs": 250,
        ])
        XCTAssertNoThrow(try authenticate(descriptorBytes: valid))

        let invalid = try descriptorWithFirstHandlerAction([
            "type": "delay",
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalid),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testTimeWindowUsesExactHHMMAndSourceWeekdayConvention() throws {
        let valid = try descriptorWithFirstHandlerAction([
            "type": "time_window",
            "startTime": "00:00",
            "endTime": "23:59",
            "timezone": ["kind": "iana", "identifier": "UTC"],
            "daysOfWeek": [0, 5, 6],
            "onInside": [],
        ])
        XCTAssertNoThrow(try authenticate(descriptorBytes: valid))

        for invalidTime in ["9:30", "24:00", "23:60", "💥:"] {
            let invalid = try descriptorWithFirstHandlerAction([
                "type": "time_window",
                "startTime": invalidTime,
                "endTime": "23:59",
                "timezone": ["kind": "iana", "identifier": "UTC"],
                "daysOfWeek": [0],
                "onInside": [],
            ])
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: invalid),
                is: "experience_release.descriptor.invalid"
            )
        }

        let invalidWeekday = try descriptorWithFirstHandlerAction([
            "type": "time_window",
            "startTime": "09:30",
            "endTime": "23:59",
            "timezone": ["kind": "iana", "identifier": "UTC"],
            "daysOfWeek": [7],
            "onInside": [],
        ])
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalidWeekday),
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

    }

    func testRejectsRemovedProviderFeatureAccessField() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var products = try XCTUnwrap(root["products"] as? [[String: Any]])
            products[0]["providerFeatureAccess"] = ["provider": "revenuecat"]
            root["products"] = products
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testAcceptsGooglePlayBasePlanAndOffer() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var products = try XCTUnwrap(root["products"] as? [[String: Any]])
            products[0]["store"] = [
                "platform": "google_play",
                "productId": "premium",
                "productType": "subscription",
                "basePlanId": "monthly",
                "purchaseOptionId": NSNull(),
            ]
            root["products"] = products
            var placements = try XCTUnwrap(root["placements"] as? [[String: Any]])
            placements[0]["googlePlay"] = ["offerId": "trial-7d"]
            root["placements"] = placements
        }

        XCTAssertNoThrow(try authenticate(descriptorBytes: descriptor))
    }

    func testRejectsGooglePlaySubscriptionWithoutBasePlan() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var products = try XCTUnwrap(root["products"] as? [[String: Any]])
            products[0]["store"] = [
                "platform": "google_play",
                "productId": "premium",
                "productType": "subscription",
                "basePlanId": NSNull(),
                "purchaseOptionId": NSNull(),
            ]
            root["products"] = products
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsGooglePlayOfferOnAppleProduct() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var placements = try XCTUnwrap(root["placements"] as? [[String: Any]])
            placements[0]["googlePlay"] = ["offerId": "trial-7d"]
            root["placements"] = placements
        }

        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: descriptor),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRejectsInvalidOrUnsortedProducts() throws {
        let invalidPlatform = try mutatedValidDescriptor { root in
            root["products"] = [[
                "id": "monthly",
                "type": "subscription",
                "store": [
                    "platform": "future_store",
                    "productId": "monthly",
                    "productType": "autoRenewable",
                ],
                "preview": productPreview("monthly"),
                "entitlements": [],
            ]]
            root["placements"] = [["id": "paywall:monthly", "productId": "monthly"]]
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: invalidPlatform),
            is: "experience_release.descriptor.invalid"
        )

        let unsorted = try mutatedValidDescriptor { root in
            root["products"] = [
                [
                    "id": "yearly", "type": "subscription",
                    "store": ["platform": "apple_app_store", "productId": "yearly", "productType": "autoRenewable"],
                    "preview": productPreview("yearly"),
                    "entitlements": [],
                ],
                [
                    "id": "monthly", "type": "subscription",
                    "store": ["platform": "apple_app_store", "productId": "monthly", "productType": "autoRenewable"],
                    "preview": productPreview("monthly"),
                    "entitlements": [],
                ],
            ]
            root["placements"] = [
                ["id": "paywall:monthly", "productId": "monthly"],
                ["id": "paywall:yearly", "productId": "yearly"],
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
                [
                    "id": "\u{10000}", "type": "subscription",
                    "store": ["platform": "apple_app_store", "productId": "store-a", "productType": "autoRenewable"],
                    "preview": productPreview("store-a"),
                    "entitlements": [],
                ],
                [
                    "id": "\u{E000}", "type": "subscription",
                    "store": ["platform": "apple_app_store", "productId": "store-b", "productType": "autoRenewable"],
                    "preview": productPreview("store-b"),
                    "entitlements": [],
                ],
            ]
            root["placements"] = [
                ["id": "placement-a", "productId": "\u{10000}"],
                ["id": "placement-b", "productId": "\u{E000}"],
            ]
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var routes = try XCTUnwrap(journey["routes"] as? [[String: Any]])
            routes[2]["program"] = [[
                "type": "purchase",
                "placementId": "placement-a",
            ]]
            journey["routes"] = routes
            root["journey"] = journey
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

    func testRejectsUnsortedOrUnknownLuauRuntimeRequirements() throws {
        let unsorted = try mutatedValidDescriptor { root in
            var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
            requirements["luau"] = ["revision": "luau-1", "bytecodeVersions": [2, 1]]
            root["requirements"] = requirements
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: unsorted),
            is: "experience_release.descriptor.invalid"
        )

        let unknown = try mutatedValidDescriptor { root in
            var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
            var luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
            luau["futureBytecodePolicy"] = true
            requirements["luau"] = luau
            root["requirements"] = requirements
        }
        assertAuthenticationError(
            try signedEnvelope(descriptorBytes: unknown),
            is: "experience_release.descriptor.invalid"
        )
    }

    func testRuntimeRequirementsFailClosedForUnsupportedSdkRuntimeLuauAndScene() throws {
        let cases: [ExperienceReleaseSupportedRuntime] = [
            supportedRuntime(currentSdkVersion: "1.1.9"),
            supportedRuntime(runtimeRevisions: []),
            supportedRuntime(luauRevisions: [:]),
            supportedRuntime(luauRevisions: ["luau-1": [1]]),
            supportedRuntime(sceneFormatMajor: 2),
            supportedRuntime(sceneFormatMinor: -1),
        ]
        for supportedRuntime in cases {
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: validDescriptorBytes()),
                supportedRuntime: supportedRuntime,
                is: "experience_release.runtime.unsupported"
            )
        }
    }

    func testEmbeddedRuntimeAdvertisesSceneFormat73AndAdmitsCompatibleMinorVersions() throws {
        let runtime = ExperienceReleaseRuntime.current
        XCTAssertEqual(runtime.sceneFormat, .init(major: 7, minor: 3))

        for minor in [0, 3] {
            XCTAssertNoThrow(
                try authenticate(
                    descriptorBytes: descriptorForCurrentRuntime(sceneFormatMinor: minor),
                    supportedRuntime: runtime
                )
            )
        }

        assertAuthenticationError(
            try signedEnvelope(
                descriptorBytes: descriptorForCurrentRuntime(sceneFormatMinor: 4)
            ),
            supportedRuntime: runtime,
            is: "experience_release.runtime.unsupported"
        )
    }

    func testRuntimeRejectsScreenActionsBeforeAcquisition() throws {
        let descriptor = try mutatedValidDescriptor { root in
            var screens = try XCTUnwrap(root["screenBehaviors"] as? [[String: Any]])
            var screen = try XCTUnwrap(screens.first)
            screen["controls"] = [[
                "actionId": "continue",
                "behavior": ["kind": "script"],
            ]]
            screen["script"] = [
                "protocol": "screen-actions",
                "artifact": [
                    "key": "screen-behavior/sha256/\(String(repeating: "c", count: 64)).bin",
                    "sha256": String(repeating: "c", count: 64),
                    "sizeBytes": 1,
                    "contentType": "application/octet-stream",
                ],
                "exportedActionIds": ["continue"],
            ]
            screens[0] = screen
            root["screenBehaviors"] = screens
        }

        XCTAssertThrowsError(try authenticate(descriptorBytes: descriptor)) { error in
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .unsupportedRuntime("screen_actions")
            )
        }
    }

    func testRejectsFutureSceneMajorAndMinor() throws {
        for scene in [["major": 2, "minor": 0], ["major": 1, "minor": 1]] {
            let descriptor = try mutatedValidDescriptor { root in
                var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
                requirements["sceneFormat"] = scene
                root["requirements"] = requirements
            }
            assertAuthenticationError(
                try signedEnvelope(descriptorBytes: descriptor),
                is: "experience_release.runtime.unsupported"
            )
        }
    }

    func testAcceptsJSONActionValueLargerThanGenericFieldBounds() throws {
        let descriptor = try descriptorWithFirstHandlerAction([
            "type": "send_event",
            "eventName": "large_payload",
            "payload": [
                "notes": ["type": "String", "value": String(repeating: "x", count: 5_000)],
            ],
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
            releaseSequence: 42
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
            descriptor: try descriptorWithIdentity(releaseSequence: 43)
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
            releaseSequence: 1
        )
        _ = try await admit(admission, descriptor: isolated)
    }

    func testAdmissionAtomicallyRejectsConcurrentDowngrade() async throws {
        let store = InMemoryExperienceReleaseHighWaterStore()
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(
            admission,
            descriptor: try descriptorWithIdentity(releaseSequence: 43)
        )
        let results = await withTaskGroup(of: Result<Int, Error>.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        let admitted = try await self.admit(
                            admission,
                            descriptor: self.validDescriptorBytes()
                        )
                        return .success(admitted.descriptor.identity.releaseSequence)
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
        XCTAssertEqual(highWater?.releaseSequence, 43)
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
            descriptor: try descriptorWithIdentity(releaseSequence: 43)
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

    func testPersistentAdmissionRejectsDifferentReleaseAtEqualSequenceAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDescriptor = try descriptorWithIdentity(releaseSequence: 43)
        let first = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )
        try await admit(first, descriptor: firstDescriptor)

        let conflicting = try mutatedValidDescriptor { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            identity["experienceVersionId"] = "version_equal_seq_conflict"
            identity["buildId"] = "build_equal_seq_conflict"
            identity["releaseSequence"] = 43
            root["identity"] = identity
        }
        let afterRestart = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )

        do {
            _ = try await admit(afterRestart, descriptor: conflicting)
            XCTFail("expected equal-sequence release substitution rejection")
        } catch {
            XCTAssertEqual(
                (error as? ExperienceReleaseDescriptorAuthenticationError)?.contractCode,
                "experience_release.replay.rejected"
            )
        }
    }

    func testPersistentAdmissionAcceptsExactReleaseAtEqualSequenceAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try descriptorWithIdentity(releaseSequence: 43)
        let first = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )
        let initiallyAdmitted = try await admit(first, descriptor: descriptor)

        let afterRestart = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )
        let readmitted = try await admit(afterRestart, descriptor: descriptor)

        XCTAssertEqual(readmitted.descriptor.identity, initiallyAdmitted.descriptor.identity)
        XCTAssertEqual(readmitted.descriptorSHA256, initiallyAdmitted.descriptorSHA256)
    }

    func testDefaultReleaseStorageKeepsReplayLedgerOutOfPurgeableCaches() throws {
        let caches = URL(fileURLWithPath: "/test/Library/Caches", isDirectory: true)
        let support = URL(
            fileURLWithPath: "/test/Library/Application Support",
            isDirectory: true
        )
        let resolved = ExperienceReleaseStoragePaths.resolve(
            customStoragePath: nil,
            cachesDirectory: caches,
            applicationSupportDirectory: support
        )

        XCTAssertTrue(resolved.objects.path.hasPrefix(caches.path))
        XCTAssertTrue(try XCTUnwrap(resolved.admission).path.hasPrefix(support.path))
        XCTAssertFalse(try XCTUnwrap(resolved.admission).path.hasPrefix(caches.path))

        let custom = URL(fileURLWithPath: "/test/custom", isDirectory: true)
        let customized = ExperienceReleaseStoragePaths.resolve(
            customStoragePath: custom,
            cachesDirectory: caches,
            applicationSupportDirectory: support
        )
        XCTAssertTrue(customized.objects.path.hasPrefix(custom.path))
        XCTAssertTrue(try XCTUnwrap(customized.admission).path.hasPrefix(custom.path))

        let missingSupport = ExperienceReleaseStoragePaths.resolve(
            customStoragePath: nil,
            cachesDirectory: caches,
            applicationSupportDirectory: nil
        )
        XCTAssertTrue(missingSupport.objects.path.hasPrefix(caches.path))
        XCTAssertNil(missingSupport.admission)
    }

    func testPersistentAdmissionFailsClosedOnCorruptHighWater() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistentExperienceReleaseHighWaterStore(directory: directory)
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(admission, descriptor: validDescriptorBytes())
        let stateFile = directory.appendingPathComponent("high-water-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))
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

    func testPersistentAdmissionRejectsLegacyReplayLedgerWithoutFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistentExperienceReleaseHighWaterStore(directory: directory)
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(admission, descriptor: validDescriptorBytes())
        let stateFile = directory.appendingPathComponent("high-water-v1.json")
        var ledger = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateFile))
                as? [String: Any]
        )
        let key = try XCTUnwrap(ledger.keys.first)
        var mark = try XCTUnwrap(ledger[key] as? [String: Any])
        mark["publishedAt"] = mark.removeValue(forKey: "releaseCreatedAt")
        mark["publishedAtSeq"] = mark.removeValue(forKey: "releaseSequence")
        ledger[key] = mark
        try JSONSerialization.data(withJSONObject: ledger)
            .write(to: stateFile, options: .atomic)

        let afterRestart = ExperienceReleaseAdmission(
            store: try PersistentExperienceReleaseHighWaterStore(directory: directory)
        )
        do {
            _ = try await admit(afterRestart, descriptor: validDescriptorBytes())
            XCTFail("expected legacy replay state to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ExperienceReleaseDescriptorAuthenticationError,
                .replayRejected
            )
        }
    }

    func testAdmissionPinnedRollbackDoesNotPromoteHighWater() async throws {
        let store = InMemoryExperienceReleaseHighWaterStore()
        let admission = ExperienceReleaseAdmission(store: store)
        try await admit(
            admission,
            descriptor: try descriptorWithIdentity(releaseSequence: 43)
        )
        let pinnedEnvelope = try signedEnvelopeValue(descriptorBytes: validDescriptorBytes())
        let pinned = try await admission.authenticateAndAdmit(
            envelopeBytes: try pinnedEnvelope.canonicalBytes(),
            authorizationKeys: [authorizationKey],
            expectedIdentity: expectedIdentity,
            supportedRuntime: supportedRuntime,
            mode: .pinned(
                experienceVersionId: expectedIdentity.experienceVersionId,
                buildId: expectedIdentity.buildId,
                descriptorSHA256: pinnedEnvelope.descriptorSha256
            )
        )
        XCTAssertNil(pinned.releaseSequenceToPromote)
        let key = ExperienceReleaseHighWaterKey(
            appId: expectedIdentity.appId,
            environment: expectedIdentity.environment,
            experienceId: expectedIdentity.experienceId
        )
        let highWater = await store.highWater(for: key)
        XCTAssertEqual(highWater?.releaseSequence, 43)
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
            releaseCreatedAt: "2026-08-12T12:00:00.000Z",
            releaseSequence: 42
        )
    }

    private var supportedRuntime: ExperienceReleaseSupportedRuntime {
        supportedRuntime()
    }

    private func supportedRuntime(
        capabilities: Set<String> = ["rive", "text-input"],
        currentSdkVersion: String = "1.2.0",
        runtimeRevisions: Set<String> = ["runtime-1"],
        luauRevisions: [String: Set<Int>] = ["luau-1": [1, 2]],
        sceneFormatMajor: Int = 1,
        sceneFormatMinor: Int = 0
    ) -> ExperienceReleaseSupportedRuntime {
        ExperienceReleaseSupportedRuntime(
            currentSdkVersion: currentSdkVersion,
            supportedRuntimeRevisions: runtimeRevisions,
            supportedLuauRevisions: luauRevisions,
            sceneFormat: .init(major: sceneFormatMajor, minor: sceneFormatMinor),
            timezoneDataRevision: "2026c",
            timezoneDataSHA256: SignedTimezoneBundle.sha256,
            supportedCapabilities: capabilities
        )
    }

    private func validDescriptorBytes() -> Data {
        let envelope = try! JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelope.self,
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
        try signedEnvelopeValue(descriptorBytes: descriptorBytes).canonicalBytes()
    }

    private func authenticate(
        descriptorBytes: Data,
        expectedIdentity: ExperienceReleaseIdentityExpectation? = nil,
        supportedRuntime: ExperienceReleaseSupportedRuntime? = nil
    ) throws -> AuthenticatedExperienceReleaseDescriptor {
        try ExperienceReleaseDescriptorVerifier().authenticate(
            envelopeBytes: signedEnvelope(descriptorBytes: descriptorBytes),
            authorizationKeys: [authorizationKey],
            expectedIdentity: expectedIdentity ?? self.expectedIdentity,
            supportedRuntime: supportedRuntime ?? self.supportedRuntime,
            replayPolicy: .active(minimumReleaseSequence: 0)
        )
    }

    private func assertAuthenticationError(
        _ envelope: @autoclosure () throws -> Data,
        expectedIdentity: ExperienceReleaseIdentityExpectation? = nil,
        supportedRuntime: ExperienceReleaseSupportedRuntime? = nil,
        replayPolicy: ExperienceReleaseReplayPolicy = .active(minimumReleaseSequence: 0),
        is expectedCode: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ExperienceReleaseDescriptorVerifier().authenticate(
                envelopeBytes: envelope(),
                authorizationKeys: [authorizationKey],
                expectedIdentity: expectedIdentity ?? self.expectedIdentity,
                supportedRuntime: supportedRuntime ?? self.supportedRuntime,
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

    private func descriptorForCurrentRuntime(sceneFormatMinor: Int) throws -> Data {
        let runtime = ExperienceReleaseRuntime.current
        let runtimeRevision = try XCTUnwrap(runtime.supportedRuntimeRevisions.sorted().first)
        let luauRevision = try XCTUnwrap(runtime.supportedLuauRevisions.keys.sorted().first)
        let luauBytecodeVersions = try XCTUnwrap(runtime.supportedLuauRevisions[luauRevision])

        return try mutatedValidDescriptor { root in
            root["requirements"] = [
                "minimumSdkVersion": runtime.currentSdkVersion,
                "runtimeRevision": runtimeRevision,
                "luau": [
                    "revision": luauRevision,
                    "bytecodeVersions": luauBytecodeVersions.sorted(),
                ],
                "sceneFormat": [
                    "major": runtime.sceneFormat.major,
                    "minor": sceneFormatMinor,
                ],
                "timezoneData": [
                    "format": "iana-tzdb",
                    "revision": runtime.timezoneDataRevision,
                    "sha256": runtime.timezoneDataSHA256,
                ],
                "requiredCapabilities": runtime.supportedCapabilities.sorted(),
            ]
        }
    }

    private func descriptorWithFirstHandlerAction(
        _ action: [String: Any]
    ) throws -> Data {
        try mutatedValidDescriptor { root in
            var journey = try XCTUnwrap(root["journey"] as? [String: Any])
            var routes = try XCTUnwrap(journey["routes"] as? [[String: Any]])
            let index = try XCTUnwrap(routes.firstIndex { route in
                guard let host = route["host"] as? [String: Any] else { return false }
                return host["kind"] as? String == "journey"
            })
            routes[index]["program"] = [action]
            journey["routes"] = routes
            root["journey"] = journey
        }
    }

    private func descriptorWithIdentity(
        experienceId: String? = nil,
        releaseSequence: Int
    ) throws -> Data {
        try mutatedValidDescriptor { root in
            var identity = try XCTUnwrap(root["identity"] as? [String: Any])
            if let experienceId { identity["experienceId"] = experienceId }
            identity["releaseSequence"] = releaseSequence
            root["identity"] = identity
        }
    }

    private func productPreview(_ name: String) -> [String: Any] {
        [
            "name": name,
            "description": "",
            "price": "",
            "period": "",
            "periodCount": 0,
            "periodLabel": "",
            "hasTrial": false,
            "trialLabel": "",
            "introOfferLabel": "",
            "renewalLabel": "",
        ]
    }

    @discardableResult
    private func admit(
        _ admission: ExperienceReleaseAdmission,
        descriptor: Data
    ) async throws -> AuthenticatedExperienceReleaseDescriptor {
        let identity = try JSONDecoder().decode(
            ExperienceReleaseDescriptor.self,
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
                releaseCreatedAt: identity.releaseCreatedAt,
                releaseSequence: identity.releaseSequence
            ),
            supportedRuntime: supportedRuntime,
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
                .appendingPathComponent("fixtures/experience-release-descriptor")
                .appendingPathComponent(name)
        )
    }

    private func signedEnvelopeValue(
        descriptorBytes: Data
    ) throws -> ExperienceReleaseDescriptorEnvelope {
        let signedBytes = Data(ExperienceReleaseDescriptorLimits.signatureDomain.utf8)
            + descriptorBytes
        let signature = try signingKey.signature(for: signedBytes)
        return ExperienceReleaseDescriptorEnvelope(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: SHA256Provider.hexDigest(descriptorBytes),
            descriptorSizeBytes: descriptorBytes.count,
            descriptorBytesBase64: descriptorBytes.base64EncodedString(),
            signature: ExperienceReleaseDescriptorSignature(
                version: 1,
                algorithm: "ed25519",
                keyId: "TEST_ONLY_DEV_KEYPAIR",
                signatureBase64: signature.base64EncodedString()
            )
        )
    }
}
