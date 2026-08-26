import Foundation

/// Owns the journey resume timers: keyed, cancellable tasks whose delay is
/// computed at schedule time. Extracted from JourneyService (Phase 6).
///
/// The scheduler is deliberately dumb — keys and work closures in, timed
/// callbacks out. The service passes a Sendable closure that hops back onto
/// the service actor, so all journey mutation stays actor-isolated there.
/// @unchecked Sendable relies on `activeTasks` and `nextGeneration` being
/// accessed only under `lock`; the injected providers are Sendable.
final class JourneyTimerScheduler: @unchecked Sendable {
    private enum SchedulingContext {
        @TaskLocal static var epoch: UInt64?
    }

    private struct Registration {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var activeTasks: [String: Registration] = [:]
    private var nextGeneration: UInt64 = 0
    private var schedulerEpoch: UInt64 = 0
    private let dateProvider: DateProviderProtocol
    private let sleepProvider: SleepProviderProtocol

    var activeTaskCount: Int {
        lock.withLock { activeTasks.count }
    }

    init(dateProvider: DateProviderProtocol, sleepProvider: SleepProviderProtocol) {
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
    }

    static func taskKey(journeyId: String, kind: String, id: String? = nil) -> String {
        var key = "\(journeyId):\(kind)"
        if let id {
            key += ":\(id)"
        }
        return key
    }

    @discardableResult
    func schedule(
        key: String,
        at date: Date,
        work: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let delay = max(0, date.timeIntervalSince(dateProvider.now()))
        let sleepProvider = self.sleepProvider
        let task: Task<Void, Never>

        lock.lock()
        let registrationEpoch = SchedulingContext.epoch ?? schedulerEpoch
        guard registrationEpoch == schedulerEpoch else {
            lock.unlock()
            let rejectedTask = Task<Void, Never> {}
            rejectedTask.cancel()
            return rejectedTask
        }
        activeTasks[key]?.task.cancel()
        nextGeneration &+= 1
        let generation = nextGeneration
        task = Task { [weak self] in
            defer { self?.clear(key, generation: generation) }
            do {
                try await sleepProvider.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await SchedulingContext.$epoch.withValue(registrationEpoch) {
                    await work()
                }
            } catch {
                LogDebug("Journey task \(key) cancelled/failed: \(error)")
            }
        }
        activeTasks[key] = Registration(generation: generation, task: task)
        lock.unlock()
        return task
    }

    /// Cancels every scheduled task whose key belongs to `journeyId`.
    func cancelTasks(journeyId: String) {
        lock.lock()
        let keys = activeTasks.keys.filter { $0.hasPrefix("\(journeyId):") }
        var cancelled: [Task<Void, Never>] = []
        for key in keys {
            if let registration = activeTasks.removeValue(forKey: key) {
                cancelled.append(registration.task)
            }
        }
        lock.unlock()
        for task in cancelled {
            task.cancel()
        }
    }

    func cancelAll() async {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            schedulerEpoch &+= 1
            let tasks = activeTasks.values.map(\.task)
            activeTasks.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func clear(_ key: String, generation: UInt64) {
        lock.lock()
        if activeTasks[key]?.generation == generation {
            activeTasks.removeValue(forKey: key)
        }
        lock.unlock()
    }
}
