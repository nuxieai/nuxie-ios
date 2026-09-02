import Foundation

/// Protocol for presenting experiences in dedicated windows
protocol ExperiencePresentationServiceProtocol: DeviceLegPresenting {
    /// Present a experience by ID in a dedicated window
    @discardableResult
    @MainActor func presentExperience(_ experienceVersionId: String, from journey: Journey?, runtimeDelegate: ExperienceRuntimeDelegate?) async throws -> ExperienceViewController

    /// Present a experience by ID in a dedicated window
    @discardableResult
    @MainActor func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode
    ) async throws -> ExperienceViewController

    @MainActor func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String?
    ) async throws -> ExperienceViewController

    /// Presents the exact authenticated screen commit selected and persisted
    /// by journey control before renderer acquisition begins.
    @MainActor func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        commit: JourneyPendingPresentation
    ) async throws -> ExperienceViewController
    
    /// Dismiss the currently presented experience
    @MainActor func dismissCurrentExperience() async
    @MainActor func dismissCurrentExperience(reason: CloseReason) async
    @MainActor func dismissCurrentExperienceFromHost() async
    @MainActor func shutdownCurrentExperience() async
    
    /// Check if a experience is currently presented
    @MainActor var isExperiencePresented: Bool { get }
    @MainActor var presentedJourneyId: String? { get }
    
    /// Called when app becomes active - starts grace period
    @MainActor func onAppBecameActive()

    /// Re-opens device Journey presentation admission after the foreground
    /// profile authority and its dependent projections are current.
    @MainActor func deviceLegProfileRefreshDidComplete()
    
    /// Called when app enters background - clears grace period
    @MainActor func onAppDidEnterBackground()
}

extension ExperiencePresentationServiceProtocol {
    @MainActor
    func deviceLegProfileRefreshDidComplete() {}

    @MainActor
    func reserveDeviceLegPresentation(
        ownerDistinctId: String
    ) -> (any DeviceLegPresentationReservation)? {
        _ = ownerDistinctId
        return nil
    }

    @MainActor
    func presentDeviceLeg(
        _ request: DeviceLegPresentationRequest
    ) async -> DeviceLegPresentationResult {
        _ = request
        return .declined
    }

    @MainActor
    func navigateDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String,
        screenId: String,
        transition: ExperienceReleaseJSONValue?
    ) async -> DeviceLegPresentationNavigationResult {
        _ = journeyId
        _ = ownerDistinctId
        _ = screenId
        _ = transition
        return .noPresentation
    }

    @MainActor
    func finishDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String
    ) async {
        _ = journeyId
        _ = ownerDistinctId
    }

    @MainActor
    func shutdownDeviceLegPresentation(ownerDistinctId: String) async {
        _ = ownerDistinctId
    }
}

/// Service for presenting experiences in dedicated windows over the entire app
@MainActor
final class ExperiencePresentationService: ExperiencePresentationServiceProtocol {

    private struct DeviceLegPresentationContext {
        let journeyId: String
        let distinctId: String
        let experienceId: String
    }

    private struct PendingDeviceLegReservation {
        let id: UUID
        let ownerDistinctId: String
        var wasContended: Bool
    }

    private final class DeviceLegReservation: DeviceLegPresentationReservation {
        let id: UUID
        let ownerDistinctId: String
        private let service: ExperiencePresentationService

        init(
            id: UUID,
            ownerDistinctId: String,
            service: ExperiencePresentationService
        ) {
            self.id = id
            self.ownerDistinctId = ownerDistinctId
            self.service = service
        }

        func release() {
            service.releaseDeviceLegReservation(id: id)
        }
    }

    private struct PresentationOperationState {
        var presentationID: UUID?
        var owner: PresentationOwner?
        var deviceLegOwnerDistinctId: String?
    }

    /// Production presentations are owned by the Journey identity. The owner
    /// remains occupied until the attempt finishes; screen movement for that
    /// owner uses the dedicated navigation seam instead of another present.
    private enum PresentationOwner: Equatable {
        case journey(String)
        case direct
    }

    /// State retained after host surface control has synchronously detached a
    /// presentation. Durable Journey input and renderer teardown may outlive
    /// the visible window and continue to occupy its sole presentation slot.
    private struct DetachedHostPresentation {
        let id: UUID
        let window: PresentationWindowProtocol?
        let experienceVersionId: String
        let journey: Journey?
        let deviceLegContext: DeviceLegPresentationContext?
        let viewController: ExperienceViewController
        let runtimeDelegate: ExperienceRuntimeDelegate?
        let runtimeDelegateTraceToken: ExperiencePresentationTraceToken?
    }
    
    // MARK: - Dependencies
    
    private let experienceService: ExperienceServiceProtocol
    private let eventLog: EventCapturing
    private let triggerBroker: TriggerBrokerProtocol
    private let dateProvider: DateProviderProtocol
    private let windowProvider: WindowProviderProtocol
    
    // MARK: - State
    
