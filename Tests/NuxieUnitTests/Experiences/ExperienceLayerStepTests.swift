import XCTest
@testable import Nuxie

@MainActor
final class ExperienceLayerStepTests: XCTestCase {
    func testTogetherStylesRegisterBothHalvesBeforeInsertionAndWriteOneBatch() async throws {
        for style in [ExperienceScreenTransitionSpec.Kind.magicMove, .push, .fade] {
            for back in [false, true] {
                let probe = LayerStepProbe()
                try await probe.run(style: style, back: back)
                XCTAssertEqual(probe.order, ["input:false", "prepare", "register:A:exit", "register:B:enter",
                    "insert:1", "phases:A=exiting,B=entering:pair",
                    "present", "wait:2:700", "remove", "phases:A=hidden,B=active:",
                    "hidden", "active", "input:true"])
            }
        }
    }

    func testCutRunsPublishedHalvesSequentiallyInsteadOfTheDeclaredExit() async throws {
        let probe = LayerStepProbe()
        try await probe.run(style: .none)
        XCTAssertEqual(probe.order, ["input:false", "prepare", "register:A:exit",
            "phases:A=exiting:pair", "present", "wait:1:700", "insert:1", "remove",
            "register:B:enter", "phases:B=entering:pair", "present", "wait:1:700",
            "phases:A=hidden,B=active:", "hidden", "active", "input:true"])
    }

    func testMissingPairUsesCutAndDoesNotWaitForAnUndeclaredEntrance() async throws {
        let probe = LayerStepProbe()
        try await probe.run(style: .magicMove, plan: nil)
        XCTAssertEqual(probe.order, ["input:false", "prepare", "register:A:declared-exit",
            "phases:A=exiting:", "present", "wait:1:350", "insert:1", "remove",
            "phases:B=entering:", "present", "phases:A=hidden,B=active:", "hidden", "active", "input:true"])
    }

    func testReducedMotionChangesEveryPhaseWithoutWaitingOrPresentingBetweenHalves() async throws {
        let probe = LayerStepProbe()
        try await probe.run(style: .magicMove, reduced: true)
        XCTAssertEqual(probe.order, ["input:false", "prepare", "phases:A=exiting:pair", "insert:1", "remove",
            "phases:B=entering:pair", "phases:A=hidden,B=active:", "hidden", "active", "input:true"])
    }

