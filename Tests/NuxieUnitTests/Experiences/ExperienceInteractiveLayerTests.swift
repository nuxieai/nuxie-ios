#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

final class ExperienceInteractiveLayerTests: XCTestCase {
    func testRowsRunTheirDefaultMachinesAndKeepValuesAcrossRemovalAndRevisit() async throws {
        try await withLayer { layer, preparation in
            try await layer.insert(screenID: "screen_1", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            _ = try await layer.step(elapsedSeconds: 0.25)
            let a = try await layer.snapshot(screenID: "screen_1")
            XCTAssertGreaterThan(try self.number(a, "rowWidth"), 0)
            XCTAssertGreaterThan(try self.number(a, "markerX"), 0)
            try await layer.insert(screenID: "screen_2", at: 1)
            _ = try await layer.step(elapsedSeconds: 0)
            let b = try await layer.snapshot(screenID: "screen_2")
            XCTAssertNotEqual(a.rootInstanceID, b.rootInstanceID)
            XCTAssertNotEqual(a.instances.first?.schemaIndex, b.instances.first?.schemaIndex)
            XCTAssertGreaterThan(try self.number(b, "rowWidth"), 0)
            let both = await layer.mountedScreenIDs
            XCTAssertEqual(both, ["screen_1", "screen_2"])
            do { try await layer.insert(screenID: "screen_2", at: 1); XCTFail("Duplicate row accepted") }
            catch {}
            _ = try await layer.applyJourneyState(.value(.init(viewModelName: "Runtime_Upsell",
                instanceID: "row-b", instanceName: nil, path: "keptValue", value: .number(42))), screenID: "screen_2")
            try await layer.remove(screenID: "screen_1")
            _ = try await layer.step(elapsedSeconds: 0.5)
            let kept = try await layer.snapshot(screenID: "screen_2")
            XCTAssertEqual(kept.rootInstanceID, b.rootInstanceID)
            XCTAssertEqual(try self.number(kept, "keptValue"), 42)
            XCTAssertGreaterThan(try self.number(kept, "markerX"), 100)
            try await layer.remove(screenID: "screen_2")
            _ = try await layer.step(elapsedSeconds: 0)
            try await layer.insert(screenID: "screen_2", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            let revisited = try await layer.snapshot(screenID: "screen_2")
            XCTAssertEqual(revisited.rootInstanceID, b.rootInstanceID)
            XCTAssertEqual(try self.number(revisited, "keptValue"), 42)
            XCTAssertEqual(try self.number(revisited, "markerX"), 0, accuracy: 0.01)
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 1)
        }
    }

    func testIncomingOrderUsesTheLowerRowOnlyForPushBack() async throws {
        for (style, back, expected) in [(ExperienceScreenTransitionSpec.Kind.push, true, ["screen_2", "screen_1"]),
            (.push, false, ["screen_1", "screen_2"]), (.magicMove, true, ["screen_1", "screen_2"]),
            (.fade, true, ["screen_1", "screen_2"])] {
            try await withLayer { layer, _ in
                try await layer.insert(screenID: "screen_1", at: 0)
                try await layer.insertIncoming(screenID: "screen_2", style: style, isBack: back)
                _ = try await layer.step(elapsedSeconds: 0)
                let mounted = await layer.mountedScreenIDs
                XCTAssertEqual(mounted, expected)
            }
        }
    }

    func testForwardAndReverseCompletionEventsKeepTheirRowSources() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            for reverse in [false, true] {
                if !reverse {
                    try await layer.insertIncoming(screenID: "screen_2", style: .magicMove, isBack: false)
                }
                let outgoing = reverse ? "screen_2" : "screen_1"
                let incoming = reverse ? "screen_1" : "screen_2"
                let suffix = reverse ? ".reverse" : ""
                let names = ["nx_exit_done:transition.native-contract" + suffix,
                             "nx_enter_done:transition.native-contract" + suffix]
                let outWaiter = try await layer.registerCompletion(screenID: outgoing, eventName: names[0])
                let inWaiter = try await layer.registerCompletion(screenID: incoming, eventName: names[1])
                try await layer.setPhases([(outgoing, .exiting), (incoming, .entering)],
                    transition: "transition.native-contract")
                var found: [String: UInt64] = [:]
                var attributed: [String: Set<String>] = [:]
                for _ in 0..<42 {
                    let frame = try await layer.step(elapsedSeconds: 1 / 60)
                    XCTAssertTrue(frame.unattributedEvents.isEmpty)
                    for event in frame.native.events where names.contains(event.name) {
                        found[event.name] = event.sourceViewModelInstanceID
                    }
                    for (screen, result) in frame.rows {
                        for effect in result.effects {
                            if case .reportedEvent(let event) = effect.kind, names.contains(event.name) {
                                XCTAssertNil(event.sourceRejection)
                                attributed[screen, default: []].insert(event.name)
                            }
                        }
                    }
                }
                let outRoot = try await layer.snapshot(screenID: outgoing).rootInstanceID
                let inRoot = try await layer.snapshot(screenID: incoming).rootInstanceID
                XCTAssertEqual(found[names[0]], outRoot)
                XCTAssertEqual(found[names[1]], inRoot)
                XCTAssertEqual(attributed[outgoing], [names[0]])
                XCTAssertEqual(attributed[incoming], [names[1]])
                // Finish the streams even on assertion failure, so this check cannot hang.
                await layer.removeCompletion(screenID: outgoing, id: outWaiter.id)
                await layer.removeCompletion(screenID: incoming, id: inWaiter.id)
                var outEvents = outWaiter.events.makeAsyncIterator()
                var inEvents = inWaiter.events.makeAsyncIterator()
                let outCompleted = await outEvents.next()
                let inCompleted = await inEvents.next()
                XCTAssertNotNil(outCompleted)
                XCTAssertNotNil(inCompleted)
                try await layer.setPhases([(outgoing, .hidden), (incoming, .active)])
                _ = try await layer.step(elapsedSeconds: 0)
            }
        }
    }

    func testControlInTopRowIsAttributedToB() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            try await layer.insert(screenID: "screen_2", at: 1)
            _ = try await layer.step(elapsedSeconds: 0)
            // The published Upsell's only pressable is its top button.
            _ = try await layer.step(pointers: [.init(kind: .down, x: 60, y: 40)], elapsedSeconds: 0)
            let frame = try await layer.step(pointers: [.init(kind: .up, x: 60, y: 40)], elapsedSeconds: 0)
            let b = try await layer.snapshot(screenID: "screen_2")
            let events = frame.native.events.filter { $0.name == "Nuxie Interaction" }
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.sourceViewModelInstanceID, b.rootInstanceID)
            XCTAssertTrue(frame.rows["screen_1"]?.effects.isEmpty == true)
            XCTAssertTrue(frame.rows["screen_2"]?.effects.contains(where: {
                if case .rejectedHostCommand(let name, let reason) = $0.kind {
                    return name == "Nuxie Interaction" && reason == "invalid generated control identity"
                }
                return false
            }) == true)
        }
    }

    func testJourneyReservedWritesAreStrippedPerRow() async throws {
        try await withLayer { layer, _ in
            for (id, index, name, alias) in [("screen_1", 0, "Runtime", "row-a"), ("screen_2", 1, "Runtime_Upsell", "row-b")] {
                try await layer.insert(screenID: id, at: index)
                try await layer.setPhases([(id, .entering)])
                _ = try await layer.applyJourneyState(.snapshot([
                    .init(viewModelName: name, instanceID: alias, instanceName: nil, path: "screen/phase", value: .string("hidden")),
                    .init(viewModelName: name, instanceID: alias, instanceName: nil, path: "keptValue", value: .number(7)),
                ]), screenID: id)
                let snapshot = try await layer.snapshot(screenID: id)
                XCTAssertEqual(try self.number(snapshot, "keptValue"), 7)
                XCTAssertTrue(snapshot.values.contains { $0.name == "phase" && $0.value == .integer(1) })
            }
        }
    }

    func testMountedRowsFillResizedRoot() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            try await layer.insert(screenID: "screen_2", at: 1)
            try await layer.setLayoutSize(width: 510, height: 710)
            _ = try await layer.step(elapsedSeconds: 0)
            var sizes: [(Float, Float)] = []
            for id in ["screen_1", "screen_2"] {
                let snapshot = try await layer.snapshot(screenID: id)
                sizes.append((try self.number(snapshot, "rowWidth"), try self.number(snapshot, "rowHeight")))
            }
            XCTExpectFailure("UNIV-5113: list rows retain authored size instead of filling the layer root") {
                for (width, height) in sizes {
                    XCTAssertEqual(width, 510)
                    XCTAssertEqual(height, 710)
                }
            }
        }
    }

    private func number(_ snapshot: NuxieNativeViewModelSnapshot, _ name: String) throws -> Float {
        let value = try XCTUnwrap(snapshot.values.first { $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == name })
        guard case .number(let number) = value.value else { throw NSError(domain: "Missing number", code: 1) }
        return number
    }

    private func withLayer(_ body: (ExperienceInteractiveLayer, ExperienceInteractivePreparation) async throws -> Void) async throws {
        let payload = try await interimLayerPayload()
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let layer = try await preparation.openLayer(pixelWidth: 390, pixelHeight: 844)
        do { try await body(layer, preparation); try await layer.close() }
        catch { try? await layer.close(); throw error }
    }
}

