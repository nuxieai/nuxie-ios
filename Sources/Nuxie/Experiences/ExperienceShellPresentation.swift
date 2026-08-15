import CoreGraphics
import Foundation

struct ExperienceShellPresentationPlan: Equatable, Sendable {
    let style: ExperienceBehaviorPresentationStyle
    let preferredContentSize: CGSize
    let dismissible: Bool
    let sheetDetent: ExperienceBehaviorPresentation.Sheet.Detent?
    let drawerLayout: ExperienceShellLayout?

    init(contract: ExperienceShellContract) {
        style = contract.presentation.style
        preferredContentSize = CGSize(
            width: contract.screen.width,
            height: contract.screen.height
        )
        switch contract.presentation.style {
        case .fullScreen:
            dismissible = false
            sheetDetent = nil
            drawerLayout = nil
        case .sheet:
            dismissible = contract.presentation.sheet?.dismissible ?? true
            sheetDetent = contract.presentation.sheet?.detent
            drawerLayout = nil
        case .drawer:
            dismissible = contract.presentation.drawer?.dismissible ?? true
            sheetDetent = nil
            drawerLayout = contract.presentation.drawer.map(ExperienceShellLayout.init)
        }
    }
}

enum ExperienceShellLayoutDirection: Equatable, Sendable {
    case leftToRight
    case rightToLeft
}

struct ExperienceShellLayout: Equatable, Sendable {
    let drawer: ExperienceBehaviorPresentation.Drawer

    var cornerRadius: CGFloat { CGFloat(drawer.cornerRadius) }

    func frame(
        in bounds: CGRect,
        layoutDirection: ExperienceShellLayoutDirection = .leftToRight
    ) -> CGRect {
        let ratio = CGFloat(drawer.extentRatio)
        switch resolvedEdge(for: layoutDirection) {
        case .bottom:
            let height = bounds.height * ratio
            return CGRect(
                x: bounds.minX,
                y: bounds.maxY - height,
                width: bounds.width,
                height: height
            )
        case .top:
            return CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height * ratio
            )
        case .leading:
            return CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width * ratio,
                height: bounds.height
            )
        case .trailing:
            let width = bounds.width * ratio
            return CGRect(
                x: bounds.maxX - width,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
        }
    }

    func offscreenFrame(
        from frame: CGRect,
        in bounds: CGRect,
        layoutDirection: ExperienceShellLayoutDirection
    ) -> CGRect {
        switch resolvedEdge(for: layoutDirection) {
        case .bottom: frame.offsetBy(dx: 0, dy: bounds.height)
        case .top: frame.offsetBy(dx: 0, dy: -bounds.height)
        case .leading: frame.offsetBy(dx: -bounds.width, dy: 0)
        case .trailing: frame.offsetBy(dx: bounds.width, dy: 0)
        }
    }

    private func resolvedEdge(
        for layoutDirection: ExperienceShellLayoutDirection
    ) -> ExperienceBehaviorPresentation.Drawer.Edge {
        guard layoutDirection == .rightToLeft else { return drawer.edge }
        switch drawer.edge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top, .bottom: return drawer.edge
        }
    }
}

#if canImport(UIKit)
import UIKit

