import XCTest
@testable import Nuxie

@MainActor
final class ExperiencePageStepTests: XCTestCase {
    func testTogetherStepTakesRowRegistersBothWaitersThenBatchesPhasesAndBegin() async throws {
        for style in [ExperienceScreenTransitionSpec.Kind.magicMove, .fade] {
            let probe = PageStepProbe()
            try await probe.perform(style: style)
            XCTAssertEqual(probe.order, ["input:false", "prepare", "batch", "register:A:exit", "register:B:enter",
                "batch", "present", "wait:2:700", "batch", "hidden", "active", "input:true"])
            XCTAssertEqual(probe.batches, [[.take], [.phases([("A", .exiting), ("B", .entering)], "pair"), .begin("pair")], [.end("pair"), .retire,
                .phases([("A", .hidden)], ""), .phases([("B", .active)], "")]])
        }
    }

    func testCutRunsPublishedHalvesSequentiallyAndRetiresAfterBegin() async throws {
        let probe = PageStepProbe()
        try await probe.perform(style: .none)
        XCTAssertEqual(probe.order, ["input:false", "prepare", "register:A:exit", "batch", "present", "wait:1:700",
            "register:B:enter", "batch", "present", "wait:1:700", "batch", "hidden", "active", "input:true"])
        XCTAssertEqual(probe.batches[1], [.phases([("B", .entering)], "pair"), .take, .begin("pair"),
            .retire, .phases([("A", .hidden)], "")])
        XCTAssertEqual(probe.batches[2], [.end("pair"), .phases([("B", .active)], "")])
    }

    func testCutWithoutIDPassesNullAndWaitsOnlyForDeclaredExit() async throws {
        let probe = PageStepProbe()
        try await probe.perform(style: .none, plan: nil)
        XCTAssertEqual(probe.order.filter { $0.hasPrefix("register:") }, ["register:A:declared-exit"])
        XCTAssertEqual(probe.order.filter { $0.hasPrefix("wait:") }, ["wait:1:350"])
        XCTAssertTrue(probe.batches.flatMap { $0 }.contains(.begin(nil)))
        XCTAssertTrue(probe.batches.flatMap { $0 }.contains(.end(nil)))
    }

    func testCutWithoutTimelinesDoesNotWaitOrPresent() async throws {
        let probe = PageStepProbe()
        try await probe.perform(style: .none, plan: nil, declaredExit: false)
        XCTAssertFalse(probe.order.contains("present"))
        XCTAssertFalse(probe.order.contains { $0.hasPrefix("wait:") || $0.hasPrefix("register:") })
    }

    func testReducedMotionCallsBeginAndEndInOneBatchWithoutWait() async throws {
        for style in [ExperienceScreenTransitionSpec.Kind.magicMove, .fade, .none] {
            let probe = PageStepProbe()
            try await probe.perform(style: style, reduced: true)
            XCTAssertEqual(probe.batches, [[.phases([("A", .exiting)], "pair"), .phases([("B", .entering)], "pair"),
                .take, .begin("pair"), .end("pair"), .retire, .phases([("A", .hidden)], ""), .phases([("B", .active)], "")]])
            XCTAssertFalse(probe.order.contains("present"))
        }
    }

    func testBeginAlwaysFollowsExpandedIncomingRow() async throws {
        for style in [ExperienceScreenTransitionSpec.Kind.magicMove, .fade, .none] {
            for reduced in [false, true] {
                let probe = PageStepProbe()
                try await probe.perform(style: style, reduced: reduced)
                let changes = probe.batches.flatMap { $0 }
                XCTAssertLessThan(try XCTUnwrap(changes.firstIndex(of: .take)), try XCTUnwrap(changes.firstIndex(of: .begin("pair"))))
            }
        }
    }

    func testWatchdogStartsAfterPresentedFrame() async throws {
        let probe = PageStepProbe()
        try await probe.perform(style: .fade)
        XCTAssertLessThan(try XCTUnwrap(probe.order.firstIndex(of: "present")), try XCTUnwrap(probe.order.firstIndex(of: "wait:2:700")))
    }

