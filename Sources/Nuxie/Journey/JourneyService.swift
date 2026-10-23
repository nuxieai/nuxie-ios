import Foundation
import NuxieRuntime

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
    /// A fetch of the customer's copy of the setup begins. While they have
    /// no usable copy (it was withdrawn after a language change) their
    /// events wait, then replay against the copy when it lands.
    func profileRefetchWillBegin(distinctId: String) async
    /// That fetch has settled, with or without a copy. Once the customer's
    /// last fetch has settled, events still waiting go through.
    func profileRefetchDidSettle(distinctId: String) async
}

extension JourneyProfileConsuming {
    func profileRefetchWillBegin(distinctId: String) async {}
    func profileRefetchDidSettle(distinctId: String) async {}
}

protocol JourneyServiceProtocol: JourneyProfileConsuming {
    func prepareForEvents() async
    func finishStartupRouting() async
    func initialize() async
    func handleEvent(_ event: NuxieEvent) async
    /// `admittedProfileGeneration` is the setup generation sampled when the
    /// event was captured. Entry no longer depends on it: an event starts
    /// from the copy installed when it is handled.
    @discardableResult
    func handleEvent(
        _ event: NuxieEvent,
        admittedProfileGeneration: UInt64?
    ) async -> Bool
    func eventAdmissionGeneration() -> UInt64
    func onAppDidEnterBackground() async
    func onAppWillEnterForeground() async
    func onAppBecameActive() async
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
    func finishUserChangeRouting(to newDistinctId: String, profileSettled: Bool) async
    func shutdown() async
}

extension JourneyServiceProtocol {
    func prepareForEvents() async {}
    func finishStartupRouting() async {}
    func finishUserChangeRouting(to newDistinctId: String, profileSettled: Bool) async {}
    /// A transition whose profile refresh settled, admitted or failed.
    func finishUserChangeRouting(to newDistinctId: String) async {
        await finishUserChangeRouting(to: newDistinctId, profileSettled: true)
    }
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
        let originAdmission: JourneyCommitAdmission
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
    private let responseSaveDelivery: JourneyResponseSaveDelivery?
    private let beforeCommerceOutcomeDeferral: (@Sendable (String) async throws -> Void)?
    private let journalBeforePersist: (@Sendable () throws -> Void)?
    /// Production starts without a journal namespace and installs one only
    /// after profile transport authenticates the configured Nuxie app. Tests
    /// may inject a fixed scope for direct journal inspection.
    private var storageScope: JourneyStorageScope?
    private let acceptsProfileAuthorityScope: Bool
    private let featureAccess: FeatureAccessLookup
    private let offerFeatureAccess: FeatureAccessLookup
    private let storeEntitlements: StoreEntitlementLookup
    private let dispatcher: any JourneyDispatching
    private let presenter: (any JourneyPresenting)?
    private let presentationTrace: JourneyPresentationTraceCoordinator
    private let pinnedReleaseAuthenticator: PinnedReleaseAuthenticator
    private let timezones: SignedTimezoneBundle
    private let currentDeviceTimezone: TimeZone

    private var initialized = false
    private var startupRecoveryStarted = false
    private var startupRoutingDeferral: UInt64?
    private var startupProfileSettled = false
    private var userChangeRoutingDeferral: UInt64?
    /// The customer an identity transition is bringing in, from its first
    /// step until it finishes. Startup leaves their journal and routing to
    /// that transition.
    private var transitionInFlight: String?
    /// Fetches replacing a customer's saved copy that have not settled.
    private var profileRefetchesInFlight: [String: Int] = [:]
    /// Holds a customer's events while a refetch replaces their withdrawn
    /// copy, until the fresh copy lands or the last fetch settles.
    private var refetchRoutingDeferral: (distinctId: String, generation: UInt64)?
    /// The same identity used by the journal when consuming a timed park.
    /// Candidate and pending events can change without replacing the wait.
    private struct ParkCheckpoint: Equatable, Sendable {
        let stepId: String
        let anchorAt: Date?
        let wakeAt: Date

        init(stepId: String, checkpoint: JourneyControlExecutor.Checkpoint) {
            self.stepId = stepId
            self.anchorAt = JourneyTime.date(checkpoint.anchorAtMillis)
            self.wakeAt = JourneyTime.date(checkpoint.wakeAtMillis)
        }

        init?(_ run: JourneyRun) {
            guard run.completion == nil, let park = run.park, let wakeAt = park.wakeAt else { return nil }
            self.stepId = run.stepId
            self.anchorAt = park.anchorAt
            self.wakeAt = wakeAt
        }
    }
    private struct NativeRestoreRetry {
        let checkpoint: ParkCheckpoint
        let at: Date
    }
    /// Checkpoints currently queued for this journal instance.
    private var enqueuedDeadlines: Set<JourneyDeadline> = []
    private var deadlineRetryAt: [JourneyDeadline: Date] = [:]
    private var foregroundDeadlines: Set<JourneyDeadline> = []
    private var nativeRestoreRetryTasks: [String: Task<Void, Never>] = [:]
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
    private var journal: JourneyRunJournal? {
        didSet {
            journalGeneration &+= 1
            enqueuedDeadlines.removeAll()
            deadlineRetryAt.removeAll()
            foregroundDeadlines.removeAll()
            cancelWake()
        }
    }
    private var journalGeneration: UInt64 = 0
    private var recoveredJournalGeneration: UInt64?
    private var journalRecoveryOperation: (id: UUID, task: Task<Void, Never>)?
    typealias NativeValuesPreparer = @Sendable (ExperienceRunValues, AuthenticatedJourneyRelease,
        JourneyReleaseDelivery, JourneyPinnedReleaseArtifacts?) async throws -> Void
    typealias NativeValuesReader = @Sendable (ExperienceRunValues) async throws -> ExactJSONObject<JourneyReleaseJSONValue>
    typealias JournalRunsReader = @Sendable (JourneyRunJournal) async throws -> [JourneyRun]
    private let readNativeValues: NativeValuesReader
    private let readJournalRuns: JournalRunsReader
    private let prepareNativeValues: NativeValuesPreparer
    private var nativeValuesByRun: [String: (owner: String, values: ExperienceRunValues, policy: JourneyReleaseValuePolicy)] = [:]
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
    private struct RunExecutionKey: Hashable {
        let runID: String
        let owner: String
        let generation: UInt64
    }
    private var activeRunExecutions: [RunExecutionKey: Int] = [:]
    private var deferredCommerceOutcomes: [RunExecutionKey: NuxieEvent] = [:]
    private var commerceSettlementTasks: [RunExecutionKey: Task<Void, Never>] = [:]
    private var pendingPresentationDismissalContinuations: [
        String: PendingPresentationDismissalContinuation
    ] = [:]
    /// The renderer resolves purchase references against the active screen
    /// instance before starting commerce. Keep that exact value with the
    /// claimed run so only its matching SDK outcome can advance the cursor.
    private var pendingPresentationPurchasePlacements: [String: String] = [:]
    private let onPresentationContinuationFinished: (@Sendable () -> Void)?
    private var wakeTask: Task<Void, Never>?
    private var nativeRestoreRetries: [String: NativeRestoreRetry] = [:]
    private var wakeGeneration: UInt64 = 0

    init(
        identity: IdentityServiceProtocol,
        events: EventLogProtocol,
        dateProvider: DateProviderProtocol,
        sleepProvider: SleepProviderProtocol,
        journalDirectory: URL?,
        storageScope: JourneyStorageScope? = .testFixture,
        responseSaveDelivery: JourneyResponseSaveDelivery? = nil,
        featureAccess: @escaping FeatureAccessLookup,
        offerFeatureAccess: FeatureAccessLookup? = nil,
        storeEntitlements: @escaping StoreEntitlementLookup = { [] },
        dispatcher: any JourneyDispatching,
        presenter: (any JourneyPresenting)? = nil,
        prepareNativeValues: @escaping NativeValuesPreparer = { _, _, _, _ in },
        readNativeValues: @escaping NativeValuesReader = { try await $0.journeyValues() },
        readJournalRuns: @escaping JournalRunsReader = { try await $0.runs() },
        presentationTrace: JourneyPresentationTraceCoordinator = .init(
            recorder: DisabledExperiencePresentationTrace()
        ),
        pinnedReleaseAuthenticator: @escaping PinnedReleaseAuthenticator,
        timezones: SignedTimezoneBundle,
        currentDeviceTimezone: TimeZone = .current,
        journalBeforePersist: (@Sendable () throws -> Void)? = nil,
        beforeCommerceOutcomeDeferral: (@Sendable (String) async throws -> Void)? = nil,
        onPresentationContinuationFinished: (@Sendable () -> Void)? = nil
    ) {
        self.onPresentationContinuationFinished = onPresentationContinuationFinished
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
        self.responseSaveDelivery = responseSaveDelivery
        self.journalBeforePersist = journalBeforePersist
        self.beforeCommerceOutcomeDeferral = beforeCommerceOutcomeDeferral
        self.storageScope = storageScope
        acceptsProfileAuthorityScope = storageScope == nil
        self.featureAccess = featureAccess
        self.offerFeatureAccess = offerFeatureAccess ?? featureAccess
        self.storeEntitlements = storeEntitlements
        self.dispatcher = dispatcher
        self.presenter = presenter
        self.prepareNativeValues = prepareNativeValues
        self.readNativeValues = readNativeValues
        self.readJournalRuns = readJournalRuns
        self.presentationTrace = presentationTrace
        self.pinnedReleaseAuthenticator = pinnedReleaseAuthenticator
        self.timezones = timezones
        self.currentDeviceTimezone = currentDeviceTimezone
    }

    deinit {
        wakeTask?.cancel()
        for task in nativeRestoreRetryTasks.values { task.cancel() }
    }
}

// MARK: - Runtime lifecycle and profile publication

extension JourneyService {
    /// Install and repair durable state before EventLog releases buffered
    /// captures. This phase must never capture, query or replay EventLog events.
    func prepareForEvents() async {
        guard !initialized else { return }
        await events.setJourneyDeadlineHandler { [weak self] deadline in
            await self?.handleJourneyDeadline(deadline) ?? false
        }
        await events.setJourneyResumeRetryHandler { [weak self] in
            guard let self else { return true }
            do {
                try await self.resumeParkedRuns(event: nil)
                return true
            } catch {
                LogWarning("JourneyService: saved input resume will retry: \(error)")
                return false
            }
        }
        startupRoutingDeferral = await events.deferCommittedRouting()
        if startupOpensJournal(for: identity.getDistinctId()) {
            await prepareJournal(for: identity.getDistinctId())
        }
        initialized = true
        await presenter?.setJourneyPresentationAvailabilityHandler {
            [weak self] in
            Task { await self?.presentationDidBecomeAvailable() }
        }
    }

    /// Failed/offline profile startup must not retain live analytics forever.
    /// The generation prevents this fallback from opening a newer authenticated
    /// recovery gate if profile admission races prefetch completion.
    func finishStartupRouting() async {
        startupProfileSettled = true
        guard initialized, journal == nil,
              !awaitsIdentifiedProfile(identity.getDistinctId()),
              let generation = startupRoutingDeferral else { return }
        await events.resumeCommittedRouting(ifGeneration: generation)
    }

