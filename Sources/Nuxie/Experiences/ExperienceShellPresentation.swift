#if canImport(UIKit)
import UIKit

/// Owns the weak UIKit delegates for the first native layer.
@MainActor
final class ExperienceShellPresentationConfigurator {
    private var adaptiveDismissalDelegate: ExperienceAdaptivePresentationDismissalDelegate?

    func configure(_ controller: UIViewController, shell: ExperienceShellContract?) {
        let presentation = shell?.layer ?? .init(kind: .fullscreen)
        let configurator = ExperienceLayerPresentationConfigurator(presentation: presentation)
        configurator.configure(controller)
        let delegate = ExperienceAdaptivePresentationDismissalDelegate { [weak controller] in
            (controller as? ExperienceViewController)?.performInteractiveDismissal()
        }
        adaptiveDismissalDelegate = delegate
        delegate.bind(to: controller)
    }
}

@MainActor
final class ExperienceAdaptivePresentationDismissalDelegate: NSObject, UISheetPresentationControllerDelegate {
    private let onInteractiveDismissal: @MainActor () -> Void

    init(onInteractiveDismissal: @escaping @MainActor () -> Void) {
        self.onInteractiveDismissal = onInteractiveDismissal
    }

    func bind(to controller: UIViewController) {
        controller.presentationController?.delegate = self
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onInteractiveDismissal()
    }
}
#endif
