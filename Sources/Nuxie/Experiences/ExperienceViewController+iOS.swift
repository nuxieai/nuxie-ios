#if canImport(UIKit)
import UIKit
import simd

/// The loading treatment for a signed `shimmer` presentation: a soft band of
/// light that travels across the authored background.
///
/// It is the only loading affordance the shell draws. A spinner and status
/// copy on top of it said the same thing twice and turned a calm surface into
/// app chrome that did not belong to the Experience.
///
/// The effect geometry is ported from Mercari's ShimmerView (MIT licensed, see
/// THIRD_PARTY_NOTICES.md), which solves the parts that are easy to get subtly
/// wrong:
///
/// - The gradient layer is squared off and centered, so its unit coordinate
///   space is isotropic and `effectAngle` is a real angle rather than one the
///   view's aspect ratio distorts.
/// - The band travels by animating `startPoint`/`endPoint`, which accept values
///   outside the unit square. `locations` is clamped to 0...1, so sweeping
///   stops instead collapses them onto an edge for much of the cycle.
/// - Travel is derived from the effect radius, the projection of the view onto
///   the effect axis, so the band clears the surface completely at both ends
///   for any angle instead of relying on tuned constants.
/// - Stops are interpolated with smoothstep across many steps, which removes
///   the banding a three-stop linear gradient shows at the band's edges.
final class ExperienceShellShimmerView: UIView {
    private static let animationKey = "nuxie.experience.shell.shimmer"

    /// One traversal, then a pause before the next. A full repetition is
    /// `sweepDuration + sweepInterval`.
    ///
    /// ShimmerView's defaults suit small skeleton elements in a list, where
    /// many shimmer together and a gap between traversals reads as rhythm.
    /// This surface is a single full-screen field, so a long gap just looks
    /// like the animation stopped. The pause is kept short enough to break the
    /// repetition without leaving the screen dead.
    private static let sweepDuration: CFTimeInterval = 1.2
    private static let sweepInterval: CFTimeInterval = 0.15

    /// Width of the band as a fraction of the surface's diagonal. Wider than a
    /// skeleton element's band, because here the band has a whole screen to
    /// cross and a narrow one spends most of the traversal off-surface.
    private static let effectSpanRatio: CGFloat = 0.45

    /// Tilt of the band. The squared-off gradient layer makes this a true
    /// angle, so every presentation mode shows the same sweep.
    private static let effectAngle: CGFloat = 20 * .pi / 180

    /// Stops per color segment for the smoothstep ramp.
    private static let interpolationSteps = 30

    private let gradientLayer = CAGradientLayer()

    /// Whether the sweep should be running. The attached animation can be
    /// dropped by the system (backgrounding removes animations); this stays the
    /// intent, and `restoreAnimationIfNeeded` reconciles reality to it.
    private(set) var isAnimating = false

