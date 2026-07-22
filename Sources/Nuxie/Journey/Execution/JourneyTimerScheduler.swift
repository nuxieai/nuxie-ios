import Foundation

/// Owns the journey resume timers: keyed, cancellable tasks whose delay is
/// computed at schedule time. Extracted from JourneyService (Phase 6).
///
/// The scheduler is deliberately dumb — keys and work closures in, timed
/// callbacks out. The service passes a Sendable closure that hops back onto
/// the service actor, so all journey mutation stays actor-isolated there.
final class JourneyTimerScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let dateProvider: DateProviderProtocol
    private let sleepProvider: SleepProviderProtocol

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

    func schedule(key: String, at date: Date, work: @escaping @Sendable () async -> Void) {
        let delay = max(0, date.timeIntervalSince(dateProvider.now()))
        let sleepProvider = self.sleepProvider

        lock.lock()
        activeTasks[key]?.cancel()
        let task = Task { [weak self] in
            do {
                try await sleepProvider.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await work()
            } catch {
                LogDebug("Journey task \(key) cancelled/failed: \(error)")
            }
            self?.clear(key)
        }
        activeTasks[key] = task
        lock.unlock()
    }

    /// Cancels every scheduled task whose key belongs to `journeyId`.
    func cancelTasks(journeyId: String) {
        lock.lock()
        let keys = activeTasks.keys.filter { $0.hasPrefix("\(journeyId):") }
        var cancelled: [Task<Void, Never>] = []
        for key in keys {
            if let task = activeTasks.removeValue(forKey: key) {
                cancelled.append(task)
            }
        }
        lock.unlock()
        for task in cancelled {
            task.cancel()
        }
    }

    func cancelAll() {
        lock.lock()
        let tasks = activeTasks
        activeTasks.removeAll()
        lock.unlock()
        for (_, task) in tasks {
            task.cancel()
        }
    }

    private func clear(_ key: String) {
        lock.lock()
        activeTasks.removeValue(forKey: key)
        lock.unlock()
    }
}
