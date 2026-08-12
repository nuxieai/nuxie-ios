import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit) && DEBUG
/// Debug-only host for committed signed `.nux` fixtures.
public enum ExperienceRuntimeFixtureHost {
    @MainActor
    public static func makeViewController(
        fixtureBaseURL: URL,
        cacheRootURL: URL,
        experienceId: String? = nil,
        initialScreenID: String? = nil,
        initialNavigationStack: [String] = [],
        scriptTrustPublicKeysBase64ByKeyId: [String: String] = [:],
        statusObserver: (@MainActor (String) -> Void)? = nil
    ) throws -> UIViewController {
        let packageURL = fixtureBaseURL.appendingPathComponent("experience.nux")
        let read = try BoundedFileIO.read(
            at: packageURL,
            maximumBytes: NuxPackageLimits.packageBytes
        )
        let contents = try NuxPackageReader.read(read.data)
        let remote = RemoteExperience(
            experienceId: experienceId ?? contents.metadata.identity.experienceId,
            versionId: contents.metadata.identity.buildId,
            buildId: contents.metadata.identity.buildId,
            artifact: RemoteExperienceArtifact(
                url: packageURL.absoluteString,
                sha256: read.digest.sha256,
                sizeBytes: read.digest.byteCount
            ),
            name: contents.metadata.identity.experienceId,
            reentry: .everyTime,
            publishedAt: ""
        )
        let keys: [ExperiencePackageAuthorizationKey]
        if scriptTrustPublicKeysBase64ByKeyId.isEmpty {
            keys = try ExperienceTrustRoots.keys(for: .development)
        } else {
            keys = try scriptTrustPublicKeysBase64ByKeyId.map { keyId, value in
                guard let data = Data(base64Encoded: value), data.count == 32 else {
                    throw ExperienceTrustRootError.malformed(.development)
                }
                return ExperiencePackageAuthorizationKey(
                    keyID: keyId,
                    ed25519PublicKeyBytes: data
                )
            }
        }
        let store = ExperiencePackageStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("packages"),
            assetCacheDirectory: cacheRootURL.appendingPathComponent("assets"),
            authorizationKeys: keys
        )
        return ExperiencePackageFixtureLoadingViewController(
            remote: remote,
            assetBaseURL: fixtureBaseURL,
            packageStore: store,
            cacheRootURL: cacheRootURL,
            initialScreenID: initialScreenID,
            initialNavigationStack: initialNavigationStack,
            statusObserver: statusObserver
        )
    }
}

@MainActor
private final class ExperiencePackageFixtureLoadingViewController: UIViewController {
    private let remote: RemoteExperience
    private let assetBaseURL: URL
    private let packageStore: ExperiencePackageStore
    private let cacheRootURL: URL
    private let initialScreenID: String?
    private let initialNavigationStack: [String]
    private let statusObserver: (@MainActor (String) -> Void)?
    private var task: Task<Void, Never>?

    init(
        remote: RemoteExperience,
        assetBaseURL: URL,
        packageStore: ExperiencePackageStore,
        cacheRootURL: URL,
        initialScreenID: String?,
        initialNavigationStack: [String],
        statusObserver: (@MainActor (String) -> Void)?
    ) {
        self.remote = remote
        self.assetBaseURL = assetBaseURL
        self.packageStore = packageStore
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
                statusObserver?("loading")
                let acquisition = try await packageStore.getOrDownloadPackage(
                    for: remote,
                    assetBaseURL: assetBaseURL
                )
                try Task.checkCancellation()
                let payload = try await SwiftExperiencePackageAuthenticator()
                    .authenticate(acquisition)
                let package = LoadedExperiencePackage(
                    acquired: acquisition,
                    payload: payload
                )
                let child = try makeExperienceViewController(package: package)
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
        // Keep teardown nonisolated. The concurrency back-deploy thunk used by
        // `isolated deinit` invalid-frees task-local state on older simulators.
        task?.cancel()
    }

    private func makeExperienceViewController(
        package: LoadedExperiencePackage
    ) throws -> ExperienceViewController {
        let configuration = NuxieConfiguration(apiKey: "fixture")
        configuration.environment = .development
        configuration.apiEndpoint = URL(string: "http://127.0.0.1")!
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
            transactionObserver: FixtureTransactionObserver(),
            pendingPurchaseStore: PendingPurchaseStore(
                customStoragePath: cacheRootURL
            ),
            dateProvider: SystemDateProvider(),
            settings: NuxieRuntimeSettings(configuration: configuration),
            eventSink: systemEvents
        )
        let experience = Experience(
            remote: remote,
            journey: package.journey,
            assetBaseURL: assetBaseURL
        )
        let controller = ExperienceViewController(
            experience: experience,
            packageStore: packageStore,
            eventLog: eventLog,
            transactionService: transactionService,
            productService: productService,
            systemEventSink: systemEvents
        )
        if let initialScreenID {
            controller.navigate(to: initialScreenID)
        }
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
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

private actor FixtureTransactionObserver: TransactionObserverProtocol {
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
#endif
