import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// Nuxie Companion host for an exact signed release profile.
@_spi(Companion) public enum ExperienceReleasePreviewHost {
    /// Authenticates the profile, acquires its content-addressed objects, and
    /// builds the ordinary native experience controller.
    @MainActor
    public static func makeViewController(
        profileData: Data,
        cacheRootURL: URL,
        environment: Environment,
        urlSession: URLSession = .shared,
        initialScreenID: String? = nil,
        initialNavigationStack: [String] = [],
        statusObserver: (@MainActor (String) -> Void)? = nil
    ) throws -> UIViewController {
        try ExperienceReleaseFixtureHost.makeViewController(
            profileData: profileData,
            cacheRootURL: cacheRootURL,
            environment: environment,
            urlSession: urlSession,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            statusObserver: statusObserver
        )
    }
}

/// Test host for committed descriptor-native release fixtures.
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
        let (profile, session) = try registeredFixtureProfile(at: fixtureBaseURL)
        return try makeViewController(
            profile: profile,
            cacheRootURL: cacheRootURL,
            environment: .development,
            urlSession: session,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            statusObserver: statusObserver
        )
    }

    /// Builds a view controller from exact signed profile bytes and the
    /// profile's authenticated HTTPS delivery origins.
    @MainActor
    public static func makeViewController(
        profileData: Data,
        cacheRootURL: URL,
        environment: Environment = .development,
        urlSession: URLSession = .shared,
        initialScreenID: String? = nil,
        initialNavigationStack: [String] = [],
        statusObserver: (@MainActor (String) -> Void)? = nil
    ) throws -> UIViewController {
        guard profileData.count <= ExperienceReleaseDescriptorLimits.profileBytes else {
            throw ExperienceReleaseFixtureHostError.invalidProfile
        }
        return try makeViewController(
            profile: decodeProfile(profileData),
            cacheRootURL: cacheRootURL,
            environment: environment,
            urlSession: urlSession,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            statusObserver: statusObserver
        )
    }

    private static func decodeProfile(_ data: Data) throws -> ExperienceReleaseProfile {
        try StrictJSONDuplicateKeyValidator.validate(data)
        return try JSONDecoder().decode(ExperienceReleaseProfile.self, from: data)
    }

    @MainActor
    private static func makeViewController(
        profile: ExperienceReleaseProfile,
        cacheRootURL: URL,
        environment: Environment,
        urlSession: URLSession,
        initialScreenID: String?,
        initialNavigationStack: [String],
        statusObserver: (@MainActor (String) -> Void)?
    ) throws -> UIViewController {
        ExperienceReleaseFixtureLoadingViewController(
            inputs: try PresentationInputs(
                profile: profile,
                cacheRootURL: cacheRootURL,
                environment: environment,
                urlSession: urlSession
            ),
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            statusObserver: statusObserver
        )
    }

    /// Builds the authenticate/resolve/acquire/construct steps for a fixture
    /// as separately callable pieces.
    ///
    /// The embedded fixture host runs them start to finish, while presentation
    /// review needs to interleave them with an artificial acquisition
    /// condition. Sharing one value keeps both on the same authenticated path
    /// instead of growing a second construction route.
    @MainActor
    static func makePresentationInputs(
        fixtureBaseURL: URL,
        cacheRootURL: URL
    ) throws -> PresentationInputs {
        let (profile, session) = try registeredFixtureProfile(at: fixtureBaseURL)
        return try PresentationInputs(
            profile: profile,
            cacheRootURL: cacheRootURL,
            environment: .development,
            urlSession: session
        )
    }

    @MainActor
    struct PresentationInputs {
        let profile: ExperienceReleaseProfile
        let acquisitionStore: ExperienceReleaseAcquisitionStore
        let cacheRootURL: URL
        let environment: Environment

        init(
            profile: ExperienceReleaseProfile,
            cacheRootURL: URL,
            environment: Environment,
            urlSession: URLSession
        ) throws {
            self.profile = profile
            self.cacheRootURL = cacheRootURL
            self.environment = environment
            acquisitionStore = ExperienceReleaseAcquisitionStore(
                cacheDirectory: cacheRootURL.appendingPathComponent(
                    "objects",
                    isDirectory: true
                ),
                urlSession: urlSession,
                authorizationKeys: try ExperienceTrustRoots.keys(for: environment),
                supportedRuntime: ExperienceReleaseRuntime.current,
                admission: ExperienceReleaseAdmission(
                    store: InMemoryExperienceReleaseHighWaterStore()
                )
            )
        }

        func authenticate() async throws -> AuthenticatedExperienceReleaseDefinition {
            let catalog = try await acquisitionStore.authenticateProfile(profile)
            guard catalog.definitions.count == 1,
                  let definition = catalog.definitions.first else {
                throw ExperienceReleaseFixtureHostError.invalidProfile
            }
            return definition
        }

        func resolveInitialScreenID(
            definition: AuthenticatedExperienceReleaseDefinition
        ) async throws -> String {
            try await ExperienceReleaseInitialPresentationResolver.resolve(
                definition: definition,
                cacheRootURL: cacheRootURL,
                environment: environment
            )
        }

        func acquire(
            definition: AuthenticatedExperienceReleaseDefinition,
            initialScreenID: String
        ) async throws -> AcquiredExperienceArtifact {
            try await acquisitionStore.presentationArtifact(
                definition: definition,
                initialScreenID: initialScreenID
            )
        }

        func makeViewController(
            definition: AuthenticatedExperienceReleaseDefinition,
            artifactLoader: @escaping ExperienceArtifactLoader
        ) -> ExperienceViewController {
            let configuration = NuxieConfiguration(apiKey: "fixture")
            configuration.environment = environment
            // The fixture path never reaches a real API; a loopback endpoint
            // keeps the event pipeline constructible without network effects.
            let loopbackEndpoint = URL(string: "http://127.0.0.1")!
            let api = NuxieApi(
                apiKey: configuration.apiKey,
                baseURL: loopbackEndpoint,
                useGzipCompression: false,
                urlSession: nil
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
                assetBaseURL: URL(string: definition.delivery.assetBaseUrl)
                    ?? loopbackEndpoint,
                authenticatedReleaseID: definition.releaseID
            )
            return ExperienceViewController(
                experience: experience,
                artifactLoader: artifactLoader,
                artifactTelemetryContext: .from(experience: experience),
                eventLog: eventLog,
                transactionService: transactionService,
                productService: productService,
                systemEventSink: systemEvents
            )
        }
    }

    /// Reads a committed fixture profile and routes its signed delivery origin
    /// at the on-disk fixture objects.
    @MainActor
    private static func registeredFixtureProfile(
        at fixtureBaseURL: URL
    ) throws -> (ExperienceReleaseProfile, URLSession) {
        let read = try BoundedFileIO.read(
            at: fixtureBaseURL.appendingPathComponent("profile.json"),
            maximumBytes: ExperienceReleaseDescriptorLimits.profileBytes
        )
        let profile = try decodeProfile(read.data)
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
        return (profile, URLSession(configuration: sessionConfiguration))
    }
}

