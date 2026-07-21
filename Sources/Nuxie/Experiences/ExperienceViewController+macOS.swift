#if canImport(AppKit)
import AppKit

extension ExperienceViewController {
    func platformApplyDefaultBackgroundColor() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func platformApplyColorSchemeMode(_ mode: ExperienceColorSchemeMode) {
        view.appearance = mode.appearance
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        loadingView?.wantsLayer = true
        loadingView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        errorView?.wantsLayer = true
        errorView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func platformSetupLoadingView() {
        loadingView = NSView()
        loadingView.wantsLayer = true
        loadingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        loadingView.isHidden = true
        view.addSubview(loadingView)

        activityIndicator = NSProgressIndicator()
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .regular
        activityIndicator.isDisplayedWhenStopped = false
        loadingView.addSubview(activityIndicator)

        let loadingLabel = NSTextField(labelWithString: "Loading...")
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingView.addSubview(loadingLabel)

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
        errorView = NSView()
        errorView.wantsLayer = true
        errorView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        errorView.isHidden = true
        view.addSubview(errorView)

        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(handleMacRefreshTapped))
        refreshButton.bezelStyle = .rounded
        errorView.addSubview(refreshButton)

        closeButton = NSButton(title: "Close", target: self, action: #selector(handleMacCloseTapped))
        closeButton.bezelStyle = .rounded
        errorView.addSubview(closeButton)

        errorView.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            refreshButton.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 120),
            refreshButton.heightAnchor.constraint(equalToConstant: 34),

            closeButton.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 14),
            closeButton.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 100),
            closeButton.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    func platformStartLoadingIndicator() {
        activityIndicator.startAnimation(nil)
    }

    func platformStopLoadingIndicator() {
        activityIndicator.stopAnimation(nil)
    }

    @objc private func handleMacRefreshTapped() {
        retryFromErrorView()
    }

    @objc private func handleMacCloseTapped() {
        performDismiss(reason: .userDismissed)
    }
}
#endif
