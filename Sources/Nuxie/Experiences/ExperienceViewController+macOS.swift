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

        loadingLabel = NSTextField(labelWithString: "Loading...")
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
        guard !suppressesLoadingTreatmentForPresentation else {
            return
        }
        guard let loadingStyle = presentationShellContract?.presentation.loading.style else {
            activityIndicator.startAnimation(nil)
            return
        }
        guard loadingStyle == .shimmer else { return }
        activityIndicator.startAnimation(nil)
    }

    func platformStopLoadingIndicator() {
        activityIndicator.stopAnimation(nil)
    }

    func platformApplyPresentationShell(_ contract: ExperienceShellContract?) {
        guard let contract else { return }
        let background = NSColor(nuxieRGBAHex: contract.presentation.backgroundColor)
            ?? .windowBackgroundColor
        let loadingBackground = NSColor(
            nuxieRGBAHex: contract.presentation.loading.backgroundColor
        ) ?? background
        view.layer?.backgroundColor = background.cgColor
        loadingView.layer?.backgroundColor = loadingBackground.cgColor
        errorView.layer?.backgroundColor = loadingBackground.cgColor
        switch contract.presentation.loading.style {
        case .shimmer:
            activityIndicator.isHidden = suppressesLoadingTreatmentForPresentation
            loadingLabel.isHidden = suppressesLoadingTreatmentForPresentation
        case .solid:
            activityIndicator.isHidden = true
            loadingLabel.isHidden = true
        case .none:
            activityIndicator.isHidden = true
            loadingLabel.isHidden = true
            loadingView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func platformBringPresentationShellToFront() {
        if !loadingView.isHidden {
            loadingView.removeFromSuperview()
            view.addSubview(loadingView, positioned: .above, relativeTo: nil)
        }
        if !errorView.isHidden {
            errorView.removeFromSuperview()
            view.addSubview(errorView, positioned: .above, relativeTo: nil)
        }
    }

    func platformCancelPresentationRevealTransition() {
        presentationRevealGeneration &+= 1
        loadingView.layer?.removeAllAnimations()
        errorView.layer?.removeAllAnimations()
        loadingView.alphaValue = 1
        errorView.alphaValue = 1
    }

    func platformRevealPresentationContent() {
        presentationRevealGeneration &+= 1
        let generation = presentationRevealGeneration
        let overlays = [loadingView, errorView].compactMap { $0 }.filter { !$0.isHidden }
        let duration = ExperienceShellRevealTransition.duration(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        guard duration > 0, !overlays.isEmpty else {
            overlays.forEach {
                $0.isHidden = true
                $0.alphaValue = 1
            }
            return
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = duration
                overlays.forEach { $0.animator().alphaValue = 0 }
            },
            completionHandler: { [weak self] in
                guard self?.presentationRevealGeneration == generation else {
                    return
                }
                overlays.forEach {
                    $0.isHidden = true
                    $0.alphaValue = 1
                }
            }
        )
    }

    @objc private func handleMacRefreshTapped() {
        retryFromErrorView()
    }

    @objc private func handleMacCloseTapped() {
        performDismiss(reason: .userDismissed)
    }
}

private extension NSColor {
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
