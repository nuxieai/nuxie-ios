import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class NuxieEventTests: QuickSpec {
    
    override class func spec() {
        
        // MARK: - NuxieEvent Basic Tests
        
        describe("NuxieEvent") {
            it("should create event with required parameters") {
                let now = Date()
                let event = TestEventBuilder(name: "test_event")
                    .withDistinctId("user123")
                    .withProperties(["key": "value", "source": "test"])
                    .withTimestamp(now)
                    .build()
                
                expect(event.name).to(equal("test_event"))
                expect(event.distinctId).to(equal("user123"))
                expect(event.properties["key"] as? String).to(equal("value"))
                expect(event.properties["source"] as? String).to(equal("test"))
                expect(event.id).toNot(beEmpty())
                expect(event.timestamp).to(beCloseTo(now, within: 1))
            }
            
            it("should generate unique IDs for different events") {
                let event1 = TestEventBuilder(name: "event1")
                    .withDistinctId("user")
                    .build()
                
                let event2 = TestEventBuilder(name: "event2")
                    .withDistinctId("user")
                    .build()
                
                expect(event1.id).toNot(equal(event2.id))
            }
            
            it("should handle nil session in properties") {
                let event = TestEventBuilder(name: "test")
                    .withDistinctId("user")
                    .build()
                
                expect(event.properties["source"]).to(beNil())
            }
            
            it("should handle empty properties") {
                let event = TestEventBuilder(name: "empty_props")
                    .withDistinctId("user")
                    .build()
                
                expect(event.properties).to(beEmpty())
            }
        }
        
        
        // MARK: - Event Validation Tests
        
        describe("NuxieEvent Validation") {
            it("should handle special characters in event names") {
                let event = TestEventBuilder(name: "special-chars_test.event$123")
                    .withDistinctId("user")
                    .build()
                
                expect(event.name).to(equal("special-chars_test.event$123"))
            }
            
            it("should handle unicode in properties") {
                let properties = [
                    "emoji": "🎉🚀",
                    "chinese": "你好",
                    "arabic": "مرحبا",
                    "special": "æøå"
                ] as [String: Any]
                
                let event = TestEventBuilder(name: "unicode_test")
                    .withDistinctId("user")
                    .withProperties(properties)
                    .build()
                
                expect(event.properties["emoji"] as? String).to(equal("🎉🚀"))
                expect(event.properties["chinese"] as? String).to(equal("你好"))
                expect(event.properties["arabic"] as? String).to(equal("مرحبا"))
                expect(event.properties["special"] as? String).to(equal("æøå"))
            }
            
            it("should handle large property dictionaries") {
                var largeProperties: [String: Any] = [:]
                
                // Create 100 properties
                for i in 0..<100 {
                    largeProperties["key_\(i)"] = "value_\(i)"
                }
                
                let event = TestEventBuilder(name: "large_props_test")
                    .withDistinctId("user")
                    .withProperties(largeProperties)
                    .build()
                
                expect(event.properties.count).to(equal(100))
                expect(event.properties["key_0"] as? String).to(equal("value_0"))
                expect(event.properties["key_99"] as? String).to(equal("value_99"))
            }
        }
    }
}
