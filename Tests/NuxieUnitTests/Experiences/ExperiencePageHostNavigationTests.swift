#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit
import XCTest
@testable import NuxieTestSupport
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

@MainActor
final class ExperiencePageHostNavigationTests: JourneyTestCase {
    func testRealCompletionsForwardBackAndRevisitUseOneControllerAndPlayer() async throws {
        try await withCoordinator { coordinator, controller, probe, preparation in
            XCTAssertTrue(controller.isPageController)
            XCTAssertEqual(probe.firstPhases[ObjectIdentifier(controller)], .entering,
                "The first row must be entering before its first advance")
            XCTAssertTrue(controller.parent is UINavigationController)
            let layer = try XCTUnwrap(controller.interactivePage)
            var completed: [String: Set<String>] = [:]
            controller.onPageStep = { step in
                for (id, row) in step.rows {
                    for effect in row.effects {
                        if case .reportedEvent(let event) = effect.kind, event.name.hasPrefix("nx_") {
                            completed[id, default: []].insert(event.name)
                        }
                    }
                }
            }
            let a = try await layer.snapshot(screenID: "screen_1").rootInstanceID
            try await navigate(coordinator, to: "screen_2", transition: ["type": "magic-move", "transitionId": "transition.native-contract"])
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1", "screen_2"]])
            XCTAssertEqual(controller.screenId, "screen_2")
            XCTAssertTrue(completed["screen_1"]?.contains("nx_exit_done:transition.native-contract") == true)
            XCTAssertTrue(completed["screen_2"]?.contains("nx_enter_done:transition.native-contract") == true)
            XCTAssertTrue(probe.events.contains("screen_1:nx_exit_done:transition.native-contract"))
            XCTAssertTrue(probe.events.contains("screen_2:nx_enter_done:transition.native-contract"))
            let mountedB = await layer.mountedScreenIDs
            XCTAssertEqual(mountedB, ["screen_1", "screen_2"])
            XCTAssertTrue(coordinator.applyValue(path: VmPathRef(viewModelName: "Runtime_Upsell", path: "keptValue"),
                value: 42, screenId: "screen_2", instanceId: "row-b"))
            try await back(coordinator, to: "screen_1")
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1"]])
            XCTAssertTrue(completed["screen_2"]?.contains("nx_exit_done:transition.native-contract.reverse") == true)
            XCTAssertTrue(completed["screen_1"]?.contains("nx_enter_done:transition.native-contract.reverse") == true)
            let revisitedA = try await layer.snapshot(screenID: "screen_1").rootInstanceID
            XCTAssertEqual(a, revisitedA)
            try await navigate(coordinator, to: "screen_2", transition: ["type": "none"])
            let revisitedB = try await layer.snapshot(screenID: "screen_2")
            XCTAssertTrue(revisitedB.values.contains { $0.name == "keptValue" && $0.value == .number(42) })
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 1)
            XCTAssertEqual(probe.lifecycle.suffix(2), ["hidden:screen_1", "active:screen_2"])
        }
    }

    func testPageBackWithOwnPrimitiveReversesTheForwardStep() async throws {
        try await withCoordinator { coordinator, controller, probe, preparation in
            try await navigate(coordinator, to: "screen_2",
                transition: ["type": "magic-move", "transitionId": "transition.native-contract"])
            try await back(coordinator, to: "screen_1", transition: ["type": "none"])
            XCTAssertEqual(controller.screenId, "screen_1")
            XCTAssertTrue(probe.events.contains("screen_2:nx_exit_done:transition.native-contract.reverse"))
            XCTAssertTrue(probe.events.contains("screen_1:nx_enter_done:transition.native-contract.reverse"))
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 1)
        }
    }

    func testCachedSnapshotInitializesNewRowsWithoutOverwritingRevisitedValues() async throws {
        try await withCoordinator { coordinator, controller, _, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            XCTAssertTrue(coordinator.applySnapshot(.init(values: [
                .init(viewModelName: "Runtime", instanceId: "row-a", path: "keptValue", value: AnyCodable(7)),
                .init(viewModelName: "Runtime_Upsell", instanceId: "row-b", path: "keptValue", value: AnyCodable(11))
            ]), screenId: nil))
            XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Runtime", path: "keptValue"),
                value: 21, screenId: "screen_1", instanceId: "row-a"))
            try await navigate(coordinator, to: "screen_2")
            let firstB = try await layer.snapshot(screenID: "screen_2")
            XCTAssertEqual(rootValue("keptValue", in: firstB), .number(11), "A newly prepared row receives the cached snapshot")
            XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Runtime_Upsell", path: "keptValue"),
                value: 42, screenId: "screen_2", instanceId: "row-b"))
            try await back(coordinator, to: "screen_1")
            let returnedA = try await layer.snapshot(screenID: "screen_1")
            XCTAssertEqual(rootValue("keptValue", in: returnedA), .number(21))
            try await navigate(coordinator, to: "screen_2")
            let returnedB = try await layer.snapshot(screenID: "screen_2")
            XCTAssertEqual(returnedB.rootInstanceID, firstB.rootInstanceID)
            XCTAssertEqual(rootValue("keptValue", in: returnedB), .number(42))
            XCTAssertTrue(coordinator.applySnapshot(.init(values: [
                .init(viewModelName: "Runtime_Upsell", instanceId: "row-b", path: "keptValue", value: AnyCodable(99))
            ]), screenId: "screen_2"))
            try await back(coordinator, to: "screen_1")
            let updatedB = try await layer.snapshot(screenID: "screen_2")
            XCTAssertEqual(rootValue("keptValue", in: updatedB), .number(99), "Explicit snapshots still update retained rows")
        }
    }

    func testUnqualifiedBroadcastResolvesTheDefaultViewModelOfEachRetainedRow() async throws {
        try await withCoordinator { coordinator, controller, _, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            try await navigate(coordinator, to: "screen_2")
            XCTAssertTrue(coordinator.applyValue(path: .init(path: "keptValue"), value: 42,
                screenId: nil, instanceId: nil))
            try await back(coordinator, to: "screen_1")
            let a = try await layer.snapshot(screenID: "screen_1")
            let b = try await layer.snapshot(screenID: "screen_2")
            XCTAssertEqual(rootValue("keptValue", in: a), .number(42))
            XCTAssertEqual(rootValue("keptValue", in: b), .number(42))
            XCTAssertTrue(coordinator.applyValue(path: .init(path: "keptValue"), value: 84,
                screenId: nil, instanceId: nil))
            try await navigate(coordinator, to: "screen_2")
            let nextA = try await layer.snapshot(screenID: "screen_1")
            let nextB = try await layer.snapshot(screenID: "screen_2")
            XCTAssertEqual(rootValue("keptValue", in: nextA), .number(84))
            XCTAssertEqual(rootValue("keptValue", in: nextB), .number(84))
        }
    }

    func testCutWithPublishedHalvesEmitsItsOutgoingCompletionBeforeSwapping() async throws {
        try await withCoordinator { coordinator, controller, _, _ in
            var mountedAtExit: [String]?
            let layer = try XCTUnwrap(controller.interactivePage)
            controller.onPageStep = { step in
                if step.rows["screen_1"]?.effects.contains(where: {
                    if case .reportedEvent(let event) = $0.kind {
                        return event.name == "nx_exit_done:transition.native-contract"
                    }
                    return false
                }) == true {
                    mountedAtExit = step.mountedScreenIDs
                }
            }
            try await navigate(coordinator, to: "screen_2", transition: ["type": "none", "transitionId": "transition.native-contract"])
            XCTAssertEqual(mountedAtExit, ["screen_1"], "The published leave must finish before insertion")
            let mounted = await layer.mountedScreenIDs
            XCTAssertEqual(mounted, ["screen_1", "screen_2"])
        }
    }

    func testRowInitiatedStepDeliversBothTransitionHalvesExactlyOnce() async throws {
        try await checkRowInitiatedStep(removingRequester: false)
    }

    func testRemovedRowsLateStepStillDeliversTheMountedRowsEffects() async throws {
        try await checkRowInitiatedStep(removingRequester: true)
    }

    private func checkRowInitiatedStep(removingRequester: Bool) async throws {
        try await withCoordinator { _, controller, probe, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            try await controller.preparePageRow(screenID: "screen_2", products: [])
            let requester = try await layer.binding(screenID: "screen_1")
            let loop = try XCTUnwrap(Mirror(reflecting: controller).children
                .first { $0.label == "presentationLoop" }?.value as? ExperienceRuntimePresentationLoop)
            var delivered: [String: [String]] = [:]
            controller.onPageStep = { step in
                for (id, row) in step.rows {
                    for effect in row.effects {
                        if case .reportedEvent(let event) = effect.kind {
                            delivered[id, default: []].append(event.name)
                        }
                    }
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loop.enqueue(.init {
                    try await layer.insert(screenID: "screen_2", at: 1)
                    try await layer.setPhases([("screen_1", .exiting), ("screen_2", .entering)],
                        transition: "transition.native-contract")
                    _ = try await layer.step(elapsedSeconds: 0)
                    if removingRequester { _ = try await layer.remove(screenID: "screen_1") }
                    let result = try await requester.step(elapsedSeconds: 0.6)
                    return .work(requestsFrame: false) {
                        await controller.deliverStep(result, screenID: "screen_1")
                    }
                }, completion: { continuation.resume(with: $0) })
            }
            let incoming = "nx_enter_done:transition.native-contract"
            XCTAssertEqual(delivered["screen_2"]?.filter { $0 == incoming }, [incoming])
            XCTAssertEqual(probe.events.filter { $0 == "screen_2:\(incoming)" }.count, 1)
            if !removingRequester {
                let outgoing = "nx_exit_done:transition.native-contract"
                XCTAssertEqual(delivered["screen_1"]?.filter { $0 == outgoing }, [outgoing])
                XCTAssertEqual(probe.events.filter { $0 == "screen_1:\(outgoing)" }.count, 1)
            }
        }
    }

    private func rootValue(_ name: String, in snapshot: NuxieNativeViewModelSnapshot) -> NuxieNativeViewModelValue? {
        snapshot.values.first { $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == name }?.value
    }

    func testNavigationRequestedDuringStepQueuesAndSelfNavigationCompletesAlreadyActive() async throws {
        try await withCoordinator { coordinator, controller, _, _ in
            let first = expectation(description: "forward")
            let second = expectation(description: "queued self")
            var results: [ExperienceScreenNavigationResult] = []
            XCTAssertTrue(coordinator.navigate(to: "screen_2", transition: ["type": "fade", "transitionId": "transition.native-contract"]) { result, _ in
                results.append(result); first.fulfill()
            })
            let deadline = Date().addingTimeInterval(2)
            while controller.lifecyclePhase != .exiting, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(controller.lifecyclePhase, .exiting)
            XCTAssertFalse(controller.receiveFocusInput(.next), "Input is blocked while both rows run")
            XCTAssertTrue(coordinator.navigate(to: "screen_2", transition: nil) { result, _ in
                results.append(result); second.fulfill()
            })
            await fulfillment(of: [first, second], timeout: 5)
            XCTAssertEqual(results, [.navigated, .alreadyActive])
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1", "screen_2"]])
            XCTAssertEqual(controller.screenId, "screen_2")
        }
    }

    func testPushOpensNewPageAndSkippingBackCutsCoveredLowerPageBeforePop() async throws {
        try await withCoordinator { coordinator, lower, _, preparation in
            try await navigate(coordinator, to: "screen_2")
            let navigation = try XCTUnwrap(lower.navigationController)
            let lowerPlayer = try XCTUnwrap(lower.interactivePage)
            try await navigate(coordinator, to: "screen_1", transition: ["type": "push"])
            let pushed = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(pushed === lower)
            XCTAssertFalse(pushed.interactivePage === lowerPlayer)
            XCTAssertEqual(lower.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.count, 1)
            XCTAssertEqual(pushed.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.count, 1)
            XCTAssertEqual(lower.lifecyclePhase, .hidden)
            XCTAssertEqual(pushed.lifecyclePhase, .active)
            XCTAssertEqual(pushed.pageHistory.screenIDs, ["screen_1"])
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 2)
            let priorLifecycle = await lowerPlayer.lifecycle(screenID: "screen_1")
            let before = try XCTUnwrap(priorLifecycle).appearances
            var cutWhileCovered = false
            lower.onPageStep = { _ in
                if lower.screenId == "screen_1", lower.lifecyclePhase == .hidden, navigation.viewControllers.count == 2 {
                    cutWhileCovered = true
                    XCTAssertEqual(lower.lifecycleAppearances, before)
                }
            }
            let result = await withCheckedContinuation { continuation in
                XCTAssertTrue(coordinator.back(to: "screen_1", steps: 2) { result, _ in continuation.resume(returning: result) })
            }
            XCTAssertEqual(result, .navigated)
            XCTAssertTrue(cutWhileCovered)
            XCTAssertTrue(navigation.topViewController === lower)
            XCTAssertEqual(lower.screenId, "screen_1")
            XCTAssertEqual(lower.pageHistory.screenIDs, ["screen_1"])
            XCTAssertEqual(lower.lifecycleAppearances, before + 1)
        }
    }

    func testJourneyBackFromOneModalAnnouncesOnlyTheDestinationOnce() async throws {
        try await assertModalBackActivation(modalCount: 1)
    }

    func testJourneyBackAcrossTwoModalsAnnouncesOnlyTheFinalDestinationOnce() async throws {
        try await assertModalBackActivation(modalCount: 2)
    }

    private func assertModalBackActivation(modalCount: Int) async throws {
        try await withLifecycleCoordinator { coordinator, base, probe, _ in
            for index in 0..<modalCount {
                try await navigate(coordinator, to: index.isMultiple(of: 2) ? "screen_2" : "screen_1",
                    transition: ["type": "modal", "present": "sheet"])
            }
            probe.resetActivationRecords()
            try await back(coordinator, to: "screen_1", steps: modalCount)
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1"]])
            XCTAssertEqual(base.lifecyclePhase, .active)
            assertActivation(probe, screenID: "screen_1")
            try await assertTimelineAdvances(base)
        }
    }

    func testInteractiveSheetCancellationDoesNotVisitOrUncoverLowerPage() async throws {
        try await assertInteractivePageDecision(modal: true, completes: false)
    }

    func testInteractiveSheetCompletionVisitsAndAnnouncesOnce() async throws {
        try await assertInteractivePageDecision(modal: true, completes: true)
    }

    func testInteractivePopCancellationDoesNotVisitOrUncoverLowerPage() async throws {
        try await assertInteractivePageDecision(modal: false, completes: false)
    }

    func testInteractivePopCompletionVisitsAndAnnouncesOnce() async throws {
        try await assertInteractivePageDecision(modal: false, completes: true)
    }

    private func assertInteractivePageDecision(modal: Bool, completes: Bool) async throws {
        try await withLifecycleCoordinator { coordinator, lower, probe, _ in
            try await navigate(coordinator, to: "screen_2", transition: modal
                ? ["type": "modal", "present": "sheet"] : ["type": "push"])
            let navigation = modal ? coordinator.topPresentedLayer as? UINavigationController : lower.navigationController
            let outgoing = try XCTUnwrap(navigation?.topViewController as? ExperienceScreenViewController)
            let appearances = lower.lifecycleAppearances
            let elapsed = lower.timelineElapsedSeconds
            probe.resetActivationRecords()
            // Drive the same owner used by UIKit's interaction-decision callbacks.
            // Keeping real mounted pages makes hidden timeline/input checks observable.
            let transition = coordinator.pageTransition(revealing: lower, covering: outgoing, interactive: true)
            await transition.begin()
            for _ in 0..<3 {
                lower.advance(delta: 1 / 60)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(lower.timelineElapsedSeconds, elapsed)
            XCTAssertEqual(lower.lifecycleAppearances, appearances)
            XCTAssertEqual(lower.lifecyclePhase, .hidden)
            XCTAssertFalse(lower.view.isUserInteractionEnabled)
            XCTAssertEqual(outgoing.lifecyclePhase, .active)
            XCTAssertTrue(probe.shownScreenIDs.isEmpty)
            XCTAssertFalse(probe.lifecycle.contains { $0.hasPrefix("active:") })
            await transition.interactionEnded(cancelled: !completes)
            if completes {
                XCTAssertEqual(lower.lifecyclePhase, .entering)
                XCTAssertEqual(lower.lifecycleAppearances, appearances + 1)
                XCTAssertEqual(outgoing.lifecyclePhase, .active)
                XCTAssertTrue(probe.shownScreenIDs.isEmpty)
                let committed = await transition.commit()
                XCTAssertTrue(committed)
                let repeated = await transition.commit()
                XCTAssertFalse(repeated)
                XCTAssertEqual(lower.lifecyclePhase, .active)
                XCTAssertEqual(outgoing.lifecyclePhase, .hidden)
                XCTAssertEqual(lower.lifecycleAppearances, appearances + 1)
                assertActivation(probe, screenID: "screen_1")
            } else {
                // Stale acceptance/completion must not revive a cancelled transition.
                await transition.interactionEnded(cancelled: false)
                let committed = await transition.commit()
                XCTAssertFalse(committed)
                lower.advance(delta: 1 / 60)
                try await Task.sleep(nanoseconds: 20_000_000)
                XCTAssertEqual(lower.timelineElapsedSeconds, elapsed)
                XCTAssertEqual(lower.lifecycleAppearances, appearances)
                XCTAssertEqual(lower.lifecyclePhase, .hidden)
                XCTAssertFalse(lower.view.isUserInteractionEnabled)
                XCTAssertEqual(outgoing.lifecyclePhase, .active)
                XCTAssertTrue(outgoing.view.isUserInteractionEnabled)
                XCTAssertTrue(probe.shownScreenIDs.isEmpty)
                XCTAssertFalse(probe.lifecycle.contains { $0.hasPrefix("active:") })
            }
        }
    }

    func testHostPopAnnouncesTheRevealedPageOnce() async throws {
        try await withLifecycleCoordinator { coordinator, base, probe, _ in
            let before = base.lifecycleAppearances
            try await navigate(coordinator, to: "screen_2", transition: ["type": "push"])
            let navigation = try XCTUnwrap(base.navigationController)
            probe.resetActivationRecords()
            // Exercise the delegate path used by a completed edge swipe, outside a Journey drain.
            navigation.popViewController(animated: false)
            let deadline = Date().addingTimeInterval(2)
            while probe.shownScreenIDs.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            // A repeated UIKit completion must not announce the same pop again.
            coordinator.navigationController(navigation, didShow: base, animated: false)
            await Task.yield()
            assertActivation(probe, screenID: "screen_1")
            try await assertTimelineAdvances(base)
            XCTAssertEqual(base.lifecyclePhase, .active)
            XCTAssertEqual(base.lifecycleAppearances, before + 1)
        }
    }

    func testModalOwnsAnotherPlayerAndDismissalRevealsRetainedBase() async throws {
        try await withLifecycleCoordinator { coordinator, base, probe, preparation in
            let layer = try XCTUnwrap(base.interactivePage)
            let before = try await layer.snapshot(screenID: "screen_1").rootInstanceID
            try await navigate(coordinator, to: "screen_2", transition: ["type": "modal", "present": "sheet", "closedby": "none"])
            let modal = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(modal === base)
            XCTAssertEqual(probe.firstPhases[ObjectIdentifier(modal)], .entering)
            let firstAppearance = await modal.interactivePage?.lifecycle(screenID: "screen_2")
            XCTAssertEqual(firstAppearance?.appearances, 1)
            XCTAssertFalse(modal.interactivePage === base.interactivePage)
            XCTAssertTrue(modal.navigationController?.isModalInPresentation == true)
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1"], ["screen_2"]])
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 2)
            probe.resetActivationRecords()
            let result = await coordinator.closeTopLayer()
            XCTAssertEqual(result, .navigated)
            XCTAssertNil(coordinator.topPresentedLayer)
            XCTAssertEqual(coordinator.activeScreenId, "screen_1")
            let after = try await layer.snapshot(screenID: "screen_1").rootInstanceID
            XCTAssertEqual(before, after)
            assertActivation(probe, screenID: "screen_1")
            try await assertTimelineAdvances(base)
        }
    }

    func testTapFromActiveNestedRowKeepsItsScreenOwner() async throws {
        try await withCoordinator { coordinator, controller, _, _ in
            try await navigate(coordinator, to: "screen_2")
            let layer = try XCTUnwrap(controller.interactivePage)
            let down = try await layer.step(pointers: [.init(kind: .down, x: 60, y: 40)], elapsedSeconds: 0)
            let up = try await layer.step(pointers: [.init(kind: .up, x: 60, y: 40)], elapsedSeconds: 0)
            XCTAssertTrue(down.rows["screen_1"] == nil)
            XCTAssertTrue(up.rows["screen_1"] == nil)
            XCTAssertTrue(up.rows["screen_2"]?.effects.contains {
                if case .rejectedHostCommand(let name, _) = $0.kind { return name == "Nuxie Interaction" }
                return false
            } == true)
            XCTAssertTrue(up.unattributedEvents.isEmpty)
        }
    }

    func testOnlyActiveRowExposesSemanticsAndEditorsAndFieldOwnerSurvivesRevisit() async throws {
        let root = experiencePreparationRepositoryRoot()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/runtime/layer-host-input/layer-host.riv"))
        let path = "nuxieTextInputs/input_scr_screens_sinput_v2_476c0e3c"
        let inputs = [NativeExperienceTextInput(inputId: "name", screenId: "input", artboardId: "input",
            viewNodeId: "scr_screens_sinput::v2", renderedNodeId: "scr_screens_sinput::v2",
            textInputName: "scr_screens_sinput::v2 editable value", value: "", placeholder: nil, editable: true,
            geometry: .init(xPath: "\(path)/x", yPath: "\(path)/y", widthPath: "\(path)/width", heightPath: "\(path)/height",
                rotationPath: "\(path)/rotation", scaleXPath: "\(path)/scaleX", scaleYPath: "\(path)/scaleY"),
            style: .init(fontFamily: "System", fontWeight: "400", fontStyle: "normal", fontSize: 16,
                lineHeight: -1, letterSpacing: 0, color: 0xFF111827,
                fontAssetUniqueName: "font-system-400-normal-6cda3de3-0", textAlign: "left"),
            keyboardType: nil, secureTextEntry: false, multiline: false, maxLength: nil, responseFieldKey: nil)]
        let base = try SharedValuesFixture.payload(directory: PublishedInputFixture.directory, screens: ["input", "greeting"],
            scene: bytes, textInputs: inputs)
        let plan = NativeExperienceRenderPlan(identity: base.renderPlan.identity, scene: base.renderPlan.scene,
            entry: base.renderPlan.entry, pageHost: .init(artboardName: "LayerList", listPath: "screens"),
            screens: base.renderPlan.screens, transitions: [], textInputs: inputs, images: [], fonts: [],
            systemFonts: base.renderPlan.systemFonts)
        let payload = AuthenticatedRuntimePayload(authenticatedKeyID: base.authenticatedKeyID,
            requiredCapabilities: base.requiredCapabilities.union(["experience-accessibility"]), renderPlan: plan,
            journey: base.journey, sceneBytes: bytes, assets: base.assets)
        try await withCoordinator(payload: payload) { coordinator, controller, _, _ in
            var capture: NuxieNativeSemanticCapture?
            controller.onSemanticCapture = { capture = $0 }
            @MainActor func fields(_ view: UIView) -> [UITextField] {
                (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields)
            }
            @MainActor func settle(_ predicate: @MainActor () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(5)
                while !predicate(), Date() < deadline {
                    controller.advance(delta: 1 / 60)
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(predicate())
            }
            try await settle { fields(controller.view).first?.text == "Ada" && capture != nil }
            let field = try XCTUnwrap(fields(controller.view).first)
            field.keyboardType = .asciiCapable
            XCTAssertTrue(field.becomeFirstResponder())
            try await settle { controller.riveFocusState.expectsKeyboardInput }
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
            field.insertText("Grace")
            try await settle { field.text == "Grace" && controller.hasDeliveredLatestSemanticFrame }
            let binding = try await XCTUnwrap(controller.interactivePage).binding(screenID: "input")
            let current = try XCTUnwrap(capture)
            let node = try XCTUnwrap(current.tree.nodes.first { $0.role == NuxieNativeSemanticRole.textField.rawValue })
            let source = try await binding.readSemanticText(captureID: current.id, inputID: inputs[0].inputId, nodeID: node.id)
            XCTAssertNotNil(source.ownerInstanceID)
            XCTAssertEqual(source.text, "Grace")
            try await navigate(coordinator, to: "greeting")
            try await settle { capture?.tree.nodes.contains { $0.role == NuxieNativeSemanticRole.textField.rawValue } == false }
            XCTAssertTrue(fields(controller.view).allSatisfy { $0.isHidden || $0.superview == nil })
            try await back(coordinator, to: "input")
            try await settle { fields(controller.view).first?.text == "Grace" }
            XCTAssertEqual(controller.screenId, "input")
        }
    }

    func testBackRequestedDuringAStepQueuesAndReversesThePairThatFinishes() async throws {
        try await withCoordinator { coordinator, controller, probe, _ in
            let forward = expectation(description: "forward finishes")
            let returned = expectation(description: "queued back finishes")
            var results: [ExperienceScreenNavigationResult] = []
            XCTAssertTrue(coordinator.navigate(to: "screen_2", transition: ["type": "magic-move", "transitionId": "transition.native-contract"]) { result, _ in
                results.append(result)
                forward.fulfill()
            })
            let deadline = Date().addingTimeInterval(2)
            while controller.lifecyclePhase != .exiting, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(controller.lifecyclePhase, .exiting)
            XCTAssertTrue(coordinator.back(to: "screen_1", steps: 1) { result, _ in
                results.append(result)
                returned.fulfill()
            })
            XCTAssertTrue(results.isEmpty, "Back during a step must be queued rather than completing alreadyActive")
            await fulfillment(of: [forward, returned], timeout: 5)
            XCTAssertEqual(results, [.navigated, .navigated])
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1"]])
            XCTAssertTrue(probe.events.contains("screen_2:nx_exit_done:transition.native-contract.reverse"))
            XCTAssertTrue(probe.events.contains("screen_1:nx_enter_done:transition.native-contract.reverse"))
        }
    }

    func testStackedSheetsAndSwipeDismissalKeepEachLayerIndependent() async throws {
        try await withLifecycleCoordinator { coordinator, base, probe, preparation in
            try await navigate(coordinator, to: "screen_2", transition: ["type": "modal", "present": "sheet", "height": "medium"])
            let lower = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            try await navigate(coordinator, to: "screen_1", transition: ["type": "modal", "present": "sheet"])
            let upper = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(upper.view.window === lower.view.window)
            XCTAssertTrue(lower.view.window === base.view.window)
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1"], ["screen_2"], ["screen_1"]])
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 3)
            probe.resetActivationRecords()
            let presentation = try XCTUnwrap(upper.navigationController?.presentationController)
            await withCheckedContinuation { continuation in upper.navigationController?.dismiss(animated: false) { continuation.resume() } }
            coordinator.presentationControllerDidDismiss(presentation)
            let deadline = Date().addingTimeInterval(2)
            while probe.shownScreenIDs.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1"], ["screen_2"]])
            XCTAssertEqual(lower.lifecyclePhase, .active)
            coordinator.presentationControllerDidDismiss(presentation)
            await Task.yield()
            assertActivation(probe, screenID: "screen_2")
            try await assertTimelineAdvances(lower)
            probe.resetActivationRecords()
            let closed = await coordinator.closeTopLayer()
            XCTAssertEqual(closed, .navigated)
            assertActivation(probe, screenID: "screen_1")
            try await assertTimelineAdvances(base)
            XCTAssertEqual(coordinator.layerScreenIds, [["screen_1"]])
        }
    }

    func testAttributedJourneyEventCannotOverrideItsRowWithAPayloadScreenID() async throws {
        try await withCoordinator { _, controller, probe, _ in
            let effect = ExperienceInteractiveEffect(sequence: 0, correlationID: 1,
                kind: .journeyEvent(name: "row-event", payload: .object([.init(key: "screenId", value: .string("screen_1"))])))
            await controller.deliverStep(effects: [effect], screenID: "screen_2")
            XCTAssertTrue(probe.events.contains("screen_2:row-event"))
        }
    }

    func testSwipeDuringAnUnpresentedPhaseSupersedesNavigationAndReleasesTheDrain() async throws {
        try await withCoordinator { coordinator, _, _, _ in
            try await navigate(coordinator, to: "screen_2", transition: ["type": "modal", "present": "sheet"])
            let sheet = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            let presentation = try XCTUnwrap(sheet.navigationController?.presentationController)
            let blocked = expectation(description: "phase waiting for presentation")
            var withdrew = false
            sheet.onPageStep = { [weak sheet] _ in
                guard let sheet else { return }
                if sheet.lifecyclePhase == .exiting && !withdrew {
                    withdrew = true
                    sheet.setContentHidden(true)
                    blocked.fulfill()
                }
            }
            let superseded = expectation(description: "sheet navigation superseded")
            var sheetResult: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "screen_1",
                transition: ["type": "magic-move", "transitionId": "transition.native-contract"]) { result, _ in
                sheetResult = result
                superseded.fulfill()
            })
            await fulfillment(of: [blocked], timeout: 2)
            XCTAssertNil(sheetResult)
            let drain = try XCTUnwrap(Mirror(reflecting: coordinator).children
                .first { $0.label == "navigationTask" }?.value as? Task<Void, Never>)
            await withCheckedContinuation { continuation in sheet.navigationController?.dismiss(animated: false) { continuation.resume() } }
            coordinator.presentationControllerDidDismiss(presentation)
            let deadline = Date().addingTimeInterval(2)
            while coordinator.topPresentedLayer != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertNil(coordinator.topPresentedLayer)
            let revealed = expectation(description: "navigation in revealed layer finishes")
            var baseResult: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "screen_2", transition: nil) { result, _ in
                baseResult = result
                revealed.fulfill()
            })
            await fulfillment(of: [superseded, revealed], timeout: 3)
            XCTAssertEqual(sheetResult, .superseded)
            XCTAssertEqual(baseResult, .navigated)
            XCTAssertEqual(coordinator.activeScreenId, "screen_2")
            // Cancellation keeps the pre-fix regression bounded after its assertions fail.
            drain.cancel()
            await drain.value
        }
    }

    func testRevisitsReuseTheRowsOriginalProductsForDisplayAndCheckout() async throws {
        let resolver = LayerProductResolver()
        try await withCoordinator(productResolver: { await resolver.resolve($0) }) { coordinator, controller, probe, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            try await navigate(coordinator, to: "screen_2")
            let original = try await layer.products(screenID: "screen_2")
            XCTAssertEqual(original.first?.price, "screen_2:1")
            try await back(coordinator, to: "screen_1")
            try await navigate(coordinator, to: "screen_2")
            let counts = await resolver.counts
            XCTAssertEqual(counts, ["screen_1": 1, "screen_2": 1])
            XCTAssertEqual(probe.checkoutProducts.last, original)
            try await navigate(coordinator, to: "screen_2", transition: ["type": "modal", "present": "sheet"])
            let modal = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            let modalProducts = try await XCTUnwrap(modal.interactivePage).products(screenID: "screen_2")
            XCTAssertEqual(modalProducts.first?.price, "screen_2:2", "A new layer prepares its own row")
            let closed = await coordinator.closeTopLayer()
            XCTAssertEqual(closed, .navigated)
            try await back(coordinator, to: "screen_1")
            try await navigate(coordinator, to: "screen_2")
            let retained = try await layer.products(screenID: "screen_2")
            let finalCounts = await resolver.counts
            XCTAssertEqual(finalCounts, ["screen_1": 1, "screen_2": 2])
            XCTAssertEqual(retained, original)
            XCTAssertEqual(probe.checkoutProducts.last, original,
                "Checkout must use the same product set that initialized the retained row")
        }
    }

    private func navigate(_ coordinator: ExperienceScreenTransitionCoordinator, to id: String, transition: Any? = nil) async throws {
        let result: ExperienceScreenNavigationResult = await withCheckedContinuation { continuation in
            if !coordinator.navigate(to: id, transition: transition, completion: { result, _ in continuation.resume(returning: result) }) {
                continuation.resume(returning: .failed)
            }
        }
        XCTAssertEqual(result, .navigated)
    }

    private func back(_ coordinator: ExperienceScreenTransitionCoordinator, to id: String, steps: Int = 1, transition: Any? = nil) async throws {
        let result: ExperienceScreenNavigationResult = await withCheckedContinuation { continuation in
            if !coordinator.back(to: id, steps: steps, transition: transition, completion: { result, _ in continuation.resume(returning: result) }) {
                continuation.resume(returning: .failed)
            }
        }
        XCTAssertEqual(result, .navigated)
    }

    private func assertTimelineAdvances(_ controller: ExperienceScreenViewController,
        file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = controller.timelineElapsedSeconds
        let deadline = Date().addingTimeInterval(2)
        while controller.timelineElapsedSeconds <= before, Date() < deadline {
            controller.advance(delta: 1 / 60)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(controller.timelineElapsedSeconds, before, file: file, line: line)
        XCTAssertTrue(controller.view.isUserInteractionEnabled, file: file, line: line)
        XCTAssertEqual(controller.lifecyclePhase, .active, file: file, line: line)
    }

    func testPushingSameScreenThenPoppingKeepsScreenTargetedCommandsOnRetainedPage() async throws {
        try await withCoordinator { coordinator, base, _, _ in
            try await navigate(coordinator, to: "screen_1", transition: ["type": "push"])
            XCTAssertEqual(base.navigationController?.viewControllers.count, 2)
            try await back(coordinator, to: "screen_1")
            XCTAssertTrue(base.navigationController?.topViewController === base)
            XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Runtime", path: "keptValue"),
                value: 73, screenId: "screen_1", instanceId: "row-a"))
            // These return true only if the surviving controller accepts the queued command.
            XCTAssertTrue(coordinator.applyListOperation(.clear,
                path: .init(viewModelName: "LayerHost", path: "screens"), payload: [:],
                screenId: "screen_1", instanceId: nil))
            XCTAssertTrue(coordinator.fireTrigger(path: .init(viewModelName: "Runtime", path: "nuxieTrigger"),
                screenId: "screen_1", instanceId: "row-a"))
            let page = try XCTUnwrap(base.interactivePage)
            var snapshot = try await page.snapshot(screenID: "screen_1")
            let deadline = Date().addingTimeInterval(2)
            while rootValue("keptValue", in: snapshot) != .number(73), Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
                snapshot = try await page.snapshot(screenID: "screen_1")
            }
            XCTAssertEqual(rootValue("keptValue", in: snapshot), .number(73))
            try await assertTimelineAdvances(base)
        }
    }

    private func assertActivation(_ probe: LayerHostProbe, screenID: String,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(probe.lifecycle.filter { $0.hasPrefix("active:") }, ["active:\(screenID)"], file: file, line: line)
        let journeyID = screenID == "screen_1" ? "screen_welcome" : "screen_details"
        XCTAssertEqual(probe.shownScreenIDs, [journeyID], file: file, line: line)
    }

    private func withLifecycleCoordinator(_ body: @MainActor (ExperienceScreenTransitionCoordinator,
        ExperienceScreenViewController, LayerHostProbe, ExperienceInteractivePreparation) async throws -> Void) async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = try await authenticatedRenderedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let presenter = RecordingJourneyPresenter()
        let service = makeService(identity: identity, events: events, directory: directory, presenter: presenter)
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let request = try XCTUnwrap(presenter.request)
        try await withCoordinator(onActive: { id in
            // The native and Journey fixtures use different names for their two Screens.
            let accepted = await request.onScreenChanged(id == "screen_1" ? "screen_welcome" : "screen_details")
            XCTAssertTrue(accepted)
        }) { coordinator, controller, probe, preparation in
            probe.journeyEvents = events
            try await body(coordinator, controller, probe, preparation)
        }
        // Keep the service alive through every callback and assertion.
        withExtendedLifetime(service) {}
    }

    private func withCoordinator(payload suppliedPayload: AuthenticatedRuntimePayload? = nil,
        productResolver: (@Sendable (String) async throws -> [StoreProduct])? = nil,
        onActive: (@MainActor (String) async -> Void)? = nil, _ body: @MainActor (ExperienceScreenTransitionCoordinator, ExperienceScreenViewController,
        LayerHostProbe, ExperienceInteractivePreparation) async throws -> Void) async throws {
        let payload: AuthenticatedRuntimePayload
        if let suppliedPayload { payload = suppliedPayload }
        else { payload = try await interimLayerPayload() }
        let root = experiencePreparationRepositoryRoot()
        let experience = Experience(id: "layer-host", versionId: "layer-version", buildId: "layer-build",
            artifactContentHash: nil, authenticatedReleaseID: nil, behaviorPresentation: .standard,
            behaviorPresentationScreens: [:], assetBaseURL: root, journey: payload.journey, definition: payload.definition)
        let acquired = AcquiredExperienceArtifact(identity: .init(experienceId: experience.id, buildId: experience.buildId),
            sceneURL: root.appendingPathComponent("fixtures/runtime/layer-host-interim/layer-host.riv"), sceneBytes: payload.sceneBytes,
            assetURLsByUniqueName: [:], source: .cache, payload: payload,
            interactivePreparation: .init(cache: ExperienceInteractivePreparationCache(), provenance: UUID().uuidString, payload: payload),
            products: [], resourceMetrics: .zero, productResolver: productResolver)
        let preparation = try await acquired.interactivePreparation.preparation()
        let host = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in presenter.present(host, animated: false) { continuation.resume() } }
        let probe = LayerHostProbe()
        let coordinator = ExperienceScreenTransitionCoordinator(experience: experience, artifact: .init(acquired: acquired),
            hostViewController: host, screenDelegate: probe,
            onPresentedScreenDismissed: { _, _ in },
            onScreenHidden: { id, _ in probe.lifecycle.append("hidden:\(id)") },
            onScreenActive: { id in
                probe.lifecycle.append("active:\(id)")
                await onActive?(id)
            }, onProductsResolved: { probe.checkoutProducts.append($0) },
            onProductsUnavailable: { _ in XCTFail("Unexpected product resolution failure") },
            onRuntimeFailure: { id, error in XCTFail("\(id): \(error)") })
        do {
            try await coordinator.install()
            coordinator.setContentHidden(false)
            _ = await coordinator.activateInitialScreen()
            let controller = try XCTUnwrap((host.children.first as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            try await body(coordinator, controller, probe, preparation)
            await coordinator.tearDown()
        } catch { await coordinator.tearDown(); window.isHidden = true; oldKey?.makeKey(); throw error }
        await withCheckedContinuation { continuation in presenter.dismiss(animated: false) { continuation.resume() } }
        window.isHidden = true
        oldKey?.makeKey()
    }
}

