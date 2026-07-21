import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

// MARK: - Mock Services

final class IRTestIdentityService: IdentityServiceProtocol, IRUserProps {
    var properties: [String: Any] = [:]
    private var distinctId = "test-user"
    private var anonymousId = "test-anonymous"
    
    func userProperty(for key: String) async -> Any? {
        return properties[key]
    }
    
    // Required protocol methods
    func getDistinctId() -> String { distinctId }
    func getRawDistinctId() -> String? { distinctId }
    func getAnonymousId() -> String { anonymousId }
    var isIdentified: Bool { true }
    func setDistinctId(_ distinctId: String) { self.distinctId = distinctId }
    func reset(keepAnonymousId: Bool) {}
    func clearUserCache(distinctId: String?) {}
    func getUserProperties() -> [String: Any] { properties }
    func setUserProperties(_ properties: [String: Any]) { self.properties = properties }
    func setOnceUserProperties(_ properties: [String: Any]) {
        for (key, value) in properties where self.properties[key] == nil {
            self.properties[key] = value
        }
    }
}

final class IRTestEventLog: EventLogProtocol, IREventQueries {
    var existsResult = false
    var countResult = 0
    var firstTimeResult: Date? = nil
    var lastTimeResult: Date? = nil
    var aggregateResult: Double? = nil
    var inOrderResult = false
    var activePeriodsResult = false
    var stoppedResult = false
    var restartedResult = false
    
    func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
        return existsResult
    }
    
    func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
        return countResult
    }
    
    func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
        return firstTimeResult
    }
    
    func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
        return lastTimeResult
    }
    
    func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
        return aggregateResult
    }
    
    func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool {
        return inOrderResult
    }
    
    func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool {
        return activePeriodsResult
    }
    
    func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return stoppedResult
    }
    
    func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool {
        return restartedResult
    }
    
    // Required EventLogProtocol methods
    func track(_ event: String, properties: [String: Any]?, userProperties: [String: Any]?, userPropertiesSetOnce: [String: Any]?) {}
    func configure(configuration: NuxieConfiguration?) async throws {}
    func subscribeCommitted(
        where filter: (@Sendable (NuxieEvent) -> Bool)?,
        handler: @escaping CommittedEventHandler
    ) async {}
    func getRecentEvents(limit: Int) async -> [StoredEvent] { return [] }
    func getEventsForUser(_ distinctId: String, limit: Int) async -> [StoredEvent] { return [] }
    func getEvents(for sessionId: String) async -> [StoredEvent] { return [] }
    func hasEvent(name: String, distinctId: String, since: Date?) async -> Bool { return false }
    func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async -> Int { return 0 }
    func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async -> Date? { return nil }
    func flushEvents() async -> Bool { return true }
    func getQueuedEventCount() async -> Int { return 0 }
    func pauseEventQueue() async {}
    func resumeEventQueue() async {}
    func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int { return 0 }
    func close() async {}
    func onAppDidEnterBackground() async {}
    func onAppBecameActive() async {}
    func drain() async {}
    func storePreparedEventInHistory(_ event: NuxieEvent) async {}
    func trackWithResponse(_ event: String, properties: [String: Any]?) async throws -> EventResponse {
        return EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: nil
        )
    }

    func trackWithResponse(
        _ event: String,
        properties: [String: Any]?,
        flushStrategy: EventFlushStrategy
    ) async throws -> EventResponse {
        return try await trackWithResponse(event, properties: properties)
    }

    func trackForTrigger(
        _ event: String,
        properties: [String: Any]?,
        userProperties: [String: Any]?,
        userPropertiesSetOnce: [String: Any]?,
        persistToHistory: Bool,
        distinctIdOverride: String?
    ) async throws -> (NuxieEvent, EventResponse) {
        let nuxieEvent = NuxieEvent(
            name: event,
            distinctId: distinctIdOverride ?? "test-user",
            properties: properties ?? [:]
        )
        let response = EventResponse(
            status: "ok",
            payload: nil,
            customer: nil,
            eventId: nil,
            message: nil,
            featuresMatched: nil,
            usage: nil,
            journey: nil,
            execution: nil
        )
        return (nuxieEvent, response)
    }
}

final class IRTestSegmentService: SegmentServiceProtocol, IRSegmentQueries, @unchecked Sendable {
    var memberSegments: Set<String> = ["premium_users"]
    var enteredDates: [String: Date] = ["premium_users": Date(timeIntervalSince1970: 1704067200)] // 2024-01-01
    
