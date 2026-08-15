import CoreGraphics
import XCTest
@testable import Nuxie
#if canImport(UIKit)
import UIKit
#endif

final class ExperienceShellLayoutTests: XCTestCase {
    func testModalPlanPreservesSignedStyleDimensionsAndDismissalContract() {
        let sheetContract = ExperienceShellContract(
            presentation: .init(
                style: .sheet,
                orientation: .portrait,
                backgroundColor: "#102030FF",
                loading: .init(style: .solid, backgroundColor: "#405060FF"),
                sheet: .init(detent: .medium, dismissible: false),
                drawer: nil
            ),
            screen: .init(width: 390, height: 640)
        )
        let sheet = ExperienceShellPresentationPlan(contract: sheetContract)
        XCTAssertEqual(sheet.style, .sheet)
        XCTAssertEqual(sheet.preferredContentSize, CGSize(width: 390, height: 640))
        XCTAssertEqual(sheet.sheetDetent, .medium)
        XCTAssertFalse(sheet.dismissible)
        XCTAssertNil(sheet.drawerLayout)

        let drawerContract = ExperienceShellContract(
            presentation: .init(
                style: .drawer,
                orientation: .landscape,
                backgroundColor: "#102030FF",
                loading: .init(style: .shimmer, backgroundColor: "#405060FF"),
                sheet: nil,
                drawer: .init(
                    edge: .trailing,
                    extentRatio: 0.4,
                    cornerRadius: 18,
                    dismissible: true
                )
            ),
            screen: .init(width: 844, height: 390)
        )
        let drawer = ExperienceShellPresentationPlan(contract: drawerContract)
        XCTAssertEqual(drawer.style, .drawer)
        XCTAssertEqual(drawer.preferredContentSize, CGSize(width: 844, height: 390))
        XCTAssertTrue(drawer.dismissible)
        XCTAssertEqual(drawer.drawerLayout?.cornerRadius, 18)
        XCTAssertNil(drawer.sheetDetent)
    }

    func testDrawerPlacementUsesSignedEdgeExtentAndCornerRadius() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let cases: [(ExperienceBehaviorPresentation.Drawer.Edge, CGRect)] = [
            (.bottom, CGRect(x: 0, y: 400, width: 400, height: 400)),
            (.top, CGRect(x: 0, y: 0, width: 400, height: 400)),
            (.leading, CGRect(x: 0, y: 0, width: 200, height: 800)),
            (.trailing, CGRect(x: 200, y: 0, width: 200, height: 800)),
        ]

        for (edge, expected) in cases {
            let layout = ExperienceShellLayout(drawer: .init(
                edge: edge,
                extentRatio: 0.5,
                cornerRadius: 24,
                dismissible: true
            ))
            XCTAssertEqual(layout.frame(in: bounds), expected)
            XCTAssertEqual(layout.cornerRadius, 24)
        }
    }

    func testDrawerLogicalEdgesMirrorInRightToLeftLayout() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let leading = ExperienceShellLayout(drawer: .init(
            edge: .leading,
            extentRatio: 0.5,
            cornerRadius: 24,
            dismissible: true
        ))
        let trailing = ExperienceShellLayout(drawer: .init(
            edge: .trailing,
            extentRatio: 0.5,
            cornerRadius: 24,
            dismissible: true
        ))

        XCTAssertEqual(
            leading.frame(in: bounds, layoutDirection: .rightToLeft),
            CGRect(x: 200, y: 0, width: 200, height: 800)
        )
        XCTAssertEqual(
            trailing.frame(in: bounds, layoutDirection: .rightToLeft),
            CGRect(x: 0, y: 0, width: 200, height: 800)
        )
        XCTAssertEqual(
            leading.offscreenFrame(
                from: CGRect(x: 200, y: 0, width: 200, height: 800),
                in: bounds,
                layoutDirection: .rightToLeft
            ),
            CGRect(x: 600, y: 0, width: 200, height: 800)
        )
        XCTAssertEqual(
            trailing.offscreenFrame(
                from: CGRect(x: 0, y: 0, width: 200, height: 800),
                in: bounds,
                layoutDirection: .rightToLeft
            ),
            CGRect(x: -400, y: 0, width: 200, height: 800)
        )
    }

    #if canImport(UIKit)
    @MainActor
    func testAdaptiveDismissalDelegateForwardsSystemDismissal() {
        var dismissalCount = 0
        let delegate = ExperienceAdaptivePresentationDismissalDelegate {
            dismissalCount += 1
        }
        let presented = UIViewController()
        let presenting = UIViewController()
        let controller = UIPresentationController(
            presentedViewController: presented,
            presenting: presenting
        )

        delegate.presentationControllerDidDismiss(controller)

        XCTAssertEqual(dismissalCount, 1)
    }

    @MainActor
    func testAdaptiveDismissalDelegateBindsBeforeSheetPresentation() throws {
        let delegate = ExperienceAdaptivePresentationDismissalDelegate {}
        let presented = UIViewController()
        presented.modalPresentationStyle = .pageSheet

        delegate.bind(to: presented)

        XCTAssertTrue(presented.sheetPresentationController?.delegate === delegate)
    }

    @MainActor
    func testOnlyDismissibleDrawerInstallsDimmingTapDismissal() throws {
        let presented = UIViewController()
        let presenting = UIViewController()
        let source = UIViewController()

        let dismissibleDelegate = ExperienceDrawerTransitioningDelegate(
            layout: drawerLayout(dismissible: true),
            dismissible: true,
            onInteractiveDismissal: {}
        )
        let dismissible = try XCTUnwrap(
            dismissibleDelegate.presentationController(
                forPresented: presented,
                presenting: presenting,
                source: source
            ) as? ExperienceDrawerPresentationController
        )
        XCTAssertTrue(dismissible.hasDimmingDismissalGesture)

        let fixedDelegate = ExperienceDrawerTransitioningDelegate(
            layout: drawerLayout(dismissible: false),
            dismissible: false,
            onInteractiveDismissal: {}
        )
        let fixed = try XCTUnwrap(
            fixedDelegate.presentationController(
                forPresented: presented,
                presenting: presenting,
                source: source
            ) as? ExperienceDrawerPresentationController
        )
        XCTAssertFalse(fixed.hasDimmingDismissalGesture)
    }

    private func drawerLayout(dismissible: Bool) -> ExperienceShellLayout {
        ExperienceShellLayout(drawer: .init(
            edge: .bottom,
            extentRatio: 0.5,
            cornerRadius: 24,
            dismissible: dismissible
        ))
    }
    #endif
}
