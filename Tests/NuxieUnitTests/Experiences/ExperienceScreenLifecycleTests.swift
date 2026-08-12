import XCTest
@testable import Nuxie

final class ExperienceScreenLifecycleTests: XCTestCase {
    func testLifecycleSnapshotBuildsOneTypedReservedStateBatch() {
        let snapshot = ExperienceScreenLifecycleSnapshot(
            phase: .entering,
            appearances: 2,
            transition: "ignored-until-custom-transitions-ship",
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
                    value: .string("")
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

private actor ExitWatchdogSleepRecorder {
    private var recordedMilliseconds: UInt64?

    func record(_ milliseconds: UInt64) {
        recordedMilliseconds = milliseconds
    }

    func milliseconds() -> UInt64? {
        recordedMilliseconds
    }
}
