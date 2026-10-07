import XCTest
@testable import Nuxie
#if canImport(UIKit)
import UIKit

@MainActor
final class ExperienceLayerPresentationTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/\(name).json"))
    }

    func testDialogGeometryMatchesSharedVector() throws {
        struct Vector: Decodable {
            struct Size: Decodable { let width: Double; let height: Double }
            struct Insets: Decodable { let top: Double; let bottom: Double }
            struct Frame: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
            struct Case: Decodable { let laidOutHeight: Double; let expectedFrame: Frame }
            let window: Size
            let safeArea: Insets
            let dialogCases: [Case]
        }
        let vector = try JSONDecoder().decode(Vector.self, from: fixture("presentation-geometry"))
        let bounds = CGRect(x: 0, y: 0, width: vector.window.width, height: vector.window.height)
        let safe = bounds.inset(by: UIEdgeInsets(top: vector.safeArea.top, left: 0,
                                               bottom: vector.safeArea.bottom, right: 0))
        for item in vector.dialogCases {
            XCTAssertEqual(ExperienceLayerPresentation.dialogFrame(in: bounds, safeArea: safe,
                laidOutHeight: item.laidOutHeight), CGRect(x: item.expectedFrame.x, y: item.expectedFrame.y,
                    width: item.expectedFrame.width, height: item.expectedFrame.height))
        }
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
            XCTAssertEqual(parsed.presentation.isAvailable, item["available"] as? Bool)
        }
        for transition in try XCTUnwrap(vector["invalid"] as? [[String: Any]]) {
            XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateJourneyTransition(transition, path: "transition"))
        }
    }

    func testNativeSheetDetentsAndCloseFlags() throws {
        let looks = try JSONDecoder().decode(ExperiencePresentationLooks.self, from: fixture("presentation-looks"))
        for height in [ExperienceLayerPresentation.Height.medium, .large] {
            for closedBy in [ExperienceLayerPresentation.ClosedBy.any, .none] {
                let controller = UIViewController()
                let configurator = ExperienceLayerPresentationConfigurator(
                    presentation: .init(height: height, closedBy: closedBy), looks: looks, onClose: {})
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

    func testFullscreenHasNoCustomDismissal() throws {
        let looks = try JSONDecoder().decode(ExperiencePresentationLooks.self, from: fixture("presentation-looks"))
        let controller = UIViewController()
        let configurator = ExperienceLayerPresentationConfigurator(
            presentation: .init(kind: .fullscreen), looks: looks, onClose: {})
        configurator.configure(controller)
        XCTAssertEqual(controller.modalPresentationStyle, .fullScreen)
        XCTAssertNil(controller.transitioningDelegate)
    }

    func testDialogCloseUsesOnlyAllowedBackdropGesture() throws {
        let looks = try JSONDecoder().decode(ExperiencePresentationLooks.self, from: fixture("presentation-looks"))
        for closedBy in [ExperienceLayerPresentation.ClosedBy.any, .none] {
            let controller = UIViewController()
            let configurator = ExperienceLayerPresentationConfigurator(
                presentation: .init(kind: .dialog, closedBy: closedBy), looks: looks, onClose: {})
            configurator.configure(controller)
            let presentation = try XCTUnwrap(configurator.presentationController(
                forPresented: controller, presenting: UIViewController(), source: UIViewController())
                as? ExperienceDialogPresentationController)
            XCTAssertEqual(controller.modalTransitionStyle, .crossDissolve)
            XCTAssertEqual(controller.isModalInPresentation, closedBy == .none)
            XCTAssertEqual(presentation.hasDimmingDismissalGesture, closedBy == .any)
            XCTAssertFalse(presentation.shouldRemovePresentersView)
        }
    }

    func testBundledLooksMatchSharedVector() throws {
        #if SWIFT_PACKAGE
        // Bundle.module belongs to the test target here; use the SDK loader.
        _ = ExperiencePresentationLooks.installed
        #endif
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(try fixture("presentation-looks"),
                       try Data(contentsOf: root.appendingPathComponent("Sources/Nuxie/Resources/presentation-looks.json")))
    }
}
#endif
