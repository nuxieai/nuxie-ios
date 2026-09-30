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
/// rest, and queues anything new. Switching users drops everything,
/// including queued and in-flight work.
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
    func replaceProfile(
        _ prepared: PreparedJourneyProfileArtifacts,
        ownerDistinctId: String?,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async {
        await install(
            snapshot: prepared.snapshot,
            runtimeSeeds: prepared.runtimeReleasesByDescriptorSHA256,
            ownerDistinctId: ownerDistinctId,
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
            ownerDistinctId: ownerDistinctId,
            generation: generation,
            admission: nil
        )
    }

    private func install(
        snapshot: JourneyProfileCatalog.Snapshot?,
        runtimeSeeds: [String: PreparedRuntimeRelease],
        ownerDistinctId newOwner: String?,
        generation: UInt64,
        admission: ProfileSideEffectAdmission?
    ) async {
        guard !isShutDown,
              generation >= latestGeneration,
              admission?() ?? true else {
            return
        }
        latestGeneration = generation
        let ownerChanged: Bool
        if let newOwner, let currentOwner = ownerDistinctId,
           newOwner != currentOwner {
            resetState()
            ownerChanged = true
        } else {
            ownerChanged = false
        }
        if let newOwner { ownerDistinctId = newOwner }
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

    /// Re-tags the stored owner without dropping anything. Used only when a
    /// user transition keeps prepared releases (see
    /// `PreparedReleaseUserSwitchPolicy`).
    func transferOwner(from departingDistinctId: String, to arrivingDistinctId: String) {
        guard ownerDistinctId == nil || ownerDistinctId == departingDistinctId else {
            return
        }
        ownerDistinctId = arrivingDistinctId
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
        if let runtime = entries[descriptorSHA256]?.runtime {
            let status = await cache.status(for: descriptorSHA256)
            outcome = status == .preparing ? .joined : .hit
            resolved = runtime
        } else if let inFlight = acquisitions[descriptorSHA256] {
            outcome = .joined
            resolved = try await inFlight.task.value
        } else {
            outcome = .cold
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
            resourceMetrics: outcome == .cold ? runtime.resourceMetrics : .zero,
            preparedReleaseOutcome: outcome,
            productResolver: productResolver
        )
    }

    // MARK: - Lifecycle

    func onAppBecameActive() {
        gate.becomeActive()
        kickLane()
    }

    /// Stops the lane and drops everything. Nothing starts afterwards.
    func shutdown() async {
        isShutDown = true
        await discard(departingDistinctId: nil)
    }

    /// Returns once the background lane is not running: every queued release
    /// is prepared, or the lane is paused in the background or disabled.
    /// For tests and the parent qualification host.
    func waitForIdle() async {
        while laneTask != nil {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    // MARK: - Lane

    private var retainedDescriptors: Set<String> {
        armed.union(reservations.keys)
    }

    private func resetState() {
        epoch &+= 1
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
        laneTask = Task(priority: .utility) {
            await self.runLane(id: id)
        }
    }

    /// Prepares one release at a time, in queue order. In-flight work is
    /// never cancelled by backgrounding: native jobs cannot be interrupted,
    /// so the current item finishes and nothing new starts until active.
    private func runLane(id: UInt64) async {
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
        resumeIdleWaitersIfIdle()
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
        guard laneTask == nil else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
