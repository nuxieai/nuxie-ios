import XCTest
@testable import Nuxie

@MainActor
final class ExperienceScreenTransitionCoordinatorTests: XCTestCase {
    func testCustomTransitionResolvesForwardDeclaration() throws {
        let plan = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(
            transitionId: "checkout-to-success",
            sourceScreenId: "checkout",
            destinationScreenId: "success",
            declarations: [customTransitionDeclaration()]
        ))

        XCTAssertEqual(plan.transitionId, "checkout-to-success")
        XCTAssertEqual(plan.durationMilliseconds, 450)
        XCTAssertTrue(plan.incomingOnTop)
        XCTAssertEqual(plan.outgoingCompletionEventName, "checkout.transition.complete")
        XCTAssertEqual(plan.incomingCompletionEventName, "success.transition.complete")
    }

    func testBackNavigationUsesReverseDeclaration() throws {
        let plan = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(
            transitionId: "checkout-to-success",
            sourceScreenId: "success",
            destinationScreenId: "checkout",
            declarations: [customTransitionDeclaration()]
        ))

        XCTAssertEqual(plan.durationMilliseconds, 250)
        XCTAssertFalse(plan.incomingOnTop)
        XCTAssertEqual(plan.outgoingCompletionEventName, "success.reverse.complete")
        XCTAssertEqual(plan.incomingCompletionEventName, "checkout.reverse.complete")
    }

    func testMissingOrMismatchedCustomDeclarationFallsBackToInstant() {
        let declaration = customTransitionDeclaration()

        XCTAssertNil(ExperienceScreenCustomTransitionPlan.resolve(
            transitionId: "missing",
            sourceScreenId: "checkout",
            destinationScreenId: "success",
            declarations: [declaration]
        ))
        XCTAssertNil(ExperienceScreenCustomTransitionPlan.resolve(
            transitionId: "checkout-to-success",
            sourceScreenId: "other",
            destinationScreenId: "success",
            declarations: [declaration]
        ))
    }

    func testReduceMotionSkipsCustomTransitionWaitPath() {
        XCTAssertNil(ExperienceScreenCustomTransitionPlan.resolve(
            transitionId: "checkout-to-success",
            sourceScreenId: "checkout",
            destinationScreenId: "success",
            declarations: [customTransitionDeclaration()],
            reduceMotion: true
        ))
    }

    func testReduceMotionCustomFallbackInstallsDestinationAndSettlesPhases() async throws {
        let spec = ExperienceScreenTransitionSpec(
            kind: .custom(transitionId: "checkout-to-success")
        )
        var source = ExperienceScreenLifecycleState(reduceMotion: true)
        var target = ExperienceScreenLifecycleState(reduceMotion: true)
        _ = source.move(to: .entering, reduceMotion: true)
        _ = source.move(to: .active, reduceMotion: true)
        var installedScreenId: String?

        let didNavigate = try await ExperienceScreenLifecycleNavigation.perform(
            targetEntering: {
                _ = target.move(to: .entering, reduceMotion: true)
            },
            sourceExiting: {
                _ = source.move(to: .exiting, reduceMotion: true)
            },
            nativeOperation: {
                XCTAssertEqual(spec.effectiveKind(reduceMotion: true), spec.kind)
                installedScreenId = "success"
                return true
            },
            sourceHidden: {
                _ = source.move(to: .hidden, reduceMotion: true)
            },
            targetActive: {
                _ = target.move(to: .active, reduceMotion: true)
            },
            restoreAfterFailure: {
                XCTFail("Successful reduced-motion navigation must not restore the source")
            }
        )

        XCTAssertTrue(didNavigate)
        XCTAssertEqual(installedScreenId, "success")
        XCTAssertEqual(source.phase, .hidden)
        XCTAssertEqual(target.phase, .active)
    }

    func testCustomFlowWritesTransitionPhasesAndDisablesOutgoingInputDuringOverlap() async {
        let transitionId = "checkout-to-success"
        var source = ExperienceScreenLifecycleState(reduceMotion: false)
        var target = ExperienceScreenLifecycleState(reduceMotion: false)
        _ = source.move(to: .entering)
        _ = source.move(to: .active)
        var inputEnabled = true
        var sourceCommand: ExperienceInteractiveStateCommand?
        var targetCommand: ExperienceInteractiveStateCommand?

        let didNavigate = await ExperienceScreenCustomTransitionExecution.perform(
            setOutgoingInputEnabled: { inputEnabled = $0 },
            writePhases: {
                XCTAssertFalse(inputEnabled)
                sourceCommand = source.move(
                    to: .exiting,
                    transition: transitionId
                ).stateCommand(viewModelName: "Source", instanceID: "source")
                targetCommand = target.move(
                    to: .entering,
                    transition: transitionId
                ).stateCommand(viewModelName: "Target", instanceID: "target")
            },
            awaitCompletion: {
                XCTAssertFalse(inputEnabled)
            },
            finalize: {
                XCTAssertFalse(inputEnabled)
                return true
            }
        )

        XCTAssertTrue(didNavigate)
        XCTAssertTrue(inputEnabled)
        XCTAssertEqual(
            sourceCommand,
            lifecycleCommand(
                viewModelName: "Source",
                instanceID: "source",
                phase: .exiting,
                appearances: 1,
                transitionId: transitionId
            )
        )
        XCTAssertEqual(
            targetCommand,
            lifecycleCommand(
                viewModelName: "Target",
                instanceID: "target",
                phase: .entering,
                appearances: 1,
                transitionId: transitionId
            )
        )
    }

    func testCustomFlowFinalizesBeforeHiddenAndActiveAnalyticsEdgesAfterTimeout() async {
        var order: [String] = []
        let outgoing = AsyncStream<Void> { _ in }
        let incoming = AsyncStream<Void> { _ in }
        let timeout = TransitionTimeoutRecorder()

        let didNavigate = await ExperienceScreenCustomTransitionExecution.perform(
            setOutgoingInputEnabled: { enabled in
                order.append("input:\(enabled ? "enabled" : "disabled")")
            },
            writePhases: {
                order.append("phases:written")
            },
            awaitCompletion: {
                await ExperienceScreenExitWatchdog.wait(
                    for: [outgoing, incoming],
                    watchdogMilliseconds: 700,
                    sleep: { milliseconds in await timeout.record(milliseconds) }
                )
                order.append("watchdog:timed-out")
            },
            finalize: {
                order.append("navigation:finalized")
                return true
            }
        )
        if didNavigate {
            order.append(SystemEventNames.screenDismissed)
            order.append(SystemEventNames.screenShown)
        }

        XCTAssertEqual(order, [
            "input:disabled",
            "phases:written",
            "watchdog:timed-out",
            "navigation:finalized",
            "input:enabled",
            SystemEventNames.screenDismissed,
            SystemEventNames.screenShown,
        ])
        let watchdogMilliseconds = await timeout.milliseconds()
        XCTAssertEqual(watchdogMilliseconds, 700)
    }

    func testEveryNavigationKindSettlesBeforeHiddenAndActiveAnalyticsEdges() async throws {
        for kind in ExperienceScreenTransitionSpec.Kind.allCases {
            var source = ExperienceScreenLifecycleState(reduceMotion: false)
            var target = ExperienceScreenLifecycleState(reduceMotion: false)
            _ = source.move(to: .entering)
            _ = source.move(to: .active)
            var order: [String] = []

            let didNavigate = try await ExperienceScreenLifecycleNavigation.perform(
                targetEntering: {
                    order.append("target:\(target.move(to: .entering).phase.rawValue)")
                },
                sourceExiting: {
                    order.append("source:\(source.move(to: .exiting).phase.rawValue)")
                },
                nativeOperation: {
                    order.append("native:\(kind.rawValue):settled")
                    return true
                },
                sourceHidden: {
                    order.append("source:\(source.move(to: .hidden).phase.rawValue)")
                    order.append(SystemEventNames.screenDismissed)
                },
                targetActive: {
                    order.append("target:\(target.move(to: .active).phase.rawValue)")
                    order.append(SystemEventNames.screenShown)
                },
                restoreAfterFailure: {
                    XCTFail("Successful navigation must not restore lifecycle state")
                }
            )

            XCTAssertTrue(didNavigate, kind.rawValue)
            XCTAssertEqual(
                order,
                [
                    "target:entering",
                    "source:exiting",
                    "native:\(kind.rawValue):settled",
                    "source:hidden",
                    SystemEventNames.screenDismissed,
                    "target:active",
                    SystemEventNames.screenShown,
                ],
                kind.rawValue
            )
        }
    }

    func testFailedNativeNavigationRestoresLifecycleWithoutAnalyticsEdges() async throws {
        var order: [String] = []

        let didNavigate = try await ExperienceScreenLifecycleNavigation.perform(
            targetEntering: { order.append("target:entering") },
            sourceExiting: { order.append("source:exiting") },
            nativeOperation: {
                order.append("native:failed")
                return false
            },
            sourceHidden: { order.append(SystemEventNames.screenDismissed) },
            targetActive: { order.append(SystemEventNames.screenShown) },
            restoreAfterFailure: { order.append("restored") }
        )

        XCTAssertFalse(didNavigate)
        XCTAssertEqual(order, ["target:entering", "source:exiting", "native:failed", "restored"])
    }

    func testCancellationAfterExitHandshakePreventsNativeNavigation() async {
        let handshake = TransitionSuspension()
        let enteredHandshake = expectation(description: "entered exit handshake")
        var didStartNativeNavigation = false

        let navigation = Task { @MainActor in
            try await ExperienceScreenLifecycleNavigation.perform(
                targetEntering: {},
                sourceExiting: {
                    enteredHandshake.fulfill()
                    await handshake.wait()
                },
                nativeOperation: {
                    didStartNativeNavigation = true
                    return true
                },
                sourceHidden: {},
                targetActive: {},
                restoreAfterFailure: {}
            )
        }

        await fulfillment(of: [enteredHandshake])
        navigation.cancel()
        handshake.resume()

        do {
            _ = try await navigation.value
            XCTFail("Expected cancelled navigation to stop after its exit handshake")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(didStartNativeNavigation)
    }

    func testSheetDragUsesPostHocEdgesAndAwaitsHiddenAnalyticsBeforeReveal() async {
        var order: [String] = []

        await ExperienceScreenLifecycleSheetDismissal.perform(
            dismissedExiting: { order.append("dismissed:exiting") },
            dismissedHidden: { order.append("dismissed:hidden") },
            hiddenAnalytics: {
                order.append(SystemEventNames.screenDismissed)
                await Task.yield()
                order.append("dismissed:analytics-complete")
            },
            revealedEntering: { order.append("revealed:entering") },
            revealedActive: {
                order.append("revealed:active")
                order.append(SystemEventNames.screenShown)
            }
        )

        XCTAssertEqual(order, [
            "dismissed:exiting",
            "dismissed:hidden",
            SystemEventNames.screenDismissed,
            "dismissed:analytics-complete",
            "revealed:entering",
            "revealed:active",
            SystemEventNames.screenShown,
        ])
    }

    func testHiddenEdgeContextCarriesDestinationAndDismissalMethod() {
        XCTAssertEqual(
            ExperienceScreenHiddenContext.navigation(revealingScreenId: "screen-2"),
            ExperienceScreenHiddenContext(
                revealingScreenId: "screen-2",
                method: "navigate"
            )
        )
        XCTAssertEqual(
            [
                ExperienceScreenHiddenContext.teardown(reason: .userDismissed).method,
                ExperienceScreenHiddenContext.teardown(reason: .goalMet).method,
                ExperienceScreenHiddenContext.teardown(reason: .purchaseCompleted).method,
                ExperienceScreenHiddenContext.teardown(reason: .timeout).method,
                ExperienceScreenHiddenContext.teardown(
                    reason: .error(NSError(domain: "test", code: 1))
                ).method,
                ExperienceScreenHiddenContext.teardown(reason: nil).method,
                ExperienceScreenHiddenContext.runtimeFailure.method,
            ],
            [
                "user",
                "goal_met",
                "purchase_completed",
                "timeout",
                "error",
                "experience",
                "error",
            ]
        )
    }

    func testSheetRevealActivationSuppressesDuplicateJourneyTransition() {
        XCTAssertFalse(JourneyTransitionAnalytics.shouldTrack(
            from: "revealed-screen",
            to: "revealed-screen"
        ))
        XCTAssertTrue(JourneyTransitionAnalytics.shouldTrack(
            from: "dismissed-screen",
            to: "revealed-screen"
        ))
    }
}

