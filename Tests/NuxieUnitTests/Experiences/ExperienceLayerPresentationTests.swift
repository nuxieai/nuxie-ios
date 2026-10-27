import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif
#if canImport(UIKit)
import UIKit

@MainActor
final class ExperienceLayerPresentationTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/\(name).json"))
    }

    func testSharedPresentationOptionsAndStrictValidation() throws {
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("presentation-options")) as? [String: Any])
        for item in try XCTUnwrap(vector["cases"] as? [[String: Any]]) {
            let transition = try XCTUnwrap(item["transition"] as? [String: Any])
            XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateJourneyTransition(transition, path: "transition"))
            let parsed = ExperienceScreenTransitionSpec(raw: transition)
            XCTAssertEqual(parsed.kind, .modal)
            XCTAssertEqual(parsed.presentation.kind.rawValue, item["present"] as? String)
            XCTAssertEqual(parsed.presentation.height.rawValue, item["height"] as? String)
            XCTAssertEqual(parsed.presentation.closedBy.rawValue, item["closedby"] as? String)
            XCTAssertEqual(parsed.isAvailable, item["available"] as? Bool)
        }
        for transition in try XCTUnwrap(vector["invalid"] as? [[String: Any]]) {
            XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateJourneyTransition(transition, path: "transition"))
        }
    }

    func testUnknownModalPresentationIsUnavailable() {
        for kind in ["dialog", "unknown"] {
            let parsed = ExperienceScreenTransitionSpec(raw: ["type": "modal", "present": kind])
            XCTAssertFalse(parsed.isAvailable)
        }
    }

    func testNativeSheetDetentsAndCloseFlags() throws {
        for height in [ExperienceLayerPresentation.Height.medium, .large] {
            for closedBy in [ExperienceLayerPresentation.ClosedBy.any, .none] {
                let controller = UIViewController()
                let configurator = ExperienceLayerPresentationConfigurator(
                    presentation: .init(height: height, closedBy: closedBy))
                configurator.configure(controller)
                XCTAssertEqual(controller.modalPresentationStyle, .pageSheet)
                XCTAssertEqual(controller.isModalInPresentation, closedBy == .none)
                XCTAssertEqual(controller.sheetPresentationController?.prefersGrabberVisible, closedBy == .any)
                XCTAssertEqual(controller.sheetPresentationController?.detents.count, 1)
                if #available(iOS 16.0, *) {
                    XCTAssertEqual(controller.sheetPresentationController?.detents.map(\.identifier),
                                   [height == .medium ? .medium : .large])
                }
            }
        }
    }

    func testContentHeightUsesNativeMaximumAndSystemDetents() {
        XCTAssertEqual(ExperienceLayerPresentationConfigurator.contentHeight(300, maximum: 852), 300)
        XCTAssertEqual(ExperienceLayerPresentationConfigurator.contentHeight(900, maximum: 852), 852)
        XCTAssertTrue(ExperienceLayerPresentationConfigurator.usesMediumDetent(contentHeight: 300, availableHeight: 852))
        XCTAssertFalse(ExperienceLayerPresentationConfigurator.usesMediumDetent(contentHeight: 600, availableHeight: 852))
        XCTAssertFalse(ExperienceLayerPresentationConfigurator.usesMediumDetent(contentHeight: 0, availableHeight: 852))
        let controller = UIViewController()
        ExperienceLayerPresentationConfigurator(presentation: .init(height: .fitContent)).configure(controller)
        if #available(iOS 16.0, *) {
            XCTAssertEqual(controller.sheetPresentationController?.detents.map(\.identifier), [.large])
        }
        ExperienceLayerPresentationConfigurator.updateContentHeight(controller, height: 152)
        XCTAssertEqual(controller.preferredContentSize.height, 152)
    }

    func testFirstLayerDelegateForwardsCompletedSwipeOnlyOnceWithoutWaitingForExit() async throws {
        let controller = CompletedSheetDismissalController()
        let screenID = try XCTUnwrap(controller.experience.behaviorPresentationScreens.keys.first)
        let shell = try XCTUnwrap(controller.experience.shellContract(screenId: screenID,
            transition: ExperienceScreenTransitionSpec(kind: .modal, presentation: .init(height: .medium))))
        let configurator = ExperienceShellPresentationConfigurator()
        configurator.configure(controller, shell: shell)
        let presentation = try XCTUnwrap(controller.presentationController)
        let delegate = try XCTUnwrap(presentation.delegate)
        let closed = expectation(description: "completed native swipe reports close")
        var closeCount = 0
        controller.onClose = { _ in closeCount += 1; closed.fulfill() }
        delegate.presentationControllerDidDismiss?(presentation)
        delegate.presentationControllerDidDismiss?(presentation)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(controller.completedDismissals, [true])
    }

    func testFirstLayerDelegateAsksTheExperienceBeforeASwipeAndWhenItStarts() throws {
        let controller = SwipeGateController()
        let screenID = try XCTUnwrap(controller.experience.behaviorPresentationScreens.keys.first)
        let shell = try XCTUnwrap(controller.experience.shellContract(screenId: screenID,
            transition: ExperienceScreenTransitionSpec(kind: .modal, presentation: .init(height: .medium))))
        let configurator = ExperienceShellPresentationConfigurator()
        configurator.configure(controller, shell: shell)
        let presentation = try XCTUnwrap(controller.presentationController)
        let delegate = try XCTUnwrap(presentation.delegate)
        controller.accepts = false
        XCTAssertEqual(delegate.presentationControllerShouldDismiss?(presentation), false,
            "The Experience's sheet springs back while a move runs")
        controller.accepts = true
        XCTAssertEqual(delegate.presentationControllerShouldDismiss?(presentation), true)
        XCTAssertEqual(controller.swipesBegun, 0, "The question takes nothing")
        delegate.presentationControllerWillDismiss?(presentation)
        XCTAssertEqual(controller.swipesBegun, 1)
    }

    func testFullscreenHasNoCustomDismissal() throws {
        let controller = UIViewController()
        let configurator = ExperienceLayerPresentationConfigurator(
            presentation: .init(kind: .fullscreen))
        configurator.configure(controller)
        XCTAssertEqual(controller.modalPresentationStyle, .fullScreen)
        XCTAssertNil(controller.transitioningDelegate)
    }

}

@MainActor
private final class SwipeGateController: MockExperienceViewController {
    var accepts = true
    var swipesBegun = 0
    override var acceptsInteractiveDismissal: Bool { accepts }
    override func interactiveDismissalWillBegin() { swipesBegun += 1 }
}

private final class CompletedSheetDismissalController: MockExperienceViewController {
    var completedDismissals: [Bool] = []
    override func prepareForDismissal(reason: CloseReason? = nil, alreadyDismissed: Bool = false) async {
        completedDismissals.append(alreadyDismissed)
    }
}
#endif
