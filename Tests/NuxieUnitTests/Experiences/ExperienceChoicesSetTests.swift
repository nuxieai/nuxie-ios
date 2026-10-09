#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceChoicesSetTests: XCTestCase {
    func testPublishedScriptReplacesChoicesAtomicallyAndNilKeepsRecords() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("choices-set")
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        let release = try JSONDecoder().decode(JourneyReleaseDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("release.json")))
        let payload = AuthenticatedRuntimePayload(valuePolicy: release.valuePolicy,
            authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR", requiredCapabilities: ["system-fonts"],
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(experienceId: "choices-set", buildId: "choices-set-build", appId: "test-app", environment: "test"),
                scene: .init(key: "screen.riv", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
                entry: .init(screenId: "first"),
                screens: [.init(screenId: "first", artboardId: "scr_screens_sfirst", artboardName: "first", width: 300, height: 300, exit: nil)],
                transitions: [], textInputs: [], images: [], fonts: [],
                systemFonts: [.init(authoredAssetId: 0, assetUniqueName: "font-system-400-normal-6cda3de3-0", weight: "400", style: "normal")]),
            journey: JourneyDocument(screens: [.init(id: "first", defaultViewModelName: "Runtime first scr_screens_sfirst", defaultInstanceId: "first-root")], viewModelValues: []),
            sceneBytes: scene, assets: [])
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let screen = try await preparation.openScreen(screenID: "first", runValues: run, pixelWidth: 300, pixelHeight: 300)
        addTeardownBlock { try await screen.close() }
        try await screen.enableSemantics()
        try assertChoices(try await screen.snapshot(), picked: [true, false, false], errors: [])

        // These expectations are authored independently in the shared fixture.
        let picks = [[true, false, false], [false, true, false], [false, false, false]]
        for index in 0..<3 {
            let bounds = try await saveBounds(screen)
            let down = try await screen.step(pointers: [.init(kind: .down, x: Float(bounds.midX), y: Float(bounds.midY))], elapsedSeconds: 0)
            XCTAssertTrue(down.pointerHits.contains { $0 != .none }, "The published Save control must receive the tap")
            let up = try await screen.step(pointers: [.init(kind: .up, x: Float(bounds.midX), y: Float(bounds.midY))], elapsedSeconds: 0)
            let advance = try await screen.step(elapsedSeconds: 1.0 / 60.0)
            let commands = (down.effects + up.effects + advance.effects).compactMap { effect -> ExperienceInteractiveValue? in
                guard case .hostCommand(let name, let value) = effect.kind, name == "checked" else { return nil }
                return value
            }
            XCTAssertEqual(commands.count, 1)
            let command = try XCTUnwrap(commands.first)
            XCTAssertEqual(command["ok"], .bool(index != 0))
            XCTAssertEqual(command["rule"], index == 0 ? .string("maxItems") : nil)
            try assertChoices(try await screen.snapshot(), picked: picks[index],
                errors: index == 0 ? [["maxItems", "Choose fewer options."]] : [])
        }
    }

    private func assertChoices(_ snapshot: ExperienceInteractiveViewModelSnapshot, picked: [Bool], errors: [[String]], file: StaticString = #filePath, line: UInt = #line) throws {
        func value(_ owner: UInt64, _ name: String) throws -> ExperienceInteractiveViewModelValue {
            try XCTUnwrap(snapshot.values.first { $0.ownerInstanceID == owner && $0.name == name }?.value, file: file, line: line)
        }
        func reference(_ owner: UInt64, _ name: String) throws -> UInt64 {
            guard case .referencedInstance(let id) = try value(owner, name) else { throw CocoaError(.coderInvalidValue) }
            return id
        }
        let experience = try reference(snapshot.rootInstanceID, "experience")
        let answers = try reference(experience, "responses:signup")
        guard case .list(let records) = try value(answers, "picks") else { throw CocoaError(.coderInvalidValue) }
        XCTAssertEqual(records.count, 3, file: file, line: line)
        XCTAssertEqual(try records.map { try value($0, "picked") }, picked.map { .bool($0) }, file: file, line: line)
        XCTAssertEqual(try records.map { try value($0, "value") }, ["a", "b", "c"].map { .bytes(Data($0.utf8)) }, file: file, line: line)
        let errorOwner = try reference(answers, "errors")
        guard case .list(let rows) = try value(errorOwner, "picks") else { throw CocoaError(.coderInvalidValue) }
        XCTAssertEqual(try rows.map { row in try [value(row, "rule"), value(row, "message")] },
            errors.map { $0.map { .bytes(Data($0.utf8)) } }, file: file, line: line)
    }

    private func saveBounds(_ screen: ExperienceInteractiveScreen) async throws -> CGRect {
        let layer = CAMetalLayer()
        layer.device = try await screen.metalDevice().value
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 300, height: 300)
        let drawable = try XCTUnwrap(layer.nextDrawable())
        let completed = expectation(description: "choices frame presented")
        let frame = try await screen.renderFrame(layoutScaleFactor: 1, drawable: ExperienceInteractiveDrawable(drawable),
            capturesSemantics: true, completion: { completed.fulfill() })
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(frame.outcome.disposition, .presented)
        let node = try XCTUnwrap(frame.semantics?.tree.nodes.first { $0.label == "Save" || $0.value == "Save" })
        XCTAssertGreaterThan(node.bounds.width, 0)
        XCTAssertGreaterThan(node.bounds.height, 0)
        return node.bounds
    }
}
#endif
