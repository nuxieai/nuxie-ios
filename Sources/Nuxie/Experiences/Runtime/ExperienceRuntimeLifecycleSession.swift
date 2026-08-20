import Foundation

/// Main-actor owner for one interactive presentation's lifecycle bookkeeping.
/// Platform controllers execute the returned work, but cannot invent lifecycle
/// states or mutate work from a stale mount generation.
@MainActor
final class ExperienceRuntimeLifecycleSession<Command, Navigation> {
    enum State: Equatable, Sendable {
        case inactive(generation: UInt64)
        case loading(generation: UInt64)
        case mounting(generation: UInt64)
        case ready(generation: UInt64)
        case terminalFailure(generation: UInt64)
        case tearingDown(generation: UInt64)

        var generation: UInt64 {
            switch self {
            case .inactive(let generation), .loading(let generation),
                 .mounting(let generation), .ready(let generation),
                 .terminalFailure(let generation), .tearingDown(let generation):
                generation
            }
        }
    }

    struct TeardownWork {
        let generation: UInt64
        let mountTask: Task<Void, Never>?
        let failureTask: Task<Void, Never>?
    }

    struct InterruptedWork {
        let mountTask: Task<Void, Never>?
        let failureTask: Task<Void, Never>?
    }

    private(set) var state: State = .inactive(generation: 0)
    private(set) var pendingCommands: [Command] = []
    private(set) var activeNavigation: Navigation?
    private(set) var isDrainingCommands = false
    private(set) var hasCrossedInitialActivationBoundary = false
    private(set) var readyNotificationGeneration: UInt64?
    private(set) var mountTask: Task<Void, Never>?
    private(set) var failureTask: Task<Void, Never>?

    var generation: UInt64 { state.generation }

    func beginLoading(requeue command: Command? = nil) -> InterruptedWork {
        if let command { pendingCommands.insert(command, at: 0) }
        let work = InterruptedWork(mountTask: mountTask, failureTask: failureTask)
        mountTask?.cancel()
        mountTask = nil
        failureTask?.cancel()
        failureTask = nil
        activeNavigation = nil
        isDrainingCommands = false
        hasCrossedInitialActivationBoundary = false
        readyNotificationGeneration = nil
        state = .loading(generation: generation &+ 1)
        return work
    }

    func invalidateLoading() -> (generation: UInt64, work: InterruptedWork) {
        let nextGeneration = generation &+ 1
        let work = InterruptedWork(mountTask: mountTask, failureTask: failureTask)
        mountTask?.cancel()
        mountTask = nil
        failureTask?.cancel()
        failureTask = nil
        activeNavigation = nil
        isDrainingCommands = false
        hasCrossedInitialActivationBoundary = false
        readyNotificationGeneration = nil
        state = .inactive(generation: nextGeneration)
        return (nextGeneration, work)
    }

    func beginMount() -> (generation: UInt64, previousTask: Task<Void, Never>?)? {
        guard case .loading(let generation) = state else { return nil }
        let previousTask = mountTask
        state = .mounting(generation: generation)
        return (generation, previousTask)
    }

    func ownMountTask(_ task: Task<Void, Never>, generation: UInt64) {
        guard isCurrent(generation) else {
            task.cancel()
            return
        }
        switch state {
        case .inactive, .loading, .mounting:
            break
        case .ready, .terminalFailure, .tearingDown:
            task.cancel()
            return
        }
        mountTask = task
    }

    func clearMountTask(generation: UInt64) {
        guard isCurrent(generation) else { return }
        mountTask = nil
    }

    @discardableResult
    func becomeReady(generation: UInt64) -> Bool {
        guard isCurrent(generation), case .mounting = state else { return false }
        state = .ready(generation: generation)
        hasCrossedInitialActivationBoundary = false
        readyNotificationGeneration = generation
        return true
    }

