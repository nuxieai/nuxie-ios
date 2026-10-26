#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit
import QuartzCore
import Metal
import XCTest
@testable import NuxieTestSupport
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

@MainActor
final class ExperiencePageHostNavigationTests: JourneyTestCase {
    func testNativePageAbortTimesOutWithoutAbandoningItsPendingNativeWork() async {
        let entered = expectation(description: "native reveal is waiting")
        let abandoned = expectation(description: "native reveal eventually retires")
        var release: CheckedContinuation<Void, Never>?
        var errors: [Error] = []
        let transition = ExperienceNativePageTransition(interactive: false,
            onRetirementFailure: { errors.append($0) }, start: {
                entered.fulfill()
                await withCheckedContinuation { release = $0 }
            }, finish: {}, abandon: { abandoned.fulfill() })
        transition.retirementTimeoutNanoseconds = 1_000_000
        let begin = Task { @MainActor in await transition.begin() }
        await fulfillment(of: [entered], timeout: 1)
        await transition.cancel()
        XCTAssertEqual(errors.first as? ExperienceRuntimeRetirementError, .timedOut)
        release?.resume(); release = nil
        await begin.value
        await fulfillment(of: [abandoned], timeout: 1)
        await transition.cancel()
        XCTAssertEqual(errors.count, 1)
    }

