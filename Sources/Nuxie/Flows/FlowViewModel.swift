import Foundation
import FactoryKit

struct FlowArtifactTelemetryContext {
    let artifactBuildId: String

    static func from(flow: Flow) -> FlowArtifactTelemetryContext {
        return FlowArtifactTelemetryContext(
            artifactBuildId: flow.remoteFlow.flowArtifact.buildId
        )
    }
}

/// View model for FlowViewController - handles business logic and state management
@MainActor
class FlowViewModel {
    typealias ArtifactLoader = (Flow) async throws -> LoadedFlowArtifact

    // MARK: - State
    
    enum State: Equatable {
        case loading
        case loaded
        case error
    }
    
    // MARK: - Properties
    
    private(set) var flow: Flow
    private(set) var products: [FlowProduct]
    private(set) var currentState: State = .loading {
        didSet {
            onStateChanged?(currentState)
        }
    }
    
    private let artifactLoader: ArtifactLoader
    private var artifactTelemetryContext: FlowArtifactTelemetryContext
    @Injected(\.eventService) private var eventService: EventServiceProtocol
    
    // MARK: - Bindings (Closures)
    
    /// Called when state changes
    var onStateChanged: ((State) -> Void)?

    /// Called synchronously whenever a new artifact load supersedes the prior one.
    var onLoadStarted: (() -> Void)?

    /// Called synchronously when the active load is cancelled or times out.
    /// The UI owner uses this to revoke any native import/session mount that
    /// began after artifact acquisition completed.
    var onLoadInvalidated: (() -> Void)?
    
    /// Called when products need to be injected
    
    /// Called when the native flow artifact is ready to mount.
    var onLoadArtifact: ((LoadedFlowArtifact) -> Void)?
    
    // MARK: - Timer
    
    private var loadingTimer: Timer?
    private let loadingTimeoutSeconds: TimeInterval
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var currentArtifactSource: FlowArtifactSource = .unknown
    private var hasRecordedArtifactLoadOutcome = false
    
    // MARK: - Initialization
    
    init(
        flow: Flow,
        artifactStore: FlowArtifactStore,
        artifactTelemetryContext: FlowArtifactTelemetryContext? = nil,
        loadingTimeoutSeconds: TimeInterval = 15.0,
        artifactLoader: ArtifactLoader? = nil
    ) {
        self.flow = flow
        self.products = flow.products
        self.artifactLoader = artifactLoader ?? { flow in
            try await artifactStore.getOrDownloadArtifact(for: flow)
        }
        self.loadingTimeoutSeconds = loadingTimeoutSeconds
        self.artifactTelemetryContext = artifactTelemetryContext ?? FlowArtifactTelemetryContext.from(flow: flow)
        LogDebug("FlowViewModel initialized for flow: \(flow.id)")
    }
    
    deinit {
        loadTask?.cancel()
        loadTask = nil
        loadingTimer?.invalidate()
        loadingTimer = nil
    }
    
    // MARK: - Public Methods
    