    func initialize() async {
        guard !startupRecoveryStarted else { return }
        startupRecoveryStarted = true
        await prepareForEvents()
        if startupOpensJournal(for: identity.getDistinctId()) {
            await openJournal(for: identity.getDistinctId())
        }
        if startupProfileSettled {
            await finishStartupRouting()
        }
        await resetForegroundStateArmReceiptsIfNeeded()
        try? await resumeParkedRuns(event: nil)
        guard let state = currentProfileState() else { return }
        await evaluateStateArms(state: state, kinds: nil)
    }

    func shutdown() async {
        guard initialized || profileState != nil || journal != nil else { return }
        // Revoke execution before asking the shared presenter to tear down its
        // surface. Renderer callbacks emitted by teardown then fail every
        // profile and execution-fence check.
        initialized = false
        startupRecoveryStarted = false
        startupRoutingDeferral = nil
        startupProfileSettled = false
        userChangeRoutingDeferral = nil
        transitionInFlight = nil
        profileRefetchesInFlight.removeAll()
        refetchRoutingDeferral = nil
        foreground = false
        cancelWake()
        await events.setJourneyDeadlineHandler(nil)
        await events.setJourneyResumeRetryHandler(nil)
        await presenter?.setJourneyPresentationAvailabilityHandler(nil)
        await profileDidClearAll()
        await experimentExposures.cancelAndAwaitRetries()
        await responseSaveDelivery?.shutdown()
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
        await activateResponseSaveDelivery()
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
        await activateResponseSaveDelivery()
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
        guard identity.getDistinctId() == distinctId,
              let deliveryGeneration = profileDeliveryGenerationsByDistinctId[distinctId] else { return }
        // A retained route carries the profile fence captured at replay admission.
        // Keep that profile installed until the shared recovery consumes it.
        if let operation = journalRecoveryOperation {
            await operation.task.value
        }
        guard identity.getDistinctId() == distinctId,
              profileDeliveryGenerationsByDistinctId[distinctId] == deliveryGeneration else { return }
        let routingGeneration = initialized && journal == nil
            ? await events.deferCommittedRouting() : nil
        guard identity.getDistinctId() == distinctId,
              profileDeliveryGenerationsByDistinctId[distinctId] == deliveryGeneration else {
            if let routingGeneration {
                await events.resumeCommittedRouting(ifGeneration: routingGeneration)
            }
            return
        }
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
        if journal == nil, let routingGeneration {
            await events.resumeCommittedRouting(ifGeneration: routingGeneration)
        }
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
        // Events held while this copy was fetched replay against it before
        // any wait they could satisfy is resolved.
        await releaseRefetchRouting(for: distinctId)
        guard let state = currentProfileState() else { return }
        try? await resumeParkedRuns(event: nil)
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
        if let operation = journalRecoveryOperation {
            await operation.task.value
        }
        guard profileDeliveryGenerationsByDistinctId[distinctId] == admissionGeneration,
              identity.getDistinctId() == distinctId else { return }
        if initialized {
            await ensureJournal(for: distinctId)
        }
        // While a fresh copy is fetched, the customer's events wait for it.
        await holdEventsWhileRefetching(distinctId)
        guard profileDeliveryGenerationsByDistinctId[distinctId]
                == admissionGeneration,
              identity.getDistinctId() == distinctId,
              profileState?.distinctId == distinctId
                || journal?.distinctId == distinctId else {
            // A newer copy or customer outran this withdrawal. A newer
            // withdrawal keeps the hold for its own fetch.
            if profileState?.distinctId == distinctId
                || identity.getDistinctId() != distinctId {
                await releaseRefetchRouting(for: distinctId)
            }
            return
        }
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
        try? await resumeParkedRuns(event: nil)
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
        let deliveryGeneration = profileDeliveryGenerationsByDistinctId[distinctId]
        if let operation = journalRecoveryOperation {
            await operation.task.value
        }
        guard profileDeliveryGenerationsByDistinctId[distinctId] == deliveryGeneration else { return }
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
        deferredCommerceOutcomes.removeAll()
        for task in commerceSettlementTasks.values { task.cancel() }
        commerceSettlementTasks.removeAll()
        let retiredValues = takeNativeValues(owner: distinctId)
        await presentationPublications.clearDirectRoutes()
        for values in retiredValues { await values.retire() }
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
        let deliveryGeneration = profileDeliveryGeneration
        if let operation = journalRecoveryOperation {
            await operation.task.value
        }
        guard profileDeliveryGeneration == deliveryGeneration else { return }
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
        deferredCommerceOutcomes.removeAll()
        for task in commerceSettlementTasks.values { task.cancel() }
        commerceSettlementTasks.removeAll()
        let retiredValues = nativeValuesByRun.values.map(\.values)
        nativeValuesByRun.removeAll()
        nativeRestoreRetries.removeAll()
        enqueuedDeadlines.removeAll()
        for task in nativeRestoreRetryTasks.values { task.cancel() }
        nativeRestoreRetryTasks.removeAll()
        await presentationPublications.clearDirectRoutes()
        for values in retiredValues { await values.retire() }
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

    @discardableResult
    func handleEvent(
        _ event: NuxieEvent,
        admittedProfileGeneration: UInt64?
    ) async -> Bool {
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
        guard initialized,
              event.distinctId == identity.getDistinctId(),
              event.name != JourneyEvents.journeyStarted,
              event.name != JourneyEvents.journeyCompleted else {
            return true
        }

        guard await recoverConversionOccurrences(throughEventId: event.id) else { return false }
        let directlyRoutedRunId = await presentationPublications
            .directRoute(eventId: event.id)
        do {
            try await resumeParkedRuns(event: event, excludingRunId: directlyRoutedRunId)
        } catch {
            // Retain unsuccessful delivery so replay can still offer this
            // event to its original event-time window.
            LogWarning("JourneyService: failed to inspect parked Journeys for event: \(error)")
            return false
        }
        guard await resumePresentationActionOutcome(
            event: event,
            excludingRunId: directlyRoutedRunId
        ) else { return false }
        // Keep ownership through every failure above so replay cannot offer a
        // renderer publication to the owning run's newly parked wait.
        _ = await presentationPublications.consumeDirectRoute(eventId: event.id)
        guard let state = currentProfileState() else {
            await scheduleNextWake()
            return true
        }
        // An event captured before this copy was installed (the first launch,
        // when EventLog holds events until the first copy arrives, or before a
        // fresh copy replaced the old one) starts from the copy it is handled
        // under. Identity can change while routing awaits; one customer's
        // event never starts another customer's Journey.
        guard isCurrent(state), state.distinctId == event.distinctId else { return true }
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
        return true
    }
}

extension JourneyService {
    /// Controls are always consumed. Unavailable work is derived again from
    /// the journal, without retaining a deadline at the local queue head.
    func handleJourneyDeadline(_ deadline: JourneyDeadline) async -> Bool {
        enqueuedDeadlines.remove(deadline)
        guard initialized, deadline.distinctId == identity.getDistinctId(),
              journal?.distinctId == deadline.distinctId else { return true }
        let generation = journalGeneration
        deadlineRetryAt[deadline] = dateProvider.now().addingTimeInterval(1)
        do {
            try await resumeParkedRuns(event: nil, deadline: deadline)
        } catch {
            LogWarning("JourneyService: failed to handle Journey deadline: \(error)")
        }
        if generation == journalGeneration { await scheduleNextWake() }
        return true
    }
}

// MARK: - Presentation commerce outcomes

private extension JourneyService {
    private func resumePresentationActionOutcome(
        event: NuxieEvent,
        excludingRunId: String? = nil
    ) async -> Bool {
        guard let route = JourneyActionType.presentationOutcomeRoute(eventName: event.name),
              let journal, isCurrentIdentity(journal: journal) else { return true }
        guard let candidates = try? await journal.runs() else { return false }
        for candidate in candidates where candidate.completion == nil
            && (candidate.park == nil || candidate.pendingCommerce != nil)
            && candidate.id != excludingRunId {
            guard isCurrentIdentity(journal: journal) else { continue }
            let token = executionFence.token()
            guard let release = await release(for: candidate, state: currentProfileState(),
                journal: journal, executionFenceToken: token) else { continue }
            // Release authentication can suspend while an authored route changes the run.
            guard let currentRuns = try? await journal.runs() else { return false }
            guard executionFence.isCurrent(token), isCurrentIdentity(journal: journal),
                  let candidate = currentRuns.first(where: { $0.id == candidate.id && $0.completion == nil }),
                  candidate.park == nil || candidate.pendingCommerce != nil else { continue }
            let leg = release.descriptor.leg
            let pending = candidate.pendingCommerce
            guard let step = leg.steps.first(where: { $0.id == (pending?.stepId ?? candidate.stepId) }),
                  let action = step.action, JourneyActionType(action: action) == route.actionType,
                  let effectId = pending?.effectId ?? candidate.effectReceipts[step.id],
                  presentationOutcomeMatches(event, effectId: effectId, runId: candidate.id,
                    action: action, release: release, pendingPlacement: pending?.placementId) else { continue }
            // Never replace an authored route's cursor while its effects or
            // renderer publication are suspended. Its release drains this result.
            let executionKey = RunExecutionKey(runID: candidate.id, owner: journal.distinctId, generation: token.generation)
            if activeRunExecutions[executionKey, default: 0] > 0 {
                do { try await beforeCommerceOutcomeDeferral?(candidate.id) } catch { return false }
                guard let controlEvent = controlEvent(event) else { return false }
                guard let admission = journalCommitAdmission(journal: journal, executionFenceToken: token) else { continue }
                do {
                    let deferred = try await journal.deferPresentationCommerceOutcome(candidate.id, stepId: step.id,
                        effectId: effectId, event: controlEvent, admission: admission)
                    if !deferred {
                        // A concurrent finish or cursor move is not a delivery failure.
                        let latestRuns = try await journal.runs()
                        guard executionFence.isCurrent(token), isCurrentIdentity(journal: journal),
                              let latest = latestRuns.first(where: { $0.id == candidate.id && $0.completion == nil }),
                              latest.pendingCommerce.map({ $0.stepId == step.id && $0.effectId == effectId })
                                ?? (latest.stepId == step.id && latest.effectReceipts[step.id] == effectId)
                        else { continue }
                        return false
                    }
                } catch {
                    LogWarning("JourneyService: failed to defer presentation commerce outcome: \(error)")
                    return false
                }
                if deferredCommerceOutcomes[executionKey] == nil { deferredCommerceOutcomes[executionKey] = event }
                // The authored route may have finished while the journal write suspended.
                if activeRunExecutions[executionKey, default: 0] == 0 { endRunExecution(executionKey) }
                // The journal owns settlement now. Other subscribers and Journey entries may proceed.
                return true
            }
            if candidate.pendingPresentationPublication != nil {
                beginRunExecution(executionKey)
                do {
                    try await recoverPendingPresentationPublications(in: journal, runId: candidate.id)
                } catch {
                    endRunExecution(executionKey)
                    return false
                }
                endRunExecution(executionKey)
                return await resumePresentationActionOutcome(event: event, excludingRunId: excludingRunId)
            }
            let nextStepId = step.outlets?[route.outlet]
            if nextStepId == nil, let outcome = candidate.authoredCloseOutcome {
                // Retain correlation until completion is durable so a failed read or write can retry.
                return await finish(candidate, outcome: outcome, leg: leg, journal: journal, executionFenceToken: token)
            }
            do {
                guard let admission = journalCommitAdmission(journal: journal, executionFenceToken: token),
                      let continued = try await journal.settlePresentationCommerce(candidate.id,
                        stepId: step.id, effectId: effectId, nextStepId: nextStepId, admission: admission) else { continue }
                pendingPresentationPurchasePlacements.removeValue(forKey: candidate.id)
                let errorCode = route.outlet == "failed"
                    ? ["error_code", "errorCode", "code", "error"].compactMap { event.properties[$0] as? String }.first { !$0.isEmpty } ?? ""
                    : ""
                await presenter?.projectJourneyCommerceOutcome(owner: .init(journeyId: candidate.journeyId, distinctId: journal.distinctId),
                    actionType: route.actionType, outlet: route.outlet, errorCode: errorCode, effectId: effectId)
                if nextStepId != nil {
                    await continuePresentedRun(continued, release: release, executionFenceToken: token,
                        signal: .init(), journal: journal)
                }
            } catch {
                LogWarning("JourneyService: failed to settle presentation commerce outcome: \(error)")
                return false
            }
            return true
        }
        return true
    }

