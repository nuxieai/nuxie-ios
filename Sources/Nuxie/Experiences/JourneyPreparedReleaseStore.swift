import Foundation

/// The single shared store of prepared Journey releases, keyed by signed
/// descriptor SHA-256.
///
/// A prepared release is its verified bytes and renderer payloads in memory
/// (`PreparedRuntimeRelease`) plus its native preparation in `cache`. Every
/// armed release is prepared once, in the background, at low priority, one
/// Experience at a time. A show of a prepared release is then a lookup: no
/// object reads, no SHA checks, and no native preparation.
///
/// Profile commits are bookkeeping only and never wait for lane work. A new
/// profile keeps what is still armed or reserved by a live show, drops the
/// rest, and queues anything new. Resetting or switching between identified
/// users drops everything, including queued and in-flight work; a first
/// sign-in keeps it (`PreparedReleaseUserSwitchPolicy`).
actor JourneyPreparedReleaseStore {
    struct Entry: Sendable {
        let release: AuthenticatedJourneyRelease
        let delivery: JourneyReleaseDelivery
        var runtime: PreparedRuntimeRelease?
        let isEnrollment: Bool
    }

    nonisolated let cache: ExperienceInteractivePreparationCache
    nonisolated let gate: ExperiencePreparationGate

    private let acquirer: any JourneyReleaseAcquiring
    private let automaticPreparation: Bool

    private var ownerDistinctId: String?
    /// The anonymous owner whose releases the current owner kept when its
    /// profile committed before the user transition reported that sign-in.
    private var unconfirmedSignInFrom: String?
    private var latestGeneration: UInt64 = 0
    /// Fences work started for an earlier user or a discarded state.
    private var epoch: UInt64 = 0
    /// Fences the tail of a profile change that a newer change superseded
    /// while it awaited the preparation cache.
    private var revision: UInt64 = 0
    private var entries: [String: Entry] = [:]
    private var armed: Set<String> = []
    private var reservations: [String: Set<UUID>] = [:]
    private var pending: [String] = []
    private var laneTask: Task<Void, Never>?
    private var laneID: UInt64 = 0
    /// Lane bodies still running, including one a discard cancelled while
    /// it finishes its current item.
    private var runningLanes = 0
    private var laneItem: String?
    private var acquisitions: [String: Acquisition] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false

    private struct Acquisition {
        let id: UUID
        let task: Task<PreparedRuntimeRelease?, Error>
    }

    init(
        acquirer: any JourneyReleaseAcquiring,
        cache: ExperienceInteractivePreparationCache = .init(),
        gate: ExperiencePreparationGate,
        automaticPreparation: Bool
    ) {
        self.acquirer = acquirer
        self.cache = cache
        self.gate = gate
        self.automaticPreparation = automaticPreparation
    }

    // MARK: - Profile

    /// Installs the armed releases of a committed profile. Bookkeeping only:
    /// it never awaits lane work, so it cannot delay profile admission.
    /// A profile for a different owner first drops everything prepared for
    /// the current one, unless the new owner signed in from it. A nil owner
    /// never changes the owner.
    func replaceProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        owner: PreparedReleaseOwner?,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async {
        await install(
            snapshot: prepared.snapshot,
            runtimeSeeds: prepared.runtimeReleasesByDescriptorSHA256,
            owner: owner,
            generation: generation,
            admission: admission
        )
    }

    /// The profile was withdrawn without a replacement (locale change,
    /// per-user cache clear). Nothing stays armed; reserved releases stay
    /// for the shows that hold them. A withdrawal for someone other than the
    /// stored owner holds nothing of theirs and changes nothing.
    func withdrawProfile(
        ownerDistinctId: String?,
        generation: UInt64
    ) async {
        if let ownerDistinctId, let currentOwner = self.ownerDistinctId,
           ownerDistinctId != currentOwner {
            return
        }
        await install(
            snapshot: nil,
            runtimeSeeds: [:],
            owner: ownerDistinctId.map { PreparedReleaseOwner(distinctId: $0) },
            generation: generation,
            admission: nil
        )
    }

    private func install(
        snapshot: JourneyProfileCatalog.Snapshot?,
        runtimeSeeds: [String: PreparedRuntimeRelease],
        owner newOwner: PreparedReleaseOwner?,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async {
        guard !isShutDown,
              generation >= latestGeneration,
              admission?() ?? true else {
            return
        }
        latestGeneration = generation
        var ownerChanged = false
        if let newOwner, let currentOwner = ownerDistinctId,
           newOwner.distinctId != currentOwner {
            if PreparedReleaseUserSwitchPolicy.keepsPreparedReleases(
                ownedBy: currentOwner,
                for: newOwner
            ) {
                // A first sign-in whose profile arrived before its user
                // transition. Keep everything; the transition confirms it.
                unconfirmedSignInFrom = currentOwner
            } else {
                resetState()
                ownerChanged = true
            }
        }
        if let newOwner { ownerDistinctId = newOwner.distinctId }
        revision &+= 1
        let installRevision = revision

        var nextArmed: Set<String> = []
        if let snapshot {
            let enrollment = Set(snapshot.profile.armedLegs.compactMap {
                $0.binding.type == .new ? $0.reference.descriptorSha256 : nil
            })
            for (descriptorSHA256, release) in snapshot.releasesByDigest
            where release.descriptor.render != nil {
                nextArmed.insert(descriptorSHA256)
                entries[descriptorSHA256] = Entry(
                    release: release,
                    delivery: snapshot.profile.delivery,
                    runtime: entries[descriptorSHA256]?.runtime
                        ?? runtimeSeeds[descriptorSHA256],
                    isEnrollment: enrollment.contains(descriptorSHA256)
                )
            }
        }
        armed = nextArmed
        let retained = retainedDescriptors
        for descriptorSHA256 in Array(entries.keys)
        where !retained.contains(descriptorSHA256) {
            entries[descriptorSHA256] = nil
        }
        for (descriptorSHA256, acquisition) in acquisitions
        where !retained.contains(descriptorSHA256) {
            acquisition.task.cancel()
            acquisitions[descriptorSHA256] = nil
        }
        pending.removeAll { !armed.contains($0) }

        if ownerChanged {
            await cache.removeAll()
        } else {
            await cache.retainPreparations(for: retained)
        }
        guard revision == installRevision else { return }

        let candidates = armed
            .filter { $0 != laneItem && !pending.contains($0) }
            .sorted { lhs, rhs in
                let lhsEnrollment = entries[lhs]?.isEnrollment == true
                let rhsEnrollment = entries[rhs]?.isEnrollment == true
                if lhsEnrollment != rhsEnrollment { return lhsEnrollment }
                return lhs < rhs
            }
        var queued: [String] = []
        for descriptorSHA256 in candidates {
            if await cache.status(for: descriptorSHA256) == .miss {
                queued.append(descriptorSHA256)
            }
        }
        guard revision == installRevision else { return }
        pending.append(contentsOf: queued.filter {
            armed.contains($0) && $0 != laneItem && !pending.contains($0)
        })
        gate.noteProfileCommitted()
        kickLane()
    }

    /// Drops everything prepared, queued, and in flight for the departing
    /// user. It acts only when `departingDistinctId` is nil, matches the
    /// stored owner, or no owner is stored, so a discard that arrives after
    /// the next user's profile commit cannot wipe that user's state.
    func discard(departingDistinctId: String?) async {
        if let departingDistinctId, let currentOwner = ownerDistinctId,
           departingDistinctId != currentOwner {
            return
        }
        resetState()
        ownerDistinctId = nil
        revision &+= 1
        await cache.removeAll()
        resumeIdleWaitersIfIdle()
    }

    /// Hands everything prepared to the user an anonymous user signed in as
    /// (see `PreparedReleaseUserSwitchPolicy`), without dropping anything.
    /// If the arriving user's profile committed first, it already kept them
    /// and this confirms it. If a later user's commit kept them instead, the
    /// anonymous user signed in as someone else before that user arrived, so
    /// the later user is a switch between identified users and everything
    /// is dropped. Their profile admits again later in the same transition.
    func transferOwner(
        from departingDistinctId: String,
        to arrivingDistinctId: String
    ) async {
        if ownerDistinctId == nil || ownerDistinctId == departingDistinctId {
            ownerDistinctId = arrivingDistinctId
            unconfirmedSignInFrom = nil
        } else if ownerDistinctId == arrivingDistinctId {
            unconfirmedSignInFrom = nil
        } else if unconfirmedSignInFrom == departingDistinctId {
            await discard(departingDistinctId: nil)
        }
    }

    // MARK: - Shows

    /// Reserves one release for a show, so nothing drops it until the show
    /// ends, and reports whether the show can skip the loading shimmer.
    func reserve(
        descriptorSHA256: String
    ) async -> (ExperiencePresentationWarmReservation, ExperiencePresentationReadiness) {
        let id = UUID()
        reservations[descriptorSHA256, default: []].insert(id)
        let status = await cache.status(for: descriptorSHA256)
        let readiness: ExperiencePresentationReadiness =
            entries[descriptorSHA256]?.runtime != nil && status == .prepared
                ? .prepared
                : .cold
        let reservation = ExperiencePresentationWarmReservation { [weak self] in
            Task { await self?.releaseReservation(id, descriptorSHA256: descriptorSHA256) }
        }
        return (reservation, readiness)
    }

    private func releaseReservation(_ id: UUID, descriptorSHA256: String) async {
        guard reservations[descriptorSHA256]?.remove(id) != nil else { return }
        if reservations[descriptorSHA256]?.isEmpty == true {
            reservations[descriptorSHA256] = nil
        }
        guard !armed.contains(descriptorSHA256),
              reservations[descriptorSHA256] == nil else {
            return
        }
        entries[descriptorSHA256] = nil
        acquisitions.removeValue(forKey: descriptorSHA256)?.task.cancel()
        await cache.retainPreparations(for: retainedDescriptors)
    }

    /// Answers one show's artifact request. A prepared release is a lookup;
    /// a release waiting in the lane starts now at the trigger's priority and
    /// the lane skips it; an in-flight preparation is joined, never started
    /// twice; anything else takes the cold path, and its work fills the
    /// store for later shows.
    func presentationArtifact(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?,
        screenID: String,
        identity: AcquiredExperienceArtifact.Identity,
        productResolver: @escaping @Sendable (String) async throws -> [StoreProduct]
    ) async throws -> AcquiredExperienceArtifact {
        let descriptorSHA256 = release.descriptorSHA256
        let wasWaiting = pending.contains(descriptorSHA256)
        pending.removeAll { $0 == descriptorSHA256 }

        var outcome: JourneyPreparedReleaseOutcome
        let resolved: PreparedRuntimeRelease?
        // Only a show that starts the read reports what the read cost and
        // where it came from; anything the store already held, or another
        // caller was reading, is a cache hit that read nothing.
        let startedAcquisition: Bool
        if let runtime = entries[descriptorSHA256]?.runtime {
            let status = await cache.status(for: descriptorSHA256)
            outcome = status == .preparing ? .joined : .hit
            startedAcquisition = false
            resolved = runtime
        } else if let inFlight = acquisitions[descriptorSHA256] {
            outcome = .joined
            startedAcquisition = false
            resolved = try await inFlight.task.value
        } else {
            outcome = .cold
            startedAcquisition = true
            resolved = try await acquisition(
                release: release,
                delivery: delivery,
                intent: .presentation,
                pinnedArtifacts: pinnedArtifacts
            ).value
        }
        if wasWaiting { outcome = .jumped }
        guard let runtime = resolved else {
            throw JourneyReleaseAcquisitionError.invalidProfileEntry
        }
        guard let payload = runtime.payloadsByScreenID[screenID] else {
            throw JourneyReleaseAcquisitionError.selectedScreenNotDeclared(
                screenID
            )
        }
        return try runtime.presentationArtifact(
            identity: identity,
            provenance: descriptorSHA256,
            initialScreenID: screenID,
            interactivePreparation: ExperienceInteractivePreparationHandle(
                cache: cache,
                provenance: descriptorSHA256,
                payload: payload
            ),
            source: startedAcquisition ? runtime.source : .cache,
            resourceMetrics: startedAcquisition ? runtime.resourceMetrics : .zero,
            preparedReleaseOutcome: outcome,
            productResolver: productResolver
        )
    }

    // MARK: - Lifecycle

    /// The app became active. The gate opens now, on the caller's thread,
    /// so it stays in notification order with the pause. The lane then
    /// starts on the store, unless the app backgrounded again first. The
    /// returned task is that start; only tests await it.
    @discardableResult
    nonisolated func appDidBecomeActive() -> Task<Void, Never> {
        gate.becomeActive()
        return Task(priority: .utility) { await self.kickLane() }
    }

    /// Stops the lane and drops everything. Nothing starts afterwards.
    func shutdown() async {
        isShutDown = true
        await discard(departingDistinctId: nil)
    }

    /// Returns once no lane is running: every queued release is prepared, or
    /// the lane is paused in the background or disabled. A lane that a
    /// discard cancelled counts until it finishes its current item.
    /// For tests and the parent qualification host.
    func waitForIdle() async {
        while laneTask != nil || runningLanes > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// Read-only view of the store's bookkeeping, for tests.
    struct Inspection: Equatable, Sendable {
        let ownerDistinctId: String?
        let armed: Set<String>
        let pending: [String]
        let entries: Set<String>
        let reserved: Set<String>
    }

    func inspection() -> Inspection {
        Inspection(
            ownerDistinctId: ownerDistinctId,
            armed: armed,
            pending: pending,
            entries: Set(entries.keys),
            reserved: Set(reservations.keys)
        )
    }

    // MARK: - Lane

    private var retainedDescriptors: Set<String> {
        armed.union(reservations.keys)
    }

    private func resetState() {
        epoch &+= 1
        unconfirmedSignInFrom = nil
        laneTask?.cancel()
        laneTask = nil
        laneItem = nil
        for acquisition in acquisitions.values { acquisition.task.cancel() }
        acquisitions.removeAll()
        pending.removeAll()
        entries.removeAll()
        armed.removeAll()
        reservations.removeAll()
    }

    private func kickLane() {
        guard automaticPreparation,
              !isShutDown,
              !gate.snapshot().isBackgrounded,
              laneTask == nil,
              !pending.isEmpty else {
            resumeIdleWaitersIfIdle()
            return
        }
        laneID &+= 1
        let id = laneID
        runningLanes += 1
        laneTask = Task(priority: .utility) {
            await self.runLane(id: id)
        }
    }

    /// Prepares one release at a time, in queue order. In-flight work is
    /// never cancelled by backgrounding: native jobs cannot be interrupted,
    /// so the current item finishes and nothing new starts until active.
    private func runLane(id: UInt64) async {
        defer {
            runningLanes -= 1
            resumeIdleWaitersIfIdle()
        }
        while laneID == id,
              !Task.isCancelled,
              !isShutDown,
              !gate.snapshot().isBackgrounded,
              !pending.isEmpty {
            let descriptorSHA256 = pending.removeFirst()
            guard entries[descriptorSHA256] != nil,
                  await cache.status(for: descriptorSHA256) == .miss,
                  laneID == id,
                  let entry = entries[descriptorSHA256] else {
                continue
            }
            laneItem = descriptorSHA256
            await prepare(entry, descriptorSHA256: descriptorSHA256)
            if laneID == id { laneItem = nil }
        }
        guard laneID == id else { return }
        laneTask = nil
    }

    private func prepare(_ entry: Entry, descriptorSHA256: String) async {
        let startEpoch = epoch
        do {
            let runtime: PreparedRuntimeRelease?
            if let existing = entry.runtime {
                runtime = existing
            } else {
                runtime = try await (acquisitions[descriptorSHA256]?.task
                    ?? acquisition(
                        release: entry.release,
                        delivery: entry.delivery,
                        intent: .preload,
                        pinnedArtifacts: nil
                    )).value
            }
            guard epoch == startEpoch,
                  retainedDescriptors.contains(descriptorSHA256),
                  let runtime,
                  let payload = runtime.preparationPayload else {
                return
            }
            if entries[descriptorSHA256]?.runtime == nil {
                entries[descriptorSHA256]?.runtime = runtime
            }
            _ = try await ExperienceInteractivePreparationHandle(
                cache: cache,
                provenance: descriptorSHA256,
                payload: payload
            ).preparation(resourceMetricOwner: .preload)
            // The request leaves this actor before it reaches the cache, so
            // a discard or a profile change can drop the release and reach
            // the cache first; the request then prepares a release nothing
            // keeps. Re-apply the current set so it does not stay prepared.
            if epoch != startEpoch || !retainedDescriptors.contains(descriptorSHA256) {
                await cache.retainPreparations(for: retainedDescriptors)
            }
        } catch is CancellationError {
            return
        } catch {
            LogWarning(
                "Experience release preparation failed; the release stays cold: \(error)"
            )
        }
    }

    /// Starts, or returns, the one acquisition for a release. It runs as the
    /// store's own task, so a cancelled show still fills the store.
    private func acquisition(
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        intent: JourneyReleasePreparationIntent,
        pinnedArtifacts: JourneyPinnedReleaseArtifacts?
    ) -> Task<PreparedRuntimeRelease?, Error> {
        let descriptorSHA256 = release.descriptorSHA256
        if let existing = acquisitions[descriptorSHA256] { return existing.task }
        let id = UUID()
        let startEpoch = epoch
        let acquirer = acquirer
        let task = Task<PreparedRuntimeRelease?, Error> {
            do {
                let runtime = try await acquirer.prepareRuntimeRelease(
                    release: release,
                    delivery: delivery,
                    intent: intent,
                    pinnedArtifacts: pinnedArtifacts
                )
                self.finishAcquisition(
                    id: id,
                    release: release,
                    delivery: delivery,
                    runtime: runtime,
                    startEpoch: startEpoch
                )
                return runtime
            } catch {
                self.finishAcquisition(
                    id: id,
                    release: release,
                    delivery: delivery,
                    runtime: nil,
                    startEpoch: startEpoch
                )
                throw error
            }
        }
        acquisitions[descriptorSHA256] = Acquisition(id: id, task: task)
        return task
    }

    private func finishAcquisition(
        id: UUID,
        release: AuthenticatedJourneyRelease,
        delivery: JourneyReleaseDelivery,
        runtime: PreparedRuntimeRelease?,
        startEpoch: UInt64
    ) {
        let descriptorSHA256 = release.descriptorSHA256
        if acquisitions[descriptorSHA256]?.id == id {
            acquisitions[descriptorSHA256] = nil
        }
        guard let runtime,
              epoch == startEpoch,
              retainedDescriptors.contains(descriptorSHA256) else {
            return
        }
        if entries[descriptorSHA256] == nil {
            entries[descriptorSHA256] = Entry(
                release: release,
                delivery: delivery,
                runtime: runtime,
                isEnrollment: false
            )
        } else if entries[descriptorSHA256]?.runtime == nil {
            entries[descriptorSHA256]?.runtime = runtime
        }
    }

    private func resumeIdleWaitersIfIdle() {
        guard laneTask == nil, runningLanes == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