    func testPublishedRowOrderWinsOverStyleInBothDirectionsIncludingCuts() async throws {
        for forwardOnTop in [false, true] {
            for reverseOnTop: Bool? in [nil, false, true] {
                let declaration = NativeExperienceTransition(id: "pair", kind: .layer,
                    sourceScreenId: "A", destinationScreenId: "B", durationMs: 450,
                    incomingOnTop: forwardOnTop, source: .init(completeEventName: "exit"),
                    destination: .init(completeEventName: "enter"),
                    reverse: .init(durationMs: nil, incomingOnTop: reverseOnTop,
                        source: .init(completeEventName: "reverse-exit"),
                        destination: .init(completeEventName: "reverse-enter")))
                for back in [false, true] {
                    let plan = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(transitionId: "pair",
                        sourceScreenId: back ? "B" : "A", destinationScreenId: back ? "A" : "B",
                        declarations: [declaration]))
                    let onTop = back ? reverseOnTop ?? forwardOnTop : forwardOnTop
                    for style in [ExperienceScreenTransitionSpec.Kind.magicMove, .push, .fade, .none] {
                        let probe = LayerStepProbe()
                        try await probe.run(style: style, back: back, plan: plan)
                        XCTAssertEqual(probe.order.filter { $0.hasPrefix("insert:") },
                            ["insert:\(onTop ? 1 : 0)"], "\(style), back=\(back), plan=\(plan)")
                    }
                }
            }
        }
    }

    func testWithoutAPublishedPlanOnlyPushBackInsertsBelow() async throws {
        for style in [ExperienceScreenTransitionSpec.Kind.magicMove, .push, .fade, .none] {
            for back in [false, true] {
                let probe = LayerStepProbe()
                try await probe.run(style: style, back: back, plan: nil)
                XCTAssertEqual(probe.order.filter { $0.hasPrefix("insert:") },
                    ["insert:\(style == .push && back ? 0 : 1)"])
            }
        }
    }

    func testPublishedCutWithoutADeclaredExitStillWaitsForItsOutgoingHalf() async throws {
        let probe = LayerStepProbe()
        try await ExperienceLayerStep.perform(source: "A", target: "B", style: .none,
            isBack: false, plan: LayerStepProbe.plan, exit: .init(declaration: nil, reduceMotion: false),
            reduceMotion: false, operations: probe.operations)
        XCTAssertEqual(Array(probe.order.prefix(7)), ["input:false", "prepare", "register:A:exit",
            "phases:A=exiting:pair", "present", "wait:1:700", "insert:1"])
    }

    func testSelfNavigationDoesNothing() async throws {
        let probe = LayerStepProbe()
        try await probe.run(style: .magicMove, target: "A")
        XCTAssertTrue(probe.order.isEmpty)
    }

    func testCancellationDuringWaitDoesNotRemoveOrActivate() async throws {
        let probe = LayerStepProbe()
        let waiting = expectation(description: "waiting for both completions")
        let pair = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            var operations = probe.operations
            operations.wait = { _, _ in
                waiting.fulfill()
                for await _ in pair.stream { break }
            }
            try await ExperienceLayerStep.perform(source: "A", target: "B", style: .magicMove,
                isBack: false, plan: LayerStepProbe.plan, exit: .init(declaration: nil, reduceMotion: false),
                reduceMotion: false, operations: operations)
        }
        await fulfillment(of: [waiting], timeout: 1)
        task.cancel()
        pair.continuation.finish()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(probe.order.contains("remove"))
        XCTAssertFalse(probe.order.contains("active"))
        XCTAssertEqual(probe.order.last, "input:true")
    }

    func testWatchdogExpiryStillRetiresOutgoingBeforeCallbacks() async throws {
        let probe = LayerStepProbe()
        var operations = probe.operations
        operations.wait = { streams, milliseconds in
            await ExperienceScreenExitWatchdog.wait(for: streams, watchdogMilliseconds: milliseconds, sleep: { _ in })
            probe.order.append("expired")
        }
        try await ExperienceLayerStep.perform(source: "A", target: "B", style: .fade,
            isBack: false, plan: LayerStepProbe.plan, exit: .init(declaration: nil, reduceMotion: false),
            reduceMotion: false, operations: operations)
        XCTAssertEqual(Array(probe.order.suffix(6)), ["expired", "remove", "phases:A=hidden,B=active:",
            "hidden", "active", "input:true"])
    }

    func testWatchdogStillFinishesEachHalfWhenNoPhaseFrameIsPresented() async throws {
        for style in [ExperienceScreenTransitionSpec.Kind.fade, .none] {
            let probe = LayerStepProbe()
            let finished = expectation(description: "starved \(style) finishes within its watchdog budgets")
            var succeeded = false
            var presentationCount = 0
            let task = Task { @MainActor in
                var operations = probe.operations
                operations.present = {
                    presentationCount += 1
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
                do {
                    try await ExperienceLayerStep.perform(source: "A", target: "B", style: style,
                        isBack: false, plan: .init(transitionId: "pair", durationMilliseconds: 0,
                            incomingOnTop: true, outgoingCompletionEventName: "exit", incomingCompletionEventName: "enter"),
                        exit: .init(declaration: nil, reduceMotion: false), reduceMotion: false, operations: operations)
                    succeeded = true
                } catch { }
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 1.5)
            XCTAssertTrue(succeeded, "Drawable starvation must expire like the transition watchdog")
            XCTAssertEqual(presentationCount, style == .none ? 2 : 1)
            XCTAssertTrue(probe.order.contains("active"))
            XCTAssertEqual(probe.order.last, "input:true")
            XCTAssertFalse(probe.order.contains { $0.hasPrefix("wait:") }, "An expired presentation budget must not start another watchdog")
            // Cleanup bounds the pre-fix failure after the assertions above.
            task.cancel()
            await task.value
        }
    }

    func testHistoryKeepsTheActualForwardPairAndSkippingBackHasNoPair() async throws {
        var history = ExperienceLayerHistory(root: "A")
        history.visit("B", transition: .init(kind: .push, transitionId: "route-one"))
        history.visit("C", transition: .init(kind: .fade, transitionId: "route-two"))
        XCTAssertEqual(history.backTransition(steps: 1).transitionId, "route-two")
        XCTAssertNil(history.backTransition(steps: 2).transitionId)
        let skip = NativeExperienceTransition(id: "skip", kind: .layer, isDefaultPair: true, sourceScreenId: "A", destinationScreenId: "C",
            durationMs: 400, incomingOnTop: true, source: .init(completeEventName: "leave"),
            destination: .init(completeEventName: "arrive"), reverse: .init(durationMs: nil, incomingOnTop: false,
                source: .init(completeEventName: "return-leave"), destination: .init(completeEventName: "return-arrive")))
        let skipped = history.backTransition(steps: 2, target: "A", declarations: [skip])
        XCTAssertEqual(skipped.transitionId, "skip")
        XCTAssertEqual(skipped.kind, .magicMove, "Skipping Back uses the published default pair")
        let plan = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(transitionId: "skip", sourceScreenId: "C",
            destinationScreenId: "A", declarations: [skip]))
        let probe = LayerStepProbe()
        try await probe.run(style: skipped.kind, back: true, plan: plan)
        XCTAssertTrue(probe.order.contains("insert:0"))
        history.visit("A", transition: .none)
        XCTAssertEqual(history.screenIDs, ["A"])
        history.visit("B", transition: .init(kind: .magicMove, transitionId: "route-three"))
        XCTAssertEqual(history.backTransition(steps: 1).transitionId, "route-three")
    }

    func testSkippingBackDoesNotUseAnUnmarkedRouteBetweenItsEndpoints() {
        var history = ExperienceLayerHistory(root: "A")
        history.visit("B", transition: .init(kind: .push, transitionId: "A-B"))
        history.visit("C", transition: .init(kind: .fade, transitionId: "B-C"))
        let unrelatedRoute = NativeExperienceTransition(id: "unrelated-A-C", kind: .layer,
            sourceScreenId: "A", destinationScreenId: "C", durationMs: 400, incomingOnTop: true,
            source: .init(completeEventName: "override-leave"), destination: .init(completeEventName: "override-arrive"),
            reverse: .init(durationMs: nil, incomingOnTop: nil,
                source: .init(completeEventName: "override-return-leave"), destination: .init(completeEventName: "override-return-arrive")))
        XCTAssertEqual(history.backTransition(steps: 2, target: "A", declarations: [unrelatedRoute]), .none)
        XCTAssertEqual(history.backTransition(steps: 1, target: "B", declarations: [unrelatedRoute]).transitionId, "B-C")
    }

    func testSkippingBackSelectsOnlyAMarkedDefaultInEitherUsableDirection() throws {
        var history = ExperienceLayerHistory(root: "A")
        history.visit("B", transition: .init(kind: .push, transitionId: "A-B"))
        history.visit("C", transition: .init(kind: .fade, transitionId: "B-C"))
        for source in ["A", "C"] {
            for hasReverse in [false, true] {
                let pair = NativeExperienceTransition(id: "default", kind: .layer, isDefaultPair: true,
                    sourceScreenId: source, destinationScreenId: source == "A" ? "C" : "A",
                    durationMs: 400, incomingOnTop: true, source: .init(completeEventName: "leave"),
                    destination: .init(completeEventName: "arrive"), reverse: hasReverse ? .init(durationMs: nil,
                        incomingOnTop: false, source: .init(completeEventName: "return-leave"),
                        destination: .init(completeEventName: "return-arrive")) : nil)
                let route = NativeExperienceTransition(id: "route", kind: .layer, isDefaultPair: false,
                    sourceScreenId: pair.sourceScreenId, destinationScreenId: pair.destinationScreenId,
                    durationMs: 900, incomingOnTop: false, source: .init(completeEventName: "override-leave"),
                    destination: .init(completeEventName: "override-arrive"), reverse: hasReverse ? .init(durationMs: nil,
                        incomingOnTop: true, source: .init(completeEventName: "override-return-leave"),
                        destination: .init(completeEventName: "override-return-arrive")) : nil)
                // The unmarked declaration has identical endpoints and appears first.
                let result = history.backTransition(steps: 2, target: "A", declarations: [route, pair])
                if source == "C" || hasReverse {
                    XCTAssertEqual(result.transitionId, "default")
                    XCTAssertEqual(result.kind, .magicMove)
                    let id = try XCTUnwrap(result.transitionId)
                    let plan = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(transitionId: id,
                        sourceScreenId: "C", destinationScreenId: "A", declarations: [route, pair]))
                    XCTAssertEqual(plan.outgoingCompletionEventName, source == "C" ? "leave" : "return-leave")
                } else {
                    XCTAssertEqual(result, .none, "A reverse half must exist for an A to C declaration")
                }
                XCTAssertEqual(history.backTransition(steps: 2, target: "A", declarations: [route]), .none)
            }
        }
    }
}

