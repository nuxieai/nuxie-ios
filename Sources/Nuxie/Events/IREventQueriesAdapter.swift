import Foundation

/// Adapter that bridges EventLogProtocol to IREventQueries
public struct IREventQueriesAdapter: IREventQueries {
    private let eventLog: EventLogProtocol
    private let distinctId: String?
    private let additionalEvents: [StoredEvent]
    
    public init(
        eventLog: EventLogProtocol,
        distinctId: String? = nil,
        additionalEvents: [StoredEvent] = []
    ) {
        self.eventLog = eventLog
        self.distinctId = distinctId
        self.additionalEvents = additionalEvents
    }

    private func shouldUseMergedEvents() -> Bool {
        distinctId != nil || !additionalEvents.isEmpty
    }

    private func mergedEvents(limit: Int) async -> [StoredEvent] {
        let persistedEvents: [StoredEvent]
        if let distinctId {
            persistedEvents = await eventLog.getEventsForUser(distinctId, limit: limit)
        } else {
            persistedEvents = []
        }

        guard !additionalEvents.isEmpty else { return persistedEvents }

        let scopedAdditionalEvents = if let distinctId {
            additionalEvents.filter { $0.distinctId == distinctId }
        } else {
            additionalEvents
        }

        guard !scopedAdditionalEvents.isEmpty else { return persistedEvents }

        var seen = Set<String>()
        var merged: [StoredEvent] = []
        for event in persistedEvents + scopedAdditionalEvents {
            if seen.insert(event.id).inserted {
                merged.append(event)
            }
        }
        return merged
    }

    private func filteredEvents(
        name: String,
        since: Date?,
        until: Date?,
        predicate: IRPredicate?,
        limit: Int
    ) async -> [StoredEvent] {
        let events = await mergedEvents(limit: limit)
        return events
            .filter { $0.name == name }
            .filter { event in
                if let since, event.timestamp < since { return false }
                if let until, event.timestamp > until { return false }
                return true
            }
            .filter { event in
                guard let predicate else { return true }
                return PredicateEval.eval(predicate, props: event.getPropertiesDict())
            }
    }
    
    public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
        if shouldUseMergedEvents() {
            return !(await filteredEvents(
                name: name,
                since: since,
                until: until,
                predicate: predicate,
                limit: 5000
            )).isEmpty
        }
        return await eventLog.exists(name: name, since: since, until: until, where: predicate)
    }
    
    public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
        if shouldUseMergedEvents() {
            return await filteredEvents(
                name: name,
                since: since,
                until: until,
                predicate: predicate,
                limit: 5000
            ).count
        }
        return await eventLog.count(name: name, since: since, until: until, where: predicate)
    }
    
    public func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
        if shouldUseMergedEvents() {
            return await filteredEvents(
                name: name,
                since: nil,
                until: nil,
                predicate: predicate,
                limit: 5000
            )
            .sorted(by: { $0.timestamp < $1.timestamp })
            .first?.timestamp
        }
        return await eventLog.firstTime(name: name, where: predicate)
    }
    
    public func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
        if shouldUseMergedEvents() {
            return await filteredEvents(
                name: name,
                since: nil,
                until: nil,
                predicate: predicate,
                limit: 5000
            )
            .sorted(by: { $0.timestamp > $1.timestamp })
            .first?.timestamp
        }
        return await eventLog.lastTime(name: name, where: predicate)
    }
    
    public func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
        if shouldUseMergedEvents() {
            let values = await filteredEvents(
                name: name,
                since: since,
                until: until,
                predicate: predicate,
                limit: 5000
            )
            .compactMap { event in
                Coercion.asNumber(event.getPropertiesDict()[prop])
            }

            guard !values.isEmpty else { return nil }
            switch agg {
            case .sum:
                return values.reduce(0, +)
            case .avg:
                return values.reduce(0, +) / Double(values.count)
            case .min:
                return values.min()
            case .max:
                return values.max()
            case .unique:
                return Double(Set(values).count)
            }
        }
        return await eventLog.aggregate(agg, name: name, prop: prop, since: since, until: until, where: predicate)
    }
    
    public func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool {
        return await eventLog.inOrder(steps: steps, overallWithin: overallWithin, perStepWithin: perStepWithin, since: since, until: until)
    }
    
    public func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool {
        return await eventLog.activePeriods(name: name, period: period, total: total, min: min, where: predicate)
    }
    
    public func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return await eventLog.stopped(name: name, inactiveFor: inactiveFor, where: predicate)
    }
    
    public func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return await eventLog.restarted(name: name, inactiveFor: inactiveFor, within: within, where: predicate)
    }
}