    private func beginRunExecution(_ id: RunExecutionKey) {
        activeRunExecutions[id, default: 0] += 1
    }

    private func endRunExecution(_ id: RunExecutionKey) {
        let remaining = max(0, activeRunExecutions[id, default: 0] - 1)
        if remaining > 0 { activeRunExecutions[id] = remaining; return }
        activeRunExecutions.removeValue(forKey: id)
        if deferredCommerceOutcomes[id] != nil {
            scheduleCommerceSettlement(id)
        }
    }

    private func scheduleCommerceSettlement(_ id: RunExecutionKey) {
        guard commerceSettlementTasks[id] == nil else { return }
        commerceSettlementTasks[id] = Task { [weak self] in
            await self?.drainCommerceSettlement(id)
        }
    }

    private func drainCommerceSettlement(_ id: RunExecutionKey) async {
        defer { commerceSettlementTasks.removeValue(forKey: id) }
        while !Task.isCancelled, executionFence.token().generation == id.generation,
              journal?.distinctId == id.owner {
            deferredCommerceOutcomes.removeValue(forKey: id)
            if await resumeDeferredCommerceOutcomes(runId: id.runID, executionKey: id) {
                if deferredCommerceOutcomes[id] != nil, activeRunExecutions[id, default: 0] == 0 { continue }
                return
            }
            // EventLog has acknowledged the durable handoff. The journal now owns retries.
            do { try await sleepProvider.sleep(for: 5) } catch { return }
        }
    }

    private func resumeDeferredCommerceOutcomes(runId: String? = nil, executionKey: RunExecutionKey? = nil) async -> Bool {
        if let executionKey,
           executionFence.token().generation != executionKey.generation || journal?.distinctId != executionKey.owner { return false }
        guard let journal, isCurrentIdentity(journal: journal),
              let runs = try? await journal.runs() else { return false }
        for run in runs where run.completion == nil && (runId == nil || run.id == runId) {
            guard let pending = run.pendingCommerceOutcome else { continue }
            let event = NuxieEvent(id: pending.effectId, name: pending.event.name,
                distinctId: journal.distinctId,
                properties: pending.event.properties.dictionary.mapValues { journeyFoundationValue($0) ?? NSNull() },
                timestamp: Date(timeIntervalSince1970: Double(pending.event.occurredAtMillis) / 1000))
            guard await resumePresentationActionOutcome(event: event) else { return false }
        }
        return true
    }

    private func presentationOutcomeMatches(
        _ event: NuxieEvent,
        effectId: String,
        runId: String,
        action: [String: JourneyReleaseJSONValue],
        release: AuthenticatedJourneyRelease,
        pendingPlacement: String? = nil
    ) -> Bool {
        guard event.id == effectId else { return false }
        guard let type = JourneyActionType(action: action),
              type.isCommerce else { return false }
        guard type == .purchase else { return type == .restore }
        if let eventExperienceId = event.properties["experience_id"] as? String,
           eventExperienceId != release.descriptor.identity.experienceId {
            return false
        }
        guard let expectedPlacement = pendingPlacement ?? pendingPresentationPurchasePlacements[
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
        await scheduleNextWake()
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
        enqueuedDeadlines.removeAll()
        foregroundDeadlines.removeAll()
        deadlineRetryAt.removeAll()
        await resetForegroundStateArmReceiptsIfNeeded()
        try? await resumeParkedRuns(event: nil)
        guard initialized, let state = currentProfileState() else { return }
        await evaluateStateArms(state: state, kinds: nil)
    }

    func handleUserChange(
        from oldDistinctId: String,
        to newDistinctId: String
    ) async {
        // Before any await, so a startup step running meanwhile leaves the
        // arriving customer's journal and routing to this transition.
        transitionInFlight = newDistinctId
        cancelWake()
        // This transition holds and replays the arriving customer's events
        // itself, so a refetch's hold for the departing one ends here.
        if let held = refetchRoutingDeferral {
            refetchRoutingDeferral = nil
            await events.resumeCommittedRouting(ifGeneration: held.generation)
        }
        await retireNativeValues(owner: oldDistinctId)
        pendingPresentationPurchasePlacements.removeAll()
        deferredCommerceOutcomes.removeAll()
        for task in commerceSettlementTasks.values { task.cancel() }
        commerceSettlementTasks.removeAll()
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
        if profileState?.distinctId == newDistinctId {
            // Their profile outran this transition: open their journal now.
            await ensureJournal(for: newDistinctId)
        } else if await retireDisplacedJournals(arriving: newDistinctId),
                  journal == nil {
            // The arriving customer's events wait for their profile, as at
            // first launch: routed with no profile, a trigger sent right
            // after identify() is dropped. Their journal opens with that
            // profile in commitProfile, whose recovery replays what was held
            // and releases routing. The hold starts only once the departing
            // journal is retired, because retiring it drains routing.
            userChangeRoutingDeferral = await events.deferCommittedRouting()
        }
        await resetForegroundStateArmReceiptsIfNeeded()
        await scheduleNextWake()
    }

    /// The transition has finished. When its profile refresh settled
    /// (admitted, or failed) the arriving customer's journal opens now if it
    /// has not, with their profile when it arrived and without one as before
    /// the hold otherwise. When every refresh was superseded, a newer one may
    /// still bring the profile, so the journal stays closed: their events are
    /// then refused and kept by EventLog until that profile opens it. Either
    /// way this transition's hold is released, with the startup hold that
    /// waited for it. Transitions run one at a time, so no newer
    /// transition's hold exists yet.
    func finishUserChangeRouting(
        to newDistinctId: String,
        profileSettled: Bool
    ) async {
        // A newer identify() is queued behind this transition: the holds
        // stay for it, and it is the transition now in flight.
        guard identity.getDistinctId() == newDistinctId else {
            transitionInFlight = identity.getDistinctId()
            return
        }
        transitionInFlight = nil
        // Before initialization no hold was taken here; startup opens the
        // journal and releases its own hold.
        guard initialized else { return }
        if journal == nil, profileSettled {
            await ensureJournal(for: newDistinctId)
        }
        if let operation = journalRecoveryOperation {
            await operation.task.value
        }
        guard identity.getDistinctId() == newDistinctId else {
            transitionInFlight = identity.getDistinctId()
            return
        }
        guard initialized,
              journal == nil || recoveredJournalGeneration == journalGeneration
        else { return }
        let held = userChangeRoutingDeferral
        userChangeRoutingDeferral = nil
        for generation in [held, startupRoutingDeferral].compactMap({ $0 }) {
            await events.resumeCommittedRouting(ifGeneration: generation)
        }
    }

    func profileRefetchWillBegin(distinctId: String) async {
        profileRefetchesInFlight[distinctId, default: 0] += 1
        // A fetch for a customer whose copy was already withdrawn.
        if profileState?.distinctId != distinctId {
            await holdEventsWhileRefetching(distinctId)
        }
    }

    func profileRefetchDidSettle(distinctId: String) async {
        guard let inFlight = profileRefetchesInFlight[distinctId] else { return }
        guard inFlight == 1 else {
            profileRefetchesInFlight[distinctId] = inFlight - 1
            return
        }
        profileRefetchesInFlight[distinctId] = nil
        guard refetchRoutingDeferral?.distinctId == distinctId else { return }
        // No fresh copy landed: the held events go through without one, as
        // they would have, and then the waits that ran out meanwhile resolve.
        await releaseRefetchRouting(for: distinctId)
        try? await resumeParkedRuns(event: nil)
    }

    /// The customer's withdrawn copy is being replaced: EventLog holds their
    /// events until the fresh copy lands or the last fetch settles. An
    /// identity transition holds and replays the arriving customer's events
    /// itself, and without a recovered journal EventLog keeps them anyway.
    private func holdEventsWhileRefetching(_ distinctId: String) async {
        guard profileRefetchesInFlight[distinctId] != nil,
              refetchRoutingDeferral == nil,
              transitionInFlight == nil,
              identity.getDistinctId() == distinctId,
              let journal, journal.distinctId == distinctId,
              recoveredJournalGeneration == journalGeneration else { return }
        let generation = await events.deferCommittedRouting()
        if refetchRoutingDeferral.map({ $0.generation < generation }) ?? true {
            refetchRoutingDeferral = (distinctId, generation)
        }
    }

    /// Ends a refetch's hold. While the customer is still current, this
    /// returns once their held events have been handled, so a waiting
    /// Journey takes them before any of its deadlines is resolved. A newer
    /// hold keeps them for its owner.
    private func releaseRefetchRouting(for distinctId: String) async {
        guard let held = refetchRoutingDeferral,
              held.distinctId == distinctId else { return }
        refetchRoutingDeferral = nil
        guard identity.getDistinctId() == distinctId,
              transitionInFlight == nil else {
            await events.resumeCommittedRouting(ifGeneration: held.generation)
            return
        }
        await events.releaseCommittedRouting(ifGeneration: held.generation)
    }

    /// identify() while the SDK starts can leave the departing customer's
    /// profile installed, or a transition in flight for the identified one.
    /// Either way the identified customer's profile is still coming.
    private func awaitsIdentifiedProfile(_ distinctId: String) -> Bool {
        if profileState?.distinctId == distinctId { return false }
        return transitionInFlight == distinctId || profileState != nil
    }

    /// Startup opens the current customer's journal unless their profile is
    /// still coming; then it opens with that profile, or when the transition
    /// finishes without one.
    private func startupOpensJournal(for distinctId: String) -> Bool {
        storageScope != nil && !awaitsIdentifiedProfile(distinctId)
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
        while let operation = journalRecoveryOperation {
            await operation.task.value
            if journalRecoveryOperation?.id == operation.id {
                journalRecoveryOperation = nil
            }
            if journal?.distinctId == distinctId,
               recoveredJournalGeneration == journalGeneration { return }
        }
        guard initialized, identity.getDistinctId() == distinctId else { return }
        if journal?.distinctId == distinctId,
           recoveredJournalGeneration == journalGeneration { return }
        let operationId = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.prepareAndRecoverJournal(for: distinctId)
        }
        journalRecoveryOperation = (operationId, task)
        await task.value
        if journalRecoveryOperation?.id == operationId {
            journalRecoveryOperation = nil
        }
    }