@MainActor
private final class LayerStepProbe {
    nonisolated static let plan = ExperienceScreenCustomTransitionPlan(transitionId: "pair", durationMilliseconds: 450,
        incomingOnTop: true, outgoingCompletionEventName: "exit", incomingCompletionEventName: "enter")
    var order: [String] = []
    var operations: ExperienceLayerStep.Operations {
        .init(setInputEnabled: { self.order.append("input:\($0)") },
            prepare: { self.order.append("prepare") },
            register: { id, event in self.order.append("register:\(id):\(event)"); return AsyncStream { _ in } },
            insert: { self.order.append("insert:\($0)") },
            phases: { phases, transition in
                self.order.append("phases:" + phases.map { "\($0.0)=\($0.1.rawValue)" }.joined(separator: ",") + ":" + transition)
            }, present: { self.order.append("present") },
            wait: { streams, duration in self.order.append("wait:\(streams.count):\(duration)") },
            remove: { self.order.append("remove") }, hidden: { self.order.append("hidden") },
            active: { self.order.append("active") })
    }
    func run(style: ExperienceScreenTransitionSpec.Kind, back: Bool = false,
             plan: ExperienceScreenCustomTransitionPlan? = LayerStepProbe.plan,
             reduced: Bool = false, target: String = "B") async throws {
        try await ExperienceLayerStep.perform(source: "A", target: target, style: style, isBack: back,
            plan: plan, exit: .init(declaration: .init(completeEventName: "declared-exit", durationMs: 100), reduceMotion: reduced),
            reduceMotion: reduced, operations: operations)
    }
}
