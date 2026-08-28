import Foundation

/// Serializes construction and publication of a mutable SDK composition root.
///
/// Setup reserves the starting state synchronously, constructs the graph
/// outside the lock, and publishes the complete graph in one locked state
/// transition. Every mutable lifecycle field is accessed under `lock`.
final class SerializedSDKLifecycle<Graph: AnyObject & Sendable>: @unchecked Sendable {
    struct Snapshot: Sendable {
        let graph: Graph
    }

    final class Operation: @unchecked Sendable {
        let graph: Graph

        private let finishLock = NSLock()
        private var finishAction: (@Sendable () -> Void)?

        fileprivate init(graph: Graph, finishAction: @escaping @Sendable () -> Void) {
            self.graph = graph
            self.finishAction = finishAction
        }

        func finish() {
            let action = finishLock.withLock { () -> (@Sendable () -> Void)? in
                defer { finishAction = nil }
                return finishAction
            }
            action?()
        }

        deinit {
            finish()
        }
    }

    private final class RunningState: @unchecked Sendable {
        let graph: Graph
        var activeOperations = 0

        init(graph: Graph) {
            self.graph = graph
        }
    }

    private final class StartingState: @unchecked Sendable {
        var stopRequested = false
        var completionWaiters: [CheckedContinuation<Void, Never>] = []
        var installWaiters: [DispatchSemaphore] = []
    }

    private final class ShutdownState: @unchecked Sendable {
        let running: RunningState
        var ownerClaimed: Bool
        var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
        var completionWaiters: [CheckedContinuation<Void, Never>] = []

        init(running: RunningState, ownerClaimed: Bool) {
            self.running = running
            self.ownerClaimed = ownerClaimed
        }
    }

    private enum State {
        case idle
        case starting(StartingState)
        case running(RunningState)
        case stopping(ShutdownState)
    }

    private enum ShutdownAction {
        case none
        case own(ShutdownState)
        case wait(ShutdownState)
        case waitForStart(StartingState)
    }

    private let lock = NSLock()
    private var state: State = .idle

    /// Builds and atomically installs one graph when idle. Construction runs
    /// outside the lock while the explicit starting state rejects operations
    /// and competing installers.
    private enum InstallClaim {
        case owns
        case waitForActiveStart(DispatchSemaphore)
        case alreadyInstalled
    }

    @discardableResult
    func install(_ build: () throws -> Graph) rethrows -> Bool {
        let starting = StartingState()
        let claim = lock.withLock { () -> InstallClaim in
            switch state {
            case .idle:
                state = .starting(starting)
                return .owns
            case .starting(let active):
                // A losing concurrent setup must not report completion before
                // the winning graph is published (or abandoned); block this
                // synchronous caller until the active start resolves, exactly
                // like the previous locked construction did.
                let waiter = DispatchSemaphore(value: 0)
                active.installWaiters.append(waiter)
                return .waitForActiveStart(waiter)
            case .running, .stopping:
                return .alreadyInstalled
            }
        }
        switch claim {
        case .owns:
            break
        case .waitForActiveStart(let waiter):
            waiter.wait()
            return false
        case .alreadyInstalled:
            return false
        }

        do {
            let graph = try build()
            finishStarting(starting, with: graph)
            return true
        } catch {
            abandonStarting(starting)
            throw error
        }
    }

    /// Returns one immutable reference to the currently running graph.
    func snapshot() -> Snapshot? {
        lock.withLock {
            guard case .running(let running) = state else { return nil }
            return Snapshot(graph: running.graph)
        }
    }

    /// Admits one operation against the current graph. Admission closes before
    /// shutdown begins, and teardown waits for every admitted operation.
    func beginOperation() -> Operation? {
        lock.withLock {
            guard case .running(let running) = state else { return nil }
            running.activeOperations += 1
            return Operation(graph: running.graph) { [weak self, weak running] in
                guard let running else { return }
                self?.finishOperation(on: running)
            }
        }
    }

    var isRunning: Bool {
        lock.withLock {
            guard case .running = state else { return false }
            return true
        }
    }

