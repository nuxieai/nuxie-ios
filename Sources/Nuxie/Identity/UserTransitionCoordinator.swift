import Foundation

/// Serializes user identity transitions (identify/reset) across every service
/// that holds per-user state.
///
/// The facade previously fanned each transition out as a cancellable task
/// chain; a second identify() cancelled the chain mid-sequence, stranding
/// services split across two users, and identify/reset chains could
/// interleave. Here every transition runs to COMPLETION in FIFO order — a
/// superseding transition queues, never cancels.
/// Not an actor: `enqueue` must be synchronous so the FIFO order is the
/// CALLER's order (identify → reset → identify). An async enqueue hop would
/// let rapid calls race each other to the queue.
final class UserTransitionCoordinator: @unchecked Sendable {

    enum Kind {
        case identify
        case reset
    }

    struct Transition {
        let kind: Kind
        let from: String
        let to: String
        /// Migrate the old user's local events to the new id (anonymous →
        /// identified transition).
        let migrateEvents: Bool
    }

    // Constructor-injected collaborators (Phase 4c composition root).
    private let profileService: ProfileServiceProtocol
    private let eventLog: EventIdentityMigrating
    private let featureService: FeatureServiceProtocol
    private let experienceService: ExperienceServiceProtocol
    private let journeyService: (any JourneyServiceProtocol)?

    init(
        profile: ProfileServiceProtocol,
        eventLog: EventIdentityMigrating,
        features: FeatureServiceProtocol,
        experiences: ExperienceServiceProtocol,
        journeys: (any JourneyServiceProtocol)? = nil
    ) {
        self.profileService = profile
        self.eventLog = eventLog
        self.featureService = features
        self.experienceService = experiences
        self.journeyService = journeys
    }

    /// FIFO chain: each enqueued transition awaits the previous one.
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Enqueue a transition. Synchronous and fire-and-forget from the
    /// caller's perspective; execution order is the enqueue order.
    func enqueue(_ transition: Transition) {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        // Strong self: a queued transition must never be silently dropped —
        // the coordinator lives for the SDK scope and the chain keeps it
        // alive until drained.
        tail = Task {
            await previous?.value
            await self.run(transition)
        }
    }

    /// Await all currently queued transitions (test determinism).
    func drain() async {
        let current = lock.withLock { tail }
        await current?.value
    }

    private func run(_ transition: Transition) async {
        LogInfo("User transition (\(transition.kind)) \(NuxieLogger.shared.logDistinctID(transition.from)) → \(NuxieLogger.shared.logDistinctID(transition.to))")

        // 1. Local event migration first so downstream evaluation sees the
        //    new user's full history. (Previously raced the service fan-out
        //    as an independent task.)
        if transition.migrateEvents {
            do {
                let count = try await eventLog.reassignEvents(from: transition.from, to: transition.to)
                if count > 0 {
                    LogInfo("Migrated \(count) anonymous events to \(NuxieLogger.shared.logDistinctID(transition.to))")
                }
            } catch {
                LogWarning("Failed to reassign anonymous events: \(error)")
            }
        }

        // 2. Per-user state transitions, in dependency order, uncancellable.
        // Retire the old flat-leg journal while its distinct id is still
        // explicit, before profile admission can publish replacement arms.
        await journeyService?.handleUserChange(
            from: transition.from,
            to: transition.to
        )
        if transition.kind == .reset {
            await profileService.clearCache(distinctId: transition.from)
        }
        await profileService.handleUserChange(from: transition.from, to: transition.to)

        switch transition.kind {
        case .identify:
            await featureService.handleUserChange(from: transition.from, to: transition.to)
        case .reset:
            await featureService.clearCache()
            await experienceService.clearCache()
        }
    }
}
