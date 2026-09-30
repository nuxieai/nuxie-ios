import Foundation

/// Tiny synchronous flags that pace background Experience preparation.
///
/// Main-queue lifecycle observers write these flags without awaiting, in
/// notification order: the background observer pauses and the activation
/// observer resumes. Neither waits behind a slow profile refetch, and a
/// resume can never land after a later pause. The prepared-release store
/// reads them before it starts the lane and before each item.
// @unchecked Sendable: every access to `state` holds `lock`.
final class ExperiencePreparationGate: @unchecked Sendable {
    struct State: Equatable, Sendable {
        /// The app is in the background, where iOS forbids GPU work. Work
        /// already running finishes; nothing new starts until active.
        var isBackgrounded: Bool
        /// The system warned about memory. Built screens wait until the app
        /// is active again or a new profile arrives, whichever is first.
        /// Prepared releases are kept.
        var builtScreensDeferred: Bool
        /// Increments on every mutation.
        var sequence: UInt64
    }

    private let lock = NSLock()
    private var state: State

    init(startsBackgrounded: Bool = false) {
        state = State(
            isBackgrounded: startsBackgrounded,
            builtScreensDeferred: false,
            sequence: 0
        )
    }

    func enterBackground() {
        mutate { $0.isBackgrounded = true }
    }

    func becomeActive() {
        mutate {
            $0.isBackgrounded = false
            $0.builtScreensDeferred = false
        }
    }

    func noteMemoryWarning() {
        mutate { $0.builtScreensDeferred = true }
    }

    func noteProfileCommitted() {
        mutate { $0.builtScreensDeferred = false }
    }

    func snapshot() -> State {
        lock.withLock { state }
    }

    private func mutate(_ change: (inout State) -> Void) {
        lock.withLock {
            change(&state)
            state.sequence &+= 1
        }
    }
}
