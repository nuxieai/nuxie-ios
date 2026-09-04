import Foundation

protocol JourneyProfileConsuming: AnyObject, Sendable {
    func profileDidCommit(
        _ snapshot: JourneyProfileCatalog.Snapshot,
        artifacts: PreparedJourneyArtifacts?,
        authority: ProfileDeliveryAuthority,
        admissionGeneration: UInt64,
        distinctId: String
    ) async
    func profileDidWithdraw(
        authority: ProfileDeliveryAuthority?,
        admissionGeneration: UInt64,
        distinctId: String
    ) async
    func profileDidClear(
        distinctId: String,
        admissionGeneration: UInt64
    ) async
    func profileDidClearAll(admissionGeneration: UInt64) async
}

protocol JourneyServiceProtocol: JourneyProfileConsuming {
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

extension JourneyServiceProtocol {
    func shutdown() async {}
}

/// Owns the complete local lifecycle of authenticated Journeys. The
/// profile catalog authenticates immutable programs; this actor evaluates
/// arms, journals every transition, and reports terminal boundaries through
/// EventLog's existing durable event queue.
actor JourneyService {
    typealias FeatureAccessLookup = @Sendable (String) async -> FeatureAccess?
    typealias StoreEntitlementLookup = @Sendable () async -> Set<String>
    typealias PinnedReleaseAuthenticator = @Sendable (
        JourneyReleaseProfileEntry,
        ArmedJourney.Reference
    ) async throws -> AuthenticatedJourneyRelease

    private struct ProfileState: Sendable {
        let distinctId: String
        let snapshot: JourneyProfileCatalog.Snapshot
        let artifacts: PreparedJourneyArtifacts?
        let generation: UInt64
    }

    private typealias StateArmKey = JourneyStateArmReceipt

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
        let run: JourneyRun
        let release: AuthenticatedJourneyRelease
        let executionFenceToken: JourneyProfileFenceToken
        let occurredAtMillis: Int64
        let journal: JourneyRunJournal
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
    private let experimentExposures: JourneyExperimentExposureCoordinator
    private let presentationPublications:
        JourneyPresentationPublicationCoordinator
    private let dateProvider: DateProviderProtocol
    private let sleepProvider: SleepProviderProtocol
    private let journalDirectory: URL?
    private let journalBeforePersist: (@Sendable () throws -> Void)?
    /// Production starts without a journal namespace and installs one only
    /// after profile transport authenticates the configured Nuxie app. Tests
    /// may inject a fixed scope for direct journal inspection.
    private var storageScope: JourneyStorageScope?
    private let acceptsProfileAuthorityScope: Bool
    private let featureAccess: FeatureAccessLookup
    private let storeEntitlements: StoreEntitlementLookup
    private let dispatcher: any JourneyDispatching
    private let presenter: (any JourneyPresenting)?
    private let presentationTrace: JourneyPresentationTraceCoordinator
    private let pinnedReleaseAuthenticator: PinnedReleaseAuthenticator
    private let timezones: SignedTimezoneBundle
    private let currentDeviceTimezone: TimeZone

    private var initialized = false
    /// Setup occurs while the host app is in its launch foreground session.
    /// Lifecycle notifications close and reopen this latch thereafter.
    private var foreground = true
    private var profileState: ProfileState?
    /// Last ProfileService publication admitted by this runtime. Transport
    /// generations fence callbacks that were current before an actor hop but
    /// arrive after a replacement profile or identity transition.
    private var profileDeliveryGeneration: UInt64 = 0
    /// One transport generation may clear the departing customer and then
    /// install the replacement customer's cached profile. Keep the per-user
    /// claim so both publications can share that generation without admitting
    /// an older callback from any customer.
    private var profileDeliveryGenerationsByDistinctId: [String: UInt64] = [:]
    /// A global clear invalidates every per-user generation at or below it.
    private var profileDeliveryGenerationFloor: UInt64 = 0
    /// Advances for every profile publication and linearizes entry admission.
    private let profileFence = JourneyProfileFence()
    /// Advances only when admitted execution authority is explicitly revoked.
    private let executionFence: JourneyProfileFence
    private var journal: JourneyRunJournal?
    private var retainedReleasesByDigest: [String: AuthenticatedJourneyRelease] = [:]
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
        storageScope: JourneyStorageScope? = .testFixture,
        featureAccess: @escaping FeatureAccessLookup,
        storeEntitlements: @escaping StoreEntitlementLookup = { [] },
        dispatcher: any JourneyDispatching,
        presenter: (any JourneyPresenting)? = nil,
        presentationTrace: JourneyPresentationTraceCoordinator = .init(
            recorder: DisabledExperiencePresentationTrace()
        ),
        pinnedReleaseAuthenticator: @escaping PinnedReleaseAuthenticator,
        timezones: SignedTimezoneBundle,
        currentDeviceTimezone: TimeZone = .current,
        journalBeforePersist: (@Sendable () throws -> Void)? = nil
    ) {
        self.identity = identity
        self.events = events
        let executionFence = JourneyProfileFence()
        self.executionFence = executionFence
        experimentExposures = JourneyExperimentExposureCoordinator(
            events: events
        )
        presentationPublications =
            JourneyPresentationPublicationCoordinator(
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
        self.storeEntitlements = storeEntitlements
        self.dispatcher = dispatcher
        self.presenter = presenter
        self.presentationTrace = presentationTrace
        self.pinnedReleaseAuthenticator = pinnedReleaseAuthenticator
        self.timezones = timezones
        self.currentDeviceTimezone = currentDeviceTimezone
    }

    deinit {
        wakeTask?.cancel()
    }
}

// MARK: - Runtime lifecycle and profile publication

extension JourneyService {
    func initialize() async {
        guard !initialized else { return }
        initialized = true
        await presenter?.setJourneyPresentationAvailabilityHandler {
            [weak self] in
            Task { await self?.presentationDidBecomeAvailable() }
        }
        if storageScope != nil {
            await openJournal(for: identity.getDistinctId())
        }
        await resetForegroundStateArmReceiptsIfNeeded()
        await resumeParkedRuns(event: nil)
        guard let state = currentProfileState() else { return }
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
        await presenter?.setJourneyPresentationAvailabilityHandler(nil)
        await profileDidClearAll()
        await experimentExposures.cancelAndAwaitRetries()
    }