@MainActor
private final class ExperienceReleaseFixtureLoadingViewController: UIViewController {
    private let inputs: ExperienceReleaseFixtureHost.PresentationInputs
    private let initialScreenID: String?
    private let initialNavigationStack: [String]
    private let statusObserver: (@MainActor (String) -> Void)?
    private var task: Task<Void, Never>?

    init(
        inputs: ExperienceReleaseFixtureHost.PresentationInputs,
        initialScreenID: String?,
        initialNavigationStack: [String],
        statusObserver: (@MainActor (String) -> Void)?
    ) {
        self.inputs = inputs
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
                let definition = try await inputs.authenticate()
                let selectedScreenID: String
                if let initialScreenID {
                    selectedScreenID = initialScreenID
                } else {
                    selectedScreenID = try await inputs.resolveInitialScreenID(
                        definition: definition
                    )
                }
                statusObserver?("acquiring")
                let artifact = try await inputs.acquire(
                    definition: definition,
                    initialScreenID: selectedScreenID
                )
                try Task.checkCancellation()
                install(makeExperienceViewController(
                    definition: definition,
                    artifact: artifact
                ))
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
        artifact: AcquiredExperienceArtifact
    ) -> ExperienceViewController {
        let controller = inputs.makeViewController(
            definition: definition,
            artifactLoader: { _, _, _ in artifact }
        )
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
    func stopListening() async {}
    func syncTransaction(
        transactionJws: String,
        transactionId: String,
        productId: String?,
        originalTransactionId: String?
    ) async -> Bool {
        false
    }
    func syncCurrentEntitlements(distinctId: String) async {}
    func purchaseCompletionEventId(transactionId: String) async -> String {
        "purchase-completed:test-fixture:test:appStore:\(transactionId)"
    }
}

private enum ExperienceReleaseFixtureHostError: LocalizedError {
    case invalidProfile
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidProfile: "Invalid signed release fixture profile"
        case .invalidURL: "Signed release fixture URL is invalid"
        }
    }
}
#endif
