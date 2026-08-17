import Foundation

#if canImport(UIKit)
import UIKit

/// A floating circular control rendered in Liquid Glass where the platform
/// supports it, and in an equivalent blurred material everywhere else.
///
/// The control is a fixed 44pt circle so it always meets the minimum hit
/// target without the caller padding around it, and it never participates in
/// the runtime's layout: callers pin it to the safe area as an overlay so the
/// authored surface underneath keeps its full container geometry.
@MainActor
final class ExperienceGlassControl: UIControl {
    static let diameter: CGFloat = 44

    private let effectView: UIVisualEffectView
    private let tintView = UIView()
    private let imageView = UIImageView()

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            let scale: CGFloat = isHighlighted ? 0.92 : 1
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: { self.transform = .init(scaleX: scale, y: scale) }
            )
        }
    }

    init(systemImageName: String, accessibilityLabel: String) {
        effectView = UIVisualEffectView(effect: Self.makeEffect(prefersLightContent: true))
        super.init(frame: .zero)

        isAccessibilityElement = true
        accessibilityTraits = .button
        self.accessibilityLabel = accessibilityLabel

        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.layer.cornerRadius = Self.diameter / 2
        effectView.layer.cornerCurve = .continuous
        addSubview(effectView)

        tintView.isUserInteractionEnabled = false
        effectView.contentView.addSubview(tintView)

        imageView.contentMode = .center
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 15,
            weight: .semibold
        )
        imageView.image = UIImage(systemName: systemImageName)
        imageView.isUserInteractionEnabled = false
        effectView.contentView.addSubview(imageView)

        for subview in [effectView, tintView, imageView] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
            tintView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ palette: ExperienceShellPalette) {
        // The glass renders against the interface style, which the controller
        // forces from the experience's color-scheme mode rather than from the
        // authored background. Pinning the style here keeps a dark surface's
        // control on dark glass, so a light glyph is legible on it.
        overrideUserInterfaceStyle = palette.prefersLightContent ? .dark : .light
        effectView.effect = Self.makeEffect(
            prefersLightContent: palette.prefersLightContent
        )
        tintView.backgroundColor = palette.glassTint
        imageView.tintColor = palette.primary
    }

    private static func makeEffect(prefersLightContent: Bool) -> UIVisualEffect {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            return glass
        }
        #endif
        return UIBlurEffect(
            style: prefersLightContent
                ? .systemUltraThinMaterialDark
                : .systemUltraThinMaterialLight
        )
    }
}

/// A full-width capsule action in the same Liquid Glass material as the
/// floating controls.
///
/// It is sized and positioned for a thumb: the caller stretches it between the
/// surface's side gutters and anchors it near the bottom, rather than centring
/// it in the middle of the screen where a one-handed reach cannot land.
@MainActor
final class ExperienceGlassButton: UIControl {
    static let height: CGFloat = 56

    private let effectView: UIVisualEffectView
    private let tintView = UIView()
    private let titleLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    /// Shows a spinner in place of the title while the action is in flight and
    /// stops accepting input, so a slow retry cannot be tapped twice.
    var isBusy: Bool = false {
        didSet {
            guard oldValue != isBusy else { return }
            titleLabel.isHidden = isBusy
            isBusy ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
            isEnabled = !isBusy
        }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            let scale: CGFloat = isHighlighted ? 0.97 : 1
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: { self.transform = .init(scaleX: scale, y: scale) }
            )
        }
    }

    var title: String? {
        get { titleLabel.text }
        set {
            titleLabel.text = newValue
            accessibilityLabel = newValue
        }
    }

    init(title: String) {
        effectView = UIVisualEffectView(effect: Self.makeEffect(prefersLightContent: true))
        super.init(frame: .zero)

        isAccessibilityElement = true
        accessibilityTraits = .button

        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.layer.cornerRadius = Self.height / 2
        effectView.layer.cornerCurve = .continuous
        addSubview(effectView)

        tintView.isUserInteractionEnabled = false
        effectView.contentView.addSubview(tintView)

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.isUserInteractionEnabled = false
        effectView.contentView.addSubview(titleLabel)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.isUserInteractionEnabled = false
        effectView.contentView.addSubview(activityIndicator)

        for subview in [effectView, tintView, titleLabel, activityIndicator] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
            tintView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 16
            ),
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.title = title
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ palette: ExperienceShellPalette) {
        // See `ExperienceGlassControl`: the label has to contrast with the
        // glass, and the glass follows the interface style rather than the
        // authored background.
        overrideUserInterfaceStyle = palette.prefersLightContent ? .dark : .light
        effectView.effect = Self.makeEffect(
            prefersLightContent: palette.prefersLightContent
        )
        tintView.backgroundColor = palette.glassTint
        titleLabel.textColor = palette.primary
        activityIndicator.color = palette.primary
    }

    private static func makeEffect(prefersLightContent: Bool) -> UIVisualEffect {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            return glass
        }
        #endif
        return UIBlurEffect(
            style: prefersLightContent
                ? .systemUltraThinMaterialDark
                : .systemUltraThinMaterialLight
        )
    }
}