    func profileDidCommit(
        _ snapshot: JourneyProfileCatalog.Snapshot,
        artifacts: PreparedJourneyArtifacts?,
        authority: ProfileDeliveryAuthority,
        admissionGeneration: UInt64,
        distinctId: String
    ) async {
        guard claimAuthenticatedProfileDelivery(
            authority: authority,
            admissionGeneration: admissionGeneration,
            distinctId: distinctId
        ) else { return }
        await commitProfile(
            snapshot,
            artifacts: artifacts,
            distinctId: distinctId
        )
    }

    /// Direct runtime tests use an injected fixed namespace and do not model
    /// the profile transport boundary.
    func profileDidCommit(
        _ snapshot: JourneyProfileCatalog.Snapshot,
        distinctId: String
    ) async {
        _ = advanceProfileDelivery(distinctId: distinctId)
        await commitProfile(snapshot, artifacts: nil, distinctId: distinctId)
    }
}

private extension JourneyService {
    private func claimAuthenticatedProfileDelivery(
        authority: ProfileDeliveryAuthority?,
        admissionGeneration: UInt64,
        distinctId: String
    ) -> Bool {
        guard identity.getDistinctId() == distinctId,
              canClaimProfileDelivery(
                admissionGeneration,
                distinctId: distinctId
              ), installProfileAuthority(authority) else { return false }
        return claimProfileDelivery(
            admissionGeneration,
            distinctId: distinctId
        )
    }

    private func canClaimProfileDelivery(
        _ admissionGeneration: UInt64,
        distinctId: String
    ) -> Bool {
        admissionGeneration >= profileDeliveryGeneration
            && admissionGeneration > profileDeliveryGenerationFloor
            && admissionGeneration
                > (profileDeliveryGenerationsByDistinctId[distinctId] ?? 0)
    }

    @discardableResult
    private func claimProfileDelivery(
        _ admissionGeneration: UInt64,
        distinctId: String
    ) -> Bool {
        guard canClaimProfileDelivery(
            admissionGeneration,
            distinctId: distinctId
        ) else { return false }
        profileDeliveryGeneration = max(
            profileDeliveryGeneration,
            admissionGeneration
        )
        profileDeliveryGenerationsByDistinctId[distinctId] =
            admissionGeneration
        return true
    }

    @discardableResult
    private func advanceProfileDelivery(distinctId: String) -> UInt64 {
        profileDeliveryGeneration &+= 1
        profileDeliveryGenerationsByDistinctId[distinctId] =
            profileDeliveryGeneration
        return profileDeliveryGeneration
    }

    @discardableResult
    private func claimProfileDeliveryClearAll(
        _ admissionGeneration: UInt64
    ) -> Bool {
        guard admissionGeneration > profileDeliveryGeneration else {
            return false
        }
        profileDeliveryGeneration = admissionGeneration
        profileDeliveryGenerationFloor = admissionGeneration
        profileDeliveryGenerationsByDistinctId.removeAll()
        return true
    }

    private func advanceProfileDeliveryClearAll() {
        profileDeliveryGeneration &+= 1
        profileDeliveryGenerationFloor = profileDeliveryGeneration
        profileDeliveryGenerationsByDistinctId.removeAll()
    }

    private func installProfileAuthority(
        _ authority: ProfileDeliveryAuthority?
    ) -> Bool {
        guard acceptsProfileAuthorityScope, let authority else { return true }
        let authenticatedScope = JourneyStorageScope(authority: authority)
        guard storageScope == nil || storageScope == authenticatedScope else {
            LogError("JourneyService: authenticated app authority changed")
            return false
        }
        storageScope = authenticatedScope
        return true
    }

    private func commitProfile(
        _ snapshot: JourneyProfileCatalog.Snapshot,
        artifacts: PreparedJourneyArtifacts?,
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
                LogWarning("JourneyService: failed to retain journal admission metadata: \(error)")
            }
        }
        guard let state = currentProfileState() else { return }
        await resumeParkedRuns(event: nil)
        await evaluateStateArms(state: state, kinds: nil)
    }
}

extension JourneyService {
    /// Stop admitting the withdrawn delivery without revoking runs that
    /// already own execution. Their release, artifacts, delivery origins,
    /// and assignments were pinned atomically at admission.
    func profileDidWithdraw(
        authority: ProfileDeliveryAuthority?,
        admissionGeneration: UInt64,
        distinctId: String
    ) async {
        // Reject a departing customer before touching journal ownership, and
        // reject an older callback before it can erase a newer same-customer
        // profile publication.
        guard claimAuthenticatedProfileDelivery(
            authority: authority,
            admissionGeneration: admissionGeneration,
            distinctId: distinctId
        ) else { return }
        await withdrawCurrentProfile(
            distinctId: distinctId,
            admissionGeneration: admissionGeneration
        )
    }

    /// Direct runtime tests do not model ProfileService's transport token.
    func profileDidWithdraw(
        authority: ProfileDeliveryAuthority?,
        distinctId: String
    ) async {
        guard installProfileAuthority(authority) else { return }
        let admissionGeneration = advanceProfileDelivery(
            distinctId: distinctId
        )
        await withdrawCurrentProfile(
            distinctId: distinctId,
            admissionGeneration: admissionGeneration
        )
    }

    private func withdrawCurrentProfile(
        distinctId: String,
        admissionGeneration: UInt64
    ) async {
        guard identity.getDistinctId() == distinctId else { return }
        if initialized {
            await ensureJournal(for: distinctId)
        }
        guard profileDeliveryGenerationsByDistinctId[distinctId]
                == admissionGeneration,
              identity.getDistinctId() == distinctId,
              profileState?.distinctId == distinctId
                || journal?.distinctId == distinctId else { return }
        _ = profileFence.advance()
        profileState = nil
        stateArmReceipts.removeAll()
        inFlightAttempts.removeAll()
        if let journal, journal.distinctId == distinctId {
            do {
                try await journal.retainStateArmReceipts([])
            } catch {
                LogWarning(
                    "JourneyService: failed to retire withdrawn profile receipts: \(error)"
                )
            }
        }
        await resumeParkedRuns(event: nil)
        await scheduleNextWake()
    }

