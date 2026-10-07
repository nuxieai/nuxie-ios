import XCTest
@testable import Nuxie
@testable import NuxieRuntime
@testable import NuxieTestSupport
#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit

@MainActor
final class ExperienceFitContentPresentationTests: XCTestCase {
    func testNativeMeasurementMatchesActualSheetAndDoesNotTakeKeyWindow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.activeWindowScene)
        let keyWindow = scene.windows.first(where: \.isKeyWindow)
        let measured = try await ExperienceLayerPresentationConfigurator.availableSheetSize(in: scene, above: nil)
        XCTAssertTrue(scene.windows.first(where: \.isKeyWindow) === keyWindow)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let sheet = UIViewController()
        ExperienceLayerPresentationConfigurator(presentation: .init(height: .large)).configure(sheet)
        await withCheckedContinuation { continuation in
            root.present(sheet, animated: false) { continuation.resume() }
        }
        XCTAssertEqual(measured.width, sheet.view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(measured.height, sheet.view.bounds.height, accuracy: 0.5)
        // Independent row arithmetic makes measuring at window width observable.
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try await NuxieNativeRuntime.open(bytes: Data(contentsOf: directory.appendingPathComponent(
            "fixtures/runtime/fit-content/wrapping-children.riv")), artboardName: "Sheet",
            player: .defaultScene, pixelWidth: UInt32(measured.width), pixelHeight: UInt32(measured.height),
            bindDefaultViewModel: true)
        _ = try await ExperiencePresentationHeight().apply(to: runtime, fitContent: true,
            width: Float(measured.width), height: Float(measured.height))
        _ = try await runtime.step(elapsedSeconds: 0)
        let laidOut = try await runtime.layoutSize()
        let columns = max(1, floor(sheet.view.bounds.width / 140))
        XCTAssertEqual(laidOut.height, 32 + ceil(6 / columns) * 120)
        try await runtime.close()
        let stacked = try await ExperienceLayerPresentationConfigurator.availableSheetSize(in: scene, above: sheet)
        let second = UIViewController()
        ExperienceLayerPresentationConfigurator(presentation: .init(height: .large)).configure(second)
        await withCheckedContinuation { continuation in
            sheet.present(second, animated: false) { continuation.resume() }
        }
        XCTAssertEqual(stacked.width, second.view.bounds.width, accuracy: 0.5)
        XCTAssertEqual(stacked.height, second.view.bounds.height, accuracy: 0.5)
        await withCheckedContinuation { continuation in
            root.dismiss(animated: false) { continuation.resume() }
        }
    }

    func testDismissalWhileInitialMeasurementWaitsDoesNotPresentLater() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.activeWindowScene)
        let controller = MockExperienceViewController()
        let screenID = try XCTUnwrap(controller.experience.behaviorPresentationScreens.keys.first)
        let shell = try XCTUnwrap(controller.experience.shellContract(screenId: screenID,
            transition: ExperienceScreenTransitionSpec(kind: .modal, presentation: .init(height: .fitContent))))
        controller.configurePresentationShell(shell, suppressLoadingTreatment: false)
        let window = IOSPresentationWindow(scene: scene)
        let task = Task { await window.present(controller, shell: shell) }
        await Task.yield()
        await window.dismiss()
        controller.resolveInitialContentHeight(ready: false)
        controller.resolveInitialContentHeight()
        await task.value
        XCTAssertFalse(window.isPresenting)
        window.destroy()
        await controller.shutdownRuntime()
    }

}
#endif