    /// Removes the running graph from public use and tears it down exactly
    /// once. Concurrent callers join the in-progress teardown. A new graph
    /// cannot install until teardown has completed.
    func shutdown(
        beforeDraining: @escaping @Sendable (Graph) async -> Void = { _ in },
        afterWaitingForStart: @escaping @Sendable () async -> Void = {},
        _ tearDown: @escaping @Sendable (Graph) async -> Void
    ) async {
        let action = lock.withLock { () -> ShutdownAction in
            switch state {
            case .idle:
                return .none
            case .starting(let starting):
                starting.stopRequested = true
                return .waitForStart(starting)
            case .running(let running):
                let shutdown = ShutdownState(running: running, ownerClaimed: true)
                state = .stopping(shutdown)
                return .own(shutdown)
            case .stopping(let shutdown):
                if !shutdown.ownerClaimed {
                    shutdown.ownerClaimed = true
                    return .own(shutdown)
                }
                return .wait(shutdown)
            }
        }

        switch action {
        case .none:
            return
        case .own(let shutdown):
            await beforeDraining(shutdown.running.graph)
            await waitForOperations(of: shutdown)
            await tearDown(shutdown.running.graph)
            finish(shutdown)
        case .wait(let shutdown):
            await waitForCompletion(of: shutdown)
        case .waitForStart(let starting):
            await waitForStart(starting)
            await afterWaitingForStart()
            await shutdown(
                beforeDraining: beforeDraining,
                afterWaitingForStart: afterWaitingForStart,
                tearDown
            )
        }
    }

    private func finishStarting(_ starting: StartingState, with graph: Graph) {
        var installWaiters: [DispatchSemaphore] = []
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard case .starting(let active) = state, active === starting else {
                return []
            }
            let running = RunningState(graph: graph)
            if starting.stopRequested {
                // Close admission atomically with publication. The first
                // waiting shutdown caller claims teardown ownership.
                state = .stopping(ShutdownState(
                    running: running,
                    ownerClaimed: false
                ))
            } else {
                state = .running(running)
            }
            installWaiters = starting.installWaiters
            starting.installWaiters.removeAll()
            let waiters = starting.completionWaiters
            starting.completionWaiters.removeAll()
            return waiters
        }
        installWaiters.forEach { $0.signal() }
        waiters.forEach { $0.resume() }
    }

    private func abandonStarting(_ starting: StartingState) {
        var installWaiters: [DispatchSemaphore] = []
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard case .starting(let active) = state, active === starting else {
                return []
            }
            state = .idle
            installWaiters = starting.installWaiters
            starting.installWaiters.removeAll()
            let waiters = starting.completionWaiters
            starting.completionWaiters.removeAll()
            return waiters
        }
        installWaiters.forEach { $0.signal() }
        waiters.forEach { $0.resume() }
    }

    private func waitForStart(_ starting: StartingState) async {
        await withCheckedContinuation { continuation in
            let alreadyFinished = lock.withLock { () -> Bool in
                guard case .starting(let active) = state, active === starting else {
                    return true
                }
                starting.completionWaiters.append(continuation)
                return false
            }
            if alreadyFinished {
                continuation.resume()
            }
        }
    }

    private func finishOperation(on running: RunningState) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard running.activeOperations > 0 else { return [] }
            running.activeOperations -= 1
            guard running.activeOperations == 0,
                  case .stopping(let shutdown) = state,
                  shutdown.running === running else {
                return []
            }
            let waiters = shutdown.operationDrainWaiters
            shutdown.operationDrainWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    private func waitForOperations(of shutdown: ShutdownState) async {
        await withCheckedContinuation { continuation in
            let alreadyDrained = lock.withLock { () -> Bool in
                guard case .stopping(let active) = state, active === shutdown,
                      shutdown.running.activeOperations > 0 else {
                    return true
                }
                shutdown.operationDrainWaiters.append(continuation)
                return false
            }
            if alreadyDrained {
                continuation.resume()
            }
        }
    }

    private func finish(_ shutdown: ShutdownState) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard case .stopping(let active) = state, active === shutdown else {
                return []
            }
            state = .idle
            let waiters = shutdown.completionWaiters
            shutdown.completionWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    private func waitForCompletion(of shutdown: ShutdownState) async {
        await withCheckedContinuation { continuation in
            let alreadyFinished = lock.withLock { () -> Bool in
                guard case .stopping(let active) = state, active === shutdown else {
                    return true
                }
                shutdown.completionWaiters.append(continuation)
                return false
            }
            if alreadyFinished {
                continuation.resume()
            }
        }
    }
}