    func profileDidClear(
        distinctId: String,
        admissionGeneration: UInt64
    ) async {
        guard claimProfileDelivery(
            admissionGeneration,
            distinctId: distinctId
        ) else { return }
        await clearProfile(distinctId: distinctId)
    }

    func profileDidClear(distinctId: String) async {
        _ = advanceProfileDelivery(distinctId: distinctId)
        await clearProfile(distinctId: distinctId)
    }

    private func clearProfile(distinctId: String) async {
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
        await presenter?.shutdownJourneyPresentation(
            ownerDistinctId: distinctId
        )
        if let journalToAbandon {
            await abandon(journalToAbandon)
        }
    }

    func profileDidClearAll(admissionGeneration: UInt64) async {
        guard claimProfileDeliveryClearAll(admissionGeneration) else { return }
        await clearAllProfiles()
    }

    func profileDidClearAll() async {
        advanceProfileDeliveryClearAll()
        await clearAllProfiles()
    }

    private func clearAllProfiles() async {
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
            await presenter?.shutdownJourneyPresentation(
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
        let traceTimestamp = ExperiencePresentationTimestamp.now(
            wallClock: dateProvider.now()
        )
        let presentationAttempt = presentationTrace.consumeEvent(
            id: event.id,
            at: traceTimestamp
        )
        defer {
            if let presentationAttempt {
                presentationTrace.completeRouting(
                    presentationAttempt,
                    at: .now(wallClock: dateProvider.now())
                )
            }
        }
        let directlyRoutedRunId = await presentationPublications
            .consumeDirectRoute(eventId: event.id)
        guard initialized,
              event.distinctId == identity.getDistinctId(),
              event.name != JourneyEvents.journeyStarted,
              event.name != JourneyEvents.journeyCompleted else { return }

        await resumeParkedRuns(
            event: event,
            excludingRunId: directlyRoutedRunId
        )
        await resumePresentationActionOutcome(
            event: event,
            excludingRunId: directlyRoutedRunId
        )
        guard let state = currentProfileState() else {
            await scheduleNextWake()
            return
        }
        guard isCurrent(state) else { return }
        guard admittedProfileGeneration == state.generation else {
            await scheduleNextWake()
            return
        }
        for arm in state.snapshot.profile.armedLegs
        where arm.entryCondition.type == .event
            && arm.entryCondition.eventName == event.name {
            await attemptStart(
                arm,
                state: state,
                event: event,
                presentationAttempt: presentationAttempt
            )
        }
        await scheduleNextWake()
    }
}

// MARK: - Presentation commerce outcomes

private extension JourneyService {
    private func resumePresentationActionOutcome(
        event: NuxieEvent,
        excludingRunId: String? = nil
    ) async {
        guard let route = JourneyActionType.presentationOutcomeRoute(
            eventName: event.name
        ),
              let journal,
              isCurrentIdentity(journal: journal) else { return }
        let candidates: [JourneyRun]
        do {
            candidates = try await journal.runs()
        } catch {
            return
        }
        for candidate in candidates
        where candidate.completion == nil
            && candidate.park == nil
            && candidate.id != excludingRunId {
            guard isCurrentIdentity(journal: journal) else { continue }
            let executionFenceToken = executionFence.token()
            guard let release = await release(
                for: candidate,
                state: currentProfileState(),
                journal: journal,
                executionFenceToken: executionFenceToken
            ) else { continue }
            let leg = release.descriptor.leg
            guard let step = leg.steps.first(where: {
                $0.id == candidate.stepId
            }), let action = step.action,
                  JourneyActionType(action: action) == route.actionType,
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
                    "JourneyService: failed to persist presentation action outcome: \(error)"
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
        action: [String: JourneyReleaseJSONValue],
        release: AuthenticatedJourneyRelease
    ) -> Bool {
        guard event.id == effectId else { return false }
        guard let type = JourneyActionType(action: action),
              type.isCommerce else { return false }
        guard type == .purchase else { return type == .restore }
        if let eventExperienceId = event.properties["experience_id"] as? String,
           eventExperienceId != release.descriptor.identity.experienceId {
            return false
        }
        guard let expectedPlacement = pendingPresentationPurchasePlacements[
                runId
              ] ?? journeyPresentationLiteralString(action["placementId"]),
              event.properties["placement_id"] as? String
                == expectedPlacement else {
            return false
        }
        return true
    }
}

// MARK: - Host lifecycle and identity transitions

extension JourneyService {
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
        await resumeParkedRuns(event: nil)
        guard initialized, let state = currentProfileState() else { return }
        await evaluateStateArms(state: state, kinds: nil)
    }

