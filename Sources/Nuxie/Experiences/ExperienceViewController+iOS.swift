#if canImport(UIKit)
import NuxieRuntime
import UIKit

extension ExperienceViewController {
    func platformApplyDefaultBackgroundColor() {
        view.backgroundColor = .systemBackground
    }

    func platformApplyColorSchemeMode(_ mode: ExperienceColorSchemeMode) {
        overrideUserInterfaceStyle = mode.userInterfaceStyle
        view.backgroundColor = .systemBackground
        loadingView?.backgroundColor = .systemBackground
        errorView?.backgroundColor = .systemBackground
        applyShellPalette()
    }

    func platformSetupLoadingView() {
        loadingView = UIView()
        loadingView.backgroundColor = .systemBackground
        loadingView.isHidden = true
        loadingView.accessibilityIdentifier = "nuxie-experience-loading-shell"
        loadingView.accessibilityLabel = "Experience loading"
        loadingView.isAccessibilityElement = true
        view.addSubview(loadingView)

        loadingShimmerView = ExperienceShellShimmerView()
        loadingShimmerView.accessibilityIdentifier = "nuxie-experience-shimmer"
        loadingView.addSubview(loadingShimmerView)

        // Embedded hosts that never carry a signed presentation contract have
        // no authored background to shimmer, so they keep a plain indicator.
        activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.hidesWhenStopped = true
        loadingView.addSubview(activityIndicator)

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingShimmerView.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingShimmerView.topAnchor.constraint(equalTo: loadingView.topAnchor),
            loadingShimmerView.leadingAnchor.constraint(equalTo: loadingView.leadingAnchor),
            loadingShimmerView.trailingAnchor.constraint(equalTo: loadingView.trailingAnchor),
            loadingShimmerView.bottomAnchor.constraint(equalTo: loadingView.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor),
        ])
    }

    func platformSetupErrorView() {
        let recoveryView = ExperienceShellRecoveryView(
            onRetry: { [weak self] in self?.retryFromErrorView() }
        )
        recoveryView.backgroundColor = .systemBackground
        recoveryView.isHidden = true
        shellRecoveryView = recoveryView
        errorView = recoveryView
        refreshButton = recoveryView.primaryActionButton
        view.addSubview(recoveryView)

        // The close is an overlay on the controller's own view rather than a
        // child of the recovery surface, so it keeps one fixed position and
        // never affects the runtime surface's frame.
        let closeControl = ExperienceGlassControl(
            systemImageName: "xmark",
            accessibilityLabel: "Close"
        )
        closeControl.accessibilityIdentifier = "nuxie-experience-close"
        closeControl.isHidden = true
        closeControl.addAction(
            UIAction { [weak self] _ in self?.performDismiss(reason: .userDismissed) },
            for: .touchUpInside
        )
        shellCloseControl = closeControl
        view.addSubview(closeControl)

        recoveryView.translatesAutoresizingMaskIntoConstraints = false
        closeControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recoveryView.topAnchor.constraint(equalTo: view.topAnchor),
            recoveryView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            recoveryView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            recoveryView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeControl.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 12
            ),
            closeControl.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -16
            ),
        ])
    }

    func platformStartLoadingIndicator() {
        guard !suppressesLoadingTreatmentForPresentation else { return }
        guard presentationShellContract != nil else {
            // Embedded hosts carry no signed presentation, so there is no
            // authored background to shimmer over.
            activityIndicator.startAnimating()
            return
        }
        loadingShimmerView.configure(
            backgroundColor: loadingView.backgroundColor ?? .systemBackground,
            palette: shellPalette,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
    }

    func platformStopLoadingIndicator() {
        activityIndicator.stopAnimating()
        loadingShimmerView.stopAnimating()
    }

    func platformSetShellCloseControlVisible(_ visible: Bool) {
        shellCloseControl?.isHidden = !visible
        if visible, let shellCloseControl {
            view.bringSubviewToFront(shellCloseControl)
        }
    }

    func platformSetRecoveryRetrying(_ retrying: Bool) {
        shellRecoveryView?.isRetrying = retrying
    }

    func platformApplyRecoveryReason(_ reason: ExperienceShellRecoveryReason) {
        shellRecoveryView?.apply(reason: reason)
    }

    func platformApplyPresentationShell(_ contract: ExperienceShellContract?) {
        guard let contract else { return }
        // One authored color carries the whole presentation: the surface behind
        // the runtime, the field the shimmer sweeps, and the ground the
        // recovery state sits on.
        // Every surface carries the authored value unchanged, alpha included.
        //
        // A translucent ground is an unresolved corner: the shell surfaces sit
        // over the controller's own, so a background with alpha composites
        // twice while they are up, and painting them clear instead would stop
        // them hiding a runtime layer that can mount content after a timeout.
        // Preserving the signed value exactly is the behaviour that is right
        // for every descriptor the publisher emits. UNIV-2462 decides what a
        // translucent ground should mean here.
        let background = UIColor(nuxieRGBAHex: contract.presentation.backgroundColor)
            ?? .systemBackground
        view.backgroundColor = background
        loadingView.backgroundColor = background
        errorView.backgroundColor = background

        applyShellPalette()

        // A signed contract always shimmers; the embedded-host indicator has
        // no place here.
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true

        if suppressesLoadingTreatmentForPresentation {
            loadingShimmerView.stopAnimating()
            loadingShimmerView.isHidden = true
        } else {
            loadingShimmerView.configure(
                backgroundColor: background,
                palette: shellPalette,
                reduceMotion: UIAccessibility.isReduceMotionEnabled
            )
        }
    }

    /// Recomputes shell chrome colors from the authored background.
    ///
    /// The recovery surface is the case that used to fail: its labels resolved
    /// against `overrideUserInterfaceStyle` instead of the color a descriptor
    /// actually authored, so its dismissal control rendered near-black on a
    /// near-black background.
    func applyShellPalette() {
        let palette = ExperienceShellPalette(
            backgroundCandidates: [loadingView?.backgroundColor, view.backgroundColor]
        )
        shellPalette = palette
        shellRecoveryView?.apply(palette)
        shellCloseControl?.apply(palette)
    }

    func platformBringPresentationShellToFront() {
        if !loadingView.isHidden { view.bringSubviewToFront(loadingView) }
        if !errorView.isHidden { view.bringSubviewToFront(errorView) }
        if let shellCloseControl, !shellCloseControl.isHidden {
            view.bringSubviewToFront(shellCloseControl)
        }
    }

    func platformCancelPresentationRevealTransition() {
        presentationRevealGeneration &+= 1
        loadingView.layer.removeAllAnimations()
        errorView.layer.removeAllAnimations()
        loadingView.alpha = 1
        errorView.alpha = 1
        // The close fades with the rest of the shell, so a cancelled reveal has
        // to restore its opacity too.
        shellCloseControl?.layer.removeAllAnimations()
        shellCloseControl?.alpha = 1
    }

    /// Returns shell chrome to its pre-presentation state.
    ///
    /// The close is a sibling of the recovery surface rather than a child, so
    /// hiding `errorView` for a new presentation does not take it with it. A
    /// controller dismissed while recovery was visible would otherwise carry a
    /// live close over the next presentation's shimmer, where the contract says
    /// no chrome belongs.
    func platformResetShellChrome() {
        shellCloseControl?.layer.removeAllAnimations()
        shellCloseControl?.isHidden = true
        shellCloseControl?.alpha = 1
        shellRecoveryView?.isRetrying = false
    }

    func platformRevealPresentationContent() {
        presentationRevealGeneration &+= 1
        let generation = presentationRevealGeneration
        let overlays = [loadingView, errorView, shellCloseControl]
            .compactMap { $0 }
            .filter { !$0.isHidden }
        let duration = ExperienceShellRevealTransition.duration(
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
        guard duration > 0, !overlays.isEmpty else {
            overlays.forEach {
                $0.isHidden = true
                $0.alpha = 1
            }
            return
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: {
                overlays.forEach { $0.alpha = 0 }
            },
            completion: { [weak self] _ in
                guard self?.presentationRevealGeneration == generation else {
                    return
                }
                overlays.forEach {
                    $0.isHidden = true
                    $0.alpha = 1
                }
            }
        )
    }
}
#endif
