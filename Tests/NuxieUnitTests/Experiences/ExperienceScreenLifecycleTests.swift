import XCTest
@testable import Nuxie

final class ExperienceScreenLifecycleTests: XCTestCase {
    func testLifecycleSnapshotBuildsOneTypedReservedStateBatch() {
        let snapshot = ExperienceScreenLifecycleSnapshot(
            phase: .entering,
            appearances: 2,
            transition: "transition.checkout_to_success",
            reduceMotion: true
        )

        XCTAssertEqual(
            snapshot.stateCommand(viewModelName: "Root", instanceID: "root-id"),
            .snapshot([
                .init(
                    viewModelName: "Root",
                    instanceID: "root-id",
                    instanceName: nil,
                    path: "screen/phase",
                    value: .string("entering")
                ),
                .init(
                    viewModelName: "Root",
                    instanceID: "root-id",
                    instanceName: nil,
                    path: "screen/appearances",
                    value: .number(2)
                ),
                .init(
                    viewModelName: "Root",
                    instanceID: "root-id",
                    instanceName: nil,
                    path: "screen/transition",
                    value: .string("transition.checkout_to_success")
                ),
                .init(
                    viewModelName: "Root",
                    instanceID: "root-id",
                    instanceName: nil,
                    path: "env/reduceMotion",
                    value: .bool(true)
                ),
            ])
        )
    }

    func testFreshMountUsesHiddenEnteringActiveOrdering() {
        var screen = ExperienceScreenLifecycleState(reduceMotion: false)

        let edges = [
            screen.snapshot.phase,
            screen.move(to: .entering).phase,
            screen.move(to: .active).phase,
        ]

        XCTAssertEqual(edges, [.hidden, .entering, .active])
    }

    func testCachedReturnsIncrementAppearances() {
        var state = ExperienceScreenLifecycleState(reduceMotion: false)

        XCTAssertEqual(state.move(to: .entering).appearances, 1)
        _ = state.move(to: .active)
        _ = state.move(to: .exiting)
        _ = state.move(to: .hidden)
        XCTAssertEqual(state.move(to: .entering).appearances, 2)
    }

    func testAnalyticsAreAnchoredOnlyToActiveAndHiddenEdges() {
        XCTAssertNil(ExperienceScreenLifecyclePhase.entering.analyticsEventName)
        XCTAssertEqual(
            ExperienceScreenLifecyclePhase.active.analyticsEventName,
            SystemEventNames.screenShown
        )
        XCTAssertNil(ExperienceScreenLifecyclePhase.exiting.analyticsEventName)
        XCTAssertEqual(
            ExperienceScreenLifecyclePhase.hidden.analyticsEventName,
            SystemEventNames.screenDismissed
        )
    }

    func testEnvironmentUpdateDoesNotChangePhase() {
        var state = ExperienceScreenLifecycleState(reduceMotion: false)
        _ = state.move(to: .active)

        let snapshot = state.updateReduceMotion(true)

        XCTAssertEqual(snapshot.phase, .active)
        XCTAssertTrue(snapshot.reduceMotion)
    }

    func testHiddenClearsCustomTransitionContext() {
        var state = ExperienceScreenLifecycleState(reduceMotion: false)
        _ = state.move(
            to: .exiting,
            transition: "checkout-to-success"
        )

        let hidden = state.move(to: .hidden)

        XCTAssertEqual(hidden.phase, .hidden)
        XCTAssertEqual(hidden.transition, "")
    }

    func testExitWatchdogUsesDeclaredDurationPlusGraceAndProceedsOnTimeout() async throws {
        let plan = ExperienceScreenExitPlan(
            declaration: NuxPackageScreenExit(
                completeEventName: "exit.complete",
                durationMs: 300
            ),
            reduceMotion: false
        )
        let pair = AsyncStream<Void>.makeStream()
        let recorder = ExitWatchdogSleepRecorder()

        await ExperienceScreenExitWatchdog.wait(
            for: pair.stream,
            watchdogMilliseconds: try XCTUnwrap(plan.watchdogMilliseconds),
            sleep: { milliseconds in await recorder.record(milliseconds) }
        )

        let sleptMilliseconds = await recorder.milliseconds()
        XCTAssertEqual(sleptMilliseconds, 550)
    }

