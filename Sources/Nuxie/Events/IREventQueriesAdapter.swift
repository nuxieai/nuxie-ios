import Foundation

/// Adapter that bridges EventLogProtocol to IREventQueries
struct IREventQueriesAdapter: IREventQueries {
    private static let queryLimit = 10_000
    private let eventLog: EventQuerySource
    private let distinctId: String?
    private let additionalEvents: [StoredEvent]
    private let now: @Sendable () -> Date
    
    public init(
        eventLog: EventQuerySource,
        distinctId: String? = nil,
        additionalEvents: [StoredEvent] = []
    ) {
        self.eventLog = eventLog
        self.distinctId = distinctId
        self.additionalEvents = additionalEvents
        self.now = { Date() }
    }

    init(
        eventLog: EventQuerySource,
        distinctId: String?,
        additionalEvents: [StoredEvent],
        now: @escaping @Sendable () -> Date
    ) {
        self.eventLog = eventLog
        self.distinctId = distinctId
        self.additionalEvents = additionalEvents
        self.now = now
    }

    private func shouldUseMergedEvents() -> Bool {
        distinctId != nil || !additionalEvents.isEmpty
    }

    func historyCoverage() async throws -> EventHistoryCoverage {
        try await eventLog.historyCoverage()
    }

    private func mergedEvents(
        names: Set<String>,
        since: Date?,
        until: Date?
    ) async throws -> [StoredEvent] {
        var persistedEvents: [StoredEvent] = []
        if let distinctId {
            for name in names.sorted() {
                let events = try await eventLog.queryEventsForIR(
                    distinctId,
                    name: name,
                    since: since,
                    until: until,
                    ascending: true,
                    limit: Self.queryLimit + 1
                )
                guard events.count <= Self.queryLimit else {
                    throw EventHistoryQueryError.truncated(limit: Self.queryLimit)
                }
                persistedEvents += events
            }
        }

        let scopedAdditionalEvents = additionalEvents
            .filter { distinctId == nil || $0.distinctId == distinctId }
            .filter { names.contains($0.name) }
            .filter { event in
                if let since, event.timestamp < since { return false }
                if let until, event.timestamp > until { return false }
                return true
            }

        // Persisted rows win when a formerly transient fact crosses the
        // persistence boundary. Its stable id keeps the merged view singular.
        var seen = Set<String>()
        let mergedEvents = (persistedEvents + scopedAdditionalEvents).filter {
            seen.insert($0.id).inserted
        }
        var countsByName: [String: Int] = [:]
        for event in mergedEvents {
            let count = (countsByName[event.name] ?? 0) + 1
            guard count <= Self.queryLimit else {
                throw EventHistoryQueryError.truncated(limit: Self.queryLimit)
            }
            countsByName[event.name] = count
        }
        return chronological(mergedEvents)
    }

