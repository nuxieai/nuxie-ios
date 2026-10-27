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
            XCTAssertEqual(rootValue("offset", in: returnedB), .number(999),
                "Writes made while Back had removed B reach its new row, in order, after its retained values")
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
            await layer.runtime.recordRowWrites()
            XCTAssertTrue(coordinator.applyValue(path: .init(path: "offset"), value: 84,
                screenId: nil, instanceId: nil))
            try await navigate(coordinator, to: "B")
            let nextA = try await layer.snapshot(screenID: "A")
            let nextB = try await layer.snapshot(screenID: "B")
            XCTAssertEqual(rootValue("offset", in: nextA), .number(84))
            XCTAssertNotEqual(nextB.rootInstanceID, b.rootInstanceID)
            XCTAssertEqual(rootValue("offset", in: nextB), .number(84),
                "A broadcast made while Back had removed B reaches its new row after its retained values")
            let writes = await layer.runtime.rowWriteLog
            XCTAssertFalse(writes.contains(b.rootInstanceID), "R6b: a broadcast never writes to removed B")
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

    func testAMoveAskedForDuringAnEscapeWaitsForTheRevealedPageAndTheRemovedPagesShutdown() async throws {
        final class Box {
            var coordinator: ExperienceScreenTransitionCoordinator?
            var asked: XCTestExpectation?
            var result: ExperienceScreenNavigationResult?
            var log: [String] = []
        }
        let box = Box()
        try await withCoordinator(onWillNavigate: { source, target in
            box.log.append("leave:\(source)>\(target)")
            return .handled
        }, onActive: { id in box.log.append("active:\(id)") }, onHidden: { id in
            box.log.append("hidden:\(id)")
            // Like a Journey that routes the popped Screen's hidden notice to a move.
            guard id == "B", let coordinator = box.coordinator, let asked = box.asked else { return }
            box.asked = nil
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { result, _ in
                box.result = result
                asked.fulfill()
            })
        }) { coordinator, base, _, _ in
            box.coordinator = coordinator
            try await navigate(coordinator, to: "B", transition: ["type": "push"])
            let navigation = try XCTUnwrap(base.navigationController)
            let pushed = try XCTUnwrap(navigation.topViewController as? ExperienceScreenViewController)
            XCTAssertFalse(pushed === base)
            pushed.onShutdown = {
                box.log.append("shutdown:B")
                // Hold the removed page's shutdown long enough for an early move to start.
                try? await Task.sleep(nanoseconds: 300_000_000)
                box.log.append("released:B")
            }
            box.log.removeAll()
            let asked = expectation(description: "the move asked for during the escape lands")
            box.asked = asked
            XCTAssertTrue(navigation.accessibilityPerformEscape(), "VoiceOver's escape is the person's Back")
            await fulfillment(of: [asked], timeout: 10)
            XCTAssertEqual(box.result, .navigated)
            XCTAssertEqual(box.log, ["leave:B>A", "hidden:B", "active:A", "shutdown:B", "released:B",
                "leave:A>B", "hidden:A", "active:B"],
                "The Journey is asked first, and the next move waits until the removed page is shut down")
            XCTAssertEqual(base.screenId, "B")
        }
    }

    func testEscapeAnnouncesTheRevealedPageOnce() async throws {
        try await withLifecycleCoordinator { coordinator, base, probe, _ in
            let before = base.lifecycleAppearances
            try await navigate(coordinator, to: "B", transition: ["type": "push"])
            let navigation = try XCTUnwrap(base.navigationController)
            probe.resetActivationRecords()
            XCTAssertTrue(navigation.accessibilityPerformEscape())
            let deadline = Date().addingTimeInterval(2)
            while probe.shownScreenIDs.isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            await Task.yield()
            assertActivation(probe, screenID: "A")
            try await assertTimelineAdvances(base)
            XCTAssertEqual(base.lifecyclePhase, .active)
            XCTAssertEqual(base.lifecycleAppearances, before + 1)
            XCTAssertTrue(navigation.topViewController === base)
        }
    }

    func testEscapeIsRefusedWithNowhereToGoWaitsDuringAMoveAndClosesASheetAtItsRoot() async throws {
        try await withCoordinator { coordinator, base, probe, _ in
            let navigation = try XCTUnwrap(base.navigationController)
            XCTAssertFalse(navigation.accessibilityPerformEscape(), "With nowhere to go, VoiceOver passes the escape on")
            let forward = expectation(description: "the step lands")
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { _, _ in
                forward.fulfill()
            })
            var deadline = Date().addingTimeInterval(2)
            while base.lifecyclePhase != .exiting, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(base.lifecyclePhase, .exiting, "The escape must arrive during the step")
            probe.lifecycle.removeAll()
            XCTAssertTrue(navigation.accessibilityPerformEscape(), "During a move the escape waits, like a tap on Back")
            await fulfillment(of: [forward], timeout: 5)
            deadline = Date().addingTimeInterval(5)
            while probe.lifecycle.last != "active:A", Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(probe.lifecycle, ["hidden:A", "active:B", "hidden:B", "active:A"],
                "The step lands, then the escape goes back from the Screen it landed on")
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
            let sheet = try XCTUnwrap(coordinator.topPresentedLayer)
            XCTAssertTrue(sheet.accessibilityPerformEscape(), "At a sheet's root the escape closes the sheet")
            deadline = Date().addingTimeInterval(5)
            // The close has landed once the revealed page is active and the queue is free.
            while coordinator.topPresentedLayer != nil || !coordinator.acceptsSwipe, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertNil(coordinator.topPresentedLayer)
            XCTAssertTrue(coordinator.acceptsSwipe)
            XCTAssertEqual(coordinator.layerScreenIds.count, 1)
            XCTAssertEqual(coordinator.activeScreenId, "A")
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

    func testASheetRemovedDuringAnUnpresentedPhaseLandsTheStepThenTheDismissal() async throws {
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
            let landed = expectation(description: "sheet navigation lands")
            var order: [String] = []
            XCTAssertTrue(coordinator.navigate(to: "A",
                transition: ["type": "magic-move", "transitionId": "t1"]) { result, _ in
                order.append("step:\(result)")
                landed.fulfill()
            })
            await fulfillment(of: [blocked], timeout: 2)
            XCTAssertTrue(order.isEmpty)
            let drain = try XCTUnwrap(Mirror(reflecting: coordinator).children
                .first { $0.label == "navigationTask" }?.value as? Task<Void, Never>)
            // UIKit removes the sheet without asking: the running step lands first.
            await withCheckedContinuation { continuation in sheet.navigationController?.dismiss(animated: false) { continuation.resume() } }
            coordinator.presentationControllerDidDismiss(presentation)
            XCTAssertNotNil(coordinator.topPresentedLayer, "The dismissal waits for the running step")
            let deadline = Date().addingTimeInterval(5)
            while coordinator.topPresentedLayer != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            order.append("dismissed")
            XCTAssertNil(coordinator.topPresentedLayer)
            let revealed = expectation(description: "navigation in revealed layer finishes")
            var baseResult: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "B", transition: nil) { result, _ in
                baseResult = result
                revealed.fulfill()
            })
            await fulfillment(of: [landed, revealed], timeout: 3)
            XCTAssertEqual(order, ["step:navigated", "dismissed"])
            XCTAssertEqual(baseResult, .navigated)
            XCTAssertEqual(coordinator.activeScreenId, "B")
            // Cancellation keeps the pre-fix regression bounded after its assertions fail.
            drain.cancel()
            await drain.value
        }
    }

    func testASwipeThatMeetsABackAcrossItsSheetLandsOnceWithoutDismissingAgain() async throws {
        final class Box {
            var coordinator: ExperienceScreenTransitionCoordinator?
            var layer: UIViewController?
            var dismissed: [String] = []
        }
        let box = Box()
        try await withCoordinator(onWillNavigate: { source, target in
            // The person's swipe commits just as the Back starts, and UIKit carries the sheet away.
            if source == "B", target == "A", let coordinator = box.coordinator, let layer = box.layer,
               let presentation = layer.presentationController {
                box.layer = nil
                coordinator.presentationControllerWillDismiss(presentation)
                await withCheckedContinuation { continuation in layer.dismiss(animated: false) { continuation.resume() } }
                coordinator.presentationControllerDidDismiss(presentation)
            }
            return .handled
        }, onDismissed: { dismissed, revealing in
            box.dismissed.append("\(dismissed)>\(revealing ?? "-")")
        }) { coordinator, base, _, _ in
            box.coordinator = coordinator
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
            box.layer = try XCTUnwrap(coordinator.topPresentedLayer)
            let landed = expectation(description: "the Back lands")
            var result: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.back(to: "A", steps: 1) { value, _ in
                result = value
                landed.fulfill()
            })
            await fulfillment(of: [landed], timeout: 10)
            XCTAssertNil(box.layer, "The swipe must arrive during the Back")
            XCTAssertEqual(result, .navigated)
            XCTAssertEqual(box.dismissed, ["B>A"], "The Back takes the swipe over: the Journey hears one dismissal")
            XCTAssertEqual(coordinator.layerScreenIds, [["A"]])
            XCTAssertEqual(base.lifecyclePhase, .active)
        }
    }

    func testAMoveAskedForWhenASwipedAwaySheetLeavesWaitsForTheRevealedPage() async throws {
        final class Box {
            var coordinator: ExperienceScreenTransitionCoordinator?
            var asked: XCTestExpectation?
            var result: ExperienceScreenNavigationResult?
            var log: [String] = []
        }
        let box = Box()
        try await withCoordinator(onWillNavigate: { source, target in
            box.log.append("leave:\(source)>\(target)")
            return .handled
        }, onActive: { id in box.log.append("active:\(id)") }, onHidden: { id in box.log.append("hidden:\(id)") },
        onDismissed: { dismissed, _ in
            box.log.append("dismissed:\(dismissed)")
            // Like a Journey that routes the dismissal to a move, then keeps working before it returns.
            guard let coordinator = box.coordinator, let asked = box.asked else { return }
            box.asked = nil
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { result, _ in
                box.result = result
                asked.fulfill()
            })
            let deadline = Date().addingTimeInterval(0.5)
            while box.result == nil, !box.log.contains(where: { $0.hasPrefix("leave:") }), Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }) { coordinator, _, _, _ in
            box.coordinator = coordinator
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
            let layer = try XCTUnwrap(coordinator.topPresentedLayer)
            let presentation = try XCTUnwrap(layer.presentationController)
            box.log.removeAll()
            let asked = expectation(description: "the move asked for during the swipe-away lands")
            box.asked = asked
            XCTAssertTrue(coordinator.presentationControllerShouldDismiss(presentation))
            coordinator.presentationControllerWillDismiss(presentation)
            await withCheckedContinuation { continuation in layer.dismiss(animated: false) { continuation.resume() } }
            coordinator.presentationControllerDidDismiss(presentation)
            await fulfillment(of: [asked], timeout: 10)
            XCTAssertEqual(box.result, .navigated)
            XCTAssertEqual(box.log, ["dismissed:B", "active:A", "leave:A>B", "hidden:A", "active:B"],
                "The swipe-away activates A before the move it was asked for leaves A")
        }
    }

    func testASwipeIsRefusedWhileAMoveRunsAndAllowedOnceItLands() async throws {
        try await withCoordinator { coordinator, _, _, _ in
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
            let sheet = try XCTUnwrap((coordinator.topPresentedLayer as? UINavigationController)?.topViewController as? ExperienceScreenViewController)
            let presentation = try XCTUnwrap(sheet.navigationController?.presentationController)
            XCTAssertTrue(coordinator.presentationControllerShouldDismiss(presentation))
            let landed = expectation(description: "the step lands")
            XCTAssertTrue(coordinator.navigate(to: "A", transition: ["type": "magic-move", "transitionId": "t1"]) { _, _ in
                landed.fulfill()
            })
            var deadline = Date().addingTimeInterval(2)
            while sheet.lifecyclePhase != .exiting, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(sheet.lifecyclePhase, .exiting, "The question must arrive during the step")
            XCTAssertFalse(coordinator.presentationControllerShouldDismiss(presentation), "The sheet springs back during a move")
            XCTAssertFalse(coordinator.acceptsSwipe, "The Experience's own sheet asks the same gate")
            await fulfillment(of: [landed], timeout: 5)
            deadline = Date().addingTimeInterval(2)
            while !coordinator.acceptsSwipe, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(coordinator.presentationControllerShouldDismiss(presentation))
        }
    }

    func testASwipeQuestionUIKitNeverFollowsUpTakesNothing() async throws {
        try await withCoordinator { coordinator, _, _, _ in
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
            let presentation = try XCTUnwrap(coordinator.topPresentedLayer?.presentationController)
            XCTAssertTrue(coordinator.presentationControllerShouldDismiss(presentation))
            let landed = expectation(description: "the next move runs straight away")
            var result: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "A", transition: ["type": "magic-move", "transitionId": "t1"]) { value, _ in
                result = value
                landed.fulfill()
            })
            await fulfillment(of: [landed], timeout: 5)
            XCTAssertEqual(result, .navigated)
            XCTAssertEqual(coordinator.activeScreenId, "A")
        }
    }

    func testACancelledSwipeReleasesTheSlotThroughItsTransitionCoordinator() async throws {
        try await assertCancelledSwipeReleasesTheSlot { coordinator, layer, _ in
            let platform = DrivenTransitionCoordinator()
            coordinator.beginSwipe(of: layer, revealsPageBelow: true, platform: platform)
            return { platform.end(cancelled: true) }
        }
    }

    func testACancelledSwipeReleasesTheSlotWhenUIKitShowsTheSheetAgain() async throws {
        try await assertCancelledSwipeReleasesTheSlot { coordinator, layer, presentation in
            // In tests UIKit has no transition coordinator: the sheet's reappearance is the cancel.
            coordinator.presentationControllerWillDismiss(presentation)
            return {
                layer.beginAppearanceTransition(false, animated: false)
                layer.beginAppearanceTransition(true, animated: false)
                layer.endAppearanceTransition()
            }
        }
    }

    private func assertCancelledSwipeReleasesTheSlot(
        _ begin: @MainActor (ExperienceScreenTransitionCoordinator, UIViewController, UIPresentationController) -> (@MainActor () -> Void)
    ) async throws {
        try await withCoordinator { coordinator, base, _, _ in
            try await navigate(coordinator, to: "B", transition: ["type": "modal", "present": "sheet"])
            let layer = try XCTUnwrap(coordinator.topPresentedLayer)
            let presentation = try XCTUnwrap(layer.presentationController)
            let cancel = begin(coordinator, layer, presentation)
            XCTAssertFalse(coordinator.acceptsSwipe, "The swipe holds the slot while the finger is down")
            let landed = expectation(description: "the move asked for during the swipe lands")
            var result: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "A", transition: ["type": "magic-move", "transitionId": "t1"]) { value, _ in
                result = value
                landed.fulfill()
            })
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertNil(result, "The move waits while the person holds the sheet")
            cancel()
            await fulfillment(of: [landed], timeout: 5)
            XCTAssertEqual(result, .navigated)
            XCTAssertTrue(coordinator.topPresentedLayer === layer, "The move ran on the sheet")
            XCTAssertEqual(coordinator.activeScreenId, "A")
            XCTAssertEqual(base.lifecyclePhase, .hidden, "The page below never became active")
        }
    }

    func testTheExperiencesOwnSheetHoldsTheSlotWhileDragged() async throws {
        try await withCoordinator { coordinator, base, _, _ in
            // The host stands in for the Experience's own sheet (ExperienceViewController).
            let host = try XCTUnwrap(base.navigationController?.parent)
            coordinator.beginSwipe(of: host, revealsPageBelow: false)
            let cancelled = expectation(description: "a move asked for during a cancelled drag runs")
            var result: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { value, _ in
                result = value
                cancelled.fulfill()
            })
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertNil(result, "The move waits while the person drags the Experience's sheet")
            coordinator.layerDidAppear(host)
            await fulfillment(of: [cancelled], timeout: 5)
            XCTAssertEqual(result, .navigated)
            let deadline = Date().addingTimeInterval(2)
            while !coordinator.acceptsSwipe, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            coordinator.beginSwipe(of: host, revealsPageBelow: false)
            let finished = expectation(description: "a move asked for during a finished drag fails with the close")
            var closedResult: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "A", transition: ["type": "magic-move", "transitionId": "t1"]) { value, _ in
                closedResult = value
                finished.fulfill()
            })
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertNil(closedResult)
            coordinator.closeAfterSwipe(of: host)
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(closedResult, .failed)
            XCTAssertEqual(coordinator.activeScreenId, "B")
        }
    }

    func testACloseDuringAMoveLongerThanTheNativeLimitLetsTheMoveLand() async throws {
        try await withCoordinator { coordinator, controller, probe, _ in
            coordinator.retirementTimeoutNanoseconds = 100_000_000
            var withheld = false
            controller.onPageStep = { [weak controller] _ in
                guard let controller, controller.lifecyclePhase == .exiting, !withheld else { return }
                withheld = true
                // No frame reaches the screen, so each authored wait runs to its own
                // watchdog, well past the native limit.
                controller.setContentHidden(true)
            }
            let forward = expectation(description: "the step lands")
            var result: ExperienceScreenNavigationResult?
            XCTAssertTrue(coordinator.navigate(to: "B", transition: ["type": "magic-move", "transitionId": "t1"]) { value, _ in
                result = value
                forward.fulfill()
            })
            let deadline = Date().addingTimeInterval(2)
            while !withheld, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(withheld, "The close must arrive during the step")
            probe.lifecycle.removeAll()
            let started = Date()
            await coordinator.exitActiveScreenForTeardown(reason: nil)
            await fulfillment(of: [forward], timeout: 5)
            XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2, "The step and the close's exit outlast the native limit")
            XCTAssertEqual(result, .navigated, "A step under way lands; nothing is undone halfway")
            XCTAssertEqual(probe.lifecycle, ["hidden:A", "active:B", "hidden:B"])
            coordinator.retirementTimeoutNanoseconds = ExperienceRuntimeRetirement.timeoutNanoseconds
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

    /// A pushed or presented page mounts entering. As a pushed Screen did
    /// before the page host, its timeline runs through UIKit's presentation.
    func testANewPagesTimelineRunsThroughItsNativePresentation() async throws {
        let payload = try await hostedLiveMovePayload()
        let root = experiencePreparationRepositoryRoot()
        let experience = Experience(id: "layer-host", versionId: "layer-version", buildId: "layer-build",
            artifactContentHash: nil, authenticatedReleaseID: nil, behaviorPresentation: .standard,
            behaviorPresentationScreens: [:], assetBaseURL: root, journey: payload.journey, definition: payload.definition)
        let acquired = AcquiredExperienceArtifact(identity: .init(experienceId: experience.id, buildId: experience.buildId),
            sceneURL: root.appendingPathComponent("fixtures/runtime/page-host-live-moves/page2.riv"), sceneBytes: payload.sceneBytes,
            assetURLsByUniqueName: [:], source: .cache, payload: payload,
            interactivePreparation: .init(cache: hostedLiveMovePreparationCache(), provenance: UUID().uuidString, payload: payload),
            products: [], resourceMetrics: .zero)
        let run = ExperienceRunValues()
        let controller = ExperienceScreenViewController(experience: experience, artifact: .init(acquired: acquired),
            screen: try XCTUnwrap(payload.renderPlan.screens.first { $0.screenId == "B" }), runValues: run,
            reduceMotion: false, usesSystemDisplayLink: false, delegate: nil)
        addTeardownBlock { @MainActor in await controller.shutdownInteractiveScreen(); await run.retire() }
        controller.loadViewIfNeeded()
        try await controller.mountInteractiveScreen(hostTraits: nil)
        let loop = try XCTUnwrap(Mirror(reflecting: controller).children
            .first { $0.label == "presentationLoop" }?.value as? ExperienceRuntimePresentationLoop)
        func timelineIsActive() throws -> Bool {
            try XCTUnwrap(Mirror(reflecting: loop).children.first { $0.label == "isTimelineActive" }?.value as? Bool)
        }
        XCTAssertEqual(controller.lifecyclePhase, .entering)
        XCTAssertFalse(try timelineIsActive(), "Mounting holds the page at its first frame")
        try await controller.preparePagePresentationPhase(.entering, reduceMotion: false)
        XCTAssertEqual(controller.lifecyclePhase, .entering)
        XCTAssertTrue(try timelineIsActive(), "UIKit's presentation plays the entering page")
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
        onActive: (@MainActor (String) async -> Void)? = nil, onHidden: (@MainActor (String) async -> Void)? = nil,
        onDismissed: (@MainActor (String, String?) async -> Void)? = nil,
        _ body: @MainActor (ExperienceScreenTransitionCoordinator, ExperienceScreenViewController,
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
            onPresentedScreenDismissed: { dismissed, revealing in await onDismissed?(dismissed, revealing) },
            onScreenHidden: { id, _ in
                probe.lifecycle.append("hidden:\(id)")
                await onHidden?(id)
            },
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

/// UIKit's coordinator for a swipe the test drives: the finger lifts, then the transition ends.
@MainActor
private final class DrivenTransitionCoordinator: NSObject, UIViewControllerTransitionCoordinator {
    private var interactionHandlers: [(any UIViewControllerTransitionCoordinatorContext) -> Void] = []
    private var completions: [(any UIViewControllerTransitionCoordinatorContext) -> Void] = []
    private(set) var isCancelled = false
    private(set) var isInteractive = true
    var isAnimated: Bool { true }
    var presentationStyle: UIModalPresentationStyle { .pageSheet }
    var initiallyInteractive: Bool { true }
    var isInterruptible: Bool { false }
    var transitionDuration: TimeInterval { 0.3 }
    var percentComplete: CGFloat { 0 }
    var completionVelocity: CGFloat { 1 }
    var completionCurve: UIView.AnimationCurve { .easeOut }
    let containerView = UIView()
    var targetTransform: CGAffineTransform { .identity }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }

    func animate(alongsideTransition animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
                 completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)? = nil) -> Bool {
        if let completion { completions.append(completion) }
        return true
    }

    func animateAlongsideTransition(in view: UIView?,
                                    animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
                                    completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)? = nil) -> Bool {
        animate(alongsideTransition: animation, completion: completion)
    }

    func notifyWhenInteractionEnds(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {
        interactionHandlers.append(handler)
    }

    func notifyWhenInteractionChanges(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {
        interactionHandlers.append(handler)
    }

    func end(cancelled: Bool) {
        isCancelled = cancelled
        isInteractive = false
        interactionHandlers.forEach { $0(self) }
        completions.forEach { $0(self) }
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

#endif
