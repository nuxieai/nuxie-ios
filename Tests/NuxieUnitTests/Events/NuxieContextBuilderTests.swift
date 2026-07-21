import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class NuxieContextBuilderTests: QuickSpec {
    
    override class func spec() {
        var mockFactory: MockFactory!
        var identityService: MockIdentityService!
        var configuration: NuxieConfiguration!
        var contextBuilder: NuxieContextBuilder!
        
        beforeEach {
            mockFactory = MockFactory.shared
            identityService = mockFactory.identityService
            
            configuration = NuxieConfiguration(apiKey: "test-api-key")
            configuration.environment = .development
            configuration.logLevel = .debug
            
            contextBuilder = NuxieContextBuilder(
                identityService: identityService,
                configuration: configuration
            )
        }
        
        afterEach {
            identityService.reset()
        }

        func awaitEnriched(
            _ builder: NuxieContextBuilder,
            customProperties: [String: Any] = [:]
        ) -> [String: Any] {
            var result: [String: Any] = [:]
            waitUntil { done in
                Task {
                    result = await builder.buildEnrichedProperties(customProperties: customProperties)
                    done()
                }
            }
            return result
        }
        
        describe("NuxieContextBuilder") {
            
            describe("buildEnrichedProperties") {
                
                it("should include all context layers") {
                    let customProperties = ["custom_key": "custom_value"]
                    
                    let enriched = awaitEnriched(contextBuilder, customProperties: customProperties)
                    
                    // Layer 1: Static Device Context
                    expect(enriched["$device_manufacturer"]).toNot(beNil())
                    expect(enriched["$device_model"]).toNot(beNil())
                    expect(enriched["$device_type"]).toNot(beNil())
                    expect(enriched["$os_name"]).toNot(beNil())
                    expect(enriched["$os_version"]).toNot(beNil())
                    
                    // Layer 2: Dynamic Context
                    expect(enriched["$locale"]).toNot(beNil())
                    expect(enriched["$timezone"]).toNot(beNil())
                    expect(enriched["$memory_total"]).toNot(beNil())
                    
                    // Layer 3: SDK Context
                    expect(enriched["$lib"] as? String).to(equal("nuxie-ios"))
                    expect(enriched["$lib_version"]).toNot(beNil())
                    expect(enriched["$environment"] as? String).to(equal("development"))
                    expect(enriched["$log_level"] as? String).to(equal("debug"))
                    
                    // Layer 4: User Context
                    expect(enriched["$distinct_id"]).toNot(beNil())
                    expect(enriched["$is_identified"]).toNot(beNil())
                    
                    // Layer 5: Custom Properties
                    expect(enriched["custom_key"] as? String).to(equal("custom_value"))
                }
                
                it("should prioritize custom properties over system properties") {
                    let customProperties = [
                        "$lib": "custom-lib",
                        "$device_manufacturer": "CustomManufacturer",
                        "user_property": "user_value"
                    ] as [String: Any]
                    
                    let enriched = awaitEnriched(contextBuilder, customProperties: customProperties)
                    
                    // Custom properties should override system properties
                    expect(enriched["$lib"] as? String).to(equal("custom-lib"))
                    expect(enriched["$device_manufacturer"] as? String).to(equal("CustomManufacturer"))
                    expect(enriched["user_property"] as? String).to(equal("user_value"))
                }
                
                it("should work with empty custom properties") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    // Should still have all system properties
                    expect(enriched["$device_manufacturer"]).toNot(beNil())
                    expect(enriched["$lib"]).toNot(beNil())
                    expect(enriched["$distinct_id"]).toNot(beNil())
                }
            }
            
            describe("static device context") {
                
                it("should include app information") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    // App bundle ID should always be present
                    expect(enriched["$app_bundle_id"]).toNot(beNil())
                    
                    // These may or may not be present depending on test bundle configuration
                    // but we should check they are handled correctly if present
                    if let appName = enriched["$app_name"] as? String {
                        expect(appName).toNot(beEmpty())
                    }
                    
                    if let appVersion = enriched["$app_version"] as? String {
                        expect(appVersion).toNot(beEmpty())
                    }
                    
                    if let appBuild = enriched["$app_build"] as? String {
                        expect(appBuild).toNot(beEmpty())
                    }
                }
                
                it("should include device information") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$device_manufacturer"] as? String).to(equal("Apple"))
                    expect(enriched["$device_model"] as? String).toNot(beEmpty())
                    expect(enriched["$device_type"] as? String).toNot(beEmpty())
                }
                
                it("should include OS information") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$os_name"] as? String).toNot(beEmpty())
                    expect(enriched["$os_version"] as? String).toNot(beEmpty())
                }
                
                it("should detect environment flags") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$is_emulator"] as? Bool).toNot(beNil())
                    expect(enriched["$is_debug"] as? Bool).toNot(beNil())
                }
            }
            
            describe("dynamic context") {
                
                it("should include screen information on iOS") {
                    #if canImport(UIKit)
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$screen_width"] as? Float).toNot(beNil())
                    expect(enriched["$screen_height"] as? Float).toNot(beNil())
                    expect(enriched["$screen_scale"] as? Float).toNot(beNil())
                    #endif
                }
                
                it("should include locale and timezone") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$locale"] as? String).toNot(beEmpty())
                    expect(enriched["$language"]).toNot(beNil()) // May be nil in some locales
                    expect(enriched["$country"]).toNot(beNil()) // May be nil in some locales
                    expect(enriched["$timezone"] as? String).toNot(beEmpty())
                    expect(enriched["$timezone_offset"] as? Int).toNot(beNil())
                }
                
                it("should include memory information") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$memory_total"] as? Int).to(beGreaterThan(0))
                    expect(enriched["$memory_available"] as? Int).toNot(beNil())
                }
                
                it("should include network type") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    // Currently returns "unknown" as placeholder
                    expect(enriched["$network_type"] as? String).to(equal("unknown"))
                }
            }
            
            describe("SDK context") {
                
                it("should include SDK information") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$lib"] as? String).to(equal("nuxie-ios"))
                    expect(enriched["$lib_version"] as? String).to(equal(SDKVersion.current))
                }
                
                it("should include configuration context") {
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$environment"] as? String).to(equal("development"))
                    expect(enriched["$log_level"] as? String).to(equal("debug"))
                }
                
                it("should not stamp a session-start timestamp") {
                    // Session boundaries come from $session_id (UUIDv7) stamps;
                    // a per-event "$session_start = now" field was a lie.
                    let enriched = awaitEnriched(contextBuilder)
                    expect(enriched["$session_start"]).to(beNil())
                }
                
                it("should handle nil configuration") {
                    let builderWithoutConfig = NuxieContextBuilder(
                        identityService: identityService,
                        configuration: nil
                    )
                    
                    let enriched = awaitEnriched(builderWithoutConfig)
                    
                    // Should still have SDK info but not configuration-specific fields
                    expect(enriched["$lib"] as? String).to(equal("nuxie-ios"))
                    expect(enriched["$lib_version"]).toNot(beNil())
                    expect(enriched["$environment"]).to(beNil())
                    expect(enriched["$log_level"]).to(beNil())
                }
            }
            
            describe("user context") {
                
                it("should include user context when identity service is available") {
                    identityService.setDistinctId("test_user_123")
                    identityService.setAnonymousId("anon_456")
                    
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$distinct_id"] as? String).to(equal("test_user_123"))
                    expect(enriched["$user_id"] as? String).to(equal("test_user_123"))
                    expect(enriched["$anonymous_id"] as? String).to(equal("anon_456"))
                    expect(enriched["$is_identified"] as? Bool).to(beTrue())
                }
                
                it("should use anonymous ID when user not identified") {
                    identityService.reset(keepAnonymousId: true)
                    identityService.setAnonymousId("anon_789")
                    
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$distinct_id"] as? String).to(equal("anon_789"))
                    expect(enriched["$user_id"]).to(beNil())
                    expect(enriched["$anonymous_id"] as? String).to(equal("anon_789"))
                    expect(enriched["$is_identified"] as? Bool).to(beFalse())
                }
                
                it("should handle nil identity service") {
                    let builderWithoutIdentity = NuxieContextBuilder(
                        identityService: nil,
                        configuration: configuration
                    )
                    
                    let enriched = awaitEnriched(builderWithoutIdentity)
                    
                    // Should not have user context fields
                    expect(enriched["$distinct_id"]).to(beNil())
                    expect(enriched["$user_id"]).to(beNil())
                    expect(enriched["$anonymous_id"]).to(beNil())
                    expect(enriched["$is_identified"]).to(beNil())
                }
                
                it("should handle mixed identified and anonymous state") {
                    identityService.setDistinctId("user_123")
                    identityService.setAnonymousId("anon_456")
                    
                    let enriched = awaitEnriched(contextBuilder)
                    
                    expect(enriched["$distinct_id"] as? String).to(equal("user_123"))
                    expect(enriched["$user_id"] as? String).to(equal("user_123"))
                    expect(enriched["$anonymous_id"] as? String).to(equal("anon_456"))
                    expect(enriched["$is_identified"] as? Bool).to(beTrue())
                }
            }
            
            describe("layer merging") {
                
                it("should merge layers in correct precedence order") {
                    identityService.setDistinctId("user_123")
                    
                    let customProperties = [
                        "$lib": "override-lib",
                        "$distinct_id": "override-user",
                        "custom_field": "custom_value"
                    ] as [String: Any]
                    
                    let enriched = awaitEnriched(contextBuilder, customProperties: customProperties)
                    
                    // Custom properties should win
                    expect(enriched["$lib"] as? String).to(equal("override-lib"))
                    expect(enriched["$distinct_id"] as? String).to(equal("override-user"))
                    expect(enriched["custom_field"] as? String).to(equal("custom_value"))
                    
                    // Other layers should still be present
                    expect(enriched["$device_manufacturer"]).toNot(beNil())
                    expect(enriched["$timezone"]).toNot(beNil())
                }
                
                it("should handle complex nested custom properties") {
                    let customProperties = [
                        "user": [
                            "id": 123,
                            "name": "Test User",
                            "metadata": [
                                "role": "admin",
                                "tier": "premium"
                            ]
                        ],
                        "session": [
                            "id": "session_123",
                            "started_at": Date()
                        ],
                        "$custom_override": "value"
                    ] as [String: Any]
                    
                    let enriched = awaitEnriched(contextBuilder, customProperties: customProperties)
                    
                    // Custom nested properties should be preserved
                    let user = enriched["user"] as? [String: Any]
                    expect(user?["id"] as? Int).to(equal(123))
                    expect(user?["name"] as? String).to(equal("Test User"))
                    
                    let metadata = user?["metadata"] as? [String: Any]
                    expect(metadata?["role"] as? String).to(equal("admin"))
                    expect(metadata?["tier"] as? String).to(equal("premium"))
                    
                    let session = enriched["session"] as? [String: Any]
                    expect(session?["id"] as? String).to(equal("session_123"))
                    expect(session?["started_at"]).toNot(beNil())
                    
                    expect(enriched["$custom_override"] as? String).to(equal("value"))
                    
                    // System properties should still be present
                    expect(enriched["$device_manufacturer"]).toNot(beNil())
                }
            }
        }
    }
}
