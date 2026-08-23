import Foundation

/// Serializes construction and publication of a mutable SDK composition root.
///
/// Setup is intentionally synchronous, so graph construction happens while
/// this module owns its lock. Callers either observe the previous complete
/// graph or the newly installed complete graph; no partial setup state is
/// published.
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

    private final class ShutdownState: @unchecked Sendable {
        let running: RunningState
        var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
        var completionWaiters: [CheckedContinuation<Void, Never>] = []

        init(running: RunningState) {
            self.running = running
        }
    }

    private enum State {
        case idle
        case running(RunningState)
        case shuttingDown(ShutdownState)
    }

    private enum ShutdownAction {
        case none
        case own(ShutdownState)
        case wait(ShutdownState)
    }

    private let lock = NSLock()
    private var state: State = .idle

    /// Builds and atomically installs one graph when idle.
    ///
    /// Returns false without evaluating `build` when another graph is already
    /// installed. The lock covers construction so concurrent installers cannot
    /// create duplicate graphs before either one publishes its result.
    @discardableResult
    func install(_ build: () throws -> Graph) rethrows -> Bool {
        try lock.withLock {
            guard case .idle = state else { return false }
            state = .running(RunningState(graph: try build()))
            return true
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
        _ tearDown: @escaping @Sendable (Graph) async -> Void
    ) async {
        let action = lock.withLock { () -> ShutdownAction in
            switch state {
            case .idle:
                return .none
            case .running(let running):
                let shutdown = ShutdownState(running: running)
                state = .shuttingDown(shutdown)
                return .own(shutdown)
            case .shuttingDown(let shutdown):
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
        }
    }

    private func finishOperation(on running: RunningState) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard running.activeOperations > 0 else { return [] }
            running.activeOperations -= 1
            guard running.activeOperations == 0,
                  case .shuttingDown(let shutdown) = state,
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
                guard case .shuttingDown(let active) = state, active === shutdown,
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
            guard case .shuttingDown(let active) = state, active === shutdown else {
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
                guard case .shuttingDown(let active) = state, active === shutdown else {
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
final class NuxieSDKRun: @unchecked Sendable {
    let configuration: NuxieConfiguration
    let core: NuxieCore
    let lifecycleCoordinator: NuxieLifecycleCoordinator
    let eventSystemSetupTask: Task<Void, Never>
    let journeyInitializeTask: Task<Void, Never>
    let featureInfoDelegateTask: Task<Void, Never>?
    let profilePrefetchTask: Task<Void, Never>?
    let transactionObserverTask: Task<Void, Never>?
    private let facadeTasks: FacadeTaskRegistry

    init(
        configuration: NuxieConfiguration,
        core: NuxieCore,
        lifecycleCoordinator: NuxieLifecycleCoordinator,
        eventSystemSetupTask: Task<Void, Never>,
        journeyInitializeTask: Task<Void, Never>,
        featureInfoDelegateTask: Task<Void, Never>?,
        profilePrefetchTask: Task<Void, Never>?,
        transactionObserverTask: Task<Void, Never>?,
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
        self.facadeTasks = FacadeTaskRegistry(startBarrier: facadeTaskStartBarrier)
    }

    var startupTasks: [Task<Void, Never>] {
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