private extension ExperienceShellLayoutDirection {
    init(_ direction: UIUserInterfaceLayoutDirection) {
        self = direction == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

@MainActor
final class ExperienceAdaptivePresentationDismissalDelegate: NSObject,
    UISheetPresentationControllerDelegate
{
    private let onInteractiveDismissal: @MainActor () -> Void

    init(onInteractiveDismissal: @escaping @MainActor () -> Void) {
        self.onInteractiveDismissal = onInteractiveDismissal
    }

    func bind(to viewController: UIViewController) {
        if let sheet = viewController.sheetPresentationController {
            sheet.delegate = self
        } else {
            viewController.presentationController?.delegate = self
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onInteractiveDismissal()
    }
}

@MainActor
final class ExperienceDrawerTransitioningDelegate: NSObject,
    UIViewControllerTransitioningDelegate
{
    private let layout: ExperienceShellLayout
    private let dismissible: Bool
    private let onInteractiveDismissal: @MainActor () -> Void

    init(
        layout: ExperienceShellLayout,
        dismissible: Bool,
        onInteractiveDismissal: @escaping @MainActor () -> Void
    ) {
        self.layout = layout
        self.dismissible = dismissible
        self.onInteractiveDismissal = onInteractiveDismissal
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        ExperienceDrawerPresentationController(
            presentedViewController: presented,
            presenting: presenting,
            layout: layout,
            dismissible: dismissible,
            onInteractiveDismissal: onInteractiveDismissal
        )
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        ExperienceDrawerAnimator(layout: layout, presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController)
        -> UIViewControllerAnimatedTransitioning?
    {
        ExperienceDrawerAnimator(layout: layout, presenting: false)
    }
}

@MainActor
final class ExperienceDrawerPresentationController: UIPresentationController {
    private let layout: ExperienceShellLayout
    private let dimmingView = UIView()
    private let onInteractiveDismissal: @MainActor () -> Void
    private(set) var hasDimmingDismissalGesture = false

    init(
        presentedViewController: UIViewController,
        presenting presentingViewController: UIViewController?,
        layout: ExperienceShellLayout,
        dismissible: Bool,
        onInteractiveDismissal: @escaping @MainActor () -> Void
    ) {
        self.layout = layout
        self.onInteractiveDismissal = onInteractiveDismissal
        super.init(
            presentedViewController: presentedViewController,
            presenting: presentingViewController
        )
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        dimmingView.alpha = 0
        if dismissible {
            dimmingView.addGestureRecognizer(UITapGestureRecognizer(
                target: self,
                action: #selector(dismissFromDimmingView)
            ))
            hasDimmingDismissalGesture = true
        }
    }

    @objc private func dismissFromDimmingView() {
        presentedViewController.dismiss(animated: true) { [onInteractiveDismissal] in
            onInteractiveDismissal()
        }
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        return layout.frame(
            in: containerView.bounds,
            layoutDirection: ExperienceShellLayoutDirection(
                containerView.effectiveUserInterfaceLayoutDirection
            )
        )
    }

    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        dimmingView.frame = containerView.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        containerView.insertSubview(dimmingView, at: 0)
        presentedViewController.transitionCoordinator?.animate { _ in
            self.dimmingView.alpha = 1
        }
    }

    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate { _ in
            self.dimmingView.alpha = 0
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
        presentedView?.layer.cornerRadius = layout.cornerRadius
        presentedView?.layer.masksToBounds = true
    }
}

@MainActor
private final class ExperienceDrawerAnimator: NSObject,
    UIViewControllerAnimatedTransitioning
{
    private let layout: ExperienceShellLayout
    private let presenting: Bool

    init(layout: ExperienceShellLayout, presenting: Bool) {
        self.layout = layout
        self.presenting = presenting
    }

    func transitionDuration(
        using transitionContext: UIViewControllerContextTransitioning?
    ) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0 : 0.24
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key) else {
            transitionContext.completeTransition(false)
            return
        }
        let container = transitionContext.containerView
        let layoutDirection = ExperienceShellLayoutDirection(
            container.effectiveUserInterfaceLayoutDirection
        )
        let finalFrame = layout.frame(
            in: container.bounds,
            layoutDirection: layoutDirection
        )
        if presenting { container.addSubview(controller.view) }
        let hiddenFrame = layout.offscreenFrame(
            from: finalFrame,
            in: container.bounds,
            layoutDirection: layoutDirection
        )
        controller.view.frame = presenting ? hiddenFrame : finalFrame
        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            animations: {
                controller.view.frame = self.presenting ? finalFrame : hiddenFrame
            },
            completion: { finished in
                transitionContext.completeTransition(
                    finished && !transitionContext.transitionWasCancelled
                )
            }
        )
    }

}
#endif
