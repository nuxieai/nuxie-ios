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
    
    private let artifactStore: FlowArtifactStore
    private var artifactTelemetryContext: FlowArtifactTelemetryContext
    @Injected(\.eventService) private var eventService: EventServiceProtocol
    
    // MARK: - Bindings (Closures)
    
    /// Called when state changes
    var onStateChanged: ((State) -> Void)?
    
    /// Called when products need to be injected
    
    /// Called when the native flow artifact is ready to mount.
    var onLoadArtifact: ((LoadedFlowArtifact) -> Void)?
    
    // MARK: - Timer
    
    private var loadingTimer: Timer?
    private let loadingTimeoutSeconds: TimeInterval = 15.0
    private var currentArtifactSource: FlowArtifactSource = .unknown
    private var hasRecordedArtifactLoadOutcome = false
    
    // MARK: - Initialization
    
    init(
        flow: Flow,
        artifactStore: FlowArtifactStore,
        artifactTelemetryContext: FlowArtifactTelemetryContext? = nil
    ) {
        self.flow = flow
        self.products = flow.products
        self.artifactStore = artifactStore
        self.artifactTelemetryContext = artifactTelemetryContext ?? FlowArtifactTelemetryContext.from(flow: flow)
        LogDebug("FlowViewModel initialized for flow: \(flow.id)")
    }
    
    deinit {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }
    
    // MARK: - Public Methods
    
    /// Start loading the flow content
    func loadFlow() {
        currentState = .loading
        hasRecordedArtifactLoadOutcome = false
        currentArtifactSource = .unknown
        startLoadingTimeout()
        
        Task {
            await loadFlowAsync()
        }
    }
    
    /// Async version of loadFlow
    private func loadFlowAsync() async {
        do {
            let artifact = try await artifactStore.getOrDownloadArtifact(for: flow)
            currentArtifactSource = artifact.source
            onLoadArtifact?(artifact)
            LogDebug("Loaded native flow artifact for flow \(flow.id): \(artifact.rivURL.path)")
        } catch {
            currentArtifactSource = .unavailable
            recordArtifactLoadFailure(errorMessage: error.localizedDescription)
            currentState = .error
            LogError("Failed to load flow artifact \(flow.id): \(error)")
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
        cancelLoadingTimeout()
        currentState = .loaded
        
        // Trigger product injection
    }
    
    /// Called when loading fails
    func handleLoadingFailed(_ error: Error) {
        LogError("Failed to load flow \(flow.id): \(error)")
        recordArtifactLoadFailure(errorMessage: error.localizedDescription)
        cancelLoadingTimeout()
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
    
    private func startLoadingTimeout() {
        cancelLoadingTimeout()
        
        loadingTimer = Timer.scheduledTimer(withTimeInterval: loadingTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if case .loading = self.currentState {
                self.recordArtifactLoadFailure(errorMessage: "loading_timeout")
                self.currentState = .error
                LogDebug("Loading timeout reached for flow: \(self.flow.id)")
            }
        }
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
