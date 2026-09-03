import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// Nuxie Companion host for an exact signed release profile.
@_spi(Companion) public enum JourneyPreviewHost {
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
        try JourneyFixtureHost.makeViewController(
            profileData: profileData,
            cacheRootURL: cacheRootURL,
            environment: environment,
            urlSession: urlSession,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            presentationDiagnosticsEnabled: false,
            statusObserver: statusObserver
        )
    }
}

/// Test host for committed descriptor-native release fixtures.
@_spi(Testing) public enum JourneyFixtureHost {
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
        try makeViewController(
            fixtureBaseURL: fixtureBaseURL,
            cacheRootURL: cacheRootURL,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            presentationDiagnosticsEnabled: true,
            statusObserver: statusObserver
        )
    }

    /// Builds a fixture view controller with explicit qualification diagnostics.
    /// - Parameters:
    ///   - presentationDiagnosticsEnabled: Enables qualification diagnostics
    ///     for this explicitly constructed fixture host.
    @MainActor
    public static func makeViewController(
        fixtureBaseURL: URL,
        cacheRootURL: URL,
        initialScreenID: String? = nil,
        initialNavigationStack: [String] = [],
        presentationDiagnosticsEnabled: Bool,
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
            presentationDiagnosticsEnabled: presentationDiagnosticsEnabled,
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
        try makeViewController(
            profileData: profileData,
            cacheRootURL: cacheRootURL,
            environment: environment,
            urlSession: urlSession,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            presentationDiagnosticsEnabled: true,
            statusObserver: statusObserver
        )
    }

    /// Builds a fixture view controller with explicit qualification diagnostics.
    /// - Parameters:
    ///   - presentationDiagnosticsEnabled: Enables qualification diagnostics
    ///     for this explicitly constructed fixture host.
    @MainActor
    public static func makeViewController(
        profileData: Data,
        cacheRootURL: URL,
        environment: Environment = .development,
        urlSession: URLSession = .shared,
        initialScreenID: String? = nil,
        initialNavigationStack: [String] = [],
        presentationDiagnosticsEnabled: Bool,
        statusObserver: (@MainActor (String) -> Void)? = nil
    ) throws -> UIViewController {
        guard profileData.count <= JourneyReleaseLimits.profileBytes else {
            throw JourneyFixtureHostError.invalidProfile
        }
        return try makeViewController(
            profile: decodeProfile(profileData),
            cacheRootURL: cacheRootURL,
            environment: environment,
            urlSession: urlSession,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            presentationDiagnosticsEnabled: presentationDiagnosticsEnabled,
            statusObserver: statusObserver
        )
    }

    private static func decodeProfile(_ data: Data) throws -> JourneyPlaneProfile {
        try JourneyPlaneProfile.decode(data)
    }

    @MainActor
    private static func makeViewController(
        profile: JourneyPlaneProfile,
        cacheRootURL: URL,
        environment: Environment,
        urlSession: URLSession,
        initialScreenID: String?,
        initialNavigationStack: [String],
        presentationDiagnosticsEnabled: Bool = false,
        statusObserver: (@MainActor (String) -> Void)?
    ) throws -> UIViewController {
        JourneyFixtureLoadingViewController(
            inputs: try PresentationInputs(
                profile: profile,
                cacheRootURL: cacheRootURL,
                environment: environment,
                urlSession: urlSession,
                presentationDiagnosticsEnabled: presentationDiagnosticsEnabled
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
        struct AuthenticatedFixture {
            let snapshot: JourneyProfileCatalog.Snapshot
            let release: AuthenticatedJourneyRelease
            let presentation: PreparedJourneyPresentation
        }

        let profile: JourneyPlaneProfile
        let authority: ProfileDeliveryAuthority
        let profileCatalog: JourneyProfileCatalog
        let acquisitionStore: JourneyReleaseAcquisitionStore
        let cacheRootURL: URL
        let environment: Environment
        let presentationDiagnosticsEnabled: Bool

        init(
            profile: JourneyPlaneProfile,
            cacheRootURL: URL,
            environment: Environment,
            urlSession: URLSession,
            presentationDiagnosticsEnabled: Bool = false
        ) throws {
            self.profile = profile
            self.cacheRootURL = cacheRootURL
            self.environment = environment
            self.presentationDiagnosticsEnabled = presentationDiagnosticsEnabled
            guard let locator = profile.releases.first?.locator else {
                throw JourneyFixtureHostError.invalidProfile
            }
            authority = ProfileDeliveryAuthority(
                appId: locator.appId,
                environment: locator.environment
            )
            profileCatalog = JourneyProfileCatalog(
                authorizationKeys: try JourneyTrustRoots.keys(for: environment),
                supportedRuntime: JourneyReleaseRuntime.current,
                highWaterStore: InMemoryJourneyReleaseHighWaterStore()
            )
            acquisitionStore = JourneyReleaseAcquisitionStore(
                cacheDirectory: cacheRootURL.appendingPathComponent(
                    "objects",
                    isDirectory: true
                ),
                urlSession: urlSession
            )
        }

        func authenticate() async throws -> AuthenticatedFixture {
            guard profile.releases.count == 1,
                  profile.armedLegs.count == 1,
                  let arm = profile.armedLegs.first else {
                throw JourneyFixtureHostError.invalidProfile
            }
            let prepared = try await profileCatalog.prepare(
                profile,
                authority: authority
            )
            guard try await profileCatalog.commit(
                prepared,
                distinctId: "journey-fixture"
            ), let release = prepared.snapshot.releasesByDigest[
                arm.reference.descriptorSha256
            ] else {
                throw JourneyFixtureHostError.invalidProfile
            }
            let presentation = try await acquisitionStore.preparePresentation(
                release: release,
                delivery: profile.delivery,
                productResolver: { _ in [] }
            )
            return AuthenticatedFixture(
                snapshot: prepared.snapshot,
                release: release,
                presentation: presentation
            )
        }

        func resolveInitialScreenID(
            fixture: AuthenticatedFixture
        ) throws -> String {
            let journey = fixture.release.descriptor.leg
            if let entry = journey.steps.first(where: {
                $0.id == journey.entryStepId
            }), case .string(let screenID)? = entry.action?["screenId"] {
                return screenID
            }
            guard journey.screens.count == 1,
                  let screenID = journey.screens.first?.id else {
                throw JourneyFixtureHostError.invalidProfile
            }
            return screenID
        }

        func acquire(
            fixture: AuthenticatedFixture,
            initialScreenID: String
        ) async throws -> AcquiredExperienceArtifact {
            try await fixture.presentation.artifactLoader(
                fixture.presentation.experience,
                nil,
                initialScreenID
            )
        }

        func makeViewController(
            fixture: AuthenticatedFixture,
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
                dateProvider: SystemDateProvider(),
                apiClient: api
            )
            let productService = ProductService()
            let systemEvents = DiscardingSystemEventSink()
            let transactionService = TransactionService(
                productService: productService,
                transactionObserver: JourneyFixtureTransactionObserver(),
                pendingPurchaseStore: PendingPurchaseStore(customStoragePath: cacheRootURL),
                dateProvider: SystemDateProvider(),
                settings: NuxieRuntimeSettings(configuration: configuration),
                eventSink: systemEvents
            )
            let experience = fixture.presentation.experience
            return ExperienceViewController(
                experience: experience,
                artifactLoader: artifactLoader,
                artifactTelemetryContext: .from(experience: experience),
                eventLog: eventLog,
                presentationDiagnosticsEnabled: presentationDiagnosticsEnabled,
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
    ) throws -> (JourneyPlaneProfile, URLSession) {
        let read = try BoundedFileIO.read(
            at: fixtureBaseURL.appendingPathComponent("profile.json"),
            maximumBytes: JourneyReleaseLimits.profileBytes
        )
        let profile = try decodeProfile(read.data)
        let deliveryHosts = [
            profile.delivery.renderBaseUrl,
            profile.delivery.assetBaseUrl,
        ].compactMap { URL(string: $0)?.host }
        guard deliveryHosts.count == 2 else {
            throw JourneyFixtureHostError.invalidProfile
        }
        for host in Set(deliveryHosts) {
            JourneyFixtureURLProtocol.register(
                fixtureBaseURL: fixtureBaseURL,
                forHost: host
            )
        }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [JourneyFixtureURLProtocol.self]
        return (profile, URLSession(configuration: sessionConfiguration))
    }
}

@MainActor
private final class JourneyFixtureLoadingViewController: UIViewController {
    private let inputs: JourneyFixtureHost.PresentationInputs
    private let initialScreenID: String?
    private let initialNavigationStack: [String]
    private let statusObserver: (@MainActor (String) -> Void)?
    private var task: Task<Void, Never>?

    init(
        inputs: JourneyFixtureHost.PresentationInputs,
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
                let fixture = try await inputs.authenticate()
                let selectedScreenID: String
                if let initialScreenID {
                    selectedScreenID = initialScreenID
                } else {
                    selectedScreenID = try inputs.resolveInitialScreenID(
                        fixture: fixture
                    )
                }
                statusObserver?("acquiring")
                let artifact = try await inputs.acquire(
                    fixture: fixture,
                    initialScreenID: selectedScreenID
                )
                try Task.checkCancellation()
                install(makeExperienceViewController(
                    fixture: fixture,
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
        fixture: JourneyFixtureHost.PresentationInputs.AuthenticatedFixture,
        artifact: AcquiredExperienceArtifact
    ) -> ExperienceViewController {
        let controller = inputs.makeViewController(
            fixture: fixture,
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

private final class JourneyFixtureURLProtocol: URLProtocol, @unchecked Sendable {
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
            client?.urlProtocol(self, didFailWithError: JourneyFixtureHostError.invalidURL)
            return
        }
        let relativePath = url.path.drop(while: { $0 == "/" })
        let fileURL = fixtureBaseURL.appendingPathComponent(String(relativePath))
        do {
            let read = try BoundedFileIO.read(
                at: fileURL,
                maximumBytes: JourneyReleaseLimits.artifactAggregateBytes
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
                throw JourneyFixtureHostError.invalidURL
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

private actor JourneyFixtureTransactionObserver: TransactionObserverProtocol {
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

private enum JourneyFixtureHostError: LocalizedError {
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
