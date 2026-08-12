import XCTest
@testable import Nuxie

@MainActor
final class ExperienceScreenTransitionCoordinatorTests: XCTestCase {
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
}
