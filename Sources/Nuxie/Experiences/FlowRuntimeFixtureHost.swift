import Foundation

#if canImport(UIKit)
import UIKit
#endif

// Test/preview scaffolding only. DEBUG-gated so it can never ship in a release
// build of a host app: it registers a fake configuration and resets the SDK's
// DI scope, which would destroy a live SDK if called in production.
// Consumers: Tests/FlowRuntimeHostApp, Examples/FlowRuntimeReferenceApp (both
// build Debug). Full relocation to a test-support target happens with the
// Phase 4 composition root.
#if canImport(UIKit) && DEBUG
public enum FlowRuntimeFixtureHost {
    private static let fixtureBaseURLToken = "__NUXIE_FIXTURE_BASE_URL__"

    @MainActor
    public static func makeViewController(
        fixtureBaseURL: URL,
        cacheRootURL: URL,
        flowId: String? = nil,
        initialNavigationStack: [String] = [],
        manualEventName: String? = nil,
        statusObserver: (@MainActor (String) -> Void)? = nil
    ) throws -> UIViewController {
        let configuration = makeFixtureConfiguration(cacheRootURL: cacheRootURL)

        let fixtureBaseURL = try prepareFixtureBaseURL(
            fixtureBaseURL,
            cacheRootURL: cacheRootURL
        )
        let manifestURL = fixtureBaseURL.appendingPathComponent(ExperienceArtifactStore.manifestPath)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: manifestData)
        let fixtureFlow = try loadFixtureFlowDefinition(fixtureBaseURL: fixtureBaseURL)
        let resolvedFlowId = flowId ?? manifest.flowId

        let buildFiles = try buildFiles(
            for: manifest,
            manifestData: manifestData,
            fixtureBaseURL: fixtureBaseURL
        )
        let buildManifest = BuildManifest(
            totalFiles: buildFiles.count,
            totalSize: buildFiles.reduce(0) { $0 + $1.size },
            contentHash: contentHash(for: manifest, manifestData: manifestData, fixtureBaseURL: fixtureBaseURL),
            files: buildFiles
        )
        let screens = RemoteFlow(
            id: resolvedFlowId,
            flowArtifact: FlowArtifact(
                url: fixtureBaseURL.absoluteString,
                buildId: manifest.buildId,
                manifest: buildManifest
            ),
            screens: fixtureFlow.screens ?? manifest.screens.map {
                RemoteFlowScreen(
                    id: $0.screenId,
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )
            },
            events: fixtureFlow.events ?? [:],
            handlers: fixtureFlow.handlers ?? [:],
            scripts: fixtureFlow.scripts ?? [:],
            viewModelValues: nil
        )