    func testPresentationStarvationExpiresWithoutStartingAnotherWatchdog() async throws {
        let probe = PageStepProbe()
        var operations = probe.operations
        operations.present = { try await Task.sleep(nanoseconds: 60_000_000_000) }
        try await ExperiencePageStep.perform(source: "A", target: "B", style: .fade, isBack: false,
            plan: .init(transitionId: "pair", durationMilliseconds: 0, incomingOnTop: true,
                outgoingCompletionEventName: "exit", incomingCompletionEventName: "enter"),
            exit: .init(declaration: nil, reduceMotion: false), reduceMotion: false, operations: operations)
        XCTAssertFalse(probe.order.contains { $0.hasPrefix("wait:") })
        XCTAssertTrue(probe.order.contains("active"))
    }

    func testActiveNavigationIsNoOp() async throws {
        let probe = PageStepProbe()
        try await probe.perform(style: .magicMove, target: "A")
        XCTAssertTrue(probe.order.isEmpty)
    }

    func testCancellationDoesNotEndRetireOrActivate() async throws {
        let probe = PageStepProbe()
        let enteredWait = expectation(description: "wait")
        let stream = AsyncStream<Void>.makeStream()
        var operations = probe.operations
        operations.wait = { _, _ in enteredWait.fulfill(); for await _ in stream.stream { break } }
        let task = Task { @MainActor in
            try await ExperiencePageStep.perform(source: "A", target: "B", style: .fade, isBack: false,
                plan: PageStepProbe.plan, exit: .init(declaration: nil, reduceMotion: false), reduceMotion: false, operations: operations)
        }
        await fulfillment(of: [enteredWait], timeout: 1)
        task.cancel()
        stream.continuation.finish()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(probe.batches.flatMap { $0 }.contains(.retire))
        XCTAssertFalse(probe.order.contains("active"))
        XCTAssertEqual(probe.order.last, "input:true")
    }

    func testRowsAppendCollapseAndExpandWithoutChangingOrder() {
        var rows = ExperiencePageRows()
        XCTAssertEqual(rows.take("A"), .append("A", 0))
        XCTAssertEqual(rows.take("B"), .append("B", 1))
        XCTAssertEqual(rows.retire(active: "B", reachable: ["A", "B"]), [.collapse("A", 0, true)])
        XCTAssertEqual(rows.take("A"), .collapse("A", 0, false))
        XCTAssertEqual(rows.screenIDs, ["A", "B"])
        XCTAssertEqual(rows.retire(active: "A", reachable: ["A", "B"]), [.collapse("B", 1, true)])
    }

    func testBackRemovesOnlyUnreachableRowsAndUpdatesIndexes() {
        var rows = ExperiencePageRows()
        for id in ["A", "B", "C", "D"] { _ = rows.take(id) }
        XCTAssertEqual(rows.retire(active: "A", reachable: ["A", "D"]), [.remove("B", 1), .remove("C", 1), .collapse("D", 1, true)])
        XCTAssertEqual(rows.take("D"), .collapse("D", 1, false))
        XCTAssertEqual(rows.screenIDs, ["A", "D"])
    }

    func testNavigateToKeptScreenRemovesNothingAndKeepsHistory() {
        var history = ExperiencePageHistory(root: "A")
        history.visit("B", transition: .init(kind: .fade, transitionId: "ab"))
        history.visit("A", transition: .init(kind: .magicMove, transitionId: "ba.under"))
        XCTAssertEqual(history.screenIDs, ["A", "B", "A"])
        XCTAssertEqual(history.backTransition(steps: 1).transitionId, "ba.under")
        history.back(to: "B", steps: 1)
        XCTAssertEqual(history.screenIDs, ["A", "B"])
    }

