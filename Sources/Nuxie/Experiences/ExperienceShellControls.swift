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

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let textStack = UIStackView()
    private let actionButton: ExperienceGlassButton

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
        addSubview(textStack)

        actionButton.accessibilityIdentifier = "nuxie-experience-retry"
        actionButton.addAction(UIAction { _ in onRetry() }, for: .touchUpInside)
        addSubview(actionButton)

        textStack.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // The copy sits a little above centre rather than dead centre,
            // which keeps it clear of the bottom-anchored action.
            textStack.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -48
            ),
            textStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            textStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: Self.horizontalGutter + 8
            ),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -(Self.horizontalGutter + 8)
            ),

            actionButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.horizontalGutter
            ),
            actionButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.horizontalGutter
            ),
            actionButton.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor,
                constant: -Self.actionBottomInset
            ),
            actionButton.topAnchor.constraint(
                greaterThanOrEqualTo: textStack.bottomAnchor,
                constant: 24
            ),
        ])

        apply(reason: reason)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Scales a system text style at a specific weight, so the copy honours
    /// Dynamic Type instead of pinning a point size.
    private static func scaledFont(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight
    ) -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
        return UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: descriptor.pointSize, weight: weight)
        )
    }

    /// The retry action, republished so shell state stays assertable.
    var primaryActionButton: ExperienceGlassButton { actionButton }

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
