#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
@testable import Nuxie

final class ExperienceInteractiveScreenTests: XCTestCase {
    func testAuthenticatedScriptedScreenRoutesExactProductEffectsInAuthoredOrder() async throws {
        let payload = try await authenticatedScriptedPayload()
        XCTAssertEqual(payload.authenticatedKeyID, "TEST_ONLY_DEV_KEYPAIR")
        let screen = try await ExperienceInteractiveScreen.open(
            payload: payload,
            player: .stateMachine("Generated Nuxie Pressable Interaction"),
            pixelWidth: 64,
            pixelHeight: 64
        )
        defer { Task { try? await screen.close() } }

        _ = try await render(screen)
        _ = try await screen.step(elapsedSeconds: 0.016)
        let result = try await screen.step(
            pointers: [
                ExperienceInteractivePointerEvent(
                    kind: .down,
                    x: 100,
                    y: 728,
                    pointerID: 1
                ),
                ExperienceInteractivePointerEvent(
                    kind: .up,
                    x: 100,
                    y: 728,
                    pointerID: 1
                ),
            ],
            elapsedSeconds: 0.016,
            correlationID: 42
        )

        XCTAssertEqual(result.effects.map(\.sequence), Array(0...4))
        XCTAssertEqual(result.effects.map(\.correlationID), Array(repeating: 42, count: 5))
        XCTAssertEqual(
            result.effects.map(\.kind),
            [
                .responseSet(field: "plan", value: .string("pro")),
                .journeyEvent(name: "purchase_tapped", payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])),
                .hostCommand(name: "selection_changed", payload: Self.object([
                    ("value", .string("annual"))
                ])),
                .hostCommand(name: "custom.analytics", payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])),
                .rejectedHostCommand(
                    name: "$response_set",
                    reason: "expected a non-empty string field and a value"
                ),
            ]
        )
    }

    func testAuthenticatedFactoryRejectsScreenOutsideSignedManifest() async throws {
        let payload = try await authenticatedScriptedPayload()
        do {
            _ = try await ExperienceInteractiveScreen.open(
                payload: payload,
                screenID: "unsigned-screen",
                player: .staticArtboard,
                pixelWidth: 16,
                pixelHeight: 16
            )
            XCTFail("Expected an unsigned screen to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ExperienceInteractiveScreenError,
                .screenNotFound("unsigned-screen")
            )
        }
    }

    func testAuthenticatedFactoryRejectsAssetOutsideSignedManifestAndSceneCatalog() async throws {
        let payload = try await authenticatedScriptedPayload()
        let tampered = AuthenticatedRuntimePayload(
            authenticatedKeyID: payload.authenticatedKeyID,
            manifest: payload.manifest,
            journey: payload.journey,
            sceneBytes: payload.sceneBytes,
            assets: [AuthenticatedRuntimeAsset(
                kind: .image,
                riveAssetID: 7,
                riveUniqueName: "unsigned-image-7",
                sourceKey: "assets/unsigned.png",
                contentType: "image/png",
                sha256: String(repeating: "0", count: 64),
                required: false,
                bytes: nil
            )]
        )
        do {
            _ = try await ExperienceInteractiveScreen.open(
                payload: tampered,
                player: .staticArtboard,
                pixelWidth: 16,
                pixelHeight: 16
            )
            XCTFail("Expected an unsigned asset to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ExperienceInteractiveScreenError,
                .assetContract("unsigned-image-7")
            )
        }
    }

    func testRouterPreservesPhaseAndCommandOrderWithExactCorrelations() {
        var router = ExperienceInteractiveEffectRouter()
        let reported = ExperienceInteractiveReportedEvent(
            localIndex: 0,
            coreType: 128,
            name: "opened",
            url: "",
            target: "",
            delay: 0,
            properties: []
        )
        let stateChange = ExperienceInteractiveStateChange(
            layerIndex: 1,
            coreType: 7,
            globalID: 9
        )
        let change = ExperienceInteractiveViewModelChange(
            origin: .runtime,
            correlationID: 77,
            ownerInstanceID: 4,
            propertyIndex: 2,
            value: .number(5)
        )
        let effects = router.project(
            reportedEvents: [reported],
            stateChanges: [stateChange],
            viewModelChanges: [change],
            hostCommands: scriptedCommands,
            declaredEventNames: ["purchase_tapped", "selection_changed"],
            validScreenIDs: ["screen_1", "screen_2"],
            correlationID: 42
        )

        XCTAssertEqual(effects.map(\.sequence), Array(0...7))
        XCTAssertEqual(effects.map(\.correlationID), [42, 42, 77, 42, 42, 42, 42, 42])
        XCTAssertEqual(
            effects.map(\.kind),
            [
                .reportedEvent(reported),
                .stateChange(stateChange),
                .viewModelChange(change),
                .responseSet(field: "plan", value: .string("pro")),
                .journeyEvent(name: "purchase_tapped", payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])),
                .journeyEvent(name: "selection_changed", payload: Self.object([
                    ("value", .string("annual"))
                ])),
                .hostCommand(name: "custom.analytics", payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])),
                .rejectedHostCommand(
                    name: "$response_set",
                    reason: "expected a non-empty string field and a value"
                ),
            ]
        )

        let next = router.project(
            reportedEvents: [],
            viewModelChanges: [],
            hostCommands: [ExperienceInteractiveHostCommand(
                name: "$navigate",
                payload: Self.object([
                    ("screenId", .string("screen_2")),
                    ("transition", .string("push")),
                ])
            )],
            declaredEventNames: [],
            validScreenIDs: ["screen_1", "screen_2"],
            correlationID: 100
        )
        XCTAssertEqual(next, [ExperienceInteractiveEffect(
            sequence: 8,
            correlationID: 100,
            kind: .navigate(screenID: "screen_2", transition: "push")
        )])
    }

    func testMalformedNavigationIsAProductRejectionAndDoesNotDropItsSiblings() {
        var router = ExperienceInteractiveEffectRouter()
        let effects = router.project(
            reportedEvents: [],
            viewModelChanges: [],
            hostCommands: [
                ExperienceInteractiveHostCommand(
                    name: "$navigate",
                    payload: Self.object([("screenId", .string("unsigned-screen"))])
                ),
                ExperienceInteractiveHostCommand(
                    name: "custom.after",
                    payload: .null
                ),
            ],
            declaredEventNames: [],
            validScreenIDs: ["screen_1"],
            correlationID: 9
        )

        XCTAssertEqual(effects, [
            ExperienceInteractiveEffect(
                sequence: 0,
                correlationID: 9,
                kind: .rejectedHostCommand(
                    name: "$navigate",
                    reason: "expected a declared screenId"
                )
            ),
            ExperienceInteractiveEffect(
                sequence: 1,
                correlationID: 9,
                kind: .hostCommand(name: "custom.after", payload: .null)
            ),
        ])
    }

    private var scriptedCommands: [ExperienceInteractiveHostCommand] {
        [
            ExperienceInteractiveHostCommand(
                name: "$response_set",
                payload: Self.object([
                    ("field", .string("plan")),
                    ("value", .string("pro")),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "purchase_tapped",
                payload: Self.object([
                    ("placementIndex", .number(2)),
                    ("productId", .string("pro_annual")),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "selection_changed",
                payload: Self.object([("value", .string("annual"))])
            ),
            ExperienceInteractiveHostCommand(
                name: "custom.analytics",
                payload: Self.object([
                    ("channel", .string("editor")),
                    ("sampled", .bool(true)),
                ])
            ),
            ExperienceInteractiveHostCommand(
                name: "$response_set",
                payload: Self.object([
                    ("field", .number(42)),
                    ("value", .string("rejected-in-swift")),
                ])
            ),
        ]
    }

    private static func object(
        _ fields: [(String, ExperienceInteractiveValue)]
    ) -> ExperienceInteractiveValue {
        .object(fields.map { ExperienceInteractiveField(key: $0.0, value: $0.1) })
    }

    private func authenticatedScriptedPayload() async throws
        -> AuthenticatedRuntimePayload
    {
        let encoded = try fixture(named: "scripted_generic_commands", extension: "nux.base64")
        guard let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let acquisition = try NuxPackageReader.read(bytes)
        let identity = acquisition.metadata.identity
        let packageURL = URL(fileURLWithPath: "/authenticated-fixtures/scripted.nux")
        let acquired = AcquiredExperiencePackage(
            remote: RemoteExperience(
                experienceId: identity.experienceId,
                versionId: identity.buildId,
                buildId: identity.buildId,
                artifact: RemoteExperienceArtifact(
                    url: packageURL.absoluteString,
                    sha256: SHA256Provider.hexDigest(bytes),
                    sizeBytes: bytes.count
                ),
                name: identity.experienceId,
                reentry: .everyTime,
                publishedAt: "2026-08-08T00:00:00Z"
            ),
            packageURL: packageURL,
            packageBytes: bytes,
            acquisition: acquisition,
            assetURLsByRiveUniqueName: [:],
            source: .cache,
            authorizationKeys: try ExperienceTrustRoots.keys(for: .development)
        )
        return try await SwiftExperiencePackageAuthenticator().authenticate(acquired)
    }

    private func render(_ screen: ExperienceInteractiveScreen) async throws
        -> ExperienceInteractiveRenderOutcome
    {
        let device = try await screen.metalDevice()
        let layer = CAMetalLayer()
        layer.device = device.value
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: 64, height: 64)
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        guard let drawable = layer.nextDrawable() else {
            throw XCTSkip("This host cannot vend a CAMetalDrawable")
        }
        return try await screen.render(
            drawable: ExperienceInteractiveDrawable(drawable),
            clearColor: 0xFF11_2233
        )
    }

    private func fixture(named name: String, extension fileExtension: String) throws -> Data {
        let testBundle = Bundle(for: Self.self)
        if let url = testBundle.url(forResource: name, withExtension: fileExtension) {
            return try Data(contentsOf: url)
        }
        let siblings = try FileManager.default.contentsOfDirectory(
            at: testBundle.bundleURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        for sibling in siblings where sibling.pathExtension == "bundle" {
            if let url = Bundle(url: sibling)?.url(
                forResource: name,
                withExtension: fileExtension
            ) {
                return try Data(contentsOf: url)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
#endif
