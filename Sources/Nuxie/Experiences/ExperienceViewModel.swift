import Foundation

struct ExperienceArtifactTelemetryContext {
    let artifactBuildId: String

    static func from(experience: Experience) -> ExperienceArtifactTelemetryContext {
        return ExperienceArtifactTelemetryContext(
            artifactBuildId: experience.buildId
        )
    }
}

/// View model for ExperienceViewController - handles business logic and state management
@MainActor
class ExperienceViewModel {
    typealias ArtifactLoader = (Experience) async throws -> AcquiredExperiencePackage

    // MARK: - State
    
    enum State: Equatable {
        case loading
        case loaded
        case error
    }
    
    // MARK: - Properties
    
    private(set) var experience: Experience
    private(set) var products: [ExperienceProduct]
    private(set) var currentState: State = .loading {
        didSet {
            onStateChanged?(currentState)
        }
    }
    
    private let artifactLoader: ArtifactLoader
    private var artifactTelemetryContext: ExperienceArtifactTelemetryContext
    private let eventLog: EventLogProtocol
    
    // MARK: - Bindings (Closures)
    
    /// Called when state changes
    var onStateChanged: ((State) -> Void)?

    /// Called synchronously whenever a new artifact load supersedes the prior one.
    var onLoadStarted: (() -> Void)?

    /// Called synchronously when the active load is cancelled or times out.
    /// The UI owner uses this to revoke any interactive-screen mount that
    /// began after artifact acquisition completed.
    var onLoadInvalidated: (() -> Void)?
    
    /// Called when products need to be injected
    
    /// Called when the native experience artifact is ready to mount.
    var onLoadArtifact: ((AcquiredExperiencePackage) -> Void)?
    
    // MARK: - Timer
    
    // nonisolated(unsafe): MainActor-confined; also touched by deinit, which
    // has exclusive access to the last reference.
    private nonisolated(unsafe) var loadingTimer: Timer?
    private let loadingTimeoutSeconds: TimeInterval
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var currentArtifactSource: ExperiencePackageSource = .unknown
    private var hasRecordedArtifactLoadOutcome = false
    
    // MARK: - Initialization
    
    init(
        experience: Experience,
        packageStore: ExperiencePackageStore,
        artifactTelemetryContext: ExperienceArtifactTelemetryContext? = nil,
        loadingTimeoutSeconds: TimeInterval = 15.0,
        artifactLoader: ArtifactLoader? = nil,
        eventLog: EventLogProtocol
    ) {
        self.eventLog = eventLog
        self.experience = experience
        self.products = experience.products
        self.artifactLoader = artifactLoader ?? { experience in
            try await packageStore.getOrDownloadPackage(
                for: experience.remote,
                assetBaseURL: experience.assetBaseURL
            )
        }
        self.loadingTimeoutSeconds = loadingTimeoutSeconds
        self.artifactTelemetryContext = artifactTelemetryContext ?? ExperienceArtifactTelemetryContext.from(experience: experience)
        LogDebug("ExperienceViewModel initialized for experience: \(experience.id)")
    }
    
    deinit {
        loadTask?.cancel()
        loadTask = nil
        loadingTimer?.invalidate()
        loadingTimer = nil
    }
    
    // MARK: - Public Methods
    
    /// Start loading the experience content
    func loadExperience() {
        // `onLoadStarted` below owns native-mount invalidation for this
        // superseding attempt, so do not notify twice while rotating the
        // artifact acquisition task.
        cancelLoading(notifyInvalidation: false)
        loadGeneration &+= 1
        let generation = loadGeneration
        let experience = experience
        let artifactLoader = artifactLoader

        currentState = .loading
        hasRecordedArtifactLoadOutcome = false
        currentArtifactSource = .unknown
        startLoadingTimeout(for: generation)
        onLoadStarted?()
        guard loadGeneration == generation else { return }

        loadTask = Task { @MainActor [weak self] in
            do {
                let artifact = try await artifactLoader(experience)
                try Task.checkCancellation()
                guard let self, self.loadGeneration == generation else { return }
                self.currentArtifactSource = artifact.source
                self.onLoadArtifact?(artifact)
                LogDebug(
                    "Loaded experience package \(experience.id): \(artifact.packageURL.path)"
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
                LogError("Failed to load experience artifact \(experience.id): \(error)")
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
        LogDebug("Started loading experience: \(experience.id)")
        currentState = .loading
    }
    
    /// Called when loading finishes successfully
    func handleLoadingFinished() {
        LogDebug("Finished loading experience: \(experience.id)")
        recordArtifactLoadSuccess()
        // The native coordinator is now the committed owner. Finishing its
        // acquisition timer must not invalidate that successful mount.
        cancelLoading(notifyInvalidation: false)
        currentState = .loaded
        
        // Trigger product injection
    }
    
    /// Called when loading fails
    func handleLoadingFailed(_ error: Error) {
        LogError("Failed to load experience \(experience.id): \(error)")
        recordArtifactLoadFailure(errorMessage: error.localizedDescription)
        // The controller reporting a native failure already revoked its mount.
        cancelLoading(notifyInvalidation: false)
        currentState = .error
    }

    func updateArtifactTelemetryContext(_ context: ExperienceArtifactTelemetryContext) {
        artifactTelemetryContext = context
    }
    
    /// Update products
    func updateProducts(_ newProducts: [ExperienceProduct]) {
        self.products = newProducts
        
        // If already loaded, inject the new products
        if case .loaded = currentState {
        }
        
        LogDebug("Updated products for experience: \(experience.id)")
    }
    
    /// Update the experience and reload if content has changed
    func updateExperienceIfNeeded(_ newExperience: Experience) {
        let hasContentChanged =
            experience.buildId != newExperience.buildId ||
            experience.artifact.sha256 != newExperience.artifact.sha256
        
        // Always update the experience reference
        self.experience = newExperience
        self.products = newExperience.products
        
        // If content or URL changed, reload the native artifact.
        if hasContentChanged {
            LogDebug("Experience content changed for \(experience.id), reloading artifact")
            loadExperience()
        } else if products != newExperience.products {
            // Just products changed, inject them without full reload
            LogDebug("Only products changed for \(experience.id), updating products")
            updateProducts(newExperience.products)
        }
    }
    
    /// Retry loading
    func retry() {
        loadExperience()
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
        LogDebug("Loading timeout reached for experience: \(experience.id)")
    }
    
    private func cancelLoadingTimeout() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    private func recordArtifactLoadSuccess() {
        guard !hasRecordedArtifactLoadOutcome else { return }
        hasRecordedArtifactLoadOutcome = true

        eventLog.track(
            JourneyEvents.experienceArtifactLoadSucceeded,
            properties: JourneyEvents.experienceArtifactLoadSucceededProperties(
                experienceVersion: experience.id,
                artifactBuildId: artifactTelemetryContext.artifactBuildId,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: experience.artifact.sha256
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }

    private func recordArtifactLoadFailure(errorMessage: String?) {
        guard !hasRecordedArtifactLoadOutcome else { return }
        hasRecordedArtifactLoadOutcome = true

        eventLog.track(
            JourneyEvents.experienceArtifactLoadFailed,
            properties: JourneyEvents.experienceArtifactLoadFailedProperties(
                experienceVersion: experience.id,
                artifactBuildId: artifactTelemetryContext.artifactBuildId,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: experience.artifact.sha256,
                errorMessage: errorMessage
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }
}
