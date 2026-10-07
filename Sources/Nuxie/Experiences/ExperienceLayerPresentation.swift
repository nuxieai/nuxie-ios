import Foundation

/// Native geometry for one modal layer.
struct ExperienceLayerPresentation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case sheet, fullscreen }
    enum Height: String, Codable, Sendable { case large, medium; case fitContent = "fit-content" }
    enum ClosedBy: String, Codable, Sendable { case any, none }

    var kind: Kind = .sheet
    var height: Height = .large
    var closedBy: ClosedBy = .any
    var dismissible: Bool { closedBy == .any }
    var fitsContent: Bool { kind == .sheet && height == .fitContent }

    static let modalDefault = Self()

}

#if canImport(UIKit)
import UIKit

@MainActor
final class ExperienceLayerPresentationConfigurator {
    private let presentation: ExperienceLayerPresentation

    init(presentation: ExperienceLayerPresentation) {
        self.presentation = presentation
    }

    func configure(_ controller: UIViewController) {
        controller.isModalInPresentation = !presentation.dismissible
        switch presentation.kind {
        case .sheet:
            controller.modalPresentationStyle = .pageSheet
            if presentation.fitsContent {
                Self.updateContentHeight(controller, height: controller.preferredContentSize.height)
            } else {
                controller.sheetPresentationController?.detents = presentation.height == .medium
                    ? [.medium()] : [.large()]
            }
            controller.sheetPresentationController?.prefersGrabberVisible = presentation.dismissible
        case .fullscreen:
            controller.modalPresentationStyle = .fullScreen
        }
    }
    /// Ask UIKit for its page-sheet geometry before measuring the Rive root.
    /// The probe is transparent, inaccessible and never becomes the key window.
    /// Reproduce the presenting sheet stack so compact and regular-width scenes
    /// use the same native insets as the eventual presentation.
    static func availableSheetSize(in scene: UIWindowScene,
                                   above presenter: UIViewController?) async throws -> CGSize {
        let window = UIWindow(windowScene: scene)
        window.alpha = 0
        window.isUserInteractionEnabled = false
        window.accessibilityElementsHidden = true
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        root.view.layoutIfNeeded()
        var ancestors: [UIViewController] = []
        var current = presenter
        while let controller = current {
            if controller.presentingViewController != nil,
               controller.modalPresentationStyle == .pageSheet { ancestors.append(controller) }
            current = controller.presentingViewController ?? controller.parent
        }
        var probePresenter = root
        for source in ancestors.reversed() {
            let probe = UIViewController()
            probe.modalPresentationStyle = .pageSheet
            probe.preferredContentSize = source.preferredContentSize
            probe.sheetPresentationController?.detents = source.sheetPresentationController?.detents ?? [.large()]
            await withCheckedContinuation { continuation in
                probePresenter.present(probe, animated: false) { continuation.resume() }
            }
            probePresenter = probe
        }
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.large()]
        await withCheckedContinuation { continuation in
            probePresenter.present(sheet, animated: false) { continuation.resume() }
        }
        sheet.view.layoutIfNeeded()
        let size = sheet.view.bounds.size
        await withCheckedContinuation { continuation in
            root.dismiss(animated: false) { continuation.resume() }
        }
        guard !Task.isCancelled, size.width > 0, size.height > 0 else { throw CancellationError() }
        return size
    }

    static func contentHeight(_ measured: CGFloat, maximum: CGFloat) -> CGFloat {
        guard measured.isFinite, measured > 0 else { return maximum }
        return min(measured, maximum)
    }

    static func usesMediumDetent(contentHeight: CGFloat, availableHeight: CGFloat) -> Bool {
        contentHeight.isFinite && contentHeight > 0 && contentHeight <= availableHeight / 2
    }

    static func updateContentHeight(_ controller: UIViewController, height: CGFloat) {
        controller.preferredContentSize = CGSize(width: controller.preferredContentSize.width, height: height)
        guard let sheet = controller.sheetPresentationController else { return }
        if #available(iOS 16.0, *) {
            if height > 0, height.isFinite {
                sheet.detents = [.custom(identifier: .init("nuxie.content")) { context in
                    contentHeight(height, maximum: context.maximumDetentValue)
                }]
                sheet.invalidateDetents()
            } else { sheet.detents = [.large()] }
        } else {
            let available = controller.view.window?.bounds.height
                ?? controller.presentingViewController?.view.bounds.height ?? controller.view.bounds.height
            sheet.detents = usesMediumDetent(contentHeight: height, availableHeight: available)
                ? [.medium()] : [.large()]
        }
    }

}
#endif
