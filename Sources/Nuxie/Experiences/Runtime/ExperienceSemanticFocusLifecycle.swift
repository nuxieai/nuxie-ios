import Foundation

/// Focus is eligible only after the latest lifecycle write has been accepted.
/// Snapshot values can repeat after rollback, so ownership uses write identity.
struct ExperienceSemanticFocusLifecycle {
    private var latestWrite: UUID?
    private var committedWrite: UUID?
    private var latestPhase: ExperienceScreenLifecyclePhase = .hidden
    private(set) var canExposeCurrentScene = false

    var isReady: Bool { latestWrite != nil && latestWrite == committedWrite }

    mutating func beginWrite(phase: ExperienceScreenLifecyclePhase = .active) -> UUID {
        let id = UUID()
        latestWrite = id
        latestPhase = phase
        // A settings refresh of an active screen does not revoke its already
        // presented focus. A phase transition always withdraws that ownership.
        if phase != .active { canExposeCurrentScene = false }
        committedWrite = nil
        return id
    }

    @discardableResult
    mutating func completeWrite(_ id: UUID, succeeded: Bool) -> Bool {
        guard latestWrite == id else { return false }
        committedWrite = succeeded ? id : nil
        canExposeCurrentScene = succeeded && latestPhase == .active
        return succeeded
    }

    func admitsHandoff(from id: UUID) -> Bool {
        isReady && latestPhase == .active && committedWrite == id
    }
}