    func handleUserChange(
        from oldDistinctId: String,
        to newDistinctId: String
    ) async {
        cancelWake()
        pendingPresentationPurchasePlacements.removeAll()
        await presenter?.shutdownJourneyPresentation(
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
}

// MARK: - Admission, journal, and release recovery

private extension JourneyService {
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

    private func retainReceipts(for snapshot: JourneyProfileCatalog.Snapshot) {
        stateArmReceipts.retain(stateArmReceiptKeys(for: snapshot))
    }

    private func resetForegroundStateArmReceiptsIfNeeded() async {
        let distinctId = identity.getDistinctId()
        guard !foregroundReceiptResetCustomers.contains(distinctId) else {
            return
        }
        let entryKind = JourneyEntryCondition.Kind.appForegrounded
        stateArmReceipts.remove { $0.entryKind == entryKind }
        guard let journal, journal.distinctId == distinctId else { return }
        do {
            try await journal.clearStateArmReceipts(entryKind: entryKind)
            foregroundReceiptResetCustomers.insert(distinctId)
        } catch {
            LogWarning("JourneyService: failed to reset foreground admission latch: \(error)")
        }
    }

    private func stateArmReceiptKeys(
        for snapshot: JourneyProfileCatalog.Snapshot
    ) -> Set<JourneyStateArmReceipt> {
        Set(snapshot.profile.armedLegs.compactMap { arm in
            arm.entryCondition.type == .event
                ? nil
                : JourneyStateArmReceipt(arm)
        })
    }

    private func openJournal(for distinctId: String) async {
        guard let storageScope else {
            journal = nil
            return
        }
        guard let journalDirectory else {
            LogError("JourneyService: durable journal directory unavailable")
            journal = nil
            return
        }
        do {
            let opened = try JourneyRunJournal(
                directory: journalDirectory,
                distinctId: distinctId,
                storageScope: storageScope,
                beforePersist: journalBeforePersist
            )
            clearRetainedReleaseCache()
            journal = opened
            // A process break terminals every non-parked run before any
            // retained renderer route can advance it. Parked runs remain
            // eligible for publication recovery and current-fact wakeup.
            _ = try await opened.recover(at: dateProvider.now())
            guard await events.replayPendingStableRoutes(
                distinctId: distinctId
            ) else {
                throw JourneyJournalError.invalidState
            }
            try await recoverPendingPresentationPublications(in: opened)
            _ = try await experimentExposures.flushPending(in: opened)
            try await JourneyReporter(journal: opened, events: events)
                .flushPending()
            _ = try await opened.finalizeRevocation()
            await scheduleNextWake()
        } catch {
            LogError("JourneyService: durable journal recovery failed: \(error)")
            journal = nil
        }
    }

    private func recoverPendingPresentationPublications(
        in journal: JourneyRunJournal
    ) async throws {
        for run in try await journal.runs()
        where run.pendingPresentationPublication != nil {
            let executionFenceToken = executionFence.token()
            if run.completion != nil {
                guard await presentationPublications.recoverObservability(
                    run,
                    in: journal,
                    executionFenceToken: executionFenceToken
                ) else {
                    throw JourneyJournalError.invalidState
                }
                continue
            }
            guard let release = await release(
                for: run,
                state: currentProfileState(),
                journal: journal,
                executionFenceToken: executionFenceToken
            ) else {
                throw JourneyJournalError.invalidState
            }
            let disposition = await presentationPublications.recover(
                run,
                leg: release.descriptor.leg,
                in: journal,
                executionFenceToken: executionFenceToken
            )
            switch disposition {
            case .accepted:
                break
            case .continueExecution(let continuation):
                await continuePresentedRun(
                    continuation.run,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: continuation.signal,
                    checkpoint: continuation.checkpoint,
                    presentationSource: run.pendingPresentationPublication?
                        .source,
                    journal: journal
                )
            case .rejected, .publicationFailed:
                throw JourneyJournalError.invalidState
            }
            let retained = try await journal.runs().first { $0.id == run.id }
            guard retained?.pendingPresentationPublication == nil else {
                throw JourneyJournalError.invalidState
            }
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
    private func abandon(_ journal: JourneyRunJournal) async -> Bool {
        revokingCustomers.insert(journal.distinctId)
        do {
            try await journal.abandonAll(at: dateProvider.now())
        } catch {
            LogWarning("JourneyService: failed to durably revoke Journey journal: \(error)")
            return false
        }
        var finalized = false
        do {
            _ = try await experimentExposures.flushPending(in: journal)
            try await JourneyReporter(journal: journal, events: events)
                .flushPending()
            finalized = try await journal.finalizeRevocation()
        } catch {
            // Every run is already terminal and the durable marker blocks new
            // work. Recovery retries report delivery before clearing it.
            LogWarning("JourneyService: Journey revocation report remains pending: \(error)")
        }
        if finalized {
            revokingCustomers.remove(journal.distinctId)
        }
        return finalized
    }

    private func evaluateStateArms(
        state: ProfileState,
        kinds: Set<JourneyEntryCondition.Kind>?
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
        _ arm: ArmedJourney,
        state: ProfileState,
        event: NuxieEvent?,
        presentationAttempt: ExperiencePresentationAttempt? = nil
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
            release: release,
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
              let context = JourneyBoundaryProjector.inputContext(
                arm: arm,
                event: event,
                boundary: release.descriptor.leg.inputs
              ) else { return }

        let admittedArm = ArmedJourney(
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
                    executionSnapshot: .init(
                        delivery: state.snapshot.profile.delivery,
                        assignments: state.snapshot.profile.facts.assignments
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
                if let presentationAttempt {
                    presentationTrace.bind(
                        presentationAttempt,
                        toRunId: run.id,
                        journeyId: run.journeyId,
                        at: .now(wallClock: dateProvider.now())
                    )
                }
                let reporter = JourneyReporter(journal: journal, events: events)
                try await reporter.flushPending()
                guard let queued = try await journal.runs().first(where: {
                    $0.id == run.id && $0.startedQueued
                }) else { return }
                await execute(
                    queued,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: executorSignal(event),
                    checkpoint: nil,
                    journal: journal,
                    presentationReservation: presentationReservation
                )
            } catch {
                LogWarning("JourneyService: failed to start Journey: \(error)")
            }
        }
    }

    private func entryMatches(
        _ arm: ArmedJourney,
        state: ProfileState,
        event: NuxieEvent?,
        history: IREventQueries,
        features: IRFeatureQueries
    ) async -> Bool {
        guard isCurrent(state) else { return false }
        return await JourneyEntryEvaluator.matches(
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
        _ gate: Journey.EntitlementGate,
        release: AuthenticatedJourneyRelease,
        features: IRFeatureQueries
    ) async -> Bool {
        guard gate.enabled, !gate.products.isEmpty else { return false }
        let entitledStoreProductIds = await storeEntitlements()
        if !entitledStoreProductIds.isEmpty,
           let releaseProducts = try? decodeJourneyDocuments(
               JourneyReleaseProductDocument.self,
               from: release.descriptor.products
           ) {
            let ownedProducts = releaseProducts.filter {
                $0.store.platform == "apple_app_store"
                    && entitledStoreProductIds.contains($0.store.productId)
            }
            let ownedProductIds = Set(ownedProducts.map(\.id))
            for gatedProduct in gate.products {
                if ownedProductIds.contains(gatedProduct.productId) {
                    return true
                }
                let requiredFeatures = Set(gatedProduct.featureIds)
                guard !requiredFeatures.isEmpty else { continue }
                if ownedProducts.contains(where: { owned in
                    requiredFeatures.isSubset(of: Set(owned.entitlements.map {
                        $0.featureId ?? $0.id
                    }))
                }) {
                    return true
                }
            }
        }
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
        for release: AuthenticatedJourneyRelease,
        distinctId: String
    ) async -> (any JourneyPresentationReservation)? {
        guard !release.descriptor.leg.screens.isEmpty,
              let presenter else { return nil }
        return await presenter.reserveJourneyPresentation(
            ownerDistinctId: distinctId
        )
    }

    private func withPresentationReservation<Result>(
        _ reservation: (any JourneyPresentationReservation)?,
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
        event: NuxieEvent?,
        excludingRunId: String? = nil
    ) async {
        guard event != nil || foreground,
              let journal,
              isCurrentIdentity(journal: journal) else { return }
        do {
            for parked in try await journal.runs()
            where parked.park != nil
                && parked.completion == nil
                && parked.id != excludingRunId {
                guard isCurrentIdentity(journal: journal) else { return }
                if event == nil {
                    guard parked.park?.pendingEvent != nil
                            || parked.park?.pendingResponsesChanged == true
                            || parked.park?.wakeAt.map({
                                $0 <= dateProvider.now()
                            }) == true else { continue }
                }
                let executionFenceToken = executionFence.token()
                guard let release = await release(
                    for: parked,
                    state: currentProfileState(),
                    journal: journal,
                    executionFenceToken: executionFenceToken
                ) else { continue }
                let executionSnapshot = parked.executionSnapshot
                guard executionFence.isCurrent(executionFenceToken),
                      isCurrentIdentity(journal: journal) else {
                    return
                }
                let checkpoint = parked.park.flatMap { park -> JourneyControlExecutor.Checkpoint? in
                    guard let wakeAt = park.wakeAt,
                          let wakeMillis = JourneyTime.milliseconds(wakeAt) else {
                        return nil
                    }
                    let anchor = park.anchorAt.flatMap(
                        JourneyTime.milliseconds
                    ) ?? wakeMillis
                    return .init(
                        anchorAtMillis: anchor,
                        wakeAtMillis: wakeMillis
                    )
                }
                if !foreground, !release.descriptor.leg.screens.isEmpty {
                    if let event,
                       let controlEvent = controlEvent(event),
                       let checkpoint,
                       let step = release.descriptor.leg.steps.first(where: {
                           $0.id == parked.stepId
                       }), controlExecutor(for: release).parkedWaitAccepts(
                           controlEvent,
                           step: step,
                           context: parked.context,
                           assignments: executionSnapshot.assignments,
                           checkpoint: checkpoint
                       ), let admission = journalCommitAdmission(
                           journal: journal,
                           executionFenceToken: executionFenceToken
                       ) {
                        _ = try await journal.stageParkedEvent(
                            parked.id,
                            expectedStepId: parked.stepId,
                            expectedCheckpoint: checkpoint,
                            event: controlEvent,
                            admission: admission
                        )
                    }
                    continue
                }
                let pendingEvent = parked.park?.pendingEvent
                let pendingResponsesChanged = parked.park?
                    .pendingResponsesChanged == true
                guard let admission = journalCommitAdmission(
                    journal: journal,
                    executionFenceToken: executionFenceToken
                ) else { return }
                guard let resumed = try await journal.resumeParked(
                    parked.id,
                    admission: admission
                ) else { continue }
                // A rendered leg can wake into a branch that never presents.
                // Reserve only if execution reaches navigate; execute also
                // recognizes an already-owned presentation before reserving.
                await execute(
                    resumed,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: event.map(executorSignal)
                        ?? .init(
                            event: pendingEvent,
                            responsesChanged: pendingResponsesChanged
                        ),
                    checkpoint: checkpoint,
                    journal: journal
                )
            }
        } catch {
            LogWarning("JourneyService: failed to resume parked Journey: \(error)")
        }
        await scheduleNextWake()
    }

    private func release(
        for run: JourneyRun,
        state: ProfileState?,
        journal: JourneyRunJournal,
        executionFenceToken: JourneyProfileFenceToken
    ) async -> AuthenticatedJourneyRelease? {
        if let current = state?.snapshot.releasesByDigest[
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
                throw JourneyJournalError.invalidState
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
                throw JourneyJournalError.invalidState
            }
            cacheRetainedRelease(retained)
            return retained
        } catch {
            LogWarning(
                "JourneyService: retained journey release rejected: \(error)"
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
    ) -> AuthenticatedJourneyRelease? {
        guard let release = retainedReleasesByDigest[descriptorSHA256] else {
            return nil
        }
        retainedReleaseOrder.removeAll { $0 == descriptorSHA256 }
        retainedReleaseOrder.append(descriptorSHA256)
        return release
    }

    private func cacheRetainedRelease(
        _ release: AuthenticatedJourneyRelease
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
        _ release: AuthenticatedJourneyRelease,
        reference: ArmedJourney.Reference
    ) -> Bool {
        release.descriptorSHA256 == reference.descriptorSha256
            && release.descriptor.identity.experienceId
                == reference.experienceId
            && release.descriptor.identity.experienceVersionId
                == reference.versionId
            && release.descriptor.leg.id == reference.legId
    }

    private func abandon(
        _ run: JourneyRun,
        journal: JourneyRunJournal
    ) async {
        do {
            try await journal.complete(
                run.id,
                outcome: "abandoned",
                at: dateProvider.now(),
                responseOutputs: run.context.responses
            )
            _ = try await experimentExposures.flushPending(in: journal)
            try await JourneyReporter(journal: journal, events: events)
                .flushPending()
        } catch {
            LogWarning(
                "JourneyService: failed to abandon retained Journey: \(error)"
            )
        }
    }
}

// MARK: - Renderer batch publication

private extension JourneyService {
    private func handlePresentationBatch(
        _ batch: ScreenEmissionBatch,
        runId: String,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken
    ) async -> Bool {
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              isCurrentIdentity(journal: journal) else {
            return false
        }
        let runs: [JourneyRun]
        do {
            runs = try await journal.runs()
        } catch {
            return false
        }
        guard let run = runs.first(where: {
            $0.id == runId && $0.completion == nil
        }), batch.journeyId == run.journeyId else { return false }
        let leg = release.descriptor.leg
        let screenId = batch.source.screenId
        guard leg.screens.contains(where: { $0.id == screenId }),
              await presenter?.ownsJourneyPresentation(
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
        let disposition = await presentationPublications.process(
            batch,
            for: run,
            leg: leg,
            in: journal,
            executionFenceToken: executionFenceToken
        )
        switch disposition {
        case .rejected:
            return false
        case .accepted:
            return true
        case .continueExecution(let continuation):
            Task { [weak self] in
                await self?.continuePresentedRun(
                    continuation.run,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: continuation.signal,
                    checkpoint: continuation.checkpoint,
                    presentationSource: batch.source,
                    journal: journal
                )
            }
            return true
        case .publicationFailed(let failure):
            return await acknowledgePublishedPresentationBatchFailure(
                failure.publishedOrdinaryEvents,
                run: failure.run,
                context: failure.context,
                leg: leg,
                journal: journal,
                executionFenceToken: executionFenceToken
            )
        }
    }

    private func handlePresentationPermissionEvent(
        _ eventName: String,
        properties: UncheckedSendable<[String: Any]>,
        run: JourneyRun,
        identityFenceToken: IdentityFenceToken,
        executionFenceToken: JourneyProfileFenceToken
    ) async {
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              await isCurrentIdentity(identityFenceToken, journal: journal) else {
            return
        }
        let scopedProperties = JourneyPresentationEventProjector.attributedProperties(
            properties.value,
            run: run
        )
        let scopedPropertiesBox = UncheckedSendable(scopedProperties)
        let admission = JourneyCommitAdmission(
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
        _ event: JourneyPresentationPermissionEvent,
        eventId: String,
        run: JourneyRun,
        identityFenceToken: IdentityFenceToken,
        executionFenceToken: JourneyProfileFenceToken,
        journal: JourneyRunJournal
    ) async -> DurableTriggerCapture? {
        guard executionFence.isCurrent(executionFenceToken),
              await isCurrentIdentity(identityFenceToken, journal: journal) else {
            return nil
        }
        let scopedProperties = JourneyPresentationEventProjector.attributedProperties(
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
        run: JourneyRun,
        context: ArmedJourney.Context,
        leg: Journey,
        journal: JourneyRunJournal,
        executionFenceToken: JourneyProfileFenceToken
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
}

// MARK: - Presentation lifecycle

private extension JourneyService {
    private func handlePresentationOutcome(
        _ outcome: JourneySurfaceOutcome,
        screenId: String?,
        runId: String,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken
    ) async -> Bool {
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              isCurrentIdentity(journal: journal) else {
            return false
        }
        let runs: [JourneyRun]
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
                try await JourneyReporter(journal: journal, events: events)
                    .flushPending()
                let remainingRuns = try await journal.runs()
                return !remainingRuns.contains { $0.id == runId }
            } catch {
                LogWarning(
                    "JourneyService: failed to retry completed presentation report: \(error)"
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
        let hostDismissContext = ArmedJourney.Context(
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
            LogWarning("JourneyService: failed to persist host-dismiss route: \(error)")
            return false
        }
        run.stepId = routeStepId
        run.context = hostDismissContext
        run.park = nil
        guard executionFence.isCurrent(executionFenceToken),
              isCurrentIdentity(journal: journal) else {
            return true
        }
        let now = JourneyTime.milliseconds(dateProvider.now()) ?? 0
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
        presentedRun: JourneyRun,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken
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
        presentedRun: JourneyRun,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken
    ) async -> JourneyScreenDismissalResult {
        var payload: ExactJSONObject<JourneyReleaseJSONValue> = [
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
        presentedRun: JourneyRun,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken
    ) async -> JourneyProductFailureResult {
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
                    JourneyReleaseJSONValue.string($0)
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
        payload: ExactJSONObject<JourneyReleaseJSONValue>,
        screenId: String,
        presentedRun: JourneyRun,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken,
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
        let runs: [JourneyRun]
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
        let context = ArmedJourney.Context(
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
            LogWarning("JourneyService: failed to persist screen lifecycle route: \(error)")
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
        payload: ExactJSONObject<JourneyReleaseJSONValue>,
        screenId: String,
        run: JourneyRun,
        executionFenceToken: JourneyProfileFenceToken,
        journal: JourneyRunJournal
    ) async -> DurableTriggerCapture? {
        guard let identityFence = identity.performWithCurrentIdentityFence(
            journal.distinctId,
            { _ in () }
        ), let properties = JourneyPresentationEventProjector.properties(
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

    private func continuePresentedRun(
        _ run: JourneyRun,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken,
        signal: JourneyControlExecutor.Signal,
        checkpoint: JourneyControlExecutor.Checkpoint? = nil,
        presentationSource: ScreenEmissionSource? = nil,
        dismissPresentationOnCompletion: Bool = true,
        journal: JourneyRunJournal
    ) async {
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
        await execute(
            run,
            release: release,
            executionFenceToken: executionFenceToken,
            signal: signal,
            checkpoint: checkpoint,
            journal: journal,
            presentationSource: presentationSource,
            dismissPresentationOnCompletion: dismissPresentationOnCompletion
        )
    }

    private func presentationRoute(
        in leg: Journey,
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

}

// MARK: - Durable execution

private extension JourneyService {
    private func execute(
        _ initial: JourneyRun,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken,
        signal initialSignal: JourneyControlExecutor.Signal,
        checkpoint initialCheckpoint: JourneyControlExecutor.Checkpoint?,
        journal: JourneyRunJournal,
        presentationSource: ScreenEmissionSource? = nil,
        dismissPresentationOnCompletion: Bool = true,
        presentationReservation initialPresentationReservation:
            (any JourneyPresentationReservation)? = nil
    ) async {
        let leg = release.descriptor.leg
        let executionSnapshot = initial.executionSnapshot
        var coordinator = JourneyRunExecutionCoordinator(
            run: initial,
            assignments: executionSnapshot.assignments,
            release: release,
            signal: initialSignal,
            checkpoint: initialCheckpoint,
            journal: journal,
            timezones: timezones,
            currentDeviceTimezone: currentDeviceTimezone
        )
        var presentationReservation = initialPresentationReservation

        for _ in 0..<JourneyRunExecutionCoordinator.iterationLimit {
            let run = coordinator.run
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
            switch coordinator.command(at: dateProvider.now()) {
            case .advance(let command):
                do {
                    try await coordinator.commit(command)
                } catch {
                    LogWarning("JourneyService: failed to persist control transition: \(error)")
                    return
                }

            case .park(let command):
                do {
                    try await coordinator.commit(command)
                } catch {
                    LogWarning("JourneyService: failed to persist park point: \(error)")
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

            case .dispatch(let command):
                let action = command.action
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
                    effectId = try await coordinator.claimEffect(for: command)
                } catch {
                    LogWarning("JourneyService: failed to claim effect cursor: \(error)")
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
                   JourneyActionType(action: action) == .navigate {
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
                    do {
                        guard let admission = journalCommitAdmission(
                            journal: journal,
                            executionFenceToken: executionFenceToken
                        ), try await coordinator.bindExperimentExposures(
                            to: screenId,
                            admission: admission
                        ) else { return }
                    } catch {
                        LogWarning(
                            "JourneyService: failed to bind experiment exposure to presentation: \(error)"
                        )
                        return
                    }
                    switch await presenter.navigateJourneyPresentation(
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
                            screenId: screenId,
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
                    case .declined:
                        await parkPresentationRetry(
                            run,
                            stepId: command.step.id,
                            journal: journal,
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
                    let reserved: (any JourneyPresentationReservation)?
                    if let presentationReservation {
                        reserved = presentationReservation
                    } else {
                        reserved = await presenter.reserveJourneyPresentation(
                            ownerDistinctId: journal.distinctId
                        )
                    }
                    presentationReservation = nil
                    let pinnedArtifacts: JourneyPinnedReleaseArtifacts
                    do {
                        guard let retained = try await journal.pinnedArtifacts(
                            forRunId: run.id
                        ) else {
                            throw JourneyJournalError.invalidState
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
                    let presentationTraceContext = presentationTrace
                        .beginPresentation(
                            runId: presentedRun.id,
                            journeyId: presentedRun.journeyId,
                            experienceVersionId: release.descriptor.identity
                                .experienceVersionId,
                            at: .now(wallClock: dateProvider.now())
                        )
                    let result = await presenter.presentJourney(.init(
                        release: release,
                        delivery: executionSnapshot.delivery,
                        pinnedArtifacts: pinnedArtifacts,
                        screenId: screenId,
                        owner: .init(
                            journeyId: run.journeyId,
                            distinctId: journal.distinctId
                        ),
                        reservation: reserved,
                        presentationTraceContext: presentationTraceContext,
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
                        onPresentationRevealed: { [weak self] screenId in
                            guard let self else { return }
                            await self.markExperimentExposuresShown(
                                forRunId: presentedRun.id,
                                screenId: screenId,
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
                    switch result {
                    case .shown:
                        await reserved?.release()
                        return
                    case .declined:
                        await parkPresentationRetry(
                            run,
                            stepId: command.step.id,
                            journal: journal,
                            executionFenceToken: executionFenceToken
                        )
                        await reserved?.release()
                        return
                    case .failed:
                        await reserved?.release()
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
                let result: JourneyDispatchResult
                var presentationSignal: JourneyControlExecutor.Signal?
                if let presenter,
                   let actionType = JourneyActionType(action: action),
                   actionType.isPresentationOwned,
                   await presenter.ownsJourneyPresentation(
                    owner: .init(
                        journeyId: run.journeyId,
                        distinctId: journal.distinctId
                    )
                   ) {
                    guard let contextResolvedAction = resolvedPresentationAction(
                        action,
                        context: run.context
                    ), let resolvedAction = await presenter
                        .resolveJourneyPresentationAction(
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
                        .dispatchJourneyPresentationAction(
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
                        stepId: command.step.id,
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
                    do {
                        guard try await coordinator.commit(
                            outlet: outlet,
                            for: command,
                            presentationSignal: presentationSignal
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
                    } catch {
                        LogWarning("JourneyService: failed to persist effect transition: \(error)")
                        return
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
            coordinator.run,
            outcome: "abandoned",
            leg: leg,
            journal: journal,
            dismissPresentation: dismissPresentationOnCompletion,
            executionFenceToken: executionFenceToken
        )
    }

    private func markExperimentExposuresShown(
        forRunId runId: String,
        screenId: String,
        journal: JourneyRunJournal,
        executionFenceToken: JourneyProfileFenceToken
    ) async {
        guard let admission = journalCommitAdmission(
            journal: journal,
            executionFenceToken: executionFenceToken
        ) else { return }
        await experimentExposures.markShown(
            forRunId: runId,
            screenId: screenId,
            in: journal,
            at: dateProvider.now(),
            admission: admission
        )
    }

    @discardableResult
    private func finish(
        _ run: JourneyRun,
        outcome: String,
        leg: Journey,
        journal: JourneyRunJournal,
        dismissPresentation: Bool = true,
        executionFenceToken: JourneyProfileFenceToken? = nil,
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
        let admission: JourneyCommitAdmission?
    }

    private func persistCompletion(
        _ run: JourneyRun,
        outcome: String,
        leg: Journey,
        journal: JourneyRunJournal,
        executionFenceToken: JourneyProfileFenceToken? = nil,
        requireCurrentIdentity: Bool = true
    ) async -> PersistedCompletion? {
        let projected = leg.completionOutputs[outcome].flatMap {
            JourneyBoundaryProjector.project(
                context: run.context,
                boundary: $0
            )
        }
        let finalOutcome = projected == nil && leg.completionOutputs[outcome] != nil
            ? "abandoned"
            : outcome
        do {
            let admission: JourneyCommitAdmission?
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
            LogWarning("JourneyService: failed to persist Journey completion: \(error)")
            await scheduleNextWake()
            return nil
        }
    }

    private func settlePersistedCompletion(
        _ run: JourneyRun,
        journal: JourneyRunJournal,
        admission: JourneyCommitAdmission?,
        dismissPresentation: Bool
    ) async -> Bool {
        do {
            _ = try await experimentExposures.flushPending(
                in: journal,
                admission: admission
            )
            try await JourneyReporter(journal: journal, events: events)
                .flushPending()
        } catch {
            LogWarning("JourneyService: failed to settle Journey completion: \(error)")
            await scheduleNextWake()
            return false
        }
        pendingPresentationDismissalContinuations.removeValue(forKey: run.id)
        pendingPresentationPurchasePlacements.removeValue(forKey: run.id)
        if dismissPresentation, let presenter {
            await presenter.finishJourneyPresentation(
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
        _ run: JourneyRun,
        leg: Journey,
        journal: JourneyRunJournal,
        executionFenceToken: JourneyProfileFenceToken
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
        journal: JourneyRunJournal,
        executionFenceToken: JourneyProfileFenceToken,
        requireCurrentIdentity: Bool = true
    ) -> JourneyCommitAdmission? {
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
        return JourneyCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
    }

    private func isCurrentIdentity(journal: JourneyRunJournal) -> Bool {
        self.journal?.distinctId == journal.distinctId
            && journal.distinctId == identity.getDistinctId()
    }

    private func isCurrentIdentity(
        _ token: IdentityFenceToken,
        journal: JourneyRunJournal
    ) async -> Bool {
        guard isCurrentIdentity(journal: journal) else { return false }
        return await MainActor.run {
            identity.publishIfCurrentIdentityFenceToken(token) {}
        }
    }

    private func executorSignal(
        _ event: NuxieEvent?
    ) -> JourneyControlExecutor.Signal {
        guard let event, let controlEvent = controlEvent(event) else {
            return .init()
        }
        return .init(event: controlEvent)
    }

    private func controlExecutor(
        for release: AuthenticatedJourneyRelease
    ) -> JourneyControlExecutor {
        let appDefaultTimezone: String? = if case .string(let value)? =
            release.descriptor.metadata["appDefaultTimezone"] { value } else { nil }
        return JourneyControlExecutor(
            timezones: timezones,
            currentDeviceTimezone: currentDeviceTimezone,
            appDefaultTimezone: appDefaultTimezone
        )
    }

    private func controlEvent(
        _ event: NuxieEvent
    ) -> JourneyControlExecutor.Event? {
        guard let occurredAt = JourneyTime.milliseconds(event.timestamp) else {
            return nil
        }
        var properties = ExactJSONObject<JourneyReleaseJSONValue>()
        for (key, value) in event.properties {
            if let converted = JourneyBoundaryProjector.jsonValue(value) {
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
        _ run: JourneyRun,
        in leg: Journey
    ) -> Bool {
        guard run.effectReceipts[run.stepId] != nil,
              let action = leg.steps.first(where: { $0.id == run.stepId })?.action,
              let type = JourneyActionType(action: action) else {
            return false
        }
        return type.isCommerce
    }

    private func resolvedPresentationAction(
        _ action: [String: JourneyReleaseJSONValue],
        context: ArmedJourney.Context
    ) -> [String: JourneyReleaseJSONValue]? {
        guard let type = JourneyActionType(action: action) else { return nil }
        guard type == .openLink else { return action }
        guard let encoded = action["url"].flatMap({
            try? ExactJSONCodec.encode($0)
        }), let value = try? ExactJSONCodec.decode(
            JourneyValue.self,
            from: encoded
        ), case .string(let url)? = JourneyValues.resolve(
            value,
            context: context
        ) else {
            return nil
        }
        var resolved = action
        resolved["url"] = .string(url)
        return resolved
    }
}

// MARK: - Presentation availability and wake scheduling

private extension JourneyService {
    private func parkPresentationRetry(
        _ run: JourneyRun,
        stepId: String,
        journal: JourneyRunJournal,
        executionFenceToken: JourneyProfileFenceToken
    ) async {
        guard let admission = journalCommitAdmission(
            journal: journal,
            executionFenceToken: executionFenceToken
        ) else { return }
        do {
            guard try await journal.park(
                run.id,
                stepId: stepId,
                until: dateProvider.now(),
                admission: admission
            ) else { return }
        } catch {
            LogWarning(
                "JourneyService: failed to preserve declined presentation: \(error)"
            )
        }
        await scheduleNextWake()
    }

    private func presentationDidBecomeAvailable() async {
        guard initialized, foreground else { return }
        await resumeParkedRuns(event: nil)
        guard let state = currentProfileState() else { return }
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
              isCurrentIdentity(journal: journal) else { return }
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
            LogWarning("JourneyService: failed to inspect park points: \(error)")
            return
        }
        guard foreground,
              schedulingGeneration == wakeGeneration,
              self.journal?.distinctId == journal.distinctId,
              isCurrentIdentity(journal: journal),
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
              dateProvider.now() >= deadline else { return }
        wakeTask = nil
        await resumeParkedRuns(event: nil)
    }

    private func cancelWake() {
        wakeGeneration &+= 1
        wakeTask?.cancel()
        wakeTask = nil
    }

}

extension JourneyService: JourneyServiceProtocol {}

private struct ClosureFeatureQueries: IRFeatureQueries {
    let access: JourneyService.FeatureAccessLookup

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

private enum JourneyBoundaryProjector {
    static func inputContext(
        arm: ArmedJourney,
        event: NuxieEvent?,
        boundary: Journey.Boundary
    ) -> ArmedJourney.Context? {
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
        context: ArmedJourney.Context,
        boundary: Journey.Boundary
    ) -> ArmedJourney.Context? {
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

    static func jsonValue(_ value: Any) -> JourneyReleaseJSONValue? {
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
            var result: [JourneyReleaseJSONValue] = []
            result.reserveCapacity(values.count)
            for value in values {
                guard let converted = jsonValue(value) else { return nil }
                result.append(converted)
            }
            return .array(result)
        }
        if let values = value as? [String: Any] {
            var result = ExactJSONObject<JourneyReleaseJSONValue>()
            for (key, value) in values {
                guard let converted = jsonValue(value) else { return nil }
                result[key] = converted
            }
            return .object(result)
        }
        return nil
    }

    private static func project(
        values: ExactJSONObject<JourneyReleaseJSONValue>,
        fields: [[String: JourneyReleaseJSONValue]],
        response: Bool
    ) -> ExactJSONObject<JourneyReleaseJSONValue>? {
        var result = ExactJSONObject<JourneyReleaseJSONValue>()
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
        _ value: JourneyReleaseJSONValue,
        type: String,
        field: [String: JourneyReleaseJSONValue],
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

    private static func string(_ value: JourneyReleaseJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func bool(_ value: JourneyReleaseJSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private static func number(_ value: JourneyReleaseJSONValue?) -> Double? {
        guard case .number(let value)? = value else { return nil }
        return value
    }

    private static func options(
        _ value: JourneyReleaseJSONValue?
    ) -> Set<String>? {
        guard case .array(let values)? = value else { return nil }
        let strings = values.compactMap(string)
        guard strings.count == values.count else { return nil }
        return Set(strings)
    }
}
