import Foundation

protocol DeviceLegProfileConsuming: AnyObject, Sendable {
    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        artifacts: PreparedDeviceLegArtifacts?,
        authority: ProfileDeliveryAuthority,
        distinctId: String
    ) async
    func profileDidClear(distinctId: String) async
    func profileDidClearAll() async
}

protocol DeviceLegServiceProtocol: DeviceLegProfileConsuming {
    func initialize() async
    func handleEvent(_ event: NuxieEvent) async
    func handleEvent(
        _ event: NuxieEvent,
        admittedProfileGeneration: UInt64?
    ) async
    func eventAdmissionGeneration() -> UInt64
    func onAppDidEnterBackground() async
    func onAppWillEnterForeground() async
    func onAppBecameActive() async
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
    func shutdown() async
}

extension DeviceLegServiceProtocol {
    func shutdown() async {}
}

/// Owns the complete local lifecycle of authenticated flat device legs. The
/// profile catalog authenticates immutable programs; this actor evaluates
/// arms, journals every transition, and reports terminal boundaries through
/// EventLog's existing durable event queue.
actor DeviceLegService {
    typealias FeatureAccessLookup = @Sendable (String) async -> FeatureAccess?
    typealias PinnedReleaseAuthenticator = @Sendable (
        DeviceLegReleaseProfileEntry,
        ArmedDeviceLeg.Reference
    ) async throws -> AuthenticatedDeviceLegRelease

    private struct ProfileState: Sendable {
        let distinctId: String
        let snapshot: DeviceLegProfileCatalog.Snapshot
        let artifacts: PreparedDeviceLegArtifacts?
        let generation: UInt64
    }

    private typealias StateArmKey = DeviceLegStateArmReceipt

    private struct AttemptKey: Hashable, Sendable {
        let arm: StateArmKey
        let eventId: String?
        let profileGeneration: UInt64
    }

    private enum PresentationLifecycleResult {
        case accepted
        case completed
        case rejected
    }

    private struct PendingPresentationDismissalContinuation: Sendable {
        let run: DeviceLegRun
        let release: AuthenticatedDeviceLegRelease
        let executionFenceToken: DeviceLegProfileFenceToken
        let occurredAtMillis: Int64
        let journal: DeviceLegRunJournal
    }

    /// The journal publishes a state-arm receipt from its filesystem
    /// transaction, outside this actor's executor. A short lock lets that
    /// publication linearize with profile replacement without actor reentry.
    private final class StateArmReceiptStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: Set<StateArmKey> = []

        func contains(_ key: StateArmKey) -> Bool {
            lock.withLock { values.contains(key) }
        }

        func insert(_ key: StateArmKey) {
            lock.withLock { _ = values.insert(key) }
        }

        func retain(_ allowed: Set<StateArmKey>) {
            lock.withLock { values.formIntersection(allowed) }
        }

        func remove(where shouldRemove: (StateArmKey) -> Bool) {
            lock.withLock { values = Set(values.filter { !shouldRemove($0) }) }
        }

        func removeAll() {
            lock.withLock { values.removeAll() }
        }
    }

    private let identity: IdentityServiceProtocol
    private let events: EventLogProtocol
    private let experimentExposures: DeviceLegExperimentExposureCoordinator
    private let presentationPublications:
        DeviceLegPresentationPublicationCoordinator
    private let dateProvider: DateProviderProtocol
    private let sleepProvider: SleepProviderProtocol
    private let journalDirectory: URL?
    private let journalBeforePersist: (@Sendable () throws -> Void)?
    /// Production starts without a journal namespace and installs one only
    /// after profile transport authenticates the configured Nuxie app. Tests
    /// may inject a fixed scope for direct journal inspection.
    private var storageScope: DeviceLegStorageScope?
    private let acceptsProfileAuthorityScope: Bool
    private let featureAccess: FeatureAccessLookup
    private let dispatcher: any DeviceLegDispatching
    private let presenter: (any DeviceLegPresenting)?
    private let pinnedReleaseAuthenticator: PinnedReleaseAuthenticator
    private let timezones: SignedTimezoneBundle
    private let currentDeviceTimezone: TimeZone

    private var initialized = false
    /// Setup occurs while the host app is in its launch foreground session.
    /// Lifecycle notifications close and reopen this latch thereafter.
    private var foreground = true
    private var profileState: ProfileState?
    /// Advances for every profile publication and linearizes entry admission.
    private let profileFence = DeviceLegProfileFence()
    /// Advances only when admitted execution authority is explicitly revoked.
    private let executionFence: DeviceLegProfileFence
    private var journal: DeviceLegRunJournal?
    private var retainedReleasesByDigest: [String: AuthenticatedDeviceLegRelease] = [:]
    private var retainedReleaseOrder: [String] = []
    private var retainedReleaseBytes = 0
    private static let retainedReleaseCacheByteLimit = 64 * 1_024 * 1_024
    private static let retainedReleaseCacheCountLimit = 256
    private let stateArmReceipts = StateArmReceiptStore()
    /// Each foreground session reopens the app-foregrounded latch once per
    /// customer journal. A failed journal write leaves the customer absent so
    /// the next lifecycle/profile callback retries before evaluating arms.
    private var foregroundReceiptResetCustomers: Set<String> = []
    /// A failed revocation write blocks reuse of that journal until a later
    /// profile/identity transition retries it successfully.
    private var revokingCustomers: Set<String> = []
    private var inFlightAttempts: Set<AttemptKey> = []
    private var pendingPresentationDismissalContinuations: [
        String: PendingPresentationDismissalContinuation
    ] = [:]
    /// The renderer resolves purchase references against the active screen
    /// instance before starting commerce. Keep that exact value with the
    /// claimed run so only its matching SDK outcome can advance the cursor.
    private var pendingPresentationPurchasePlacements: [String: String] = [:]
    private var wakeTask: Task<Void, Never>?
    private var wakeGeneration: UInt64 = 0

    init(
        identity: IdentityServiceProtocol,
        events: EventLogProtocol,
        dateProvider: DateProviderProtocol,
        sleepProvider: SleepProviderProtocol,
        journalDirectory: URL?,
        storageScope: DeviceLegStorageScope? = .testFixture,
        featureAccess: @escaping FeatureAccessLookup,
        dispatcher: any DeviceLegDispatching,
        presenter: (any DeviceLegPresenting)? = nil,
        pinnedReleaseAuthenticator: @escaping PinnedReleaseAuthenticator,
        timezones: SignedTimezoneBundle,
        currentDeviceTimezone: TimeZone = .current,
        journalBeforePersist: (@Sendable () throws -> Void)? = nil
    ) {
        self.identity = identity
        self.events = events
        let executionFence = DeviceLegProfileFence()
        self.executionFence = executionFence
        experimentExposures = DeviceLegExperimentExposureCoordinator(
            events: events
        )
        presentationPublications =
            DeviceLegPresentationPublicationCoordinator(
                identity: identity,
                events: events,
                executionFence: executionFence
            )
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.journalDirectory = journalDirectory
        self.journalBeforePersist = journalBeforePersist
        self.storageScope = storageScope
        acceptsProfileAuthorityScope = storageScope == nil
        self.featureAccess = featureAccess
        self.dispatcher = dispatcher
        self.presenter = presenter
        self.pinnedReleaseAuthenticator = pinnedReleaseAuthenticator
        self.timezones = timezones
        self.currentDeviceTimezone = currentDeviceTimezone
    }

    deinit {
        wakeTask?.cancel()
    }

    func initialize() async {
        guard !initialized else { return }
        initialized = true
        await presenter?.setDeviceLegPresentationAvailabilityHandler {
            [weak self] in
            Task { await self?.presentationDidBecomeAvailable() }
        }
        if storageScope != nil {
            await openJournal(for: identity.getDistinctId())
        }
        await resetForegroundStateArmReceiptsIfNeeded()
        guard let state = currentProfileState() else { return }
        await resumeParkedRuns(state: state, event: nil)
        await evaluateStateArms(state: state, kinds: nil)
    }

    func shutdown() async {
        guard initialized || profileState != nil || journal != nil else { return }
        // Revoke execution before asking the shared presenter to tear down its
        // surface. Renderer callbacks emitted by teardown then fail every
        // profile and execution-fence check.
        initialized = false
        foreground = false
        cancelWake()
        await presenter?.setDeviceLegPresentationAvailabilityHandler(nil)
        await profileDidClearAll()
        await experimentExposures.cancelAndAwaitRetries()
    }

    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        artifacts: PreparedDeviceLegArtifacts?,
        authority: ProfileDeliveryAuthority,
        distinctId: String
    ) async {
        guard identity.getDistinctId() == distinctId else { return }
        if acceptsProfileAuthorityScope {
            let authenticatedScope = DeviceLegStorageScope(authority: authority)
            guard storageScope == nil || storageScope == authenticatedScope else {
                LogError("DeviceLegService: authenticated app authority changed")
                return
            }
            storageScope = authenticatedScope
        }
        await commitProfile(
            snapshot,
            artifacts: artifacts,
            distinctId: distinctId
        )
    }

    /// Direct runtime tests use an injected fixed namespace and do not model
    /// the profile transport boundary.
    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        distinctId: String
    ) async {
        await commitProfile(snapshot, artifacts: nil, distinctId: distinctId)
    }

    private func commitProfile(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        artifacts: PreparedDeviceLegArtifacts?,
        distinctId: String
    ) async {
        guard identity.getDistinctId() == distinctId else { return }
        let generation = profileFence.advance()
        profileState = ProfileState(
            distinctId: distinctId,
            snapshot: snapshot,
            artifacts: artifacts,
            generation: generation
        )
        retainReceipts(for: snapshot)
        guard initialized else { return }
        await ensureJournal(for: distinctId)
        await resetForegroundStateArmReceiptsIfNeeded()
        if let journal, journal.distinctId == distinctId {
            do {
                try await journal.retainStateArmReceipts(
                    stateArmReceiptKeys(for: snapshot)
                )
                try await journal.retainCheckmarks(
                    liveExperiences: snapshot.liveReentryPolicies,
                    at: dateProvider.now()
                )
            } catch {
                LogWarning("DeviceLegService: failed to retain journal admission metadata: \(error)")
            }
        }
        guard let state = currentProfileState() else { return }
        await resumeParkedRuns(state: state, event: nil)
        await evaluateStateArms(state: state, kinds: nil)
    }

    func profileDidClear(distinctId: String) async {
        guard profileState?.distinctId == distinctId
                || journal?.distinctId == distinctId else { return }
        cancelWake()
        let journalToAbandon = journal?.distinctId == distinctId ? journal : nil
        _ = profileFence.advance()
        _ = executionFence.advance()
        profileState = nil
        clearRetainedReleaseCache()
        stateArmReceipts.removeAll()
        inFlightAttempts.removeAll()
        pendingPresentationDismissalContinuations.removeAll()
        pendingPresentationPurchasePlacements.removeAll()
        await presentationPublications.clearDirectRoutes()
        await presenter?.shutdownDeviceLegPresentation(
            ownerDistinctId: distinctId
        )
        if let journalToAbandon {
            await abandon(journalToAbandon)
        }
    }

    func profileDidClearAll() async {
        cancelWake()
        let journalToAbandon = journal
        let presentationOwner = journalToAbandon?.distinctId
            ?? profileState?.distinctId
        _ = profileFence.advance()
        _ = executionFence.advance()
        profileState = nil
        clearRetainedReleaseCache()
        stateArmReceipts.removeAll()
        inFlightAttempts.removeAll()
        pendingPresentationDismissalContinuations.removeAll()
        pendingPresentationPurchasePlacements.removeAll()
        await presentationPublications.clearDirectRoutes()
        if let presentationOwner {
            await presenter?.shutdownDeviceLegPresentation(
                ownerDistinctId: presentationOwner
            )
        }
        if let journalToAbandon {
            await abandon(journalToAbandon)
        }
    }

    nonisolated func eventAdmissionGeneration() -> UInt64 {
        profileFence.token().generation
    }

    func handleEvent(_ event: NuxieEvent) async {
        await handleEvent(
            event,
            admittedProfileGeneration: eventAdmissionGeneration()
        )
    }

    func handleEvent(
        _ event: NuxieEvent,
        admittedProfileGeneration: UInt64?
    ) async {
        let directlyRoutedRunId = await presentationPublications
            .consumeDirectRoute(eventId: event.id)
        guard initialized,
              event.distinctId == identity.getDistinctId(),
              event.name != JourneyEvents.journeyLegStarted,
              event.name != JourneyEvents.journeyLegCompleted,
              let state = currentProfileState() else { return }

        await resumeParkedRuns(
            state: state,
            event: event,
            excludingRunId: directlyRoutedRunId
        )
        guard isCurrent(state) else { return }
        await resumePresentationActionOutcome(
            state: state,
            event: event,
            excludingRunId: directlyRoutedRunId
        )
        guard isCurrent(state) else { return }
        guard admittedProfileGeneration == state.generation else {
            await scheduleNextWake()
            return
        }
        for arm in state.snapshot.profile.armedLegs
        where arm.entryCondition.type == .event
            && arm.entryCondition.eventName == event.name {
            await attemptStart(arm, state: state, event: event)
        }
        await scheduleNextWake()
    }

    private func resumePresentationActionOutcome(
        state: ProfileState,
        event: NuxieEvent,
        excludingRunId: String? = nil
    ) async {
        guard let route = DeviceLegActionType.presentationOutcomeRoute(
            eventName: event.name
        ),
              let journal,
              isCurrent(state),
              isCurrentIdentity(journal: journal) else { return }
        let candidates: [DeviceLegRun]
        do {
            candidates = try await journal.runs()
        } catch {
            return
        }
        for candidate in candidates
        where candidate.completion == nil
            && candidate.park == nil
            && candidate.id != excludingRunId {
            guard isCurrent(state),
                  isCurrentIdentity(journal: journal) else { continue }
            let executionFenceToken = executionFence.token()
            guard let release = await release(
                for: candidate,
                state: state,
                journal: journal,
                executionFenceToken: executionFenceToken
            ) else { continue }
            let leg = release.descriptor.leg
            guard let step = leg.steps.first(where: {
                $0.id == candidate.stepId
            }), let action = step.action,
                  DeviceLegActionType(action: action) == route.actionType,
                  let effectId = candidate.effectReceipts[step.id],
                  presentationOutcomeMatches(
                    event,
                    effectId: effectId,
                    runId: candidate.id,
                    action: action,
                    release: release
                  ),
                  let nextStepId = step.outlets?[route.outlet] else {
                continue
            }
            do {
                guard let admission = journalCommitAdmission(
                    journal: journal,
                    executionFenceToken: executionFenceToken
                ), try await journal.transition(
                    candidate.id,
                    stepId: nextStepId,
                    context: candidate.context,
                    admission: admission
                ) else { return }
            } catch {
                LogWarning(
                    "DeviceLegService: failed to persist presentation action outcome: \(error)"
                )
                return
            }
            pendingPresentationPurchasePlacements.removeValue(
                forKey: candidate.id
            )
            var continued = candidate
            continued.stepId = nextStepId
            continued.park = nil
            await continuePresentedRun(
                continued,
                release: release,
                executionFenceToken: executionFenceToken,
                signal: .init(),
                journal: journal
            )
            return
        }
    }

    private func presentationOutcomeMatches(
        _ event: NuxieEvent,
        effectId: String,
        runId: String,
        action: [String: ExperienceReleaseJSONValue],
        release: AuthenticatedDeviceLegRelease
    ) -> Bool {
        guard event.id == effectId else { return false }
        guard let type = DeviceLegActionType(action: action),
              type.isCommerce else { return false }
        guard type == .purchase else { return type == .restore }
        if let eventExperienceId = event.properties["experience_id"] as? String,
           eventExperienceId != release.descriptor.identity.experienceId {
            return false
        }
        guard let expectedPlacement = pendingPresentationPurchasePlacements[
                runId
              ] ?? deviceLegPresentationLiteralString(action["placementId"]),
              event.properties["placement_id"] as? String
                == expectedPlacement else {
            return false
        }
        return true
    }

    func onAppDidEnterBackground() async {
        foreground = false
        cancelWake()
    }

    func onAppWillEnterForeground() async {
        // Keep rendered execution closed while ProfileService revalidates the
        // foreground profile. Its commit callback is awaited by the lifecycle
        // worker, so resuming an existing presentation here could wait on the
        // presentation gate that same worker opens only after revalidation.
        foregroundReceiptResetCustomers.removeAll()
        await resetForegroundStateArmReceiptsIfNeeded()
    }

    func onAppBecameActive() async {
        // NuxieLifecycleCoordinator opens foreground presentation admission
        // before invoking this callback.
        foreground = true
        await resetForegroundStateArmReceiptsIfNeeded()
        guard initialized, let state = currentProfileState() else { return }
        await resumeParkedRuns(state: state, event: nil)
        await evaluateStateArms(state: state, kinds: nil)
    }

    func handleUserChange(
        from oldDistinctId: String,
        to newDistinctId: String
    ) async {
        cancelWake()
        pendingPresentationPurchasePlacements.removeAll()
        await presenter?.shutdownDeviceLegPresentation(
            ownerDistinctId: oldDistinctId
        )
        if let departing = journal,
           departing.distinctId == oldDistinctId {
            let retired = await abandon(departing)
            if retired, journal?.distinctId == oldDistinctId {
                journal = nil
            }
        }
        if profileState?.distinctId == oldDistinctId {
            _ = profileFence.advance()
            profileState = nil
            stateArmReceipts.removeAll()
            inFlightAttempts.removeAll()
            pendingPresentationDismissalContinuations.removeAll()
        }
        // IdentityService's own fence revokes the departing user's execution.
        // Do not advance the global execution fence here: a queued transition
        // may run after the new user's profile and journal are already live.
        clearRetainedReleaseCache()
        guard initialized, identity.getDistinctId() == newDistinctId else { return }
        await ensureJournal(for: newDistinctId)
        await resetForegroundStateArmReceiptsIfNeeded()
        await scheduleNextWake()
    }

    private func currentProfileState() -> ProfileState? {
        guard let state = profileState,
              state.distinctId == identity.getDistinctId() else { return nil }
        return state
    }

    private func isCurrent(_ state: ProfileState) -> Bool {
        profileState?.generation == state.generation
            && profileState?.distinctId == state.distinctId
            && identity.getDistinctId() == state.distinctId
    }

    private func retainReceipts(for snapshot: DeviceLegProfileCatalog.Snapshot) {
        stateArmReceipts.retain(stateArmReceiptKeys(for: snapshot))
    }

    private func resetForegroundStateArmReceiptsIfNeeded() async {
        let distinctId = identity.getDistinctId()
        guard !foregroundReceiptResetCustomers.contains(distinctId) else {
            return
        }
        let entryKind = DeviceLegEntryCondition.Kind.appForegrounded
        stateArmReceipts.remove { $0.entryKind == entryKind }
        guard let journal, journal.distinctId == distinctId else { return }
        do {
            try await journal.clearStateArmReceipts(entryKind: entryKind)
            foregroundReceiptResetCustomers.insert(distinctId)
        } catch {
            LogWarning("DeviceLegService: failed to reset foreground admission latch: \(error)")
        }
    }

    private func stateArmReceiptKeys(
        for snapshot: DeviceLegProfileCatalog.Snapshot
    ) -> Set<DeviceLegStateArmReceipt> {
        Set(snapshot.profile.armedLegs.compactMap { arm in
            arm.entryCondition.type == .event
                ? nil
                : DeviceLegStateArmReceipt(arm)
        })
    }

    private func openJournal(for distinctId: String) async {
        guard let storageScope else {
            journal = nil
            return
        }
        guard let journalDirectory else {
            LogError("DeviceLegService: durable journal directory unavailable")
            journal = nil
            return
        }
        do {
            let opened = try DeviceLegRunJournal(
                directory: journalDirectory,
                distinctId: distinctId,
                storageScope: storageScope,
                beforePersist: journalBeforePersist
            )
            clearRetainedReleaseCache()
            journal = opened
            try await presentationPublications.flushPending(
                in: opened,
                executionFenceToken: executionFence.token()
            )
            _ = try await opened.recover(at: dateProvider.now())
            _ = try await experimentExposures.flushPending(in: opened)
            try await DeviceLegReporter(journal: opened, events: events)
                .flushPending()
            _ = try await opened.finalizeRevocation()
            await scheduleNextWake()
        } catch {
            LogError("DeviceLegService: durable journal recovery failed: \(error)")
            journal = nil
        }
    }

    private func ensureJournal(for distinctId: String) async {
        guard storageScope != nil else { return }
        // A new-user profile can outrun the queued identity transition. Retire
        // every journal displaced during that race before installing another.
        while let displaced = journal,
              displaced.distinctId != distinctId {
            guard await abandon(displaced) else { return }
            guard identity.getDistinctId() == distinctId else { return }
            if journal?.distinctId == displaced.distinctId {
                journal = nil
            }
        }
        if let current = journal,
           current.distinctId == distinctId,
           revokingCustomers.contains(distinctId) {
            guard await abandon(current) else { return }
        }
        guard identity.getDistinctId() == distinctId,
              journal?.distinctId != distinctId else { return }
        await openJournal(for: distinctId)
    }

    @discardableResult
    private func abandon(_ journal: DeviceLegRunJournal) async -> Bool {
        revokingCustomers.insert(journal.distinctId)
        do {
            try await journal.abandonAll(at: dateProvider.now())
        } catch {
            LogWarning("DeviceLegService: failed to durably revoke device-leg journal: \(error)")
            return false
        }
        var finalized = false
        do {
            _ = try await experimentExposures.flushPending(in: journal)
            try await DeviceLegReporter(journal: journal, events: events)
                .flushPending()
            finalized = try await journal.finalizeRevocation()
        } catch {
            // Every run is already terminal and the durable marker blocks new
            // work. Recovery retries report delivery before clearing it.
            LogWarning("DeviceLegService: device-leg revocation report remains pending: \(error)")
        }
        if finalized {
            revokingCustomers.remove(journal.distinctId)
        }
        return finalized
    }

    private func evaluateStateArms(
        state: ProfileState,
        kinds: Set<DeviceLegEntryCondition.Kind>?
    ) async {
        guard isCurrent(state) else { return }
        for arm in state.snapshot.profile.armedLegs {
            let kind = arm.entryCondition.type
            guard kind != .event, kinds?.contains(kind) ?? true else { continue }
            await attemptStart(arm, state: state, event: nil)
        }
        await scheduleNextWake()
    }

    private func attemptStart(
        _ arm: ArmedDeviceLeg,
        state: ProfileState,
        event: NuxieEvent?
    ) async {
        let stateKey = StateArmKey(arm)
        guard arm.entryCondition.type == .event
                || !stateArmReceipts.contains(stateKey),
              let journal,
              journal.distinctId == state.distinctId,
              !revokingCustomers.contains(journal.distinctId),
              let release = state.snapshot.releasesByDigest[
                arm.reference.descriptorSha256
              ], let releasePin = state.snapshot.profile.releases.first(where: {
                $0.envelope.descriptorSha256
                    == arm.reference.descriptorSha256
              }), release.descriptor.leg.screens.isEmpty || foreground else { return }

        let attempt = AttemptKey(
            arm: stateKey,
            eventId: event?.id,
            profileGeneration: state.generation
        )
        guard inFlightAttempts.insert(attempt).inserted else { return }
        defer { inFlightAttempts.remove(attempt) }

        let features = ClosureFeatureQueries(access: featureAccess)
        let history = IREventQueriesAdapter(
            eventLog: events,
            distinctId: state.distinctId,
            additionalEvents: [],
            now: { [dateProvider] in dateProvider.now() }
        )
        guard await entryMatches(
            arm,
            state: state,
            event: event,
            history: history,
            features: features
        ) else { return }
        let entitlementSuppressed = await entitlementGateSuppresses(
            release.descriptor.leg.entitlementGate,
            features: features
        )
        guard !entitlementSuppressed, isCurrent(state) else { return }

        // The optimistic start check is deliberately repeated after every
        // suspending gate and immediately before the first durable side effect.
        guard await entryMatches(
            arm,
            state: state,
            event: event,
            history: history,
            features: features
        ), isCurrent(state),
              let context = DeviceLegBoundaryProjector.inputContext(
                arm: arm,
                event: event,
                boundary: release.descriptor.leg.inputs
              ) else { return }

        let admittedArm = ArmedDeviceLeg(
            reference: arm.reference,
            binding: arm.binding,
            entryCondition: arm.entryCondition,
            context: context
        )
        let presentationReservation = await presentationReservation(
            for: release,
            distinctId: state.distinctId
        )
        if presenter != nil,
           !release.descriptor.leg.screens.isEmpty,
           presentationReservation == nil {
            // Presentation contention never consumes an arm. State arms are
            // re-evaluated by the capacity callback; event arms wait for the
            // next matching event, preserving the canonical no-queue rule.
            return
        }
        await withPresentationReservation(presentationReservation) {
            guard let profileFenceToken = profileFence.token(
                ifCurrent: state.generation
            ) else { return }
            let executionFenceToken = executionFence.token()
            do {
                guard let run = try await journal.admit(
                    arm: admittedArm,
                    release: releasePin,
                    artifactSource: state.artifacts?.source(
                        for: release.descriptorSHA256
                    ),
                    reentry: release.descriptor.leg.reentry,
                    entryStepId: release.descriptor.leg.entryStepId,
                    at: dateProvider.now(),
                    profileFence: profileFence,
                    profileFenceToken: profileFenceToken,
                    stateArmReceipt: arm.entryCondition.type == .event
                        ? nil
                        : stateKey,
                    onAdmitted: { [stateArmReceipts] in
                        guard arm.entryCondition.type != .event else { return }
                        stateArmReceipts.insert(stateKey)
                    }
                ) else { return }
                guard executionFence.isCurrent(executionFenceToken),
                      isCurrentIdentity(journal: journal) else {
                    await finishAfterAuthorityLoss(
                        run,
                        leg: release.descriptor.leg,
                        journal: journal,
                        executionFenceToken: executionFenceToken
                    )
                    return
                }
                let reporter = DeviceLegReporter(journal: journal, events: events)
                try await reporter.flushPending()
                guard let queued = try await journal.runs().first(where: {
                    $0.id == run.id && $0.startedQueued
                }) else { return }
                await execute(
                    queued,
                    release: release,
                    state: state,
                    executionFenceToken: executionFenceToken,
                    signal: executorSignal(event),
                    checkpoint: nil,
                    journal: journal,
                    presentationReservation: presentationReservation
                )
            } catch {
                LogWarning("DeviceLegService: failed to start device leg: \(error)")
            }
        }
    }

    private func entryMatches(
        _ arm: ArmedDeviceLeg,
        state: ProfileState,
        event: NuxieEvent?,
        history: IREventQueries,
        features: IRFeatureQueries
    ) async -> Bool {
        guard isCurrent(state) else { return false }
        return await DeviceLegEntryEvaluator.matches(
            arm.entryCondition,
            facts: state.snapshot.profile.facts,
            references: state.snapshot.releasesByDigest[
                arm.reference.descriptorSha256
            ]?.descriptor.leg.facts ?? .init(
                propertyKeys: [], segmentIds: [], experimentIds: []
            ),
            foreground: foreground,
            event: event,
            now: dateProvider.now(),
            events: history,
            features: features
        )
    }

    private func entitlementGateSuppresses(
        _ gate: DeviceLeg.EntitlementGate,
        features: IRFeatureQueries
    ) async -> Bool {
        guard gate.enabled else { return false }
        for product in gate.products where !product.featureIds.isEmpty {
            var fullyGranted = true
            for featureId in product.featureIds {
                if !(await features.has(featureId)) {
                    fullyGranted = false
                    break
                }
            }
            if fullyGranted { return true }
        }
        return false
    }

    private func presentationReservation(
        for release: AuthenticatedDeviceLegRelease,
        distinctId: String
    ) async -> (any DeviceLegPresentationReservation)? {
        guard !release.descriptor.leg.screens.isEmpty,
              let presenter else { return nil }
        return await presenter.reserveDeviceLegPresentation(
            ownerDistinctId: distinctId
        )
    }

    private func withPresentationReservation<Result>(
        _ reservation: (any DeviceLegPresentationReservation)?,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        do {
            let result = try await operation()
            await reservation?.release()
            return result
        } catch {
            await reservation?.release()
            throw error
        }
    }

    private func resumeParkedRuns(
        state: ProfileState,
        event: NuxieEvent?,
        excludingRunId: String? = nil
    ) async {
        guard isCurrent(state),
              event != nil || foreground,
              let journal else { return }
        do {
            for parked in try await journal.runs()
            where parked.park != nil
                && parked.completion == nil
                && parked.id != excludingRunId {
                guard isCurrent(state),
                      let profileFenceToken = profileFence.token(
                        ifCurrent: state.generation
                      ) else { return }
                if event == nil {
                    guard let wake = parked.park?.wakeAt,
                          wake <= dateProvider.now() else { continue }
                }
                let executionFenceToken = executionFence.token()
                guard let release = await release(
                    for: parked,
                    state: state,
                    journal: journal,
                    executionFenceToken: executionFenceToken
                ) else { continue }
                guard isCurrent(state),
                      profileFence.isCurrent(profileFenceToken),
                      executionFence.isCurrent(executionFenceToken),
                      isCurrentIdentity(journal: journal) else {
                    return
                }
                let checkpoint = parked.park.flatMap { park -> DeviceLegControlExecutor.Checkpoint? in
                    guard let wakeAt = park.wakeAt,
                          let wakeMillis = milliseconds(wakeAt) else { return nil }
                    let anchor = park.anchorAt.flatMap(milliseconds) ?? wakeMillis
                    return .init(
                        anchorAtMillis: anchor,
                        wakeAtMillis: wakeMillis
                    )
                }
                guard let resumed = try await journal.resumeParked(
                    parked.id,
                    profileFence: profileFence,
                    profileFenceToken: profileFenceToken
                ) else { continue }
                // A rendered leg can wake into a branch that never presents.
                // Reserve only if execution reaches navigate; execute also
                // recognizes an already-owned presentation before reserving.
                await execute(
                    resumed,
                    release: release,
                    state: state,
                    executionFenceToken: executionFenceToken,
                    signal: executorSignal(event),
                    checkpoint: checkpoint,
                    journal: journal
                )
            }
        } catch {
            LogWarning("DeviceLegService: failed to resume parked device leg: \(error)")
        }
        await scheduleNextWake()
    }

    private func release(
        for run: DeviceLegRun,
        state: ProfileState,
        journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> AuthenticatedDeviceLegRelease? {
        if let current = state.snapshot.releasesByDigest[
            run.reference.descriptorSha256
        ] {
            guard matches(current, reference: run.reference) else {
                await abandon(run, journal: journal)
                return nil
            }
            return current
        }
        if let cached = cachedRetainedRelease(
            descriptorSHA256: run.reference.descriptorSha256
        ) {
            guard matches(cached, reference: run.reference) else {
                removeCachedRetainedRelease(
                    descriptorSHA256: run.reference.descriptorSha256
                )
                await abandon(run, journal: journal)
                return nil
            }
            return cached
        }
        do {
            guard executionFence.isCurrent(executionFenceToken),
                  isCurrentIdentity(journal: journal) else { return nil }
            guard let pin = try await journal.releasePin(
                descriptorSHA256: run.reference.descriptorSha256
            ) else {
                throw DeviceLegJournalError.invalidState
            }
            guard executionFence.isCurrent(executionFenceToken),
                  isCurrentIdentity(journal: journal) else { return nil }
            let retained = try await pinnedReleaseAuthenticator(
                pin,
                run.reference
            )
            guard executionFence.isCurrent(executionFenceToken),
                  isCurrentIdentity(journal: journal),
                  matches(retained, reference: run.reference) else {
                throw DeviceLegJournalError.invalidState
            }
            cacheRetainedRelease(retained)
            return retained
        } catch {
            LogWarning(
                "DeviceLegService: retained device-leg release rejected: \(error)"
            )
            if executionFence.isCurrent(executionFenceToken),
               isCurrentIdentity(journal: journal) {
                await abandon(run, journal: journal)
            }
            return nil
        }
    }

    private func cachedRetainedRelease(
        descriptorSHA256: String
    ) -> AuthenticatedDeviceLegRelease? {
        guard let release = retainedReleasesByDigest[descriptorSHA256] else {
            return nil
        }
        retainedReleaseOrder.removeAll { $0 == descriptorSHA256 }
        retainedReleaseOrder.append(descriptorSHA256)
        return release
    }

    private func cacheRetainedRelease(
        _ release: AuthenticatedDeviceLegRelease
    ) {
        let descriptorSHA256 = release.descriptorSHA256
        let bytes = release.exactDescriptorBytes.count
        guard bytes <= Self.retainedReleaseCacheByteLimit else { return }
        removeCachedRetainedRelease(descriptorSHA256: descriptorSHA256)
        while retainedReleasesByDigest.count
                >= Self.retainedReleaseCacheCountLimit
                || retainedReleaseBytes + bytes
                    > Self.retainedReleaseCacheByteLimit {
            guard let oldest = retainedReleaseOrder.first else { break }
            removeCachedRetainedRelease(descriptorSHA256: oldest)
        }
        retainedReleasesByDigest[descriptorSHA256] = release
        retainedReleaseOrder.append(descriptorSHA256)
        retainedReleaseBytes += bytes
    }

    private func removeCachedRetainedRelease(
        descriptorSHA256: String
    ) {
        if let removed = retainedReleasesByDigest.removeValue(
            forKey: descriptorSHA256
        ) {
            retainedReleaseBytes -= removed.exactDescriptorBytes.count
        }
        retainedReleaseOrder.removeAll { $0 == descriptorSHA256 }
    }

    private func clearRetainedReleaseCache() {
        retainedReleasesByDigest.removeAll(keepingCapacity: false)
        retainedReleaseOrder.removeAll(keepingCapacity: false)
        retainedReleaseBytes = 0
    }

    private func matches(
        _ release: AuthenticatedDeviceLegRelease,
        reference: ArmedDeviceLeg.Reference
    ) -> Bool {
        release.descriptorSHA256 == reference.descriptorSha256
            && release.descriptor.identity.experienceId
                == reference.experienceId
            && release.descriptor.identity.experienceVersionId
                == reference.versionId
            && release.descriptor.leg.id == reference.legId
    }

    private func abandon(
        _ run: DeviceLegRun,
        journal: DeviceLegRunJournal
    ) async {
        do {
            try await journal.complete(
                run.id,
                outcome: "abandoned",
                at: dateProvider.now(),
                responseOutputs: run.context.responses
            )
            _ = try await experimentExposures.flushPending(in: journal)
            try await DeviceLegReporter(journal: journal, events: events)
                .flushPending()
        } catch {
            LogWarning(
                "DeviceLegService: failed to abandon retained device leg: \(error)"
            )
        }
    }

    private func handlePresentationBatch(
        _ batch: ScreenEmissionBatch,
        runId: String,
        release: AuthenticatedDeviceLegRelease,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> Bool {
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              isCurrentIdentity(journal: journal) else {
            return false
        }
        let runs: [DeviceLegRun]
        do {
            runs = try await journal.runs()
        } catch {
            return false
        }
        guard var run = runs.first(where: {
            $0.id == runId && $0.completion == nil
        }), batch.journeyId == run.journeyId else { return false }
        let leg = release.descriptor.leg
        let screenId = batch.source.screenId
        guard leg.screens.contains(where: { $0.id == screenId }),
              await presenter?.ownsDeviceLegPresentation(
                owner: .init(
                    journeyId: run.journeyId,
                    distinctId: journal.distinctId
                )
              ) == true else { return false }
        // Purchase and restore outcomes correlate to the effect receipt on the
        // current cursor. Another renderer batch must not transition that
        // cursor, even back to itself, because transition removes the receipt
        // and would permit a second StoreKit operation with a new effect ID.
        guard !isAwaitingPresentationCommerceOutcome(run, in: leg) else {
            return false
        }
        let expectedStepId = run.stepId
        let expectedCheckpoint = controlCheckpoint(from: run.park)
        let responseCaptures = Set(
            leg.screens.first(where: { $0.id == screenId })?.responseCaptures ?? []
        )
        var context = run.context
        var responses = context.responses
        var batchResponsesChanged = false
        var routedEvent: NuxieEvent?
        var routeStepId: String?
        var publicationItems: [DeviceLegRun.PendingPresentationPublication.Item] = []
        publicationItems.reserveCapacity(batch.emissions.count)

        for emission in batch.emissions {
            if emission.name == SystemEventNames.responseSet {
                guard case .string(let field)? = emission.payload["field"],
                      let value = emission.payload["value"],
                      responseCaptures.contains(field) else {
                    return false
                }
                responses[field] = value.releaseJSONValue
                batchResponsesChanged = true
                continue
            }
            if emission.name == SystemEventNames.responseUnset {
                guard case .string(let field)? = emission.payload["field"],
                      responseCaptures.contains(field) else {
                    return false
                }
                responses[field] = nil
                batchResponsesChanged = true
                continue
            }
            guard let occurredAt = DeviceLegPresentationEventProjector.date(
                emission.occurredAt
            ),
                  milliseconds(occurredAt) != nil else {
                return false
            }
            let properties = DeviceLegPresentationEventProjector.values(
                payload: ExactJSONObject(
                    emission.payload.mapValues(\.releaseJSONValue)
                ),
                screenId: screenId,
                run: run
            )
            publicationItems.append(.init(
                name: emission.name,
                properties: properties,
                eventId: emission.id,
                occurredAt: occurredAt
            ))
        }

        context = ArmedDeviceLeg.Context(
            event: context.event,
            responses: responses
        )

        let publication = DeviceLegRun.PendingPresentationPublication(
            invocationId: batch.invocationId,
            context: context,
            items: publicationItems
        )
        do {
            guard let admission = journalCommitAdmission(
                journal: journal,
                executionFenceToken: executionFenceToken
            ), try await journal.stagePresentationPublication(
                run.id,
                expectedStepId: expectedStepId,
                expectedCheckpoint: expectedCheckpoint,
                publication: publication,
                admission: admission
            ) else { return false }
        } catch {
            LogWarning(
                "DeviceLegService: failed to stage renderer publication: \(error)"
            )
            return false
        }
        run.context = context

        guard let ordinaryItems = DeviceLegPresentationEventProjector
            .routedItems(
            publication.items,
            distinctId: journal.distinctId
        ) else { return false }

        var publishedOrdinaryEvents = false
        if !ordinaryItems.isEmpty {
            guard let published = await presentationPublications.publish(
                ordinaryItems,
                forRunId: run.id,
                in: journal,
                executionFenceToken: executionFenceToken
            ) else { return false }
            publishedOrdinaryEvents = true
            guard published.remainsAuthorized else {
                return true
            }
            for item in ordinaryItems {
                guard let capture = published.captures[
                    item.request.eventId
                ],
                      capture.routesLocally,
                      let candidate = presentationRoute(
                        in: leg,
                        eventName: capture.event.name,
                        screenId: screenId
                      ) else {
                    continue
                }
                routedEvent = capture.event
                routeStepId = candidate
                break
            }
        }

        do {
            guard let current = try await journal.runs().first(where: {
                $0.id == run.id
                    && $0.completion == nil
                    && $0.stepId == expectedStepId
            }) else {
                return await acknowledgePublishedPresentationBatchFailure(
                    publishedOrdinaryEvents,
                    run: run,
                    context: ArmedDeviceLeg.Context(
                        event: context.event,
                        responses: responses
                    ),
                    leg: leg,
                    journal: journal,
                    executionFenceToken: executionFenceToken
                )
            }
            run = current
        } catch {
            return await acknowledgePublishedPresentationBatchFailure(
                publishedOrdinaryEvents,
                run: run,
                context: ArmedDeviceLeg.Context(
                    event: context.event,
                    responses: responses
                ),
                leg: leg,
                journal: journal,
                executionFenceToken: executionFenceToken
            )
        }

        if let routedEvent, let routeStepId {
            guard let controlEvent = controlEvent(routedEvent) else {
                return await acknowledgePublishedPresentationBatchFailure(
                    publishedOrdinaryEvents,
                    run: run,
                    context: ArmedDeviceLeg.Context(
                        event: context.event,
                        responses: responses
                    ),
                    leg: leg,
                    journal: journal,
                    executionFenceToken: executionFenceToken
                )
            }
            context = ArmedDeviceLeg.Context(
                event: controlEvent.properties,
                responses: responses
            )
            do {
                guard let admission = journalCommitAdmission(
                    journal: journal,
                    executionFenceToken: executionFenceToken
                ), try await journal.transition(
                    run.id,
                    stepId: routeStepId,
                    context: context,
                    clearingPresentationPublication: batch.invocationId,
                    admission: admission
                ) else {
                    return await acknowledgePublishedPresentationBatchFailure(
                        publishedOrdinaryEvents,
                        run: run,
                        context: context,
                        leg: leg,
                        journal: journal,
                        executionFenceToken: executionFenceToken
                    )
                }
            } catch {
                LogWarning("DeviceLegService: failed to persist screen route: \(error)")
                return await acknowledgePublishedPresentationBatchFailure(
                    publishedOrdinaryEvents,
                    run: run,
                    context: context,
                    leg: leg,
                    journal: journal,
                    executionFenceToken: executionFenceToken
                )
            }
            run.stepId = routeStepId
            run.context = context
            run.park = nil
            let signal = DeviceLegControlExecutor.Signal(
                event: controlEvent,
                responsesChanged: batchResponsesChanged
            )
            let continuedRun = run
            Task { [weak self] in
                await self?.continuePresentedRun(
                    continuedRun,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: signal,
                    presentationSource: batch.source,
                    journal: journal
                )
            }
            return true
        }
        guard await clearPresentationPublication(
            runId: run.id,
            invocationId: batch.invocationId,
            journal: journal,
            executionFenceToken: executionFenceToken
        ) else {
            return await acknowledgePublishedPresentationBatchFailure(
                publishedOrdinaryEvents,
                run: run,
                context: context,
                leg: leg,
                journal: journal,
                executionFenceToken: executionFenceToken
            )
        }
        run.pendingPresentationPublication = nil
        if batchResponsesChanged,
           stepAcceptsResponseChange(run.stepId, in: leg) {
            let continuedRun = run
            let checkpoint = controlCheckpoint(from: continuedRun.park)
            Task { [weak self] in
                await self?.continuePresentedRun(
                    continuedRun,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: .init(responsesChanged: true),
                    checkpoint: checkpoint,
                    presentationSource: batch.source,
                    journal: journal
                )
            }
        }
        return true
    }

    private func handlePresentationPermissionEvent(
        _ eventName: String,
        properties: UncheckedSendable<[String: Any]>,
        run: DeviceLegRun,
        identityFenceToken: IdentityFenceToken,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async {
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              await isCurrentIdentity(identityFenceToken, journal: journal) else {
            return
        }
        let scopedProperties = DeviceLegPresentationEventProjector.attributedProperties(
            properties.value,
            run: run
        )
        let scopedPropertiesBox = UncheckedSendable(scopedProperties)
        let admission = DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFenceToken,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
        _ = await events.captureAndRouteSystemEvent(
            .init(
                name: eventName,
                properties: scopedPropertiesBox.value,
                eventId: UUID.v7().uuidString,
                distinctId: journal.distinctId
            ),
            admission: admission
        )
    }

    private func capturePresentationPermissionEvent(
        _ event: DeviceLegPresentationPermissionEvent,
        eventId: String,
        run: DeviceLegRun,
        identityFenceToken: IdentityFenceToken,
        executionFenceToken: DeviceLegProfileFenceToken,
        journal: DeviceLegRunJournal
    ) async -> DurableTriggerCapture? {
        guard executionFence.isCurrent(executionFenceToken),
              await isCurrentIdentity(identityFenceToken, journal: journal) else {
            return nil
        }
        let scopedProperties = DeviceLegPresentationEventProjector.attributedProperties(
            Dictionary(
                uniqueKeysWithValues: event.properties.map {
                    ($0.key, $0.value as Any)
                }
            ),
            run: run
        )
        let scopedPropertiesBox = UncheckedSendable(scopedProperties)
        return await presentationPublications.capture(
            name: event.name,
            properties: scopedPropertiesBox,
            eventId: eventId,
            occurredAt: dateProvider.now(),
            forRunId: run.id,
            in: journal,
            identityFenceToken: identityFenceToken,
            executionFenceToken: executionFenceToken
        )
    }

    private func acknowledgePublishedPresentationBatchFailure(
        _ publishedOrdinaryEvents: Bool,
        run: DeviceLegRun,
        context: ArmedDeviceLeg.Context,
        leg: DeviceLeg,
        journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> Bool {
        guard publishedOrdinaryEvents else { return false }
        var abandonedRun = run
        abandonedRun.context = context
        guard let persisted = await persistCompletion(
            abandonedRun,
            outcome: "abandoned",
            leg: leg,
            journal: journal,
            executionFenceToken: executionFenceToken
        ) else {
            // The renderer keeps ownership of a rejected batch. Never retire
            // its response values until either the exact batch can retry or an
            // abandonment record containing them is durable.
            return false
        }
        // The renderer is awaiting this acknowledgement from inside its
        // navigation drain. The abandonment record and its collected responses
        // are already durable; let the callback unwind before report delivery
        // and presentation teardown try to join that same drain.
        Task { [weak self] in
            guard let self else { return }
            _ = await self.settlePersistedCompletion(
                abandonedRun,
                journal: journal,
                admission: persisted.admission,
                dismissPresentation: true
            )
        }
        return true
    }

    private func handlePresentationOutcome(
        _ outcome: DeviceLegSurfaceOutcome,
        screenId: String?,
        runId: String,
        release: AuthenticatedDeviceLegRelease,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> Bool {
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              isCurrentIdentity(journal: journal) else {
            return false
        }
        let runs: [DeviceLegRun]
        do {
            runs = try await journal.runs()
        } catch {
            return false
        }
        guard executionFence.isCurrent(executionFenceToken),
              isCurrentIdentity(journal: journal) else {
            return false
        }
        guard var run = runs.first(where: { $0.id == runId }) else {
            return false
        }
        if run.completion != nil {
            do {
                try await DeviceLegReporter(journal: journal, events: events)
                    .flushPending()
                let remainingRuns = try await journal.runs()
                return !remainingRuns.contains { $0.id == runId }
            } catch {
                LogWarning(
                    "DeviceLegService: failed to retry completed presentation report: \(error)"
                )
                return false
            }
        }
        let leg = release.descriptor.leg
        guard outcome == .dismissed else {
            return await finish(
                run,
                outcome: "abandoned",
                leg: leg,
                journal: journal,
                dismissPresentation: false,
                executionFenceToken: executionFenceToken
            )
        }
        guard let routeStepId = presentationRoute(
            in: leg,
            eventName: "host_dismissed",
            screenId: screenId
        ) else {
            return await finish(
                run,
                outcome: "host_dismissed",
                leg: leg,
                journal: journal,
                dismissPresentation: false,
                executionFenceToken: executionFenceToken
            )
        }
        let hostDismissContext = ArmedDeviceLeg.Context(
            event: [:],
            responses: run.context.responses
        )
        do {
            guard let admission = journalCommitAdmission(
                journal: journal,
                executionFenceToken: executionFenceToken
            ), try await journal.transition(
                run.id,
                stepId: routeStepId,
                context: hostDismissContext,
                admission: admission
            ) else { return false }
        } catch {
            LogWarning("DeviceLegService: failed to persist host-dismiss route: \(error)")
            return false
        }
        run.stepId = routeStepId
        run.context = hostDismissContext
        run.park = nil
        guard executionFence.isCurrent(executionFenceToken),
              isCurrentIdentity(journal: journal) else {
            return true
        }
        let now = milliseconds(dateProvider.now()) ?? 0
        pendingPresentationDismissalContinuations[run.id] = .init(
            run: run,
            release: release,
            executionFenceToken: executionFenceToken,
            occurredAtMillis: now,
            journal: journal
        )
        return true
    }

    private func handlePresentationFinished(runId: String) async {
        guard let pending = pendingPresentationDismissalContinuations
            .removeValue(forKey: runId) else {
            return
        }
        await continuePresentedRun(
            pending.run,
            release: pending.release,
            executionFenceToken: pending.executionFenceToken,
            signal: .init(event: .init(
                name: "host_dismissed",
                occurredAtMillis: pending.occurredAtMillis,
                properties: [:]
            )),
            journal: pending.journal
        )
    }

    private func handlePresentationScreenChanged(
        _ screenId: String,
        presentedRun: DeviceLegRun,
        release: AuthenticatedDeviceLegRelease,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> Bool {
        switch await handlePresentationLifecycleEvent(
            name: SystemEventNames.screenShown,
            payload: ["screen_id": .string(screenId)],
            screenId: screenId,
            presentedRun: presentedRun,
            release: release,
            executionFenceToken: executionFenceToken
        ) {
        case .accepted, .completed:
            return true
        case .rejected:
            return false
        }
    }

    private func handlePresentationScreenDismissed(
        _ screenId: String,
        revealingScreenId: String?,
        method: String,
        presentedRun: DeviceLegRun,
        release: AuthenticatedDeviceLegRelease,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> DeviceLegScreenDismissalResult {
        var payload: ExactJSONObject<ExperienceReleaseJSONValue> = [
            "screen_id": .string(screenId),
            "method": .string(method),
        ]
        if let revealingScreenId {
            payload["revealing_screen_id"] = .string(revealingScreenId)
        }
        switch await handlePresentationLifecycleEvent(
            name: SystemEventNames.screenDismissed,
            payload: payload,
            screenId: screenId,
            presentedRun: presentedRun,
            release: release,
            executionFenceToken: executionFenceToken,
            unhandledOutcome: revealingScreenId == nil
                ? (method == "error" ? "abandoned" : "host_dismissed")
                : nil,
            awaitContinuation: revealingScreenId == nil
        ) {
        case .accepted:
            return .handled
        case .completed:
            return .completed
        case .rejected:
            return .rejected
        }
    }

    private func handlePresentationProductsUnavailable(
        _ screenId: String,
        presentedRun: DeviceLegRun,
        release: AuthenticatedDeviceLegRelease,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> DeviceLegProductFailureResult {
        let parsedProductIds: [String] = release.descriptor.products.compactMap {
            product -> String? in
            guard case .object(let fields) = product,
                  case .string(let id)? = fields["id"] else { return nil }
            return id
        }
        let productIds = Array(Set(parsedProductIds)).sorted()
        switch await handlePresentationLifecycleEvent(
            name: SystemEventNames.productsUnavailable,
            payload: [
                "product_ids": .array(productIds.map {
                    ExperienceReleaseJSONValue.string($0)
                }),
            ],
            screenId: screenId,
            presentedRun: presentedRun,
            release: release,
            executionFenceToken: executionFenceToken,
            unhandledOutcome: "products_unavailable"
        ) {
        case .accepted:
            return .handled
        case .completed:
            return .completed
        case .rejected:
            return .rejected
        }
    }

    private func handlePresentationLifecycleEvent(
        name: String,
        payload: ExactJSONObject<ExperienceReleaseJSONValue>,
        screenId: String,
        presentedRun: DeviceLegRun,
        release: AuthenticatedDeviceLegRelease,
        executionFenceToken: DeviceLegProfileFenceToken,
        unhandledOutcome: String? = nil,
        awaitContinuation: Bool = false
    ) async -> PresentationLifecycleResult {
        let occurredAt = dateProvider.now()
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              isCurrentIdentity(journal: journal) else {
            return .rejected
        }
        guard let capture = await capturePresentationEvent(
                name: name,
                eventId: UUID.v7().uuidString,
                occurredAt: occurredAt,
                payload: payload,
                screenId: screenId,
                run: presentedRun,
                executionFenceToken: executionFenceToken,
                journal: journal
              ) else { return .rejected }
        let runs: [DeviceLegRun]
        do {
            runs = try await journal.runs()
        } catch {
            return .rejected
        }
        guard var run = runs.first(where: {
            $0.id == presentedRun.id && $0.completion == nil
        }) else { return .rejected }
        if !capture.routesLocally {
            if let unhandledOutcome {
                let completed = await finish(
                    run,
                    outcome: unhandledOutcome,
                    leg: release.descriptor.leg,
                    journal: journal,
                    dismissPresentation: false,
                    executionFenceToken: executionFenceToken
                )
                return completed ? .completed : .rejected
            }
            return .accepted
        }
        guard let controlEvent = controlEvent(capture.event) else {
            return .rejected
        }
        let routedEventName = controlEvent.name
        guard let routeStepId = presentationRoute(
            in: release.descriptor.leg,
            eventName: routedEventName,
            screenId: screenId
        ) else {
            if let unhandledOutcome {
                let completed = await finish(
                    run,
                    outcome: unhandledOutcome,
                    leg: release.descriptor.leg,
                    journal: journal,
                    dismissPresentation: false,
                    executionFenceToken: executionFenceToken
                )
                return completed ? .completed : .rejected
            }
            return .accepted
        }
        let context = ArmedDeviceLeg.Context(
            event: controlEvent.properties,
            responses: run.context.responses
        )
        do {
            guard let admission = journalCommitAdmission(
                journal: journal,
                executionFenceToken: executionFenceToken
            ), try await journal.transition(
                run.id,
                stepId: routeStepId,
                context: context,
                admission: admission
            ) else { return .rejected }
        } catch {
            LogWarning("DeviceLegService: failed to persist screen lifecycle route: \(error)")
            return .rejected
        }
        run.stepId = routeStepId
        run.context = context
        run.park = nil
        let dismissPresentationOnCompletion = !awaitContinuation
        let continueRun = { [weak self] in
            await self?.continuePresentedRun(
                run,
                release: release,
                executionFenceToken: executionFenceToken,
                signal: .init(event: .init(
                    name: controlEvent.name,
                    occurredAtMillis: controlEvent.occurredAtMillis,
                    properties: controlEvent.properties
                )),
                dismissPresentationOnCompletion: dismissPresentationOnCompletion,
                journal: journal
            )
        }
        if awaitContinuation {
            await continueRun()
            do {
                let remainsLive = try await journal.runs().contains {
                    $0.id == run.id && $0.completion == nil
                }
                return remainsLive ? .accepted : .completed
            } catch {
                return .rejected
            }
        } else {
            Task { await continueRun() }
        }
        return .accepted
    }

    private func capturePresentationEvent(
        name: String,
        eventId: String,
        occurredAt: Date,
        payload: ExactJSONObject<ExperienceReleaseJSONValue>,
        screenId: String,
        run: DeviceLegRun,
        executionFenceToken: DeviceLegProfileFenceToken,
        journal: DeviceLegRunJournal
    ) async -> DurableTriggerCapture? {
        guard let identityFence = identity.performWithCurrentIdentityFence(
            journal.distinctId,
            { _ in () }
        ), let properties = DeviceLegPresentationEventProjector.properties(
            payload: payload,
            screenId: screenId,
            run: run
        ) else { return nil }
        return await presentationPublications.capture(
            name: name,
            properties: UncheckedSendable(properties),
            eventId: eventId,
            occurredAt: occurredAt,
            forRunId: run.id,
            in: journal,
            identityFenceToken: identityFence.token,
            executionFenceToken: executionFenceToken
        )
    }

    private func stepAcceptsResponseChange(
        _ stepId: String,
        in leg: DeviceLeg
    ) -> Bool {
        guard let action = leg.steps.first(where: { $0.id == stepId })?.action,
              DeviceLegActionType(action: action) == .waitUntil,
              case .object(let trigger)? = action["trigger"],
              case .string(let kind)? = trigger["kind"] else {
            return false
        }
        return kind == "response_change"
            || kind == "event_or_response_change"
    }

    private func controlCheckpoint(
        from park: DeviceLegRun.Park?
    ) -> DeviceLegControlExecutor.Checkpoint? {
        guard let wakeAt = park?.wakeAt,
              let wakeMillis = milliseconds(wakeAt) else { return nil }
        let anchor = park?.anchorAt.flatMap(milliseconds) ?? wakeMillis
        return .init(anchorAtMillis: anchor, wakeAtMillis: wakeMillis)
    }

    private func continuePresentedRun(
        _ run: DeviceLegRun,
        release: AuthenticatedDeviceLegRelease,
        executionFenceToken: DeviceLegProfileFenceToken,
        signal: DeviceLegControlExecutor.Signal,
        checkpoint: DeviceLegControlExecutor.Checkpoint? = nil,
        presentationSource: ScreenEmissionSource? = nil,
        dismissPresentationOnCompletion: Bool = true,
        journal: DeviceLegRunJournal
    ) async {
        guard let state = currentProfileState(),
              executionFence.isCurrent(executionFenceToken),
              isCurrentIdentity(journal: journal) else {
            await finishAfterAuthorityLoss(
                run,
                leg: release.descriptor.leg,
                journal: journal,
                executionFenceToken: executionFenceToken
            )
            return
        }
        await execute(
            run,
            release: release,
            state: state,
            executionFenceToken: executionFenceToken,
            signal: signal,
            checkpoint: checkpoint,
            journal: journal,
            presentationSource: presentationSource,
            dismissPresentationOnCompletion: dismissPresentationOnCompletion
        )
    }

    private func presentationRoute(
        in leg: DeviceLeg,
        eventName: String,
        screenId: String?
    ) -> String? {
        screenId.flatMap { screenId in
            leg.routes.first(where: {
                $0.eventName == eventName
                    && $0.host.kind == .screen
                    && $0.host.screenId == screenId
            })?.entryStepId
        } ?? leg.routes.first(where: {
            $0.eventName == eventName && $0.host.kind == .journey
        })?.entryStepId
    }

    private func clearPresentationPublication(
        runId: String,
        invocationId: String,
        journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> Bool {
        do {
            guard let admission = journalCommitAdmission(
                journal: journal,
                executionFenceToken: executionFenceToken
            ), try await journal.clearPresentationPublication(
                runId,
                invocationId: invocationId,
                admission: admission
            ) else {
                return false
            }
            return true
        } catch {
            LogWarning(
                "DeviceLegService: failed to clear renderer publication: \(error)"
            )
            return false
        }
    }

    private func execute(
        _ initial: DeviceLegRun,
        release: AuthenticatedDeviceLegRelease,
        state: ProfileState,
        executionFenceToken: DeviceLegProfileFenceToken,
        signal initialSignal: DeviceLegControlExecutor.Signal,
        checkpoint initialCheckpoint: DeviceLegControlExecutor.Checkpoint?,
        journal: DeviceLegRunJournal,
        presentationSource: ScreenEmissionSource? = nil,
        dismissPresentationOnCompletion: Bool = true,
        presentationReservation initialPresentationReservation:
            (any DeviceLegPresentationReservation)? = nil
    ) async {
        let leg = release.descriptor.leg
        let steps = Dictionary(uniqueKeysWithValues: leg.steps.map { ($0.id, $0) })
        let appDefaultTimezone: String? = if case .string(let value)? =
            release.descriptor.metadata["appDefaultTimezone"] { value } else { nil }
        let executor = DeviceLegControlExecutor(
            timezones: timezones,
            currentDeviceTimezone: currentDeviceTimezone,
            appDefaultTimezone: appDefaultTimezone
        )
        var run = initial
        var checkpoint = initialCheckpoint
        var signal = initialSignal
        var presentationReservation = initialPresentationReservation

        for _ in 0..<10_000 {
            guard executionFence.isCurrent(executionFenceToken),
                  isCurrentIdentity(journal: journal) else {
                await finishAfterAuthorityLoss(
                    run,
                    leg: leg,
                    journal: journal,
                    executionFenceToken: executionFenceToken
                )
                return
            }
            guard let step = steps[run.stepId],
                  let now = milliseconds(dateProvider.now()) else {
                await finish(
                    run,
                    outcome: "abandoned",
                    leg: leg,
                    journal: journal,
                    dismissPresentation: dismissPresentationOnCompletion,
                    executionFenceToken: executionFenceToken
                )
                return
            }
            switch executor.evaluate(
                step: step,
                context: run.context,
                assignments: state.snapshot.profile.facts.assignments,
                nowMillis: now,
                checkpoint: checkpoint,
                signal: signal
            ) {
            case .advance(let stepId, let context, let experimentSelection):
                let experimentExposure: DeviceLegRun.ExperimentExposure?
                if let experimentSelection,
                   !run.experimentExposures.contains(where: {
                       $0.experimentId == experimentSelection.experimentId
                   }) {
                    let kind: DeviceLegRun.ExperimentExposure.Kind
                    let assignedVariantId: String?
                    switch experimentSelection.source {
                    case .profile:
                        kind = .assigned
                        assignedVariantId = experimentSelection.variantId
                    case .noAssignment:
                        kind = .fallback
                        assignedVariantId = nil
                    case .invalidAssignment(let variantId):
                        kind = .invalidAssignment
                        assignedVariantId = variantId
                    }
                    experimentExposure = .init(
                        experimentId: experimentSelection.experimentId,
                        variantId: experimentSelection.variantId,
                        assignedVariantId: assignedVariantId,
                        isHoldout: experimentSelection.isHoldout,
                        kind: kind,
                        eventId: UUID.v7().uuidString.lowercased(),
                        selectedAt: dateProvider.now(),
                        shownAt: nil,
                        queued: false
                    )
                } else {
                    experimentExposure = nil
                }
                do {
                    try await journal.transition(
                        run.id,
                        stepId: stepId,
                        context: context,
                        experimentExposure: experimentExposure
                    )
                } catch {
                    LogWarning("DeviceLegService: failed to persist control transition: \(error)")
                    return
                }
                run.stepId = stepId
                run.context = context
                if let experimentExposure {
                    run.experimentExposures.append(experimentExposure)
                }
                run.park = nil
                checkpoint = nil

            case .park(let stepId, let nextCheckpoint):
                do {
                    try await journal.transition(
                        run.id,
                        stepId: stepId,
                        context: run.context,
                        checkpoint: nextCheckpoint
                    )
                } catch {
                    LogWarning("DeviceLegService: failed to persist park point: \(error)")
                }
                await scheduleNextWake()
                return

            case .complete(let outcome):
                await finish(
                    run,
                    outcome: outcome,
                    leg: leg,
                    journal: journal,
                    dismissPresentation: dismissPresentationOnCompletion,
                    executionFenceToken: executionFenceToken
                )
                return

            case .dispatch(let stepId, let action):
                guard let identityFence = identity.performWithCurrentIdentityFence(
                    journal.distinctId,
                    { _ in () }
                ) else {
                    await finishAfterAuthorityLoss(
                        run,
                        leg: leg,
                        journal: journal,
                        executionFenceToken: executionFenceToken
                    )
                    return
                }
                let effectId: String
                do {
                    effectId = try await journal.claimEffect(
                        run.id,
                        stepId: stepId
                    )
                } catch {
                    LogWarning("DeviceLegService: failed to claim effect cursor: \(error)")
                    return
                }
                guard executionFence.isCurrent(executionFenceToken),
                      await isCurrentIdentity(
                    identityFence.token,
                    journal: journal
                ) else {
                    await finishAfterAuthorityLoss(
                        run,
                        leg: leg,
                        journal: journal,
                        executionFenceToken: executionFenceToken
                    )
                    return
                }
                if let presenter,
                   DeviceLegActionType(action: action) == .navigate {
                    guard case .string(let screenId)? = action["screenId"] else {
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                    switch await presenter.navigateDeviceLegPresentation(
                        owner: .init(
                            journeyId: run.journeyId,
                            distinctId: journal.distinctId
                        ),
                        screenId: screenId,
                        transition: action["transition"]
                    ) {
                    case .navigated:
                        // The runtime's visible-screen callback owns exposure.
                        // A navigation request completing is not itself proof
                        // that the selected variant reached the surface.
                        return
                    case .alreadyActive:
                        // A no-op navigation does not reactivate the renderer's
                        // current screen, so synthesize the lifecycle input the
                        // control graph would receive after a real transition.
                        await markExperimentExposuresShown(
                            forRunId: run.id,
                            journal: journal,
                            executionFenceToken: executionFenceToken
                        )
                        _ = await handlePresentationScreenChanged(
                            screenId,
                            presentedRun: run,
                            release: release,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    case .productsUnavailable:
                        // The runtime delegate owns the authenticated
                        // $products_unavailable route or terminal outcome.
                        return
                    case .noPresentation:
                        break
                    case .declined, .failed:
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                    let reserved: (any DeviceLegPresentationReservation)?
                    if let presentationReservation {
                        reserved = presentationReservation
                    } else {
                        reserved = await presenter.reserveDeviceLegPresentation(
                            ownerDistinctId: journal.distinctId
                        )
                    }
                    presentationReservation = nil
                    let pinnedArtifacts: DeviceLegPinnedReleaseArtifacts
                    do {
                        guard let retained = try await journal.pinnedArtifacts(
                            forRunId: run.id
                        ) else {
                            throw DeviceLegJournalError.invalidState
                        }
                        pinnedArtifacts = retained
                    } catch {
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                    let presentedRun = run
                    let presentationIdentityFenceToken = identityFence.token
                    let result = await presenter.presentDeviceLeg(.init(
                        release: release,
                        delivery: state.snapshot.profile.delivery,
                        pinnedArtifacts: pinnedArtifacts,
                        screenId: screenId,
                        owner: .init(
                            journeyId: run.journeyId,
                            distinctId: journal.distinctId
                        ),
                        reservation: reserved,
                        onScreenChanged: { [weak self] changedScreenId in
                            guard let self else { return false }
                            return await self.handlePresentationScreenChanged(
                                changedScreenId,
                                presentedRun: presentedRun,
                                release: release,
                                executionFenceToken: executionFenceToken
                            )
                        },
                        onScreenDismissed: {
                            [weak self] dismissedScreenId, revealingScreenId, method in
                            guard let self else { return .rejected }
                            return await self.handlePresentationScreenDismissed(
                                dismissedScreenId,
                                revealingScreenId: revealingScreenId,
                                method: method,
                                presentedRun: presentedRun,
                                release: release,
                                executionFenceToken: executionFenceToken
                            )
                        },
                        onProductsUnavailable: { [weak self] screenId in
                            guard let self else { return .rejected }
                            return await self.handlePresentationProductsUnavailable(
                                screenId,
                                presentedRun: presentedRun,
                                release: release,
                                executionFenceToken: executionFenceToken
                            )
                        },
                        onEmissionBatch: { [weak self] batch in
                            guard let self else { return false }
                            return await self.handlePresentationBatch(
                                batch,
                                runId: presentedRun.id,
                                release: release,
                                executionFenceToken: executionFenceToken
                            )
                        },
                        onPermissionEvent: {
                            [weak self] eventName, properties in
                            Task {
                                await self?.handlePresentationPermissionEvent(
                                    eventName,
                                    properties: properties,
                                    run: presentedRun,
                                    identityFenceToken: presentationIdentityFenceToken,
                                    executionFenceToken: executionFenceToken
                                )
                            }
                        },
                        onPresentationRevealed: { [weak self] in
                            guard let self else { return }
                            await self.markExperimentExposuresShown(
                                forRunId: presentedRun.id,
                                journal: journal,
                                executionFenceToken: executionFenceToken
                            )
                        },
                        onOutcome: { [weak self] outcome, activeScreenId in
                            guard let self else { return false }
                            return await self.handlePresentationOutcome(
                                outcome,
                                screenId: activeScreenId,
                                runId: presentedRun.id,
                                release: release,
                                executionFenceToken: executionFenceToken
                            )
                        },
                        onPresentationFinished: { [weak self] in
                            Task {
                                await self?.handlePresentationFinished(
                                    runId: presentedRun.id
                                )
                            }
                        }
                    ))
                    await reserved?.release()
                    switch result {
                    case .shown:
                        return
                    case .declined, .failed:
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                }
                let result: DeviceLegDispatchResult
                var presentationSignal: DeviceLegControlExecutor.Signal?
                if let presenter,
                   let actionType = DeviceLegActionType(action: action),
                   actionType.isPresentationOwned,
                   await presenter.ownsDeviceLegPresentation(
                    owner: .init(
                        journeyId: run.journeyId,
                        distinctId: journal.distinctId
                    )
                   ) {
                    guard let contextResolvedAction = resolvedPresentationAction(
                        action,
                        context: run.context
                    ), let resolvedAction = await presenter
                        .resolveDeviceLegPresentationAction(
                            owner: .init(
                                journeyId: run.journeyId,
                                distinctId: journal.distinctId
                            ),
                            action: contextResolvedAction,
                            source: presentationSource
                        )
                    else {
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                    if actionType == .purchase {
                        guard case .string(let placementId)? = resolvedAction[
                            "placementId"
                        ], !placementId.isEmpty else {
                            await finish(
                                run,
                                outcome: "abandoned",
                                leg: leg,
                                journal: journal,
                                dismissPresentation: dismissPresentationOnCompletion,
                                executionFenceToken: executionFenceToken
                            )
                            return
                        }
                        pendingPresentationPurchasePlacements[run.id] =
                            placementId
                    }
                    let presentationResult = await presenter
                        .dispatchDeviceLegPresentationAction(
                            owner: .init(
                                journeyId: run.journeyId,
                                distinctId: journal.distinctId
                            ),
                            action: resolvedAction,
                            effectId: effectId
                        )
                    guard executionFence.isCurrent(executionFenceToken),
                          await isCurrentIdentity(
                            identityFence.token,
                            journal: journal
                          ) else {
                        await finishAfterAuthorityLoss(
                            run,
                            leg: leg,
                            journal: journal,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                    switch presentationResult {
                    case .advanced(let outlet):
                        pendingPresentationPurchasePlacements.removeValue(
                            forKey: run.id
                        )
                        result = .outlet(outlet)
                    case .permissionResolved(let outlet, let event):
                        pendingPresentationPurchasePlacements.removeValue(
                            forKey: run.id
                        )
                        guard let capture = await capturePresentationPermissionEvent(
                            event,
                            eventId: effectId,
                            run: run,
                            identityFenceToken: identityFence.token,
                            executionFenceToken: executionFenceToken,
                            journal: journal
                        ) else {
                            await finish(
                                run,
                                outcome: "abandoned",
                                leg: leg,
                                journal: journal,
                                dismissPresentation: dismissPresentationOnCompletion,
                                executionFenceToken: executionFenceToken
                            )
                            return
                        }
                        presentationSignal = capture.routesLocally
                            ? executorSignal(capture.event)
                            : .init()
                        result = .outlet(outlet)
                    case .awaitingOutcome:
                        // Commerce remains on this claimed cursor until its
                        // correlated SDK outcome arrives.
                        return
                    case .handled, .productsUnavailable:
                        pendingPresentationPurchasePlacements.removeValue(
                            forKey: run.id
                        )
                        // Navigation-style actions continue through screen
                        // lifecycle callbacks.
                        return
                    case .noPresentation, .declined, .failed:
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                } else {
                    result = await dispatcher.dispatch(.init(
                        runId: run.id,
                        journeyId: run.journeyId,
                        generation: run.generation,
                        reference: run.reference,
                        release: release,
                        stepId: stepId,
                        action: action,
                        context: run.context,
                        effectId: effectId,
                        distinctId: journal.distinctId,
                        identityFence: identityFence.token,
                        executionFence: executionFence,
                        executionFenceToken: executionFenceToken
                    ))
                }
                guard executionFence.isCurrent(executionFenceToken),
                      await isCurrentIdentity(
                    identityFence.token,
                    journal: journal
                ) else {
                    await finishAfterAuthorityLoss(
                        run,
                        leg: leg,
                        journal: journal,
                        executionFenceToken: executionFenceToken
                    )
                    return
                }
                switch result {
                case .outlet(let outlet):
                    guard case .advance(let nextStepId, let context, _) = executor.selectOutlet(
                        step,
                        outlet: outlet,
                        context: run.context
                    ) else {
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion,
                            executionFenceToken: executionFenceToken
                        )
                        return
                    }
                    do {
                        try await journal.transition(
                            run.id,
                            stepId: nextStepId,
                            context: context
                        )
                    } catch {
                        LogWarning("DeviceLegService: failed to persist effect transition: \(error)")
                        return
                    }
                    run.stepId = nextStepId
                    run.context = context
                    run.park = nil
                    checkpoint = nil
                    if let presentationSignal {
                        signal = presentationSignal
                    }

                case .complete(let outcome):
                    await finish(
                        run,
                        outcome: outcome,
                        leg: leg,
                        journal: journal,
                        dismissPresentation: dismissPresentationOnCompletion,
                        executionFenceToken: executionFenceToken
                    )
                    return

                case .unsupported:
                    await finish(
                        run,
                        outcome: "abandoned",
                        leg: leg,
                        journal: journal,
                        dismissPresentation: dismissPresentationOnCompletion,
                        executionFenceToken: executionFenceToken
                    )
                    return

                case .failed:
                    await finish(
                        run,
                        outcome: "abandoned",
                        leg: leg,
                        journal: journal,
                        dismissPresentation: dismissPresentationOnCompletion,
                        executionFenceToken: executionFenceToken
                    )
                    return
                }

            case .invalid:
                await finish(
                    run,
                    outcome: "abandoned",
                    leg: leg,
                    journal: journal,
                    dismissPresentation: dismissPresentationOnCompletion,
                    executionFenceToken: executionFenceToken
                )
                return
            }
        }

        await finish(
            run,
            outcome: "abandoned",
            leg: leg,
            journal: journal,
            dismissPresentation: dismissPresentationOnCompletion,
            executionFenceToken: executionFenceToken
        )
    }

    private func markExperimentExposuresShown(
        forRunId runId: String,
        journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async {
        guard let admission = journalCommitAdmission(
            journal: journal,
            executionFenceToken: executionFenceToken
        ) else { return }
        await experimentExposures.markShown(
            forRunId: runId,
            in: journal,
            at: dateProvider.now(),
            admission: admission
        )
    }

    @discardableResult
    private func finish(
        _ run: DeviceLegRun,
        outcome: String,
        leg: DeviceLeg,
        journal: DeviceLegRunJournal,
        dismissPresentation: Bool = true,
        executionFenceToken: DeviceLegProfileFenceToken? = nil,
        requireCurrentIdentity: Bool = true
    ) async -> Bool {
        guard let persisted = await persistCompletion(
            run,
            outcome: outcome,
            leg: leg,
            journal: journal,
            executionFenceToken: executionFenceToken,
            requireCurrentIdentity: requireCurrentIdentity
        ) else { return false }
        return await settlePersistedCompletion(
            run,
            journal: journal,
            admission: persisted.admission,
            dismissPresentation: dismissPresentation
        )
    }

    private struct PersistedCompletion {
        let admission: DeviceLegCommitAdmission?
    }

    private func persistCompletion(
        _ run: DeviceLegRun,
        outcome: String,
        leg: DeviceLeg,
        journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken? = nil,
        requireCurrentIdentity: Bool = true
    ) async -> PersistedCompletion? {
        let projected = leg.completionOutputs[outcome].flatMap {
            DeviceLegBoundaryProjector.project(
                context: run.context,
                boundary: $0
            )
        }
        let finalOutcome = projected == nil && leg.completionOutputs[outcome] != nil
            ? "abandoned"
            : outcome
        do {
            let admission: DeviceLegCommitAdmission?
            if let executionFenceToken {
                guard let currentAdmission = journalCommitAdmission(
                    journal: journal,
                    executionFenceToken: executionFenceToken,
                    requireCurrentIdentity: requireCurrentIdentity
                ) else { return nil }
                admission = currentAdmission
            } else {
                admission = nil
            }
            guard try await journal.complete(
                run.id,
                outcome: finalOutcome,
                at: dateProvider.now(),
                eventOutputs: projected?.event ?? [:],
                responseOutputs: finalOutcome == "abandoned"
                    ? run.context.responses
                    : projected?.responses ?? [:],
                admission: admission
            ) else { return nil }
            return PersistedCompletion(admission: admission)
        } catch {
            LogWarning("DeviceLegService: failed to persist device leg completion: \(error)")
            await scheduleNextWake()
            return nil
        }
    }

    private func settlePersistedCompletion(
        _ run: DeviceLegRun,
        journal: DeviceLegRunJournal,
        admission: DeviceLegCommitAdmission?,
        dismissPresentation: Bool
    ) async -> Bool {
        do {
            _ = try await experimentExposures.flushPending(
                in: journal,
                admission: admission
            )
            try await DeviceLegReporter(journal: journal, events: events)
                .flushPending()
        } catch {
            LogWarning("DeviceLegService: failed to settle device leg completion: \(error)")
            await scheduleNextWake()
            return false
        }
        pendingPresentationDismissalContinuations.removeValue(forKey: run.id)
        pendingPresentationPurchasePlacements.removeValue(forKey: run.id)
        if dismissPresentation, let presenter {
            await presenter.finishDeviceLegPresentation(
                owner: .init(
                    journeyId: run.journeyId,
                    distinctId: journal.distinctId
                )
            )
        }
        await scheduleNextWake()
        return true
    }

    private func finishAfterAuthorityLoss(
        _ run: DeviceLegRun,
        leg: DeviceLeg,
        journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async {
        // Execution revocation owns teardown and abandonment. A bare identity
        // fence loss can also occur inside a host callback before the queued
        // identity transition reaches this actor; finish the departing
        // customer's run while still refusing to cross execution revocation.
        guard executionFence.isCurrent(executionFenceToken) else { return }
        _ = await finish(
            run,
            outcome: "abandoned",
            leg: leg,
            journal: journal,
            executionFenceToken: executionFenceToken,
            requireCurrentIdentity: false
        )
    }

    private func journalCommitAdmission(
        journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken,
        requireCurrentIdentity: Bool = true
    ) -> DeviceLegCommitAdmission? {
        guard requireCurrentIdentity else {
            return .executionOnly(
                identity: identity,
                executionFence: executionFence,
                executionFenceToken: executionFenceToken
            )
        }
        guard let identityFence = identity.performWithCurrentIdentityFence(
            journal.distinctId,
            { _ in () }
        ) else { return nil }
        return DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
    }

    private func isCurrentIdentity(journal: DeviceLegRunJournal) -> Bool {
        self.journal?.distinctId == journal.distinctId
            && journal.distinctId == identity.getDistinctId()
            && profileState?.distinctId == identity.getDistinctId()
    }

    private func isCurrentIdentity(
        _ token: IdentityFenceToken,
        journal: DeviceLegRunJournal
    ) async -> Bool {
        guard isCurrentIdentity(journal: journal) else { return false }
        return await MainActor.run {
            identity.publishIfCurrentIdentityFenceToken(token) {}
        }
    }

    private func executorSignal(
        _ event: NuxieEvent?
    ) -> DeviceLegControlExecutor.Signal {
        guard let event, let controlEvent = controlEvent(event) else {
            return .init()
        }
        return .init(event: controlEvent)
    }

    private func controlEvent(
        _ event: NuxieEvent
    ) -> DeviceLegControlExecutor.Event? {
        guard let occurredAt = milliseconds(event.timestamp) else { return nil }
        var properties = ExactJSONObject<ExperienceReleaseJSONValue>()
        for (key, value) in event.properties {
            if let converted = DeviceLegBoundaryProjector.jsonValue(value) {
                properties[key] = converted
            }
        }
        return .init(
            name: event.name,
            occurredAtMillis: occurredAt,
            properties: properties
        )
    }

    private func isAwaitingPresentationCommerceOutcome(
        _ run: DeviceLegRun,
        in leg: DeviceLeg
    ) -> Bool {
        guard run.effectReceipts[run.stepId] != nil,
              let action = leg.steps.first(where: { $0.id == run.stepId })?.action,
              let type = DeviceLegActionType(action: action) else {
            return false
        }
        return type.isCommerce
    }

    private func resolvedPresentationAction(
        _ action: [String: ExperienceReleaseJSONValue],
        context: ArmedDeviceLeg.Context
    ) -> [String: ExperienceReleaseJSONValue]? {
        guard let type = DeviceLegActionType(action: action) else { return nil }
        guard type == .openLink else { return action }
        guard let encoded = action["url"].flatMap({
            try? ExactJSONCodec.encode($0)
        }), let value = try? ExactJSONCodec.decode(
            JourneyValue.self,
            from: encoded
        ), case .string(let url)? = DeviceLegValues.resolve(
            value,
            context: context
        ) else {
            return nil
        }
        var resolved = action
        resolved["url"] = .string(url)
        return resolved
    }

    private func presentationDidBecomeAvailable() async {
        guard initialized,
              foreground,
              let state = currentProfileState() else { return }
        await resumeParkedRuns(state: state, event: nil)
        guard isCurrent(state) else { return }
        // Event-triggered arms deliberately wait for the next matching event.
        // State arms can be re-evaluated when capacity returns without storing
        // or replaying a presentation request.
        await evaluateStateArms(state: state, kinds: nil)
    }

    private func scheduleNextWake() async {
        cancelWake()
        guard foreground,
              let journal,
              let state = currentProfileState() else { return }
        let schedulingGeneration = wakeGeneration
        let next: Date?
        do {
            let now = dateProvider.now()
            next = try await journal.runs().compactMap { run in
                guard run.completion == nil,
                      let wake = run.park?.wakeAt,
                      wake > now else { return nil }
                return wake
            }.min()
        } catch {
            LogWarning("DeviceLegService: failed to inspect park points: \(error)")
            return
        }
        guard foreground,
              schedulingGeneration == wakeGeneration,
              self.journal?.distinctId == journal.distinctId,
              isCurrent(state),
              let next else { return }
        wakeGeneration &+= 1
        let generation = wakeGeneration
        let delay = max(0, next.timeIntervalSince(dateProvider.now()))
        let sleepProvider = sleepProvider
        wakeTask = Task { [weak self] in
            do {
                try await sleepProvider.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.wake(generation: generation, deadline: next)
        }
    }

    private func wake(generation: UInt64, deadline: Date) async {
        guard generation == wakeGeneration,
              foreground,
              dateProvider.now() >= deadline,
              let state = currentProfileState() else { return }
        wakeTask = nil
        await resumeParkedRuns(state: state, event: nil)
    }

    private func cancelWake() {
        wakeGeneration &+= 1
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded(.towardZero))
    }
}

extension DeviceLegService: DeviceLegServiceProtocol {}

private struct ClosureFeatureQueries: IRFeatureQueries {
    let access: DeviceLegService.FeatureAccessLookup

    func has(_ featureId: String) async -> Bool {
        await access(featureId)?.allowed ?? false
    }

    func isUnlimited(_ featureId: String) async -> Bool {
        await access(featureId)?.unlimited ?? false
    }

    func getBalance(_ featureId: String) async -> Double? {
        await access(featureId)?.balance
    }
}

private enum DeviceLegBoundaryProjector {
    static func inputContext(
        arm: ArmedDeviceLeg,
        event: NuxieEvent?,
        boundary: DeviceLeg.Boundary
    ) -> ArmedDeviceLeg.Context? {
        var eventValues = arm.context.event
        if let event {
            for field in boundary.eventFields {
                guard let key = string(field["key"]) else { return nil }
                if let value = event.properties[key] {
                    guard let converted = jsonValue(value) else { return nil }
                    eventValues[key] = converted
                }
            }
        }
        guard let projectedEvent = project(
            values: eventValues,
            fields: boundary.eventFields,
            response: false
        ), let projectedResponses = project(
            values: arm.context.responses,
            fields: boundary.responseFields,
            response: true
        ) else { return nil }
        return .init(event: projectedEvent, responses: projectedResponses)
    }

    static func project(
        context: ArmedDeviceLeg.Context,
        boundary: DeviceLeg.Boundary
    ) -> ArmedDeviceLeg.Context? {
        guard let event = project(
            values: context.event,
            fields: boundary.eventFields,
            response: false
        ), let responses = project(
            values: context.responses,
            fields: boundary.responseFields,
            response: true
        ) else { return nil }
        return .init(event: event, responses: responses)
    }

    static func jsonValue(_ value: Any) -> ExperienceReleaseJSONValue? {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            guard number.doubleValue.isFinite else { return nil }
            return .number(number.doubleValue)
        }
        if let value = value as? String { return .string(value) }
        if let values = value as? [Any] {
            var result: [ExperienceReleaseJSONValue] = []
            result.reserveCapacity(values.count)
            for value in values {
                guard let converted = jsonValue(value) else { return nil }
                result.append(converted)
            }
            return .array(result)
        }
        if let values = value as? [String: Any] {
            var result = ExactJSONObject<ExperienceReleaseJSONValue>()
            for (key, value) in values {
                guard let converted = jsonValue(value) else { return nil }
                result[key] = converted
            }
            return .object(result)
        }
        return nil
    }

    private static func project(
        values: ExactJSONObject<ExperienceReleaseJSONValue>,
        fields: [[String: ExperienceReleaseJSONValue]],
        response: Bool
    ) -> ExactJSONObject<ExperienceReleaseJSONValue>? {
        var result = ExactJSONObject<ExperienceReleaseJSONValue>()
        for field in fields {
            guard let key = string(field["key"]),
                  let type = string(field["type"]),
                  let required = bool(field["required"]) else { return nil }
            guard let value = values[key] else {
                if required { return nil }
                continue
            }
            guard valid(value, type: type, field: field, response: response) else {
                return nil
            }
            result[key] = value
        }
        return result
    }

    private static func valid(
        _ value: ExperienceReleaseJSONValue,
        type: String,
        field: [String: ExperienceReleaseJSONValue],
        response: Bool
    ) -> Bool {
        switch (type, value) {
        case ("number", .number(let value)):
            guard value.isFinite else { return false }
            if let minimum = number(field["min"]), value < minimum { return false }
            if let maximum = number(field["max"]), value > maximum { return false }
            return true
        case ("string", .string(let value)) where !response:
            return options(field["enum"]).map { $0.contains(value) } ?? true
        case ("text", .string) where response:
            return true
        case ("date", .string) where response:
            return true
        case ("enum", .string(let value)) where response:
            return options(field["options"])?.contains(value) == true
        case ("multi_enum", .array(let values)) where response:
            guard let allowed = options(field["options"]) else { return false }
            let selected = values.compactMap { string($0) }
            return selected.count == values.count
                && Set(selected).count == selected.count
                && selected.allSatisfy(allowed.contains)
        case ("boolean", .bool): return true
        case ("null", .null) where !response: return true
        case ("json", _) where !response: return true
        default: return false
        }
    }

    private static func string(_ value: ExperienceReleaseJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func bool(_ value: ExperienceReleaseJSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private static func number(_ value: ExperienceReleaseJSONValue?) -> Double? {
        guard case .number(let value)? = value else { return nil }
        return value
    }

    private static func options(
        _ value: ExperienceReleaseJSONValue?
    ) -> Set<String>? {
        guard case .array(let values)? = value else { return nil }
        let strings = values.compactMap(string)
        guard strings.count == values.count else { return nil }
        return Set(strings)
    }
}