    func testPublishedResponseNavigationDrawsNothingNewUntilDismissalCheckpointSettles() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("forms-saves")
        let (experience, artifact) = try await authenticatedFixtureArtifact(at: directory,
            profileBytes: signedReleaseEntryProfileBytes(fixture: directory, host: "checkpoint-page.nuxie.test"))
        let payload = artifact.payload
        let source = try FixturePageRow.screenID("feedback", in: payload.renderPlan)
        let destination = try FixturePageRow.screenID("welcome", in: payload.renderPlan)
        let entered = expectation(description: "source dismissal checkpoint is waiting")
        var release: CheckedContinuation<JourneyScreenDismissalResult, Never>?
        var checkpoints = 0
        defer { release?.resume(returning: .rejected) }
        try await withCoordinator(presentation: (experience, artifact), initialScreenID: source, onWillNavigate: { from, to in
            XCTAssertEqual(from, source)
            XCTAssertEqual(to, destination)
            checkpoints += 1
            entered.fulfill()
            return await withCheckedContinuation { release = $0 }
        }) { coordinator, controller, _, _ in
            let page = try XCTUnwrap(controller.interactivePage)
            let loop = try XCTUnwrap(Mirror(reflecting: controller).children
                .first { $0.label == "presentationLoop" }?.value as? ExperienceRuntimePresentationLoop)
            XCTAssertTrue(controller.applyValue(path: .init(path: "experience/responses:feedback/comment"),
                value: "edited response", screenId: source, instanceId: nil))
            // applyValue admits FIFO work; it does not wait for the write's
            // zero-delta reflection or presentation. Settle it before navigation.
            try await loop.advanceZeroDelta(awaitsPresentation: true)
            let editedRow = try await FixturePageRow.resolve(page, screenID: source).snapshot
            let editedForm = try fixtureRowReference("experience/responses:feedback", in: editedRow)
            XCTAssertEqual(editedRow.values.first { $0.ownerInstanceID == editedForm && $0.name == "comment" }?.value,
                .bytes(Data("edited response".utf8)))
            XCTAssertEqual(checkpoints, 0, "The edit settles without any navigation checkpoint")
            await page.recordLifecycleWrites()
            var deliveredSteps = 0
            controller.onPageStep = { _ in deliveredSteps += 1 }
            let finished = self.expectation(description: "navigation finished")
            XCTAssertTrue(coordinator.navigate(to: destination, transition: ["type": "none"]) { result, _ in
                XCTAssertTrue(result.reachedTarget)
                finished.fulfill()
            })
            await self.fulfillment(of: [entered], timeout: 5)
            let phasesAtCheckpoint = await page.lifecycleWriteLog
            let mountedAtCheckpoint = await page.mountedScreenIDs
            XCTAssertEqual(phasesAtCheckpoint, [], "No exit or incoming lifecycle write before the checkpoint")
            XCTAssertEqual(mountedAtCheckpoint, [source])
            // A source frame accepted just before the timeline pause may still
            // be retiring. Wait for lane quiescence, never for pixels to match.
            let idleDeadline = Date().addingTimeInterval(5)
            while !controller.hasCompletedLatestFrame, Date() < idleDeadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(controller.hasCompletedLatestFrame, "The source lane must settle before the pixel baseline")
            let elapsedAtBaseline = controller.timelineElapsedSeconds
            let stepsAtBaseline = deliveredSteps
            let surface = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.first)
            // Use the current device-pixel size and scale, without resizing the
            // live renderer. This is the same readback seam as the F6 count test.
            @MainActor func pixels() async throws -> Data {
                let width = Int(surface.metalLayer.drawableSize.width)
                let height = Int(surface.metalLayer.drawableSize.height)
                XCTAssertGreaterThan(width, 0); XCTAssertGreaterThan(height, 0)
                let device = try await page.runtime.metalDevice().value
                let layer = CAMetalLayer()
                layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.framebufferOnly = false
                layer.drawableSize = CGSize(width: width, height: height)
                let drawable = try XCTUnwrap(layer.nextDrawable())
                let stride = (width * 4 + 255) & ~255
                let buffer = try XCTUnwrap(device.makeBuffer(length: stride * height, options: .storageModeShared))
                let rendered = self.expectation(description: "checkpoint pixel readback")
                let scale = Float(surface.runtimeDisplayScale)
                let target = NuxieNativeDrawable(drawable)
                let readback = NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: stride)
                // Read back on the same lane as accepted writes and source
                // steps, without requesting another advance or presentation.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    loop.enqueue(.init {
                        let frame = try await page.runtime.renderFrame(layoutScaleFactor: scale,
                            drawable: .available(target), readback: readback, completion: { rendered.fulfill() })
                        return .work(requestsFrame: false) {
                            XCTAssertEqual(frame.outcome.disposition, .presented)
                        }
                    }, completion: { continuation.resume(with: $0) })
                }
                await self.fulfillment(of: [rendered], timeout: 5)
                var data = Data()
                for row in 0..<height {
                    data.append(buffer.contents().assumingMemoryBound(to: UInt8.self) + row * stride, count: width * 4)
                }
                return data
            }
            let before = try await pixels()
            controller.advance(delta: 1 / 60)
            try await Task.sleep(nanoseconds: 100_000_000)
            let waiting = try await pixels()
            XCTAssertTrue(waiting == before, "Zero changed pixels while the source checkpoint waits")
            XCTAssertEqual(controller.timelineElapsedSeconds, elapsedAtBaseline)
            XCTAssertEqual(deliveredSteps, stepsAtBaseline, "No source advance during the settled checkpoint wait")
            let phasesWhileWaiting = await page.lifecycleWriteLog
            XCTAssertEqual(phasesWhileWaiting, [], "No lifecycle or page step starts while the checkpoint waits")
            XCTAssertEqual(controller.screenId, source)
            XCTAssertFalse(controller.view.isUserInteractionEnabled)
            let mounted = await page.mountedScreenIDs
            XCTAssertEqual(mounted, [source], "No incoming expansion or step_begin before the checkpoint")
            let resume = release; release = nil; resume?.resume(returning: .handled)
            await self.fulfillment(of: [finished], timeout: 5)
            let row = try await FixturePageRow.resolve(page, screenID: destination).snapshot
            let form = try fixtureRowReference("experience/responses:feedback", in: row)
            XCTAssertEqual(row.values.first { $0.ownerInstanceID == form && $0.name == "comment" }?.value,
                .bytes(Data("edited response".utf8)))
            XCTAssertEqual(checkpoints, 1, "Navigation must not commit the dismissal twice")
        }
    }

    func testHandledCheckpointLeavesTheOnlyExitAndWaitToThePageStep() async throws {
        let entered = expectation(description: "checkpoint before any exit")
        var release: CheckedContinuation<JourneyScreenDismissalResult, Never>?
        defer { release?.resume(returning: .rejected) }
        try await withCoordinator(onWillNavigate: { _, _ in
            entered.fulfill()
            return await withCheckedContinuation { release = $0 }
        }) { coordinator, controller, _, _ in
            let page = try XCTUnwrap(controller.interactivePage)
            await page.recordLifecycleWrites()
            var waits = 0
            controller.onExitCompletionWait = { waits += 1 }
            let finished = self.expectation(description: "handled step finished")
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { result, _ in
                XCTAssertTrue(result.reachedTarget)
                finished.fulfill()
            })
            await self.fulfillment(of: [entered], timeout: 5)
            let pendingWrites = await page.lifecycleWriteLog
            XCTAssertEqual(pendingWrites, [])
            XCTAssertEqual(controller.lifecyclePhase, .active)
            XCTAssertEqual(waits, 0)
            let resume = release; release = nil; resume?.resume(returning: .handled)
            await self.fulfillment(of: [finished], timeout: 5)
            let writes = await page.lifecycleWriteLog ?? []
            XCTAssertEqual(writes.filter { $0.phase == .exiting }, [.init(screenID: "A", phase: .exiting)])
            XCTAssertEqual(waits, 1, "The page transition owns the only completion wait")
        }
    }

    func testTerminalDismissalCheckpointNeverStartsIncomingPageStep() async throws {
        for outcome in [JourneyScreenDismissalResult.completed, .rejected] {
            try await withCoordinator(onWillNavigate: { _, _ in outcome }) { coordinator, controller, _, _ in
                let page = try XCTUnwrap(controller.interactivePage)
                await page.recordLifecycleWrites()
                var waits = 0
                controller.onExitCompletionWait = { waits += 1 }
                let finished = self.expectation(description: "terminal navigation result")
                XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "none"]) { result, _ in
                    XCTAssertFalse(result.reachedTarget); finished.fulfill()
                })
                await self.fulfillment(of: [finished], timeout: 5)
                XCTAssertEqual(controller.screenId, "A")
                XCTAssertEqual(controller.lifecyclePhase, .active)
                let mounted = await controller.interactivePage?.mountedScreenIDs
                XCTAssertEqual(mounted, ["A"])
                let writes = await page.lifecycleWriteLog
                XCTAssertEqual(writes, [], "Terminal checkpoint outcomes must never write exiting")
                XCTAssertEqual(waits, 0)
            }
        }
    }

    func testOpeningPushOrModalNeverDismissesItsPresentingScreen() async throws {
        let transitions: [[String: Any]] = [
            ["type": "push"],
            ["type": "modal", "present": "sheet"],
            ["type": "modal", "present": "fullscreen"]
        ]
        for transition in transitions {
            try await withCoordinator(onWillNavigate: { _, _ in
                XCTFail("Opening a layer must not checkpoint its presenter")
                return .rejected
            }) { coordinator, presenter, probe, _ in
                let page = try XCTUnwrap(presenter.interactivePage)
                let before = try await page.snapshot(screenID: "A").rootInstanceID
                await page.recordLifecycleWrites()
                probe.lifecycle.removeAll()
                try await self.navigate(coordinator, to: "B", transition: transition)
                XCTAssertFalse(probe.lifecycle.contains("hidden:A"), "No didDismissScreen when a layer opens")
                XCTAssertEqual(presenter.screenId, "A")
                let active = await page.activeScreenID
                let mounted = await page.mountedScreenIDs
                let after = try await page.snapshot(screenID: "A").rootInstanceID
                let writes = await page.lifecycleWriteLog ?? []
                XCTAssertEqual(active, "A", "Coverage preserves the presenter's selected active row")
                XCTAssertEqual(mounted, ["A"])
                XCTAssertEqual(before, after)
                XCTAssertFalse(writes.contains { $0.phase == .exiting })
                XCTAssertFalse(presenter.view.isUserInteractionEnabled)
                XCTAssertEqual(coordinator.activeScreenId, "B")
            }
        }
    }

    func testBackAcrossPagesCheckpointsBeforeTheUpperPagesSingleExit() async throws {
        let transitions: [[String: Any]] = [["type": "push"], ["type": "modal", "present": "sheet"]]
        for transition in transitions {
            var upperPage: ExperienceInteractivePage?
            var checkpoints = 0
            try await withCoordinator(onWillNavigate: { from, to in
                checkpoints += 1
                XCTAssertEqual(from, "B")
                XCTAssertEqual(to, "A")
                guard let page = upperPage else {
                    XCTFail("Back must checkpoint the mounted upper page")
                    return .rejected
                }
                let writes = await page.lifecycleWriteLog
                XCTAssertEqual(writes, [], "Back checkpoints before the upper page exits")
                return .handled
            }) { coordinator, lower, _, _ in
                try await self.navigate(coordinator, to: "B", transition: transition)
                let navigation = transition["type"] as? String == "push"
                    ? lower.navigationController : coordinator.topPresentedLayer as? UINavigationController
                let upper = try XCTUnwrap(navigation?.topViewController as? ExperienceScreenViewController)
                let page = try XCTUnwrap(upper.interactivePage)
                upperPage = page
                await page.recordLifecycleWrites()
                XCTAssertEqual(checkpoints, 0)
                try await self.back(coordinator, to: "A")
                let writes = await page.lifecycleWriteLog ?? []
                XCTAssertEqual(writes.filter { $0.phase == .exiting }, [.init(screenID: "B", phase: .exiting)])
                XCTAssertEqual(checkpoints, 1)
                XCTAssertEqual(lower.lifecyclePhase, .active)
                XCTAssertEqual(coordinator.activeScreenId, "A")
            }
        }
    }

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
            let a = try await layer.snapshot(screenID: "A").rootInstanceID
            try await navigate(coordinator, to: "B", transition: ["type": "magic-move", "transitionId": "t1"])
            XCTAssertEqual(coordinator.layerScreenIds, [["A", "B"]])
            XCTAssertEqual(controller.screenId, "B")
            XCTAssertFalse(completed["A"]?.contains("nx_exit_done:t1") == true)
            XCTAssertTrue(completed["B"]?.contains("nx_enter_done:t1") == true)
            XCTAssertFalse(probe.events.contains("A:nx_exit_done:t1"), "Fixture has no outgoing completion")
            XCTAssertTrue(probe.events.contains("B:nx_enter_done:t1"))
            let mountedB = await layer.mountedScreenIDs
            XCTAssertEqual(mountedB, ["A", "B"])
            XCTAssertTrue(coordinator.applyValue(path: VmPathRef(viewModelName: "Screen1", path: "offset"),
                value: 42, screenId: "B", instanceId: "row-b"))
            try await back(coordinator, to: "A")
            XCTAssertEqual(coordinator.layerScreenIds, [["A"]])
            XCTAssertFalse(completed["B"]?.contains("nx_exit_done:back") == true)
            XCTAssertTrue(completed["A"]?.contains("nx_enter_done:back") == true)
            let revisitedA = try await layer.snapshot(screenID: "A").rootInstanceID
            XCTAssertEqual(a, revisitedA)
            try await navigate(coordinator, to: "B", transition: ["type": "none"])
            let revisitedB = try await layer.snapshot(screenID: "B")
            XCTAssertTrue(revisitedB.values.contains { $0.name == "offset" && $0.value == .number(42) })
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 1)
            XCTAssertEqual(probe.lifecycle.suffix(2), ["hidden:A", "active:B"])
        }
    }

    func testPageBackWithOwnPrimitiveReversesTheForwardStep() async throws {
        try await withCoordinator { coordinator, controller, probe, preparation in
            try await navigate(coordinator, to: "B",
                transition: ["type": "magic-move", "transitionId": "t1"])
            try await back(coordinator, to: "A", transition: ["type": "none"])
            XCTAssertEqual(controller.screenId, "A")
            XCTAssertFalse(probe.events.contains("B:nx_exit_done:back"), "Fixture has no outgoing completion")
            XCTAssertTrue(probe.events.contains("A:nx_enter_done:back"))
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 1)
        }
    }

    func testCachedSnapshotInitializesNewRowsWithoutOverwritingRevisitedValues() async throws {
        try await withCoordinator { coordinator, controller, _, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            XCTAssertTrue(coordinator.applySnapshot(.init(values: [
                .init(viewModelName: "Screen0", instanceId: "row-a", path: "offset", value: AnyCodable(7)),
                .init(viewModelName: "Screen1", instanceId: "row-b", path: "offset", value: AnyCodable(11))
            ]), screenId: nil))
            XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Screen0", path: "offset"),
                value: 21, screenId: "A", instanceId: "row-a"))
            try await navigate(coordinator, to: "B")
            let firstB = try await layer.snapshot(screenID: "B")
            XCTAssertEqual(rootValue("offset", in: firstB), .number(11), "A newly prepared row receives the cached snapshot")
            XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Screen1", path: "offset"),
                value: 42, screenId: "B", instanceId: "row-b"))
            try await back(coordinator, to: "A")
            let returnedA = try await layer.snapshot(screenID: "A")
            XCTAssertEqual(rootValue("offset", in: returnedA), .number(21))
            await layer.runtime.recordRowWrites()
            XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Screen1", path: "offset"),
                value: 123, screenId: "B", instanceId: "row-b"))
            XCTAssertTrue(coordinator.applySnapshot(.init(values: [
                .init(viewModelName: "Screen1", instanceId: "row-b", path: "offset", value: AnyCodable(999))
            ]), screenId: "B"))
            try await navigate(coordinator, to: "B")
            let returnedB = try await layer.snapshot(screenID: "B")
            XCTAssertNotEqual(returnedB.rootInstanceID, firstB.rootInstanceID)
            XCTAssertEqual(rootValue("offset", in: returnedB), .number(42))
            let writes = await layer.runtime.rowWriteLog
            XCTAssertFalse(writes.contains(firstB.rootInstanceID), "Queued values and cached snapshots must not write to removed B")
            XCTAssertTrue(coordinator.applySnapshot(.init(values: [
                .init(viewModelName: "Screen1", instanceId: "row-b", path: "offset", value: AnyCodable(99))
            ]), screenId: "B"))
            try await back(coordinator, to: "A")
            let updatedB = try await layer.snapshot(screenID: "B")
            XCTAssertEqual(rootValue("offset", in: updatedB), .number(99), "Explicit snapshots still update retained rows")
        }
    }

    func testUnqualifiedBroadcastResolvesTheDefaultViewModelOfEachRetainedRow() async throws {
        try await withCoordinator { coordinator, controller, _, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            try await navigate(coordinator, to: "B")
            XCTAssertTrue(coordinator.applyValue(path: .init(path: "offset"), value: 42,
                screenId: nil, instanceId: nil))
            try await back(coordinator, to: "A")
            let a = try await layer.snapshot(screenID: "A")
            let b = try await layer.snapshot(screenID: "B")
            XCTAssertEqual(rootValue("offset", in: a), .number(42))
            XCTAssertEqual(rootValue("offset", in: b), .number(42))
            XCTAssertTrue(coordinator.applyValue(path: .init(path: "offset"), value: 84,
                screenId: nil, instanceId: nil))
            try await navigate(coordinator, to: "B")
            let nextA = try await layer.snapshot(screenID: "A")
            let nextB = try await layer.snapshot(screenID: "B")
            XCTAssertEqual(rootValue("offset", in: nextA), .number(84))
            XCTAssertEqual(rootValue("offset", in: nextB), .number(42), "R6b: broadcasts do not change a removed row's frozen values")
        }
    }

    func testCutWithPublishedHalvesEmitsItsOutgoingCompletionBeforeSwapping() async throws {
        throw XCTSkip("Stage C: A/B live-move fixture has no outgoing completion event or leave duration; requires a published two-half cut fixture")
        try await withCoordinator { coordinator, controller, _, _ in
            var mountedAtExit: [String]?
            let layer = try XCTUnwrap(controller.interactivePage)
            controller.onPageStep = { step in
                if step.rows["A"]?.effects.contains(where: {
                    if case .reportedEvent(let event) = $0.kind {
                        return event.name == "nx_exit_done:t1"
                    }
                    return false
                }) == true {
                    mountedAtExit = step.mountedScreenIDs
                }
            }
            try await navigate(coordinator, to: "B", transition: ["type": "none", "transitionId": "t1"])
            XCTAssertEqual(mountedAtExit, ["A"], "The published leave must finish before insertion")
            let mounted = await layer.mountedScreenIDs
            XCTAssertEqual(mounted, ["A", "B"])
        }
    }

    func testRowInitiatedStepDeliversBothTransitionHalvesExactlyOnce() async throws {
        throw XCTSkip("Stage C: A/B fixture has only incoming completion events; cannot prove delivery of both authored halves")
        try await checkRowInitiatedStep(removingRequester: false)
    }

    func testRemovedRowsLateStepStillDeliversTheMountedRowsEffects() async throws {
        try await checkRowInitiatedStep(removingRequester: true)
    }

    private func checkRowInitiatedStep(removingRequester: Bool) async throws {
        try await withCoordinator { _, controller, probe, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            try await controller.preparePageRow(screenID: "B", products: [])
            let requester = try await layer.binding(screenID: "A")
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
                    try await layer.insert(screenID: "B", at: 1)
                    try await layer.setPhases([("A", .exiting), ("B", .entering)],
                        transition: "t1")
                    _ = try await layer.step(elapsedSeconds: 0)
                    if removingRequester { _ = try await layer.remove(screenID: "A") }
                    let result = try await requester.step(elapsedSeconds: 1.1)
                    return .work(requestsFrame: false) {
                        await controller.deliverStep(result, screenID: "A")
                    }
                }, completion: { continuation.resume(with: $0) })
            }
            let incoming = "nx_enter_done:t1"
            XCTAssertEqual(delivered["B"]?.filter { $0 == incoming }, [incoming])
            XCTAssertEqual(probe.events.filter { $0 == "B:\(incoming)" }.count, 1)
            if !removingRequester {
                let outgoing = "nx_exit_done:t1"
                XCTAssertEqual(delivered["A"]?.filter { $0 == outgoing }, [outgoing])
                XCTAssertEqual(probe.events.filter { $0 == "A:\(outgoing)" }.count, 1)
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
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "fade", "transitionId": "t1"]) { result, _ in
                results.append(result); first.fulfill()
            })
            let deadline = Date().addingTimeInterval(2)
            while controller.lifecyclePhase != .exiting, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(controller.lifecyclePhase, .exiting)
            XCTAssertFalse(controller.receiveFocusInput(.next), "Input is blocked while both rows run")
            XCTAssertTrue(coordinator.navigate(to: "B", transition: nil) { result, _ in
                results.append(result); second.fulfill()
            })
            await fulfillment(of: [first, second], timeout: 5)
            XCTAssertEqual(results, [.navigated, .alreadyActive])
            XCTAssertEqual(coordinator.layerScreenIds, [["A", "B"]])
            XCTAssertEqual(controller.screenId, "B")
        }
    }

    func testPushOpensNewPageAndSkippingBackCutsCoveredLowerPageBeforePop() async throws {
        try await withCoordinator { coordinator, lower, _, preparation in
            try await navigate(coordinator, to: "B")
            let navigation = try XCTUnwrap(lower.navigationController)
            let lowerPlayer = try XCTUnwrap(lower.interactivePage)
            try await navigate(coordinator, to: "A", transition: ["type": "push"])
            let pushed = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(pushed === lower)
            XCTAssertFalse(pushed.interactivePage === lowerPlayer)
            XCTAssertEqual(lower.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.count, 1)
            XCTAssertEqual(pushed.view.subviews.compactMap { $0 as? ExperienceRuntimeSurfaceView }.count, 1)
            XCTAssertEqual(lower.lifecyclePhase, .hidden)
            XCTAssertEqual(pushed.lifecyclePhase, .active)
            XCTAssertEqual(pushed.pageHistory.screenIDs, ["A"])
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 2)
            let priorLifecycle = await lowerPlayer.lifecycle(screenID: "A")
            let before = try XCTUnwrap(priorLifecycle).appearances
            var cutWhileCovered = false
            lower.onPageStep = { _ in
                if lower.screenId == "A", lower.lifecyclePhase == .hidden, navigation.viewControllers.count == 2 {
                    cutWhileCovered = true
                    XCTAssertEqual(lower.lifecycleAppearances, before)
                }
            }
            let result = await withCheckedContinuation { continuation in
                XCTAssertTrue(coordinator.back(to: "A", steps: 2) { result, _ in continuation.resume(returning: result) })
            }
            XCTAssertEqual(result, .navigated)
            XCTAssertTrue(cutWhileCovered)
            XCTAssertTrue(navigation.topViewController === lower)
            XCTAssertEqual(lower.screenId, "A")
            XCTAssertEqual(lower.pageHistory.screenIDs, ["A"])
            XCTAssertEqual(lower.lifecycleAppearances, before + 1)
        }
    }

    func testPushInsideFitContentSheetPublishesItsHeightAndPopRestoresLowerHeightOnce() async throws {
        try await withCoordinator { coordinator, _, probe, _ in
            let heights = PageSheetHeightProbe(initialHeights: [152, 400])
            probe.onFirstAdvance = { heights.install(on: $0) }
            try await navigate(coordinator, to: "B",
                transition: ["type": "modal", "present": "sheet", "height": "fit-content"])
            let navigation = try XCTUnwrap(coordinator.topPresentedLayer as? UINavigationController)
            let lower = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            XCTAssertEqual(navigation.preferredContentSize.height, 152)
            XCTAssertGreaterThan(heights.queryCount(for: lower), 0)

            try await navigate(coordinator, to: "A", transition: ["type": "push"])
            let pushed = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(pushed === lower)
            XCTAssertFalse(pushed.interactivePage === lower.interactivePage)
            XCTAssertEqual(navigation.preferredContentSize.height, 400)
            XCTAssertEqual(heights.published(for: pushed, to: navigation), [400])
            let coveredQueries = heights.queryCount(for: lower)
            try await advanceHeightFrame(lower)
            XCTAssertEqual(heights.queryCount(for: lower), coveredQueries)

            heights.setHeight(480, for: pushed)
            try await advanceHeightFrame(pushed)
            XCTAssertEqual(navigation.preferredContentSize.height, 480)
            XCTAssertEqual(heights.published(for: pushed, to: navigation), [400, 480])
            try await advanceHeightFrame(pushed)
            XCTAssertEqual(heights.published(for: pushed, to: navigation), [400, 480],
                "A cached height must not publish twice")

            let beforePop = heights.published(for: lower, to: navigation).count
            try await back(coordinator, to: "B")
            XCTAssertTrue(navigation.topViewController === lower)
            XCTAssertEqual(navigation.preferredContentSize.height, 152)
            XCTAssertEqual(heights.published(for: lower, to: navigation).count, beforePop + 1,
                "Reveal must reclaim the shared sheet target once even when the lower height is unchanged")
            try await advanceHeightFrame(lower)
            XCTAssertEqual(heights.published(for: lower, to: navigation).count, beforePop + 1)
        }
    }

    func testSkippingBackCutsCoveredFitContentPageBeforeRestoringItsCurrentHeight() async throws {
        try await withCoordinator { coordinator, _, probe, _ in
            let heights = PageSheetHeightProbe(initialHeights: [152, 400])
            probe.onFirstAdvance = { heights.install(on: $0) }
            try await navigate(coordinator, to: "B",
                transition: ["type": "modal", "present": "sheet", "height": "fit-content"])
            let navigation = try XCTUnwrap(coordinator.topPresentedLayer as? UINavigationController)
            let lower = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            try await navigate(coordinator, to: "A")
            XCTAssertEqual(lower.pageHistory.screenIDs, ["B", "A"])
            try await navigate(coordinator, to: "B", transition: ["type": "push"])
            XCTAssertEqual(navigation.preferredContentSize.height, 400)
            let coveredQueries = heights.queryCount(for: lower)
            let coveredPublications = heights.published(for: lower, to: navigation).count
            heights.setHeight(230, for: lower)
            var cutBeforePop = false
            lower.onPageStep = { _ in
                if lower.screenId == "B", lower.lifecyclePhase == .hidden, navigation.viewControllers.count == 2 {
                    cutBeforePop = true
                    XCTAssertEqual(heights.queryCount(for: lower), coveredQueries)
                    XCTAssertEqual(heights.published(for: lower, to: navigation).count, coveredPublications)
                    XCTAssertEqual(navigation.preferredContentSize.height, 400)
                }
            }
            try await back(coordinator, to: "B", steps: 2)
            XCTAssertTrue(cutBeforePop)
            XCTAssertTrue(navigation.topViewController === lower)
            XCTAssertEqual(lower.pageHistory.screenIDs, ["B"])
            XCTAssertEqual(navigation.preferredContentSize.height, 230)
            XCTAssertEqual(heights.published(for: lower, to: navigation).filter { $0 == 230 }, [230])
            try await advanceHeightFrame(lower)
            XCTAssertEqual(heights.published(for: lower, to: navigation).filter { $0 == 230 }, [230])
        }
    }

    func testSheetOverPushedFitContentPageOwnsItsHeightAndCoveredPagesDoNotMeasure() async throws {
        try await withCoordinator { coordinator, _, probe, _ in
            let heights = PageSheetHeightProbe(initialHeights: [152, 400, 260])
            probe.onFirstAdvance = { heights.install(on: $0) }
            try await navigate(coordinator, to: "B",
                transition: ["type": "modal", "present": "sheet", "height": "fit-content"])
            let navigation = try XCTUnwrap(coordinator.topPresentedLayer as? UINavigationController)
            let lower = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            try await navigate(coordinator, to: "A", transition: ["type": "push"])
            let pushed = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            try await navigate(coordinator, to: "B",
                transition: ["type": "modal", "present": "sheet", "height": "fit-content"])
            let upperNavigation = try XCTUnwrap(coordinator.topPresentedLayer as? UINavigationController)
            let upper = try XCTUnwrap(upperNavigation.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(upperNavigation === navigation)
            XCTAssertEqual(upperNavigation.preferredContentSize.height, 260)
            XCTAssertEqual(navigation.preferredContentSize.height, 400)
            let pushedQueries = heights.queryCount(for: pushed)
            let lowerQueries = heights.queryCount(for: lower)
            let pushedPublications = heights.published(for: pushed, to: navigation)
            try await advanceHeightFrame(pushed)
            try await advanceHeightFrame(lower)
            XCTAssertEqual(heights.queryCount(for: pushed), pushedQueries)
            XCTAssertEqual(heights.queryCount(for: lower), lowerQueries)
            heights.setHeight(280, for: upper)
            try await advanceHeightFrame(upper)
            XCTAssertEqual(upperNavigation.preferredContentSize.height, 280)
            XCTAssertEqual(heights.published(for: upper, to: upperNavigation), [260, 280])
            XCTAssertEqual(navigation.preferredContentSize.height, 400)
            XCTAssertEqual(heights.published(for: pushed, to: navigation), pushedPublications)

            let result = await coordinator.closeTopLayer()
            XCTAssertEqual(result, .navigated)
            XCTAssertTrue(navigation.topViewController === pushed)
            XCTAssertEqual(navigation.preferredContentSize.height, 400)
            XCTAssertGreaterThan(heights.queryCount(for: pushed), pushedQueries)
            XCTAssertEqual(heights.queryCount(for: lower), lowerQueries)
            XCTAssertEqual(heights.published(for: pushed, to: navigation), pushedPublications,
                "Revealing the pushed page must not republish an unchanged sheet target")
        }
    }

    private func advanceHeightFrame(_ controller: ExperienceScreenViewController) async throws {
        let loop = try XCTUnwrap(Mirror(reflecting: controller).children.first {
            $0.label == "presentationLoop"
        }?.value as? ExperienceRuntimePresentationLoop)
        try await loop.advanceZeroDelta()
    }

    func testBackThreeTrimsRepeatedLowerScreenBeforeUpperPageDismissal() async throws {
        try await withCoordinator { coordinator, lower, _, _ in
            try await navigate(coordinator, to: "B")
            try await navigate(coordinator, to: "A")
            XCTAssertEqual(lower.pageHistory.screenIDs, ["A", "B", "A"])
            let page = try XCTUnwrap(lower.interactivePage)
            let bSnapshot = try await page.snapshot(screenID: "B")
            let b = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: bSnapshot.rootInstanceID))
            let before = await page.mountedScreenIDs
            XCTAssertTrue(before.contains("B"))

            // A push to B is expressible above A with the A/B live-move release.
            try await navigate(coordinator, to: "B", transition: ["type": "push"])
            let navigation = try XCTUnwrap(lower.navigationController)
            let upper = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(upper === lower)
            XCTAssertEqual(upper.pageHistory.screenIDs, ["B"])
            let loop = try XCTUnwrap(Mirror(reflecting: upper).children
                .first { $0.label == "presentationLoop" }?.value as? ExperienceRuntimePresentationLoop)
            let gate = ConcurrencyProbeGate(holding: .all)
            defer { Task { await gate.open() } }
            // Hold the upper loop so its exit handshake cannot finish and pop.
            // The independent lower page can still trim and remove its native row.
            XCTAssertTrue(loop.enqueue(.init {
                try await gate.enter("upper-exit")
                await gate.exit("upper-exit")
                return .work(requestsFrame: false) {}
            }))
            let returning = Task { try await back(coordinator, to: "A", steps: 3) }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if await page.mountedScreenIDs == ["A"] { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(navigation.topViewController === upper,
                "The lower page must be trimmed before the upper page is dismissed")
            XCTAssertEqual(navigation.viewControllers.count, 2)
            XCTAssertEqual(lower.pageHistory.screenIDs, ["A"])
            let mounted = await page.mountedScreenIDs
            XCTAssertEqual(mounted, ["A"])
            let native = try await page.runtime.snapshot()
            let list = native.values.first {
                $0.ownerInstanceID == native.rootInstanceID && $0.name == "screens"
            }
            if case .list(let ids) = list?.value {
                XCTAssertEqual(ids.count, 1)
                XCTAssertFalse(ids.contains(b.rawValue))
            } else {
                XCTFail("The lower page must expose its native Screen list")
            }
            let retainedNativeB = try await page.runtime.retainsViewModel(b)
            XCTAssertFalse(retainedNativeB)
            let retained = await page.retainedScreenIDs
            XCTAssertTrue(retained.contains("B"), "The removed row keeps its frozen snapshot until revisit or close")
            let removedB = await page.isRowRemoved(screenID: "B")
            XCTAssertTrue(removedB)
            await gate.open()
            try await returning.value
            XCTAssertTrue(navigation.topViewController === lower)
            XCTAssertEqual(lower.pageHistory.screenIDs, ["A"])
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
                try await navigate(coordinator, to: index.isMultiple(of: 2) ? "B" : "A",
                    transition: ["type": "modal", "present": "sheet"])
            }
            probe.resetActivationRecords()
            try await back(coordinator, to: "A", steps: modalCount)
            XCTAssertEqual(coordinator.layerScreenIds, [["A"]])
            XCTAssertEqual(base.lifecyclePhase, .active)
            assertActivation(probe, screenID: "A")
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
            try await navigate(coordinator, to: "B", transition: modal
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
                assertActivation(probe, screenID: "A")
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
            try await navigate(coordinator, to: "B", transition: ["type": "push"])
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
            assertActivation(probe, screenID: "A")
            try await assertTimelineAdvances(base)
            XCTAssertEqual(base.lifecyclePhase, .active)
            XCTAssertEqual(base.lifecycleAppearances, before + 1)
        }
    }

    func testModalOwnsAnotherPlayerAndDismissalRevealsRetainedBase() async throws {
        try await withLifecycleCoordinator { coordinator, base, probe, preparation in
            let layer = try XCTUnwrap(base.interactivePage)
            let before = try await layer.snapshot(screenID: "A").rootInstanceID
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet", "closedby": "none"])
            let modal = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(modal === base)
            XCTAssertEqual(probe.firstPhases[ObjectIdentifier(modal)], .entering)
            let firstAppearance = await modal.interactivePage?.lifecycle(screenID: "B")
            XCTAssertEqual(firstAppearance?.appearances, 1)
            XCTAssertFalse(modal.interactivePage === base.interactivePage)
            XCTAssertTrue(modal.navigationController?.isModalInPresentation == true)
            XCTAssertEqual(coordinator.layerScreenIds, [["A"], ["B"]])
            let metrics = await preparation.metrics()
            XCTAssertEqual(metrics.openedSessionCount, 2)
            probe.resetActivationRecords()
            let result = await coordinator.closeTopLayer()
            XCTAssertEqual(result, .navigated)
            XCTAssertNil(coordinator.topPresentedLayer)
            XCTAssertEqual(coordinator.activeScreenId, "A")
            let after = try await layer.snapshot(screenID: "A").rootInstanceID
            XCTAssertEqual(before, after)
            assertActivation(probe, screenID: "A")
            try await assertTimelineAdvances(base)
        }
    }

    func testTapFromActiveNestedRowKeepsItsScreenOwner() async throws {
        throw XCTSkip("Stage C: A/B fixture has no generated Nuxie Interaction pressable at the interim probe coordinates")
        try await withCoordinator { coordinator, controller, _, _ in
            try await navigate(coordinator, to: "B")
            let layer = try XCTUnwrap(controller.interactivePage)
            let down = try await layer.step(pointers: [.init(kind: .down, x: 60, y: 40)], elapsedSeconds: 0)
            let up = try await layer.step(pointers: [.init(kind: .up, x: 60, y: 40)], elapsedSeconds: 0)
            XCTAssertTrue(down.rows["A"] == nil)
            XCTAssertTrue(up.rows["A"] == nil)
            XCTAssertTrue(up.rows["B"]?.effects.contains {
                if case .rejectedHostCommand(let name, _) = $0.kind { return name == "Nuxie Interaction" }
                return false
            } == true)
            XCTAssertTrue(up.unattributedEvents.isEmpty)
        }
    }

    func testOnlyActiveRowExposesSemanticsAndEditorsAndFieldOwnerSurvivesRevisit() async throws {
        throw XCTSkip("Stage C: layer-host-input lacks live-move records; A/B fixture lacks the two published editable Screen declarations required by this scenario")
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
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { result, _ in
                results.append(result)
                forward.fulfill()
            })
            let deadline = Date().addingTimeInterval(2)
            while controller.lifecyclePhase != .exiting, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(controller.lifecyclePhase, .exiting)
            XCTAssertTrue(coordinator.back(to: "A", steps: 1) { result, _ in
                results.append(result)
                returned.fulfill()
            })
            XCTAssertTrue(results.isEmpty, "Back during a step must be queued rather than completing alreadyActive")
            await fulfillment(of: [forward, returned], timeout: 5)
            XCTAssertEqual(results, [.navigated, .navigated])
            XCTAssertEqual(coordinator.layerScreenIds, [["A"]])
            XCTAssertFalse(probe.events.contains("B:nx_exit_done:back"), "Fixture has no outgoing completion")
            XCTAssertTrue(probe.events.contains("A:nx_enter_done:back"))
        }
    }

    func testCloseDuringAStepLandsTheStepThenExitsTheScreenItLandedOn() async throws {
        try await withCoordinator { coordinator, controller, probe, _ in
            let forward = expectation(description: "forward finishes")
            var result: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { navigated, _ in
                result = navigated
                forward.fulfill()
            })
            let deadline = Date().addingTimeInterval(2)
            while controller.lifecyclePhase != .exiting, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(controller.lifecyclePhase, .exiting, "The close must arrive during the step")
            probe.lifecycle.removeAll()
            await coordinator.exitActiveScreenForTeardown(reason: nil)
            await fulfillment(of: [forward], timeout: 5)
            XCTAssertEqual(result, .navigated, "A step under way lands; nothing is undone halfway")
            XCTAssertEqual(controller.screenId, "B")
            XCTAssertTrue(probe.events.contains("B:nx_enter_done:t1"))
            XCTAssertEqual(probe.lifecycle, ["hidden:A", "active:B", "hidden:B"])
            XCTAssertEqual(controller.lifecyclePhase, .hidden)
        }
    }

    func testStackedSheetsAndSwipeDismissalKeepEachLayerIndependent() async throws {
        try await withLifecycleCoordinator { coordinator, base, probe, preparation in
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet", "height": "medium"])
            let lower = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            try await navigate(coordinator, to: "A", transition: ["type": "modal", "present": "sheet"])
            let upper = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(upper.view.window === lower.view.window)
            XCTAssertTrue(lower.view.window === base.view.window)
            XCTAssertEqual(coordinator.layerScreenIds, [["A"], ["B"], ["A"]])
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
            XCTAssertEqual(coordinator.layerScreenIds, [["A"], ["B"]])
            XCTAssertEqual(lower.lifecyclePhase, .active)
            coordinator.presentationControllerDidDismiss(presentation)
            await Task.yield()
            assertActivation(probe, screenID: "B")
            try await assertTimelineAdvances(lower)
            probe.resetActivationRecords()
            let closed = await coordinator.closeTopLayer()
            XCTAssertEqual(closed, .navigated)
            assertActivation(probe, screenID: "A")
            try await assertTimelineAdvances(base)
            XCTAssertEqual(coordinator.layerScreenIds, [["A"]])
        }
    }

    func testAttributedJourneyEventCannotOverrideItsRowWithAPayloadScreenID() async throws {
        try await withCoordinator { _, controller, probe, _ in
            let effect = ExperienceInteractiveEffect(sequence: 0, correlationID: 1,
                kind: .journeyEvent(name: "row-event", payload: .object([.init(key: "screenId", value: .string("A"))])))
            await controller.deliverStep(effects: [effect], screenID: "B")
            XCTAssertTrue(probe.events.contains("B:row-event"))
        }
    }

    func testSwipeDuringAnUnpresentedPhaseSupersedesNavigationAndReleasesTheDrain() async throws {
        try await withCoordinator { coordinator, _, _, _ in
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
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
            XCTAssertTrue(coordinator.navigate(to: "A",
                transition: ["type": "magic-move", "transitionId": "t1"]) { result, _ in
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
            XCTAssertTrue(coordinator.navigate(to: "B", transition: nil) { result, _ in
                baseResult = result
                revealed.fulfill()
            })
            await fulfillment(of: [superseded, revealed], timeout: 3)
            XCTAssertEqual(sheetResult, .superseded)
            XCTAssertEqual(baseResult, .navigated)
            XCTAssertEqual(coordinator.activeScreenId, "B")
            // Cancellation keeps the pre-fix regression bounded after its assertions fail.
            drain.cancel()
            await drain.value
        }
    }

    func testRevisitsReuseTheRowsOriginalProductsForDisplayAndCheckout() async throws {
        let resolver = LayerProductResolver()
        try await withCoordinator(productResolver: { await resolver.resolve($0) }) { coordinator, controller, probe, _ in
            let layer = try XCTUnwrap(controller.interactivePage)
            try await navigate(coordinator, to: "B")
            let original = try await layer.products(screenID: "B")
            XCTAssertEqual(original.first?.price, "B:1")
            try await back(coordinator, to: "A")
            try await navigate(coordinator, to: "B")
            let counts = await resolver.counts
            XCTAssertEqual(counts, ["A": 1, "B": 1])
            XCTAssertEqual(probe.checkoutProducts.last, original)
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
            let modal = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            let modalProducts = try await XCTUnwrap(modal.interactivePage).products(screenID: "B")
            XCTAssertEqual(modalProducts.first?.price, "B:2", "A new layer prepares its own row")
            let closed = await coordinator.closeTopLayer()
            XCTAssertEqual(closed, .navigated)
            try await back(coordinator, to: "A")
            try await navigate(coordinator, to: "B")
            let retained = try await layer.products(screenID: "B")
            let finalCounts = await resolver.counts
            XCTAssertEqual(finalCounts, ["A": 1, "B": 2])
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
        guard result == .navigated else { throw NavigationDidNotComplete(result: result) }
    }

    private struct NavigationDidNotComplete: Error {
        let result: ExperienceScreenNavigationResult
    }

    private func back(_ coordinator: ExperienceScreenTransitionCoordinator, to id: String, steps: Int = 1, transition: Any? = nil) async throws {
        let result: ExperienceScreenNavigationResult = await withCheckedContinuation { continuation in
            if !coordinator.back(to: id, steps: steps, transition: transition, completion: { result, _ in continuation.resume(returning: result) }) {
                continuation.resume(returning: .failed)
            }
        }
        guard result == .navigated else { throw NavigationDidNotComplete(result: result) }
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

    func testDuplicateScreenPagesReceiveEnvironmentAndShutdownExactlyOnce() async throws {
        try await withCoordinator { coordinator, base, _, _ in
            try await navigate(coordinator, to: "A", transition: ["type": "push"])
            let pushed = try XCTUnwrap(base.navigationController?.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(pushed === base)
            XCTAssertEqual(base.navigationController?.viewControllers.count, 2)
            let basePage = try XCTUnwrap(base.interactivePage)
            let pushedPage = try XCTUnwrap(pushed.interactivePage)
            for value in [true, false] {
                await coordinator.updateReduceMotion(value)
                let baseState = await basePage.lifecycle(screenID: "A")
                let pushedState = await pushedPage.lifecycle(screenID: "A")
                XCTAssertEqual(baseState?.reduceMotion, value)
                XCTAssertEqual(pushedState?.reduceMotion, value)
            }
            XCTAssertEqual(base.shutdownInvocationCount, 0)
            XCTAssertEqual(pushed.shutdownInvocationCount, 0)
            await coordinator.tearDown()
            XCTAssertEqual(base.shutdownInvocationCount, 1)
            XCTAssertEqual(pushed.shutdownInvocationCount, 1)
            XCTAssertNil(base.interactivePage)
            XCTAssertNil(pushed.interactivePage)
            await coordinator.tearDown()
            XCTAssertEqual(base.shutdownInvocationCount, 1)
            XCTAssertEqual(pushed.shutdownInvocationCount, 1)
        }
    }

    func testPushingSameScreenThenPoppingKeepsScreenTargetedCommandsOnRetainedPage() async throws {
        try await withCoordinator { coordinator, base, _, _ in
            try await navigate(coordinator, to: "A", transition: ["type": "push"])
            XCTAssertEqual(base.navigationController?.viewControllers.count, 2)
            try await back(coordinator, to: "A")
            XCTAssertTrue(base.navigationController?.topViewController === base)
            XCTAssertTrue(coordinator.applyValue(path: .init(viewModelName: "Screen0", path: "offset"),
                value: 73, screenId: "A", instanceId: "row-a"))
            XCTAssertTrue(coordinator.applySnapshot(.init(values: [
                .init(viewModelName: "Screen0", instanceId: "row-a", path: "offset", value: AnyCodable(73))
            ]), screenId: "A"))
            let page = try XCTUnwrap(base.interactivePage)
            var snapshot = try await page.snapshot(screenID: "A")
            let deadline = Date().addingTimeInterval(2)
            while rootValue("offset", in: snapshot) != .number(73), Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
                snapshot = try await page.snapshot(screenID: "A")
            }
            XCTAssertEqual(rootValue("offset", in: snapshot), .number(73))
            try await assertTimelineAdvances(base)
        }
    }

    private func assertActivation(_ probe: LayerHostProbe, screenID: String,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(probe.lifecycle.filter { $0.hasPrefix("active:") }, ["active:\(screenID)"], file: file, line: line)
        let journeyID = screenID
        XCTAssertEqual(probe.shownScreenIDs, [journeyID], file: file, line: line)
    }

    private func withLifecycleCoordinator(_ body: @MainActor (ExperienceScreenTransitionCoordinator,
        ExperienceScreenViewController, LayerHostProbe, ExperienceInteractivePreparation) async throws -> Void) async throws {
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let fixture = try hostedLiveMoveFixture()
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
            let accepted = await request.onScreenChanged(id)
            XCTAssertTrue(accepted)
        }) { coordinator, controller, probe, preparation in
            probe.journeyEvents = events
            try await body(coordinator, controller, probe, preparation)
        }
        // Keep the service alive through every callback and assertion.
        withExtendedLifetime(service) {}
    }

    private func withCoordinator(presentation suppliedPresentation: (Experience, LoadedExperienceArtifact)? = nil,
        payload suppliedPayload: AuthenticatedRuntimePayload? = nil,
        initialScreenID: String? = nil,
        productResolver: (@Sendable (String) async throws -> [StoreProduct])? = nil,
        onWillNavigate: @escaping @MainActor (String, String) async -> JourneyScreenDismissalResult = { _, _ in .handled },
        onActive: (@MainActor (String) async -> Void)? = nil, _ body: @MainActor (ExperienceScreenTransitionCoordinator, ExperienceScreenViewController,
        LayerHostProbe, ExperienceInteractivePreparation) async throws -> Void) async throws {
        let experience: Experience
        let artifact: LoadedExperienceArtifact
        if let suppliedPresentation {
            // Keep signed acquisition's resource bindings and ordinary preparation.
            experience = suppliedPresentation.0
            artifact = suppliedPresentation.1
        } else {
            let payload: AuthenticatedRuntimePayload
            if let suppliedPayload { payload = suppliedPayload }
            else { payload = try await hostedLiveMovePayload() }
            let root = experiencePreparationRepositoryRoot()
            experience = Experience(id: "layer-host", versionId: "layer-version", buildId: "layer-build",
                artifactContentHash: nil, authenticatedReleaseID: nil, behaviorPresentation: .standard,
                behaviorPresentationScreens: [:], assetBaseURL: root, journey: payload.journey, definition: payload.definition)
            let acquired = AcquiredExperienceArtifact(identity: .init(experienceId: experience.id, buildId: experience.buildId),
                sceneURL: root.appendingPathComponent("fixtures/runtime/page-host-live-moves/page2.riv"), sceneBytes: payload.sceneBytes,
                assetURLsByUniqueName: [:], source: .cache, payload: payload,
                interactivePreparation: .init(cache: hostedLiveMovePreparationCache(), provenance: UUID().uuidString, payload: payload),
                products: [], resourceMetrics: .zero, productResolver: productResolver)
            artifact = .init(acquired: acquired)
        }
        let preparation = try await artifact.acquired.interactivePreparation.preparation()
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
        let coordinator = ExperienceScreenTransitionCoordinator(experience: experience, artifact: artifact,
            initialScreenID: initialScreenID,
            hostViewController: host, screenDelegate: probe,
            onPresentedScreenDismissed: { _, _ in },
            onScreenHidden: { id, _ in probe.lifecycle.append("hidden:\(id)") },
            onScreenWillNavigate: onWillNavigate,
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
    var onFirstAdvance: (@MainActor (ExperienceScreenViewController) -> Void)?
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
            onFirstAdvance?(controller)
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

/// The A/B live-move fixture has no qualified unequal intrinsic heights.
/// Supply heights at the ordinary query boundary and observe the actual UIKit
/// publisher, while navigation, coverage, row cuts and detents use product code.
@MainActor
private final class PageSheetHeightProbe {
    private let initialHeights: [Float]
    private var heights: [ObjectIdentifier: Float] = [:]
    private var queries: [ObjectIdentifier: Int] = [:]
    private var publications: [(owner: ObjectIdentifier, target: ObjectIdentifier, height: CGFloat)] = []

    init(initialHeights: [Float]) { self.initialHeights = initialHeights }

    func install(on controller: ExperienceScreenViewController) {
        let owner = ObjectIdentifier(controller)
        guard heights[owner] == nil else { return }
        guard initialHeights.indices.contains(heights.count) else {
            XCTFail("Unexpected page in sheet-height scenario")
            return
        }
        let height = initialHeights[heights.count]
        heights[owner] = height
        controller.pageContentHeightQuery = { [weak self] in
            guard let self else { return nil }
            self.queries[owner, default: 0] += 1
            return self.heights[owner]
        }
        controller.onContentHeightPublished = { [weak self] target, height in
            if let navigation = target as? UINavigationController {
                XCTAssertEqual(navigation.topViewController.map { ObjectIdentifier($0) }, owner,
                    "Only the installed top page may publish to a sheet navigation target")
            }
            self?.publications.append((owner, ObjectIdentifier(target), height))
        }
    }

    func setHeight(_ height: Float, for controller: ExperienceScreenViewController) {
        heights[ObjectIdentifier(controller)] = height
    }

    func queryCount(for controller: ExperienceScreenViewController) -> Int {
        queries[ObjectIdentifier(controller), default: 0]
    }

    func published(for controller: ExperienceScreenViewController, to target: UIViewController) -> [CGFloat] {
        // Initial NOT_FOUND selects the large fallback; these assertions compare
        // the positive page heights that replace it on the shared sheet target.
        publications.filter {
            $0.owner == ObjectIdentifier(controller) && $0.target == ObjectIdentifier(target) && $0.height > 0
        }
            .map { $0.height }
    }
}
#endif