/// The recovery surface shown when a presentation cannot finish acquiring.
///
/// Laid out like the platform's own interruption screens: a large tinted
/// glyph, a short title, a sentence of explanation, and one full-width action
/// anchored near the bottom where a thumb actually reaches. The action is the
/// same Liquid Glass material as the floating close, so the two read as one
/// set of controls.
@MainActor
final class ExperienceShellRecoveryView: UIView {
    /// Side gutter for the action, and the minimum margin for copy.
    private static let horizontalGutter: CGFloat = 24
    /// Gap between the action and the bottom safe area.
    private static let actionBottomInset: CGFloat = 32
    /// Breathing room above the copy on a surface tall enough to have it.
    private static let contentTopInset: CGFloat = 24
    /// Smallest gap kept between the copy and the action.
    static let minimumCopyActionGap: CGFloat = 24

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let textStack = UIStackView()
    private let actionButton: ExperienceGlassButton
    private let scrollView = UIScrollView()
    private let layoutStack = UIStackView()

    private(set) var reason: ExperienceShellRecoveryReason = .unavailable

    /// Retry is in flight.
    var isRetrying: Bool = false {
        didSet { actionButton.isBusy = isRetrying }
    }

    private static let actionTitle = "Try Again"

    init(onRetry: @escaping @MainActor () -> Void) {
        actionButton = ExperienceGlassButton(title: Self.actionTitle)
        super.init(frame: .zero)
        accessibilityIdentifier = "nuxie-experience-recovery-shell"

        // Large enough to carry the state on its own, the way a platform
        // interruption screen leads with its glyph.
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 64,
            weight: .regular
        )
        iconView.contentMode = .center
        iconView.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = Self.scaledFont(.title1, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = Self.scaledFont(.title3, weight: .regular)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        textStack.axis = .vertical
        textStack.alignment = .center
        textStack.spacing = 6
        textStack.addArrangedSubview(iconView)
        textStack.setCustomSpacing(22, after: iconView)
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(messageLabel)

        actionButton.accessibilityIdentifier = "nuxie-experience-retry"
        actionButton.addAction(UIAction { _ in onRetry() }, for: .touchUpInside)

        // The surface has to survive geometry the descriptor can legitimately
        // sign. A drawer may take a small fraction of the screen, and Dynamic
        // Type can push this copy past even a full screen, so the content
        // scrolls rather than forcing UIKit to break a constraint and overlap
        // the action with the copy exactly when loading has already failed.
        let topSpacer = UIView()
        let bottomSpacer = UIView()
        for spacer in [topSpacer, bottomSpacer] {
            spacer.isUserInteractionEnabled = false
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        layoutStack.axis = .vertical
        layoutStack.alignment = .fill
        layoutStack.addArrangedSubview(topSpacer)
        layoutStack.addArrangedSubview(textStack)
        layoutStack.addArrangedSubview(bottomSpacer)
        layoutStack.addArrangedSubview(actionButton)

        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        addSubview(scrollView)
        scrollView.addSubview(layoutStack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        layoutStack.translatesAutoresizingMaskIntoConstraints = false
        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        // Free space above the copy is kept a little smaller than the space
        // below it, so the block sits above centre without a fixed offset that
        // a short surface cannot honour.
        let bias = topSpacer.heightAnchor.constraint(
            equalTo: bottomSpacer.heightAnchor,
            multiplier: 0.8
        )
        bias.priority = .defaultHigh
        // Free space collapses first on a short surface; the copy and the
        // action must still not end up flush against each other.
        let minimumGap = bottomSpacer.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumCopyActionGap
        )
        // Fills the surface when there is room; scrolls when there is not.
        let fills = layoutStack.heightAnchor.constraint(
            greaterThanOrEqualTo: frame.heightAnchor,
            constant: -(Self.contentTopInset + Self.actionBottomInset)
        )
        fills.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

            layoutStack.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: Self.contentTopInset
            ),
            layoutStack.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -Self.actionBottomInset
            ),
            layoutStack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor,
                constant: Self.horizontalGutter
            ),
            layoutStack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -Self.horizontalGutter
            ),
            layoutStack.widthAnchor.constraint(
                equalTo: frame.widthAnchor,
                constant: -(Self.horizontalGutter * 2)
            ),
            bias,
            minimumGap,
            fills,
        ])

        apply(reason: reason)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Scales a system text style at a specific weight, so the copy honours
    /// Dynamic Type instead of pinning a point size.
    ///
    /// The base size is read at the default content size category on purpose.
    /// `preferredFontDescriptor(withTextStyle:)` returns a size already scaled
    /// for the current category, and handing that to `UIFontMetrics` scales it
    /// a second time: at AX5 that turns `.title3` into roughly 143pt instead
    /// of 55pt and overflows the surface.
    static func scaledFont(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        let unscaled = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        return UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: unscaled.pointSize, weight: weight),
            compatibleWith: traits
        )
    }

    /// The retry action, republished so shell state stays assertable.
    var primaryActionButton: ExperienceGlassButton { actionButton }

    /// Bounds of the copy block within the surface, for layout assertions.
    var copyFrameInSurface: CGRect {
        textStack.convert(textStack.bounds, to: self)
    }

    /// Total scrollable height, so a test can prove nothing is stranded out of
    /// reach on a short surface.
    var scrollableContentHeight: CGFloat {
        max(scrollView.contentSize.height, scrollView.bounds.height)
    }

    /// The action's frame in the scroll view's content space, comparable with
    /// `scrollableContentHeight`.
    var actionFrameInScrollableContent: CGRect {
        actionButton.convert(actionButton.bounds, to: scrollView)
    }

    /// Non-empty copy currently on the surface.
    var visibleTextLabels: [String] {
        textStack.arrangedSubviews
            .compactMap { $0 as? UILabel }
            .filter { !$0.isHidden }
            .compactMap { $0.text }
            .filter { !$0.isEmpty }
    }

    /// Copy for each reason.
    ///
    /// Only `offline`, which the device itself reports, mentions connectivity,
    /// and even then it does not name Wi-Fi or imply the user misconfigured
    /// anything. A server fault or a verification failure stays neutral,
    /// because telling someone to check their network would be a guess that
    /// sends them to fix something that is not broken.
    func apply(reason: ExperienceShellRecoveryReason) {
        self.reason = reason
        switch reason {
        case .offline:
            // Radio waves rather than a Wi-Fi glyph: the device may be on
            // cellular, and the shell has no idea which link is missing.
            iconView.image = Self.symbol(
                "antenna.radiowaves.left.and.right.slash",
                fallback: "exclamationmark.circle.fill"
            )
            titleLabel.text = "No Connection"
            messageLabel.text = "Reconnect to the internet and try again."
        case .unavailable:
            iconView.image = Self.symbol(
                "exclamationmark.circle.fill",
                fallback: "exclamationmark.circle"
            )
            titleLabel.text = "Something Went Wrong"
            messageLabel.text = "There was a problem loading this content."
        }
        accessibilityLabel = [titleLabel.text, messageLabel.text]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    /// Resolves a symbol, falling back when a name is unavailable on the
    /// running OS so the recovery surface never renders without its glyph.
    private static func symbol(_ name: String, fallback: String) -> UIImage? {
        UIImage(systemName: name) ?? UIImage(systemName: fallback)
    }

    func apply(_ palette: ExperienceShellPalette) {
        iconView.tintColor = palette.accentTint
        titleLabel.textColor = palette.primary
        messageLabel.textColor = palette.secondary
        actionButton.apply(palette)
    }
}
#endif
