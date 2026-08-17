import Foundation

typealias ExperienceArtifactLoader = @Sendable (
    Experience,
    ExperiencePresentationTraceContext?,
    String?
) async throws -> AcquiredExperienceArtifact

struct ExperienceArtifactTelemetryContext {
    let artifactBuildId: String
    let artifactContentHash: String

    static func from(experience: Experience) -> ExperienceArtifactTelemetryContext {
        return ExperienceArtifactTelemetryContext(
            artifactBuildId: experience.buildId,
            artifactContentHash: experience.artifactContentHash ?? experience.buildId
        )
    }
}

/// View model for ExperienceViewController - handles business logic and state management
@MainActor
class ExperienceViewModel {

    // MARK: - State
    
    enum State: Equatable {
        case loading
        case loaded
        case timedOut
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

    /// Why the last attempt did not finish, for the recovery surface's copy.
    /// Nil while an attempt is healthy or has not failed yet.
    private(set) var recoveryReason: ExperienceShellRecoveryReason?
    
    private let artifactLoader: ExperienceArtifactLoader
    private var artifactTelemetryContext: ExperienceArtifactTelemetryContext
    private let eventLog: EventCapturing
    private var presentationTraceContext: ExperiencePresentationTraceContext?
    private var initialScreenID: String?
    
    // MARK: - Bindings (Closures)
    
    /// Called when state changes
    var onStateChanged: ((State) -> Void)?

    /// Called synchronously whenever a new artifact load supersedes the prior one.
    var onLoadStarted: (() -> Void)?

    /// Called synchronously when the active load is cancelled.
    /// The UI owner uses this to revoke any interactive-screen mount that
    /// began after artifact acquisition completed.
    var onLoadInvalidated: (() -> Void)?
    
    /// Called when products need to be injected
    
    /// Called when the native experience artifact is ready to mount.
    var onLoadArtifact: ((AcquiredExperienceArtifact) -> Void)?
    
    // MARK: - Timer
    
    // nonisolated(unsafe): MainActor-confined; also touched by deinit, which
    // has exclusive access to the last reference.
    private nonisolated(unsafe) var loadingTimer: Timer?
    private let loadingTimeoutSeconds: TimeInterval
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var currentArtifactSource: ExperienceArtifactSource = .unknown
    private var hasRecordedArtifactLoadOutcome = false
    
    // MARK: - Initialization
    
    init(
        experience: Experience,
        artifactTelemetryContext: ExperienceArtifactTelemetryContext? = nil,
        loadingTimeoutSeconds: TimeInterval = 15.0,
        artifactLoader: @escaping ExperienceArtifactLoader,
        eventLog: EventCapturing
    ) {
        self.eventLog = eventLog
        self.experience = experience
        self.products = experience.products
        self.artifactLoader = artifactLoader
        self.loadingTimeoutSeconds = loadingTimeoutSeconds
        self.artifactTelemetryContext = artifactTelemetryContext ?? ExperienceArtifactTelemetryContext.from(experience: experience)
        LogDebug("ExperienceViewModel initialized for experience: \(experience.id)")
    }

    func setInitialScreenID(_ initialScreenID: String?) {
        self.initialScreenID = initialScreenID
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
        let presentationTraceContext = presentationTraceContext
        let initialScreenID = initialScreenID

        recoveryReason = nil
        currentState = .loading
        hasRecordedArtifactLoadOutcome = false
        currentArtifactSource = .unknown
        startLoadingTimeout(for: generation)
        onLoadStarted?()
        guard loadGeneration == generation else { return }

        loadTask = Task { @MainActor [weak self] in
            do {
                let span = presentationTraceContext?.begin(
                    .artifactAcquisition,
                    attributes: ["phase": "presentation"]
                )
                let artifact: AcquiredExperienceArtifact
                do {
                    artifact = try await artifactLoader(
                        experience,
                        presentationTraceContext,
                        initialScreenID
                    )
                    if let span {
                        var attributes = artifact.resourceMetrics
                            .qualificationTraceAttributes
                        attributes["phase"] = "presentation"
                        attributes["source"] = artifact.source.rawValue
                        attributes["bytes"] = String(artifact.sceneBytes.count)
                        if artifact.resourceMetrics.duplicateReadBytes > 0 {
                            attributes["cache_outcome"] = "recovered"
                        }
                        presentationTraceContext?.complete(
                            span,
                            attributes: attributes
                        )
                    }
                } catch {
                    let reportedError: Error
                    var attributes = ["phase": "presentation"]
                    if let failure = error as? ExperienceReleaseResourceFailure {
                        reportedError = failure.underlying
                        attributes.merge(
                            failure.resourceMetrics.qualificationTraceAttributes
                        ) { _, measured in measured }
                        if failure.resourceMetrics.duplicateReadBytes > 0 {
                            attributes["cache_outcome"] = "rejected"
                        }
                    } else {
                        reportedError = error
                    }
                    if let span {
                        presentationTraceContext?.fail(
                            span,
                            error: reportedError,
                            attributes: attributes
                        )
                    }
                    throw reportedError
                }
                try Task.checkCancellation()
                guard let self, self.loadGeneration == generation else { return }
                self.currentArtifactSource = artifact.source
                self.onLoadArtifact?(artifact)
                LogDebug(
                    "Loaded experience artifact \(experience.id): \(artifact.sceneURL.path)"
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
                // Acquisition failures reach `.error` here rather than through
                // `handleLoadingFailed`, which covers native mount failures.
                // Both have to classify, or the recovery surface falls back to
                // generic copy for the one case it can actually explain.
                self.recoveryReason = ExperienceShellRecoveryReason(error: error)
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
        recoveryReason = nil
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
        recoveryReason = ExperienceShellRecoveryReason(error: error)
        recordArtifactLoadFailure(errorMessage: error.localizedDescription)
        // The controller reporting a native failure already revoked its mount.
        cancelLoading(notifyInvalidation: false)
        currentState = .error
    }

    func updateArtifactTelemetryContext(_ context: ExperienceArtifactTelemetryContext) {
        artifactTelemetryContext = context
    }

    func updatePresentationTraceContext(
        _ context: ExperiencePresentationTraceContext?
    ) {
        presentationTraceContext = context
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
            experience.artifactContentHash != newExperience.artifactContentHash ||
            experience.authenticatedReleaseID != newExperience.authenticatedReleaseID
        
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
        // The acquisition layer owns network and byte-admission deadlines. A
        // slow but healthy signed download may outlive this presentation hint;
        // keep it alive so the error shell can recover automatically when the
        // authenticated artifact becomes ready.
        cancelLoadingTimeout()
        // Acquisition is still running, so nothing is known to be broken; the
        // presentation deadline simply passed. That is indistinguishable from
        // any other failure to the person waiting, so it takes the neutral
        // reason rather than one that speculates.
        recoveryReason = .unavailable
        currentState = .timedOut
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
                experienceVersion: experience.versionId,
                artifactBuildId: artifactTelemetryContext.artifactBuildId,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: artifactTelemetryContext.artifactContentHash
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
                experienceVersion: experience.versionId,
                artifactBuildId: artifactTelemetryContext.artifactBuildId,
                artifactSource: currentArtifactSource.rawValue,
                artifactContentHash: artifactTelemetryContext.artifactContentHash,
                errorMessage: errorMessage
            ),
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
    }
}