    private func chronological(_ events: [StoredEvent]) -> [StoredEvent] {
        events.sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp < $1.timestamp
        }
    }

    private func filteredEvents(
        name: String,
        since: Date?,
        until: Date?,
        predicate: IRPredicate?
    ) async throws -> [StoredEvent] {
        let events = try await mergedEvents(names: [name], since: since, until: until)
        return try events.filter { event in
            guard let predicate else { return true }
            return PredicateEval.eval(
                predicate,
                props: try event.getPropertiesDictForIR()
            )
        }
    }
    
    public func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async throws -> Bool {
        if shouldUseMergedEvents() {
            return !(try await filteredEvents(
                name: name,
                since: since,
                until: until,
                predicate: predicate
            )).isEmpty
        }
        return try await eventLog.exists(name: name, since: since, until: until, where: predicate)
    }
    
    public func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async throws -> Int {
        if shouldUseMergedEvents() {
            return try await filteredEvents(
                name: name,
                since: since,
                until: until,
                predicate: predicate
            ).count
        }
        return try await eventLog.count(name: name, since: since, until: until, where: predicate)
    }
    
    public func firstTime(name: String, where predicate: IRPredicate?) async throws -> Date? {
        if shouldUseMergedEvents() {
            return chronological(try await filteredEvents(
                name: name,
                since: nil,
                until: nil,
                predicate: predicate
            )).first?.timestamp
        }
        return try await eventLog.firstTime(name: name, where: predicate)
    }
    
    public func lastTime(name: String, where predicate: IRPredicate?) async throws -> Date? {
        if shouldUseMergedEvents() {
            return chronological(try await filteredEvents(
                name: name,
                since: nil,
                until: nil,
                predicate: predicate
            )).last?.timestamp
        }
        return try await eventLog.lastTime(name: name, where: predicate)
    }
    
    public func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async throws -> Double? {
        if shouldUseMergedEvents() {
            let values = try await filteredEvents(
                name: name,
                since: since,
                until: until,
                predicate: predicate
            )
            .compactMap { event in
                Coercion.asNumber(try event.getPropertiesDictForIR()[prop])
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
        return try await eventLog.aggregate(agg, name: name, prop: prop, since: since, until: until, where: predicate)
    }
    
    public func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async throws -> Bool {
        if shouldUseMergedEvents() {
            let stepNames = Set(steps.map(\.name))
            let events = try await mergedEvents(names: stepNames, since: since, until: until)
            return try IREventSequenceMatcher.matches(
                events: events,
                steps: steps,
                overallWithin: overallWithin,
                perStepWithin: perStepWithin
            )
        }
        return try await eventLog.inOrder(steps: steps, overallWithin: overallWithin, perStepWithin: perStepWithin, since: since, until: until)
    }
    
    public func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async throws -> Bool {
        if shouldUseMergedEvents() {
            guard total > 0, min > 0, min <= total else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let now = self.now()
            guard let windowStart = period.activePeriodsWindowStart(
                total: total,
                now: now
            ) else { return false }
            let events = try await filteredEvents(
                name: name,
                since: windowStart,
                until: now,
                predicate: predicate
            )
            let buckets = Set(events.map { event -> DateComponents in
                switch period {
                case .day:
                    return calendar.dateComponents([.year, .month, .day], from: event.timestamp)
                case .week:
                    return calendar.dateComponents(
                        [.yearForWeekOfYear, .weekOfYear], from: event.timestamp)
                case .month:
                    return calendar.dateComponents([.year, .month], from: event.timestamp)
                case .year:
                    return calendar.dateComponents([.year], from: event.timestamp)
                }
            })
            return buckets.count >= min
        }
        return try await eventLog.activePeriods(name: name, period: period, total: total, min: min, where: predicate)
    }
    
    public func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async throws -> Bool {
        if shouldUseMergedEvents() {
            guard let last = chronological(try await filteredEvents(
                name: name,
                since: nil,
                until: nil,
                predicate: predicate
            )).last else {
                return false
            }
            return self.now().timeIntervalSince(last.timestamp) >= inactiveFor
        }
        return try await eventLog.stopped(name: name, inactiveFor: inactiveFor, where: predicate)
    }
    
    public func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async throws -> Bool {
        if shouldUseMergedEvents() {
            let now = self.now()
            let events = chronological(try await filteredEvents(
                name: name,
                since: nil,
                until: now,
                predicate: predicate
            ))
            guard events.count >= 2 else { return false }

            for index in 1..<events.count {
                let previous = events[index - 1]
                let restart = events[index]
                if restart.timestamp.timeIntervalSince(previous.timestamp) >= inactiveFor,
                   now.timeIntervalSince(restart.timestamp) <= within {
                    return true
                }
            }
            return false
        }
        return try await eventLog.restarted(name: name, inactiveFor: inactiveFor, within: within, where: predicate)
    }
}

enum IREventSequenceMatcher {
    static func matches(
        events: [StoredEvent],
        steps: [StepQuery],
        overallWithin: TimeInterval?,
        perStepWithin: TimeInterval?
    ) throws -> Bool {
        guard !steps.isEmpty else { return true }

        func matches(_ event: StoredEvent, step: StepQuery) throws -> Bool {
            guard event.name == step.name else { return false }
            guard let predicate = step.predicate else { return true }
            return PredicateEval.eval(
                predicate,
                props: try event.getPropertiesDictForIR()
            )
        }

        // Try every viable first fact. For a fixed start, choosing the
        // earliest next fact is optimal because both windows are upper
        // bounds; a later match can only leave less room for later steps.
        for startIndex in events.indices
        where try matches(events[startIndex], step: steps[0]) {
            let firstTime = events[startIndex].timestamp
            var previousTime = firstTime
            var nextIndex = events.index(after: startIndex)
            var completed = true

            for step in steps.dropFirst() {
                var matchIndex: Int?
                while nextIndex < events.endIndex {
                    let event = events[nextIndex]
                    if let perStepWithin,
                       event.timestamp.timeIntervalSince(previousTime) > perStepWithin {
                        break
                    }
                    if let overallWithin,
                       event.timestamp.timeIntervalSince(firstTime) > overallWithin {
                        break
                    }
                    if try matches(event, step: step) {
                        matchIndex = nextIndex
                        break
                    }
                    nextIndex = events.index(after: nextIndex)
                }

                guard let matchIndex else {
                    completed = false
                    break
                }
                previousTime = events[matchIndex].timestamp
                nextIndex = events.index(after: matchIndex)
            }

            if completed { return true }
        }
        return false
    }
}
