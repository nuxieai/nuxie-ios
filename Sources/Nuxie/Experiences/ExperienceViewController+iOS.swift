#if canImport(UIKit)
import UIKit

final class ExperienceShellShimmerView: UIView {
    private static let animationKey = "nuxie.experience.shell.shimmer"

    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var gradientLayer: CAGradientLayer {
        layer as! CAGradientLayer
    }

    private(set) var isAnimating = false
    private var configuredBackgroundColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        isHidden = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(backgroundColor: UIColor, reduceMotion: Bool) {
        configuredBackgroundColor = backgroundColor
        let highlight = backgroundColor.blended(with: .white, fraction: 0.14)
        gradientLayer.colors = [
            backgroundColor.cgColor,
            highlight.cgColor,
            backgroundColor.cgColor,
        ]
        gradientLayer.locations = [0, 0.5, 1]
        isHidden = false
        reduceMotion ? stopAnimating() : startAnimating()
    }

    @objc private func reduceMotionStatusDidChange() {
        guard let configuredBackgroundColor, !isHidden else { return }
        configure(
            backgroundColor: configuredBackgroundColor,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func startAnimating() {
        guard !isAnimating else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-1, -0.5, 0]
        animation.toValue = [1, 1.5, 2]
        animation.duration = 1.15
        animation.repeatCount = .infinity
        gradientLayer.add(animation, forKey: Self.animationKey)
        isAnimating = true
    }

    func stopAnimating() {
        gradientLayer.removeAnimation(forKey: Self.animationKey)
        isAnimating = false
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
    }

    func platformSetupLoadingView() {
        // Container view
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

        // Activity indicator
        if #available(iOS 13.0, *) {
            activityIndicator = UIActivityIndicatorView(style: .large)
        } else {
            activityIndicator = UIActivityIndicatorView(style: .whiteLarge)
            activityIndicator.color = .gray
        }
        activityIndicator.hidesWhenStopped = true
        loadingView.addSubview(activityIndicator)

        // Loading label
        loadingLabel = UILabel()
        loadingLabel.text = "Loading..."
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.font = .systemFont(ofSize: 16)
        loadingLabel.textAlignment = .center
        loadingView.addSubview(loadingLabel)

        // Setup constraints
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingShimmerView.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

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
            activityIndicator.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor, constant: -20),

            loadingLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            loadingLabel.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor)
        ])
    }

    func platformSetupErrorView() {
        // Container view
        errorView = UIView()
        errorView.backgroundColor = .systemBackground
        errorView.isHidden = true
        errorView.accessibilityIdentifier = "nuxie-experience-recovery-shell"
        view.addSubview(errorView)

        // Refresh button with icon
        refreshButton = UIButton(type: .system)
        refreshButton.accessibilityIdentifier = "nuxie-experience-retry"
        if let refreshImage = UIImage(systemName: "arrow.clockwise") {
            refreshButton.setImage(refreshImage, for: .normal)
        }
        refreshButton.setTitle(" Refresh", for: .normal)
        refreshButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        refreshButton.backgroundColor = .systemBlue
        refreshButton.setTitleColor(.white, for: .normal)
        refreshButton.tintColor = .white
        refreshButton.layer.cornerRadius = 22
        refreshButton.addAction(
            UIAction { [weak self] _ in
                self?.retryFromErrorView()
            },
            for: .touchUpInside
        )
        errorView.addSubview(refreshButton)

        // Close button
        closeButton = UIButton(type: .system)
        closeButton.accessibilityIdentifier = "nuxie-experience-close"
        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 17)
        closeButton.setTitleColor(.label, for: .normal)
        closeButton.addAction(
            UIAction { [weak self] _ in
                self?.performDismiss(reason: .userDismissed)
            },
            for: .touchUpInside
        )
        errorView.addSubview(closeButton)

        // Setup constraints
        errorView.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Refresh button centered
            refreshButton.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 140),
            refreshButton.heightAnchor.constraint(equalToConstant: 44),

            // Close button below refresh
            closeButton.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 16),
            closeButton.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 100),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    func platformStartLoadingIndicator() {
        guard !suppressesLoadingTreatmentForPresentation else {
            return
        }
        guard let loadingStyle = presentationShellContract?.presentation.loading.style else {
            activityIndicator.startAnimating()
            return
        }
        guard loadingStyle == .shimmer else { return }
        loadingShimmerView.configure(
            backgroundColor: loadingView.backgroundColor ?? .systemBackground,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
    }

    func platformStopLoadingIndicator() {
        activityIndicator.stopAnimating()
        loadingShimmerView.stopAnimating()
    }

    func platformApplyPresentationShell(_ contract: ExperienceShellContract?) {
        guard let contract else { return }
        let background = UIColor(nuxieRGBAHex: contract.presentation.backgroundColor)
            ?? .systemBackground
        let loadingBackground = UIColor(
            nuxieRGBAHex: contract.presentation.loading.backgroundColor
        ) ?? background
        view.backgroundColor = background
        loadingView.backgroundColor = loadingBackground
        errorView.backgroundColor = loadingBackground

        switch contract.presentation.loading.style {
        case .shimmer:
            activityIndicator.isHidden = true
            loadingLabel.isHidden = true
            if suppressesLoadingTreatmentForPresentation {
                loadingShimmerView.stopAnimating()
                loadingShimmerView.isHidden = true
            } else {
                loadingShimmerView.configure(
                    backgroundColor: loadingBackground,
                    reduceMotion: UIAccessibility.isReduceMotionEnabled
                )
            }
        case .solid:
            activityIndicator.isHidden = true
            loadingLabel.isHidden = true
            loadingShimmerView.stopAnimating()
            loadingShimmerView.isHidden = true
        case .none:
            activityIndicator.isHidden = true
            loadingLabel.isHidden = true
            loadingShimmerView.stopAnimating()
            loadingShimmerView.isHidden = true
            loadingView.backgroundColor = .clear
        }
    }

    func platformBringPresentationShellToFront() {
        if !loadingView.isHidden { view.bringSubviewToFront(loadingView) }
        if !errorView.isHidden { view.bringSubviewToFront(errorView) }
    }

    func platformCancelPresentationRevealTransition() {
        presentationRevealGeneration &+= 1
        loadingView.layer.removeAllAnimations()
        errorView.layer.removeAllAnimations()
        loadingView.alpha = 1
        errorView.alpha = 1
    }

    func platformRevealPresentationContent() {
        presentationRevealGeneration &+= 1
        let generation = presentationRevealGeneration
        let overlays = [loadingView, errorView].compactMap { $0 }.filter { !$0.isHidden }
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

private extension UIColor {
    func blended(with other: UIColor, fraction: CGFloat) -> UIColor {
        let amount = min(max(fraction, 0), 1)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var otherRed: CGFloat = 0
        var otherGreen: CGFloat = 0
        var otherBlue: CGFloat = 0
        var otherAlpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              other.getRed(
                &otherRed,
                green: &otherGreen,
                blue: &otherBlue,
                alpha: &otherAlpha
              ) else {
            return self
        }
        return UIColor(
            red: red + (otherRed - red) * amount,
            green: green + (otherGreen - green) * amount,
            blue: blue + (otherBlue - blue) * amount,
            alpha: alpha + (otherAlpha - alpha) * amount
        )
    }
}

private extension UIColor {
    convenience init?(nuxieRGBAHex value: String) {
        guard value.count == 9, value.first == "#",
              let rgba = UInt32(value.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            red: CGFloat((rgba >> 24) & 0xff) / 255,
            green: CGFloat((rgba >> 16) & 0xff) / 255,
            blue: CGFloat((rgba >> 8) & 0xff) / 255,
            alpha: CGFloat(rgba & 0xff) / 255
        )
    }
}
#endif