private actor LayerProductResolver {
    private(set) var counts: [String: Int] = [:]
    func resolve(_ screenID: String) -> [StoreProduct] {
        counts[screenID, default: 0] += 1
        return [StoreProduct(productId: "product", placementId: "placement", name: screenID,
            price: "\(screenID):\(counts[screenID]!)", period: nil)]
    }
}

@MainActor
private final class LayerHostProbe: ExperienceScreenViewControllerDelegate {
    var journeyEvents: MockEventLog?
    private var shownBaseline = 0
    var shownScreenIDs: [String] {
        Array((journeyEvents?.routedEvents ?? []).filter { $0.name == SystemEventNames.screenShown }
            .dropFirst(shownBaseline).compactMap { $0.properties["screen_id"] as? String })
    }
    func resetActivationRecords() {
        lifecycle.removeAll()
        shownBaseline = (journeyEvents?.routedEvents ?? []).filter { $0.name == SystemEventNames.screenShown }.count
    }
    var checkoutProducts: [[StoreProduct]] = []
    var lifecycle: [String] = []
    var events: [String] = []
    var firstPhases: [ObjectIdentifier: ExperienceScreenLifecyclePhase] = [:]
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController) {
        if firstPhases[ObjectIdentifier(controller)] == nil {
            firstPhases[ObjectIdentifier(controller)] = controller.lifecyclePhase
        }
    }
    func screenEmissionRun(for controller: ExperienceScreenViewController) -> ScreenEmissionRun? { nil }
    func experienceScreenViewController(_ controller: ExperienceScreenViewController,
        didEmitScreenEmission input: ExperienceRuntimeScreenEmission, originatingRun: ScreenEmissionRun?, frameSources: ExperienceEmissionSources?) async {
        let id: String
        let drafts: [ScreenEmissionDraft]
        switch input {
        case .control(let screenId, _, let additional): id = screenId; drafts = additional
        case .effects(let source, let emitted): id = source.screenId; drafts = emitted
        }
        for case .event(let name, _) in drafts { events.append("\(id):\(name)") }
    }
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didEmitViewModelChange change: ExperienceRendererViewModelChange) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didRequestOpenLink request: ExperienceRendererOpenLinkRequest) async {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didPresentDrawable drawable: ExperienceRuntimePresentedDrawable, frameNumber: UInt64) {}
    func experienceScreenViewController(_ controller: ExperienceScreenViewController, didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput) {}
}
#endif
