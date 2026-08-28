@testable import Nuxie

/// Builder for creating test segment identities.
class TestSegmentBuilder {
    private var id: String
    private var name: String

    init(id: String = "test-segment") {
        self.id = id
        self.name = "Test Segment"
    }

    func withId(_ id: String) -> TestSegmentBuilder {
        self.id = id
        return self
    }

    func withName(_ name: String) -> TestSegmentBuilder {
        self.name = name
        return self
    }

    func build() -> Segment {
        Segment(id: id, name: name)
    }
}
