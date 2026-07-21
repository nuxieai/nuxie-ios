import Foundation
@testable import Nuxie

/// Builder for creating test events with fluent API
class TestEventBuilder {
    private var name: String
    private var distinctId: String
    private var properties: [String: Any]
    private var timestamp: Date

    init(name: String = "test_event", dateProvider: DateProviderProtocol? = nil) {
        self.name = name
        self.distinctId = "test_user"
        self.properties = [:]
        self.timestamp = dateProvider?.now() ?? Date()
    }
    
    func withName(_ name: String) -> TestEventBuilder {
        self.name = name
        return self
    }
    
    func withDistinctId(_ distinctId: String) -> TestEventBuilder {
        self.distinctId = distinctId
        return self
    }
    
    func withProperties(_ properties: [String: Any]) -> TestEventBuilder {
        self.properties = properties
        return self
    }
    
    func addProperty(_ key: String, value: Any) -> TestEventBuilder {
        self.properties[key] = value
        return self
    }
    
    func withTimestamp(_ timestamp: Date) -> TestEventBuilder {
        self.timestamp = timestamp
        return self
    }
    
    func build() -> NuxieEvent {
        return NuxieEvent(
            name: name,
            distinctId: distinctId,
            properties: properties,
            timestamp: timestamp
        )
    }
}