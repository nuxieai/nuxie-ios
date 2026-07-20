import CryptoKit
import Foundation
import SwiftUI
import UIKit

@main
struct NuxieFlowRuntimeReferenceApp: App {
    var body: some Scene {
        WindowGroup {
            FlowRuntimeReferenceView()
                .ignoresSafeArea()
        }
    }
}

private struct FlowRuntimeReferenceView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        FlowRuntimeReferenceViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

@MainActor
private final class FlowRuntimeReferenceViewController: UIViewController {
    private let fixtureNames = [
        "layout-paint",
        "pressable-interaction",
    ]
    private var currentViewController: UIViewController?
    private let segmentedControl = UISegmentedControl()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureFixtureControl()
        loadFixture(named: fixtureNames[0])
    }

    private func configureFixtureControl() {
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.accessibilityIdentifier = "nuxie-reference-fixture-selector"
        for (index, fixtureName) in fixtureNames.enumerated() {
            segmentedControl.insertSegment(withTitle: fixtureName, at: index, animated: false)
        }
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        segmentedControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let index = self.segmentedControl.selectedSegmentIndex
            guard self.fixtureNames.indices.contains(index) else { return }
            self.loadFixture(named: self.fixtureNames[index])
        }, for: .valueChanged)

        view.addSubview(segmentedControl)
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
            segmentedControl.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func loadFixture(named fixtureName: String) {
        do {
            let viewController = try makeRuntimeViewController(fixtureName: fixtureName)
            replaceCurrentViewController(with: viewController)
        } catch {
            replaceCurrentViewController(with: FlowRuntimeReferenceErrorViewController(error: error))
        }
    }

    private func makeRuntimeViewController(fixtureName: String) throws -> UIViewController {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw FlowRuntimeReferenceError.missingResourceRoot
        }

        let fixtureBaseURL = resourceURL
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(fixtureName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixtureBaseURL.path) else {
            throw FlowRuntimeReferenceError.missingFixture(fixtureName)
        }

        #if canImport(NuxieRuntime)
        return try FlowRuntimeNativeFixtureViewController(
            fixtureName: fixtureName,
            fixtureBaseURL: fixtureBaseURL
        )
        #else
        throw FlowRuntimeReferenceError.runtimeNotLinked
        #endif
    }

    private func replaceCurrentViewController(with nextViewController: UIViewController) {
        if let currentViewController {
            currentViewController.willMove(toParent: nil)
            currentViewController.view.removeFromSuperview()
            currentViewController.removeFromParent()
        }

        addChild(nextViewController)
        nextViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(nextViewController.view, at: 0)
        NSLayoutConstraint.activate([
            nextViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nextViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nextViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            nextViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        nextViewController.didMove(toParent: self)
        currentViewController = nextViewController
        view.bringSubviewToFront(segmentedControl)
    }
}

#if canImport(NuxieRuntime)
@MainActor
private final class FlowRuntimeNativeFixtureViewController: UIViewController {
    private let fixtureName: String
    private let artifactBytes: Data
    private let artboardName: String
    private let surfaceView = FlowRuntimeSurfaceView()
    private let statusLabel = UILabel()
    private var displayHost: FlowRuntimeDisplayHost?
    private var startTask: Task<Void, Never>?
    private var rendererGeneration: UInt64 = 0
    private var isPresentationVisible = false

    init(fixtureName: String, fixtureBaseURL: URL) throws {
        let manifestURL = fixtureBaseURL.appendingPathComponent("nuxie-manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(
            FlowRuntimeReferenceManifest.self,
            from: manifestData
        )
        artifactBytes = try Data(
            contentsOf: fixtureBaseURL.appendingPathComponent(manifest.riv.path)
        )
        artboardName = manifest.entry.artboardName
        self.fixtureName = fixtureName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.accessibilityIdentifier = "nuxie-runtime-metal-surface"
        surfaceView.accessibilityLabel = "Nuxie Runtime Metal surface"
        surfaceView.isAccessibilityElement = true
        view.addSubview(surfaceView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityIdentifier = "nuxie-runtime-status"
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.textAlignment = .center
        statusLabel.text = "loading:\(fixtureName)"
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: view.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 12
            ),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -12
            ),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -12
            ),
            statusLabel.heightAnchor.constraint(equalToConstant: 28),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationVisible = true
        if let displayHost {
            displayHost.setPresentationVisible(true)
            return
        }
        guard startTask == nil else { return }

        rendererGeneration &+= 1
        let generation = rendererGeneration
        startTask = Task { @MainActor [weak self] in
            await self?.startRenderer(generation: generation)
            guard let self, rendererGeneration == generation else { return }
            startTask = nil
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationVisible = false
        displayHost?.setPresentationVisible(false)
    }

    override func willMove(toParent parent: UIViewController?) {
        super.willMove(toParent: parent)
        guard parent == nil else { return }
        stopRenderer()
    }

    private func stopRenderer() {
        rendererGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        guard let displayHost else { return }
        self.displayHost = nil
        Task { @MainActor in
            await displayHost.shutdown()
        }
    }

    deinit {
        startTask?.cancel()
    }

    private func startRenderer(generation: UInt64) async {
        var candidateDisplayHost: FlowRuntimeDisplayHost?
        do {
            let factory = FlowRuntimeContextFactory(adapter: NuxieRuntimeAdapter())
            let context = try await factory.makeContext(
                for: try makeUnsignedImportRequest()
            )
            try Task.checkCancellation()
            guard rendererGeneration == generation else { throw CancellationError() }
            let session = try await context.makeSession(
                descriptor: FlowRenderSessionDescriptor(artboardName: artboardName)
            )
            try Task.checkCancellation()
            guard rendererGeneration == generation else { throw CancellationError() }
            let displayHost = FlowRuntimeDisplayHost(
                session: session,
                surfaceView: surfaceView,
                onResult: { _ in },
                onError: { [weak self] error in
                    guard self?.rendererGeneration == generation else { return }
                    self?.show(error: error)
                }
            )
            candidateDisplayHost = displayHost
            self.displayHost = displayHost
            displayHost.setPresentationVisible(isPresentationVisible)
            try await displayHost.start()
            try Task.checkCancellation()
            guard rendererGeneration == generation else { throw CancellationError() }
            try await waitForFirstPresentedFrame(from: session)
            guard rendererGeneration == generation else { throw CancellationError() }
            statusLabel.text = "presented:\(fixtureName)"
        } catch is CancellationError {
            if displayHost === candidateDisplayHost {
                displayHost = nil
            }
            await candidateDisplayHost?.shutdown()
        } catch {
            if displayHost === candidateDisplayHost {
                displayHost = nil
            }
            await candidateDisplayHost?.shutdown()
            guard rendererGeneration == generation else { return }
            show(error: error)
        }
    }

    private func makeUnsignedImportRequest() throws -> FlowRuntimeImportRequest {
        let flowId = "runtime-reference-\(artboardName)"
        let buildId = "bundled-fixture"
        let digest = SHA256.hash(data: artifactBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifestBytes = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "flowId": flowId,
                "buildId": buildId,
                "renderer": "rive",
                "riv": [
                    "path": "flow.riv",
                    "sha256": digest,
                    "sizeBytes": artifactBytes.count,
                ],
                "assets": ["images": [], "fonts": []],
            ],
            options: [.sortedKeys]
        )
        return FlowRuntimeImportRequest(
            artifactBytes: artifactBytes,
            expectedIdentity: FlowRuntimeArtifactIdentity(
                flowId: flowId,
                buildId: buildId
            ),
            authorizationEvidence: FlowRuntimeAuthorizationEvidence(
                signedContentBytes: manifestBytes,
                signatureEnvelopeBytes: nil,
                selectedKey: nil
            )
        )
    }

    private func show(error: Error) {
        statusLabel.text = "error:\(error.localizedDescription)"
        statusLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.86)
    }

    private func waitForFirstPresentedFrame(
        from session: FlowRenderSession
    ) async throws {
        for _ in 0..<300 {
            try Task.checkCancellation()
            if session.readiness == .ready { return }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw FlowRuntimeReferenceRendererError.firstFrameTimedOut
    }
}

private struct FlowRuntimeReferenceManifest: Decodable {
    struct Riv: Decodable {
        let path: String
    }

    struct Entry: Decodable {
        let artboardName: String
    }

    let riv: Riv
    let entry: Entry
}
#endif

private enum FlowRuntimeReferenceRendererError: LocalizedError {
    case firstFrameTimedOut

    var errorDescription: String? {
        "NuxieRuntime did not present its first frame within five seconds"
    }
}

private enum FlowRuntimeReferenceError: LocalizedError {
    case missingResourceRoot
    case missingFixture(String)
    case runtimeNotLinked

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            return "Flow runtime reference app could not resolve Bundle.main.resourceURL"
        case .missingFixture(let fixture):
            return "Flow runtime fixture is missing: \(fixture)"
        case .runtimeNotLinked:
            return "NuxieRuntime.xcframework is not linked into the reference app"
        }
    }
}

@MainActor
private final class FlowRuntimeReferenceErrorViewController: UIViewController {
    private let error: Error

    init(error: Error) {
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "nuxie-runtime-reference-error"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .label
        label.text = error.localizedDescription

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
