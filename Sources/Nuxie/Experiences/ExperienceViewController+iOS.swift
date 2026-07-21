#if canImport(UIKit)
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
    }

    func platformSetupLoadingView() {
        // Container view
        loadingView = UIView()
        loadingView.backgroundColor = .systemBackground
        loadingView.isHidden = true
        view.addSubview(loadingView)

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
        let loadingLabel = UILabel()
        loadingLabel.text = "Loading..."
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.font = .systemFont(ofSize: 16)
        loadingLabel.textAlignment = .center
        loadingView.addSubview(loadingLabel)

        // Setup constraints
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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
        view.addSubview(errorView)

        // Refresh button with icon
        refreshButton = UIButton(type: .system)
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
        activityIndicator.startAnimating()
    }

    func platformStopLoadingIndicator() {
        activityIndicator.stopAnimating()
    }
}
#endif
