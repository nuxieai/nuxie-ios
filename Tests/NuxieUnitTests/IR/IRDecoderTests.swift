import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class IRDecoderTests: AsyncSpec {
    override class func spec() {
        describe("IREnvelope") {
            it("should decode a simple IR envelope") {
                let json = """
                {
                    "ir_version": 1,
                    "engine_min": "1.0.0",
                    "compiled_at": 1723780000,
                    "expr": {
                        "type": "Bool",
                        "value": true
                    }
                }
                """
                
                let data = json.data(using: .utf8)!
                let envelope = try JSONDecoder().decode(IREnvelope.self, from: data)
                
                expect(envelope.ir_version).to(equal(1))
                expect(envelope.engine_min).to(equal("1.0.0"))
                expect(envelope.compiled_at).to(equal(1723780000))
                
                if case .bool(let value) = envelope.expr {
                    expect(value).to(beTrue())
                } else {
                    fail("Expected bool expression")
                }
            }
        }
        
        describe("IRExpr scalar types") {
            it("should decode Bool node") {
                let json = """
                {"type": "Bool", "value": false}
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .bool(let value) = expr {
                    expect(value).to(beFalse())
                } else {
                    fail("Expected bool expression")
                }
            }
            
            it("should decode Number node") {
                let json = """
                {"type": "Number", "value": 42.5}
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .number(let value) = expr {
                    expect(value).to(equal(42.5))
                } else {
                    fail("Expected number expression")
                }
            }
            
            it("should decode String node") {
                let json = """
                {"type": "String", "value": "hello world"}
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .string(let value) = expr {
                    expect(value).to(equal("hello world"))
                } else {
                    fail("Expected string expression")
                }
            }
            
            it("should decode Timestamp node") {
                let json = """
                {"type": "Timestamp", "value": 1723780000.5}
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .timestamp(let value) = expr {
                    expect(value).to(equal(1723780000.5))
                } else {
                    fail("Expected timestamp expression")
                }
            }
            
            it("should decode Duration node") {
                let json = """
                {"type": "Duration", "value": 3600}
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .duration(let value) = expr {
                    expect(value).to(equal(3600))
                } else {
                    fail("Expected duration expression")
                }
            }
            
            it("should decode List node") {
                let json = """
                {
                    "type": "List",
                    "value": [
                        {"type": "Number", "value": 1},
                        {"type": "String", "value": "test"},
                        {"type": "Bool", "value": true}
                    ]
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .list(let values) = expr {
                    expect(values).to(haveCount(3))
                    
                    if case .number(let n) = values[0] {
                        expect(n).to(equal(1))
                    } else {
                        fail("Expected number in list")
                    }
                    
                    if case .string(let s) = values[1] {
                        expect(s).to(equal("test"))
                    } else {
                        fail("Expected string in list")
                    }
                    
                    if case .bool(let b) = values[2] {
                        expect(b).to(beTrue())
                    } else {
                        fail("Expected bool in list")
                    }
                } else {
                    fail("Expected list expression")
                }
            }
        }
        
        describe("IRExpr boolean operators") {
            it("should decode And node") {
                let json = """
                {
                    "type": "And",
                    "args": [
                        {"type": "Bool", "value": true},
                        {"type": "Bool", "value": false}
                    ]
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .and(let args) = expr {
                    expect(args).to(haveCount(2))
                } else {
                    fail("Expected and expression")
                }
            }
            
            it("should decode Or node") {
                let json = """
                {
                    "type": "Or",
                    "args": [
                        {"type": "Bool", "value": true},
                        {"type": "Bool", "value": false}
                    ]
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .or(let args) = expr {
                    expect(args).to(haveCount(2))
                } else {
                    fail("Expected or expression")
                }
            }
            
            it("should decode Not node") {
                let json = """
                {
                    "type": "Not",
                    "arg": {"type": "Bool", "value": true}
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .not(let arg) = expr {
                    if case .bool(let value) = arg {
                        expect(value).to(beTrue())
                    } else {
                        fail("Expected bool in not")
                    }
                } else {
                    fail("Expected not expression")
                }
            }
        }
        
        describe("IRExpr comparison") {
            it("should decode Compare node") {
                let json = """
                {
                    "type": "Compare",
                    "op": ">=",
                    "left": {"type": "Number", "value": 10},
                    "right": {"type": "Number", "value": 5}
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .compare(let op, let left, let right) = expr {
                    expect(op).to(equal(">="))
                    
                    if case .number(let l) = left {
                        expect(l).to(equal(10))
                    } else {
                        fail("Expected number on left")
                    }
                    
                    if case .number(let r) = right {
                        expect(r).to(equal(5))
                    } else {
                        fail("Expected number on right")
                    }
                } else {
                    fail("Expected compare expression")
                }
            }
        }
        
        describe("IRExpr user operations") {
            it("should decode User node with value") {
                let json = """
                {
                    "type": "User",
                    "op": "eq",
                    "key": "email",
                    "value": {"type": "String", "value": "test@example.com"}
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .user(let op, let key, let value) = expr {
                    expect(op).to(equal("eq"))
                    expect(key).to(equal("email"))
                    
                    if let val = value, case .string(let s) = val {
                        expect(s).to(equal("test@example.com"))
                    } else {
                        fail("Expected string value")
                    }
                } else {
                    fail("Expected user expression")
                }
            }
            
            it("should decode User node without value") {
                let json = """
                {
                    "type": "User",
                    "op": "is_set",
                    "key": "premium"
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .user(let op, let key, let value) = expr {
                    expect(op).to(equal("is_set"))
                    expect(key).to(equal("premium"))
                    expect(value).to(beNil())
                } else {
                    fail("Expected user expression")
                }
            }
        }
        
        describe("IRExpr event operations") {
            it("should decode Event node with value") {
                let json = """
                {
                    "type": "Event",
                    "op": "eq",
                    "key": "$name",
                    "value": {"type": "String", "value": "purchase"}
                }
                """
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                if case .event(let op, let key, let value) = expr {
                    expect(op).to(equal("eq"))
                    expect(key).to(equal("$name"))
                    if let val = value, case .string(let s) = val {
                        expect(s).to(equal("purchase"))
                    } else {
                        fail("Expected string value")
                    }
                } else {
                    fail("Expected event expression")
                }
            }
        }
        
        describe("IRExpr event queries") {
            it("should decode Events.Exists node") {
                let json = """
                {
                    "type": "Events.Exists",
                    "name": "purchase",
                    "within": {"type": "Duration", "value": 86400}
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .eventsExists(let name, let since, let until, let within, let where_) = expr {
                    expect(name).to(equal("purchase"))
                    expect(since).to(beNil())
                    expect(until).to(beNil())
                    expect(where_).to(beNil())
                    
                    if let w = within, case .duration(let d) = w {
                        expect(d).to(equal(86400))
                    } else {
                        fail("Expected duration for within")
                    }
                } else {
                    fail("Expected eventsExists expression")
                }
            }
            
            it("should decode Events.Count with predicate") {
                let json = """
                {
                    "type": "Events.Count",
                    "name": "purchase",
                    "where": {
                        "type": "Pred",
                        "op": "gte",
                        "key": "amount",
                        "value": {"type": "Number", "value": 100}
                    }
                }
                """
                
                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                
                if case .eventsCount(let name, _, _, _, let where_) = expr {
                    expect(name).to(equal("purchase"))
                    
                    if let predicate = where_, case .pred(let op, let key, let value) = predicate {
                        expect(op).to(equal("gte"))
                        expect(key).to(equal("amount"))
                        
                        if let val = value, case .number(let n) = val {
                            expect(n).to(equal(100))
                        } else {
                            fail("Expected number value in predicate")
                        }
                    } else {
                        fail("Expected predicate")
                    }
                } else {
                    fail("Expected eventsCount expression")
                }
            }
        }
        
        describe("IRExpr time helpers") {
            it("should decode Time.Now node") {
                let json = """
                {"type": "Time.Now"}
                """

                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)

                if case .timeNow = expr {
                    // Success
                } else {
                    fail("Expected timeNow expression")
                }
            }

            it("should decode Time.Window node") {
                let json = """
                {
                    "type": "Time.Window",
                    "value": 7,
                    "interval": "day"
                }
                """

                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)

                if case .timeWindow(let value, let interval) = expr {
                    expect(value).to(equal(7))
                    expect(interval).to(equal("day"))
                } else {
                    fail("Expected timeWindow expression")
                }
            }
        }

        describe("IRExpr journey context") {
            it("should decode Journey.Id node") {
                let json = """
                {"type": "Journey.Id"}
                """

                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)

                if case .journeyId = expr {
                    // Success
                } else {
                    fail("Expected journeyId expression")
                }
            }
        }
        
        describe("Forward compatibility") {
            it("decodes unknown node types tolerantly and evaluates them fail-closed") {
                // One new server op must never brick the enclosing
                // experience/profile decode for older SDKs.
                let json = """
                {"type": "UnknownNode", "value": 123}
                """

                let data = json.data(using: .utf8)!
                let expr = try JSONDecoder().decode(IRExpr.self, from: data)
                expect(expr).to(equal(.unknown(type: "UnknownNode")))

                let interpreter = IRInterpreter(ctx: EvalContext(now: Date()))
                let result = try await interpreter.evalBool(expr)
                expect(result).to(beFalse())
            }

            it("skips envelopes stamped with a newer engine_min") {
                let envelope = IREnvelope(
                    ir_version: 1,
                    engine_min: "99",
                    compiled_at: nil,
                    expr: .bool(true)
                )
                expect(envelope.isSupportedByThisEngine).to(beFalse())

                let supported = IREnvelope(
                    ir_version: 1,
                    engine_min: "1",
                    compiled_at: nil,
                    expr: .bool(true)
                )
                expect(supported.isSupportedByThisEngine).to(beTrue())
            }
        }
    }
}