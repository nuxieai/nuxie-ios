import Foundation

protocol DeviceLegProfileConsuming: AnyObject, Sendable {
    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
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
}

/// Owns the complete local lifecycle of authenticated flat device legs. The
/// profile catalog authenticates immutable programs; this actor evaluates
/// arms, journals every transition, and reports terminal boundaries through
/// EventLog's existing durable event queue.
actor DeviceLegService: DeviceLegServiceProtocol {
    typealias FeatureAccessLookup = @Sendable (String) async -> FeatureAccess?
    typealias PinnedReleaseAuthenticator = @Sendable (
        DeviceLegReleaseProfileEntry,
        ArmedDeviceLeg.Reference
    ) async throws -> AuthenticatedDeviceLegRelease

    private struct ProfileState: Sendable {
        let distinctId: String
        let snapshot: DeviceLegProfileCatalog.Snapshot
        let generation: UInt64
    }

    private typealias StateArmKey = DeviceLegStateArmReceipt

    private struct AttemptKey: Hashable, Sendable {
        let arm: StateArmKey
        let eventId: String?
        let profileGeneration: UInt64
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
    private let dateProvider: DateProviderProtocol
    private let sleepProvider: SleepProviderProtocol
    private let journalDirectory: URL?
    /// Production starts without a journal namespace and installs one only
    /// after profile transport authenticates the configured Nuxie app. Tests
    /// may inject a fixed scope for direct journal inspection.
    private var storageScope: DeviceLegStorageScope?
    private let acceptsProfileAuthorityScope: Bool
    private let featureAccess: FeatureAccessLookup
    private let dispatcher: any DeviceLegDispatching
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
    private let executionFence = DeviceLegProfileFence()
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
        pinnedReleaseAuthenticator: @escaping PinnedReleaseAuthenticator,
        timezones: SignedTimezoneBundle,
        currentDeviceTimezone: TimeZone = .current
    ) {
        self.identity = identity
        self.events = events
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.journalDirectory = journalDirectory
        self.storageScope = storageScope
        acceptsProfileAuthorityScope = storageScope == nil
        self.featureAccess = featureAccess
        self.dispatcher = dispatcher
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
        if storageScope != nil {
            await openJournal(for: identity.getDistinctId())
        }
        await resetForegroundStateArmReceiptsIfNeeded()
        guard let state = currentProfileState() else { return }
        await resumeParkedRuns(state: state, event: nil)
        await evaluateStateArms(state: state, kinds: nil)
    }

    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
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
        await commitProfile(snapshot, distinctId: distinctId)
    }

    /// Direct runtime tests use an injected fixed namespace and do not model
    /// the profile transport boundary.
    func profileDidCommit(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        distinctId: String
    ) async {
        await commitProfile(snapshot, distinctId: distinctId)
    }

    private func commitProfile(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        distinctId: String
    ) async {
        guard identity.getDistinctId() == distinctId else { return }
        let generation = profileFence.advance()
        profileState = ProfileState(
            distinctId: distinctId,
            snapshot: snapshot,
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
        if let journalToAbandon {
            await abandon(journalToAbandon)
        }
    }

    func profileDidClearAll() async {
        cancelWake()
        let journalToAbandon = journal
        _ = profileFence.advance()
        _ = executionFence.advance()
        profileState = nil
        clearRetainedReleaseCache()
        stateArmReceipts.removeAll()
        inFlightAttempts.removeAll()
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
        guard initialized,
              event.distinctId == identity.getDistinctId(),
              event.name != JourneyEvents.journeyLegStarted,
              event.name != JourneyEvents.journeyLegCompleted,
              let state = currentProfileState() else { return }

        await resumeParkedRuns(state: state, event: event)
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

    func onAppDidEnterBackground() async {
        foreground = false
        cancelWake()
    }

    func onAppWillEnterForeground() async {
        foreground = true
        foregroundReceiptResetCustomers.removeAll()
        await resetForegroundStateArmReceiptsIfNeeded()
    }

    func onAppBecameActive() async {
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
        let entryKind = DeviceLegEntryCondition.Kind.appForegrounded.rawValue
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
                storageScope: storageScope
            )
            clearRetainedReleaseCache()
            journal = opened
            _ = try await opened.recover(at: dateProvider.now())
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
        return true
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
              }) else { return }

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
        guard let profileFenceToken = profileFence.token(
            ifCurrent: state.generation
        ) else { return }
        let executionFenceToken = executionFence.token()
        do {
            guard let run = try await journal.admit(
                arm: admittedArm,
                release: releasePin,
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
                await finish(
                    run,
                    outcome: "abandoned",
                    leg: release.descriptor.leg,
                    journal: journal
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
                journal: journal
            )
        } catch {
            LogWarning("DeviceLegService: failed to start device leg: \(error)")
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

    private func resumeParkedRuns(
        state: ProfileState,
        event: NuxieEvent?
    ) async {
        guard isCurrent(state),
              event != nil || foreground,
              let journal else { return }
        do {
            for parked in try await journal.runs()
            where parked.park != nil && parked.completion == nil {
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
                ) else { return }
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
            try await DeviceLegReporter(journal: journal, events: events)
                .flushPending()
        } catch {
            LogWarning(
                "DeviceLegService: failed to abandon retained device leg: \(error)"
            )
        }
    }

    private func execute(
        _ initial: DeviceLegRun,
        release: AuthenticatedDeviceLegRelease,
        state: ProfileState,
        executionFenceToken: DeviceLegProfileFenceToken,
        signal: DeviceLegControlExecutor.Signal,
        checkpoint initialCheckpoint: DeviceLegControlExecutor.Checkpoint?,
        journal: DeviceLegRunJournal
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

        for _ in 0..<10_000 {
            guard executionFence.isCurrent(executionFenceToken),
                  isCurrentIdentity(journal: journal) else {
                await finish(
                    run,
                    outcome: "abandoned",
                    leg: leg,
                    journal: journal
                )
                return
            }
            guard let step = steps[run.stepId],
                  let now = milliseconds(dateProvider.now()) else {
                await finish(
                    run,
                    outcome: "abandoned",
                    leg: leg,
                    journal: journal
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
            case .advance(let stepId, let context):
                do {
                    try await journal.transition(
                        run.id,
                        stepId: stepId,
                        context: context
                    )
                } catch {
                    LogWarning("DeviceLegService: failed to persist control transition: \(error)")
                    return
                }
                run.stepId = stepId
                run.context = context
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
                    journal: journal
                )
                return

            case .dispatch(let stepId, let action):
                guard let identityFence = identity.performWithCurrentIdentityFence(
                    journal.distinctId,
                    { _ in () }
                ) else {
                    await finish(
                        run,
                        outcome: "abandoned",
                        leg: leg,
                        journal: journal
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
                    await finish(
                        run,
                        outcome: "abandoned",
                        leg: leg,
                        journal: journal
                    )
                    return
                }
                let result = await dispatcher.dispatch(.init(
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
                guard executionFence.isCurrent(executionFenceToken),
                      await isCurrentIdentity(
                    identityFence.token,
                    journal: journal
                ) else {
                    await finish(
                        run,
                        outcome: "abandoned",
                        leg: leg,
                        journal: journal
                    )
                    return
                }
                switch result {
                case .outlet(let outlet):
                    guard case .advance(let nextStepId, let context) = executor.selectOutlet(
                        step,
                        outlet: outlet,
                        context: run.context
                    ) else {
                        await finish(
                            run,
                            outcome: "abandoned",
                            leg: leg,
                            journal: journal
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

                case .complete(let outcome):
                    await finish(
                        run,
                        outcome: outcome,
                        leg: leg,
                        journal: journal
                    )
                    return

                case .unsupported:
                    do {
                        try await journal.park(
                            run.id,
                            stepId: stepId,
                            until: nil
                        )
                    } catch {
                        LogWarning("DeviceLegService: failed to retain effect cursor: \(error)")
                    }
                    return

                case .failed:
                    await finish(
                        run,
                        outcome: "abandoned",
                        leg: leg,
                        journal: journal
                    )
                    return
                }

            case .invalid:
                await finish(
                    run,
                    outcome: "abandoned",
                    leg: leg,
                    journal: journal
                )
                return
            }
        }

        await finish(
            run,
            outcome: "abandoned",
            leg: leg,
            journal: journal
        )
    }

    private func finish(
        _ run: DeviceLegRun,
        outcome: String,
        leg: DeviceLeg,
        journal: DeviceLegRunJournal
    ) async {
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
            try await journal.complete(
                run.id,
                outcome: finalOutcome,
                at: dateProvider.now(),
                eventOutputs: projected?.event ?? [:],
                responseOutputs: finalOutcome == "abandoned"
                    ? run.context.responses
                    : projected?.responses ?? [:]
            )
            try await DeviceLegReporter(journal: journal, events: events)
                .flushPending()
        } catch {
            LogWarning("DeviceLegService: failed to complete device leg: \(error)")
        }
        await scheduleNextWake()
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
        guard let event,
              let occurredAt = milliseconds(event.timestamp) else { return .init() }
        var properties = ExactJSONObject<ExperienceReleaseJSONValue>()
        for (key, value) in event.properties {
            if let converted = DeviceLegBoundaryProjector.jsonValue(value) {
                properties[key] = converted
            }
        }
        return .init(event: .init(
            name: event.name,
            occurredAtMillis: occurredAt,
            properties: properties
        ))
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