    func testSkippingBackUsesOnlyOrderedMarkedDefaultPair() {
        var history = ExperiencePageHistory(root: "A")
        history.visit("B", transition: .none)
        history.visit("C", transition: .init(kind: .fade, transitionId: "bc"))
        let reverse = declaration(id: "reverse", from: "A", to: "C", marked: true)
        let route = declaration(id: "route", from: "C", to: "A", marked: false)
        let pair = declaration(id: "default", from: "C", to: "A", marked: true)
        XCTAssertEqual(history.backTransition(steps: 2, target: "A", declarations: [reverse, route]), .none)
        XCTAssertEqual(history.backTransition(steps: 2, target: "A", declarations: [reverse, route, pair]).transitionId, "default")
        XCTAssertEqual(history.backTransition(steps: 1).transitionId, "bc")
    }

    func testReverseBackUsesActualForwardIDAndReverseCompletions() throws {
        let pair = declaration(id: "route.under", from: "A", to: "B", marked: false)
        let plan = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(transitionId: pair.id,
            sourceScreenId: "B", destinationScreenId: "A", declarations: [pair]))
        XCTAssertEqual(plan.transitionId, "route.under.reverse")
        XCTAssertEqual(plan.outgoingCompletionEventName, "nx_exit_done:route.under.reverse")
        XCTAssertEqual(plan.incomingCompletionEventName, "nx_enter_done:route.under.reverse")
    }

    func testPushHasIndependentPageHistoryAndSkippingBackTargetsLowerPage() {
        let location = ExperiencePageStack.back(steps: 2, histories: [["A", "B"], ["C"]])
        XCTAssertEqual(location, .init(page: 0, entry: 0, screenID: "A"))
        XCTAssertEqual(ExperiencePageStack.back(steps: 1, histories: [["A", "B"], ["C"]]), .init(page: 0, entry: 1, screenID: "B"))
        XCTAssertEqual(ExperiencePageHistory(root: "C").screenIDs, ["C"])
    }

    func testBackAcrossPushCutsHiddenLowerPageBeforeNativePop() async throws {
        var order: [String] = []
        try await ExperiencePageBack.perform(cut: { order.append("cut:hidden:A") }, pop: { order.append("pop:A") })
        XCTAssertEqual(order, ["cut:hidden:A", "pop:A"])
    }

    private func declaration(id: String, from: String, to: String, marked: Bool) -> NativeExperienceTransition {
        .init(id: id, kind: .page, isDefaultPair: marked, sourceScreenId: from, destinationScreenId: to, durationMs: 450,
            incomingOnTop: true, source: .init(completeEventName: "nx_exit_done:\(id)"), destination: .init(completeEventName: "nx_enter_done:\(id)"),
            reverse: .init(durationMs: nil, incomingOnTop: nil, source: .init(completeEventName: "nx_exit_done:\(id).reverse"),
                destination: .init(completeEventName: "nx_enter_done:\(id).reverse")))
    }
}

@MainActor
private final class PageStepProbe {
    nonisolated static let plan = ExperienceScreenCustomTransitionPlan(transitionId: "pair", durationMilliseconds: 450,
        incomingOnTop: true, outgoingCompletionEventName: "exit", incomingCompletionEventName: "enter")
    var order: [String] = []
    var batches: [[ExperiencePageStep.Change]] = []
    var operations: ExperiencePageStep.Operations {
        .init(setInputEnabled: { self.order.append("input:\($0)") }, prepare: { self.order.append("prepare") },
            register: { id, name in self.order.append("register:\(id):\(name)"); return AsyncStream { _ in } },
            batch: { self.order.append("batch"); self.batches.append($0) }, present: { self.order.append("present") },
            wait: { streams, duration in self.order.append("wait:\(streams.count):\(duration)") },
            hidden: { self.order.append("hidden") }, active: { self.order.append("active") })
    }
    func perform(style: ExperienceScreenTransitionSpec.Kind, plan: ExperienceScreenCustomTransitionPlan? = PageStepProbe.plan,
                 reduced: Bool = false, declaredExit: Bool = true, target: String = "B") async throws {
        try await ExperiencePageStep.perform(source: "A", target: target, style: style, isBack: false, plan: plan,
            exit: .init(declaration: declaredExit ? .init(completeEventName: "declared-exit", durationMs: 100) : nil, reduceMotion: reduced),
            reduceMotion: reduced, operations: operations)
    }
}
