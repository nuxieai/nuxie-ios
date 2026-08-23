import Foundation
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class IREventQueriesAdapterTests: AsyncSpec {
    override class func spec() {
        describe("IREventQueriesAdapter merged event semantics") {
            let userId = "query-user"
            let now = Date(timeIntervalSince1970: 1_786_550_400)

            func stored(
                id: String,
                name: String,
                secondsBeforeNow: TimeInterval,
                properties: [String: Any] = [:]
            ) throws -> StoredEvent {
                try StoredEvent(
                    id: id,
                    name: name,
                    properties: properties,
                    timestamp: now.addingTimeInterval(-secondsBeforeNow),
                    distinctId: userId
                )
            }

            func persist(_ event: StoredEvent, in log: MockEventLog) async {
                _ = await log.route(NuxieEvent(
                    id: event.id,
                    name: event.name,
                    distinctId: event.distinctId,
                    properties: event.getPropertiesDict(),
                    timestamp: event.timestamp
                ))
            }

            it("uses one deduplicated persisted-and-transient history for every operator") {
                let log = MockEventLog()
                let duplicate = try stored(
                    id: "activity-older",
                    name: "activity",
                    secondsBeforeNow: 3 * 86_400,
                    properties: ["value": 2]
                )
                let firstStep = try stored(
                    id: "step-a",
                    name: "step_a",
                    secondsBeforeNow: 200
                )
                let stoppedPreviously = try stored(
                    id: "habit-old",
                    name: "habit",
                    secondsBeforeNow: 1_000
                )
                let restartPreviously = try stored(
                    id: "restart-old",
                    name: "restart",
                    secondsBeforeNow: 1_000
                )
                for event in [duplicate, firstStep, stoppedPreviously, restartPreviously] {
                    await persist(event, in: log)
                }

                let transient = [
                    duplicate,
                    try stored(
                        id: "activity-newer",
                        name: "activity",
                        secondsBeforeNow: 86_400,
                        properties: ["value": 3]
                    ),
                    try stored(id: "step-b", name: "step_b", secondsBeforeNow: 100),
                    try stored(id: "habit-new", name: "habit", secondsBeforeNow: 10),
                    try stored(id: "restart-new", name: "restart", secondsBeforeNow: 10),
                    try stored(id: "transient-only", name: "local_only", secondsBeforeNow: 5),
                ]
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: transient,
                    now: { now }
                )

                let exists = try await queries.exists(
                    name: "local_only", since: nil, until: nil, where: nil
                )
                let count = try await queries.count(
                    name: "activity", since: nil, until: nil, where: nil
                )
                let firstTime = try await queries.firstTime(name: "activity", where: nil)
                let lastTime = try await queries.lastTime(name: "activity", where: nil)
                let sum = try await queries.aggregate(
                    .sum, name: "activity", prop: "value", since: nil, until: nil, where: nil
                )
                let inOrder = try await queries.inOrder(
                    steps: [
                        StepQuery(name: "step_a", predicate: nil),
                        StepQuery(name: "step_b", predicate: nil),
                    ],
                    overallWithin: 150,
                    perStepWithin: 150,
                    since: nil,
                    until: nil
                )
                let activePeriods = try await queries.activePeriods(
                    name: "activity", period: .day, total: 5, min: 2, where: nil
                )
                let stopped = try await queries.stopped(
                    name: "habit", inactiveFor: 100, where: nil
                )
                let restarted = try await queries.restarted(
                    name: "restart", inactiveFor: 500, within: 60, where: nil
                )

                expect(exists).to(beTrue())
                expect(count).to(equal(2))
                expect(firstTime).to(equal(duplicate.timestamp))
                expect(lastTime).to(equal(now.addingTimeInterval(-86_400)))
                expect(sum).to(equal(5))
                expect(inOrder).to(beTrue())
                expect(activePeriods).to(beTrue())
                expect(stopped).to(beFalse())
                expect(restarted).to(beTrue())
            }

            it("uses timestamp and id ordering consistently across source boundaries") {
                let log = MockEventLog()
                let timestamp = now.addingTimeInterval(-10)
                let persisted = try StoredEvent(
                    id: "b",
                    name: "second",
                    timestamp: timestamp,
                    distinctId: userId
                )
                let transient = try StoredEvent(
                    id: "a",
                    name: "first",
                    timestamp: timestamp,
                    distinctId: userId
                )
                await persist(persisted, in: log)
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: [transient],
                    now: { now }
                )

                let forward = try await queries.inOrder(
                    steps: [
                        StepQuery(name: "first", predicate: nil),
                        StepQuery(name: "second", predicate: nil),
                    ],
                    overallWithin: nil,
                    perStepWithin: nil,
                    since: nil,
                    until: nil
                )
                let reverse = try await queries.inOrder(
                    steps: [
                        StepQuery(name: "second", predicate: nil),
                        StepQuery(name: "first", predicate: nil),
                    ],
                    overallWithin: nil,
                    perStepWithin: nil,
                    since: nil,
                    until: nil
                )

                expect(forward).to(beTrue())
                expect(reverse).to(beFalse())
            }

            it("treats corrupt merged properties as unknown instead of satisfying is_not_set") {
                let log = MockEventLog()
                let corrupt = StoredEvent(
                    id: "corrupt-transient",
                    name: "purchase",
                    properties: Data("not-json".utf8),
                    timestamp: now.addingTimeInterval(-60),
                    distinctId: userId,
                    sessionId: nil
                )
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: [corrupt],
                    now: { now }
                )
                let boundedCountIsZero = IRExpr.compare(
                    op: "==",
                    left: .eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .duration(600),
                        where_: .pred(op: "is_not_set", key: "plan", value: nil)
                    ),
                    right: .number(0)
                )
                let result = await IRRuntime(
                    dateProvider: MockDateProvider(initialDate: now)
                ).eval(
                    .init(
                        ir_version: 1,
                        engine_min: nil,
                        compiled_at: nil,
                        expr: .not(boundedCountIsZero)
                    ),
                    .init(now: now, events: queries)
                )

                expect(result).to(beFalse())
            }

            it("restarts sequence matching from a later viable first step") {
                let log = MockEventLog()
                let events = [
                    try stored(id: "a-early", name: "a", secondsBeforeNow: 105),
                    try stored(id: "a-late", name: "a", secondsBeforeNow: 5),
                    try stored(id: "b", name: "b", secondsBeforeNow: 0),
                ]
                for event in events { await persist(event, in: log) }
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: [],
                    now: { now }
                )

                let matched = try await queries.inOrder(
                    steps: [
                        StepQuery(name: "a", predicate: nil),
                        StepQuery(name: "b", predicate: nil),
                    ],
                    overallWithin: 10,
                    perStepWithin: 10,
                    since: nil,
                    until: nil
                )

                expect(matched).to(beTrue())
            }

            it("queries persisted history by event name before applying limits") {
                let log = MockEventLog()
                let target = try stored(
                    id: "older-target",
                    name: "target",
                    secondsBeforeNow: 20_000
                )
                await persist(target, in: log)
                for index in 0..<10_001 {
                    await persist(try stored(
                        id: "noise-\(index)",
                        name: "noise",
                        secondsBeforeNow: TimeInterval(10_001 - index)
                    ), in: log)
                }
                let transient = try stored(
                    id: target.id,
                    name: target.name,
                    secondsBeforeNow: 20_000
                )
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: [transient],
                    now: { now }
                )

                let count = try await queries.count(
                    name: "target", since: nil, until: nil, where: nil
                )
                let first = try await queries.firstTime(name: "target", where: nil)

                expect(count).to(equal(1))
                expect(first).to(equal(target.timestamp))
            }

            it("rejects merged same-name history beyond the limit after deduplication") {
                let source = IRTestEventLog()
                source.history = try (0..<10_000).map { index in
                    try stored(
                        id: "persisted-\(index)",
                        name: "purchase",
                        secondsBeforeNow: TimeInterval(index + 1)
                    )
                }
                let transient = try stored(
                    id: "unique-transient",
                    name: "purchase",
                    secondsBeforeNow: 0
                )
                let queries = IREventQueriesAdapter(
                    eventLog: source,
                    distinctId: userId,
                    additionalEvents: [transient],
                    now: { now }
                )

                do {
                    _ = try await queries.count(
                        name: "purchase", since: nil, until: nil, where: nil
                    )
                    fail("Expected merged history truncation")
                } catch {
                    expect(error as? EventHistoryQueryError)
                        .to(equal(.truncated(limit: 10_000)))
                }
            }

            it("filters the default named-history query before applying its limit") {
                let source = IRTestEventLog()
                let target = try stored(
                    id: "default-target",
                    name: "target",
                    secondsBeforeNow: 20_000
                )
                source.history = [target] + (0..<100).map { index in
                    try! stored(
                        id: "default-noise-\(index)",
                        name: "noise",
                        secondsBeforeNow: TimeInterval(100 - index)
                    )
                }

                let matches = await (source as EventQuerySource).getEventsForUser(
                    userId,
                    name: "target",
                    since: nil,
                    until: nil,
                    ascending: true,
                    limit: 1
                )

                expect(matches.map(\.id)).to(equal([target.id]))
            }

            it("counts exactly the requested calendar periods") {
                let log = MockEventLog()
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let today = calendar.dateInterval(of: .day, for: now)!.start
                let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
                await persist(try StoredEvent(
                    id: "yesterday",
                    name: "daily",
                    timestamp: yesterday.addingTimeInterval(86_399),
                    distinctId: userId
                ), in: log)
                await persist(try StoredEvent(
                    id: "yesterday-only",
                    name: "yesterday_only",
                    timestamp: yesterday.addingTimeInterval(86_399),
                    distinctId: userId
                ), in: log)
                await persist(try StoredEvent(
                    id: "today",
                    name: "daily",
                    timestamp: today,
                    distinctId: userId
                ), in: log)
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: [],
                    now: { now }
                )

                let impossibleMinimum = try await queries.activePeriods(
                    name: "daily", period: .day, total: 1, min: 2, where: nil
                )
                let currentBucket = try await queries.activePeriods(
                    name: "daily", period: .day, total: 1, min: 1, where: nil
                )
                let priorBucket = try await queries.activePeriods(
                    name: "yesterday_only", period: .day, total: 1, min: 1, where: nil
                )

                expect(impossibleMinimum).to(beFalse())
                expect(currentBucket).to(beTrue())
                expect(priorBucket).to(beFalse())
            }

            it("evaluates recovered persisted history when no transient facts remain") {
                let log = MockEventLog()
                let recovered = try stored(
                    id: "recovered",
                    name: "recovered_event",
                    secondsBeforeNow: 30
                )
                await persist(recovered, in: log)
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: [],
                    now: { now }
                )

                let exists = try await queries.exists(
                    name: "recovered_event", since: nil, until: nil, where: nil
                )
                let lastTime = try await queries.lastTime(name: "recovered_event", where: nil)

                expect(exists).to(beTrue())
                expect(lastTime).to(equal(recovered.timestamp))
            }

            it("queries an unlimited merged snapshot through the real SQLite store") {
                let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ir-adapter-\(UUID.v7().uuidString).db")
                let store = SQLiteEventStore()
                let identity = MockIdentityService()
                identity.setDistinctId(userId)
                let log = EventLog(
                    identity: identity,
                    sessions: MockSessionService(),
                    dateProvider: MockDateProvider(initialDate: now),
                    apiClient: MockNuxieApi(),
                    store: store
                )
                let configuration = NuxieConfiguration(apiKey: "test-api-key")
                configuration.testingOverrides.customStoragePath = databaseURL
                try await log.configure(configuration: configuration)
                defer {
                    try? FileManager.default.removeItem(at: databaseURL)
                }

                let target = try stored(
                    id: "sqlite-target",
                    name: "sqlite_event",
                    secondsBeforeNow: 1
                )
                try await store.insertHistory(target)
                let queries = IREventQueriesAdapter(
                    eventLog: log,
                    distinctId: userId,
                    additionalEvents: [],
                    now: { now }
                )

                let count = try await queries.count(
                    name: "sqlite_event", since: nil, until: nil, where: nil
                )

                expect(count).to(equal(1))
                await log.close()
            }

            it("uses alternative sequence starts in an unscoped real-store adapter") {
                let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ir-unscoped-sequence-\(UUID.v7().uuidString).db")
                let store = SQLiteEventStore()
                let identity = MockIdentityService()
                identity.setDistinctId(userId)
                let log = EventLog(
                    identity: identity,
                    sessions: MockSessionService(),
                    dateProvider: MockDateProvider(initialDate: now),
                    apiClient: MockNuxieApi(),
                    store: store
                )
                let configuration = NuxieConfiguration(apiKey: "test-api-key")
                configuration.testingOverrides.customStoragePath = databaseURL
                try await log.configure(configuration: configuration)
                defer { try? FileManager.default.removeItem(at: databaseURL) }

                for event in [
                    try stored(id: "a-early", name: "a", secondsBeforeNow: 105),
                    try stored(id: "a-late", name: "a", secondsBeforeNow: 5),
                    try stored(id: "b", name: "b", secondsBeforeNow: 0),
                ] {
                    try await store.insertHistory(event)
                }
                let queries = IREventQueriesAdapter(eventLog: log)

                let matched = try await queries.inOrder(
                    steps: [
                        StepQuery(name: "a", predicate: nil),
                        StepQuery(name: "b", predicate: nil),
                    ],
                    overallWithin: 10,
                    perStepWithin: 10,
                    since: nil,
                    until: nil
                )

                expect(matched).to(beTrue())
                await log.close()
            }
        }
    }
}