    func testExitWatchdogProceedsWhenReportedEventArrives() async {
        let pair = AsyncStream<Void>.makeStream()
        pair.continuation.yield(())
        let startedAt = Date()

        await ExperienceScreenExitWatchdog.wait(
            for: pair.stream,
            watchdogMilliseconds: 10_000,
            sleep: { milliseconds in
                try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            }
        )

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testCustomTransitionWaitsForBothReportedEvents() async {
        let outgoing = AsyncStream<Void>.makeStream()
        let incoming = AsyncStream<Void>.makeStream()
        let watchdogStarted = AsyncStream<Void>.makeStream()
        let releaseWatchdog = AsyncStream<Void>.makeStream()
        let recorder = CompletionRecorder()
        let task = Task {
            await ExperienceScreenExitWatchdog.wait(
                for: [outgoing.stream, incoming.stream],
                watchdogMilliseconds: 10_000,
                sleep: { _ in
                    watchdogStarted.continuation.yield(())
                    for await _ in releaseWatchdog.stream { return }
                }
            )
            await recorder.markFinished()
        }

        for await _ in watchdogStarted.stream { break }
        outgoing.continuation.yield(())
        await Task.yield()
        let finishedAfterOutgoing = await recorder.isFinished()
        XCTAssertFalse(finishedAfterOutgoing)

        incoming.continuation.yield(())
        await task.value
        let finishedAfterBoth = await recorder.isFinished()
        XCTAssertTrue(finishedAfterBoth)
    }

    func testCustomTransitionWatchdogUsesDurationPlusGrace() async throws {
        let plan = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(
            transitionId: "checkout-to-success",
            sourceScreenId: "checkout",
            destinationScreenId: "success",
            declarations: [customLifecycleTransitionDeclaration()]
        ))
        let recorder = ExitWatchdogSleepRecorder()

        await ExperienceScreenExitWatchdog.wait(
            for: [AsyncStream<Void> { _ in }, AsyncStream<Void> { _ in }],
            watchdogMilliseconds: plan.watchdogMilliseconds,
            sleep: { milliseconds in await recorder.record(milliseconds) }
        )

        let sleptMilliseconds = await recorder.milliseconds()
        XCTAssertEqual(sleptMilliseconds, 700)
    }

    func testReduceMotionSkipsExitWaitWithoutSkippingPhaseEdges() {
        let plan = ExperienceScreenExitPlan(
            declaration: NuxPackageScreenExit(
                completeEventName: "exit.complete",
                durationMs: 300
            ),
            reduceMotion: true
        )
        var state = ExperienceScreenLifecycleState(reduceMotion: true)

        let exiting = state.move(to: .exiting, reduceMotion: true)

        XCTAssertNil(plan.completionEventName)
        XCTAssertNil(plan.watchdogMilliseconds)
        XCTAssertEqual(exiting.phase, .exiting)
    }
}

private func customLifecycleTransitionDeclaration() -> NuxPackageTransition {
    NuxPackageTransition(
        id: "checkout-to-success",
        kind: .choreographed,
        sourceScreenId: "checkout",
        destinationScreenId: "success",
        durationMs: 450,
        incomingOnTop: true,
        source: .init(completeEventName: "checkout.transition.complete"),
        destination: .init(completeEventName: "success.transition.complete"),
        reverse: nil
    )
}

private actor ExitWatchdogSleepRecorder {
    private var recordedMilliseconds: UInt64?

    func record(_ milliseconds: UInt64) {
        recordedMilliseconds = milliseconds
    }

    func milliseconds() -> UInt64? {
        recordedMilliseconds
    }
}

private actor CompletionRecorder {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}