    /// Start loading the flow content
    func loadFlow() {
        // `onLoadStarted` below owns native-mount invalidation for this
        // superseding attempt, so do not notify twice while rotating the
        // artifact acquisition task.
        cancelLoading(notifyInvalidation: false)
        loadGeneration &+= 1
        let generation = loadGeneration
        let flow = flow
        let artifactLoader = artifactLoader

        currentState = .loading
        hasRecordedArtifactLoadOutcome = false
        currentArtifactSource = .unknown
        startLoadingTimeout(for: generation)
        onLoadStarted?()
        guard loadGeneration == generation else { return }

        loadTask = Task { @MainActor [weak self] in
            do {
                let artifact = try await artifactLoader(flow)
                try Task.checkCancellation()
                guard let self, self.loadGeneration == generation else { return }
                self.currentArtifactSource = artifact.source
                self.onLoadArtifact?(artifact)
                LogDebug(
                    "Loaded native flow artifact for flow \(flow.id): \(artifact.rivURL.path)"
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.loadGeneration == generation else {
                    return
                }
                self.currentArtifactSource = .unavailable
                self.recordArtifactLoadFailure(errorMessage: error.localizedDescription)
                self.cancelLoadingTimeout()
                self.currentState = .error
                LogError("Failed to load flow artifact \(flow.id): \(error)")
            }

            guard let self, self.loadGeneration == generation else { return }
            self.loadTask = nil
        }
    }

    /// Cancels the active acquisition without changing the visible load state.
    /// Repeated calls after the attempt is inactive are harmless.
    func cancelLoading(notifyInvalidation: Bool = true) {
        guard loadTask != nil || loadingTimer != nil else { return }
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        cancelLoadingTimeout()
        if notifyInvalidation {
            onLoadInvalidated?()
        }
    }
    
    /// Called when loading starts
    func handleLoadingStarted() {
        LogDebug("Started loading flow: \(flow.id)")
        currentState = .loading
    }
    
    /// Called when loading finishes successfully
    func handleLoadingFinished() {
        LogDebug("Finished loading flow: \(flow.id)")
        recordArtifactLoadSuccess()
        // The native coordinator is now the committed owner. Finishing its
        // acquisition timer must not invalidate that successful mount.
        cancelLoading(notifyInvalidation: false)
        currentState = .loaded
        
        // Trigger product injection
    }
    
    /// Called when loading fails
    func handleLoadingFailed(_ error: Error) {
        LogError("Failed to load flow \(flow.id): \(error)")
        recordArtifactLoadFailure(errorMessage: error.localizedDescription)
        // The controller reporting a native failure already revoked its mount.
        cancelLoading(notifyInvalidation: false)
        currentState = .error
    }

    func updateArtifactTelemetryContext(_ context: FlowArtifactTelemetryContext) {
        artifactTelemetryContext = context
    }
    
    /// Update products
    func updateProducts(_ newProducts: [FlowProduct]) {
        self.products = newProducts
        
        // If already loaded, inject the new products
        if case .loaded = currentState {
        }
        
        LogDebug("Updated products for flow: \(flow.id)")
    }
    
    /// Update the flow and reload if content has changed
    func updateFlowIfNeeded(_ newFlow: Flow) {
        // Check if the flow content has changed (using manifest hash)
        let hasContentChanged = flow.manifest.contentHash != newFlow.manifest.contentHash
        
        // Always update the flow reference
        self.flow = newFlow
        self.products = newFlow.products
        
        // If content or URL changed, reload the native artifact.
        if hasContentChanged {
            LogDebug("Flow content changed for \(flow.id), reloading artifact")
            loadFlow()
        } else if products != newFlow.products {
            // Just products changed, inject them without full reload
            LogDebug("Only products changed for \(flow.id), updating products")
            updateProducts(newFlow.products)
        }
    }
    
    /// Retry loading
    func retry() {
        loadFlow()
    }
    
    /// Generate JSON string for products
    
    // MARK: - Private Methods
    
    private func startLoadingTimeout(for generation: UInt64) {
        cancelLoadingTimeout()
        
        loadingTimer = Timer.scheduledTimer(withTimeInterval: loadingTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLoadingTimeout(for: generation)
            }
        }
    }

    private func handleLoadingTimeout(for generation: UInt64) {
        guard loadGeneration == generation,
              case .loading = currentState else { return }
        cancelLoading()
        recordArtifactLoadFailure(errorMessage: "loading_timeout")
        currentState = .error
        LogDebug("Loading timeout reached for flow: \(flow.id)")
    }
    
    private func cancelLoadingTimeout() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    private func recordArtifactLoadSuccess() {
        guard !hasRecordedArtifactLoadOutcome else { return }
        hasRecordedArtifactLoadOutcome = true

        eventService.track(
            JourneyEvents.flowArtifactLoadSucceeded,
            properties: JourneyEvents.flowArtifactLoadSucceededProperties(
                flowId: flow.id,
                artifactBuildId: artifactTelemetryContext.artifactBuildId,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: flow.manifest.contentHash
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }

    private func recordArtifactLoadFailure(errorMessage: String?) {
        guard !hasRecordedArtifactLoadOutcome else { return }
        hasRecordedArtifactLoadOutcome = true

        eventService.track(
            JourneyEvents.flowArtifactLoadFailed,
            properties: JourneyEvents.flowArtifactLoadFailedProperties(
                flowId: flow.id,
                artifactBuildId: artifactTelemetryContext.artifactBuildId,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: flow.manifest.contentHash,
                errorMessage: errorMessage
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }
}
