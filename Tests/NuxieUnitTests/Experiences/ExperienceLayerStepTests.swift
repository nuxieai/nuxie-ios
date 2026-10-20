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
                    "insert:\(style == .push && back ? 0 : 1)", "phases:A=exiting,B=entering:pair",
                    "present", "wait:2:700", "remove", "phases:A=hidden,B=active:",
                    "hidden", "active", "input:true"])
            }
        }
    }

    func testCutRunsDeclaredExitBeforeSwapAndIncomingHalfAfterSwap() async throws {
        let probe = LayerStepProbe()
        try await probe.run(style: .none)
        XCTAssertEqual(probe.order, ["input:false", "prepare", "register:A:declared-exit",
            "phases:A=exiting:", "present", "wait:1:350", "insert:1", "remove",
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
        XCTAssertEqual(probe.order, ["input:false", "prepare", "phases:A=exiting:", "insert:1", "remove",
            "phases:B=entering:pair", "phases:A=hidden,B=active:", "hidden", "active", "input:true"])
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

    func testHistoryKeepsTheActualForwardPairAndSkippingBackHasNoPair() {
        var history = ExperienceLayerHistory(root: "A")
        history.visit("B", transition: .init(kind: .push, transitionId: "route-one"))
        history.visit("C", transition: .init(kind: .fade, transitionId: "route-two"))
        XCTAssertEqual(history.backTransition(steps: 1).transitionId, "route-two")
        XCTAssertNil(history.backTransition(steps: 2).transitionId)
        let skip = NativeExperienceTransition(id: "skip", kind: .layer, sourceScreenId: "A", destinationScreenId: "C",
            durationMs: 400, incomingOnTop: true, source: .init(completeEventName: "leave"),
            destination: .init(completeEventName: "arrive"), reverse: .init(durationMs: nil, incomingOnTop: nil,
                source: .init(completeEventName: "return-leave"), destination: .init(completeEventName: "return-arrive")))
        let skipped = history.backTransition(steps: 2, target: "A", declarations: [skip])
        XCTAssertEqual(skipped.transitionId, "skip")
        XCTAssertNotNil(ExperienceScreenCustomTransitionPlan.resolve(transitionId: "skip", sourceScreenId: "C",
            destinationScreenId: "A", declarations: [skip]))
        history.visit("A", transition: .none)
        XCTAssertEqual(history.screenIDs, ["A"])
        history.visit("B", transition: .init(kind: .magicMove, transitionId: "route-three"))
        XCTAssertEqual(history.backTransition(steps: 1).transitionId, "route-three")
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
