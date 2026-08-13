import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit) && DEBUG
/// Debug-only host for committed descriptor-native release fixtures.
@_spi(Testing) public enum ExperienceReleaseFixtureHost {
    /// Builds a view controller from an exact signed profile and its local
    /// content-addressed fixture objects.
    @MainActor
    public static func makeViewController(
        fixtureBaseURL: URL,
        cacheRootURL: URL,
        initialScreenID: String? = nil,
        initialNavigationStack: [String] = [],
        statusObserver: (@MainActor (String) -> Void)? = nil
    ) throws -> UIViewController {
        let profileURL = fixtureBaseURL.appendingPathComponent("profile.json")
        let read = try BoundedFileIO.read(
            at: profileURL,
            maximumBytes: 4 * 1_024 * 1_024
        )
        try StrictJSONDuplicateKeyValidator.validate(read.data)
        let profile = try JSONDecoder().decode(
            ExperienceReleaseProfileV1.self,
            from: read.data
        )
        guard let deliveryOrigin = URL(string: profile.delivery.renderBaseUrl),
              let host = deliveryOrigin.host else {
            throw ExperienceReleaseFixtureHostError.invalidProfile
        }
        ExperienceReleaseFixtureURLProtocol.register(
            fixtureBaseURL: fixtureBaseURL,
            forHost: host
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ExperienceReleaseFixtureURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let keys = try ExperienceTrustRoots.keys(for: .development)
        let store = ExperienceReleaseAcquisitionStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("objects", isDirectory: true),
            urlSession: session,
            authorizationKeys: keys,
            supportedCompatibility: ExperienceReleaseRuntimeCompatibility.current,
            admission: ExperienceReleaseAdmission(
                store: InMemoryExperienceReleaseHighWaterStore()
            )
        )
        return ExperienceReleaseFixtureLoadingViewController(
            profile: profile,
            acquisitionStore: store,
            cacheRootURL: cacheRootURL,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            statusObserver: statusObserver
        )
    }
}

@MainActor
private final class ExperienceReleaseFixtureLoadingViewController: UIViewController {
    private let profile: ExperienceReleaseProfileV1
    private let acquisitionStore: ExperienceReleaseAcquisitionStore
    private let cacheRootURL: URL
    private let initialScreenID: String?
    private let initialNavigationStack: [String]
    private let statusObserver: (@MainActor (String) -> Void)?
    private var task: Task<Void, Never>?

    init(
        profile: ExperienceReleaseProfileV1,
        acquisitionStore: ExperienceReleaseAcquisitionStore,
        cacheRootURL: URL,
        initialScreenID: String?,
        initialNavigationStack: [String],
        statusObserver: (@MainActor (String) -> Void)?
    ) {
        self.profile = profile
        self.acquisitionStore = acquisitionStore
        self.cacheRootURL = cacheRootURL
        self.initialScreenID = initialScreenID
        self.initialNavigationStack = initialNavigationStack
        self.statusObserver = statusObserver
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        task = Task { [weak self] in
            guard let self else { return }
            do {
                statusObserver?("authenticating")
                let catalog = try await acquisitionStore.authenticateProfile(profile)
                guard catalog.definitions.count == 1,
                      let definition = catalog.definitions.first else {
                    throw ExperienceReleaseFixtureHostError.invalidProfile
                }
                let selectedScreenID = initialScreenID
                    ?? definition.journey.screens.first?.id
                guard let selectedScreenID else {
                    throw ExperienceReleaseFixtureHostError.missingScreen
                }
                statusObserver?("acquiring")
                let artifact = try await acquisitionStore.presentationArtifact(
                    definition: definition,
                    initialScreenID: selectedScreenID
                )
                try Task.checkCancellation()
                let child = try makeExperienceViewController(
                    definition: definition,
                    artifact: artifact,
                    selectedScreenID: selectedScreenID
                )
                install(child)
                statusObserver?("ready")
            } catch {
                guard !Task.isCancelled else { return }
                installFailure(error)
                statusObserver?("error")
            }
        }
    }

    deinit {
        task?.cancel()
    }

