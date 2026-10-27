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
        let delegate = ExperienceAdaptivePresentationDismissalDelegate(
            acceptsDismissal: { [weak controller] in
                (controller as? ExperienceViewController)?.acceptsInteractiveDismissal ?? true
            },
            onDismissalWillBegin: { [weak controller] in
                (controller as? ExperienceViewController)?.interactiveDismissalWillBegin()
            },
            onInteractiveDismissal: { [weak controller] in
                (controller as? ExperienceViewController)?.performInteractiveDismissal()
            }
        )
        adaptiveDismissalDelegate = delegate
        delegate.bind(to: controller)
    }
}

@MainActor
final class ExperienceAdaptivePresentationDismissalDelegate: NSObject, UISheetPresentationControllerDelegate {
    private let acceptsDismissal: @MainActor () -> Bool
    private let onDismissalWillBegin: @MainActor () -> Void
    private let onInteractiveDismissal: @MainActor () -> Void

    /// The Experience's own sheet joins the move queue's gate and slot.
    init(acceptsDismissal: @escaping @MainActor () -> Bool = { true },
         onDismissalWillBegin: @escaping @MainActor () -> Void = {},
         onInteractiveDismissal: @escaping @MainActor () -> Void) {
        self.acceptsDismissal = acceptsDismissal
        self.onDismissalWillBegin = onDismissalWillBegin
        self.onInteractiveDismissal = onInteractiveDismissal
    }

    func bind(to controller: UIViewController) {
        controller.presentationController?.delegate = self
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        acceptsDismissal()
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        onDismissalWillBegin()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onInteractiveDismissal()
    }
}
#endif