    private func prepareAndRecoverJournal(for distinctId: String) async {
        if journal?.distinctId != distinctId {
            await prepareJournal(for: distinctId)
        }
        guard initialized, identity.getDistinctId() == distinctId,
              let journal, journal.distinctId == distinctId else { return }
        let generation = journalGeneration
        await recoverJournal(journal, generation: generation)
        if journalGeneration == generation, self.journal != nil {
            recoveredJournalGeneration = generation
        }
    }

    private func prepareJournal(for distinctId: String) async {
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
        } catch {
            LogError("JourneyService: durable journal preparation failed: \(error)")
            journal = nil
        }
    }

    private func recoverJournal(_ opened: JourneyRunJournal, generation: UInt64) async {
        do {
            guard let storageScope else { throw JourneyJournalError.invalidState }
            // EventLog is configured before recovery; preparation must not await it.
            try await events.bindConversionAuthority(storageScope)
            // Entry routing must admit its watch before later captured goals drain.
            let firstPendingRoute = try await events.firstPendingStableRouteEventId(
                distinctId: opened.distinctId
            )
            guard await recoverConversionOccurrences(throughEventId: firstPendingRoute) else {
                throw JourneyJournalError.invalidState
            }
            try await recoverPendingPresentationPublications(in: opened)
            guard await resumeDeferredCommerceOutcomes() else { throw JourneyJournalError.invalidState }
            guard try await JourneyExperimentExposureReporter(journal: opened, events: events)
                .stagePending(),
                try await JourneyReporter(journal: opened, events: events).stagePending() else {
                throw JourneyJournalError.invalidState
            }
            guard await events.replayPendingStableRoutes(
                distinctId: opened.distinctId
            ) else {
                throw JourneyJournalError.invalidState
            }
            _ = try await experimentExposures.flushPending(in: opened)
            try await JourneyReporter(journal: opened, events: events)
                .flushPending()
            _ = try await opened.finalizeRevocation()
            await scheduleNextWake()
        } catch {
            LogError("JourneyService: durable journal recovery failed: \(error)")
            if journalGeneration == generation { journal = nil }
        }
    }

