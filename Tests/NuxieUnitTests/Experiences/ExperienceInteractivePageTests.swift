#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

final class ExperienceInteractivePageTests: XCTestCase {
    func testConfirmedRowSaveRestoresKeptValuesBeforeFiringTrigger() async throws {
        try await withLayer { page, _ in
            let row = try await page.prepareRow(screenID: "screen_1", products: [])
            let rowRoot = try await row.rootViewModel()
            let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: rowRoot.rawValue))
            let pageRoot = try await page.runtime.rootViewModelReference()
            XCTAssertNotEqual(reference, pageRoot)
            let mutations = try await row.confirmedResponseSaveMutations(trigger: "saved", kept: [
                .init(path: "keptValue", kind: NuxieNativeViewModelPropertyKind.number.rawValue, value: .number(42)),
                .init(path: "markerX", kind: NuxieNativeViewModelPropertyKind.number.rawValue, value: .number(7))
            ])
            XCTAssertEqual(mutations, [
                .setNumber(instance: reference, path: "keptValue", value: 42),
                .setNumber(instance: reference, path: "markerX", value: 7),
                .fireTrigger(instance: reference, path: "saved")
            ], "The native batch restores every kept field on the row before firing its continuation")
        }
    }

    func testMappedArtboardProvidesRowSchemaWithoutJourneyTypeName() async throws {
        let base = try await interimLayerPayload()
        let payload = AuthenticatedRuntimePayload(authenticatedKeyID: base.authenticatedKeyID,
            renderPlan: base.renderPlan,
            journey: JourneyDocument(screens: [JourneyScreen(id: "screen_1"), JourneyScreen(id: "screen_2")], viewModelValues: []),
            sceneBytes: base.sceneBytes, assets: base.assets)
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let page = try await preparation.openPage(pixelWidth: 390, pixelHeight: 844)
        do {
            _ = try await page.prepareRow(screenID: "screen_2", products: [])
            let screen = try await page.screen(screenID: "screen_2")
            XCTAssertEqual(screen.defaultViewModelName, "Runtime_Upsell")
            try await page.insert(screenID: "screen_2", at: 0)
            try await page.setPhases([("screen_2", .entering)])
            let lifecycle = await page.lifecycle(screenID: "screen_2")
            XCTAssertEqual(lifecycle?.appearances, 1)
            try await page.close()
        } catch { try? await page.close(); throw error }
    }

    func testRemoveOnlyRowThenZeroTimeStep() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            try await layer.remove(screenID: "screen_1")
            try await self.checked("A removed: zero-time step") { _ = try await layer.step(elapsedSeconds: 0) }
            try await self.checked("A removed: timed step") { _ = try await layer.step(elapsedSeconds: 0.5) }
        }
    }

    func testRemoveOnlyRowThenTimedStep() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            try await layer.remove(screenID: "screen_1")
            try await self.checked("A removed: immediate timed step") { _ = try await layer.step(elapsedSeconds: 0.5) }
        }
    }

    func testRemoveAWhileBStaysMounted() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            try await layer.insert(screenID: "screen_2", at: 1)
            _ = try await layer.step(elapsedSeconds: 0)
            try await layer.remove(screenID: "screen_1")
            try await self.checked("A removed, B mounted: timed step") { _ = try await layer.step(elapsedSeconds: 0.5) }
        }
    }

    func testCompletedOutgoingRemovalAllowsNextTimedFrame() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            try await layer.insertIncoming(screenID: "screen_2", style: .magicMove, isBack: false)
            try await layer.setPhases([("screen_1", .exiting), ("screen_2", .entering)],
                transition: "transition.native-contract")
            let required: Set<String> = ["nx_exit_done:transition.native-contract", "nx_enter_done:transition.native-contract"]
            var completed: Set<String> = []
            for _ in 0..<42 {
                let frame = try await layer.step(elapsedSeconds: 1 / 60)
                completed.formUnion(frame.native.events.map(\.name).filter { required.contains($0) })
                if completed == required { break }
            }
            XCTAssertEqual(completed, required)
            guard completed == required else { return }
            // Navigation retires outgoing only after both rows have completed.
            try await layer.setPhases([("screen_1", .hidden), ("screen_2", .active)])
            try await layer.remove(screenID: "screen_1")
            try await self.checked("Both completions received, outgoing hidden and removed: next timed frame") {
                _ = try await layer.step(elapsedSeconds: 1 / 60)
            }
        }
    }

    func testRevisitRemovedBWithoutACreatesSeededInstance() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_2", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            let before = try await layer.snapshot(screenID: "screen_2")
            _ = try await layer.applyJourneyState(.value(.init(viewModelName: "Runtime_Upsell",
                instanceID: "row-b", instanceName: nil, path: "keptValue", value: .number(42))), screenID: "screen_2")
            try await layer.remove(screenID: "screen_2")
            try await self.checked("B removed: zero-time step before revisit") { _ = try await layer.step(elapsedSeconds: 0) }
            try await layer.insert(screenID: "screen_2", at: 0)
            try await self.checked("Fresh seeded B appended: zero-time step") { _ = try await layer.step(elapsedSeconds: 0) }
            let after = try await layer.snapshot(screenID: "screen_2")
            XCTAssertNotEqual(after.rootInstanceID, before.rootInstanceID)
            XCTAssertEqual(try self.number(after, "keptValue"), 42)
        }
    }

    func testRowsRunTheirDefaultMachinesAndKeepValuesAcrossRemovalAndRevisit() async throws {
        // Stage C: replace the interim scene with published live-move records.
        try XCTSkipIf(true, "Stage C: the live-move A/B fixture lacks markerX and keptValue probes needed to assert default-machine progress, reset on remount, and retained values; interim fixture lacks collapse records")
        try await withLayer { layer, preparation in
            try await layer.insert(screenID: "screen_1", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            _ = try await layer.step(elapsedSeconds: 0.25)
            let a = try await layer.snapshot(screenID: "screen_1")
            XCTAssertGreaterThan(try self.number(a, "markerX"), 0)
            try await layer.insert(screenID: "screen_2", at: 1)
            _ = try await layer.step(elapsedSeconds: 0)
            let b = try await layer.snapshot(screenID: "screen_2")
            XCTAssertNotEqual(a.rootInstanceID, b.rootInstanceID)
            XCTAssertNotEqual(a.instances.first?.schemaIndex, b.instances.first?.schemaIndex)
            let both = await layer.mountedScreenIDs
            XCTAssertEqual(both, ["screen_1", "screen_2"])
            try await layer.insert(screenID: "screen_2", at: 1)
            let stillUnique = await layer.mountedScreenIDs
            XCTAssertEqual(stillUnique, ["screen_1", "screen_2"])
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
            XCTAssertNotEqual(revisited.rootInstanceID, b.rootInstanceID)
            XCTAssertEqual(try self.number(revisited, "keptValue"), 42)
            XCTAssertEqual(try self.number(revisited, "markerX"), 0, accuracy: 0.01)
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 1)
        }
    }

    @MainActor
    func testNewRowsAppendOnTopEvenForBack() async throws {
        for (_, back, expected) in [(ExperienceScreenTransitionSpec.Kind.push, true, ["A", "B"]),
            (.push, false, ["A", "B"]), (.magicMove, true, ["A", "B"]),
            (.fade, true, ["A", "B"])] {
            try await withLiveMovePage(initialA: false) { layer in
                try await layer.insert(screenID: "A", at: 0)
                try await layer.apply([.take, .position(isBack: back), .reconcile, .expand,
                    .phases([("A", .exiting), ("B", .entering)], ""), .begin(nil)], source: "A", target: "B",
                    reachable: ["A", "B"], reduceMotion: false)
                _ = try await layer.step(elapsedSeconds: 0)
                let mounted = await layer.mountedScreenIDs
                XCTAssertEqual(mounted, expected)
            }
        }
    }

    @MainActor
    func testNavigateToKeptRowMovesAboveAndBackMovesBelowBeforeRemoval() async throws {
        try await withLiveMovePage(initialA: false) { layer in
            try await layer.insert(screenID: "A", at: 0)
            try await layer.insert(screenID: "B", at: 1)
            _ = try await layer.step(elapsedSeconds: 0)
            let original = try await layer.snapshot(screenID: "A")
            try await layer.apply([.retire], source: "A", target: "B",
                reachable: ["A", "B"], reduceMotion: false)
            try await layer.apply([.take, .position(isBack: false), .reconcile, .expand,
                .phases([("B", .exiting), ("A", .entering)], "back"), .begin("back")], source: "B", target: "A",
                reachable: ["A", "B"], reduceMotion: false)
            let forwardOrder = await layer.mountedScreenIDs
            XCTAssertEqual(forwardOrder, ["B", "A"])
            let revisited = try await layer.snapshot(screenID: "A")
            XCTAssertEqual(revisited.rootInstanceID, original.rootInstanceID)
            try await layer.apply([.end("back"), .retire], source: "B", target: "A",
                reachable: ["A", "B"], reduceMotion: false)
            // Reveal B for a Back with the kept target still above it.
            try await layer.insert(screenID: "B", at: 0)
            try await layer.setPhases([("A", .hidden), ("B", .active)])
            try await layer.apply([.retire], source: "A", target: "B",
                reachable: ["A", "B"], reduceMotion: false)
            try await layer.apply([.take, .position(isBack: true), .reconcile, .expand,
                .phases([("B", .exiting), ("A", .entering)], "back"), .begin("back")], source: "B", target: "A",
                reachable: ["A"], reduceMotion: false)
            let backOrder = await layer.mountedScreenIDs
            XCTAssertEqual(backOrder, ["A", "B"])
            try await layer.apply([.end("back"), .retire], source: "B", target: "A",
                reachable: ["A"], reduceMotion: false)
            let remaining = await layer.mountedScreenIDs
            XCTAssertEqual(remaining, ["A"])
            let landed = try await layer.snapshot(screenID: "A")
            XCTAssertEqual(landed.rootInstanceID, original.rootInstanceID)
        }
    }

    @MainActor
    func testReconcileRequiredBeforeExpansionAndAlreadyPlacedRowSkipsStep() async throws {
        try await withLiveMovePage(initialA: false) { layer in
            try await layer.insert(screenID: "A", at: 0)
            _ = try await layer.step(elapsedSeconds: 0)
            try await layer.apply([.take, .position(isBack: false)], source: "A", target: "B",
                reachable: ["A", "B"], reduceMotion: false)
            do {
                try await layer.apply([.expand], source: "A", target: "B",
                    reachable: ["A", "B"], reduceMotion: false)
                XCTFail("Must not call collapse before the runtime reconciles the insert")
            } catch is ExperienceInteractiveScreenError { }
            let first = try await layer.apply([.reconcile, .expand], source: "A", target: "B",
                reachable: ["A", "B"], reduceMotion: false)
            let frame = try XCTUnwrap(first)
            XCTAssertEqual(frame.mountedScreenIDs, ["A", "B"])
            XCTAssertEqual(Set(frame.rows.keys), ["A", "B"])
            let alreadyPlaced = try await layer.apply([.take, .position(isBack: false), .reconcile, .expand],
                source: "A", target: "B", reachable: ["A", "B"], reduceMotion: false)
            XCTAssertNil(alreadyPlaced, "No mutation means no reconcile result to deliver again")
            try await layer.apply([.take, .position(isBack: false)], source: "B", target: "A",
                reachable: ["A", "B"], reduceMotion: false)
            do {
                try await layer.apply([.expand], source: "B", target: "A",
                    reachable: ["A", "B"], reduceMotion: false)
                XCTFail("Must not call collapse before the runtime reconciles the move")
            } catch is ExperienceInteractiveScreenError { }
            let moved = try await layer.apply([.reconcile, .expand], source: "B", target: "A",
                reachable: ["A", "B"], reduceMotion: false)
            XCTAssertEqual(moved?.mountedScreenIDs, ["B", "A"])
            let repeated = try await layer.apply([.reconcile], source: "B", target: "A",
                reachable: ["A", "B"], reduceMotion: false)
            XCTAssertNil(repeated)
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
                let outCompleted: Void? = await outEvents.next()
                let inCompleted: Void? = await inEvents.next()
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
            var snapshots: [(String, NuxieNativeViewModelSnapshot)] = []
            for id in ["screen_1", "screen_2"] {
                let snapshot = try await layer.snapshot(screenID: id)
                snapshots.append((id, snapshot))
            }
            try XCTExpectFailure("UNIV-5113: publisher layouts must make authored-size rows fill the resized layer root") {
                for (id, snapshot) in snapshots {
                    XCTAssertEqual(try self.number(snapshot, "rowWidth"), 510, id)
                    XCTAssertEqual(try self.number(snapshot, "rowHeight"), 710, id)
                    XCTAssertEqual(try self.number(snapshot, "rowX"), 0, id)
                    XCTAssertEqual(try self.number(snapshot, "rowY"), 0, id)
                }
            }
        }
    }

    func testFitContentDefaultsToLargeWithDiagnostic() async throws {
        try await withLayer { page, _ in
            try await page.insert(screenID: "screen_1", at: 0)
            let diagnostics = PageDiagnosticRecorder()
            try await page.configurePresentationHeight(fitContent: true, size: CGSize(width: 390, height: 844),
                diagnostic: { await diagnostics.append($0) })
            // Layout bounds are published by the next player step, as in presentation.
            _ = try await page.step(elapsedSeconds: 0)
            XCTAssertEqual(page.artboardBounds.size, CGSize(width: 390, height: 844))
            let messages = await diagnostics.messages
            XCTAssertEqual(messages, [ExperienceInteractivePage.fitContentDiagnostic])
            XCTAssertTrue(messages[0].contains("fit-content defaults to large"))
        }
    }

    func testUpdatingAnEnteringRowsSnapshotDoesNotCountAnotherAppearance() async throws {
        try await withLayer { layer, _ in
            try await layer.insert(screenID: "screen_1", at: 0)
            try await layer.setPhases([("screen_1", .entering)])
            let current = await layer.lifecycle(screenID: "screen_1")
            var state = ExperienceScreenLifecycleState(snapshot: try XCTUnwrap(current))
            try await layer.applyLifecycleSnapshot(state.updateReduceMotion(true), screenID: "screen_1")
            let updated = await layer.lifecycle(screenID: "screen_1")
            XCTAssertEqual(updated?.appearances, 1)
            XCTAssertEqual(updated?.reduceMotion, true)
        }
    }

    @MainActor
    func testNestedRowVideoBindsDecodesAndRetiresWithTheRow() async throws {
        try await withVideoLayer { layer in
            try await layer.insert(screenID: "screen", at: 0)
            try await layer.setPhases([("screen", .active)])
            let deadline = Date().addingTimeInterval(5)
            repeat {
                _ = try await layer.step(elapsedSeconds: 1 / 60)
                if await layer.deliveredVideoFrames > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            let occurrences = try await layer.runtime.videos()
            XCTAssertEqual(occurrences.count, 1)
            let frames = await layer.deliveredVideoFrames
            XCTAssertGreaterThan(frames, 0, "The layer's shared video host must deliver decoded frames from its nested row")
            let binding = try await layer.binding(screenID: "screen")
            _ = try await binding.applyStateCommand(.value(.init(viewModelName: "Runtime", instanceID: nil,
                instanceName: nil, path: "paused", value: .bool(true))))
            _ = try await layer.step(elapsedSeconds: 0)
            let paused = try await layer.runtime.videos()
            XCTAssertEqual(paused.first?.wantsPlay, false)
            let playback = await layer.videoPlayback
            let host = try XCTUnwrap(playback)
            XCTAssertEqual(host.decoderPlayerIdentities.count, 1)
            try await layer.remove(screenID: "screen")
            // List mutation detaches the occurrence on advance; that step also ticks the video host.
            _ = try await layer.step(elapsedSeconds: 0)
            let removed = try await layer.runtime.videos()
            XCTAssertTrue(removed.isEmpty, "The reconciled row no longer owns a native video occurrence")
            XCTAssertTrue(host.decoderPlayerIdentities.isEmpty, "The page step must retire the removed occurrence's decoder")
        }
    }

    @MainActor
    func testPageStepKeepsDecoderForStableRuntimeVideoID() async throws {
        try await withVideoLayer { page in
            try await page.insert(screenID: "screen", at: 0)
            _ = try await page.step(elapsedSeconds: 0)
            let host = await page.videoPlayback
            let playback = try XCTUnwrap(host)
            let before = playback.decoderPlayerIdentities
            XCTAssertEqual(before.count, 1)
            let ids = try await page.runtime.videos().map(\.componentID)
            await page.beginPresentationStep()
            try await page.setLayoutSize(width: 1, height: 1)
            for phase in [ExperienceScreenLifecyclePhase.exiting, .entering, .active] {
                try await page.setPhases([("screen", phase)])
                _ = try await page.step(elapsedSeconds: 1 / 60)
            }
            let after = playback.decoderPlayerIdentities
            try await page.setLayoutSize(width: 320, height: 640)
            playback.setStepInProgress(false)
            XCTAssertEqual(after, before)
            let afterIDs = try await page.runtime.videos().map(\.componentID)
            XCTAssertEqual(afterIDs, ids)
        }
    }

    @MainActor
    func testExpandingLayerViewportAdmitsPreviouslyOffscreenNestedVideo() async throws {
        try await withVideoLayer(pixelWidth: 1, pixelHeight: 1) { layer in
            try await layer.insert(screenID: "screen", at: 0)
            try await layer.setPhases([("screen", .active)])
            _ = try await layer.step(elapsedSeconds: 0)
            let ids = try await layer.runtime.videos().map(\.componentID)
            XCTAssertEqual(ids.count, 1)
            let initialVisible = try await layer.runtime.visibleVideoIDs(ids,
                viewport: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertTrue(initialVisible.isEmpty, "The video starts outside the initial viewport")
            let initialFrames = await layer.deliveredVideoFrames
            XCTAssertEqual(initialFrames, 0)
            try await layer.setLayoutSize(width: 320, height: 640)
            _ = try await layer.step(elapsedSeconds: 0)
            XCTAssertEqual(layer.artboardBounds.size, CGSize(width: 320, height: 640))
            let expandedVisible = try await layer.runtime.visibleVideoIDs(ids, viewport: layer.artboardBounds)
            XCTAssertEqual(expandedVisible, Set(ids), "The settled layout now includes the nested video")
            let deadline = Date().addingTimeInterval(5)
            repeat {
                _ = try await layer.step(elapsedSeconds: 1 / 60)
                if await layer.deliveredVideoFrames > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            let frames = await layer.deliveredVideoFrames
            XCTAssertGreaterThan(frames, 0, "The enlarged viewport must admit a decoder and deliver video frames")
        }
    }

    @MainActor
    private func withVideoLayer(pixelWidth: UInt32 = 320, pixelHeight: UInt32 = 640,
                                _ body: (ExperienceInteractivePage) async throws -> Void) async throws {
        let root = experiencePreparationRepositoryRoot()
        let scene = try Data(contentsOf: root.appendingPathComponent("fixtures/runtime/layer-host-video/layer-host.riv"))
        let mediaURL = root.appendingPathComponent("fixtures/video/greeting.mp4")
        let media = try Data(contentsOf: mediaURL)
        let digest = SHA256Provider.hexDigest(media)
        let catalog = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let asset = try XCTUnwrap(catalog.first { $0.kind == .video })
        let id = try XCTUnwrap(asset.authoredID)
        let uniqueName = "\(asset.name)-\(id)"
        let key = "assets/sha256/\(digest).mp4"
        struct Inventory: Decodable { let videoElements: [NativeExperienceVideoElement] }
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/video/inventory.json")))
        let video = NativeExperienceVideoAsset(location: .external(key: key), sourceAssetKey: "asset:clip",
            authoredAssetId: UInt64(id), assetUniqueName: uniqueName, sha256: digest, sizeBytes: media.count,
            width: 64, height: 32, durationMs: 2022, videoCodec: "avc1.42c00a", audioCodec: "mp4a.40.2", captionTracks: [], required: true)
        let plan = NativeExperienceRenderPlan(identity: .init(experienceId: "video", buildId: "video", appId: "app", environment: "test"),
            scene: .init(key: "scene.nux", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
            entry: .init(screenId: "screen"), pageHost: .init(artboardName: "LayerList", listPath: "screens"),
            screens: [.init(screenId: "screen", artboardId: "screen", artboardName: "Video Frame", width: 320, height: 640, exit: nil)],
            transitions: [], textInputs: [], images: [], fonts: [], videos: [video], videoElements: inventory.videoElements)
        let payload = AuthenticatedRuntimePayload(authenticatedKeyID: "test", renderPlan: plan,
            journey: JourneyDocument(screens: [.init(id: "screen", defaultViewModelName: "Runtime")]), sceneBytes: scene,
            assets: [.init(kind: .video, authoredAssetID: id, assetUniqueName: uniqueName, sourceKey: key,
                contentType: "video/mp4", sha256: digest, required: true, bytes: nil, fileURL: mediaURL)])
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let layer = try await preparation.openPage(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            videoDecoderPool: ExperienceVideoDecoderPool.shared)
        do { try await body(layer); try await layer.close() }
        catch { try? await layer.close(); throw error }
    }

    private func number(_ snapshot: NuxieNativeViewModelSnapshot, _ name: String) throws -> Float {
        let value = try XCTUnwrap(snapshot.values.first { $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == name })
        guard case .number(let number) = value.value else { throw NSError(domain: "Missing number", code: 1) }
        return number
    }

    private func checked(_ operation: String, body: () async throws -> Void) async throws {
        do { try await body() }
        catch { throw NSError(domain: operation, code: 1, userInfo: [NSLocalizedDescriptionKey: "\(operation): \(error)"]) }
    }

    private func withLayer(_ body: (ExperienceInteractivePage, ExperienceInteractivePreparation) async throws -> Void) async throws {
        let payload = try await interimLayerPayload()
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let layer = try await preparation.openPage(pixelWidth: 390, pixelHeight: 844)
        do { try await body(layer, preparation); try await layer.close() }
        catch { try? await layer.close(); throw error }
    }
}

private actor PageDiagnosticRecorder {
    private(set) var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}

#endif
