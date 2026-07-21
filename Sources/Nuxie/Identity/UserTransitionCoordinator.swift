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
    // Note: journeyService stays lazily resolved in run(_:) to avoid the
    // JourneyService cycle until the final 4c slice.
    private let profileService: ProfileServiceProtocol
    private let segmentService: SegmentServiceProtocol
    private let eventLog: EventLogProtocol
    private let featureService: FeatureServiceProtocol
    private let flowService: ExperienceServiceProtocol
    /// Provider: JourneyService is registered after the coordinator in some
    /// test graphs; call-time resolution keeps that order working.
    private let journeysProvider: () -> JourneyServiceProtocol

    init(
        profile: ProfileServiceProtocol,
        segments: SegmentServiceProtocol,
        eventLog: EventLogProtocol,
        features: FeatureServiceProtocol,
        flows: ExperienceServiceProtocol,
        journeysProvider: @escaping () -> JourneyServiceProtocol
    ) {
        self.profileService = profile
        self.segmentService = segments
        self.eventLog = eventLog
        self.featureService = features
        self.flowService = flows
        self.journeysProvider = journeysProvider
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
        lock.lock()
        let current = tail
        lock.unlock()
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
        if transition.kind == .reset {
            await profileService.clearCache(distinctId: transition.from)
            await segmentService.clearSegments(for: transition.from)
        }
        await profileService.handleUserChange(from: transition.from, to: transition.to)
        await segmentService.handleUserChange(from: transition.from, to: transition.to)
        await journeysProvider().handleUserChange(from: transition.from, to: transition.to)

        switch transition.kind {
        case .identify:
            await featureService.handleUserChange(from: transition.from, to: transition.to)
        case .reset:
            await featureService.clearCache()
            await flowService.clearCache()
        }
    }
}