    private var configuredBackgroundColor: UIColor?
    private var configuredPalette = ExperienceShellPalette(prefersLightContent: true)
    private var highlightColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // The gradient layer is larger than the view, so the surface has to
        // clip it.
        layer.masksToBounds = true
        layer.addSublayer(gradientLayer)
        squareGradientLayer()
        isHidden = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restoreAnimationIfNeeded),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configure(
        backgroundColor: UIColor,
        palette: ExperienceShellPalette,
        reduceMotion: Bool
    ) {
        configuredBackgroundColor = backgroundColor
        configuredPalette = palette
        // An overlay, not a repaint. Blending the authored colour into the
        // stops painted it a second time over the ground already beneath, so a
        // translucent background darkened wherever the shimmer sat.
        //
        // The direction comes from the palette so a light authored background
        // darkens rather than brightening into invisibility.
        let highlight = palette.shimmerHighlight
        highlightColor = highlight.color.withAlphaComponent(highlight.fraction)
        isHidden = false
        // Reduce Motion keeps the authored background flat rather than
        // substituting a different affordance.
        reduceMotion ? stopAnimating() : startAnimating()
    }

    @objc private func reduceMotionStatusDidChange() {
        guard let configuredBackgroundColor, !isHidden else { return }
        configure(
            backgroundColor: configuredBackgroundColor,
            palette: configuredPalette,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        squareGradientLayer()
        // Travel is derived from the surface's own geometry, so new bounds mean
        // a new sweep.
        if isAnimating { attachSweep() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restoreAnimationIfNeeded()
    }

    func startAnimating() {
        isAnimating = true
        restoreAnimationIfNeeded()
    }

    func stopAnimating() {
        isAnimating = false
        gradientLayer.removeAnimation(forKey: Self.animationKey)
        // Clearing the stops leaves the authored background untouched, which is
        // what a stopped shimmer should look like.
        gradientLayer.colors = nil
    }

    /// Attaches the sweep if it should be running and is not.
    ///
    /// Core Animation drops animations when the app backgrounds, so without
    /// this a presentation that is still acquiring comes back to a dead
    /// surface.
    @objc private func restoreAnimationIfNeeded() {
        guard isAnimating,
              window != nil,
              gradientLayer.animation(forKey: Self.animationKey) == nil else {
            return
        }
        attachSweep()
    }

    private func attachSweep() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        gradientLayer.removeAnimation(forKey: Self.animationKey)
        gradientLayer.colors = interpolatedStops
        gradientLayer.add(sweepAnimation, forKey: Self.animationKey)
    }

    /// Squares the gradient layer around the view's center.
    ///
    /// A gradient's start and end points are expressed in unit coordinates of
    /// its own bounds, so on a non-square layer a given unit vector is skewed
    /// by the aspect ratio. Squaring the layer makes an angle mean the same
    /// thing on a full screen and on a short drawer.
    private func squareGradientLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let side = max(bounds.width, bounds.height)
        gradientLayer.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    // MARK: - Effect geometry

    private var effectDiameter: CGFloat {
        sqrt(bounds.width * bounds.width + bounds.height * bounds.height)
    }

    private var effectWidth: CGFloat {
        effectDiameter * Self.effectSpanRatio
    }

    /// Distance from the surface's center to the point where the effect axis
    /// leaves the surface.
    ///
    /// Travelling the band by `effectRadius + effectWidth` in each direction
    /// therefore clears the surface completely at both ends, whatever the
    /// angle.
    private var effectRadius: CGFloat {
        guard bounds.width > 0 else { return 0 }
        let baseAngle = atan(bounds.height / bounds.width)
        var angle = Self.effectAngle.truncatingRemainder(dividingBy: .pi)
        while angle < 0 { angle += .pi * 2 }
        angle = angle.truncatingRemainder(dividingBy: .pi)
        let radius = effectDiameter / 2
        return angle < .pi * 0.5
            ? abs(cos(baseAngle - angle)) * radius
            : abs(cos(baseAngle - angle + .pi * 0.5)) * radius
    }

    private func axisVector(distance: CGFloat, forward: Bool) -> CGVector {
        let sign: CGFloat = forward ? 1 : -1
        return CGVector(
            dx: sign * distance * cos(Self.effectAngle),
            dy: sign * distance * sin(Self.effectAngle)
        )
    }

    /// Converts an offset from the surface's center into the gradient layer's
    /// unit space. The layer is square, so both axes divide by its width.
    private func unitPoint(for vector: CGVector) -> CGPoint {
        let frame = gradientLayer.frame
        guard frame.width > 0 else { return .zero }
        let point = CGPoint(x: bounds.midX + vector.dx, y: bounds.midY + vector.dy)
        return CGPoint(
            x: (point.x - frame.origin.x) / frame.width,
            y: (point.y - frame.origin.y) / frame.width
        )
    }

    // MARK: - Stops

    /// Base -> highlight -> base, ramped with smoothstep.
    ///
    /// Three linear stops leave visible edges where the band meets the
    /// background; smoothstepping across many stops makes the falloff read as
    /// light rather than as a shape.
    private var interpolatedStops: [CGColor] {
        guard let highlight = highlightColor else { return [] }
        // Ramps from fully transparent to the highlight and back, so the band
        // rides over the authored ground instead of restating it.
        let base = highlight.withAlphaComponent(0)
        let segments = [base, highlight, base]
        var stops: [CGColor] = []
        let step = 1 / Float(Self.interpolationSteps)
        for index in 0..<(segments.count - 1) {
            for offset in stride(from: Float(0), to: Float(1), by: step) {
                let eased = CGFloat(simd_smoothstep(0, 1, offset))
                stops.append(
                    segments[index]
                        .nuxieBlended(with: segments[index + 1], fraction: eased)
                        .cgColor
                )
            }
        }
        stops.append(segments[segments.count - 1].cgColor)
        return stops
    }

    // MARK: - Animation

    private var sweepAnimation: CAAnimationGroup {
        let radius = effectRadius
        let width = effectWidth

        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = unitPoint(for: axisVector(distance: radius + width, forward: false))
        start.toValue = unitPoint(for: axisVector(distance: radius, forward: true))
        start.timingFunction = CAMediaTimingFunction(name: .linear)

        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = unitPoint(for: axisVector(distance: radius, forward: false))
        end.toValue = unitPoint(for: axisVector(distance: radius + width, forward: true))
        // ShimmerView eases the traversal, which suits a small element whose
        // band is on it almost the whole time. Travel here has to clear a
        // whole screen at both ends, and easing spends the slow part of the
        // curve exactly where the band is off-surface. Constant speed keeps
        // the lit stretch from being crowded into the middle.
        end.timingFunction = CAMediaTimingFunction(name: .linear)

        let sweep = CAAnimationGroup()
        sweep.animations = [start, end]
        sweep.duration = Self.sweepDuration
        sweep.fillMode = .both

        // Nesting the sweep in a longer group is what produces the pause
        // between traversals: the outer group runs for the sweep plus the
        // interval, and `fillMode` holds the finished state through the gap
        // instead of snapping the band back across the surface.
        let repeating = CAAnimationGroup()
        repeating.animations = [sweep]
        repeating.duration = Self.sweepDuration + Self.sweepInterval
        repeating.repeatCount = .infinity
        repeating.fillMode = .both
        repeating.isRemovedOnCompletion = false
        return repeating
    }

    // MARK: - Test seams

    var hasAttachedSweep: Bool {
        gradientLayer.animation(forKey: Self.animationKey) != nil
    }
    var gradientStopColors: [CGColor] {
        (gradientLayer.colors as? [CGColor]) ?? []
    }
    var gradientLayerFrame: CGRect { gradientLayer.frame }

    /// Stands in for the system stripping animations across the layer tree,
    /// which is what backgrounding does. `removeAllAnimations()` on the view's
    /// own layer would leave the sublayer's sweep attached.
    func simulateSystemDroppingAnimations() {
        gradientLayer.removeAllAnimations()
    }
}

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
        // The controller's own view carries the authored value, alpha and all.
        // The shell surfaces above it take the same colour at full opacity:
        // they exist to hide the runtime surface, which keeps rendering through
        // a timeout so a late drawable can still arrive, and a translucent
        // overlay would both fail to hide it and stack the authored alpha a
        // second time.
        let background = UIColor(nuxieRGBAHex: contract.presentation.backgroundColor)
            ?? .systemBackground
        let occludingGround = background.withAlphaComponent(1)
        view.backgroundColor = background
        loadingView.backgroundColor = occludingGround
        errorView.backgroundColor = occludingGround

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
