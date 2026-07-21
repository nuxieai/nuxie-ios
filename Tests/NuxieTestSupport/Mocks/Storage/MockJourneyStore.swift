import Foundation
@testable import Nuxie

/// Mock implementation of JourneyStore for testing
// @unchecked Sendable: all mutable state is serialized through `lock`.
// Non-final because integration tests subclass it to observe call ordering.
public class MockJourneyStore: JourneyStoreProtocol, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var activeJourneys: [String: Journey] = [:]
    private var completionRecords: [String: [JourneyCompletionRecord]] = [:]

    private var _shouldThrowOnSave = false
    private var _shouldThrowOnRecord = false

    public var shouldThrowOnSave: Bool {
        get { withLock { _shouldThrowOnSave } }
        set { withLock { _shouldThrowOnSave = newValue } }
    }
    public var shouldThrowOnRecord: Bool {
        get { withLock { _shouldThrowOnRecord } }
        set { withLock { _shouldThrowOnRecord = newValue } }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    
    public func saveJourney(_ journey: Journey) throws {
        try withLock {
            if _shouldThrowOnSave {
                throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock save error"])
            }
            activeJourneys[journey.id] = journey
        }
    }
    
    public func loadActiveJourneys() -> [Journey] {
        return withLock { Array(activeJourneys.values) }
    }
    
    public func loadJourney(id: String) -> Journey? {
        return withLock { activeJourneys[id] }
    }
    
    public func deleteJourney(id: String) {
        withLock { _ = activeJourneys.removeValue(forKey: id) }
    }
    
    public func recordCompletion(_ record: JourneyCompletionRecord) throws {
        try withLock {
            if _shouldThrowOnRecord {
                throw NSError(domain: "TestError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mock record error"])
            }
            let key = "\(record.distinctId):\(record.campaignId)"
            completionRecords[key, default: []].append(record)
        }
    }
    
    public func hasCompletedCampaign(distinctId: String, campaignId: String) -> Bool {
        let key = "\(distinctId):\(campaignId)"
        return withLock { completionRecords[key]?.isEmpty == false }
    }
    
    public func lastCompletionTime(distinctId: String, campaignId: String) -> Date? {
        let key = "\(distinctId):\(campaignId)"
        return withLock { completionRecords[key]?.last?.completedAt }
    }
    
    public func cleanup(olderThan date: Date) {
        withLock {
            // Remove old journeys
            activeJourneys = activeJourneys.filter { $0.value.startedAt >= date }

            // Remove old completion records
            for key in completionRecords.keys {
                completionRecords[key] = completionRecords[key]?.filter { $0.completedAt >= date }
            }
        }
    }
    
    public func getActiveJourneyIds(distinctId: String, campaignId: String) -> Set<String> {
        return withLock {
            let matching = activeJourneys.values.filter {
                $0.distinctId == distinctId && $0.campaignId == campaignId && $0.status.isActive
            }
            return Set(matching.map { $0.id })
        }
    }
    
    public func updateCache(for journey: Journey) {
        // No-op for mock
    }
    
    public func clearCache() {
        // No-op for mock
    }
    
    // Test helpers
    public func reset() {
        withLock {
            activeJourneys.removeAll()
            completionRecords.removeAll()
            _shouldThrowOnSave = false
            _shouldThrowOnRecord = false
        }
    }
    
    public func getCompletions(for distinctId: String) -> [JourneyCompletionRecord] {
        return withLock { completionRecords.values.flatMap { $0 }.filter { $0.distinctId == distinctId } }
    }
    
    // Public access for test convenience (from legacy mock)
    public var mockActiveJourneys: [Journey] {
        get { withLock { Array(activeJourneys.values) } }
        set {
            withLock {
                activeJourneys.removeAll()
                for journey in newValue {
                    activeJourneys[journey.id] = journey
                }
            }
        }
    }
    
    public var mockCompletionRecords: [JourneyCompletionRecord] {
        get { withLock { completionRecords.values.flatMap { $0 } } }
        set {
            withLock {
                completionRecords.removeAll()
                for record in newValue {
                    let key = "\(record.distinctId):\(record.campaignId)"
                    completionRecords[key, default: []].append(record)
                }
            }
        }
    }
}