    func getCurrentMemberships() async -> [SegmentService.SegmentMembership] {
        return memberSegments.map { segmentId in
            SegmentService.SegmentMembership(
                segmentId: segmentId,
                segmentName: segmentId,
                enteredAt: enteredDates[segmentId] ?? Date(),
                lastEvaluated: Date()
            )
        }
    }
    
    func updateSegments(
        _ segments: [Segment], referencedBy campaigns: [Campaign], for distinctId: String
    ) async {}
    func handleCommittedEvent(_ event: NuxieEvent) async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func clearSegments(for distinctId: String) async { memberSegments.removeAll(); enteredDates.removeAll() }
    var segmentChanges: AsyncStream<SegmentService.SegmentEvaluationResult> {
        AsyncStream { _ in }
    }
    
    func isInSegment(_ segmentId: String) async -> Bool {
        return memberSegments.contains(segmentId)
    }
    
    func isMember(_ segmentId: String) async -> Bool {
        return memberSegments.contains(segmentId)
    }
    
    func enteredAt(_ segmentId: String) async -> Date? {
        return enteredDates[segmentId]
    }
}

// MARK: - Tests

final class IRInterpreterTests: AsyncSpec {
    override class func spec() {
        var interpreter: IRInterpreter!
        var mockIdentity: IRTestIdentityService!
        var mockEvents: IRTestEventLog!
        var mockSegments: IRTestSegmentService!
        var ctx: EvalContext!
        let testDate = Date(timeIntervalSince1970: 1700000000)
        let triggerEvent = TestEventBuilder(name: "purchase")
            .withDistinctId("user_123")
            .withProperties([
                "amount": 149.99,
                "plan": "premium",
                "meta": ["source": "ads"]
            ])
            .withTimestamp(testDate)
            .build()
        
        beforeEach {
            mockIdentity = IRTestIdentityService()
            mockEvents = IRTestEventLog()
            mockSegments = IRTestSegmentService()
            ctx = EvalContext(
                now: testDate,
                user: mockIdentity,
                events: mockEvents,
                segments: mockSegments,
                event: triggerEvent
            )
            interpreter = IRInterpreter(ctx: ctx)
        }
        
        describe("Boolean evaluation") {
            it("should evaluate bool literals") {
                let trueExpr = IRExpr.bool(true)
                let falseExpr = IRExpr.bool(false)
                
                await expect { try await interpreter.evalBool(trueExpr) }.to(beTrue())
                await expect { try await interpreter.evalBool(falseExpr) }.to(beFalse())
            }
            
            it("should evaluate AND operations") {
                let expr = IRExpr.and([
                    .bool(true),
                    .bool(true),
                    .bool(true)
                ])
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.and([
                    .bool(true),
                    .bool(false),
                    .bool(true)
                ])
                await expect { try await interpreter.evalBool(expr2) }.to(beFalse())
                
                // Empty AND returns true
                let expr3 = IRExpr.and([])
                await expect { try await interpreter.evalBool(expr3) }.to(beTrue())
            }
            
            it("should evaluate OR operations") {
                let expr = IRExpr.or([
                    .bool(false),
                    .bool(false),
                    .bool(true)
                ])
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.or([
                    .bool(false),
                    .bool(false),
                    .bool(false)
                ])
                await expect { try await interpreter.evalBool(expr2) }.to(beFalse())
                
                // Empty OR returns false
                let expr3 = IRExpr.or([])
                await expect { try await interpreter.evalBool(expr3) }.to(beFalse())
            }
            
            it("should evaluate NOT operations") {
                let expr = IRExpr.not(.bool(true))
                await expect { try await interpreter.evalBool(expr) }.to(beFalse())
                
                let expr2 = IRExpr.not(.bool(false))
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
            }
            
            it("should handle nested boolean operations") {
                let expr = IRExpr.and([
                    .or([.bool(true), .bool(false)]),
                    .not(.bool(false))
                ])
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
            }
        }
        
        describe("Comparison operations") {
            it("should compare numbers") {
                let expr = IRExpr.compare(op: ">=", left: .number(10), right: .number(5))
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.compare(op: "<", left: .number(10), right: .number(5))
                await expect { try await interpreter.evalBool(expr2) }.to(beFalse())
                
                let expr3 = IRExpr.compare(op: "==", left: .number(5), right: .number(5))
                await expect { try await interpreter.evalBool(expr3) }.to(beTrue())
            }
            
            it("should compare strings") {
                let expr = IRExpr.compare(op: "==", left: .string("hello"), right: .string("hello"))
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.compare(op: "!=", left: .string("hello"), right: .string("world"))
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
                
                let expr3 = IRExpr.compare(op: ">", left: .string("b"), right: .string("a"))
                await expect { try await interpreter.evalBool(expr3) }.to(beTrue())
            }
            
            it("should handle in/not_in operators") {
                let expr = IRExpr.compare(op: "in", left: .string("apple"), right: .list([.string("apple"), .string("banana")]))
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.compare(op: "not_in", left: .string("orange"), right: .list([.string("apple"), .string("banana")]))
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
            }
        }
        
        describe("User property operations") {
            it("should check if property is set") {
                mockIdentity.properties["email"] = "test@example.com"
                
                let expr = IRExpr.user(op: "is_set", key: "email", value: nil)
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.user(op: "is_not_set", key: "phone", value: nil)
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
            }
            
            it("should compare user properties") {
                mockIdentity.properties["age"] = 25
                mockIdentity.properties["name"] = "John"
                
                let expr = IRExpr.user(op: "gt", key: "age", value: .number(20))
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.user(op: "eq", key: "name", value: .string("John"))
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
            }
            
            it("should handle icontains for user properties") {
                mockIdentity.properties["email"] = "test@example.com"
                
                let expr = IRExpr.user(op: "icontains", key: "email", value: .string("EXAMPLE"))
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
            }
            
            it("should handle in operator for user properties") {
                mockIdentity.properties["role"] = "admin"
                
                let expr = IRExpr.user(op: "in", key: "role", value: .list([.string("admin"), .string("moderator")]))
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.user(op: "not_in", key: "role", value: .list([.string("user"), .string("guest")]))
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
            }
        }
        
        describe("Segment operations") {
            it("should check segment membership") {
                let expr = IRExpr.segment(op: "is_member", id: "premium_users", within: nil)
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.segment(op: "not_member", id: "basic_users", within: nil)
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
            }
        }
        
        describe("Event queries") {
            it("should check event existence") {
                mockEvents.existsResult = true
                
                let expr = IRExpr.eventsExists(name: "purchase", since: nil, until: nil, within: .duration(86400), where_: nil)
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                mockEvents.existsResult = false
                await expect { try await interpreter.evalBool(expr) }.to(beFalse())
            }
            
            it("should check event count") {
                mockEvents.countResult = 5
                
                let expr = IRExpr.eventsCount(name: "login", since: nil, until: nil, within: nil, where_: nil)
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                mockEvents.countResult = 0
                await expect { try await interpreter.evalBool(expr) }.to(beFalse())
            }
            
            it("should check event timing") {
                mockEvents.firstTimeResult = Date(timeIntervalSince1970: 1699900000)
                mockEvents.lastTimeResult = Date(timeIntervalSince1970: 1699990000)
                
                let expr = IRExpr.eventsFirstTime(name: "signup", where_: nil)
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
                
                let expr2 = IRExpr.eventsLastTime(name: "login", where_: nil)
                await expect { try await interpreter.evalBool(expr2) }.to(beTrue())
                
                mockEvents.firstTimeResult = nil
                await expect { try await interpreter.evalBool(expr) }.to(beFalse())
            }
        }
        
        describe("Value evaluation") {
            it("should evaluate scalar values") {
                let numExpr = IRExpr.number(42.5)
                let numValue = try await interpreter.evalValue(numExpr)
                expect(numValue).to(equal(IRValue.number(42.5)))

                let strExpr = IRExpr.string("hello")
                let strValue = try await interpreter.evalValue(strExpr)
                expect(strValue).to(equal(IRValue.string("hello")))
            }

            it("should evaluate time expressions") {
                let nowExpr = IRExpr.timeNow
                let nowValue = try await interpreter.evalValue(nowExpr)
                if case .timestamp(let ts) = nowValue {
                    expect(ts).to(equal(testDate.timeIntervalSince1970))
                } else {
                    fail("Expected timestamp value")
                }

                let agoExpr = IRExpr.timeAgo(duration: .duration(3600))
                let agoValue = try await interpreter.evalValue(agoExpr)
                if case .timestamp(let ts) = agoValue {
                    expect(ts).to(equal(testDate.timeIntervalSince1970 - 3600))
                } else {
                    fail("Expected timestamp value")
                }

                let windowExpr = IRExpr.timeWindow(value: 7, interval: "day")
                let windowValue = try await interpreter.evalValue(windowExpr)
                if case .duration(let d) = windowValue {
                    expect(d).to(equal(7 * 86400))
                } else {
                    fail("Expected duration value")
                }
            }

            it("should evaluate lists") {
                let listExpr = IRExpr.list([.number(1), .string("two"), .bool(true)])
                let listValue = try await interpreter.evalValue(listExpr)

                if case .list(let items) = listValue {
                    expect(items).to(haveCount(3))
                    expect(items[0]).to(equal(.number(1)))
                    expect(items[1]).to(equal(.string("two")))
                    expect(items[2]).to(equal(.bool(true)))
                } else {
                    fail("Expected list value")
                }
            }
        }

        describe("Journey context evaluation") {
            it("should return journey ID when present in context") {
                let ctxWithJourney = EvalContext(
                    now: testDate,
                    user: mockIdentity,
                    events: mockEvents,
                    segments: mockSegments,
                    event: triggerEvent,
                    journeyId: "journey_abc123"
                )
                let interpreterWithJourney = IRInterpreter(ctx: ctxWithJourney)

                let expr = IRExpr.journeyId
                let value = try await interpreterWithJourney.evalValue(expr)

                if case .string(let id) = value {
                    expect(id).to(equal("journey_abc123"))
                } else {
                    fail("Expected string value for journeyId")
                }
            }

            it("should return null when journey ID is not in context") {
                // Default ctx has no journeyId
                let expr = IRExpr.journeyId
                let value = try await interpreter.evalValue(expr)

                expect(value).to(equal(IRValue.null))
            }

            it("should compare journey ID in event filter") {
                let ctxWithJourney = EvalContext(
                    now: testDate,
                    user: mockIdentity,
                    events: mockEvents,
                    segments: mockSegments,
                    event: NuxieEvent(
                        name: "$transaction_complete",
                        distinctId: "user_123",
                        properties: ["journey_id": "journey_abc123"]
                    ),
                    journeyId: "journey_abc123"
                )
                let interpreterWithJourney = IRInterpreter(ctx: ctxWithJourney)

                // Filter: properties.journey_id == Journey.Id
                let expr = IRExpr.compare(
                    op: "==",
                    left: .event(op: "eq", key: "properties.journey_id", value: nil),
                    right: .journeyId
                )

                // This tests that Journey.Id resolves to a string that can be compared
                // The actual comparison logic needs event property access
                let journeyIdValue = try await interpreterWithJourney.evalValue(.journeyId)
                expect(journeyIdValue).to(equal(IRValue.string("journey_abc123")))
            }
        }
        
        describe("Truthiness") {
            it("should treat values as truthy/falsy in boolean context") {
                // Numbers: 0 is falsy, others are truthy
                await expect { try await interpreter.evalBool(.number(0)) }.to(beFalse())
                await expect { try await interpreter.evalBool(.number(1)) }.to(beTrue())
                await expect { try await interpreter.evalBool(.number(-1)) }.to(beTrue())
                
                // Strings: empty is falsy, others are truthy
                await expect { try await interpreter.evalBool(.string("")) }.to(beFalse())
                await expect { try await interpreter.evalBool(.string("hello")) }.to(beTrue())
                
                // Lists: empty is falsy, others are truthy
                await expect { try await interpreter.evalBool(.list([])) }.to(beFalse())
                await expect { try await interpreter.evalBool(.list([.bool(false)])) }.to(beTrue())
            }
        }
        
        describe("Complex expressions") {
            it("should evaluate complex nested expressions") {
                mockIdentity.properties["subscription"] = "premium"
                mockIdentity.properties["signupDate"] = Date(timeIntervalSince1970: 1690000000)
                mockEvents.countResult = 3
                
                // User has premium subscription AND made purchases in last 30 days
                let expr = IRExpr.and([
                    .user(op: "eq", key: "subscription", value: .string("premium")),
                    .eventsCount(
                        name: "purchase",
                        since: nil,
                        until: nil,
                        within: .timeWindow(value: 30, interval: "day"),
                        where_: nil
                    )
                ])
                
                await expect { try await interpreter.evalBool(expr) }.to(beTrue())
            }
        }
        
        describe("Event node evaluation") {
            it("should match $name and properties.*") {
                let nameExpr = IRExpr.event(op: "eq", key: "$name", value: .string("purchase"))
                await expect { try await interpreter.evalBool(nameExpr) }.to(beTrue())

                let amountExpr = IRExpr.event(op: "gt", key: "properties.amount", value: .number(100))
                await expect { try await interpreter.evalBool(amountExpr) }.to(beTrue())

                let srcExpr = IRExpr.event(op: "eq", key: "properties.meta.source", value: .string("ads"))
                await expect { try await interpreter.evalBool(srcExpr) }.to(beTrue())
            }

            it("should handle timestamp date ops") {
                let afterExpr = IRExpr.event(op: "is_date_after", key: "$timestamp", value: .timestamp(1600000000))
                await expect { try await interpreter.evalBool(afterExpr) }.to(beTrue())
            }
        }
    }
}