    internal var currentWindow: PresentationWindowProtocol?
    internal var currentExperienceId: String?
    internal var currentJourney: Journey?
    internal var currentExperienceViewController: ExperienceViewController?
    private var currentRuntimeDelegate: ExperienceRuntimeDelegate?
    private var currentDeviceLegContext: DeviceLegPresentationContext?
    private var currentRuntimeDelegateTraceToken: ExperiencePresentationTraceToken?
    private var currentPresentationID: UUID?
    private var presentationOwner: PresentationOwner?
    private var presentationAttemptGeneration: UInt64 = 0
    private var presentationShutdownGeneration: UInt64 = 0
    private var presentationCleanupTask: Task<Void, Never>?
    private var detachedHostPresentations: [UUID: DetachedHostPresentation] = [:]
    private var detachedHostDismissalTasks: [UUID: Task<Void, Never>] = [:]
    private var presentationTeardownIDs: Set<UUID> = []
    private var activePresentationOperations: [UUID: PresentationOperationState] = [:]
    private var pendingDeviceLegReservation: PendingDeviceLegReservation?
    private var deviceLegPresentationAvailabilityHandler:
        (@MainActor @Sendable () -> Void)?
    private var deviceLegPresentationCapacityWasAvailable = true
    private var presentationOperationWaiters:
        [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var deviceLegPresentationOperationWaiters:
        [String: [CheckedContinuation<Void, Never>]] = [:]
    private var allPresentationOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var deviceLegForegroundAuthorityWaiters: [
        UUID: [CheckedContinuation<Bool, Never>]
    ] = [:]
    private var appIsForeground = true
    private var deviceLegForegroundAuthorityReady = true
    
    // MARK: - Grace Period
    
    private let foregroundGracePeriod: TimeInterval = 0.75  // UX grace window
    private var gracePeriodEndTime: Date?
    
    // MARK: - Initialization
    
    /// Nonisolated so the composition root can construct the instance from
    /// any thread; all state access stays MainActor-isolated.
    nonisolated init(
        windowProvider: WindowProviderProtocol? = nil,
        experiences: ExperienceServiceProtocol,
        eventLog: EventCapturing,
        triggerBroker: TriggerBrokerProtocol,
        dateProvider: DateProviderProtocol
    ) {
        self.windowProvider = windowProvider ?? DefaultWindowProvider()
        self.experienceService = experiences
        self.eventLog = eventLog
        self.triggerBroker = triggerBroker
        self.dateProvider = dateProvider
    }
    
    // MARK: - Public API
    
    var isExperiencePresented: Bool {
        currentWindow != nil
    }

    var presentedJourneyId: String? {
        currentJourney?.id
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: .system
        )
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode = .system
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            initialScreenID: nil
        )
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String?
    ) async throws -> ExperienceViewController {
        try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            initialScreenID: initialScreenID,
            expectedCommit: nil
        )
    }

    @discardableResult
    func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        commit: JourneyPendingPresentation
    ) async throws -> ExperienceViewController {
        guard commit.experienceVersionId == experienceVersionId else {
            throw ExperiencePresentationError.presentationSuperseded
        }
        return try await presentExperience(
            experienceVersionId,
            from: journey,
            runtimeDelegate: runtimeDelegate,
            colorSchemeMode: colorSchemeMode,
            initialScreenID: commit.screenId,
            expectedCommit: commit
        )
    }

    private func presentExperience(
        _ experienceVersionId: String,
        from journey: Journey?,
        runtimeDelegate: ExperienceRuntimeDelegate?,
        colorSchemeMode: ExperienceColorSchemeMode,
        initialScreenID: String?,
        expectedCommit: JourneyPendingPresentation?,
        owner suppliedOwner: PresentationOwner? = nil,
        deviceLegContext: DeviceLegPresentationContext? = nil,
        deviceLegReservation: DeviceLegReservation? = nil,
        viewControllerProvider:
            (@MainActor () async throws -> ExperienceViewController)? = nil
    ) async throws -> ExperienceViewController {
        let presentationOperationID = beginPresentationOperation()
        defer { finishPresentationOperation(presentationOperationID) }
        let requestedOwner = suppliedOwner
            ?? journey.map { .journey($0.id) }
            ?? .direct
        try claimPresentationOwnership(
            requestedOwner,
            operationID: presentationOperationID,
            deviceLegReservation: deviceLegReservation,
            requiresDeviceLegReservation: deviceLegContext != nil,
            deviceLegOwnerDistinctId: deviceLegContext?.distinctId
        )
        let shutdownGeneration = presentationShutdownGeneration
        try Task.checkCancellation()
        guard presentationShutdownGeneration == shutdownGeneration else {
            throw CancellationError()
        }
        // Validate the commit BEFORE advancing the attempt generation: an
        // invalid request must not supersede a valid suspended presentation.
        // The operation stays registered above either way, so shutdown still
        // joins this call.
        if let expectedCommit {
            guard await experienceService.validatesPresentationCommit(expectedCommit) else {
                throw ExperiencePresentationError.presentationSuperseded
            }
            guard presentationShutdownGeneration == shutdownGeneration else {
                throw CancellationError()
            }
        }
        presentationAttemptGeneration &+= 1
        let attemptGeneration = presentationAttemptGeneration
        LogInfo("ExperiencePresentationService: Presenting experience \(experienceVersionId)")
        
        // Check if we're within the grace period
        if let gracePeriodEnd = gracePeriodEndTime {
            let now = Date()
            if now < gracePeriodEnd {
                let delaySeconds = gracePeriodEnd.timeIntervalSince(now)
                LogDebug("ExperiencePresentationService: Delaying experience presentation by \(delaySeconds) seconds (grace period)")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        await presentationCleanupTask?.value
        try requireCurrentPresentationAttempt(attemptGeneration)
        
        // 1. Check if we can present
        guard windowProvider.canPresentWindow() else {
            LogError("ExperiencePresentationService: No active window available")
            throw ExperiencePresentationError.noActiveScene
        }
        
        // 2. Get experience view controller from ExperienceService
        let traceContext = (
            runtimeDelegate as? any ExperiencePresentationTraceContextProviding
        )?.presentationTraceContext
        let experienceViewController: ExperienceViewController
        if let viewControllerProvider {
            experienceViewController = try await viewControllerProvider()
        } else {
            experienceViewController = try await experienceService.viewController(
                for: experienceVersionId,
                runtimeDelegate: runtimeDelegate,
                colorSchemeMode: colorSchemeMode,
                presentationTraceContext: traceContext,
                initialScreenID: initialScreenID
            )
        }
        try requireCurrentPresentationAttempt(attemptGeneration)
        if let expectedCommit,
           await !experienceService.validatesPresentationCommit(expectedCommit) {
            throw ExperiencePresentationError.presentationSuperseded
        }
        try requireCurrentPresentationAttempt(attemptGeneration)
        let resolvedInitialScreenID = initialScreenID
            ?? (experienceViewController.experience.behaviorPresentationScreens.count == 1
                ? experienceViewController.experience.behaviorPresentationScreens.keys.first
                : nil)
        if experienceViewController.experience.authenticatedReleaseID != nil,
           resolvedInitialScreenID == nil {
            throw ExperiencePresentationError.presentationSuperseded
        }
        
        // 3. Create presentation window
        guard let window = windowProvider.createPresentationWindow() else {
            LogError("ExperiencePresentationService: Failed to create presentation window")
            throw ExperiencePresentationError.noActiveScene
        }
        
        // 4. Set up a presentation-scoped dismissal handler. Cached view
        // controllers can be reused, so an old callback must never tear down a
        // newer presentation of the same controller.
        let presentationID = UUID()
        experienceViewController.onClose = { [weak self] reason in
            Task { @MainActor in
                await self?.handleExperienceDismissal(
                    reason: reason,
                    presentationID: presentationID
                )
            }
        }

        // 5. Store state before presenting to avoid race conditions
        self.currentWindow = window
        self.currentExperienceId = experienceVersionId
        self.currentJourney = journey
        self.currentExperienceViewController = experienceViewController
        self.currentRuntimeDelegate = runtimeDelegate
        self.currentDeviceLegContext = deviceLegContext
        self.currentRuntimeDelegateTraceToken = (
            runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate
        )?.activePresentationTraceToken
        self.currentPresentationID = presentationID
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )

        // Journey persistence is not an authentication boundary. Always
        // rebuild presentation geometry and behavior from the currently
        // authenticated release carried by the loaded Experience.
        let shell = experienceViewController.experience.shellContract(
            screenId: resolvedInitialScreenID
        )
        let warmReservation = await experienceService
            .reserveMemoryWarmPresentation(for: experienceViewController.experience)
        do {
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
        } catch {
            warmReservation?.release()
            throw error
        }
        experienceViewController.configurePresentationShell(
            shell,
            suppressLoadingTreatment: warmReservation != nil,
            warmReservation: warmReservation
        )

        // Every presentation owns freshly opened interactive screens, even
        // when ExperienceService returns a cached view controller.
        await experienceViewController.prepareForPresentation(
            traceToken: currentRuntimeDelegateTraceToken,
            initialScreenID: resolvedInitialScreenID
        )
        if let expectedCommit,
           await !experienceService.validatesPresentationCommit(expectedCommit) {
            await finishPresentation(
                id: presentationID,
                reason: nil,
                dismissWindow: true
            )
            throw ExperiencePresentationError.presentationSuperseded
        }
        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )
        // 6. Present experience
        if let expectedCommit,
           await !experienceService.validatesPresentationCommit(expectedCommit) {
            await finishPresentation(
                id: presentationID,
                reason: nil,
                dismissWindow: true
            )
            throw ExperiencePresentationError.presentationSuperseded
        }
        let shellPresentationSpan = traceContext?.begin(
            .displayPresentation,
            attributes: ["phase": "shell"]
        )
        await window.present(experienceViewController, shell: shell)
        do {
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
        } catch {
            if let shellPresentationSpan {
                traceContext?.fail(
                    shellPresentationSpan,
                    error: error,
                    attributes: ["phase": "shell"]
                )
            }
            throw error
        }
        experienceViewController.markPresentationShellPresented(
            traceToken: currentRuntimeDelegateTraceToken
        )
        if let shellPresentationSpan {
            traceContext?.complete(
                shellPresentationSpan,
                attributes: ["phase": "shell"]
            )
        }

        if let journey = journey {
            await journey.markExperienceShown(at: dateProvider.now())
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
            let state = await journey.snapshot()
            try await requireOwnedPresentation(
                presentationID,
                attemptGeneration: attemptGeneration,
                fallbackWindow: window
            )
            trackExperienceShown(
                properties: JourneyEvents.experienceShownProperties(
                    experienceVersion: experienceVersionId,
                    journey: state
                ),
                distinctId: state.distinctId
            )
            if let originEventId = await journey.getContext("_origin_event_id")?.value as? String {
                try await requireOwnedPresentation(
                    presentationID,
                    attemptGeneration: attemptGeneration,
                    fallbackWindow: window
                )
                let ref = ExperienceRef(
                    experienceId: journey.experienceId,
                    experienceVersion: journey.experienceVersion,
                    journeyId: journey.id
                )
                await triggerBroker.emit(eventId: originEventId, update: .decision(.experienceShown(ref)))
            }
        } else if let deviceLegContext {
            trackExperienceShown(
                properties: [
                    "journey_id": deviceLegContext.journeyId,
                    "experience_id": deviceLegContext.experienceId,
                    "experience_version": experienceVersionId,
                ],
                distinctId: deviceLegContext.distinctId
            )
        }

        try await requireOwnedPresentation(
            presentationID,
            attemptGeneration: attemptGeneration,
            fallbackWindow: window
        )

        LogDebug("ExperiencePresentationService: Successfully presented experience \(experienceVersionId)")
        return experienceViewController
    }

    private func trackExperienceShown(
        properties: [String: Any],
        distinctId: String
    ) {
        eventLog.track(
            JourneyEvents.experienceShown,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            distinctIdOverride: distinctId
        )
    }

    func reserveDeviceLegPresentation(
        ownerDistinctId: String
    ) -> (any DeviceLegPresentationReservation)? {
        guard !ownerDistinctId.isEmpty else { return nil }
        if pendingDeviceLegReservation != nil {
            pendingDeviceLegReservation?.wasContended = true
            return nil
        }
        guard appIsForeground,
              deviceLegForegroundAuthorityReady,
              windowProvider.canPresentWindow(),
              presentationOwner == nil,
              currentPresentationID == nil,
              activePresentationOperations.isEmpty else {
            return nil
        }
        let reservation = PendingDeviceLegReservation(
            id: UUID(),
            ownerDistinctId: ownerDistinctId,
            wasContended: false
        )
        pendingDeviceLegReservation = reservation
        refreshDeviceLegPresentationCapacity()
        return DeviceLegReservation(
            id: reservation.id,
            ownerDistinctId: ownerDistinctId,
            service: self
        )
    }

    func setDeviceLegPresentationAvailabilityHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        deviceLegPresentationAvailabilityHandler = handler
        deviceLegPresentationCapacityWasAvailable =
            deviceLegPresentationCapacityIsAvailable
    }

    func ownsDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String
    ) -> Bool {
        currentPresentationID != nil
            && currentDeviceLegContext?.journeyId == journeyId
            && currentDeviceLegContext?.distinctId == ownerDistinctId
            && presentationOwner == .journey(journeyId)
    }

    func presentDeviceLeg(
        _ request: DeviceLegPresentationRequest
    ) async -> DeviceLegPresentationResult {
        guard appIsForeground,
              deviceLegForegroundAuthorityReady,
              request.release.descriptor.leg.screens.contains(where: {
            $0.id == request.screenId
        }) else {
            request.reservation?.release()
            return .failed
        }
        let reservation = request.reservation as? DeviceLegReservation
        guard request.reservation == nil || reservation != nil,
              reservation?.ownerDistinctId == request.ownerDistinctId
                || reservation == nil else {
            request.reservation?.release()
            return .declined
        }
        defer { reservation?.release() }
        let runtimeDelegate = DeviceLegRuntimeDelegate(request: request)
        do {
            _ = try await presentExperience(
                request.release.descriptor.identity.experienceVersionId,
                from: nil,
                runtimeDelegate: runtimeDelegate,
                colorSchemeMode: .system,
                initialScreenID: request.screenId,
                expectedCommit: nil,
                owner: .journey(request.journeyId),
                deviceLegContext: .init(
                    journeyId: request.journeyId,
                    distinctId: request.ownerDistinctId,
                    experienceId: request.release.descriptor.identity.experienceId
                ),
                deviceLegReservation: reservation,
                viewControllerProvider: { [experienceService] in
                    try await experienceService.viewController(
                        forDeviceLeg: request.release,
                        delivery: request.delivery,
                        runtimeDelegate: runtimeDelegate,
                        colorSchemeMode: .system
                    )
                }
            )
            return .shown
        } catch ExperiencePresentationError.presentationDeclined {
            return .declined
        } catch {
            return .failed
        }
    }

    func navigateDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String,
        screenId: String,
        transition: ExperienceReleaseJSONValue?
    ) async -> DeviceLegPresentationNavigationResult {
        guard let presentationID = currentPresentationID,
              let context = currentDeviceLegContext,
              let controller = currentExperienceViewController else {
            return .noPresentation
        }
        guard context.journeyId == journeyId,
              context.distinctId == ownerDistinctId,
              presentationOwner == .journey(journeyId) else {
            return .declined
        }
        guard await waitForDeviceLegForegroundAuthority(
            presentationID: presentationID
        ) else {
            return .noPresentation
        }
        guard currentPresentationID == presentationID,
              currentDeviceLegContext?.journeyId == journeyId,
              currentDeviceLegContext?.distinctId == ownerDistinctId,
              presentationOwner == .journey(journeyId) else {
            return .noPresentation
        }
        let navigationResult = await controller.navigateAndWaitResult(
            to: screenId,
            transition: deviceLegFoundationValue(transition)
        )
        guard currentPresentationID == presentationID,
              currentDeviceLegContext?.journeyId == journeyId,
              currentDeviceLegContext?.distinctId == ownerDistinctId else {
            return .failed
        }
        switch navigationResult {
        case .navigated:
            return .navigated
        case .alreadyActive:
            return .alreadyActive
        case .productsUnavailable:
            return .productsUnavailable
        case .failed:
            return .failed
        }
    }

    func resolveDeviceLegPresentationAction(
        journeyId: String,
        ownerDistinctId: String,
        action: [String: ExperienceReleaseJSONValue],
        source: ScreenEmissionSource?
    ) -> [String: ExperienceReleaseJSONValue]? {
        guard currentDeviceLegContext?.journeyId == journeyId,
              currentDeviceLegContext?.distinctId == ownerDistinctId,
              presentationOwner == .journey(journeyId),
              case .string(let type)? = action["type"] else {
            return nil
        }
        guard type == "purchase" else { return action }
        guard let placementValue = action["placementId"],
              let delegate = currentRuntimeDelegate as? DeviceLegRuntimeDelegate,
              let placementId = delegate.resolvePresentationString(
                placementValue,
                source: source
              ), !placementId.isEmpty else {
            return nil
        }
        var resolved = action
        resolved["placementId"] = .string(placementId)
        return resolved
    }

    func dispatchDeviceLegPresentationAction(
        journeyId: String,
        ownerDistinctId: String,
        action: [String: ExperienceReleaseJSONValue],
        effectId: String
    ) async -> DeviceLegPresentationActionResult {
        guard let presentationID = currentPresentationID,
              let context = currentDeviceLegContext,
              let controller = currentExperienceViewController else {
            return .noPresentation
        }
        guard context.journeyId == journeyId,
              context.distinctId == ownerDistinctId,
              presentationOwner == .journey(journeyId) else {
            return .declined
        }
        guard case .string(let type)? = action["type"] else {
            return .failed
        }
        guard await waitForDeviceLegForegroundAuthority(
            presentationID: presentationID
        ) else {
            return .noPresentation
        }
        guard currentPresentationID == presentationID,
              currentDeviceLegContext?.journeyId == journeyId,
              currentDeviceLegContext?.distinctId == ownerDistinctId,
              presentationOwner == .journey(journeyId) else {
            return .noPresentation
        }
        let result: DeviceLegPresentationActionResult
        switch type {
        case "back":
            let steps: Int
            if case .number(let value)? = action["steps"],
               value.isFinite,
               value.rounded(.towardZero) == value,
               value >= 1,
               value <= 256 {
                steps = Int(value)
            } else if action["steps"] == nil {
                steps = 1
            } else {
                return .failed
            }
            guard let delegate = currentRuntimeDelegate as? DeviceLegRuntimeDelegate,
                  let target = delegate.prepareBackNavigation(steps: steps) else {
                return .failed
            }
            switch await controller.navigateAndWaitResult(
                to: target,
                transition: deviceLegFoundationValue(action["transition"])
            ) {
            case .navigated, .alreadyActive:
                result = .handled
            case .productsUnavailable:
                delegate.cancelBackNavigation()
                result = .productsUnavailable
            case .failed:
                delegate.cancelBackNavigation()
                result = .failed
            }

        case "purchase":
            guard let placementValue = action["placementId"],
                  let delegate = currentRuntimeDelegate as? DeviceLegRuntimeDelegate,
                  let placementId = delegate.resolvePresentationString(
                    placementValue,
                    source: nil
                  ), !placementId.isEmpty else {
                return .failed
            }
            controller.performPurchase(
                placementId: placementId,
                outcomeCorrelation: CommerceOutcomeCorrelation(
                    eventId: effectId,
                    distinctId: ownerDistinctId
                )
            )
            result = .awaitingOutcome

        case "restore":
            controller.performRestore(outcomeCorrelation: CommerceOutcomeCorrelation(
                eventId: effectId,
                distinctId: ownerDistinctId
            ))
            result = .awaitingOutcome

        case "request_notifications":
            result = .permissionResolved(
                outlet: "next",
                event: await controller.resolveDeviceLegNotificationPermissionEvent(
                    journeyId: journeyId
                )
            )

        case "request_permission":
            guard case .string(let permissionType)? = action["permissionType"],
                  !permissionType.isEmpty else {
                return .failed
            }
            result = .permissionResolved(
                outlet: "next",
                event: await controller.resolveDeviceLegRequestPermissionEvent(
                    permissionType: permissionType,
                    journeyId: journeyId
                )
            )

        case "request_tracking":
            result = .permissionResolved(
                outlet: "next",
                event: await controller.resolveDeviceLegTrackingPermissionEvent(
                    journeyId: journeyId
                )
            )

        case "open_link":
            guard case .string(let url)? = action["url"],
                  !url.isEmpty,
                  case .string(let target)? = action["target"] else {
                return .failed
            }
            controller.performOpenLink(urlString: url, target: target)
            result = .advanced(outlet: "next")

        case "dismiss":
            controller.performDismiss(reason: .userDismissed)
            result = .handled

        default:
            return .failed
        }

        guard currentPresentationID == presentationID,
              currentDeviceLegContext?.journeyId == journeyId,
              currentDeviceLegContext?.distinctId == ownerDistinctId else {
            return .failed
        }
        return result
    }

    func finishDeviceLegPresentation(
        journeyId: String,
        ownerDistinctId: String
    ) async {
        guard let presentationID = currentPresentationID,
              currentDeviceLegContext?.journeyId == journeyId,
              currentDeviceLegContext?.distinctId == ownerDistinctId else {
            return
        }
        presentationAttemptGeneration &+= 1
        await finishPresentation(
            id: presentationID,
            reason: nil,
            dismissWindow: true
        )
    }

    func shutdownDeviceLegPresentation(ownerDistinctId: String) async {
        let ownsPendingReservation =
            pendingDeviceLegReservation?.ownerDistinctId == ownerDistinctId
        let ownsInFlightOperation = activePresentationOperations.values.contains(where: {
            $0.deviceLegOwnerDistinctId == ownerDistinctId
        })
        let ownedCurrentPresentationID =
            currentDeviceLegContext?.distinctId == ownerDistinctId
                ? currentPresentationID
                : nil
        let detachedTasks = detachedHostPresentations.compactMap {
            id, presentation -> Task<Void, Never>? in
            guard presentation.deviceLegContext?.distinctId == ownerDistinctId else {
                return nil
            }
            return detachedHostDismissalTasks[id]
        }
        if ownsPendingReservation {
            pendingDeviceLegReservation = nil
        }
        if ownsInFlightOperation || ownedCurrentPresentationID != nil {
            presentationAttemptGeneration &+= 1
        }
        detachedTasks.forEach { $0.cancel() }
        if let ownedCurrentPresentationID {
            await finishPresentation(
                id: ownedCurrentPresentationID,
                reason: nil,
                dismissWindow: true
            )
        }
        await waitForDeviceLegPresentationOperationsToFinish(
            ownerDistinctId: ownerDistinctId
        )
        for task in detachedTasks {
            await task.value
        }
        releasePresentationOwnershipIfIdle()
        refreshDeviceLegPresentationCapacity()
    }

    private func releaseDeviceLegReservation(id: UUID) {
        guard let reservation = pendingDeviceLegReservation,
              reservation.id == id else { return }
        pendingDeviceLegReservation = nil
        if reservation.wasContended {
            refreshDeviceLegPresentationCapacity()
        } else {
            // Releasing an uncontended reservation is part of unwinding the
            // current admission attempt. Publishing a callback here would
            // immediately retry the same state arm before its eligibility can
            // change.
            deviceLegPresentationCapacityWasAvailable =
                deviceLegPresentationCapacityIsAvailable
        }
    }
    
    func dismissCurrentExperience() async {
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }
        let presentationOperationID = beginPresentationOperation()
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )
        defer { finishPresentationOperation(presentationOperationID) }
        guard currentPresentationID == presentationID else { return }
        presentationAttemptGeneration &+= 1
        
        LogInfo("ExperiencePresentationService: Dismissing current experience")
        
        await finishPresentation(
            id: presentationID,
            reason: nil,
            dismissWindow: true
        )
    }

    func dismissCurrentExperience(reason: CloseReason) async {
        guard let presentationID = currentPresentationID else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }
        let presentationOperationID = beginPresentationOperation()
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )
        defer { finishPresentationOperation(presentationOperationID) }
        guard currentPresentationID == presentationID else { return }
        presentationAttemptGeneration &+= 1

        LogInfo("ExperiencePresentationService: Dismissing current experience with reason \(reason)")

        await finishPresentation(
            id: presentationID,
            reason: reason,
            dismissWindow: true
        )
    }

    func shutdownCurrentExperience() async {
        pendingDeviceLegReservation = nil
        presentationShutdownGeneration &+= 1
        presentationAttemptGeneration &+= 1
        let detachedTasks = Array(detachedHostDismissalTasks.values)
        detachedTasks.forEach { $0.cancel() }
        if let presentationID = currentPresentationID {
            await finishPresentation(
                id: presentationID,
                reason: nil,
                dismissWindow: true
            )
        } else {
            await presentationCleanupTask?.value
        }
        await waitForAllPresentationOperationsToFinish()
        await presentationCleanupTask?.value
        for task in detachedTasks {
            await task.value
        }
    }

    func dismissCurrentExperienceFromHost() async {
        guard let presentationID = currentPresentationID,
              let experienceViewController = currentExperienceViewController else {
            LogDebug("ExperiencePresentationService: No experience to dismiss")
            return
        }

        let presentation = DetachedHostPresentation(
            id: presentationID,
            window: currentWindow,
            experienceVersionId: currentExperienceId ?? "unknown",
            journey: currentJourney,
            deviceLegContext: currentDeviceLegContext,
            viewController: experienceViewController,
            runtimeDelegate: currentRuntimeDelegate,
            runtimeDelegateTraceToken: currentRuntimeDelegateTraceToken
        )
        presentationAttemptGeneration &+= 1
        experienceViewController.beginHostDismissal()

        // Surface control is synchronous with respect to callback ownership.
        // The presentation slot remains occupied until Journey, commerce, and
        // renderer teardown all settle.
        presentationTeardownIDs.insert(presentationID)
        resumeDeviceLegForegroundAuthorityWaiters(
            presentationID: presentationID,
            authorized: false
        )
        currentPresentationID = nil
        currentWindow = nil
        currentExperienceId = nil
        currentJourney = nil
        currentDeviceLegContext = nil
        currentExperienceViewController = nil
        currentRuntimeDelegate = nil
        currentRuntimeDelegateTraceToken = nil
        experienceViewController.onClose = nil

        // Hide the visible window immediately, then keep the public await and
        // presentation capacity tied to the complete host-dismissal contract.
        let surfaceTask = Task<Void, Never> { @MainActor in
            await presentation.window?.dismiss()
            presentation.window?.destroy()
        }
        let completionTask = Task<Void, Never> { @MainActor [weak self] in
            await surfaceTask.value
            guard let self else {
                presentation.window?.destroy()
                return
            }
            await self.completeDetachedHostPresentation(presentation)
            self.detachedHostPresentations.removeValue(forKey: presentationID)
            self.detachedHostDismissalTasks.removeValue(forKey: presentationID)
            self.presentationTeardownIDs.remove(presentationID)
            self.releasePresentationOwnershipIfIdle()
            self.refreshDeviceLegPresentationCapacity()
        }
        detachedHostPresentations[presentationID] = presentation
        detachedHostDismissalTasks[presentationID] = completionTask
        await completionTask.value
    }
    
    func onAppBecameActive() {
        guard !appIsForeground else { return }
        LogDebug("ExperiencePresentationService: App became active, starting grace period")
        appIsForeground = true
        deviceLegForegroundAuthorityReady = false
        // Set grace period end time
        gracePeriodEndTime = Date().addingTimeInterval(foregroundGracePeriod)
        refreshDeviceLegPresentationCapacity()
    }

    func deviceLegProfileRefreshDidComplete() {
        guard appIsForeground else { return }
        deviceLegForegroundAuthorityReady = true
        if let currentPresentationID {
            resumeDeviceLegForegroundAuthorityWaiters(
                presentationID: currentPresentationID,
                authorized: true
            )
        }
        refreshDeviceLegPresentationCapacity()
    }
    
    func onAppDidEnterBackground() {
        LogDebug("ExperiencePresentationService: App entered background, clearing grace period")
        appIsForeground = false
        deviceLegForegroundAuthorityReady = false
        pendingDeviceLegReservation = nil
        if activePresentationOperations.values.contains(where: {
            $0.deviceLegOwnerDistinctId != nil
        }) {
            presentationAttemptGeneration &+= 1
        }
        // Clear grace period when going to background
        gracePeriodEndTime = nil
        refreshDeviceLegPresentationCapacity()
    }
    
    // MARK: - Private Methods
    
    private func handleExperienceDismissal(
        reason: CloseReason,
        presentationID: UUID
    ) async {
        let presentationOperationID = beginPresentationOperation()
        associatePresentationOperation(
            presentationOperationID,
            with: presentationID
        )
        defer { finishPresentationOperation(presentationOperationID) }
        await finishPresentation(
            id: presentationID,
            reason: reason,
            dismissWindow: false
        )
    }

    private func finishPresentation(
        id presentationID: UUID,
        reason: CloseReason?,
        dismissWindow: Bool,
        screenLifecyclePrepared: Bool = false
    ) async {
        guard currentPresentationID == presentationID else {
            LogDebug("ExperiencePresentationService: Ignoring stale experience dismissal callback")
            return
        }
        LogDebug("ExperiencePresentationService: Cleaning up presentation")
        presentationTeardownIDs.insert(presentationID)

        let window = currentWindow
        let experienceViewController = currentExperienceViewController
        let experienceVersionId = currentExperienceId ?? "unknown"
        let journey = currentJourney
        let deviceLegContext = currentDeviceLegContext
        let runtimeDelegate = currentRuntimeDelegate
        let runtimeDelegateTraceToken = currentRuntimeDelegateTraceToken

        // The active screen reaches hidden and delivers its lifecycle analytics
        // before presentation ownership is revoked or its runtime is torn down.
        if !screenLifecyclePrepared {
            await experienceViewController?.prepareForDismissal(reason: reason)
        }
        guard currentPresentationID == presentationID else { return }

        // Revoke ownership before suspension so callbacks from this
        // presentation become stale immediately.
        resumeDeviceLegForegroundAuthorityWaiters(
            presentationID: presentationID,
            authorized: false
        )
        currentPresentationID = nil
        currentWindow = nil
        currentExperienceId = nil
        currentJourney = nil
        currentDeviceLegContext = nil
        currentExperienceViewController = nil
        currentRuntimeDelegate = nil
        currentRuntimeDelegateTraceToken = nil
        experienceViewController?.onClose = nil

        if let reason {
            LogInfo("ExperiencePresentationService: Experience \(experienceVersionId) dismissed with reason: \(reason)")
            if let journey {
                await trackDismissal(
                    reason,
                    experienceVersionId: experienceVersionId,
                    journey: journey
                )
            } else if let deviceLegContext {
                trackDeviceLegDismissal(
                    reason,
                    experienceVersionId: experienceVersionId,
                    context: deviceLegContext
                )
            }
        }

        // Renderer-bound sessions must close before the host window is
        // destroyed so every imported child is released before its renderer.
        let previousCleanupTask = presentationCleanupTask
        let cleanupTask = Task<Void, Never> { @MainActor in
            await previousCleanupTask?.value
            if dismissWindow {
                await window?.dismiss()
            }
            await experienceViewController?.shutdownRuntime()
            window?.destroy()
        }
        presentationCleanupTask = cleanupTask
        await cleanupTask.value
        if let experienceViewController {
            if let scopedTraceDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate {
                scopedTraceDelegate.experienceViewControllerDidFinishPresentation(
                    experienceViewController,
                    traceToken: runtimeDelegateTraceToken
                )
            } else {
                runtimeDelegate?.experienceViewControllerDidFinishPresentation(
                    experienceViewController
                )
            }
        }
        presentationTeardownIDs.remove(presentationID)
        releasePresentationOwnershipIfIdle()
        refreshDeviceLegPresentationCapacity()
    }

    private func requireCurrentPresentationAttempt(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard presentationAttemptGeneration == generation else {
            throw CancellationError()
        }
    }

    private func completeDetachedHostPresentation(
        _ presentation: DetachedHostPresentation
    ) async {
        let viewController = presentation.viewController
        let runtimeDelegate = presentation.runtimeDelegate
        var accepted = false

        if !Task.isCancelled {
            // Reserve host input before authored screen teardown can dispatch
            // lifecycle callbacks into the same Journey.
            await runtimeDelegate?.experienceViewControllerWillRequestHostDismiss(
                viewController
            )
            await waitForPresentationOperationsToFinish(
                presentationID: presentation.id
            )
        }
        if !Task.isCancelled {
            await viewController.waitForInFlightPurchaseBeforeHostDismissal()
        }
        if !Task.isCancelled {
            await viewController.prepareForDismissal(reason: .hostDismissed)
        }

        if !Task.isCancelled {
            if let runtimeDelegate {
                while !Task.isCancelled {
                    accepted = await runtimeDelegate
                        .experienceViewControllerDidRequestHostDismiss(
                            viewController
                        )
                    if accepted { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            } else {
                accepted = true
            }
        }

        if accepted {
            LogInfo(
                "ExperiencePresentationService: Experience \(presentation.experienceVersionId) dismissed with reason: \(CloseReason.hostDismissed)"
            )
            if let journey = presentation.journey {
                await trackDismissal(
                    .hostDismissed,
                    experienceVersionId: presentation.experienceVersionId,
                    journey: journey
                )
            } else if let deviceLegContext = presentation.deviceLegContext {
                trackDeviceLegDismissal(
                    .hostDismissed,
                    experienceVersionId: presentation.experienceVersionId,
                    context: deviceLegContext
                )
            }
        }

        await viewController.shutdownRuntime()
        if let scopedTraceDelegate = runtimeDelegate
            as? any ExperiencePresentationScopedTraceDelegate {
            scopedTraceDelegate.experienceViewControllerDidFinishPresentation(
                viewController,
                traceToken: presentation.runtimeDelegateTraceToken
            )
        } else {
            runtimeDelegate?.experienceViewControllerDidFinishPresentation(
                viewController
            )
        }
    }

    private func beginPresentationOperation() -> UUID {
        let operationID = UUID()
        activePresentationOperations[operationID] = PresentationOperationState(
            presentationID: nil,
            owner: nil,
            deviceLegOwnerDistinctId: nil
        )
        refreshDeviceLegPresentationCapacity()
        return operationID
    }

    private func claimPresentationOwnership(
        _ requestedOwner: PresentationOwner,
        operationID: UUID,
        deviceLegReservation: DeviceLegReservation? = nil,
        requiresDeviceLegReservation: Bool = false,
        deviceLegOwnerDistinctId: String? = nil
    ) throws {
        if presentationOwner != nil || !presentationTeardownIDs.isEmpty {
            throw ExperiencePresentationError.presentationDeclined
        }
        if presentationOwner == nil, requiresDeviceLegReservation {
            guard let deviceLegReservation,
                  pendingDeviceLegReservation?.id == deviceLegReservation.id,
                  pendingDeviceLegReservation?.ownerDistinctId
                    == deviceLegReservation.ownerDistinctId else {
                throw ExperiencePresentationError.presentationDeclined
            }
            pendingDeviceLegReservation = nil
        } else if let pendingDeviceLegReservation,
                  pendingDeviceLegReservation.id != deviceLegReservation?.id {
            throw ExperiencePresentationError.presentationDeclined
        }
        presentationOwner = requestedOwner
        guard var operation = activePresentationOperations[operationID] else {
            throw CancellationError()
        }
        operation.owner = requestedOwner
        operation.deviceLegOwnerDistinctId = deviceLegOwnerDistinctId
        activePresentationOperations[operationID] = operation
    }

    private func releasePresentationOwnershipIfIdle() {
        guard currentPresentationID == nil,
              presentationTeardownIDs.isEmpty,
              let presentationOwner,
              !activePresentationOperations.values.contains(where: {
                $0.owner == presentationOwner
              }) else { return }
        self.presentationOwner = nil
        refreshDeviceLegPresentationCapacity()
    }

    private func associatePresentationOperation(
        _ operationID: UUID,
        with presentationID: UUID
    ) {
        guard var operation = activePresentationOperations[operationID] else { return }
        let previousPresentationID = operation.presentationID
        operation.presentationID = presentationID
        activePresentationOperations[operationID] = operation
        if let previousPresentationID,
           previousPresentationID != presentationID {
            resumePresentationOperationWaitersIfReady(
                presentationID: previousPresentationID
            )
        }
    }

    private func finishPresentationOperation(_ operationID: UUID) {
        let operation = activePresentationOperations.removeValue(forKey: operationID)
        if let presentationID = operation?.presentationID {
            resumePresentationOperationWaitersIfReady(
                presentationID: presentationID
            )
        }
        if let ownerDistinctId = operation?.deviceLegOwnerDistinctId,
           !activePresentationOperations.values.contains(where: {
               $0.deviceLegOwnerDistinctId == ownerDistinctId
           }) {
            let waiters = deviceLegPresentationOperationWaiters
                .removeValue(forKey: ownerDistinctId) ?? []
            waiters.forEach { $0.resume() }
        }
        if activePresentationOperations.isEmpty {
            let waiters = allPresentationOperationWaiters
            allPresentationOperationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        releasePresentationOwnershipIfIdle()
        refreshDeviceLegPresentationCapacity()
    }

    private var deviceLegPresentationCapacityIsAvailable: Bool {
        appIsForeground
            && deviceLegForegroundAuthorityReady
            && windowProvider.canPresentWindow()
            && presentationOwner == nil
            && currentPresentationID == nil
            && presentationTeardownIDs.isEmpty
            && pendingDeviceLegReservation == nil
            && activePresentationOperations.isEmpty
    }

    private func refreshDeviceLegPresentationCapacity() {
        let isAvailable = deviceLegPresentationCapacityIsAvailable
        guard isAvailable != deviceLegPresentationCapacityWasAvailable else {
            return
        }
        deviceLegPresentationCapacityWasAvailable = isAvailable
        if isAvailable {
            deviceLegPresentationAvailabilityHandler?()
        }
    }

    private func waitForAllPresentationOperationsToFinish() async {
        guard !activePresentationOperations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            allPresentationOperationWaiters.append(continuation)
        }
    }

    private func waitForDeviceLegPresentationOperationsToFinish(
        ownerDistinctId: String
    ) async {
        guard activePresentationOperations.values.contains(where: {
            $0.deviceLegOwnerDistinctId == ownerDistinctId
        }) else { return }
        await withCheckedContinuation { continuation in
            deviceLegPresentationOperationWaiters[
                ownerDistinctId,
                default: []
            ].append(continuation)
        }
    }

    private func waitForDeviceLegForegroundAuthority(
        presentationID: UUID
    ) async -> Bool {
        guard currentPresentationID == presentationID else { return false }
        if appIsForeground && deviceLegForegroundAuthorityReady {
            return true
        }
        return await withCheckedContinuation { continuation in
            guard currentPresentationID == presentationID else {
                continuation.resume(returning: false)
                return
            }
            deviceLegForegroundAuthorityWaiters[
                presentationID,
                default: []
            ].append(continuation)
        }
    }

    private func resumeDeviceLegForegroundAuthorityWaiters(
        presentationID: UUID,
        authorized: Bool
    ) {
        let waiters = deviceLegForegroundAuthorityWaiters
            .removeValue(forKey: presentationID) ?? []
        waiters.forEach { $0.resume(returning: authorized) }
    }

    private func waitForPresentationOperationsToFinish(
        presentationID: UUID
    ) async {
        guard activePresentationOperations.values.contains(where: {
            $0.presentationID == presentationID
        }) else { return }
        await withCheckedContinuation { continuation in
            presentationOperationWaiters[presentationID, default: []]
                .append(continuation)
        }
    }

    private func resumePresentationOperationWaitersIfReady(
        presentationID: UUID
    ) {
        guard !activePresentationOperations.values.contains(where: {
            $0.presentationID == presentationID
        }) else { return }
        let waiters = presentationOperationWaiters
            .removeValue(forKey: presentationID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func requireOwnedPresentation(
        _ presentationID: UUID,
        attemptGeneration: UInt64,
        fallbackWindow: PresentationWindowProtocol
    ) async throws {
        guard !Task.isCancelled,
              presentationAttemptGeneration == attemptGeneration,
              currentPresentationID == presentationID else {
            if currentPresentationID == presentationID {
                await finishPresentation(
                    id: presentationID,
                    reason: nil,
                    dismissWindow: true
                )
            } else {
                fallbackWindow.destroy()
            }
            throw CancellationError()
        }
    }

    private func trackDismissal(
        _ reason: CloseReason,
        experienceVersionId: String,
        journey: Journey
    ) async {
        let state = await journey.snapshot()

        switch reason {
        case .userDismissed, .goalMet, .hostDismissed:
            eventLog.track(
                JourneyEvents.experienceDismissed,
                properties: JourneyEvents.experienceDismissedProperties(
                    experienceVersion: experienceVersionId,
                    journey: state,
                    reason: reason
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil,
                distinctIdOverride: journey.distinctId
            )
        case .error(let error):
            eventLog.track(
                JourneyEvents.experienceErrored,
                properties: JourneyEvents.experienceErroredProperties(
                    experienceVersion: experienceVersionId,
                    journey: state,
                    errorMessage: error.localizedDescription
                ),
                userProperties: nil,
                userPropertiesSetOnce: nil
            )
        }
    }

    private func trackDeviceLegDismissal(
        _ reason: CloseReason,
        experienceVersionId: String,
        context: DeviceLegPresentationContext
    ) {
        var properties: [String: Any] = [
            "journey_id": context.journeyId,
            "experience_id": context.experienceId,
            "experience_version": experienceVersionId,
        ]
        switch reason {
        case .userDismissed:
            properties["reason"] = "user"
        case .goalMet:
            properties["reason"] = "goal_met"
        case .hostDismissed:
            properties["reason"] = "host"
        case .error(let error):
            properties["error_message"] = error.localizedDescription
            eventLog.track(
                JourneyEvents.experienceErrored,
                properties: properties,
                userProperties: nil,
                userPropertiesSetOnce: nil,
                distinctIdOverride: context.distinctId
            )
            return
        }
        eventLog.track(
            JourneyEvents.experienceDismissed,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil,
            distinctIdOverride: context.distinctId
        )
    }
}

// MARK: - Errors

enum ExperiencePresentationError: LocalizedError {
    case noActiveScene
    case experienceNotFound(String)
    case presentationFailed(Error)
    case presentationSuperseded
    case presentationDeclined
    
    var errorDescription: String? {
        switch self {
        case .noActiveScene:
            return "No active window available for presentation"
        case .experienceNotFound(let experienceVersionId):
            return "Experience not found: \(experienceVersionId)"
        case .presentationFailed(let error):
            return "Experience presentation failed: \(error.localizedDescription)"
        case .presentationSuperseded:
            return "The authenticated presentation commit was superseded"
        case .presentationDeclined:
            return "Another Journey owns the presentation surface"
        }
    }
}
