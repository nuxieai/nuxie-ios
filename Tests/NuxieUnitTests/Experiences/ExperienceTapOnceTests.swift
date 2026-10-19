#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

/// One tap on a repeated row, on a copy, or on a Buy button that is itself
/// a copy reports its event once, through the SDK's own player selection
/// and effect routing ([UNIV-3942](https://universe.basis.dev/issue/UNIV-3942)).
/// Subscribe is a copy with no props of its own, so its own `press` event
/// passes the source check a copy with props fails; the publisher reserves
/// that event's name, and a scene published before it did reported `press`
/// beside `purchase` here. The fixture is the parent repository's
/// `tools/sdk-fixtures/tap-once`, and the points are its `TAP_ONCE_POINTS`,
/// worked out from the CSS.
final class ExperienceTapOnceTests: XCTestCase {
    private static var directory: URL {
        SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("tap-once")
    }

    func testEachTapOnARowOrACopyReportsItsEventOnce() async throws {
        for together in [false, true] {
            let screen = try await ExperienceInteractiveScreen.open(
                payload: try Self.payload(), pixelWidth: 390, pixelHeight: 640)
            for _ in 0..<4 { _ = try await screen.step(elapsedSeconds: 1.0 / 60.0) }
            let mode = together ? "down and up in one step" : "down and up in their own steps"
            var chosen = try await Self.chosen(screen)
            XCTAssertEqual(chosen, "monthly", mode)
            for (card, y, value) in [("Annual", 168, "annual"), ("Lifetime", 256, "lifetime"),
                                     ("Monthly", 84, "monthly"), ("Annual", 168, "annual")] {
                let names = try await Self.tap(screen, x: 195, y: Float(y), together: together)
                XCTAssertEqual(names, ["picked"], "\(card), \(mode)")
                chosen = try await Self.chosen(screen)
                XCTAssertEqual(chosen, value, "\(card), \(mode)")
            }
            for _ in 0..<3 {
                let names = try await Self.tap(screen, x: 195, y: 336, together: together)
                XCTAssertEqual(names, ["purchase"], "Subscribe, \(mode)")
            }
            let names = try await Self.tap(screen, x: 195, y: 404, together: together)
            XCTAssertEqual(names, ["restore"], "Restore, \(mode)")
            try await screen.close()
        }
    }

    /// What the screen view controller routes from one tap: a link, a
    /// control, or a named event, which becomes an emission of the screen
    /// unless its name is reserved (`deliverStep` drops those).
    private static func tap(_ screen: ExperienceInteractiveScreen, x: Float, y: Float,
                            together: Bool) async throws -> [String] {
        let down = ExperienceInteractivePointerEvent(kind: .down, x: x, y: y)
        let up = ExperienceInteractivePointerEvent(kind: .up, x: x, y: y)
        var effects: [ExperienceInteractiveEffect] = []
        if together {
            effects += try await screen.step(pointers: [down, up], elapsedSeconds: 0).effects
        } else {
            effects += try await screen.step(pointers: [down], elapsedSeconds: 0).effects
            effects += try await screen.step(pointers: [up], elapsedSeconds: 0).effects
        }
        for _ in 0..<3 { effects += try await screen.step(elapsedSeconds: 1.0 / 60.0).effects }
        func emitted(_ name: String) -> String? {
            name.isEmpty || ScreenEmissionDraft.event(name: name, payload: [:]).isReservedEvent ? nil : name
        }
        return effects.compactMap { effect in
            switch effect.kind {
            case .reportedEvent(let event):
                if !event.url.isEmpty { return "open \(event.url)" }
                return emitted(event.name)
            case .controlAction(let actionId, _): return actionId
            case .journeyEvent(let name, _), .hostCommand(let name, _): return emitted(name)
            case .viewModelChange, .rejectedHostCommand: return nil
            }
        }
    }

    /// The screen's `state.chosen`, which a card writes when it is tapped.
    private static func chosen(_ screen: ExperienceInteractiveScreen) async throws -> String? {
        let snapshot = try await screen.snapshot()
        guard case .referencedInstance(let state) = snapshot.values.first(where: {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "state"
        })?.value, case .bytes(let chosen) = snapshot.values.first(where: {
            $0.ownerInstanceID == state && $0.name == "chosen"
        })?.value else { return nil }
        return String(data: chosen, encoding: .utf8)
    }

    private static func payload() throws -> AuthenticatedRuntimePayload {
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        struct Provenance: Decodable {
            struct Font: Decodable {
                let authoredAssetId: UInt64
                let assetUniqueName: String
                let weight: String
                let style: String
            }
            let fonts: [Font]
        }
        let provenance = try JSONDecoder().decode(Provenance.self,
            from: Data(contentsOf: directory.appendingPathComponent("provenance.json")))
        return AuthenticatedRuntimePayload(authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
            requiredCapabilities: ["system-fonts"],
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(experienceId: "tap-once", buildId: "tap-once-build", appId: "test-app", environment: "test"),
                scene: .init(key: "screen.riv", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
                entry: .init(screenId: "plans"),
                screens: [.init(screenId: "plans", artboardId: "scr_screens_splans", artboardName: "plans",
                                width: 390, height: 640, exit: nil)],
                transitions: [], textInputs: [], images: [], fonts: [],
                systemFonts: provenance.fonts.map { .init(authoredAssetId: $0.authoredAssetId,
                    assetUniqueName: $0.assetUniqueName, weight: $0.weight, style: $0.style) }),
            journey: JourneyDocument(screens: [JourneyScreen(id: "plans",
                defaultViewModelName: "vm_runtime_root_scr_screens_splans",
                defaultInstanceId: "vmi_runtime_scr_screens_splans")],
                viewModelValues: []),
            sceneBytes: scene, assets: [])
    }
}
#endif