        let runtimeAssetStore = RuntimeAssetStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("runtime-assets")
        )
        let artifactStore = ExperienceArtifactStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("artifacts"),
            runtimeAssetStore: runtimeAssetStore
        )

        // Self-contained leaf graph for the fixture: a real event pipeline is
        // not part of fixture rendering, so the VC gets a minimal EventLog
        // over fixture storage and a standalone StoreKit pair. The same graph
        // backs the fixture journey runner when the flow declares handlers.
        let dateProvider = SystemDateProvider()
        let sleepProvider = SystemSleepProvider()
        let api = NuxieApi(
            apiKey: configuration.apiKey,
            baseURL: configuration.apiEndpoint,
            useGzipCompression: false,
            urlSession: configuration.urlSession
        )
        let identity = IdentityService(customStoragePath: configuration.customStoragePath)
        let eventLog = EventLog(
            identity: identity,
            sessions: SessionService(),
            dateProvider: dateProvider,
            apiClient: api
        )
        let irRuntime = IRRuntime(dateProvider: dateProvider)
        let segments = SegmentService(
            identity: identity,
            dateProvider: dateProvider,
            irRuntime: irRuntime
        )
        let productService = ProductService()
        var fixtureTransactionService: TransactionService!
        let flows = ExperienceService(
            api: api,
            productService: productService,
            eventLog: eventLog,
            transactionServiceProvider: { fixtureTransactionService }
        )
        let profile = ProfileService(
            identity: identity,
            api: api,
            segments: segments,
            flows: flows,
            dateProvider: dateProvider,
            sleepProvider: sleepProvider,
            customStoragePath: configuration.customStoragePath
        )
        let features = FeatureService(
            api: api,
            identity: identity,
            profile: profile,
            dateProvider: dateProvider,
            featureInfo: FeatureInfo(),
            configProvider: { configuration }
        )
        irRuntime.wire(
            identity: identity, eventLog: eventLog,
            segments: segments, features: features)
        let transactionObserver = TransactionObserver(
            api: api,
            features: features,
            identity: identity,
            configurationProvider: { configuration },
            transactionServiceProvider: { fixtureTransactionService }
        )
        let transactionService = TransactionService(
            productService: productService,
            transactionObserver: transactionObserver,
            configurationProvider: { configuration }
        )
        fixtureTransactionService = transactionService
        let runnerDependencies = FixtureRunnerDependencies(
            eventLog: eventLog,
            identity: identity,
            segments: segments,
            features: features,
            profile: profile,
            api: api,
            dateProvider: dateProvider,
            irRuntime: irRuntime
        )

        let flow = Experience(screens: screens, products: [])
        let flowViewController = ExperienceViewController(
            flow: flow,
            artifactStore: artifactStore,
            eventLog: eventLog,
            transactionService: transactionService,
            productService: productService
        )

        if fixtureFlow.hasJourneyRuntime {
            return FlowRuntimeFixtureContainerViewController(
                flowViewController: flowViewController,
                flow: flow,
                initialNavigationStack: initialNavigationStack,
                manualEventName: manualEventName,
                statusObserver: statusObserver,
                runnerDependencies: runnerDependencies
            )
        }

        return flowViewController
    }

    private static func loadFixtureFlowDefinition(
        fixtureBaseURL: URL
    ) throws -> FixtureFlowDefinition {
        let url = fixtureBaseURL.appendingPathComponent("flow-description.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FixtureFlowDefinition()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureFlowDefinition.self, from: data)
    }

    private struct FixtureFlowDefinition: Decodable {
        var screens: [RemoteFlowScreen]? = nil
        var events: [String: [EventDeclaration]]? = nil
        var handlers: [String: [JourneyEventHandler]]? = nil
        var scripts: [String: ScreenScriptRef]? = nil

        var hasJourneyRuntime: Bool {
            handlers?.isEmpty == false
        }
    }

    /// Collaborators for the fixture journey runner, built once from the
    /// fixture's self-contained leaf graph.
    private struct FixtureRunnerDependencies {
        let eventLog: EventLogProtocol
        let identity: IdentityServiceProtocol
        let segments: SegmentServiceProtocol
        let features: FeatureServiceProtocol
        let profile: ProfileServiceProtocol
        let api: NuxieApiProtocol
        let dateProvider: DateProviderProtocol
        let irRuntime: IRRuntime
    }

    private final class FlowRuntimeFixtureContainerViewController: UIViewController {
        private let flowViewController: ExperienceViewController
        private let statusLabel = UILabel()
        private let startButton = UIButton(type: .system)
        private let runtime: FlowRuntimeFixtureExecutionRuntime
        private let manualEventName: String?
        private let statusObserver: (@MainActor (String) -> Void)?

        init(
            flowViewController: ExperienceViewController,
            flow: Experience,
            initialNavigationStack: [String],
            manualEventName: String?,
            statusObserver: (@MainActor (String) -> Void)?,
            runnerDependencies: FixtureRunnerDependencies
        ) {
            self.flowViewController = flowViewController
            self.manualEventName = manualEventName
            self.statusObserver = statusObserver
            self.runtime = FlowRuntimeFixtureExecutionRuntime(
                flow: flow,
                flowViewController: flowViewController,
                initialNavigationStack: initialNavigationStack,
                runnerDependencies: runnerDependencies
            )
            super.init(nibName: nil, bundle: nil)
            self.runtime.statusLabel = statusLabel
            self.runtime.statusObserver = statusObserver
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()

            addChild(flowViewController)
            flowViewController.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(flowViewController.view)
            flowViewController.didMove(toParent: self)

            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            statusLabel.accessibilityIdentifier = "nuxie-flow-event-log"
            statusLabel.text = "ready"
            statusLabel.textColor = .clear
            statusLabel.backgroundColor = .clear
            statusLabel.font = .systemFont(ofSize: 1, weight: .regular)
            statusLabel.numberOfLines = 1
            statusLabel.isAccessibilityElement = true
            view.addSubview(statusLabel)
            statusObserver?("ready")

            if manualEventName != nil {
                startButton.translatesAutoresizingMaskIntoConstraints = false
                startButton.accessibilityIdentifier = "nuxie-flow-manual-start"
                startButton.setTitle("Run transition", for: .normal)
                startButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
                startButton.backgroundColor = .systemBlue
                startButton.tintColor = .white
                startButton.layer.cornerRadius = 14
                startButton.addAction(UIAction { [weak self] _ in
                    guard let self, let manualEventName = self.manualEventName else { return }
                    self.startButton.isHidden = true
                    self.runtime.fireManualEvent(named: manualEventName)
                }, for: .touchUpInside)
                view.addSubview(startButton)
            }

            NSLayoutConstraint.activate([
                flowViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                flowViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                flowViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
                flowViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                statusLabel.widthAnchor.constraint(equalToConstant: 1),
                statusLabel.heightAnchor.constraint(equalToConstant: 1),
            ])

            if manualEventName != nil {
                NSLayoutConstraint.activate([
                    startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    startButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
                    startButton.widthAnchor.constraint(equalToConstant: 220),
                    startButton.heightAnchor.constraint(equalToConstant: 52),
                ])
            }
        }
    }

    private actor FlowRuntimeFixtureRunnerBridge {
        private let runner: JourneyRunner
        private var didHandleReady = false
        private var currentScreenId: String?

        init(runner: JourneyRunner) {
            self.runner = runner
        }

        func handleReady() async -> JourneyRunner.RunOutcome? {
            guard !didHandleReady else { return nil }
            didHandleReady = true
            return await runner.handleRuntimeReady()
        }

        func handleScreenChanged(_ screenId: String) async -> JourneyRunner.RunOutcome? {
            currentScreenId = screenId
            return await runner.handleScreenChanged(screenId)
        }

        func handleScreenDismissed(
            _ screenId: String,
            revealingScreenId: String?
        ) async -> JourneyRunner.RunOutcome? {
            currentScreenId = revealingScreenId
            return await runner.handleScreenDismissed(
                screenId,
                revealingScreenId: revealingScreenId,
                method: "native_sheet"
            )
        }

        func handleEvent(_ event: ExperienceRendererEvent) async -> JourneyRunner.RunOutcome? {
            let runtimeEvent = NuxieEvent(
                name: event.name,
                distinctId: "fixture-distinct-id",
                properties: event.properties
            )
            return await runner.dispatchScreenEvent(
                runtimeEvent,
                screenId: event.screenId ?? currentScreenId,
                componentId: event.componentId,
                instanceId: event.instanceId
            )
        }

        func handleManualEvent(_ eventName: String) async -> JourneyRunner.RunOutcome? {
            let runtimeEvent = NuxieEvent(
                name: eventName,
                distinctId: "fixture-distinct-id",
                properties: [:]
            )
            return await runner.dispatchJourneyEvent(runtimeEvent)
        }
    }

    private final class FlowRuntimeFixtureExecutionRuntime: FlowRuntimeDelegate {
        private let bridge: FlowRuntimeFixtureRunnerBridge
        private weak var flowViewController: ExperienceViewController?
        weak var statusLabel: UILabel?
        var statusObserver: (@MainActor (String) -> Void)?

        init(
            flow: Experience,
            flowViewController: ExperienceViewController,
            initialNavigationStack: [String],
            runnerDependencies: FixtureRunnerDependencies
        ) {
            let campaign = Campaign(
                id: "fixture-campaign",
                name: "Fixture Campaign",
                flowId: flow.screens.id,
                flowNumber: 1,
                flowName: "Fixture Experience",
                reentry: .everyTime,
                publishedAt: ISO8601DateFormatter().string(from: Date()),
                trigger: .event(EventTriggerConfig(eventName: "fixture", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                campaignType: nil
            )
            let journey = Journey(
                id: "fixture-journey",
                campaign: campaign,
                distinctId: "fixture-distinct-id",
                now: Date()
            )
            journey.flowState.navigationStack = initialNavigationStack
            let runner = JourneyRunner(
                journey: journey,
                campaign: campaign,
                flow: flow,
                eventLog: runnerDependencies.eventLog,
                identity: runnerDependencies.identity,
                segments: runnerDependencies.segments,
                features: runnerDependencies.features,
                profile: runnerDependencies.profile,
                apiClient: runnerDependencies.api,
                dateProvider: runnerDependencies.dateProvider,
                irRuntime: runnerDependencies.irRuntime
            )
            self.flowViewController = flowViewController
            self.bridge = FlowRuntimeFixtureRunnerBridge(runner: runner)
            Task {
                await runner.attach(viewController: flowViewController)
                await runner.setOnShowScreen { [weak self] screenId, transition in
                    await self?.showScreen(screenId, transition: transition?.value)
                }
            }
            flowViewController.runtimeDelegate = self
        }

        func flowViewControllerDidBecomeReady(_ controller: ExperienceViewController) {
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(await bridge.handleReady())
            }
        }

        func fireManualEvent(named eventName: String) {
            setStatus("manual_event:\(eventName)")
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(await bridge.handleManualEvent(eventName))
            }
        }

        func flowViewController(
            _ controller: ExperienceViewController,
            didChangeScreen screenId: String
        ) {
            setStatus("screen:\(screenId)")
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(await bridge.handleScreenChanged(screenId))
            }
        }

        func flowViewController(
            _ controller: ExperienceViewController,
            didDismissScreen screenId: String,
            revealingScreenId: String?
        ) {
            if let revealingScreenId {
                setStatus("screen_dismissed:\(screenId) | screen:\(revealingScreenId)")
            } else {
                setStatus("screen_dismissed:\(screenId)")
            }
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(
                    await bridge.handleScreenDismissed(
                        screenId,
                        revealingScreenId: revealingScreenId
                    )
                )
            }
        }

        func flowViewController(
            _ controller: ExperienceViewController,
            didEmitEvent event: ExperienceRendererEvent
        ) {
            setStatus("event:\(event.name)")
            Task { [bridge, weak self] in
                guard let self else { return }
                await self.handleOutcome(await bridge.handleEvent(event))
            }
        }

        func flowViewControllerDidRequestDismiss(_ controller: ExperienceViewController, reason: CloseReason) {
            setStatus("dismissed:\(String(describing: reason))")
        }

        private func setStatus(_ text: String) {
            Task { @MainActor [weak self] in
                self?.appendStatus(text)
            }
        }

        @MainActor
        private func showScreen(_ screenId: String, transition: Any?) {
            flowViewController?.navigate(to: screenId, transition: transition)
            appendStatus("navigated:\(screenId)")
        }

        @MainActor
        private func appendStatus(_ text: String) {
            guard let statusLabel else { return }
            let currentText = statusLabel.text ?? ""
            if currentText.isEmpty || currentText == "ready" {
                statusLabel.text = text
            } else {
                statusLabel.text = "\(currentText) | \(text)"
            }
            statusObserver?(statusLabel.text ?? text)
        }

        @MainActor
        private func handleOutcome(_ outcome: JourneyRunner.RunOutcome?) {
            guard let outcome else { return }
            switch outcome {
            case .paused:
                appendStatus("paused")
            case .exited(let reason):
                appendStatus("exited:\(reason.rawValue)")
            }
        }
    }

    private static func prepareFixtureBaseURL(
        _ fixtureBaseURL: URL,
        cacheRootURL: URL
    ) throws -> URL {
        let manifestURL = fixtureBaseURL.appendingPathComponent(ExperienceArtifactStore.manifestPath)
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        guard manifestText.contains(fixtureBaseURLToken) else {
            return fixtureBaseURL
        }

        let preparedBaseURL = cacheRootURL.appendingPathComponent(
            "prepared-fixture",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: preparedBaseURL)
        try FileManager.default.createDirectory(
            at: preparedBaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureBaseURL, to: preparedBaseURL)

        let replacementBaseURL = preparedBaseURL.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let preparedManifestText = manifestText.replacingOccurrences(
            of: fixtureBaseURLToken,
            with: replacementBaseURL
        )
        try preparedManifestText.write(
            to: preparedBaseURL.appendingPathComponent(ExperienceArtifactStore.manifestPath),
            atomically: true,
            encoding: .utf8
        )
        return preparedBaseURL
    }

    private static func makeFixtureConfiguration(cacheRootURL: URL) -> NuxieConfiguration {
        let configuration = NuxieConfiguration(apiKey: "flow-runtime-fixture")
        configuration.environment = .development
        configuration.customStoragePath = cacheRootURL.appendingPathComponent("sdk-storage")
        configuration.logLevel = .debug
        configuration.enableConsoleLogging = true
        configuration.trackApplicationLifecycleEvents = false
        return configuration
    }

    private static func buildFiles(
        for manifest: FlowArtifactManifest,
        manifestData: Data,
        fixtureBaseURL: URL
    ) throws -> [BuildFile] {
        var files = [
            BuildFile(
                path: ExperienceArtifactStore.manifestPath,
                size: manifestData.count,
                contentType: "application/json"
            ),
            BuildFile(
                path: manifest.riv.path,
                size: try fileSize(forRelativePath: manifest.riv.path, fixtureBaseURL: fixtureBaseURL),
                contentType: "application/octet-stream"
            ),
        ]

        for image in manifest.assets.images {
            files.append(
                BuildFile(
                    path: image.path,
                    size: try fileSize(forRelativePath: image.path, fixtureBaseURL: fixtureBaseURL),
                    contentType: image.contentType
                )
            )
        }

        return files
    }

    private static func contentHash(
        for manifest: FlowArtifactManifest,
        manifestData: Data,
        fixtureBaseURL: URL
    ) -> String {
        var data = Data()
        data.append(manifestData)
        if let rivData = try? Data(contentsOf: fixtureBaseURL.appendingPathComponent(manifest.riv.path)) {
            data.append(rivData)
        }
        for image in manifest.assets.images {
            if let imageData = try? Data(contentsOf: fixtureBaseURL.appendingPathComponent(image.path)) {
                data.append(imageData)
            }
        }
        return ExperienceArtifactStore.sha256Hex(data)
    }

    private static func fileSize(forRelativePath path: String, fixtureBaseURL: URL) throws -> Int {
        let safePath = try ExperienceArtifactStore.validateRelativePath(path)
        return try Data(contentsOf: fixtureBaseURL.appendingPathComponent(safePath)).count
    }
}
#endif