    private func recoverPendingPresentationPublications(
        in journal: JourneyRunJournal, runId: String? = nil
    ) async throws {
        for run in try await journal.runs()
        where run.pendingPresentationPublication != nil && (runId == nil || run.id == runId) {
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
        guard await retireDisplacedJournals(arriving: distinctId),
              identity.getDistinctId() == distinctId,
              journal?.distinctId != distinctId else { return }
        await openJournal(for: distinctId)
    }

    /// A new-user profile can outrun the queued identity transition. Retire
    /// every journal displaced during that race before installing another.
    private func retireDisplacedJournals(arriving distinctId: String) async -> Bool {
        guard storageScope != nil else { return false }
        while let displaced = journal,
              displaced.distinctId != distinctId {
            guard await abandon(displaced) else { return false }
            guard identity.getDistinctId() == distinctId else { return false }
            if journal?.distinctId == displaced.distinctId {
                journal = nil
            }
        }
        if let current = journal,
           current.distinctId == distinctId,
           revokingCustomers.contains(distinctId) {
            guard await abandon(current) else { return false }
        }
        return true
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
        await retireNativeValues(owner: journal.distinctId)
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
        guard isCurrent(state) else { return }

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
            context: context,
            conversion: arm.conversion
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
                        assignments: state.snapshot.profile.facts.assignments,
                        customer: try state.snapshot.profile.facts.customerValues()
                    ),
                    reentry: release.descriptor.leg.policy.entry.frequency,
                    policy: release.descriptor.leg.policy,
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
                    startingEventAt: event?.timestamp,
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

    private func offerDecision(
        _ offer: Journey.Offer,
        release: AuthenticatedJourneyRelease,
        placementId: String? = nil
    ) async -> JourneyOfferAccess.Decision {
        guard let products = try? decodeJourneyDocuments(JourneyReleaseProductDocument.self, from: release.descriptor.products),
              let placements = try? decodeJourneyDocuments(JourneyReleasePlacementDocument.self, from: release.descriptor.placements) else { return .unknown }
        if let placementId, !offer.placementIds.contains(placementId) { return .unknown }
        return await JourneyOfferAccess.evaluate(
            placementIds: placementId.map { [$0] } ?? offer.placementIds,
            products: products,
            placements: placements,
            ownedStoreProductIds: await storeEntitlements(),
            featureAccess: offerFeatureAccess
        )
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

    private func deadline(for run: JourneyRun, distinctId: String) -> JourneyDeadline? {
        guard let checkpoint = ParkCheckpoint(run) else { return nil }
        return .init(distinctId: distinctId, runId: run.id, stepId: checkpoint.stepId,
                     anchorAt: checkpoint.anchorAt, wakeAt: checkpoint.wakeAt)
    }

    private func registerNativeRestoreRetry(runID: String, checkpoint: ParkCheckpoint) {
        // Restoration owns this checkpoint's retry until it succeeds.
        cancelWake()
        if nativeRestoreRetries[runID]?.checkpoint == checkpoint,
           nativeRestoreRetryTasks[runID] != nil { return }
        let retry = NativeRestoreRetry(checkpoint: checkpoint,
            at: dateProvider.now().addingTimeInterval(5))
        nativeRestoreRetries[runID] = retry
        nativeRestoreRetryTasks.removeValue(forKey: runID)?.cancel()
        let sleeper = sleepProvider
        nativeRestoreRetryTasks[runID] = Task { [weak self] in
            do { try await sleeper.sleep(for: 5) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.retryNativeRestoration(runID: runID, checkpoint: checkpoint)
        }
    }

    private func retryNativeRestoration(runID: String, checkpoint: ParkCheckpoint) async {
        guard nativeRestoreRetries[runID]?.checkpoint == checkpoint else { return }
        nativeRestoreRetryTasks.removeValue(forKey: runID)
        // This retries native state only. Timed waits still need their queued
        // deadline or an accepted event before they can resume.
        try? await resumeParkedRuns(event: nil, nativeRetry: (runID, checkpoint))
    }

    private func resumeParkedRuns(
        event: NuxieEvent?,
        excludingRunId: String? = nil,
        deadline: JourneyDeadline? = nil,
        nativeRetry: (runID: String, checkpoint: ParkCheckpoint)? = nil
    ) async throws {
        guard initialized, let journal,
              isCurrentIdentity(journal: journal) else { return }
        let inspectedJournalGeneration = journalGeneration
        let runs: [JourneyRun]
        do {
            runs = try await readJournalRuns(journal)
        } catch {
            LogWarning("JourneyService: failed to inspect parked Journeys: \(error)")
            if event != nil || deadline != nil { throw error }
            cancelWake()
            await events.requestJourneyResumeRetry()
            return
        }
        do {
            for parked in runs
            where parked.park != nil
                && parked.completion == nil
                && parked.id != excludingRunId {
                guard journalGeneration == inspectedJournalGeneration,
                      isCurrentIdentity(journal: journal) else { return }
                var parked = parked
                if let nativeRetry,
                   parked.id != nativeRetry.runID || ParkCheckpoint(parked) != nativeRetry.checkpoint { continue }
                if let deadline, self.deadline(for: parked, distinctId: journal.distinctId) != deadline { continue }
                if event == nil {
                    // The release's screen gate below decides background eligibility.
                    let nativeRetryDue = nativeRestoreRetries[parked.id].map {
                        $0.checkpoint == ParkCheckpoint(parked) && $0.at <= dateProvider.now()
                    } == true
                    guard parked.park?.pendingEvent != nil
                            || parked.park?.candidateEvents?.isEmpty == false
                            || parked.park?.wakeAt.map({
                                $0 <= dateProvider.now()
                            }) == true || nativeRetryDue else { continue }
                }
                let executionFenceToken = executionFence.token()
                guard let admission = journalCommitAdmission(journal: journal,
                    executionFenceToken: executionFenceToken) else { return }
                guard let release = await release(
                    for: parked,
                    state: currentProfileState(),
                    journal: journal,
                    executionFenceToken: executionFenceToken
                ) else {
                    if deadline != nil { throw JourneyJournalError.invalidState }
                    continue
                }
                let executionSnapshot = parked.executionSnapshot
                guard journalGeneration == inspectedJournalGeneration,
                      admission.commitJournalIfCurrent({ true }) == true else {
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
                let waitStep = release.descriptor.leg.steps.first { $0.id == parked.stepId }
                if let candidate = event.flatMap(controlEvent), let park = parked.park,
                   let action = waitStep?.action, JourneyActionType(action: action) == .waitUntil {
                    guard let updatedPark = try await journal.appendParkedCandidate(parked.id, expectedStepId: parked.stepId,
                            expectedPark: park, event: candidate, admission: admission) else { continue }
                    parked.park = updatedPark
                }
                // A background deadline is consumed before native restoration.
                // Ordinary events retain the existing pending/candidate evaluation.
                if event == nil, !foreground, !release.descriptor.leg.screens.isEmpty {
                    if let deadline { foregroundDeadlines.insert(deadline) }
                    continue
                }
                if let retry = nativeRestoreRetries[parked.id], retry.checkpoint == ParkCheckpoint(parked),
                   retry.at > dateProvider.now(), event == nil {
                    if deadline != nil { throw JourneyJournalError.invalidState }
                    continue
                }
                // Restore while the durable checkpoint still owns recovery.
                // A failed file preparation must not consume the wait.
                var evaluationContext = parked.context
                do {
                    let values = try await preparedNativeValues(for: parked, release: release, journal: journal)
                    evaluationContext = .init(event: parked.context.event, responses: try await readNativeValues(values),
                                              formAnswers: try await values.formAnswers(policy: release.descriptor.valuePolicy))
                } catch {
                    guard journalGeneration == inspectedJournalGeneration,
                          admission.commitJournalIfCurrent({ true }) == true else { return }
                    if let checkpoint = ParkCheckpoint(parked) {
                        registerNativeRestoreRetry(runID: parked.id, checkpoint: checkpoint)
                    }
                    LogWarning("JourneyService: parked native value restoration failed: \(error)")
                    if deadline != nil { throw error }
                    continue
                }
                guard journalGeneration == inspectedJournalGeneration,
                      admission.commitJournalIfCurrent({ true }) == true else { return }
                if nativeRestoreRetries[parked.id]?.checkpoint == ParkCheckpoint(parked) {
                    nativeRestoreRetries.removeValue(forKey: parked.id)
                    nativeRestoreRetryTasks.removeValue(forKey: parked.id)?.cancel()
                }
                let acceptedEvent = parked.park?.pendingEvent ?? parked.park?.candidateEvents?.first { candidate in
                    guard let checkpoint, let waitStep else { return false }
                    return controlExecutor(for: release).parkedWaitAccepts(candidate, step: waitStep,
                        context: evaluationContext, assignments: executionSnapshot.assignments,
                        customer: executionSnapshot.customer ?? [:], checkpoint: checkpoint)
                }
                if let acceptedEvent, let checkpoint {
                    guard try await journal.stageParkedEvent(parked.id, expectedStepId: parked.stepId,
                            expectedCheckpoint: checkpoint, event: acceptedEvent, admission: admission) else { continue }
                    parked.park?.pendingEvent = acceptedEvent
                }
                if let park = parked.park, park.candidateEvents != nil {
                    guard try await journal.removeParkedCandidates(parked.id, expectedStepId: parked.stepId,
                            expectedPark: park, evaluated: park.candidateEvents ?? [], admission: admission) else { continue }
                    parked.park?.candidateEvents = nil
                }
                guard journalGeneration == inspectedJournalGeneration,
                      admission.commitJournalIfCurrent({ true }) == true else { return }
                if !foreground, !release.descriptor.leg.screens.isEmpty { continue }
                let now = dateProvider.now()
                if acceptedEvent == nil, let wake = parked.park?.wakeAt {
                    guard wake <= now else { continue }
                    // Presentation retries are ordinary availability parks.
                    // Only authored timed waits need timeout authorization.
                    if parked.park?.anchorAt != nil, deadline == nil { continue }
                }
                guard initialized, journalGeneration == inspectedJournalGeneration,
                      admission.commitJournalIfCurrent({ true }) == true else { return }
                if !foreground, !release.descriptor.leg.screens.isEmpty { continue }
                // Select the timed control's outlet before consuming the
                // durable checkpoint. The resume transaction commits both,
                // so a persistence failure leaves the route safely retryable.
                var advance: JourneyRunExecutionCoordinator.AdvanceCommand?
                if let checkpoint, let action = waitStep?.action,
                   JourneyActionType(action: action) == .waitUntil || JourneyActionType(action: action) == .delay {
                    var control = JourneyRunExecutionCoordinator(run: parked,
                        assignments: executionSnapshot.assignments, release: release,
                        signal: .init(event: acceptedEvent), checkpoint: checkpoint, journal: journal,
                        timezones: timezones, currentDeviceTimezone: currentDeviceTimezone)
                    control.useNativeValues(evaluationContext.responses, formAnswers: evaluationContext.formAnswers)
                    guard case .advance(let command) = control.command(at: now) else { continue }
                    advance = command
                }
                guard let expectedPark = parked.park,
                      let resumed = try await journal.resumeParked(
                    parked.id,
                    expectedStepId: parked.stepId,
                    expectedPark: expectedPark,
                    advancingTo: advance.map { ($0.stepId, $0.context) },
                    admission: admission
                ) else { continue }
                // A rendered leg can wake into a branch that never presents.
                // Reserve only if execution reaches navigate; execute also
                // recognizes an already-owned presentation before reserving.
                await execute(
                    resumed,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: .init(event: acceptedEvent),
                    checkpoint: advance == nil ? checkpoint : nil,
                    journal: journal,
                    originAdmission: admission
                )
            }
        } catch {
            LogWarning("JourneyService: failed to resume parked Journey: \(error)")
            if event != nil || deadline != nil { throw error }
            await events.requestJourneyResumeRetry()
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
            await retireNativeValues(runID: run.id)
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

// MARK: - Native response saves

private extension JourneyService {
    func activateResponseSaveDelivery() async {
        guard let storageScope, let responseSaveDelivery else { return }
        await responseSaveDelivery.setDisplayObserver { [weak self] journal, journeyID in
            await self?.responseSaveDisplayChanged(journal: journal, journeyID: journeyID)
        }
        await responseSaveDelivery.activate(scope: storageScope)
    }

    func applyResponseSaveDisplay(run: JourneyRun, journal: JourneyRunJournal,
        values: ExperienceRunValues, policy: JourneyReleaseValuePolicy) async throws {
        let stored = try await journal.responseSaveDisplays(journeyId: run.journeyId)
        var declared: ExactJSONObject<JourneyResponseSaveDisplay> = [:]
        for (form, display) in stored where policy.responses[form] != nil { declared[form] = display }
        if !declared.isEmpty { try await values.applyResponseSaveDisplays(declared, policy: policy) }
    }

    func responseSaveDisplayChanged(journal changed: JourneyRunJournal, journeyID: String) async {
        let fence = executionFence.token()
        guard let journal, isCurrentIdentity(journal: journal),
              journal.distinctId == changed.distinctId,
              journal.responseSaveNamespace == changed.responseSaveNamespace else { return }
        do {
            for run in try await journal.runs() where run.journeyId == journeyID && run.completion == nil {
                guard executionFence.isCurrent(fence), isCurrentIdentity(journal: journal),
                      let native = nativeValuesByRun[run.id], native.owner == journal.distinctId else { continue }
                try await applyResponseSaveDisplay(run: run, journal: journal, values: native.values,
                    policy: native.policy)
            }
        } catch is CancellationError { }
        catch { LogWarning("JourneyService: save display could not be refreshed") }
    }

    func handleResponseSave(_ save: ExperienceFrameSave, runID: String,
        release: AuthenticatedJourneyRelease, executionFenceToken: JourneyProfileFenceToken) async -> Bool {
        guard executionFence.isCurrent(executionFenceToken), let journal,
              isCurrentIdentity(journal: journal), let responseSaveDelivery,
              release.descriptor.valuePolicy.responses[save.request.form] != nil,
              release.descriptor.leg.screens.contains(where: { $0.id == save.screenID }) else { return false }
        do {
            guard let run = try await journal.runs().first(where: { $0.id == runID && $0.completion == nil }),
                  await presenter?.ownsJourneyPresentation(owner: .init(journeyId: run.journeyId,
                    distinctId: journal.distinctId)) == true,
                  executionFence.isCurrent(executionFenceToken), isCurrentIdentity(journal: journal) else { return false }
            let values = try await preparedNativeValues(for: run, release: release, journal: journal)
            guard executionFence.isCurrent(executionFenceToken), isCurrentIdentity(journal: journal) else { return false }
            guard let admission = journalCommitAdmission(journal: journal,
                executionFenceToken: executionFenceToken) else { return false }
            let sheet: JourneyResponseSave
            if save.request.awaitTrigger != nil {
                sheet = try await responseSaveDelivery.reserveWaiting(journal: journal, run: run,
                    formName: save.request.form, answers: save.request.answers, admission: admission)
            } else {
                sheet = try await responseSaveDelivery.enqueue(journal: journal, run: run,
                    formName: save.request.form, answers: save.request.answers, admission: admission)
            }
            do {
                try await applyResponseSaveDisplay(run: run, journal: journal, values: values,
                    policy: release.descriptor.valuePolicy)
            } catch is CancellationError { }
            catch { LogWarning("JourneyService: accepted save display could not be refreshed") }
            if save.request.awaitTrigger != nil {
                Task { [weak self] in
                    do {
                        let reply = try await responseSaveDelivery.sendWaiting(sheet: sheet, journal: journal)
                        guard reply.confirmed,
                              await self?.responseSaveContinuationIsCurrent(runID: runID, journal: journal,
                                fence: executionFenceToken) == true else { return }
                        await save.onConfirmed()
                    } catch is CancellationError { }
                    catch { LogWarning("JourneyService: awaited response save could not complete") }
                }
            }
            return true
        } catch is CancellationError { return false }
        catch {
            LogWarning("JourneyService: native response save could not be accepted")
            return false
        }
    }

    func responseSaveContinuationIsCurrent(runID: String, journal: JourneyRunJournal,
        fence: JourneyProfileFenceToken) async -> Bool {
        guard executionFence.isCurrent(fence), isCurrentIdentity(journal: journal),
              let runs = try? await journal.runs() else { return false }
        return executionFence.isCurrent(fence) && isCurrentIdentity(journal: journal)
            && runs.contains { $0.id == runID && $0.completion == nil }
    }
}

// MARK: - Renderer batch publication

private extension JourneyService {
    private func handlePresentationBatch(
        _ batch: ScreenEmissionBatch,
        eventSource: ExperienceEmissionSources? = nil,
        runId: String,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken
    ) async -> Bool {
        guard executionFence.isCurrent(executionFenceToken),
              let journal,
              isCurrentIdentity(journal: journal) else {
            return false
        }
        let executionKey = RunExecutionKey(runID: runId, owner: journal.distinctId, generation: executionFenceToken.generation)
        beginRunExecution(executionKey)
        defer { endRunExecution(executionKey) }
        let runs: [JourneyRun]
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
              await presenter?.ownsJourneyPresentation(
                owner: .init(
                    journeyId: run.journeyId,
                    distinctId: journal.distinctId
                )
              ) == true else { return false }
        if isAwaitingPresentationCommerceOutcome(run, in: leg) {
            let route = batch.emissions.lazy.filter { !$0.name.hasPrefix("$") }.compactMap {
                JourneyPresentationEventProjector.route(in: leg, eventName: $0.name, screenId: screenId)
            }.first
            if let route, let action = leg.steps.first(where: { $0.id == route })?.action,
               JourneyActionType(action: action)?.isCommerce == true { return false }
            if run.pendingCommerce == nil {
                guard let effectId = run.effectReceipts[run.stepId],
                      let admission = journalCommitAdmission(journal: journal, executionFenceToken: executionFenceToken),
                      let retained = try? await journal.retainPresentationCommerce(run.id,
                        stepId: run.stepId, effectId: effectId,
                        placementId: pendingPresentationPurchasePlacements[run.id], admission: admission) else { return false }
                run = retained
            }
        }
        let disposition = await presentationPublications.process(
            batch,
            for: run,
            leg: leg,
            in: journal,
            executionFenceToken: executionFenceToken
        )
        await eventSource?.frameLinks?.perform()
        switch disposition {
        case .rejected:
            return false
        case .accepted:
            return true
        case .continueExecution(let continuation):
            beginRunExecution(executionKey)
            Task { [weak self] in
                guard let self else { return }
                defer { self.onPresentationContinuationFinished?() }
                await self.continuePresentedRun(
                    continuation.run,
                    release: release,
                    executionFenceToken: executionFenceToken,
                    signal: continuation.signal,
                    checkpoint: continuation.checkpoint,
                    presentationSource: batch.source,
                    eventSource: eventSource?.source(eventID: continuation.eventID),
                    journal: journal
                )
                await self.endRunExecution(executionKey)
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

    private func handlePresentationLinkOpened(_ link: ExperienceRendererOpenLinkRequest,
        run: JourneyRun, release: AuthenticatedJourneyRelease,
        identityFenceToken: IdentityFenceToken, executionFenceToken: JourneyProfileFenceToken) async {
        guard let journal, executionFence.isCurrent(executionFenceToken),
              await isCurrentIdentity(identityFenceToken, journal: journal) else { return }
        _ = await JourneyEffectDispatcher(identity: identity, events: events).captureLinkOpened(link,
            request: .init(runId: run.id, journeyId: run.journeyId, generation: run.generation,
                reference: run.reference, release: release, stepId: run.stepId, action: [:],
                context: run.context, effectId: link.effectId ?? UUID.v7().uuidString, distinctId: journal.distinctId,
                identityFence: identityFenceToken, executionFence: executionFence,
                executionFenceToken: executionFenceToken))
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
              let originAdmission = journalCommitAdmission(journal: journal, executionFenceToken: executionFenceToken) else {
            return false
        }
        let runs: [JourneyRun]
        do {
            runs = try await journal.runs()
        } catch {
            return false
        }
        guard originAdmission.commitJournalIfCurrent({ true }) == true else {
            return false
        }
        guard var run = runs.first(where: { $0.id == runId }) else {
            // This callback belongs to an admitted presentation. Its run may
            // already have completed and retired while the host hid the
            // surface; there is no remaining Journey transition to await.
            return true
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
                executionFenceToken: executionFenceToken,
                originAdmission: originAdmission
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
                executionFenceToken: executionFenceToken,
                originAdmission: originAdmission
            )
        }
        let hostDismissContext = ArmedJourney.Context(
            event: [:],
            responses: run.context.responses
        )
        do {
            guard try await journal.transition(
                run.id,
                stepId: routeStepId,
                context: hostDismissContext,
                admission: originAdmission
            ) else { return false }
        } catch {
            LogWarning("JourneyService: failed to persist host-dismiss route: \(error)")
            return false
        }
        run.stepId = routeStepId
        run.context = hostDismissContext
        run.park = nil
        guard originAdmission.commitJournalIfCurrent({ true }) == true else {
            return true
        }
        let now = JourneyTime.milliseconds(dateProvider.now()) ?? 0
        pendingPresentationDismissalContinuations[run.id] = .init(
            originAdmission: originAdmission,
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
            journal: pending.journal,
            originAdmission: pending.originAdmission
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
              let originAdmission = journalCommitAdmission(journal: journal, executionFenceToken: executionFenceToken) else {
            return .rejected
        }
        let executionKey = RunExecutionKey(runID: presentedRun.id, owner: journal.distinctId,
            generation: executionFenceToken.generation)
        beginRunExecution(executionKey)
        defer { endRunExecution(executionKey) }
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
        // An authored close has already saved its outcome. Teardown still emits
        // lifecycle telemetry, but commerce owns the eventual terminal report.
        if name == SystemEventNames.screenDismissed,
           run.pendingCommerce != nil, run.authoredCloseOutcome != nil {
            return .accepted
        }
        if !capture.routesLocally {
            if let unhandledOutcome {
                let completed = await finish(
                    run,
                    outcome: unhandledOutcome,
                    leg: release.descriptor.leg,
                    journal: journal,
                    dismissPresentation: false,
                    executionFenceToken: executionFenceToken,
                    originAdmission: originAdmission
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
                    executionFenceToken: executionFenceToken,
                    originAdmission: originAdmission
                )
                return completed ? .completed : .rejected
            }
            return .accepted
        }
        if isAwaitingPresentationCommerceOutcome(run, in: release.descriptor.leg) {
            if let action = release.descriptor.leg.steps.first(where: { $0.id == routeStepId })?.action,
               JourneyActionType(action: action)?.isCommerce == true { return .accepted }
            if run.pendingCommerce == nil {
                guard let effectId = run.effectReceipts[run.stepId],
                      let retained = try? await journal.retainPresentationCommerce(run.id,
                        stepId: run.stepId, effectId: effectId,
                        placementId: pendingPresentationPurchasePlacements[run.id],
                        admission: originAdmission) else { return .rejected }
                run = retained
            }
        }
        let context = ArmedJourney.Context(
            event: controlEvent.properties,
            responses: run.context.responses
        )
        do {
            guard try await journal.transition(
                run.id,
                stepId: routeStepId,
                context: context,
                admission: originAdmission
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
                journal: journal,
                originAdmission: originAdmission
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
            beginRunExecution(executionKey)
            Task { [weak self] in
                await continueRun()
                await self?.endRunExecution(executionKey)
            }
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
        eventSource: ExperienceResolvedEventSource? = nil,
        dismissPresentationOnCompletion: Bool = true,
        journal: JourneyRunJournal,
        originAdmission: JourneyCommitAdmission? = nil
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
            eventSource: eventSource,
            dismissPresentationOnCompletion: dismissPresentationOnCompletion,
            originAdmission: originAdmission
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

extension JourneyService {
    /// Observes only an existing run. Never prepares native state or creates a map entry.
    func liveFormAnswersJSON(runID: String, owner: String) async throws -> Data? {
        let generation = executionFence.token().generation
        guard identity.getDistinctId() == owner,
              let entry = nativeValuesByRun[runID], entry.owner == owner else { return nil }
        guard await entry.values.isPrepared else { return nil }
        let answers: ExactJSONObject<ExactJSONObject<JourneyReleaseJSONValue>>
        do {
            answers = try await entry.values.formAnswers(policy: entry.policy)
        } catch {
            try Task.checkCancellation()
            switch error {
            case is CancellationError,
                 ExperienceInteractiveScreenError.stateContract("Response forms are unavailable"):
                return nil
            #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
            case NuxieNativeRuntimeError.closed,
                 NuxieNativeRuntimeError.missingHandle("shared view model"),
                 NuxieRuntimeExecutorError.closed:
                return nil
            #endif
            default:
                throw error
            }
        }
        guard identity.getDistinctId() == owner,
              executionFence.token().generation == generation,
              let current = nativeValuesByRun[runID], current.owner == owner,
              current.values === entry.values else { return nil }
        return try JSONEncoder().encode(answers)
    }

    func hasNativeValuesForTesting(runID: String) -> Bool {
        nativeValuesByRun[runID] != nil
    }
}

// MARK: - Durable execution

private extension JourneyService {
    func retireNativeValues(runID: String) async {
        nativeRestoreRetryTasks.removeValue(forKey: runID)?.cancel()
        nativeRestoreRetries.removeValue(forKey: runID)
        let values = nativeValuesByRun.removeValue(forKey: runID)?.values
        await values?.retire()
    }

    func takeNativeValues(owner: String) -> [ExperienceRunValues] {
        for (runID, value) in nativeValuesByRun where value.owner == owner {
            nativeRestoreRetryTasks.removeValue(forKey: runID)?.cancel()
            nativeRestoreRetries.removeValue(forKey: runID)
        }
        let values = nativeValuesByRun.values.filter { $0.owner == owner }.map(\.values)
        nativeValuesByRun = nativeValuesByRun.filter { $0.value.owner != owner }
        return values
    }

    func retireNativeValues(owner: String) async {
        for value in takeNativeValues(owner: owner) { await value.retire() }
    }

    func nativeValues(for runID: String, owner: String, policy: JourneyReleaseValuePolicy, snapshot: ExperienceRunSnapshot? = nil) -> ExperienceRunValues {
        if let existing = nativeValuesByRun[runID], existing.owner == owner { return existing.values }
        let values = ExperienceRunValues(snapshot: snapshot)
        nativeValuesByRun[runID] = (owner, values, policy)
        return values
    }
}

private extension JourneyService {
    private func preparedNativeValues(for run: JourneyRun, release: AuthenticatedJourneyRelease,
        journal: JourneyRunJournal) async throws -> ExperienceRunValues {
        let values = nativeValues(for: run.id, owner: journal.distinctId, policy: release.descriptor.valuePolicy, snapshot: run.nativeSnapshot)
        if !(await values.isPrepared) {
            try await prepareNativeValues(values, release, run.executionSnapshot.delivery,
                journal.pinnedArtifacts(forRunId: run.id))
        }
        try await applyResponseSaveDisplay(run: run, journal: journal, values: values,
            policy: release.descriptor.valuePolicy)
        return values
    }

    private static func readsNativeValues(_ value: JourneyReleaseJSONValue) -> Bool {
        switch value {
        case .object(let object):
            if case .string("Response.Field")? = object["type"] { return true }
            return object.values.contains(where: readsNativeValues)
        case .array(let array): return array.contains(where: readsNativeValues)
        default: return false
        }
    }

    private func execute(
        _ initial: JourneyRun,
        release: AuthenticatedJourneyRelease,
        executionFenceToken: JourneyProfileFenceToken,
        signal initialSignal: JourneyControlExecutor.Signal,
        checkpoint initialCheckpoint: JourneyControlExecutor.Checkpoint?,
        journal: JourneyRunJournal,
        startingEventAt: Date? = nil,
        presentationSource: ScreenEmissionSource? = nil,
        eventSource: ExperienceResolvedEventSource? = nil,
        dismissPresentationOnCompletion: Bool = true,
        presentationReservation initialPresentationReservation:
            (any JourneyPresentationReservation)? = nil,
        originAdmission: JourneyCommitAdmission? = nil
    ) async {
        let executionKey = RunExecutionKey(runID: initial.id, owner: journal.distinctId, generation: executionFenceToken.generation)
        let executionJournalGeneration = journalGeneration
        beginRunExecution(executionKey)
        defer { endRunExecution(executionKey) }
        guard let originAdmission = originAdmission ?? journalCommitAdmission(journal: journal,
            executionFenceToken: executionFenceToken),
            let originIdentityToken = originAdmission.identityFenceToken else { return }
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
            currentDeviceTimezone: currentDeviceTimezone,
            startingEventAt: startingEventAt
        )
        var presentationReservation = initialPresentationReservation

        for _ in 0..<JourneyRunExecutionCoordinator.iterationLimit {
            let durableRun = coordinator.run
            do {
                let action = leg.steps.first { $0.id == durableRun.stepId }?.action
                let needsRead = action?.values.contains(where: Self.readsNativeValues) == true
                    || durableRun.nativeSnapshot != nil
                    || (leg.steps.first { $0.id == durableRun.stepId }?.kind == .complete
                        && leg.completionOutputs.values.contains { !$0.responseFields.isEmpty })
                let values: ExperienceRunValues?
                if needsRead {
                    values = try await preparedNativeValues(for: durableRun, release: release, journal: journal)
                } else {
                    values = nativeValuesByRun[durableRun.id]?.values
                }
                if let values {
                    coordinator.useNativeValues(try await readNativeValues(values),
                                              formAnswers: try await values.formAnswers(policy: release.descriptor.valuePolicy))
                }
                else { coordinator.useNativeValues([:]) }
            } catch {
                LogWarning("JourneyService: native value read failed: \(error)")
                return
            }
            let run = coordinator.run
            guard originAdmission.commitJournalIfCurrent({ true }) == true else {
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
                    try await coordinator.commit(command, admission: originAdmission)
                } catch {
                    LogWarning("JourneyService: failed to persist control transition: \(error)")
                    return
                }

            case .park(let command):
                let snapshot: ExperienceRunSnapshot?
                var preparationFailed = false
                do {
                    let values = try await preparedNativeValues(for: run, release: release, journal: journal)
                    snapshot = try await values.snapshot()
                } catch is CancellationError {
                    return
                } catch {
                    guard initialized, journalGeneration == executionJournalGeneration,
                          originAdmission.commitJournalIfCurrent({ true }) == true else { return }
                    // Native setup must not leave an admitted run without a
                    // recovery cursor. Keep its last durable values instead.
                    preparationFailed = true
                    snapshot = run.nativeSnapshot
                    LogWarning("JourneyService: initial park native preparation failed; retaining checkpoint: \(error)")
                }
                do {
                    try await coordinator.commit(command, snapshot: snapshot, admission: originAdmission)
                    guard initialized, journalGeneration == executionJournalGeneration,
                          originAdmission.commitJournalIfCurrent({ true }) == true else { return }
                    let checkpoint = ParkCheckpoint(stepId: command.stepId, checkpoint: command.checkpoint)
                    if preparationFailed {
                        registerNativeRestoreRetry(runID: run.id, checkpoint: checkpoint)
                    }
                } catch {
                    LogWarning("JourneyService: failed to persist park point: \(error)")
                }
                await scheduleNextWake()
                return

            case .complete(let outcome):
                if run.pendingCommerce != nil {
                    await closeWhileCommercePending(run, outcome: outcome, journal: journal, admission: originAdmission)
                    return
                }
                await finish(
                    run,
                    outcome: outcome,
                    leg: leg,
                    journal: journal,
                    dismissPresentation: dismissPresentationOnCompletion,
                    executionFenceToken: executionFenceToken,
                    originAdmission: originAdmission
                )
                return

            case .dispatch(let command):
                let action = command.action
                if run.pendingCommerce != nil, JourneyActionType(action: action)?.isCommerce == true { return }
                let effectId: String
                do {
                    effectId = try await coordinator.claimEffect(for: command)
                } catch {
                    LogWarning("JourneyService: failed to claim effect cursor: \(error)")
                    return
                }
                guard executionFence.isCurrent(executionFenceToken),
                      await isCurrentIdentity(
                    originIdentityToken,
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
                if JourneyActionType(action: action) == .dismiss {
                    let ownsPresentation = await presenter?.ownsJourneyPresentation(
                        owner: .init(journeyId: run.journeyId, distinctId: journal.distinctId))
                    let hasLayer = await presenter?.hasPresentedJourneyLayer(owner: .init(
                        journeyId: run.journeyId, distinctId: journal.distinctId)) == true
                    let closesLayer = action["scope"] != .string("all") && hasLayer
                    if !closesLayer && (run.pendingCommerce != nil || ownsPresentation != true) {
                        let outcome: String
                        if case .string(let reason)? = action["reason"], !reason.isEmpty { outcome = reason }
                        else { outcome = "completed" }
                        if run.pendingCommerce != nil {
                            await closeWhileCommercePending(run, outcome: outcome, journal: journal, admission: originAdmission)
                        } else {
                            await finish(run, outcome: outcome, leg: leg, journal: journal,
                                executionFenceToken: executionFenceToken, originAdmission: originAdmission)
                        }
                        return
                    }
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
                    if let offer = leg.offers.first(where: { $0.screenId == screenId }) {
                        let decision = await offerDecision(offer, release: release)
                        guard executionFence.isCurrent(executionFenceToken),
                              await isCurrentIdentity(originIdentityToken, journal: journal) else {
                                await finishAfterAuthorityLoss(run, leg: leg, journal: journal, executionFenceToken: executionFenceToken)
                                return
                            }
                        if decision != .eligible {
                            do {
                                try await coordinator.commit(.init(
                                    stepId: decision == .alreadyEntitled ? offer.alreadyEntitledStepId : offer.unknownStepId,
                                    context: run.context,
                                    experimentExposure: nil
                                ))
                            } catch {
                                LogWarning("JourneyService: failed to persist offer alternative: \(error)")
                                return
                            }
                            continue
                        }
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
                    case .superseded:
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
                    let presentationIdentityFenceToken = originIdentityToken
                    let presentationTraceContext = presentationTrace
                        .beginPresentation(
                            runId: presentedRun.id,
                            journeyId: presentedRun.journeyId,
                            experienceVersionId: release.descriptor.identity
                                .experienceVersionId,
                            at: .now(wallClock: dateProvider.now())
                        )
                    let result = await presenter.presentJourney(.init(
                        fences: .init(identityToken: presentationIdentityFenceToken,
                            executionFence: executionFence, executionToken: executionFenceToken),
                        release: release,
                        delivery: executionSnapshot.delivery,
                        pinnedArtifacts: pinnedArtifacts,
                        runValues: nativeValues(for: presentedRun.id, owner: journal.distinctId, policy: release.descriptor.valuePolicy),
                        screenId: screenId,
                        transition: .init(raw: journeyFoundationValue(action["transition"])),
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
                        onResponseSave: { [weak self] save in
                            await self?.handleResponseSave(save, runID: presentedRun.id, release: release,
                                executionFenceToken: executionFenceToken) ?? false
                        },
                        onLinkOpened: { [weak self] link in
                            await self?.handlePresentationLinkOpened(link, run: presentedRun,
                                release: release, identityFenceToken: presentationIdentityFenceToken,
                                executionFenceToken: executionFenceToken)
                        },
                        onEmissionBatch: { [weak self] batch, frameSources in
                            guard let self else { return false }
                            return await self.handlePresentationBatch(
                                batch,
                                eventSource: frameSources,
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
                if JourneyActionType(action: action) == .openLink {
                    let owner = JourneyPresentationOwner(journeyId: run.journeyId, distinctId: journal.distinctId)
                    if let resolved = resolvedPresentationAction(action, context: run.context),
                       case .string(let url)? = resolved["url"], !url.isEmpty,
                       case .string(let target)? = resolved["target"] {
                        if let presenter, let opened = await presenter.openJourneyLink(owner: owner,
                            request: .init(urlString: url, target: target, screenId: nil, instanceId: nil, effectId: effectId)) {
                            await handlePresentationLinkOpened(opened, run: run, release: release,
                                identityFenceToken: originIdentityToken, executionFenceToken: executionFenceToken)
                        }
                    }
                    result = .outlet("next")
                } else if let presenter,
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
                    ) else {
                        await finish(run, outcome: "abandoned", leg: leg, journal: journal,
                            dismissPresentation: dismissPresentationOnCompletion, executionFenceToken: executionFenceToken)
                        return
                    }
                    let presentationAction = await presenter
                        .resolveJourneyPresentationAction(
                            owner: .init(
                                journeyId: run.journeyId,
                                distinctId: journal.distinctId
                            ),
                            action: contextResolvedAction,
                            source: presentationSource,
                            eventSource: eventSource
                        )
                    let resolvedAction: [String: JourneyReleaseJSONValue]
                    if let presentationAction {
                        resolvedAction = presentationAction
                    } else if actionType == .purchase {
                        var failedPurchase = contextResolvedAction
                        failedPurchase["placementId"] = .string("")
                        resolvedAction = failedPurchase
                    } else {
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
                    if actionType == .purchase,
                       case .string(let placementId)? = resolvedAction["placementId"],
                       !placementId.isEmpty {
                        if let offer = JourneyOfferAccess.offer(forPurchaseStep: command.step.id, in: leg) {
                            let decision = await offerDecision(offer, release: release, placementId: placementId)
                            guard executionFence.isCurrent(executionFenceToken),
                                  await isCurrentIdentity(originIdentityToken, journal: journal) else {
                                await finishAfterAuthorityLoss(run, leg: leg, journal: journal, executionFenceToken: executionFenceToken)
                                return
                            }
                            if decision != .eligible {
                                do {
                                    try await coordinator.commit(.init(
                                        stepId: decision == .alreadyEntitled ? offer.alreadyEntitledStepId : offer.unknownStepId,
                                        context: run.context,
                                        experimentExposure: nil
                                    ))
                                } catch {
                                    LogWarning("JourneyService: failed to persist checkout alternative: \(error)")
                                    return
                                }
                                continue
                            }
                        } else {
                            let placements = try? decodeJourneyDocuments(JourneyReleasePlacementDocument.self, from: release.descriptor.placements)
                            let products = try? decodeJourneyDocuments(JourneyReleaseProductDocument.self, from: release.descriptor.products)
                            let productId = placements?.first(where: { $0.id == placementId })?.productId
                            guard products?.first(where: { $0.id == productId })?.type == "consumable" else {
                                await finish(run, outcome: "abandoned", leg: leg, journal: journal,
                                    dismissPresentation: dismissPresentationOnCompletion,
                                    executionFenceToken: executionFenceToken)
                                return
                            }
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
                            effectId: effectId,
                            sourceScreenId: presentationSource?.screenId
                        )
                    guard executionFence.isCurrent(executionFenceToken),
                          await isCurrentIdentity(
                            originIdentityToken,
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
                    case .navigate(let screenId):
                        let owner = JourneyPresentationOwner(
                            journeyId: run.journeyId,
                            distinctId: journal.distinctId
                        )
                        if let offer = leg.offers.first(where: { $0.screenId == screenId }) {
                            let decision = await offerDecision(offer, release: release)
                            guard executionFence.isCurrent(executionFenceToken),
                                  await isCurrentIdentity(originIdentityToken, journal: journal) else {
                                await presenter.cancelJourneyBackNavigation(owner: owner)
                                await finishAfterAuthorityLoss(run, leg: leg, journal: journal,
                                    executionFenceToken: executionFenceToken)
                                return
                            }
                            if decision != .eligible {
                                await presenter.cancelJourneyBackNavigation(owner: owner)
                                do {
                                    try await coordinator.commit(.init(
                                        stepId: decision == .alreadyEntitled ? offer.alreadyEntitledStepId : offer.unknownStepId,
                                        context: run.context,
                                        experimentExposure: nil
                                    ))
                                } catch {
                                    LogWarning("JourneyService: failed to persist back-navigation alternative: \(error)")
                                    return
                                }
                                continue
                            }
                        }
                        let navigation = await presenter.navigateJourneyPresentation(
                            owner: owner,
                            screenId: screenId,
                            transition: resolvedAction["transition"]
                        )
                        guard executionFence.isCurrent(executionFenceToken),
                              await isCurrentIdentity(originIdentityToken, journal: journal) else {
                            await presenter.cancelJourneyBackNavigation(owner: owner)
                            await finishAfterAuthorityLoss(run, leg: leg, journal: journal,
                                executionFenceToken: executionFenceToken)
                            return
                        }
                        switch navigation {
                        case .navigated:
                            return
                        case .alreadyActive:
                            // No renderer callback is produced for a no-op.
                            await presenter.cancelJourneyBackNavigation(owner: owner)
                            _ = await handlePresentationScreenChanged(
                                screenId, presentedRun: run, release: release,
                                executionFenceToken: executionFenceToken
                            )
                            return
                        case .superseded:
                            await presenter.cancelJourneyBackNavigation(owner: owner)
                            return
                        case .productsUnavailable:
                            await presenter.cancelJourneyBackNavigation(owner: owner)
                            return
                        case .noPresentation, .declined, .failed:
                            await presenter.cancelJourneyBackNavigation(owner: owner)
                            await finish(run, outcome: "abandoned", leg: leg, journal: journal,
                                dismissPresentation: dismissPresentationOnCompletion,
                                executionFenceToken: executionFenceToken)
                            return
                        }
                    case .completed(let outcome):
                        pendingPresentationPurchasePlacements.removeValue(forKey: run.id)
                        result = .complete(outcome)
                    case .advanced(let outlet):
                        pendingPresentationPurchasePlacements.removeValue(forKey: run.id)
                        if actionType.isCommerce {
                            // Synchronous failures have the same retry semantics as store outcomes.
                            do {
                                let nextStepId = command.step.outlets?[outlet]
                                guard let continued = try await journal.settlePresentationCommerce(run.id,
                                    stepId: command.step.id, effectId: effectId, nextStepId: nextStepId,
                                    admission: originAdmission) else { return }
                                if nextStepId != nil {
                                    await continuePresentedRun(continued, release: release,
                                        executionFenceToken: executionFenceToken, signal: .init(), journal: journal)
                                }
                            } catch {
                                LogWarning("JourneyService: failed to settle synchronous commerce outcome: \(error)")
                                await finish(run, outcome: "abandoned", leg: leg, journal: journal,
                                    dismissPresentation: dismissPresentationOnCompletion,
                                    executionFenceToken: executionFenceToken,
                                    originAdmission: originAdmission)
                            }
                            return
                        }
                        result = .outlet(outlet)
                    case .permissionResolved(let outlet, let event):
                        pendingPresentationPurchasePlacements.removeValue(
                            forKey: run.id
                        )
                        guard let capture = await capturePresentationPermissionEvent(
                            event,
                            eventId: effectId,
                            run: run,
                            identityFenceToken: originIdentityToken,
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
                        identityFence: originIdentityToken,
                        executionFence: executionFence,
                        executionFenceToken: executionFenceToken,
                        customer: run.executionSnapshot.customer ?? [:]
                    ))
                }
                guard executionFence.isCurrent(executionFenceToken),
                      await isCurrentIdentity(
                    originIdentityToken,
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
                    if run.pendingCommerce != nil {
                        await closeWhileCommercePending(run, outcome: outcome, journal: journal, admission: originAdmission)
                        return
                    }
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
        requireCurrentIdentity: Bool = true,
        originAdmission: JourneyCommitAdmission? = nil
    ) async -> Bool {
        guard let persisted = await persistCompletion(
            run,
            outcome: outcome,
            leg: leg,
            journal: journal,
            executionFenceToken: executionFenceToken,
            requireCurrentIdentity: requireCurrentIdentity,
            originAdmission: originAdmission
        ) else { return false }
        return await settlePersistedCompletion(
            run,
            journal: journal,
            admission: persisted.admission,
            dismissPresentation: dismissPresentation
        )
    }

    private func closeWhileCommercePending(
        _ run: JourneyRun, outcome: String, journal: JourneyRunJournal, admission: JourneyCommitAdmission
    ) async {
        guard let pending = run.pendingCommerce else { return }
        do {
            guard try await journal.recordAuthoredCloseWhileCommercePending(run.id,
                effectId: pending.effectId, outcome: outcome, admission: admission) else { return }
            await presenter?.finishJourneyPresentation(owner: .init(journeyId: run.journeyId, distinctId: journal.distinctId))
        } catch {
            LogWarning("JourneyService: failed to retain authored close during commerce: \(error)")
        }
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
        requireCurrentIdentity: Bool = true,
        originAdmission: JourneyCommitAdmission? = nil
    ) async -> PersistedCompletion? {
        let admission: JourneyCommitAdmission?
        if let originAdmission {
            admission = originAdmission
        } else if let executionFenceToken {
            guard let currentAdmission = journalCommitAdmission(
                journal: journal,
                executionFenceToken: executionFenceToken,
                requireCurrentIdentity: requireCurrentIdentity
            ) else { return nil }
            admission = currentAdmission
        } else {
            admission = nil
        }
        var context = run.context
        if let values = nativeValuesByRun[run.id], values.owner == journal.distinctId {
            do { context = .init(event: context.event, responses: try await readNativeValues(values.values)) }
            catch {
                LogWarning("JourneyService: completion native value read failed: \(error)")
                return nil
            }
        }
        let projected = leg.completionOutputs[outcome].flatMap {
            JourneyBoundaryProjector.project(
                context: context,
                boundary: $0
            )
        }
        let finalOutcome = projected == nil && leg.completionOutputs[outcome] != nil
            ? "abandoned"
            : outcome
        do {
            guard try await journal.complete(
                run.id,
                outcome: finalOutcome,
                at: dateProvider.now(),
                eventOutputs: projected?.event ?? [:],
                responseOutputs: finalOutcome == "abandoned"
                    ? context.responses
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
        await retireNativeValues(runID: run.id)
        var reportsSettled = true
        do {
            _ = try await experimentExposures.flushPending(
                in: journal,
                admission: admission
            )
            try await JourneyReporter(journal: journal, events: events)
                .flushPending()
        } catch {
            LogWarning("JourneyService: failed to settle Journey completion: \(error)")
            reportsSettled = false
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
        return reportsSettled
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

    /// The inbox owns retry; the journal receipt closes the crash window between
    /// applying measurement and acknowledging its capture. Recovery does not
    /// route old events back through presentation or entry actions.
    private func recoverConversionOccurrences(throughEventId: String? = nil) async -> Bool {
        guard let journal, isCurrentIdentity(journal: journal) else { return false }
        let executionFenceToken = executionFence.token()
        do {
            while isCurrentIdentity(journal: journal) {
                let pending = try await events.pendingConversionOccurrences(distinctId: journal.distinctId, limit: 100, throughEventId: throughEventId)
                if pending.isEmpty { return true }
                guard let admission = journalCommitAdmission(journal: journal,
                    executionFenceToken: executionFenceToken) else { return false }
                for item in pending {
                    let stored = item.event
                    guard let properties = try JSONSerialization.jsonObject(with: stored.properties) as? [String: Any] else {
                        throw EventStorageError.invalidProperties
                    }
                    let event = NuxieEvent(id: stored.id, name: stored.name, forwardingName: stored.name, distinctId: stored.distinctId,
                        properties: properties, timestamp: stored.timestamp, journeyOrigin: stored.journeyOrigin)
                    let watches = try await journal.conversionWatches()
                    var matching = Set<String>()
                    if let occurrence = JourneyConversionWatch.normalized(event, acceptedAt: item.acceptedAt) {
                        for watch in watches.values where await watch.matches(occurrence) {
                            matching.insert(watch.journeyId)
                        }
                    }
                    guard try await journal.recordConversionOccurrence(event, acceptedAt: item.acceptedAt,
                        matching: matching, admission: admission, processingAt: dateProvider.now()) else { return false }
                    try await events.acknowledgeConversionOccurrence(eventId: event.id, distinctId: journal.distinctId)
                }
            }
        } catch {
            LogError("Failed to recover Journey conversion measurement: \(error)")
        }
        return false
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
        if run.pendingCommerce != nil { return true }
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
        try? await resumeParkedRuns(event: nil)
        guard let state = currentProfileState() else { return }
        guard isCurrent(state) else { return }
        // Event-triggered arms deliberately wait for the next matching event.
        // State arms can be re-evaluated when capacity returns without storing
        // or replaying a presentation request.
        await evaluateStateArms(state: state, kinds: nil)
    }

    private func scheduleNextWake() async {
        cancelWake()
        guard initialized, let journal, isCurrentIdentity(journal: journal) else { return }
        let schedulingGeneration = wakeGeneration
        let inspectedJournalGeneration = journalGeneration
        let runs: [JourneyRun]
        do {
            runs = try await readJournalRuns(journal)
        } catch {
            LogWarning("JourneyService: failed to inspect park points: \(error)")
            // A failed scheduling read must not lose a durable park. The next
            // scheduling pass retries the journal without querying event state.
            guard schedulingGeneration == wakeGeneration,
                  inspectedJournalGeneration == journalGeneration,
                  isCurrentIdentity(journal: journal) else { return }
            scheduleWake(generation: schedulingGeneration, at: dateProvider.now().addingTimeInterval(1), deadlines: nil)
            return
        }
        guard schedulingGeneration == wakeGeneration,
              inspectedJournalGeneration == journalGeneration,
              isCurrentIdentity(journal: journal) else { return }
        let deadlines = runs.compactMap { deadline(for: $0, distinctId: journal.distinctId) }
        let savedInputRunIds = Set(runs.filter {
            $0.park?.pendingEvent != nil || $0.park?.candidateEvents?.isEmpty == false
        }.map(\.id))
        let current = Set(deadlines)
        enqueuedDeadlines.formIntersection(current)
        foregroundDeadlines.formIntersection(current)
        deadlineRetryAt = deadlineRetryAt.filter { current.contains($0.key) }
        var savedInputRetryNeeded = false
        let pending = deadlines.filter { deadline in
            let restoring = nativeRestoreRetries[deadline.runId].map {
                $0.checkpoint.stepId == deadline.stepId && $0.checkpoint.anchorAt == deadline.anchorAt
                    && $0.checkpoint.wakeAt == deadline.wakeAt
            } ?? false
            guard !restoring else { return false }
            if foreground, savedInputRunIds.contains(deadline.runId) {
                // Saved inputs have already reached Journeys. Retry their
                // application through EventLog's timer before timing them out.
                savedInputRetryNeeded = true
                return false
            }
            return !enqueuedDeadlines.contains(deadline) && !foregroundDeadlines.contains(deadline)
        }
        let now = dateProvider.now()
        let dated = pending.map { deadline -> (deadline: JourneyDeadline, at: Date) in
            return (deadline, max(deadline.wakeAt, deadlineRetryAt[deadline] ?? deadline.wakeAt))
        }
        let due = dated.filter { $0.at <= now }.map(\.deadline)
        enqueuedDeadlines.formUnion(due)
        if savedInputRetryNeeded { await events.requestJourneyResumeRetry() }
        for deadline in due { await events.enqueueJourneyDeadline(deadline) }
        guard schedulingGeneration == wakeGeneration,
              inspectedJournalGeneration == journalGeneration else { return }
        guard let next = dated.filter({ $0.at > now }).map(\.at).min() else { return }
        scheduleWake(generation: schedulingGeneration, at: next,
                     deadlines: dated.filter { $0.at == next }.map(\.deadline))
    }

    private func scheduleWake(generation: UInt64, at date: Date, deadlines: [JourneyDeadline]?) {
        let sleeper = sleepProvider
        let delay = max(0, date.timeIntervalSince(dateProvider.now()))
        wakeTask = Task { [weak self] in
            do { try await sleeper.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.wake(generation: generation, at: date, deadlines: deadlines)
        }
    }

    private func wake(generation: UInt64, at date: Date, deadlines: [JourneyDeadline]?) async {
        guard generation == wakeGeneration else { return }
        wakeTask = nil
        guard dateProvider.now() >= date else {
            scheduleWake(generation: generation, at: date, deadlines: deadlines)
            return
        }
        guard let deadlines else { await scheduleNextWake(); return }
        // The timer only enqueues the checkpoints selected when it was set.
        // It never resumes a wait or asks about event/delivery progress.
        let due = deadlines.filter { !enqueuedDeadlines.contains($0) }
        enqueuedDeadlines.formUnion(due)
        for deadline in due { await events.enqueueJourneyDeadline(deadline) }
        // Enqueueing does not imply delivery: a routing hold can retain these
        // controls while later parks still need their own queue positions.
        guard generation == wakeGeneration else { return }
        await scheduleNextWake()
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