    @discardableResult
    func crossInitialActivationBoundary(generation: UInt64) -> Bool {
        guard isReady(generation) else { return false }
        hasCrossedInitialActivationBoundary = true
        return true
    }

    @discardableResult
    func latchTerminalFailure(generation: UInt64) -> Bool {
        guard isCurrent(generation) else { return false }
        switch state {
        case .loading, .mounting, .ready:
            state = .terminalFailure(generation: generation)
            activeNavigation = nil
            isDrainingCommands = false
            hasCrossedInitialActivationBoundary = false
            readyNotificationGeneration = nil
            return true
        case .inactive, .terminalFailure, .tearingDown:
            return false
        }
    }

    func ownFailureTask(_ task: Task<Void, Never>, generation: UInt64) {
        guard isCurrent(generation), case .terminalFailure = state else {
            task.cancel()
            return
        }
        failureTask = task
    }

    func beginTeardown() -> TeardownWork {
        if case .tearingDown(let generation) = state {
            return TeardownWork(generation: generation, mountTask: nil, failureTask: nil)
        }
        if case .inactive(let generation) = state,
           mountTask == nil,
           failureTask == nil,
           pendingCommands.isEmpty,
           activeNavigation == nil {
            return TeardownWork(generation: generation, mountTask: nil, failureTask: nil)
        }
        let nextGeneration = generation &+ 1
        state = .tearingDown(generation: nextGeneration)
        let work = TeardownWork(
            generation: nextGeneration,
            mountTask: mountTask,
            failureTask: failureTask
        )
        mountTask?.cancel()
        failureTask?.cancel()
        mountTask = nil
        failureTask = nil
        pendingCommands.removeAll()
        activeNavigation = nil
        isDrainingCommands = false
        hasCrossedInitialActivationBoundary = false
        readyNotificationGeneration = nil
        return work
    }

    func finishTeardown(generation: UInt64) {
        guard case .tearingDown(let activeGeneration) = state,
              activeGeneration == generation else { return }
        state = .inactive(generation: generation)
    }

    func enqueue(_ command: Command) {
        pendingCommands.append(command)
    }

    func beginCommandDrain(generation: UInt64) -> Bool {
        guard isReady(generation),
              hasCrossedInitialActivationBoundary,
              !isDrainingCommands,
              activeNavigation == nil else {
            return false
        }
        isDrainingCommands = true
        return true
    }

    func nextCommand(generation: UInt64) -> Command? {
        guard isReady(generation),
              hasCrossedInitialActivationBoundary,
              !pendingCommands.isEmpty else { return nil }
        return pendingCommands.removeFirst()
    }

    func endCommandDrain() {
        isDrainingCommands = false
    }

    func beginNavigation(_ navigation: Navigation, generation: UInt64) -> Bool {
        guard isReady(generation),
              hasCrossedInitialActivationBoundary,
              activeNavigation == nil else { return false }
        activeNavigation = navigation
        return true
    }

    func clearNavigation(where matches: (Navigation) -> Bool) -> Bool {
        guard let activeNavigation, matches(activeNavigation) else { return false }
        self.activeNavigation = nil
        return true
    }

    func consumeReadyNotification(generation: UInt64) -> Bool {
        guard readyNotificationGeneration == generation,
              isReady(generation),
              hasCrossedInitialActivationBoundary,
              activeNavigation == nil,
              pendingCommands.isEmpty,
              !isDrainingCommands else {
            return false
        }
        readyNotificationGeneration = nil
        return true
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        self.generation == generation
    }

    func isReady(_ generation: UInt64) -> Bool {
        guard case .ready(let currentGeneration) = state else { return false }
        return currentGeneration == generation
    }

    func isMounting(_ generation: UInt64) -> Bool {
        guard case .mounting(let currentGeneration) = state else { return false }
        return currentGeneration == generation
    }

    func acceptsCallbacks() -> Bool {
        if case .ready = state { return true }
        if case .mounting = state { return true }
        return false
    }
}