private func customTransitionDeclaration() -> NativeExperienceTransition {
    NativeExperienceTransition(
        id: "checkout-to-success",
        sourceScreenId: "checkout",
        destinationScreenId: "success",
        durationMs: 450,
        incomingOnTop: true,
        source: .init(completeEventName: "checkout.transition.complete"),
        destination: .init(completeEventName: "success.transition.complete"),
        reverse: .init(
            durationMs: 250,
            incomingOnTop: false,
            source: .init(completeEventName: "success.reverse.complete"),
            destination: .init(completeEventName: "checkout.reverse.complete")
        )
    )
}

private func lifecycleCommand(
    viewModelName: String,
    instanceID: String,
    phase: ExperienceScreenLifecyclePhase,
    appearances: Double,
    transitionId: String
) -> ExperienceInteractiveStateCommand {
    .snapshot([
        .init(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: nil,
            path: "screen/phase",
            value: .string(phase.rawValue)
        ),
        .init(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: nil,
            path: "screen/appearances",
            value: .number(appearances)
        ),
        .init(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: nil,
            path: "screen/transition",
            value: .string(transitionId)
        ),
        .init(
            viewModelName: viewModelName,
            instanceID: instanceID,
            instanceName: nil,
            path: "env/reduceMotion",
            value: .bool(false)
        ),
    ])
}

private actor TransitionTimeoutRecorder {
    private var recordedMilliseconds: UInt64?

    func record(_ milliseconds: UInt64) {
        recordedMilliseconds = milliseconds
    }

    func milliseconds() -> UInt64? {
        recordedMilliseconds
    }
}

@MainActor
private final class TransitionSuspension {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