/// One fully assembled SDK service graph and the work started with it.
/// Keeping these values together lets every facade operation retain exactly
/// one generation across suspension and lets shutdown drain that work before
/// tearing down the same generation.
/// @unchecked Sendable relies on immutable graph and task references plus the
/// separately locked mutable state in `FacadeTaskRegistry`.
final class NuxieSDKRun: @unchecked Sendable {
    let configuration: NuxieSetupConfiguration
    let core: NuxieCore
    let lifecycleCoordinator: NuxieLifecycleCoordinator
    let eventSystemSetupTask: Task<Void, Never>
    let journeyInitializeTask: Task<Void, Never>
    let featureInfoDelegateTask: Task<Void, Never>?
    let profilePrefetchTask: Task<Void, Never>?
    let transactionObserverTask: Task<Void, Never>?
    let featureCommandRecoveryTask: Task<Void, Never>?
    private let facadeTasks: FacadeTaskRegistry

    init(
        configuration: NuxieSetupConfiguration,
        core: NuxieCore,
        lifecycleCoordinator: NuxieLifecycleCoordinator,
        eventSystemSetupTask: Task<Void, Never>,
        journeyInitializeTask: Task<Void, Never>,
        featureInfoDelegateTask: Task<Void, Never>?,
        profilePrefetchTask: Task<Void, Never>?,
        transactionObserverTask: Task<Void, Never>?,
        featureCommandRecoveryTask: Task<Void, Never>?,
        facadeTaskStartBarrier: (@Sendable () async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.core = core
        self.lifecycleCoordinator = lifecycleCoordinator
        self.eventSystemSetupTask = eventSystemSetupTask
        self.journeyInitializeTask = journeyInitializeTask
        self.featureInfoDelegateTask = featureInfoDelegateTask
        self.profilePrefetchTask = profilePrefetchTask
        self.transactionObserverTask = transactionObserverTask
        self.featureCommandRecoveryTask = featureCommandRecoveryTask
        self.facadeTasks = FacadeTaskRegistry(startBarrier: facadeTaskStartBarrier)
    }

    /// Startup work that can settle before admitted facade operations drain.
    /// Feature command recovery joins only after the queue closes post-drain.
    var preDrainStartupTasks: [Task<Void, Never>] {
        [
            eventSystemSetupTask,
            journeyInitializeTask,
            featureInfoDelegateTask,
            profilePrefetchTask,
            transactionObserverTask,
        ].compactMap { $0 }
    }

    @discardableResult
    func launchFacadeTask(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        facadeTasks.launch(operation)
    }

    func stopAcceptingFacadeTasksAndCancel() -> [Task<Void, Never>] {
        facadeTasks.stopAcceptingAndCancel()
    }
}

/// Owns unstructured work launched by synchronous facade methods. Shutdown
/// closes admission and obtains a stable task snapshot before service teardown.
/// @unchecked Sendable relies on all mutable registry state being under `lock`.
private final class FacadeTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let startBarrier: (@Sendable () async -> Void)?
    private var isAccepting = true
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(startBarrier: (@Sendable () async -> Void)? = nil) {
        self.startBarrier = startBarrier
    }

    @discardableResult
    func launch(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        lock.withLock {
            guard isAccepting else { return false }
            let id = UUID()
            let task = Task { [weak self] in
                defer { self?.removeTask(id: id) }
                await self?.startBarrier?()
                // An admitted closure must run even if shutdown canceled its
                // task before execution: it may own a continuation or lease
                // that shutdown is itself waiting to settle.
                await operation()
            }
            tasks[id] = task
            return true
        }
    }

    func stopAcceptingAndCancel() -> [Task<Void, Never>] {
        let snapshot = lock.withLock { () -> [Task<Void, Never>] in
            isAccepting = false
            return Array(tasks.values)
        }
        snapshot.forEach { $0.cancel() }
        return snapshot
    }

    private func removeTask(id: UUID) {
        lock.withLock {
            _ = tasks.removeValue(forKey: id)
        }
    }
}