func interimLayerTransition() -> NativeExperienceTransition {
    .init(id: "transition.native-contract", kind: .layer,
        sourceScreenId: "screen_1", destinationScreenId: "screen_2", durationMs: 450,
        incomingOnTop: true, source: .init(completeEventName: "nx_exit_done:transition.native-contract"),
        destination: .init(completeEventName: "nx_enter_done:transition.native-contract"),
        reverse: .init(durationMs: nil, incomingOnTop: nil,
            source: .init(completeEventName: "nx_exit_done:transition.native-contract.reverse"),
            destination: .init(completeEventName: "nx_enter_done:transition.native-contract.reverse")))
}

private func interimLayerPayload() async throws -> AuthenticatedRuntimePayload {
    let bytes = try Data(contentsOf: experiencePreparationRepositoryRoot()
        .appendingPathComponent("fixtures/runtime/layer-host-interim/layer-host.riv"))
    let base = try await statePayload(defaultViewModelName: nil, values: [], scene: bytes)
    let screens = [JourneyScreen(id: "screen_1", defaultViewModelName: "Runtime", defaultInstanceId: "row-a"),
                   JourneyScreen(id: "screen_2", defaultViewModelName: "Runtime_Upsell", defaultInstanceId: "row-b")]
    let definition = ExperienceDefinition(screens: screens, viewModelValues: [], controlsByScreen: [:])
    return AuthenticatedRuntimePayload(authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
        renderPlan: .init(identity: base.renderPlan.identity, scene: base.renderPlan.scene,
            entry: .init(screenId: "screen_1"), layerHost: .init(artboardName: "LayerList", listPath: "screens"),
            screens: [.init(screenId: "screen_1", artboardId: "screen_1", artboardName: "Paywall", width: 390, height: 844, exit: nil),
                      .init(screenId: "screen_2", artboardId: "screen_2", artboardName: "Upsell", width: 430, height: 932, exit: nil)],
            transitions: [interimLayerTransition()], textInputs: [], images: base.renderPlan.images, fonts: base.renderPlan.fonts),
        journey: definition.renderShell, definition: definition, sceneBytes: bytes, assets: base.assets)
}
#endif
