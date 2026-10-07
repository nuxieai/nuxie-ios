import Foundation
import CoreGraphics

/// Native geometry for one modal layer. Content-height sheets await the root Hug seam.
struct ExperienceLayerPresentation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case sheet, fullscreen, dialog }
    enum Height: String, Codable, Sendable { case large, medium; case fitContent = "fit-content" }
    enum ClosedBy: String, Codable, Sendable { case any, none }

    var kind: Kind = .sheet
    var height: Height = .large
    var closedBy: ClosedBy = .any
    var dismissible: Bool { closedBy == .any }
    var isAvailable: Bool { kind != .sheet || height != .fitContent }

    static let modalDefault = Self()

    static func dialogFrame(in bounds: CGRect, safeArea: CGRect, laidOutHeight: CGFloat) -> CGRect {
        let height = min(max(0, laidOutHeight), safeArea.height)
        // Q1 specifies 16 points on each side of the window.
        return CGRect(x: bounds.minX + 16, y: safeArea.midY - height / 2,
                      width: max(0, bounds.width - 32), height: height)
    }
}

struct ExperiencePresentationLooks: Decodable, Sendable {
    struct IOS: Decodable, Sendable {
        struct Shadow: Decodable, Sendable {
            let color: String
            let opacity: Float
            let radius: Double
            let offsetX: Double
            let offsetY: Double
        }
        let background: String
        let cornerRadius: Double?
        let shadow: Shadow?
        let dimming: String?
    }
    let ios: IOS

    static let installed: Self = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ResourceToken.self)
        #endif
        guard let url = bundle.url(forResource: "presentation-looks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let looks = try? JSONDecoder().decode(Self.self, from: data) else {
            preconditionFailure("Missing presentation looks resource")
        }
        return looks
    }()

    private final class ResourceToken {}
}

#if canImport(UIKit)
import UIKit

@MainActor
final class ExperienceLayerPresentationConfigurator: NSObject, UIViewControllerTransitioningDelegate {
    private let presentation: ExperienceLayerPresentation
    private let looks: ExperiencePresentationLooks
    private let onClose: @MainActor () -> Void

    init(presentation: ExperienceLayerPresentation,
         looks: ExperiencePresentationLooks = .installed,
         onClose: @escaping @MainActor () -> Void) {
        self.presentation = presentation
        self.looks = looks
        self.onClose = onClose
    }

    func configure(_ controller: UIViewController) {
        precondition(presentation.isAvailable, "Content-height sheets await the runtime root Hug seam")
        controller.isModalInPresentation = !presentation.dismissible
        switch presentation.kind {
        case .sheet:
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = presentation.height == .medium
                ? [.medium()] : [.large()]
            controller.sheetPresentationController?.prefersGrabberVisible = presentation.dismissible
        case .fullscreen:
            controller.modalPresentationStyle = .fullScreen
        case .dialog:
            controller.modalPresentationStyle = .custom
            controller.modalTransitionStyle = .crossDissolve
            controller.transitioningDelegate = self
        }
    }

    func presentationController(forPresented presented: UIViewController,
                                presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        ExperienceDialogPresentationController(presentedViewController: presented,
            presenting: presenting, dismissible: presentation.dismissible, looks: looks, onClose: onClose)
    }
}

@MainActor
final class ExperienceDialogPresentationController: UIPresentationController {
    private let backdrop = UIView()
    private let looks: ExperiencePresentationLooks
    private let onClose: @MainActor () -> Void
    private(set) var hasDimmingDismissalGesture = false
    private var closing = false

    init(presentedViewController: UIViewController, presenting: UIViewController?,
         dismissible: Bool, looks: ExperiencePresentationLooks, onClose: @escaping @MainActor () -> Void) {
        self.looks = looks
        self.onClose = onClose
        super.init(presentedViewController: presentedViewController, presenting: presenting)
        // UIKit supplies no scrim for a custom presentation. A nil vector value
        // leaves the plain clear backdrop until the dialog look is decided.
        backdrop.backgroundColor = looks.ios.dimming.flatMap(UIColor.init(nuxieRGBAHex:))
        if dismissible {
            backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeFromBackdrop)))
            hasDimmingDismissalGesture = true
        }
    }

    @objc func closeFromBackdrop() {
        guard hasDimmingDismissalGesture, !closing, !presentedViewController.isModalInPresentation else { return }
        closing = true
        presentedViewController.dismiss(animated: true) { [onClose] in onClose() }
    }

    override var shouldRemovePresentersView: Bool { false }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        return ExperienceLayerPresentation.dialogFrame(in: containerView.bounds,
            safeArea: containerView.bounds.inset(by: containerView.safeAreaInsets),
            laidOutHeight: presentedViewController.preferredContentSize.height)
    }

    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        backdrop.frame = containerView.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        containerView.insertSubview(backdrop, at: 0)
        if let transition = presentedViewController.transitionCoordinator {
            backdrop.alpha = 0
            transition.animate { _ in self.backdrop.alpha = 1 }
        }
        presentedView?.backgroundColor = looks.ios.background == "systemBackground"
            ? .systemBackground : UIColor(nuxieRGBAHex: looks.ios.background)
        if let radius = looks.ios.cornerRadius { presentedView?.layer.cornerRadius = CGFloat(radius) }
        if let shadow = looks.ios.shadow {
            presentedView?.layer.shadowColor = UIColor(nuxieRGBAHex: shadow.color)?.cgColor
            presentedView?.layer.shadowOpacity = shadow.opacity
            presentedView?.layer.shadowRadius = CGFloat(shadow.radius)
            presentedView?.layer.shadowOffset = CGSize(width: shadow.offsetX, height: shadow.offsetY)
        }
    }

    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate { _ in self.backdrop.alpha = 0 }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        containerView?.setNeedsLayout()
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { backdrop.removeFromSuperview() }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed {
            backdrop.removeFromSuperview()
        } else {
            closing = false
            backdrop.alpha = 1
        }
    }
}
#endif