    private func makeExperienceViewController(
        definition: AuthenticatedExperienceReleaseDefinition,
        artifact: AcquiredExperienceArtifact,
        selectedScreenID: String
    ) throws -> ExperienceViewController {
        guard let apiEndpoint = URL(string: "http://127.0.0.1"),
              let assetBaseURL = URL(string: definition.delivery.assetBaseUrl) else {
            throw ExperienceReleaseFixtureHostError.invalidURL
        }
        let configuration = NuxieConfiguration(apiKey: "fixture")
        configuration.environment = .development
        configuration.apiEndpoint = apiEndpoint
        configuration.customStoragePath = cacheRootURL
        let api = NuxieApi(
            apiKey: configuration.apiKey,
            baseURL: configuration.apiEndpoint,
            useGzipCompression: false,
            urlSession: configuration.urlSession
        )
        let identity = IdentityService(customStoragePath: cacheRootURL)
        let eventLog = EventLog(
            identity: identity,
            sessions: SessionService(),
            dateProvider: SystemDateProvider(),
            apiClient: api
        )
        let productService = ProductService()
        let systemEvents = DiscardingSystemEventSink()
        let transactionService = TransactionService(
            productService: productService,
            transactionObserver: ExperienceReleaseFixtureTransactionObserver(),
            pendingPurchaseStore: PendingPurchaseStore(customStoragePath: cacheRootURL),
            dateProvider: SystemDateProvider(),
            settings: NuxieRuntimeSettings(configuration: configuration),
            eventSink: systemEvents
        )
        let experience = Experience(
            behavior: definition.behavior,
            journey: definition.journey,
            assetBaseURL: assetBaseURL,
            authenticatedReleaseID: definition.releaseID
        )
        let controller = ExperienceViewController(
            experience: experience,
            artifactLoader: { _, _, _ in artifact },
            artifactTelemetryContext: .from(experience: experience),
            eventLog: eventLog,
            transactionService: transactionService,
            productService: productService,
            systemEventSink: systemEvents
        )
        controller.navigate(to: selectedScreenID)
        for screenID in initialNavigationStack {
            controller.navigate(to: screenID)
        }
        return controller
    }

    private func install(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func installFailure(_ error: Error) {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = error.localizedDescription
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

private final class ExperienceReleaseFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtureBaseURLByHost: [String: URL] = [:]

    static func register(fixtureBaseURL: URL, forHost host: String) {
        lock.lock()
        fixtureBaseURLByHost[host] = fixtureBaseURL.standardizedFileURL
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https" && fixtureBaseURL(for: request.url?.host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let fixtureBaseURL = Self.fixtureBaseURL(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: ExperienceReleaseFixtureHostError.invalidURL)
            return
        }
        let relativePath = url.path.drop(while: { $0 == "/" })
        let fileURL = fixtureBaseURL.appendingPathComponent(String(relativePath))
        do {
            let read = try BoundedFileIO.read(
                at: fileURL,
                maximumBytes: ExperienceReleaseDescriptorLimits.artifactAggregateBytes
            )
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": Self.contentType(for: fileURL.pathExtension),
                    "Content-Length": String(read.data.count),
                ]
            ) else {
                throw ExperienceReleaseFixtureHostError.invalidURL
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: read.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func fixtureBaseURL(for host: String?) -> URL? {
        guard let host else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fixtureBaseURLByHost[host]
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "riv": "application/vnd.rive"
        case "png": "image/png"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "bin": "application/octet-stream"
        default: "application/octet-stream"
        }
    }
}

private actor ExperienceReleaseFixtureTransactionObserver: TransactionObserverProtocol {
    func startListening() {}
    func stopListening() {}
    func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool {
        false
    }
    func syncCurrentEntitlements() async {}
}

private enum ExperienceReleaseFixtureHostError: LocalizedError {
    case invalidProfile
    case missingScreen
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidProfile: "Invalid signed release fixture profile"
        case .missingScreen: "Signed release fixture has no declared screen"
        case .invalidURL: "Signed release fixture URL is invalid"
        }
    }
}
#endif
