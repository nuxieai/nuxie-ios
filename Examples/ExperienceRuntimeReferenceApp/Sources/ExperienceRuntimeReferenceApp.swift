@_spi(Testing) import Nuxie
import SwiftUI
import UIKit

@main
struct NuxieExperienceRuntimeReferenceApp: App {
    var body: some Scene {
        WindowGroup {
            ExperienceRuntimeReferenceView()
                .ignoresSafeArea()
        }
    }
}

private struct ExperienceRuntimeReferenceView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        ExperienceRuntimeReferenceViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

@MainActor
private final class ExperienceRuntimeReferenceViewController: UIViewController {
    private let fixtureNames = ["animation-event", "multi-screen"]
    private let segmentedControl = UISegmentedControl()
    private let statusLabel = UILabel()
    private var currentViewController: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureControls()
        loadFixture(named: fixtureNames[0])
    }

    private func configureControls() {
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.accessibilityIdentifier = "nuxie-reference-fixture-selector"
        for (index, fixtureName) in fixtureNames.enumerated() {
            segmentedControl.insertSegment(withTitle: fixtureName, at: index, animated: false)
        }
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addAction(UIAction { [weak self] _ in
            guard let self, fixtureNames.indices.contains(segmentedControl.selectedSegmentIndex) else {
                return
            }
            loadFixture(named: fixtureNames[segmentedControl.selectedSegmentIndex])
        }, for: .valueChanged)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "nuxie-runtime-status"
        statusLabel.isAccessibilityElement = true
        statusLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        statusLabel.textAlignment = .center

        view.addSubview(segmentedControl)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 12
            ),
            segmentedControl.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -12
            ),
            segmentedControl.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -12
            ),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            statusLabel.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func loadFixture(named fixtureName: String) {
        do {
            guard let resourceURL = Bundle.main.resourceURL else {
                throw ExperienceRuntimeReferenceError.missingResourceRoot
            }
            let fixtureURL = resourceURL
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent(fixtureName, isDirectory: true)
            guard FileManager.default.fileExists(
                atPath: fixtureURL.appendingPathComponent("profile.json").path
            ) else {
                throw ExperienceRuntimeReferenceError.missingFixture(fixtureName)
            }
            setStatus("loading:\(fixtureName)")
            let cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("nuxie-experience-runtime-reference", isDirectory: true)
                .appendingPathComponent(fixtureName, isDirectory: true)
            let child = try ExperienceReleaseFixtureHost.makeViewController(
                fixtureBaseURL: fixtureURL,
                cacheRootURL: cacheRoot,
                presentationDiagnosticsEnabled: true,
                statusObserver: { [weak self] status in
                    self?.setStatus(
                        status == "ready" ? "presented:\(fixtureName)" : "\(status):\(fixtureName)"
                    )
                }
            )
            replaceCurrentViewController(with: child)
        } catch {
            setStatus("error:\(error.localizedDescription)")
        }
    }

    private func replaceCurrentViewController(with next: UIViewController) {
        if let currentViewController {
            currentViewController.willMove(toParent: nil)
            currentViewController.view.removeFromSuperview()
            currentViewController.removeFromParent()
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(next.view, at: 0)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        next.didMove(toParent: self)
        currentViewController = next
        view.bringSubviewToFront(segmentedControl)
        view.bringSubviewToFront(statusLabel)
    }

    private func setStatus(_ value: String) {
        statusLabel.text = value
        statusLabel.accessibilityLabel = value
    }
}

private enum ExperienceRuntimeReferenceError: LocalizedError {
    case missingResourceRoot
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            "Reference app could not resolve Bundle.main.resourceURL"
        case .missingFixture(let fixture):
            "Signed experience release fixture is missing: \(fixture)"
        }
    }
}
